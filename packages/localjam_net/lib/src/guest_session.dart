/// LocalJam self-healing guest session: owns successive [JamGuestClient]
/// connections and rides the PROTOCOL.md §3.3 reconnect path (`hello` with
/// `resumePeerId`) so consumers see one continuous session across drops.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:localjam_core/localjam_core.dart';

import 'guest_client.dart';

/// Connection lifecycle of a [JamGuestSession].
enum JamConnectionState {
  /// A live [JamGuestClient] is connected to the host.
  connected,

  /// The connection dropped without a local close; reconnect attempts are
  /// running (§3.3).
  reconnecting,

  /// [JamGuestSession.close] was called. Terminal.
  closed,

  /// The host answered a reconnect attempt with `reject` — the session is
  /// gone (e.g. `bad_token` after a host restart). Terminal; no further
  /// retries.
  failed,
}

/// Exponential backoff schedule for [JamGuestSession] reconnect attempts:
/// `initialDelay * multiplier^attempt`, capped at [maxDelay], with
/// ±[jitterRatio] random jitter.
///
/// Subclass and override [delay] to observe or reshape the schedule (tests
/// use this to count attempts).
class JamBackoff {
  JamBackoff({
    this.initialDelay = const Duration(milliseconds: 500),
    this.multiplier = 2.0,
    this.maxDelay = const Duration(seconds: 10),
    this.jitterRatio = 0.2,
    Random? random,
  }) : assert(multiplier >= 1, 'multiplier must be >= 1'),
       assert(
         jitterRatio >= 0 && jitterRatio < 1,
         'jitterRatio must be in [0, 1)',
       ),
       _random = random ?? Random();

  /// Delay before the first reconnect attempt (default 500 ms).
  final Duration initialDelay;

  /// Growth factor per attempt (default ×2).
  final double multiplier;

  /// Upper bound on any delay (default 10 s).
  final Duration maxDelay;

  /// Uniform jitter as a fraction of the computed delay (default ±20 %).
  final double jitterRatio;

  final Random _random;

  /// The delay to wait before reconnect [attempt] (0-based).
  Duration delay(int attempt) {
    final capUs = maxDelay.inMicroseconds.toDouble();
    var us = initialDelay.inMicroseconds * pow(multiplier, attempt).toDouble();
    if (us > capUs) us = capUs;
    us *= 1 + jitterRatio * (2 * _random.nextDouble() - 1);
    return Duration(microseconds: us.clamp(0, capUs).round());
  }
}

/// A self-healing LocalJam guest session.
///
/// Wraps successive [JamGuestClient] connections behind one stable surface:
/// when the underlying connection drops without a local [close], the session
/// transitions to [JamConnectionState.reconnecting] and retries
/// [JamGuestClient.connect] with `resumePeerId` set to the last peerId
/// (§3.3), backing off per its [JamBackoff]. Retries continue indefinitely
/// until [close] or until the host answers `reject` — a reject means the
/// session is gone (e.g. `bad_token` from a restarted host), so the session
/// transitions to [JamConnectionState.failed] and stops.
///
/// The streams ([states], [playlistUpdates], [peerEvents]) are continuous
/// across reconnects: each is one broadcast stream re-piped from every new
/// client. On a successful resume the fresh `welcome` snapshot and playlist
/// are re-emitted so consumers converge. The host may hand back the same
/// peerId (resume within grace) or a fresh one (grace expired) — the session
/// adopts whichever the new `welcome` carries.
class JamGuestSession {
  JamGuestSession._(
    this._joinUri,
    this._clientName,
    this._clientKind,
    this._caps,
    this._pingInterval,
    this._connectTimeout,
    this._backoff,
    JamGuestClient client,
  ) {
    _adopt(client);
  }

