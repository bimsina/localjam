/// LocalJam host: serves the control plane (WebSocket `/ws`) and the media
/// plane (HTTP `/media/{mediaId}`) on one TCP port (PROTOCOL.md §1), and
/// drives a [HostSession] as the single authoritative state writer (§5).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:localjam_core/localjam_core.dart';
import 'package:meta/meta.dart';

import 'media_metadata.dart';
import 'monotonic.dart';

/// What a [JamHostServer] does when the current item reaches its end
/// (PROTOCOL.md §5.5). End of media is only detectable for items whose
/// playlist entry carries a `durationUs`; without one the anchor extrapolates
/// and no policy fires. Guests see only the ordinary state broadcasts the
/// policy produces — no protocol change.
enum JamEndPolicy {
  /// Pause, frozen at exactly the item's duration (the default).
  pause,

  /// Select the next playlist item (wrapping at the end of the playlist)
  /// and immediately schedule playback.
  advance,

  /// Stop: back to idle with no media selected.
  stop,
}

/// Kind of a [JamHostEvent].
enum JamHostEventKind {
  /// A guest completed the join handshake ([JamHostEvent.peer] set).
  peerJoined,

  /// A guest was dropped or left ([JamHostEvent.peerId] set).
  peerLeft,

  /// A guest reported `media_status` ([JamHostEvent.peerId],
  /// [JamHostEvent.mediaId], and [JamHostEvent.mediaState] set;
  /// [JamHostEvent.progress] set when the report carried one).
  peerMediaStatus,

  /// A new authoritative state snapshot was broadcast
  /// ([JamHostEvent.snapshot] set).
  stateBroadcast,

  /// A new playlist was broadcast ([JamHostEvent.playlist] set).
  playlistBroadcast,

  /// A guest uploaded a new media item over the media plane (§6.4;
  /// [JamHostEvent.mediaId] set, [JamHostEvent.peerId] set when the upload
  /// carried `X-LocalJam-Peer-Id`). Emitted before the playlist broadcast the
  /// upload produces. Idempotent re-uploads of existing content do not fire.
  mediaUploaded,

  /// The current item reached its end ([JamHostEvent.mediaId] set to the
  /// ended item). Emitted exactly once per track end, before the state
  /// broadcast produced by the [JamEndPolicy].
  mediaEnded,
}

/// One observability event from a [JamHostServer]. Fields other than [kind]
/// are set per [JamHostEventKind]; unrelated fields are null.
@immutable
class JamHostEvent {
  const JamHostEvent._(
    this.kind, {
    this.peer,
    this.peerId,
    this.mediaId,
    this.mediaState,
    this.progress,
    this.snapshot,
    this.playlist,
  });

  final JamHostEventKind kind;
  final PeerInfo? peer;
  final String? peerId;
  final String? mediaId;
  final MediaFetchState? mediaState;

  /// Fetch progress in [0, 1] from the guest's `media_status` report, when
  /// it carried one (§6.3). Only set for [JamHostEventKind.peerMediaStatus].
  final double? progress;

  final PlaybackSnapshot? snapshot;
  final List<MediaItem>? playlist;

  @override
  String toString() =>
      'JamHostEvent(${kind.name}'
      '${peerId != null ? ', peerId: $peerId' : ''}'
      '${mediaId != null ? ', mediaId: $mediaId' : ''})';
}

/// One connected (or connecting) guest socket.
class _GuestConn {
  _GuestConn(this.ws, {required int nowUs}) : lastFrameUs = nowUs;

  final WebSocket ws;

  /// Assigned after a valid `hello`; null while the handshake is pending.
  String? peerId;
  PeerInfo? info;

  /// Monotonic µs of the last received frame, for liveness (§3.3).
  int lastFrameUs;

  bool get joined => peerId != null;
}

