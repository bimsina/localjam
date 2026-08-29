/// LocalJam guest: joins a host over the WebSocket control plane, runs the
/// clock-sync schedule (PROTOCOL.md §4), mirrors the authoritative playback
/// state and playlist (§5, §6), and fetches media over the HTTP plane (§6.2).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:localjam_core/localjam_core.dart';
import 'package:meta/meta.dart';

import 'monotonic.dart';

/// Thrown when the host answers the join handshake with `reject` (§3.1).
class JamRejectedException implements Exception {
  const JamRejectedException(this.reason);

  /// Why the host rejected the join.
  final RejectReason reason;

  @override
  String toString() => 'JamRejectedException(${reason.wire})';
}

/// Kind of a [JamPeerEvent].
enum JamPeerEventKind { joined, left }

/// A presence change observed by this guest (§3.2).
@immutable
class JamPeerEvent {
  const JamPeerEvent._(this.kind, this.peerId, [this.peer]);

  final JamPeerEventKind kind;
  final String peerId;

  /// Set for [JamPeerEventKind.joined].
  final PeerInfo? peer;

  @override
  String toString() => 'JamPeerEvent(${kind.name}, $peerId)';
}

/// A LocalJam guest connected to one host session.
///
/// Created via [connect]. The guest's local clock is a process-wide monotonic
/// microsecond clock (§4); [clock] maps it onto the host's session clock.
class JamGuestClient {
  JamGuestClient._(
    this._ws,
    this._host,
    this._port,
    this._token,
    this._pingInterval,
  ) {
    _sub = _ws.listen(
      _onFrame,
      onDone: _onSocketDone,
      onError: (Object _) => _onSocketDone(),
      cancelOnError: true,
    );
  }

  /// Parses a `localjam://join?...` URI (§1 Discovery), tries each `host`
  /// candidate in order, performs the §3.1 handshake, and starts the §4
  /// clock-sync schedule (burst of 8 pings, then one every [pingInterval]).
  ///
  /// Pass [resumePeerId] to resume a dropped slot within the host's grace
  /// window (§3.3); it is carried in the `hello` payload.
  ///
  /// Throws [JamRejectedException] if the host rejects the join, or
  /// [SocketException] if no candidate host is reachable.
  static Future<JamGuestClient> connect(
    Uri joinUri, {
    String clientName = 'guest',
    String clientKind = 'dart',
    List<String> caps = const ['audio'],
    Duration pingInterval = const Duration(seconds: 2),
    Duration connectTimeout = const Duration(seconds: 5),
    String? resumePeerId,
  }) async {
    final params = joinUri.queryParameters;
    final hostsParam = params['host'];
    final portParam = params['port'];
    final token = params['token'];
    if (hostsParam == null || portParam == null || token == null) {
      throw FormatException('Join URI is missing host/port/token: $joinUri');
    }
    final port = int.parse(portParam);
    final hosts = [
      for (final h in hostsParam.split(','))
        if (h.trim().isNotEmpty) h.trim(),
    ];
    if (hosts.isEmpty) {
      throw FormatException('Join URI has no host candidates: $joinUri');
    }

    Object? lastError;
    for (final host in hosts) {
      final wsUri = Uri(scheme: 'ws', host: host, port: port, path: '/ws');
      final WebSocket ws;
      try {
        ws = await WebSocket.connect('$wsUri').timeout(connectTimeout);
      } catch (e) {
        lastError = e; // Try the next candidate (§1: guests try in order).
        continue;
      }
      final client = JamGuestClient._(ws, host, port, token, pingInterval);
      try {
        await client._handshake(
          clientName: clientName,
          clientKind: clientKind,
          caps: caps,
          timeout: connectTimeout,
          resumePeerId: resumePeerId,
        );
        return client;
      } on JamRejectedException {
        await client.close();
        rethrow; // A reject is authoritative; other candidates are the same host.
      } catch (e) {
        await client.close();
        lastError = e;
      }
    }
    throw SocketException(
      'Could not join via any host candidate $hosts: $lastError',
    );
  }

