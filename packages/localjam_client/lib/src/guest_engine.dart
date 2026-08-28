/// The whole guest side of a jam behind one object: an auto-reconnecting
/// [JamGuestSession], a [LocaljamAudio] player driven by the shared
/// [AudioSyncController], and full-playlist prefetching (PROTOCOL.md §6.2)
/// into a local cache directory.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:localjam_audio/localjam_audio.dart';
import 'package:localjam_net/localjam_net.dart';
import 'package:path_provider/path_provider.dart';

import 'audio_sync_controller.dart';
import 'jam_engine.dart';
import 'media_mime.dart';

/// Prefetch bookkeeping for one playlist item (§6.2/§6.3).
@immutable
class JamPrefetchState {
  const JamPrefetchState({this.progress = 0, this.path, this.error});

  /// Download progress in [0, 1].
  final double progress;

  /// Local file path, set once the item is fully fetched and sha256-verified.
  final String? path;

  /// The last fetch error for this item, if any. A later playlist broadcast
  /// (including the one re-emitted after a reconnect) retries the fetch.
  final String? error;

  /// Whether the item is fully fetched and playable.
  bool get ready => path != null;
}

/// Why a [JamGuestEngine]'s session reached its terminal state — published
/// on [JamGuestEngine.sessionEnded] so player UIs never hang on a
/// "reconnecting…" banner forever.
enum JamSessionEndReason {
  /// The connection dropped and stayed in [JamConnectionState.reconnecting]
  /// for longer than [JamGuestEngine.hostGoneTimeout]; the engine stopped
  /// the retries. The host is gone (host death ends the room — PROTOCOL.md
  /// §10; the host closes sockets with `goingAway`, and this timeout is the
  /// guest-side contract for detecting it when no reject ever arrives).
  hostGone,

  /// The host answered a (re)join with `reject` (§3.1) — e.g. `bad_token`
  /// after a host restart, or `full`/`version`. Immediate and final.
  rejected,

  /// [JamGuestEngine.close] was called locally.
  closedLocally,
}

/// One joined guest: session + clock sync + prefetch + synchronized playback.
///
/// On app resume the inherited lifecycle guard re-verifies playback sync
/// (see [JamEngine.handleLifecycleState]). Clock-sync freshness after a
/// background gap rides the existing machinery: `ClockSync`/`JamGuestClient`
/// expose no way to trigger an extra ping burst, so the steady §4 schedule
/// (one ping every 2 s, resuming with the event loop) re-converges the
/// offset — and if the connection dropped while backgrounded, the reconnect
/// path re-runs the full join burst on a fresh `ClockSync` anyway.
///
/// Create with [join]; release with [close]. The engine feeds every
/// authoritative snapshot into its [AudioSyncController] — holding the first
/// one back until the §4 clock-sync join burst lands, since scheduling needs
/// a session→local mapping — prefetches every playlist item (current and
/// future) into [mediaCacheDir], and resolves media for the controller from
/// that cache.
class JamGuestEngine extends JamEngine {
  JamGuestEngine._(
    this._session,
    this.player,
    this._cacheDir, {
    required this.hostGoneTimeout,
  }) {
    sync = AudioSyncController(
      player: player,
      sessionNowUs: () => _session.sessionNowUs,
      localNowUs: () => _session.localNowUs,
      sessionToLocalUs: (sessionUs) => _session.clock.hostToLocalUs(sessionUs),
      resolveMediaPath: (mediaId) async => prefetchStates.value[mediaId]?.path,
    );
    _subs = [
      _session.states.listen(_onSnapshot),
      _session.playlistUpdates.listen(_prefetchAll),
      _session.connectionStates.listen(_onConnectionState),
    ];
    _prefetchAll(_session.playlist);
    // Late join (§5.3): converge on whatever the host is doing right now, as
    // soon as the session clock is usable.
    unawaited(_feedAfterClockSync());
  }