  /// Connects a first [JamGuestClient] to [joinUri] and wraps it in a
  /// session. Errors from this initial connect ([JamRejectedException],
  /// `SocketException`, ...) propagate to the caller unchanged.
  ///
  /// [backoff] shapes the reconnect schedule (defaults: 500 ms, ×2, cap 10 s,
  /// jitter). The remaining parameters are forwarded to every
  /// [JamGuestClient.connect], initial and reconnect alike.
  static Future<JamGuestSession> connect(
    Uri joinUri, {
    String clientName = 'guest',
    String clientKind = 'dart',
    List<String> caps = const ['audio'],
    Duration pingInterval = const Duration(seconds: 2),
    Duration connectTimeout = const Duration(seconds: 5),
    JamBackoff? backoff,
  }) async {
    final client = await JamGuestClient.connect(
      joinUri,
      clientName: clientName,
      clientKind: clientKind,
      caps: caps,
      pingInterval: pingInterval,
      connectTimeout: connectTimeout,
    );
    return JamGuestSession._(
      joinUri,
      clientName,
      clientKind,
      caps,
      pingInterval,
      connectTimeout,
      backoff ?? JamBackoff(),
      client,
    );
  }

  final Uri _joinUri;
  final String _clientName;
  final String _clientKind;
  final List<String> _caps;
  final Duration _pingInterval;
  final Duration _connectTimeout;
  final JamBackoff _backoff;

  late JamGuestClient _client;
  List<StreamSubscription<Object?>> _clientSubs = const [];

  JamConnectionState _state = JamConnectionState.connected;

  Timer? _retryTimer;
  Completer<void>? _retryWake;

  final StreamController<JamConnectionState> _connStates =
      StreamController<JamConnectionState>.broadcast();
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

  // --- Connection state ------------------------------------------------------

  /// The current connection state.
  JamConnectionState get connectionState => _state;

  /// Every state transition after subscription ([connectionState] is the
  /// current value; the initial [JamConnectionState.connected] is not
  /// replayed).
  Stream<JamConnectionState> get connectionStates => _connStates.stream;

  // --- Mirrored JamGuestClient surface ----------------------------------------
  //
  // Getters delegate to the current (possibly just-dropped) client, whose
  // last-known values remain readable while reconnecting.

  /// This guest's peerId from the latest `welcome` (§3.1). While
  /// reconnecting: the last peerId, which is also what resume attempts carry.
  String get selfPeerId => _client.selfPeerId;

  /// The session id from the latest `welcome` (§3.1).
  String get sessionId => _client.sessionId;

  /// The session name from the latest `welcome` (§3.1).
  String get sessionName => _client.sessionName;

  /// The most recent authoritative playback snapshot (§5.1).
  PlaybackSnapshot get snapshot => _client.snapshot;

  /// Authoritative state broadcasts (§5.1), continuous across reconnects.
  /// After a resume the fresh `welcome` snapshot is re-emitted.
  Stream<PlaybackSnapshot> get states => _states.stream;

  /// The current playlist (§6.1).
  List<MediaItem> get playlist => _client.playlist;

  /// Playlist broadcasts (§6.1), continuous across reconnects. After a
  /// resume the fresh `welcome` playlist is re-emitted.
  Stream<List<MediaItem>> get playlistUpdates => _playlists.stream;

  /// Other peers currently in the session (last known while reconnecting).
  List<PeerInfo> get peers => _client.peers;

  /// Presence changes (§3.2), continuous across reconnects.
  Stream<JamPeerEvent> get peerEvents => _peerEvents.stream;

  /// The room's permission document (§5.6; last known while reconnecting).
  JamPermissions get permissions => _client.permissions;

  /// Permission-document broadcasts (§5.6), continuous across reconnects.
  /// After a resume the fresh `welcome` document is re-emitted.
  Stream<JamPermissions> get permissionUpdates => _permissionUpdates.stream;

  /// This guest's own effective capabilities (§5.6).
  Set<JamCapability> get myCapabilities => _client.myCapabilities;

  /// Host error reports (§8), continuous across reconnects.
  Stream<ErrorMessage> get errors => _errors.stream;

  /// The fatal error that ended the session, if any (§5.6/§8) — set when the
  /// session lands in [JamConnectionState.failed] because of one (a kick).
  ErrorMessage? get lastFatalError => _client.lastFatalError;

  /// The CURRENT client's clock-offset estimator (§4). Replaced on every
  /// reconnect (a new connection re-runs the join burst).
  ClockSync get clock => _client.clock;

  /// This guest's local monotonic clock (µs, arbitrary epoch).
  int get localNowUs => _client.localNowUs;

  /// The current session-clock time (§4). Throws [StateError] before the
  /// current client's clock is synchronized.
  int get sessionNowUs => _client.sessionNowUs;