  static const MessageCodec _codec = MessageCodec();

  final WebSocket _ws;
  final String _host;
  final int _port;
  final String _token;
  final Duration _pingInterval;
  final HttpClient _http = HttpClient();

  late final StreamSubscription<Object?> _sub;
  final Completer<void> _done = Completer<void>();
  Completer<Message>? _handshakeCompleter;
  Timer? _pingTimer;
  int _seq = 0;
  bool _closed = false;

  final ClockSync _clock = ClockSync();
  PlaybackSnapshot _snapshot = PlaybackSnapshot.initial;
  List<MediaItem> _playlist = const [];
  final Map<String, PeerInfo> _peers = {};

  /// Until a v0.2 host says otherwise, assume nothing is allowed (§5.6).
  JamPermissions _permissions = const JamPermissions.initial(
    policy: JamPolicy.listenOnly,
  );
  ErrorMessage? _lastFatalError;

  final StreamController<PlaybackSnapshot> _states =
      StreamController<PlaybackSnapshot>.broadcast();
  final StreamController<List<MediaItem>> _playlists =
      StreamController<List<MediaItem>>.broadcast();
  final StreamController<JamPeerEvent> _peerEvents =
      StreamController<JamPeerEvent>.broadcast();
  final StreamController<JamPermissions> _permissionUpdates =
      StreamController<JamPermissions>.broadcast();
  final StreamController<ErrorMessage> _errors =
      StreamController<ErrorMessage>.broadcast();

  late final String _selfPeerId;
  late final String _sessionId;
  late final String _sessionName;

  /// This guest's peer id as assigned by the host (§3.1).
  String get selfPeerId => _selfPeerId;

  /// The session id from `welcome` (§3.1).
  String get sessionId => _sessionId;

  /// The session name from `welcome` (§3.1).
  String get sessionName => _sessionName;

  /// The most recent authoritative playback snapshot (§5.1). Starts at the
  /// `welcome` snapshot, so late join is just convergence.
  PlaybackSnapshot get snapshot => _snapshot;

  /// Every authoritative state broadcast after the handshake (§5.1).
  Stream<PlaybackSnapshot> get states => _states.stream;

  /// The current playlist (§6.1).
  List<MediaItem> get playlist => List.unmodifiable(_playlist);

  /// Playlist broadcasts after the handshake (§6.1).
  Stream<List<MediaItem>> get playlistUpdates => _playlists.stream;

  /// The clock-offset estimator fed by this client's ping schedule (§4).
  ClockSync get clock => _clock;

  /// Other peers currently in the session (excluding this guest).
  List<PeerInfo> get peers => List.unmodifiable(_peers.values);

  /// Presence changes (§3.2).
  Stream<JamPeerEvent> get peerEvents => _peerEvents.stream;

  /// The room's permission document (§5.6): from `welcome`, then every
  /// `permissions` broadcast. Listen-only until a v0.2 host says otherwise.
  JamPermissions get permissions => _permissions;

  /// Permission-document broadcasts after the handshake (§5.6).
  Stream<JamPermissions> get permissionUpdates => _permissionUpdates.stream;

  /// This guest's own effective capabilities under [permissions] — what a
  /// UI enables/disables. The host re-validates every request regardless.
  Set<JamCapability> get myCapabilities =>
      _permissions.capabilitiesOf(_selfPeerId);

  /// Host error reports (§8), both transient (`not_allowed`, `media_gone`)
  /// and fatal.
  Stream<ErrorMessage> get errors => _errors.stream;

  /// The fatal error that ended (or is about to end) this connection, if
  /// any — e.g. `kicked` (§5.6), which reconnect layers must treat as
  /// terminal instead of retrying.
  ErrorMessage? get lastFatalError => _lastFatalError;

