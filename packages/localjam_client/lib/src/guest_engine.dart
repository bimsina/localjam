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

/// One joined guest: session + clock sync + prefetch + synchronized playback.
///
/// Create with [join]; release with [close]. The engine feeds every
/// authoritative snapshot into its [AudioSyncController] — holding the first
/// one back until the §4 clock-sync join burst lands, since scheduling needs
/// a session→local mapping — prefetches every playlist item (current and
/// future) into [mediaCacheDir], and resolves media for the controller from
/// that cache.
class JamGuestEngine extends JamEngine {
  JamGuestEngine._(this._session, this.player, this._cacheDir) {
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
  /// session's reconnect schedule (§3.3).
  ///
  /// Throws [JamRejectedException] if the host rejects the join, or
  /// [SocketException] if no host candidate is reachable.
  static Future<JamGuestEngine> join(
    Uri joinUri, {
    String clientName = 'guest',
    String clientKind = 'flutter',
    Directory? mediaCacheDir,
    JamBackoff? backoff,
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
    final engine = JamGuestEngine._(session, LocaljamAudio(), cacheDir);
    await engine.restorePersistedNudge();
    return engine;
  }

  final JamGuestSession _session;
  final Directory _cacheDir;

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
    nudgeUs.dispose();
  }
}