  /// Asks the host to start playback (§5.2). Throws [StateError] unless
  /// [connectionState] is [JamConnectionState.connected].
  Future<void> requestPlay() {
    _ensureConnected();
    return _client.requestPlay();
  }

  /// Asks the host to pause playback (§5.2). Throws [StateError] unless
  /// connected.
  Future<void> requestPause() {
    _ensureConnected();
    return _client.requestPause();
  }

  /// Asks the host to seek to [positionUs] (§5.2). Throws [StateError]
  /// unless connected.
  Future<void> requestSeek(int positionUs) {
    _ensureConnected();
    return _client.requestSeek(positionUs);
  }

  /// Asks the host to select [mediaId] (§5.2). Throws [StateError] unless
  /// connected.
  Future<void> requestSetMedia(String mediaId) {
    _ensureConnected();
    return _client.requestSetMedia(mediaId);
  }

  /// Asks the host to skip to the next queue item (§5.2). Throws
  /// [StateError] unless connected.
  Future<void> requestNext() {
    _ensureConnected();
    return _client.requestNext();
  }

  /// Asks the host to skip to the previous queue item (§5.2). Throws
  /// [StateError] unless connected.
  Future<void> requestPrevious() {
    _ensureConnected();
    return _client.requestPrevious();
  }

  /// Asks the host to move [mediaId] to queue position [toIndex] (§5.6).
  /// Throws [StateError] unless connected.
  Future<void> requestQueueMove(String mediaId, int toIndex) {
    _ensureConnected();
    return _client.requestQueueMove(mediaId, toIndex);
  }

  /// Asks the host to remove [mediaId] from the queue (§5.6). Throws
  /// [StateError] unless connected.
  Future<void> requestQueueRemove(String mediaId) {
    _ensureConnected();
    return _client.requestQueueRemove(mediaId);
  }

  /// Fetches media over the HTTP plane (§6.2) via the current client.
  /// Throws [StateError] unless connected.
  Future<Uint8List> fetchMedia(
    String mediaId, {
    void Function(double progress)? onProgress,
  }) {
    _ensureConnected();
    return _client.fetchMedia(mediaId, onProgress: onProgress);
  }

  /// Streams media over the HTTP plane straight to [destination] (§6.2) via
  /// the current client, verifying its sha256 on completion. Throws
  /// [StateError] unless connected.
  Future<File> fetchMediaToFile(
    String mediaId,
    File destination, {
    void Function(double progress)? onProgress,
  }) {
    _ensureConnected();
    return _client.fetchMediaToFile(
      mediaId,
      destination,
      onProgress: onProgress,
    );
  }

  /// Fetches artwork bytes (`GET /artwork/{artworkId}`, §6.5) via the
  /// current client. Throws [StateError] unless connected.
  Future<Uint8List> fetchArtwork(String artworkId) {
    _ensureConnected();
    return _client.fetchArtwork(artworkId);
  }

  /// Uploads [file] to the host (`POST /media`, §6.4) via the current
  /// client, streaming it from disk. Throws [StateError] unless connected.
  Future<MediaItem> uploadMedia(
    File file, {
    required MediaKind kind,
    String? name,
    String mime = 'application/octet-stream',
    int? durationUs,
    void Function(double progress)? onProgress,
  }) {
    _ensureConnected();
    return _client.uploadMedia(
      file,
      kind: kind,
      name: name,
      mime: mime,
      durationUs: durationUs,
      onProgress: onProgress,
    );
  }

  /// Sends a §6.3 `media_status` report directly via the current client
  /// (see [JamGuestClient.sendMediaStatus]) — e.g. for a prefetch cache hit
  /// that never touched the network.
  ///
  /// Unlike [requestPlay] and friends, this is close-tolerant rather than
  /// strict: while not [JamConnectionState.connected] (mid-reconnect,
  /// failed, or closed) it is silently dropped instead of throwing
  /// [StateError]. That matches [JamGuestClient]'s own transport-level send
  /// semantics (a message that can't reach the wire is just dropped, not an
  /// error) and suits the caller this exists for — a background prefetch
  /// loop that re-evaluates readiness on every playlist/track change and
  /// should never crash because a reconnect happened to be in flight.
  /// PROTOCOL.md §3.3 means nothing is lost either way: readiness is
  /// forgotten by the host on drop, so the caller re-sends after every
  /// resume (see [connectionStates]).
  void sendMediaStatus(
    String mediaId,
    MediaFetchState state, {
    double? progress,
  }) {
    if (_state != JamConnectionState.connected) return;
    _client.sendMediaStatus(mediaId, state, progress: progress);
  }