  /// Completes when the WebSocket to the host closes for any reason — host
  /// shutdown, a drop, or a local [close]. Completes exactly once and never
  /// errors.
  Future<void> get done => _done.future;

  /// This guest's local monotonic clock (µs, arbitrary epoch) — the `t0`/`t3`
  /// timebase of §4 and the input side of [clock].
  int get localNowUs => monotonicNowUs();

  /// The current session-clock time (host monotonic µs), i.e.
  /// `clock.localToHostUs(localNowUs)`.
  ///
  /// Throws [StateError] before [ClockSync.isSynchronized].
  int get sessionNowUs => _clock.localToHostUs(monotonicNowUs());

  // --- Handshake (§3.1) --------------------------------------------------------

  Future<void> _handshake({
    required String clientName,
    required String clientKind,
    required List<String> caps,
    required Duration timeout,
    String? resumePeerId,
  }) async {
    final completer = Completer<Message>();
    _handshakeCompleter = completer;
    _send(
      HelloMessage(
        token: _token,
        clientName: clientName,
        clientKind: clientKind,
        caps: caps,
        resumePeerId: resumePeerId,
      ),
    );
    final reply = await completer.future.timeout(timeout);
    _handshakeCompleter = null;
    switch (reply) {
      case WelcomeMessage():
        _selfPeerId = reply.selfPeerId;
        _sessionId = reply.sessionId;
        _sessionName = reply.sessionName;
        _snapshot = reply.snapshot;
        _playlist = reply.playlist;
        final permissions = reply.permissions;
        if (permissions != null) _permissions = permissions;
        for (final peer in reply.peers) {
          _peers[peer.peerId] = peer;
        }
        _startClockSchedule();
      case RejectMessage(:final reason):
        throw JamRejectedException(reason);
      default:
        throw StateError('Unexpected handshake reply: ${reply.type}');
    }
  }

  // --- Clock schedule (§4) -------------------------------------------------------

  void _startClockSchedule() {
    // Burst of 8 pings at join; the estimator keeps the min-RTT sample.
    for (var i = 0; i < 8; i++) {
      _sendPing();
    }
    // Steady state: one ping every 2 s (also our liveness heartbeat, §3.3).
    _pingTimer = Timer.periodic(_pingInterval, (_) => _sendPing());
  }

  void _sendPing() {
    if (_closed) return;
    _send(ClockPingMessage(t0: monotonicNowUs()));
  }

  // --- Incoming frames -------------------------------------------------------------

  void _onFrame(Object? data) {
    final t3 = monotonicNowUs(); // §4: t3 = local receive time.
    if (data is! String) return;
    final DecodedMessage decoded;
    try {
      decoded = _codec.decode(data);
    } on ProtocolException {
      return; // Malformed frame: ignore.
    }
    final message = decoded.message;

    final handshake = _handshakeCompleter;
    if (handshake != null &&
        (message is WelcomeMessage || message is RejectMessage)) {
      if (!handshake.isCompleted) handshake.complete(message);
      return;
    }

    switch (message) {
      case ClockPongMessage(:final t0, :final t1, :final t2):
        _clock.addSample(ClockSample(t0: t0, t1: t1, t2: t2, t3: t3));
      case StateMessage(:final snapshot):
        _snapshot = snapshot;
        if (!_states.isClosed) _states.add(snapshot);
      case PlaylistMessage(:final items):
        _playlist = items;
        if (!_playlists.isClosed) _playlists.add(playlist);
      case PeerJoinedMessage(:final peer):
        _peers[peer.peerId] = peer;
        if (!_peerEvents.isClosed) {
          _peerEvents.add(
            JamPeerEvent._(JamPeerEventKind.joined, peer.peerId, peer),
          );
        }
      case PeerLeftMessage(:final peerId):
        _peers.remove(peerId);
        if (!_peerEvents.isClosed) {
          _peerEvents.add(JamPeerEvent._(JamPeerEventKind.left, peerId));
        }
      case PermissionsMessage(:final permissions):
        // §5.6: keep the highest rev (broadcasts can race a resume welcome).
        if (permissions.rev >= _permissions.rev) {
          _permissions = permissions;
          if (!_permissionUpdates.isClosed) {
            _permissionUpdates.add(permissions);
          }
        }
      case ErrorMessage():
        // §8: fatal errors are followed by a host-side close; remember the
        // reason so reconnect layers can tell a kick from a plain drop.
        if (message.fatal) _lastFatalError = message;
        if (!_errors.isClosed) _errors.add(message);
      default:
        break; // unknown: ignored (§2).
    }
  }

