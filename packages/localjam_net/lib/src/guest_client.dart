/// LocalJam guest: joins a host over the WebSocket control plane, runs the
/// clock-sync schedule (PROTOCOL.md §4), mirrors the authoritative playback
/// state and playlist (§5, §6), and fetches media over the HTTP plane (§6.2).
library;

import 'dart:async';
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

  final StreamController<PlaybackSnapshot> _states =
      StreamController<PlaybackSnapshot>.broadcast();
  final StreamController<List<MediaItem>> _playlists =
      StreamController<List<MediaItem>>.broadcast();
  final StreamController<JamPeerEvent> _peerEvents =
      StreamController<JamPeerEvent>.broadcast();

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
      default:
        break; // error/unknown: ignored (§2, §8).
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

  // --- Media plane (§6.2, §6.3) ----------------------------------------------------

  /// Fetches `GET /media/{mediaId}` with Bearer auth (§6.2), reporting
  /// `media_status` upstream (§6.3): `fetching` with progress while
  /// downloading, `ready` once the sha256 digest matches the playlist entry.
  ///
  /// [onProgress] receives values in [0, 1]. Throws [ArgumentError] if
  /// [mediaId] is not in the current playlist, [HttpException] on a non-200
  /// response, and [StateError] on a digest mismatch (after reporting
  /// `media_status: none`).
  Future<Uint8List> fetchMedia(
    String mediaId, {
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
    final builder = BytesBuilder(copy: false);
    var lastReported = 0.0;
    await for (final chunk in response) {
      builder.add(chunk);
      final progress = total > 0
          ? (builder.length / total).clamp(0.0, 1.0)
          : 0.0;
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
    final bytes = builder.takeBytes();

    // §6.2: sha256 verifies the transfer (and enables cross-session caching).
    final digest = sha256.convert(bytes).toString();
    if (item.sha256.isNotEmpty && digest != item.sha256) {
      _send(MediaStatusMessage(mediaId: mediaId, state: MediaFetchState.none));
      throw StateError(
        'sha256 mismatch for $mediaId: expected ${item.sha256}, got $digest',
      );
    }
    onProgress?.call(1.0);
    _send(MediaStatusMessage(mediaId: mediaId, state: MediaFetchState.ready));
    return bytes;
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