  /// Connects to the host in [joinUri] (a `localjam://join?...` URI, §1),
  /// wires up player + sync controller, and starts prefetching the playlist.
  ///
  /// [mediaCacheDir] is where fetched media files land; defaults to the
  /// platform temp directory (`path_provider`). [backoff] shapes the
  /// session's reconnect schedule (§3.3). [hostGoneTimeout] bounds how long
  /// the engine keeps reconnecting before declaring the host gone and
  /// publishing [JamSessionEndReason.hostGone] on [sessionEnded].
  ///
  /// Throws [JamRejectedException] if the host rejects the join, or
  /// [SocketException] if no host candidate is reachable.
  static Future<JamGuestEngine> join(
    Uri joinUri, {
    String clientName = 'guest',
    String clientKind = 'flutter',
    Directory? mediaCacheDir,
    JamBackoff? backoff,
    Duration hostGoneTimeout = const Duration(seconds: 90),
  }) async {
    final session = await JamGuestSession.connect(
      joinUri,
      clientName: clientName,
      clientKind: clientKind,
      backoff: backoff,
    );
    final Directory cacheDir;
    try {
      cacheDir = mediaCacheDir ?? await getTemporaryDirectory();
    } catch (_) {
      await session.close();
      rethrow;
    }
    final engine = JamGuestEngine._(
      session,
      LocaljamAudio(),
      cacheDir,
      hostGoneTimeout: hostGoneTimeout,
    );
    await engine.restorePersistedNudge();
    await engine.startSessionGuards();
    return engine;
  }

  final JamGuestSession _session;
  final Directory _cacheDir;

  /// How long the session may sit in [JamConnectionState.reconnecting]
  /// before the engine gives up, stops the retries, and publishes
  /// [JamSessionEndReason.hostGone] on [sessionEnded]. A reconnect that
  /// succeeds within the window cancels the countdown.
  final Duration hostGoneTimeout;

  Timer? _hostGoneTimer;

  /// The session's terminal state: null while the session is (or may come
  /// back) alive, then set exactly once. Player UIs should render a terminal
  /// "session ended"/"join rejected" screen on this — distinct from the
  /// transient [JamConnectionState.reconnecting] banner, which
  /// [hostGoneTimeout] guarantees cannot last forever.
  final ValueNotifier<JamSessionEndReason?> sessionEnded =
      ValueNotifier<JamSessionEndReason?>(null);

  @override
  final LocaljamAudio player;

  @override
  late final AudioSyncController sync;

  late final List<StreamSubscription<Object?>> _subs;

  /// Media ids with a fetch currently in flight.
  final Set<String> _fetching = {};

  bool _waitingForClock = false;
  bool _closed = false;

  /// Prefetch state per mediaId (§6.2). The map is replaced (never mutated)
  /// on every change, so `ValueListenableBuilder` and plain listeners both
  /// work.
  final ValueNotifier<Map<String, JamPrefetchState>> prefetchStates =
      ValueNotifier<Map<String, JamPrefetchState>>(const {});

  // --- Session mirror ----------------------------------------------------

  /// The session name from `welcome` (§3.1).
  String get sessionName => _session.sessionName;

  /// The session id from `welcome` (§3.1).
  String get sessionId => _session.sessionId;

  /// This guest's peer id (§3.1); stable across resumed reconnects (§3.3).
  String get selfPeerId => _session.selfPeerId;

  @override
  PlaybackSnapshot get snapshot => _session.snapshot;

  @override
  Stream<PlaybackSnapshot> get states => _session.states;

  @override
  List<MediaItem> get playlist => _session.playlist;

  @override
  Stream<List<MediaItem>> get playlistUpdates => _session.playlistUpdates;

  /// Other peers currently in the session (excluding this guest).
  List<PeerInfo> get peers => _session.peers;

  /// Presence changes (§3.2).
  Stream<JamPeerEvent> get peerEvents => _session.peerEvents;

  /// The current connection state (§3.3 reconnects included).
  JamConnectionState get connectionState => _session.connectionState;

  /// Connection state transitions.
  Stream<JamConnectionState> get connectionStates => _session.connectionStates;

  /// Whether the current connection's clock has synchronized (§4). Snapshots
  /// are held back from the sync controller until this turns true.
  bool get clockSynced => _session.clock.isSynchronized;

  /// The guest→host clock offset estimate (µs), null while unsynchronized.
  int? get clockOffsetUs => _session.clock.offsetUs;

  @override
  int? get sessionNowUsOrNull =>
      _session.clock.isSynchronized ? _session.sessionNowUs : null;

  // --- Requests (§5.2) -----------------------------------------------------

  /// Asks the host to start playback (§5.2).
  Future<void> requestPlay() => _session.requestPlay();

  /// Asks the host to pause playback (§5.2).
  Future<void> requestPause() => _session.requestPause();

  /// Asks the host to seek to [positionUs] (§5.2).
  Future<void> requestSeek(int positionUs) => _session.requestSeek(positionUs);

  /// Asks the host to select [mediaId] (§5.2).
  Future<void> requestSetMedia(String mediaId) =>
      _session.requestSetMedia(mediaId);

  // --- Snapshot plumbing ----------------------------------------------------

