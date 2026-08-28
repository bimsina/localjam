/// The whole guest side of a jam behind one object: an auto-reconnecting
/// [JamGuestSession], a [LocaljamAudio] player driven by the shared
/// [AudioSyncController], and policy-driven prefetching (PROTOCOL.md §6.2)
/// into a persistent sha256-keyed media cache ([JamMediaCache]).
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:localjam_audio/localjam_audio.dart';
import 'package:localjam_net/localjam_net.dart';
import 'package:path_provider/path_provider.dart';

import 'audio_sync_controller.dart';
import 'jam_engine.dart';
import 'media_cache.dart';
import 'media_mime.dart';

/// What the guest prefetches, and in what order (§6.2).
///
/// The CURRENT track is always fetched at top priority, then the next
/// [aheadCount] playlist items after it (wrapping at the end of the
/// playlist). The plan is re-evaluated on every snapshot `mediaId` change and
/// every playlist update; at most one fetch is in flight at a time, and a
/// newly-current track preempts queued lower-priority fetches but never
/// cancels an in-flight one — it just goes next.
///
/// [prefetchAll] restores the fetch-everything behavior (still current-first
/// and one at a time): every playlist item is eventually fetched.
@immutable
class JamPrefetchPolicy {
  const JamPrefetchPolicy({this.aheadCount = 2, this.prefetchAll = false})
    : assert(aheadCount >= 0, 'aheadCount must be >= 0');

  /// How many playlist items after the current one to prefetch (wrapping).
  final int aheadCount;

  /// Fetch the whole playlist (current-first) instead of just the ahead
  /// window.
  final bool prefetchAll;

  @override
  String toString() =>
      'JamPrefetchPolicy(aheadCount: $aheadCount, prefetchAll: $prefetchAll)';
}

/// Where one playlist item is in the prefetch pipeline.
enum JamPrefetchPhase {
  /// Outside the policy's fetch window: nothing queued for it (yet). Becomes
  /// [queued] when the window reaches it.
  notQueued,

  /// In the fetch window, waiting its turn (one fetch in flight at a time).
  queued,

  /// The fetch is in flight; [JamPrefetchState.progress] moves.
  fetching,

  /// Fully fetched (or cache-hit) and playable; [JamPrefetchState.path] set.
  ready,

  /// The last fetch failed ([JamPrefetchState.error]); re-queued on the next
  /// playlist update or current-track change.
  failed,
}

/// Prefetch bookkeeping for one playlist item (§6.2/§6.3).
@immutable
class JamPrefetchState {
  const JamPrefetchState({
    this.phase = JamPrefetchPhase.queued,
    this.progress = 0,
    this.path,
    this.error,
  });

  /// The distinct "not part of the fetch window" state.
  const JamPrefetchState.notQueued() : this(phase: JamPrefetchPhase.notQueued);

  /// Where the item is in the prefetch pipeline.
  final JamPrefetchPhase phase;

  /// Download progress in [0, 1].
  final double progress;

  /// Local (cache) file path, set once the item is fully fetched and
  /// sha256-verified — or found already sitting in the cache.
  final String? path;

  /// The last fetch error for this item, if any. Kept while re-queued so UIs
  /// can render "retrying".
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
/// a session→local mapping — prefetches per its [prefetchPolicy] into the
/// persistent sha256-keyed [JamMediaCache], and resolves media for the
/// controller from that cache. Because cache files are keyed by content
/// hash, rejoining a jam (or joining another jam playing the same files)
/// re-fetches nothing.
class JamGuestEngine extends JamEngine {
  JamGuestEngine._(
    this._session,
    this.player,
    this._cache, {
    required this.prefetchPolicy,
    required this.hostGoneTimeout,
  }) {
    sync = AudioSyncController(
      player: player,
      sessionNowUs: () => _session.sessionNowUs,
      localNowUs: () => _session.localNowUs,
      sessionToLocalUs: (sessionUs) => _session.clock.hostToLocalUs(sessionUs),
      resolveMediaPath: (mediaId) async => prefetchStates.value[mediaId]?.path,
    );
    _lastPlanMediaId = _session.snapshot.mediaId;
    _subs = [
      _session.states.listen(_onSnapshot),
      _session.playlistUpdates.listen((_) => _reevaluatePrefetch()),
      _session.connectionStates.listen(_onConnectionState),
    ];
    _reevaluatePrefetch();
    // Late join (§5.3): converge on whatever the host is doing right now, as
    // soon as the session clock is usable.
    unawaited(_feedAfterClockSync());
  }