  void _onSocketDone() {
    final handshake = _handshakeCompleter;
    if (handshake != null && !handshake.isCompleted) {
      handshake.completeError(
        const SocketException('Connection closed during handshake'),
      );
    }
    if (!_done.isCompleted) _done.complete();
    unawaited(close());
  }

  // --- Requests (§5.2) ----------------------------------------------------------

  /// Asks the host to start playback (§5.2).
  Future<void> requestPlay() async =>
      _send(const RequestMessage(action: RequestAction.play));

  /// Asks the host to pause playback (§5.2).
  Future<void> requestPause() async =>
      _send(const RequestMessage(action: RequestAction.pause));

  /// Asks the host to seek to [positionUs] (§5.2).
  Future<void> requestSeek(int positionUs) async =>
      _send(RequestMessage(action: RequestAction.seek, positionUs: positionUs));

  /// Asks the host to select [mediaId] (§5.2).
  Future<void> requestSetMedia(String mediaId) async =>
      _send(RequestMessage(action: RequestAction.setMedia, mediaId: mediaId));

  /// Asks the host to skip to the next queue item (§5.2).
  Future<void> requestNext() async =>
      _send(const RequestMessage(action: RequestAction.next));

  /// Asks the host to skip to the previous queue item (§5.2).
  Future<void> requestPrevious() async =>
      _send(const RequestMessage(action: RequestAction.previous));

  /// Asks the host to move [mediaId] to queue position [toIndex] (§5.6).
  Future<void> requestQueueMove(String mediaId, int toIndex) async => _send(
    RequestMessage(
      action: RequestAction.queueMove,
      mediaId: mediaId,
      toIndex: toIndex,
    ),
  );

  /// Asks the host to remove [mediaId] from the queue (§5.6). Removing your
  /// own contribution is always allowed; others' need
  /// [JamCapability.editQueue].
  Future<void> requestQueueRemove(String mediaId) async => _send(
    RequestMessage(action: RequestAction.queueRemove, mediaId: mediaId),
  );

  // --- Media plane (§6.2, §6.3) ----------------------------------------------------

  /// Sends a §6.3 `media_status` report directly, without an in-flight
  /// fetch — e.g. a cache hit, where the guest already possesses the file
  /// and never touches the network for it. [fetchMediaToFile]/[fetchMedia]
  /// send their own reports as a fetch progresses; this is the public door
  /// for callers (the prefetch pipeline) that resolve readiness some other
  /// way.
  ///
  /// Permissive by design: [mediaId] need not be in the current playlist
  /// (mirrors the wire protocol itself, which carries no such constraint —
  /// the host just records readiness per (peer, mediaId) and a report for
  /// an id it doesn't yet know about is simply inert until that id shows up
  /// in a playlist). Silently dropped if the socket isn't open, exactly like
  /// every other outgoing message on this client (see [_send]) — a report
  /// that arrives too late to matter is not worth surfacing as an error.
  void sendMediaStatus(
    String mediaId,
    MediaFetchState state, {
    double? progress,
  }) {
    _send(
      MediaStatusMessage(mediaId: mediaId, state: state, progress: progress),
    );
  }