/// The LocalJam host: one [HttpServer] serving both protocol planes
/// (PROTOCOL.md §1), the join/presence/liveness lifecycle (§3), clock-sync
/// pong duty (§4), request application via [HostSession] (§5.2), and media
/// distribution (§6).
class JamHostServer {
  /// Creates a host for a session named [sessionName].
  ///
  /// [token] gates both planes (§9); defaults to a random 128-bit hex string.
  /// [leadTimeUs] is the scheduled-start lead (§5.3). [silenceTimeout],
  /// [reconnectGrace], and [livenessCheckInterval] implement §3.3 (defaults:
  /// drop after 10 s silence, 30 s reconnect grace) and are injectable so
  /// tests can exercise drops quickly. [endPolicy] is applied when the
  /// current item reaches its end (§5.5; checked at the
  /// [livenessCheckInterval] cadence, so end handling lags the exact end by
  /// up to one interval — the broadcast position still lands exactly on the
  /// duration because positions clamp to it).
  ///
  /// [uploadDir] is where guest uploads (§6.4) are stored; when null a fresh
  /// temp directory is created per server instance in [start] and deleted on
  /// [close]. [maxUploadBytes] caps one upload's size (default 512 MB;
  /// over-limit uploads are answered 413).
  JamHostServer({
    required this.sessionName,
    String? token,
    int leadTimeUs = 750_000,
    this.endPolicy = JamEndPolicy.pause,
    this.silenceTimeout = const Duration(seconds: 10),
    this.reconnectGrace = const Duration(seconds: 30),
    this.livenessCheckInterval = const Duration(seconds: 1),
    this.uploadDir,
    this.maxUploadBytes = 512 * 1024 * 1024,
  }) : token = token ?? _randomHex(16),
       sessionId = 's_${_randomHex(4)}',
       _session = HostSession(leadTimeUs: leadTimeUs);

  /// Human-readable session name, shared in the join URI and `welcome`.
  final String sessionName;

  /// Session token (128-bit hex by default) gating both planes (§9).
  final String token;

  /// Random session id sent in `welcome` (§3.1).
  final String sessionId;

  /// A peer is dropped after this much silence (§3.3, default 10 s).
  final Duration silenceTimeout;

  /// How long a dropped peer's slot stays resumable (§3.3, default 30 s).
  final Duration reconnectGrace;

  /// How often liveness is evaluated. End of media (§5.5) is checked at the
  /// same cadence.
  final Duration livenessCheckInterval;

  /// End-of-media policy (§5.5): what happens when the current item's
  /// position reaches its playlist `durationUs`.
  final JamEndPolicy endPolicy;

  /// Where guest uploads (§6.4) are stored. Null means a per-instance temp
  /// directory, created in [start] and deleted (with its contents) on
  /// [close]; a caller-supplied directory is created if missing and never
  /// deleted.
  final Directory? uploadDir;

  /// Upper bound on a single guest upload's size in bytes (§6.4).
  final int maxUploadBytes;

  final HostSession _session;
  static const MessageCodec _codec = MessageCodec();

  HttpServer? _server;
  Timer? _livenessTimer;

  /// The resolved upload directory (§6.4), set in [start].
  Directory? _uploadDir;

  /// Whether [_uploadDir] was created by this instance (and so is deleted on
  /// [close]).
  bool _ownsUploadDir = false;

  int _seq = 0;
  int _peerCounter = 0;
  int _playlistRev = 0;
  bool _closed = false;

  /// All open sockets, joined or still handshaking.
  final Set<_GuestConn> _conns = {};

  /// Joined peers by peer id.
  final Map<String, _GuestConn> _peers = {};

  /// Dropped peers eligible for resume: peerId → monotonic µs expiry (§3.3).
  final Map<String, int> _graceUntilUs = {};

  /// Media registry: mediaId → (playlist item, backing file).
  final Map<String, ({MediaItem item, File file})> _media = {};
  final List<MediaItem> _playlist = [];

  /// Artwork registry (§6.5): artworkId → (mime, backing file). Artwork ids
  /// are content-derived, so items sharing cover bytes share one entry.
  final Map<String, ({String mime, File file})> _artwork = {};

  final StreamController<JamHostEvent> _events =
      StreamController<JamHostEvent>.broadcast();

  /// Observability events (peer joined/left, media status, broadcasts).
  Stream<JamHostEvent> get events => _events.stream;

  /// The bound port. Throws [StateError] before [start].
  int get port {
    final server = _server;
    if (server == null) throw StateError('JamHostServer is not started');
    return server.port;
  }

  /// The current authoritative playback snapshot (§5.1).
  PlaybackSnapshot get snapshot => _session.snapshot;

  /// The current playlist (§6.1).
  List<MediaItem> get playlist => List.unmodifiable(_playlist);

  /// Currently joined peers.
  List<PeerInfo> get peers =>
      List.unmodifiable([for (final c in _peers.values) c.info!]);

  /// Whether every joined peer has reported `ready` for [mediaId] (§6.3).
  bool allPeersReady(String mediaId) => _session.allPeersReady(mediaId);