  /// Connects to the host in [joinUri] (a `localjam://join?...` URI, §1),
  /// wires up player + sync controller, and starts prefetching per
  /// [prefetchPolicy].
  ///
  /// [mediaCacheDir] is the persistent sha256-keyed media cache directory;
  /// it defaults to `getApplicationCacheDirectory()/localjam_media`
  /// (`path_provider`), shared across sessions so rejoining a jam re-fetches
  /// nothing. Override it in tests (or to relocate the cache).
  /// [cacheMaxBytes] caps the cache size (default 1 GB): after each completed
  /// fetch, least-recently-used files are evicted — never the current track
  /// or the ahead window. [backoff] shapes the session's reconnect schedule
  /// (§3.3). [hostGoneTimeout] bounds how long the engine keeps reconnecting
  /// before declaring the host gone and publishing
  /// [JamSessionEndReason.hostGone] on [sessionEnded].
  ///
  /// Throws [JamRejectedException] if the host rejects the join, or
  /// [SocketException] if no host candidate is reachable.
  static Future<JamGuestEngine> join(
    Uri joinUri, {
    String clientName = 'guest',
    String clientKind = 'flutter',
    Directory? mediaCacheDir,
    JamPrefetchPolicy prefetchPolicy = const JamPrefetchPolicy(),
    int cacheMaxBytes = 1 << 30,
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
      cacheDir =
          mediaCacheDir ??
          Directory(
            '${(await getApplicationCacheDirectory()).path}/localjam_media',
          );
      await cacheDir.create(recursive: true);
    } catch (_) {
      await session.close();
      rethrow;
    }
    final engine = JamGuestEngine._(
      session,
      LocaljamAudio(),
      JamMediaCache(cacheDir, maxBytes: cacheMaxBytes),
      prefetchPolicy: prefetchPolicy,
      hostGoneTimeout: hostGoneTimeout,
    );
    await engine.restorePersistedNudge();
    await engine.startSessionGuards();
    return engine;
  }

  final JamGuestSession _session;
  final JamMediaCache _cache;

  /// What this guest prefetches, and in what order (§6.2).
  final JamPrefetchPolicy prefetchPolicy;

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

  /// The mediaId with a fetch currently in flight, if any. In-flight fetches
  /// are never cancelled by re-prioritization — a newly-current track just
  /// goes next.
  String? _fetchingId;

  /// Re-entrancy guard for [_pumpPrefetch]: doubles as "one fetch in flight
  /// at a time".
  bool _pumping = false;

  /// The snapshot mediaId the current prefetch plan was built for; a change
  /// re-evaluates the plan.
  String? _lastPlanMediaId;

  bool _waitingForClock = false;
  bool _closed = false;

  /// Prefetch state per mediaId (§6.2). The map is replaced (never mutated)
  /// on every change, so `ValueListenableBuilder` and plain listeners both
  /// work. Items outside the policy's fetch window report
  /// [JamPrefetchPhase.notQueued].
  final ValueNotifier<Map<String, JamPrefetchState>> prefetchStates =
      ValueNotifier<Map<String, JamPrefetchState>>(const {});

  /// Progress of an in-flight [addMediaFile] upload in [0, 1]; null while no
  /// upload is running.
  final ValueNotifier<double?> uploadProgress = ValueNotifier<double?>(null);

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

  // --- Guest uploads (§6.4) --------------------------------------------------