  /// Fetches `GET /media/{mediaId}` with Bearer auth (§6.2), streaming the
  /// body straight to [destination] while hashing incrementally — the file is
  /// never held in memory. Reports `media_status` upstream (§6.3): `fetching`
  /// with progress while downloading, `ready` once the sha256 digest matches
  /// the playlist entry.
  ///
  /// [onProgress] receives values in [0, 1]. Returns [destination]. Throws
  /// [ArgumentError] if [mediaId] is not in the current playlist,
  /// [HttpException] on a non-200 response, and [StateError] on a digest
  /// mismatch — after deleting the partial [destination] and reporting
  /// `media_status: none`.
  Future<File> fetchMediaToFile(
    String mediaId,
    File destination, {
    void Function(double progress)? onProgress,
  }) async {
    final item = _playlist.firstWhere(
      (i) => i.mediaId == mediaId,
      orElse: () => throw ArgumentError.value(
        mediaId,
        'mediaId',
        'not in the current playlist',
      ),
    );
    final uri = Uri(
      scheme: 'http',
      host: _host,
      port: _port,
      path: '/media/$mediaId',
    );
    final request = await _http.getUrl(uri);
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_token');
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      throw HttpException(
        'GET $uri failed with ${response.statusCode}',
        uri: uri,
      );
    }

