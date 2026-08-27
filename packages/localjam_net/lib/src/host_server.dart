/// LocalJam host: serves the control plane (WebSocket `/ws`) and the media
/// plane (HTTP `/media/{mediaId}`) on one TCP port (PROTOCOL.md §1), and
/// drives a [HostSession] as the single authoritative state writer (§5).
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:localjam_core/localjam_core.dart';
import 'package:meta/meta.dart';

import 'monotonic.dart';

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
  /// tests can exercise drops quickly.
  JamHostServer({
    required this.sessionName,
    String? token,
    int leadTimeUs = 750_000,
    this.silenceTimeout = const Duration(seconds: 10),
    this.reconnectGrace = const Duration(seconds: 30),
    this.livenessCheckInterval = const Duration(seconds: 1),
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

  /// How often liveness is evaluated.
  final Duration livenessCheckInterval;

  final HostSession _session;
  static const MessageCodec _codec = MessageCodec();

  HttpServer? _server;
  Timer? _livenessTimer;
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
    await _events.close();
  }

  // --- HTTP routing ----------------------------------------------------------

  Future<void> _handleRequest(HttpRequest req) async {
    try {
      final path = req.uri.path;
      if (path == '/ws') {
        await _handleWsUpgrade(req);
      } else if (path.startsWith('/media/')) {
        await _serveMedia(req);
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

  /// Selects [mediaId] and broadcasts the new state (§5.1).
  ///
  /// Throws [ArgumentError] if [mediaId] is not in the media registry.
  void setMedia(String mediaId) {
    if (!_media.containsKey(mediaId)) {
      throw ArgumentError.value(mediaId, 'mediaId', 'unknown media id');
    }
    _apply((now) => _session.setMedia(mediaId, nowUs: now));
  }

  /// Starts (or resumes) playback with a scheduled anchor (§5.3).
  void play() => _apply((now) => _session.play(nowUs: now));

  /// Pauses playback, freezing the position (§5.1).
  void pause() => _apply((now) => _session.pause(nowUs: now));

  /// Seeks to [positionUs] (§5.1/§5.3).
  void seek(int positionUs) =>
      _apply((now) => _session.seek(positionUs, nowUs: now));

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
  static Future<MediaItem> describeFile(
    File file, {
    required MediaKind kind,
    String? mediaId,
    String? name,
    String mime = 'application/octet-stream',
    int? durationUs,
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
  }

  void _dropConn(_GuestConn conn) {
    if (!_conns.remove(conn)) return; // Already dropped.
    unawaited(conn.ws.close(WebSocketStatus.goingAway).catchError((_) {}));
    final peerId = conn.peerId;
    if (peerId == null || _closed) return;
    _peers.remove(peerId);
    _session.removePeer(peerId);
    // §3.3: keep a grace slot so the guest can resume with the same peerId.
    _graceUntilUs[peerId] = _nowUs() + reconnectGrace.inMicroseconds;
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