  /// Contributes [file] to the jam: probes its duration through this
  /// engine's own [player] (the plugin drives one shared native engine per
  /// app — same pattern as the host's `addMediaFile`), then streams it to
  /// the host via `POST /media` (§6.4). The host derives the mediaId from
  /// the content hash, appends the item, and broadcasts the playlist — which
  /// flows back to every guest (this one included) through the ordinary
  /// plumbing.
  ///
  /// The file is also copied into the local sha-keyed cache *before* the
  /// upload, so the uploader never re-downloads its own song when the new
  /// item enters the prefetch window.
  ///
  /// Upload progress is published on [uploadProgress] ([0, 1]; null when
  /// idle). Returns the host's [MediaItem] (the existing item when the same
  /// bytes were already in the session — uploads are idempotent, §6.4).
  /// Throws [HttpException] on a rejected upload (401/413/...), or
  /// [StateError] while the session is not connected.
  Future<MediaItem> addMediaFile(File file, {String? name}) async {
    final durationUs = await _probeDurationUs(file.path);
    final mime = mimeForPath(file.path);
    // Describe the file locally (sha256 + size) to seed the cache before the
    // upload: the playlist broadcast can beat the HTTP response, and the
    // prefetch pipeline must find the bytes already cached either way.
    final described = await JamHostServer.describeFile(
      file,
      kind: MediaKind.audio,
      name: name,
      mime: mime,
      durationUs: durationUs,
    );
    final cached = await _cache.seed(file, described);
    uploadProgress.value = 0;
    try {
      final item = await _session.uploadMedia(
        file,
        kind: MediaKind.audio,
        name: name,
        mime: mime,
        durationUs: durationUs,
        onProgress: (progress) {
          if (!_closed) uploadProgress.value = progress;
        },
      );
      if (_closed) return item;
      _setPrefetch(
        item.mediaId,
        JamPrefetchState(
          phase: JamPrefetchPhase.ready,
          progress: 1,
          path: cached.path,
        ),
      );
      await sync.notifyMediaAvailable(item.mediaId);
      unawaited(_cache.evict(protectedPaths: _protectedCachePaths()));
      return item;
    } finally {
      if (!_closed) uploadProgress.value = null;
    }
  }

  /// Same shared-engine duration probe the host engine uses: load once
  /// through [player], then invalidate the controller's loaded-media cache
  /// so the current track is reloaded (and re-scheduled if playing).
  Future<int?> _probeDurationUs(String path) async {
    final int durationUs;
    try {
      durationUs = await player.load(path);
    } catch (_) {
      return null; // Native side unavailable; upload without a duration.
    }
    await sync.invalidateLoadedMedia();
    return durationUs;
  }

  // --- Snapshot plumbing ----------------------------------------------------

  void _onSnapshot(PlaybackSnapshot snapshot) {
    if (_closed) return;
    if (snapshot.mediaId != _lastPlanMediaId) {
      _lastPlanMediaId = snapshot.mediaId;
      _reevaluatePrefetch();
    }
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

  // --- Prefetch (§6.2: policy-driven, cache-first) ---------------------------

  /// The policy's fetch window in priority order: the current track first,
  /// then the next [JamPrefetchPolicy.aheadCount] items after it (wrapping).
  /// With no current track the window starts at the head of the playlist.
  List<MediaItem> _windowItems() {
    final items = _session.playlist;
    if (items.isEmpty) return const [];
    final currentId = _session.snapshot.mediaId;
    var start = items.indexWhere((i) => i.mediaId == currentId);
    if (start < 0) start = 0;
    final count = (1 + prefetchPolicy.aheadCount).clamp(0, items.length);
    return [for (var k = 0; k < count; k++) items[(start + k) % items.length]];
  }

  /// Everything the policy wants fetched, in priority order: the window, or
  /// the whole playlist (current-first, wrapping) with `prefetchAll`.
  List<MediaItem> _targetItems() {
    if (!prefetchPolicy.prefetchAll) return _windowItems();
    final items = _session.playlist;
    if (items.isEmpty) return const [];
    final currentId = _session.snapshot.mediaId;
    var start = items.indexWhere((i) => i.mediaId == currentId);
    if (start < 0) start = 0;
    return [
      for (var k = 0; k < items.length; k++) items[(start + k) % items.length],
    ];
  }

  /// Cache paths eviction must never remove: the current track and the ahead
  /// window (regardless of `prefetchAll`), plus any in-flight destination.
  Set<String> _protectedCachePaths() => {
    for (final item in _windowItems()) ...[
      _cache.fileFor(item).path,
      '${_cache.fileFor(item).path}.part',
    ],
  };

  /// Rebuilds the prefetch plan: window items become queued (ready ones stay
  /// ready, the in-flight one stays fetching), everything else reports the
  /// distinct notQueued state. Failed items inside the window are re-queued
  /// (this runs on every playlist update — including the one re-emitted
  /// after a reconnect — and every current-track change, so errors retry).
  void _reevaluatePrefetch() {
    if (_closed) return;
    final targetIds = {for (final t in _targetItems()) t.mediaId};
    final previous = prefetchStates.value;
    final next = <String, JamPrefetchState>{};
    for (final item in _session.playlist) {
      final id = item.mediaId;
      final existing = previous[id];
      if ((existing?.ready ?? false) || id == _fetchingId) {
        next[id] = existing!;
      } else if (targetIds.contains(id)) {
        next[id] = JamPrefetchState(error: existing?.error);
      } else {
        next[id] = const JamPrefetchState.notQueued();
      }
    }
    prefetchStates.value = Map.unmodifiable(next);
    unawaited(_pumpPrefetch());
  }

  /// Runs the fetch pipeline: one fetch in flight at a time, always picking
  /// the highest-priority queued item under the CURRENT plan — so a track
  /// that became current mid-fetch preempts the remaining queue without
  /// cancelling the in-flight transfer.
  Future<void> _pumpPrefetch() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (!_closed) {
        MediaItem? next;
        for (final item in _targetItems()) {
          if (prefetchStates.value[item.mediaId]?.phase ==
              JamPrefetchPhase.queued) {
            next = item;
            break;
          }
        }
        if (next == null) return;
        _fetchingId = next.mediaId;
        try {
          await _fetchOne(next);
        } finally {
          _fetchingId = null;
        }
      }
    } finally {
      _pumping = false;
    }
  }