  void _onSnapshot(PlaybackSnapshot snapshot) {
    if (_closed) return;
    if (_session.clock.isSynchronized) {
      unawaited(sync.onSnapshot(snapshot));
    } else {
      // Fresh connection (initial join or reconnect): the §4 ping burst is
      // still in flight. Feed the latest snapshot once it lands.
      unawaited(_feedAfterClockSync());
    }
  }

  Future<void> _feedAfterClockSync() async {
    if (_waitingForClock) return;
    _waitingForClock = true;
    try {
      while (!_closed && !_session.clock.isSynchronized) {
        if (_session.connectionState == JamConnectionState.closed ||
            _session.connectionState == JamConnectionState.failed) {
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      if (_closed) return;
      await sync.onSnapshot(_session.snapshot);
    } finally {
      _waitingForClock = false;
    }
  }

  // --- Session-end contract ------------------------------------------------

  void _onConnectionState(JamConnectionState state) {
    if (_closed) return;
    switch (state) {
      case JamConnectionState.connected:
        // A reconnect succeeded: the host is alive, cancel the countdown.
        _hostGoneTimer?.cancel();
        _hostGoneTimer = null;
      case JamConnectionState.reconnecting:
        _hostGoneTimer ??= Timer(hostGoneTimeout, _onHostGoneTimeout);
      case JamConnectionState.failed:
        // §3.1: a reject is authoritative and immediate — the session is
        // gone (bad_token after a host restart, full, version).
        _end(JamSessionEndReason.rejected);
      case JamConnectionState.closed:
        // Only reachable via a local close (ours or _end's); the reason has
        // already been published by whoever initiated it.
        break;
    }
  }

  void _onHostGoneTimeout() {
    _hostGoneTimer = null;
    if (_closed) return;
    if (_session.connectionState != JamConnectionState.reconnecting) return;
    _end(JamSessionEndReason.hostGone);
  }

  /// Publishes the terminal [reason] (first writer wins) and stops the
  /// underlying session's reconnect retries.
  void _end(JamSessionEndReason reason) {
    _hostGoneTimer?.cancel();
    _hostGoneTimer = null;
    if (sessionEnded.value == null) sessionEnded.value = reason;
    if (_session.connectionState == JamConnectionState.reconnecting ||
        _session.connectionState == JamConnectionState.connected) {
      unawaited(_session.close());
    }
  }

  // --- Prefetch (§6.2: fully prefetch before playing) -----------------------

  void _prefetchAll(List<MediaItem> items) {
    if (_closed) return;
    for (final item in items) {
      final state = prefetchStates.value[item.mediaId];
      if (state?.ready ?? false) continue;
      if (_fetching.contains(item.mediaId)) continue;
      unawaited(_prefetch(item));
    }
  }

  Future<void> _prefetch(MediaItem item) async {
    _fetching.add(item.mediaId);
    _setPrefetch(item.mediaId, const JamPrefetchState());
    try {
      // fetchMedia reports media_status upstream (§6.3) and verifies sha256.
      final bytes = await _session.fetchMedia(
        item.mediaId,
        onProgress: (progress) {
          if (_closed) return;
          _setPrefetch(item.mediaId, JamPrefetchState(progress: progress));
        },
      );
      if (_closed) return;
      final path =
          '${_cacheDir.path}/localjam_${item.mediaId}'
          '.${extensionForMime(item.mime)}';
      await File(path).writeAsBytes(bytes, flush: true);
      if (_closed) return;
      _setPrefetch(item.mediaId, JamPrefetchState(progress: 1, path: path));
      await sync.notifyMediaAvailable(item.mediaId);
    } on Object catch (e) {
      if (_closed) return;
      // Remember the error; the next playlist broadcast (a reconnect re-emits
      // one) retries because the state is not ready.
      _setPrefetch(item.mediaId, JamPrefetchState(error: '$e'));
    } finally {
      _fetching.remove(item.mediaId);
    }
  }

  void _setPrefetch(String mediaId, JamPrefetchState state) {
    prefetchStates.value = Map.unmodifiable({
      ...prefetchStates.value,
      mediaId: state,
    });
  }

  // --- Teardown ----------------------------------------------------------------

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (sessionEnded.value == null) {
      sessionEnded.value = JamSessionEndReason.closedLocally;
    }
    _hostGoneTimer?.cancel();
    _hostGoneTimer = null;
    await stopSessionGuards();
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    await sync.dispose();
    try {
      await player.dispose();
    } catch (_) {
      // Native side may not be up (tests, stub platforms).
    }
    await _session.close();
    prefetchStates.dispose();
    sessionEnded.dispose();
    nudgeUs.dispose();
  }
}