    _send(
      MediaStatusMessage(
        mediaId: mediaId,
        state: MediaFetchState.fetching,
        progress: 0,
      ),
    );
    final total = item.sizeBytes > 0 ? item.sizeBytes : response.contentLength;
    final digestSink = _DigestSink();
    final hasher = sha256.startChunkedConversion(digestSink);
    await destination.parent.create(recursive: true);
    final sink = destination.openWrite();
    var received = 0;
    var lastReported = 0.0;
    try {
      await for (final chunk in response) {
        hasher.add(chunk);
        sink.add(chunk);
        received += chunk.length;
        final progress = total > 0 ? (received / total).clamp(0.0, 1.0) : 0.0;
        onProgress?.call(progress);
        // Throttle upstream progress reports to quarter steps (§6.3 is for
        // host UX, not telemetry).
        if (progress - lastReported >= 0.25 && progress < 1.0) {
          lastReported = progress;
          _send(
            MediaStatusMessage(
              mediaId: mediaId,
              state: MediaFetchState.fetching,
              progress: progress,
            ),
          );
        }
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    hasher.close();

    // §6.2: sha256 verifies the transfer (and enables cross-session caching).
    final digest = digestSink.value!.toString();
    if (item.sha256.isNotEmpty && digest != item.sha256) {
      try {
        await destination.delete();
      } catch (_) {}
      _send(MediaStatusMessage(mediaId: mediaId, state: MediaFetchState.none));
      throw StateError(
        'sha256 mismatch for $mediaId: expected ${item.sha256}, got $digest',
      );
    }
    onProgress?.call(1.0);
    _send(MediaStatusMessage(mediaId: mediaId, state: MediaFetchState.ready));
    return destination;
  }

  /// Fetches `GET /media/{mediaId}` into memory (§6.2), reporting
  /// `media_status` upstream (§6.3): `fetching` with progress while
  /// downloading, `ready` once the sha256 digest matches the playlist entry.
  ///
  /// Implemented on top of [fetchMediaToFile] via a temp file (one fetch
  /// path); the returned bytes are read back after verification. Prefer
  /// [fetchMediaToFile] for anything large.
  ///
  /// [onProgress] receives values in [0, 1]. Throws [ArgumentError] if
  /// [mediaId] is not in the current playlist, [HttpException] on a non-200
  /// response, and [StateError] on a digest mismatch (after reporting
  /// `media_status: none`).
  Future<Uint8List> fetchMedia(
    String mediaId, {
    void Function(double progress)? onProgress,
  }) async {
    final dir = await Directory.systemTemp.createTemp('localjam_fetch_');
    try {
      final file = await fetchMediaToFile(
        mediaId,
        File('${dir.path}/$mediaId'),
        onProgress: onProgress,
      );
      return await file.readAsBytes();
    } finally {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    }
  }

  /// Fetches `GET /artwork/{artworkId}` with Bearer auth (§6.5) into memory.
  /// Artwork is small (an embedded cover), so no streaming/progress plumbing.
  ///
  /// Throws [HttpException] on a non-200 response (404 for an unknown id).
  Future<Uint8List> fetchArtwork(String artworkId) async {
    final uri = Uri(
      scheme: 'http',
      host: _host,
      port: _port,
      path: '/artwork/$artworkId',
    );
    final request = await _http.getUrl(uri);
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_token');
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      throw HttpException(
        'GET $uri failed with ${response.statusCode}',
        uri: uri,
      );
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  /// Uploads [file] to the host over the media plane (`POST /media`, §6.4),
  /// streaming it from disk — the file is never read into memory whole.
  /// Metadata travels in `X-LocalJam-*` headers; the host computes the sha256
  /// and mediaId itself, adds the item to the playlist, and broadcasts it.
  ///
  /// [name] defaults to the file's basename (sent percent-encoded, §6.4).
  /// [onProgress] receives values in [0, 1] as body bytes are flushed.
  ///
  /// Returns the host's [MediaItem] — the newly created item (201), or the
  /// pre-existing item when this content was already in the session (200,
  /// idempotent). Throws [HttpException] on any other response (401 bad
  /// token, 413 over the host's size limit, ...).
  Future<MediaItem> uploadMedia(
    File file, {
    required MediaKind kind,
    String? name,
    String mime = 'application/octet-stream',
    int? durationUs,
    void Function(double progress)? onProgress,
  }) async {
    final total = await file.length();
    final uri = Uri(scheme: 'http', host: _host, port: _port, path: '/media');
    final request = await _http.postUrl(uri);
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_token');
    request.headers.set('X-LocalJam-Kind', kind.wire);
    request.headers.set(
      'X-LocalJam-Name',
      Uri.encodeComponent(name ?? Uri.file(file.path).pathSegments.last),
    );
    request.headers.set('X-LocalJam-Mime', mime);
    if (durationUs != null) {
      request.headers.set('X-LocalJam-Duration-Us', '$durationUs');
    }
    request.headers.set('X-LocalJam-Peer-Id', _selfPeerId);
    request.headers.contentType = ContentType.binary;
    request.contentLength = total;

    var sent = 0;
    await for (final chunk in file.openRead()) {
      request.add(chunk);
      // Flush per chunk: backpressure keeps memory flat and makes progress
      // reflect bytes actually handed to the socket.
      await request.flush();
      sent += chunk.length;
      onProgress?.call(total > 0 ? (sent / total).clamp(0.0, 1.0) : 1.0);
    }
    final response = await request.close();
    final body = await utf8.decodeStream(response);
    if (response.statusCode != HttpStatus.created &&
        response.statusCode != HttpStatus.ok) {
      throw HttpException(
        'POST $uri failed with ${response.statusCode}',
        uri: uri,
      );
    }
    return MediaItem.fromJson(jsonDecode(body) as Map<String, Object?>);
  }

  // --- Teardown ------------------------------------------------------------------

  /// Closes the control socket and all streams. Idempotent.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _pingTimer?.cancel();
    await _sub.cancel();
    try {
      await _ws.close(WebSocketStatus.normalClosure);
    } catch (_) {}
    if (!_done.isCompleted) _done.complete();
    _http.close(force: true);
    await _states.close();
    await _playlists.close();
    await _peerEvents.close();
    await _permissionUpdates.close();
    await _errors.close();
  }

  // --- Wire helper -----------------------------------------------------------------

  void _send(Message message) {
    if (_closed || _ws.readyState != WebSocket.open) return;
    try {
      _ws.add(_codec.encode(message, seq: _seq++));
    } on StateError {
      // Sink closed underneath us mid-teardown; close() handles the rest.
    }
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