  /// Fetches one item into the sha-keyed cache — unless the cache already
  /// holds it (right name, right size), in which case the network is skipped
  /// entirely and the item reports ready immediately.
  ///
  /// Known gap: on a cache hit no `media_status: ready` reaches the host —
  /// `localjam_net` sends §6.3 reports only from inside `fetchMediaToFile`,
  /// and exposes no API to send one directly. The host sees such a guest as
  /// `none` for that item until it re-reports; readiness here is local.
  Future<void> _fetchOne(MediaItem item) async {
    final id = item.mediaId;
    try {
      final cached = await _cache.lookup(item);
      if (cached != null) {
        if (_closed) return;
        _setPrefetch(
          id,
          JamPrefetchState(
            phase: JamPrefetchPhase.ready,
            progress: 1,
            path: cached.path,
          ),
        );
        await sync.notifyMediaAvailable(id);
        return;
      }
    } catch (_) {
      // Cache probe failed: fall through to the network.
    }
    if (_closed) return;
    _setPrefetch(id, const JamPrefetchState(phase: JamPrefetchPhase.fetching));
    final dest = _cache.fileFor(item);
    final part = File('${dest.path}.part');
    try {
      // fetchMediaToFile streams to disk (never whole files in memory),
      // verifies the sha256, and reports media_status upstream (§6.3).
      await _session.fetchMediaToFile(
        id,
        part,
        onProgress: (progress) {
          if (_closed) return;
          _setPrefetch(
            id,
            JamPrefetchState(
              phase: JamPrefetchPhase.fetching,
              progress: progress,
            ),
          );
        },
      );
      final stored = await part.rename(dest.path);
      await _cache.touch(stored);
      if (_closed) return;
      _setPrefetch(
        id,
        JamPrefetchState(
          phase: JamPrefetchPhase.ready,
          progress: 1,
          path: stored.path,
        ),
      );
      await sync.notifyMediaAvailable(id);
      await _cache.evict(protectedPaths: _protectedCachePaths());
    } on Object catch (e) {
      if (_closed) return;
      // Remember the error; the next playlist broadcast or current-track
      // change re-queues the item (see _reevaluatePrefetch).
      _setPrefetch(
        id,
        JamPrefetchState(phase: JamPrefetchPhase.failed, error: '$e'),
      );
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
    uploadProgress.dispose();
    sessionEnded.dispose();
    nudgeUs.dispose();
  }
}