  /// The readiness [peerId] last reported for [mediaId] (§6.3;
  /// [MediaReadiness.none] if it never reported on that item).
  MediaReadiness peerMediaState(String peerId, String mediaId) =>
      _session.peerMediaState(peerId, mediaId);

  /// Readiness for [mediaId] across all known peers: peerId -> readiness,
  /// defaulting to [MediaReadiness.none] for peers with no report on it.
  Map<String, MediaReadiness> peerMediaStates(String mediaId) =>
      _session.peerMediaStates(mediaId);

  static String _randomHex(int bytes) {
    final rng = Random.secure();
    final sb = StringBuffer();
    for (var i = 0; i < bytes; i++) {
      sb.write(rng.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  int _nowUs() => monotonicNowUs();

  // --- Lifecycle -------------------------------------------------------------

  /// Binds one [HttpServer] serving both planes (§1). Defaults to IPv4
  /// loopback; per §9 the host must bind LAN interfaces only, never a public
  /// 0.0.0.0 — choosing the interface is the caller's job.
  Future<void> start({InternetAddress? address, int port = 0}) async {
    if (_server != null) throw StateError('JamHostServer already started');
    final configuredDir = uploadDir;
    if (configuredDir == null) {
      _uploadDir = await Directory.systemTemp.createTemp('localjam_upload_');
      _ownsUploadDir = true;
    } else {
      await configuredDir.create(recursive: true);
      _uploadDir = configuredDir;
    }
    final server = await HttpServer.bind(
      address ?? InternetAddress.loopbackIPv4,
      port,
    );
    _server = server;
    server.listen(_handleRequest, cancelOnError: false);
    _livenessTimer = Timer.periodic(
      livenessCheckInterval,
      (_) => _checkLiveness(),
    );
  }

  /// The `localjam://join?...` URI (§1 Discovery) for [iface], which should
  /// be one of the addresses this server is reachable on.
  Uri joinUriFor(InternetAddress iface) => Uri(
    scheme: 'localjam',
    host: 'join',
    queryParameters: {
      'v': '${MessageCodec.protocolVersion}',
      'host': iface.address,
      'port': '$port',
      'token': token,
      'name': sessionName,
    },
  );

  /// Stops timers, closes every guest socket and the server.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _livenessTimer?.cancel();
    for (final conn in List.of(_conns)) {
      unawaited(conn.ws.close(WebSocketStatus.goingAway));
    }
    _conns.clear();
    _peers.clear();
    await _server?.close(force: true);
    if (_ownsUploadDir) {
      try {
        await _uploadDir?.delete(recursive: true);
      } catch (_) {
        // Best-effort cleanup of the per-instance temp dir.
      }
    }
    await _events.close();
  }

  // --- HTTP routing ----------------------------------------------------------

  Future<void> _handleRequest(HttpRequest req) async {
    try {
      final path = req.uri.path;
      if (path == '/ws') {
        await _handleWsUpgrade(req);
      } else if (path == '/media') {
        await _handleUpload(req);
      } else if (path.startsWith('/media/')) {
        await _serveMedia(req);
      } else if (path.startsWith('/artwork/')) {
        await _serveArtwork(req);
      } else {
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
      }
    } catch (_) {
      try {
        await req.response.close();
      } catch (_) {}
    }
  }

  Future<void> _handleWsUpgrade(HttpRequest req) async {
    if (!WebSocketTransformer.isUpgradeRequest(req)) {
      // §1: /ws is WebSocket-only.
      req.response.statusCode = HttpStatus.upgradeRequired;
      await req.response.close();
      return;
    }
    final ws = await WebSocketTransformer.upgrade(req);
    final conn = _GuestConn(ws, nowUs: _nowUs());
    _conns.add(conn);
    ws.listen(
      (data) => _onFrame(conn, data),
      onDone: () => _dropConn(conn),
      onError: (Object _) => _dropConn(conn),
      cancelOnError: true,
    );
  }

  // --- Media plane (§1, §6.2) --------------------------------------------------

  Future<void> _serveMedia(HttpRequest req) async {
    final res = req.response;
    // §6.2: Authorization: Bearer <sessionToken> gates the media plane.
    final auth = req.headers.value(HttpHeaders.authorizationHeader);
    if (auth != 'Bearer $token') {
      res.statusCode = HttpStatus.unauthorized;
      await res.close();
      return;
    }
    if (req.method != 'GET') {
      res.statusCode = HttpStatus.methodNotAllowed;
      await res.close();
      return;
    }
    final mediaId = req.uri.path.substring('/media/'.length);
    final entry = _media[mediaId];
    if (entry == null) {
      res.statusCode = HttpStatus.notFound;
      await res.close();
      return;
    }

    final size = await entry.file.length();
    res.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    try {
      res.headers.contentType = ContentType.parse(entry.item.mime);
    } catch (_) {
      res.headers.contentType = ContentType.binary;
    }

    var start = 0;
    var end = size - 1;
    final rangeHeader = req.headers.value(HttpHeaders.rangeHeader);
    if (rangeHeader != null) {
      final range = _parseRange(rangeHeader, size);
      if (range != null && !range.satisfiable) {
        // RFC 9110 §14: unsatisfiable single range → 416 with the length.
        res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        res.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$size');
        await res.close();
        return;
      }
      if (range != null) {
        start = range.start;
        end = range.end;
        res.statusCode = HttpStatus.partialContent;
        res.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/$size',
        );
      }
      // A syntactically invalid Range header is ignored → full 200 body.
    }
    res.contentLength = end - start + 1;
    await entry.file.openRead(start, end + 1).pipe(res);
  }

  // --- Artwork plane (§6.5) ------------------------------------------------------

  /// Serves `GET /artwork/{artworkId}` (§6.5): bearer-gated like the media
  /// plane, full-body responses only (artwork is small; no Range support).
  Future<void> _serveArtwork(HttpRequest req) async {
    final res = req.response;
    final auth = req.headers.value(HttpHeaders.authorizationHeader);
    if (auth != 'Bearer $token') {
      res.statusCode = HttpStatus.unauthorized;
      await res.close();
      return;
    }
    if (req.method != 'GET') {
      res.statusCode = HttpStatus.methodNotAllowed;
      await res.close();
      return;
    }
    final artworkId = req.uri.path.substring('/artwork/'.length);
    final entry = _artwork[artworkId];
    if (entry == null) {
      res.statusCode = HttpStatus.notFound;
      await res.close();
      return;
    }
    try {
      res.headers.contentType = ContentType.parse(entry.mime);
    } catch (_) {
      res.headers.contentType = ContentType.binary;
    }
    res.contentLength = await entry.file.length();
    await entry.file.openRead().pipe(res);
  }

  /// Registers [bytes] as servable artwork (§6.5) and returns its
  /// content-derived artworkId (`a_` + first 12 hex chars of the sha256).
  /// Idempotent: re-adding the same bytes (every track of an album) returns
  /// the existing id without rewriting. The bytes are stored on disk next to
  /// uploads, so the server must be started.
  Future<String> addArtwork(Uint8List bytes, {required String mime}) async {
    final dir = _uploadDir;
    if (dir == null) throw StateError('JamHostServer is not started');
    final digest = sha256.convert(bytes).toString();
    final artworkId = 'a_${digest.substring(0, 12)}';
    if (_artwork.containsKey(artworkId)) return artworkId;
    final file = File('${dir.path}/$artworkId');
    // Temp + rename so a crash never leaves a partial under the final name.
    final tmp = File('${file.path}.part');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(file.path);
    _artwork[artworkId] = (mime: mime, file: file);
    return artworkId;
  }

  /// The backing file for [artworkId], or null if unknown — the host's own
  /// UI reads artwork from here instead of fetching over HTTP.
  File? artworkFile(String artworkId) => _artwork[artworkId]?.file;

  // --- Guest uploads (§6.4) ------------------------------------------------------

  /// Handles `POST /media`: streams the raw body to disk while hashing
  /// incrementally (never buffering the file in memory), derives the mediaId
  /// from the host-computed sha256 exactly like [describeFile], registers the
  /// item via [addMedia], and answers 201 with the MediaItem JSON — or 200
  /// with the existing item when the content was already uploaded
  /// (idempotency, §6.4).
  Future<void> _handleUpload(HttpRequest req) async {
    final res = req.response;
    // §6.4/§9: Authorization: Bearer <sessionToken> gates uploads too.
    final auth = req.headers.value(HttpHeaders.authorizationHeader);
    if (auth != 'Bearer $token') {
      res.statusCode = HttpStatus.unauthorized;
      await res.close();
      return;
    }
    if (req.method != 'POST') {
      res.statusCode = HttpStatus.methodNotAllowed;
      await res.close();
      return;
    }

    final MediaKind kind;
    try {
      kind = MediaKind.fromWire(req.headers.value('X-LocalJam-Kind') ?? '');
    } on FormatException {
      res.statusCode = HttpStatus.badRequest;
      await res.close();
      return;
    }
    final String? rawName = req.headers.value('X-LocalJam-Name');
    final String name;
    try {
      // §6.4: the name header is percent-encoded UTF-8.
      name = rawName == null ? 'upload' : Uri.decodeComponent(rawName);
    } on ArgumentError {
      res.statusCode = HttpStatus.badRequest;
      await res.close();
      return;
    }
    final mime =
        req.headers.value('X-LocalJam-Mime') ?? 'application/octet-stream';
    final durationUs = int.tryParse(
      req.headers.value('X-LocalJam-Duration-Us') ?? '',
    );
    final peerId = req.headers.value('X-LocalJam-Peer-Id');

    // §6.4: a declared over-limit size is rejected without reading the body.
    if (req.contentLength > maxUploadBytes) {
      res.persistentConnection = false;
      res.statusCode = HttpStatus.requestEntityTooLarge;
      await res.close();
      return;
    }

    final dir = _uploadDir!;
    final tmp = File('${dir.path}/incoming_${_randomHex(8)}.part');
    final digestSink = _DigestSink();
    final hasher = sha256.startChunkedConversion(digestSink);
    final sink = tmp.openWrite();
    var received = 0;
    var overLimit = false;
    try {
      // Stream to disk while hashing — the file is never held in memory.
      await for (final chunk in req) {
        received += chunk.length;
        if (received > maxUploadBytes) {
          overLimit = true;
          break;
        }
        hasher.add(chunk);
        sink.add(chunk);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    hasher.close();

    if (overLimit) {
      try {
        await tmp.delete();
      } catch (_) {}
      res.persistentConnection = false;
      res.statusCode = HttpStatus.requestEntityTooLarge;
      await res.close();
      return;
    }

    final digest = digestSink.value!.toString();
    final mediaId = 'm_${digest.substring(0, 12)}';

    final existing = _media[mediaId];
    if (existing != null) {
      // §6.4 idempotency: the mediaId is content-derived, so an existing id
      // means the same bytes — answer 200 with the existing item, keep its
      // original metadata, and broadcast nothing.
      try {
        await tmp.delete();
      } catch (_) {}
      res.statusCode = HttpStatus.ok;
      res.headers.contentType = ContentType.json;
      res.write(jsonEncode(existing.item.toJson()));
      await res.close();
      return;
    }

    final stored = await tmp.rename('${dir.path}/$mediaId');
    // §6.1/§6.5: the host extracts tags + artwork itself — one implementation
    // for uploads and host files, and guests never need a tag parser. The
    // uploader's declared duration wins over the tag value (a decoder probe
    // beats a tag claim); everything is best-effort.
    var tags = const JamAudioTags();
    String? artworkId;
    if (kind == MediaKind.audio) {
      tags = await readAudioTags(stored);
      final artworkBytes = tags.artworkBytes;
      if (tags.hasArtwork) {
        artworkId = await addArtwork(artworkBytes!, mime: tags.artworkMime!);
      }
    }
    final item = MediaItem(
      mediaId: mediaId,
      kind: kind,
      name: name,
      mime: mime,
      sizeBytes: received,
      durationUs: durationUs ?? tags.durationUs,
      sha256: digest,
      title: tags.title,
      artist: tags.artist,
      album: tags.album,
      artworkId: artworkId,
    );
    // §6.4: the upload event first, then addMedia's playlist broadcast
    // (which also threads durationUs into the session per §5.5).
    _emit(
      JamHostEvent._(
        JamHostEventKind.mediaUploaded,
        peerId: peerId,
        mediaId: mediaId,
      ),
    );
    addMedia(item, stored);

    res.statusCode = HttpStatus.created;
    res.headers.contentType = ContentType.json;
    res.write(jsonEncode(item.toJson()));
    await res.close();
  }

  /// Parses a single-range `Range` header against a resource of [size] bytes.
  ///
  /// Returns null for a malformed header (caller serves the full body per
  /// RFC 9110), a record with `satisfiable: false` for a well-formed but
  /// unsatisfiable range (caller answers 416), or the resolved byte range.
  static ({int start, int end, bool satisfiable})? _parseRange(
    String header,
    int size,
  ) {
    final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(header.trim());
    if (match == null) return null;
    final rawStart = match.group(1)!;
    final rawEnd = match.group(2)!;
    if (rawStart.isEmpty && rawEnd.isEmpty) return null;
    const unsatisfiable = (start: 0, end: 0, satisfiable: false);
    if (rawStart.isEmpty) {
      // Suffix range: last <rawEnd> bytes.
      final suffix = int.parse(rawEnd);
      if (suffix == 0 || size == 0) return unsatisfiable;
      return (start: max(0, size - suffix), end: size - 1, satisfiable: true);
    }
    final start = int.parse(rawStart);
    final end = rawEnd.isEmpty ? size - 1 : min(int.parse(rawEnd), size - 1);
    if (start >= size || start > end) return unsatisfiable;
    return (start: start, end: end, satisfiable: true);
  }

  // --- Control plane (§3–§6) ---------------------------------------------------

  void _onFrame(_GuestConn conn, Object? data) {
    final receivedUs = _nowUs();
    conn.lastFrameUs = receivedUs;
    if (data is! String) return; // v1 control frames are JSON text (§1).

    final DecodedMessage decoded;
    try {
      decoded = _codec.decode(data);
    } on ProtocolException {
      return; // Malformed frame: log-and-ignore territory.
    }

    final message = decoded.message;
    if (!conn.joined) {
      if (message is HelloMessage) _onHello(conn, message);
      return; // Anything else before hello is ignored.
    }
    switch (message) {
      case ClockPingMessage(:final t0):
        // §4: t1 = host receive, t2 = host send, both session-clock µs.
        _sendTo(
          conn.ws,
          ClockPongMessage(t0: t0, t1: receivedUs, t2: _nowUs()),
        );
      case RequestMessage():
        _onRequest(conn, message);
      case MediaStatusMessage():
        _onMediaStatus(conn, message);
      case HelloMessage():
        break; // Already joined; ignore duplicate hello.
      default:
        break; // Unknown/unexpected types are ignored (§2).
    }
  }

  void _onHello(_GuestConn conn, HelloMessage hello) {
    if (hello.token != token) {
      _sendTo(conn.ws, const RejectMessage(reason: RejectReason.badToken));
      unawaited(conn.ws.close(WebSocketStatus.policyViolation));
      return;
    }

    // §3.3 reconnect: same token + peerId within the grace window resumes
    // the slot.
    String peerId;
    final resumeId = hello.resumePeerId;
    final graceExpiry = resumeId == null ? null : _graceUntilUs[resumeId];
    if (resumeId != null &&
        graceExpiry != null &&
        graceExpiry >= _nowUs() &&
        !_peers.containsKey(resumeId)) {
      peerId = resumeId;
      _graceUntilUs.remove(resumeId);
    } else {
      peerId = 'p_${++_peerCounter}';
    }

    final info = PeerInfo(
      peerId: peerId,
      clientName: hello.clientName,
      clientKind: hello.clientKind,
    );
    conn.peerId = peerId;
    conn.info = info;
    _peers[peerId] = conn;
    _session.upsertPeer(peerId);

    // §3.1: welcome carries the full snapshot + playlist + existing peers.
    _sendTo(
      conn.ws,
      WelcomeMessage(
        sessionId: sessionId,
        sessionName: sessionName,
        selfPeerId: peerId,
        peers: [
          for (final other in _peers.values)
            if (other != conn) other.info!,
        ],
        snapshot: _session.snapshot,
        playlist: playlist,
      ),
    );
    // §3.2: announce to everyone else.
    _broadcast(PeerJoinedMessage(peer: info), except: conn);
    _emit(JamHostEvent._(JamHostEventKind.peerJoined, peer: info));
  }

  void _onRequest(_GuestConn conn, RequestMessage request) {
    // §5.2: guests never mutate state; the host applies their requests.
    try {
      switch (request.action) {
        case RequestAction.play:
          play();
        case RequestAction.pause:
          pause();
        case RequestAction.seek:
          final positionUs = request.positionUs;
          if (positionUs != null) seek(positionUs);
        case RequestAction.setMedia:
          final mediaId = request.mediaId;
          if (mediaId != null) setMedia(mediaId);
      }
    } on StateError catch (e) {
      _sendTo(
        conn.ws,
        ErrorMessage(code: ErrorCode.internal, message: e.message),
      );
    } on ArgumentError catch (e) {
      _sendTo(
        conn.ws,
        ErrorMessage(code: ErrorCode.mediaGone, message: '${e.message}'),
      );
    }
  }

  void _onMediaStatus(_GuestConn conn, MediaStatusMessage status) {
    // §6.3: track readiness in the session state machine.
    final readiness = switch (status.state) {
      MediaFetchState.none => MediaReadiness.none,
      MediaFetchState.fetching => MediaReadiness.fetching,
      MediaFetchState.ready => MediaReadiness.ready,
    };
    _session.setPeerMediaState(conn.peerId!, status.mediaId, readiness);
    _emit(
      JamHostEvent._(
        JamHostEventKind.peerMediaStatus,
        peerId: conn.peerId,
        mediaId: status.mediaId,
        mediaState: status.state,
        progress: status.progress,
      ),
    );
  }

  // --- Host-initiated controls (§5) --------------------------------------------

  /// Selects [mediaId] and broadcasts the new state (§5.1). The item's
  /// playlist `durationUs` (when set) is threaded into the session so seeks
  /// clamp to it and end of media is detectable (§5.5).
  ///
  /// Throws [ArgumentError] if [mediaId] is not in the media registry.
  void setMedia(String mediaId) {
    final entry = _media[mediaId];
    if (entry == null) {
      throw ArgumentError.value(mediaId, 'mediaId', 'unknown media id');
    }
    _apply(
      (now) => _session.setMedia(
        mediaId,
        nowUs: now,
        durationUs: entry.item.durationUs,
      ),
    );
  }

  /// Starts (or resumes) playback with a scheduled anchor (§5.3).
  void play() => _apply((now) => _session.play(nowUs: now));

  /// Pauses playback, freezing the position (§5.1).
  void pause() => _apply((now) => _session.pause(nowUs: now));

  /// Seeks to [positionUs] (§5.1/§5.3), clamped to the current item's
  /// duration when known (§5.5).
  void seek(int positionUs) =>
      _apply((now) => _session.seek(positionUs, nowUs: now));

  /// Stops playback: back to idle with no media selected (§5.5).
  void stop() => _apply((now) => _session.stop(nowUs: now));

  void _apply(PlaybackSnapshot Function(int nowUs) mutate) {
    final before = _session.snapshot.rev;
    final after = mutate(_nowUs());
    if (after.rev == before) return; // No-op: suppress redundant broadcast.
    _broadcast(StateMessage(snapshot: after));
    _emit(JamHostEvent._(JamHostEventKind.stateBroadcast, snapshot: after));
  }

  // --- Media registry (§6.1) -----------------------------------------------------

  /// Registers (or replaces) a playlist item backed by [file] and broadcasts
  /// the updated playlist (§6.1). The caller precomputes [item] — see
  /// [describeFile].
  void addMedia(MediaItem item, File file) {
    _media[item.mediaId] = (item: item, file: file);
    final index = _playlist.indexWhere((i) => i.mediaId == item.mediaId);
    if (index >= 0) {
      _playlist[index] = item;
    } else {
      _playlist.add(item);
    }
    _playlistRev++;
    _broadcast(PlaylistMessage(rev: _playlistRev, items: playlist));
    _emit(
      JamHostEvent._(JamHostEventKind.playlistBroadcast, playlist: playlist),
    );
  }

  /// Builds a [MediaItem] for [file]: computes [MediaItem.sizeBytes] and the
  /// streaming sha256 digest (§6.1). [mediaId] defaults to `m_` + the first
  /// 12 hex chars of the digest (stable across sessions, which is what makes
  /// guest-side caching by sha256 work); [name] defaults to the file name.
  ///
  /// This never probes the file for its duration — duration extraction is
  /// platform-dependent (afinfo, ffprobe, the app's audio engine), so callers
  /// SHOULD supply [durationUs] for audio items (§5.5): without it the host
  /// cannot detect end of media and no [JamEndPolicy] fires.
  static Future<MediaItem> describeFile(
    File file, {
    required MediaKind kind,
    String? mediaId,
    String? name,
    String mime = 'application/octet-stream',
    int? durationUs,
    String? title,
    String? artist,
    String? album,
    String? artworkId,
  }) async {
    final size = await file.length();
    final digest = (await sha256.bind(file.openRead()).first).toString();
    return MediaItem(
      mediaId: mediaId ?? 'm_${digest.substring(0, 12)}',
      kind: kind,
      name: name ?? Uri.file(file.path).pathSegments.last,
      mime: mime,
      sizeBytes: size,
      durationUs: durationUs,
      sha256: digest,
      title: title,
      artist: artist,
      album: album,
      artworkId: artworkId,
    );
  }

  // --- Liveness (§3.3) -----------------------------------------------------------

  void _checkLiveness() {
    final now = _nowUs();
    final silenceUs = silenceTimeout.inMicroseconds;
    for (final conn in List.of(_conns)) {
      if (now - conn.lastFrameUs > silenceUs) _dropConn(conn);
    }
    _graceUntilUs.removeWhere((_, expiry) => expiry < now);
    _checkEndOfMedia(now);
  }

  // --- End of media (§5.5) ---------------------------------------------------

  /// Set once the current track end has been handled; reset as soon as the
  /// session is observed not-ended (new track, seek back, stop). Guards the
  /// periodic check so [JamHostEventKind.mediaEnded] and the policy fire
  /// exactly once per track end.
  bool _endHandled = false;

  void _checkEndOfMedia(int now) {
    if (!_session.hasEnded(now)) {
      _endHandled = false;
      return;
    }
    if (_endHandled) return;
    _endHandled = true;

    final endedId = _session.snapshot.mediaId;
    // §5.5: the end event first, then the policy's resulting state broadcast.
    _emit(JamHostEvent._(JamHostEventKind.mediaEnded, mediaId: endedId));
    switch (endPolicy) {
      case JamEndPolicy.pause:
        pause(); // Positions clamp to the duration: freezes exactly at it.
      case JamEndPolicy.advance:
        final next = _nextMediaId(endedId);
        if (next == null) {
          pause(); // Empty playlist: nothing to advance to.
        } else {
          setMedia(next);
          play();
        }
      case JamEndPolicy.stop:
        stop();
    }
  }

  /// The playlist item after [current], wrapping; null if the playlist is
  /// empty. An unknown [current] yields the first item.
  String? _nextMediaId(String? current) {
    if (_playlist.isEmpty) return null;
    final index = _playlist.indexWhere((i) => i.mediaId == current);
    return _playlist[(index + 1) % _playlist.length].mediaId;
  }

  /// Disconnects [peerId] (host moderation): closes its socket with
  /// `goingAway` and broadcasts `peer_left` (§3.2).
  ///
  /// With [allowResume] (the default) the peer keeps a §3.3 grace slot
  /// exactly like a silence drop, so a reconnecting guest reclaims the same
  /// peerId. With `allowResume: false` no grace slot is kept: a reconnect
  /// carrying the old `resumePeerId` silently falls back to a fresh join.
  ///
  /// Throws [ArgumentError] if [peerId] is not a currently joined peer.
  void kickPeer(String peerId, {bool allowResume = true}) {
    final conn = _peers[peerId];
    if (conn == null) {
      throw ArgumentError.value(peerId, 'peerId', 'not a joined peer');
    }
    _dropConn(conn, allowResume: allowResume);
  }

  void _dropConn(_GuestConn conn, {bool allowResume = true}) {
    if (!_conns.remove(conn)) return; // Already dropped.
    unawaited(conn.ws.close(WebSocketStatus.goingAway).catchError((_) {}));
    final peerId = conn.peerId;
    if (peerId == null || _closed) return;
    _peers.remove(peerId);
    _session.removePeer(peerId);
    if (allowResume) {
      // §3.3: keep a grace slot so the guest can resume with the same peerId.
      _graceUntilUs[peerId] = _nowUs() + reconnectGrace.inMicroseconds;
    }
    _broadcast(PeerLeftMessage(peerId: peerId));
    _emit(JamHostEvent._(JamHostEventKind.peerLeft, peerId: peerId));
  }

  // --- Wire helpers ----------------------------------------------------------------

  void _sendTo(WebSocket ws, Message message) {
    _safeAdd(ws, _codec.encode(message, seq: _seq++));
  }

  void _broadcast(Message message, {_GuestConn? except}) {
    final encoded = _codec.encode(message, seq: _seq++);
    for (final conn in _peers.values) {
      if (conn == except) continue;
      _safeAdd(conn.ws, encoded);
    }
  }

  /// Adds a frame, swallowing the race where the socket's close handshake
  /// began between frame receipt and the reply (liveness will reap the conn).
  static void _safeAdd(WebSocket ws, String frame) {
    if (ws.readyState != WebSocket.open) return;
    try {
      ws.add(frame);
    } on StateError {
      // Sink closed underneath us: the peer is going away.
    }
  }

  void _emit(JamHostEvent event) {
    if (!_events.isClosed) _events.add(event);
  }
}

/// Terminal sink for one chunked sha256 conversion (avoids a package:convert
/// dependency for `AccumulatorSink`).
class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