  void _ensureConnected() {
    if (_state != JamConnectionState.connected) {
      throw StateError('Session is ${_state.name}, not connected to the host');
    }
  }

  // --- Reconnect machinery -----------------------------------------------------

  void _adopt(JamGuestClient client) {
    for (final sub in _clientSubs) {
      unawaited(sub.cancel());
    }
    _client = client;
    _clientSubs = [
      client.states.listen(_states.add),
      client.playlistUpdates.listen(_playlists.add),
      client.peerEvents.listen(_peerEvents.add),
      client.permissionUpdates.listen(_permissionUpdates.add),
      client.errors.listen(_errors.add),
    ];
    unawaited(client.done.then((_) => _onClientDone(client)));
  }

  void _onClientDone(JamGuestClient client) {
    if (!identical(client, _client)) return; // A superseded connection.
    if (_state != JamConnectionState.connected) return; // Local close/failed.
    if (client.lastFatalError?.code == ErrorCode.kicked) {
      // §5.6: a kick is deliberate and terminal — never auto-rejoin.
      _transition(JamConnectionState.failed);
      return;
    }
    _transition(JamConnectionState.reconnecting);
    unawaited(_reconnectLoop());
  }

  Future<void> _reconnectLoop() async {
    var attempt = 0;
    while (_state == JamConnectionState.reconnecting) {
      await _sleep(_backoff.delay(attempt));
      attempt++;
      if (_state != JamConnectionState.reconnecting) return;

      final JamGuestClient next;
      try {
        next = await JamGuestClient.connect(
          _joinUri,
          clientName: _clientName,
          clientKind: _clientKind,
          caps: _caps,
          pingInterval: _pingInterval,
          connectTimeout: _connectTimeout,
          // §3.3: try to reclaim the old slot. An expired/unknown id falls
          // back to a fresh join on the host side — either way the new
          // welcome's peerId is adopted.
          resumePeerId: _client.selfPeerId,
        );
      } on JamRejectedException {
        // §3.1: a reject is authoritative — the session is gone (bad_token
        // after a host restart, and full/version are equally final).
        if (_state == JamConnectionState.reconnecting) {
          _transition(JamConnectionState.failed);
        }
        return;
      } catch (_) {
        continue; // Host unreachable / timeout: keep retrying.
      }
      if (_state != JamConnectionState.reconnecting) {
        await next.close(); // close() raced the reconnect; discard.
        return;
      }
      _adopt(next);
      _transition(JamConnectionState.connected);
      // Re-emit the fresh welcome snapshot, playlist, and permissions so
      // stream consumers converge without re-reading the getters.
      if (!_states.isClosed) _states.add(next.snapshot);
      if (!_playlists.isClosed) _playlists.add(next.playlist);
      if (!_permissionUpdates.isClosed) {
        _permissionUpdates.add(next.permissions);
      }
      return;
    }
  }

  /// A [close]-interruptible delay.
  Future<void> _sleep(Duration duration) {
    final wake = Completer<void>();
    _retryWake = wake;
    _retryTimer = Timer(duration, () {
      if (!wake.isCompleted) wake.complete();
    });
    return wake.future;
  }

  void _transition(JamConnectionState next) {
    if (_state == next) return;
    _state = next;
    if (!_connStates.isClosed) _connStates.add(next);
  }

  // --- Teardown ------------------------------------------------------------------

  /// Closes the current client, stops any reconnect attempts, and lands the
  /// session in [JamConnectionState.closed]. Idempotent.
  Future<void> close() async {
    if (_state == JamConnectionState.closed) return;
    _transition(JamConnectionState.closed);
    _retryTimer?.cancel();
    final wake = _retryWake;
    if (wake != null && !wake.isCompleted) wake.complete();
    for (final sub in _clientSubs) {
      unawaited(sub.cancel());
    }
    _clientSubs = const [];
    await _client.close();
    await _connStates.close();
    await _states.close();
    await _playlists.close();
    await _peerEvents.close();
    await _permissionUpdates.close();
    await _errors.close();
  }
}
