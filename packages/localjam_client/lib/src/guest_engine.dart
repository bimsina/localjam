/// The whole guest side of a jam behind one object: an auto-reconnecting
/// [JamGuestSession], a [LocaljamAudio] player driven by the shared
/// [AudioSyncController], and policy-driven prefetching (PROTOCOL.md §6.2)
/// into a [JamMediaStore]: natively the persistent sha256-keyed media cache
/// ([JamFileMediaStore]), in a browser bytes in memory under a budget
/// ([JamMemoryMediaStore], docs/design/WEB_GUEST.md D7).
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:localjam_audio/localjam_audio.dart';
import 'package:localjam_net/localjam_net.dart';

import 'audio_sync_controller.dart';
import 'engine_notifier.dart';
import 'jam_engine.dart';
import 'jam_identity.dart';
import 'media_cache.dart';
import 'media_mime.dart';
import 'media_store.dart';
import 'media_store_file.dart';
import 'platform/default_media_store.dart';

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

  /// The last fetch failed ([JamPrefetchState.error]). While
  /// [JamPrefetchState.willRetry] is true a retry is scheduled (bounded,
  /// jittered backoff); after that the item stays failed until
  /// [JamGuestEngine.retryFetch], a reconnect, or it becoming the current
  /// track — never stuck on "getting this track" with nothing happening.
  failed,

  /// Fetched and verified, but this device cannot decode it (a browser
  /// guest, §3.1: Ogg in Safari). Reported `none` to the host and never
  /// fetched again this session; it never blocks the room (§6.3 waits only
  /// for `fetching`). Copy: "Can't play in this browser". Only a store that
  /// [JamMediaStore.verifiesDecode] produces it.
  unplayable,
}

/// Prefetch bookkeeping for one playlist item (§6.2/§6.3).
@immutable
class JamPrefetchState {
  const JamPrefetchState({
    this.phase = JamPrefetchPhase.queued,
    this.progress = 0,
    this.path,
    this.error,
    this.failures = 0,
    this.willRetry = false,
  });

  /// The distinct "not part of the fetch window" state.
  const JamPrefetchState.notQueued() : this(phase: JamPrefetchPhase.notQueued);

  /// Where the item is in the prefetch pipeline.
  final JamPrefetchPhase phase;

  /// Download progress in [0, 1].
  final double progress;

  /// The item's [JamMediaStore] ref — natively its cache file's path — set
  /// once the item is fully fetched and sha256-verified (and, where the
  /// store [JamMediaStore.verifiesDecode], decoded once), or found already
  /// sitting in the store.
  final String? path;

  /// The last fetch error for this item, if any. Kept while re-queued so UIs
  /// can render "retrying".
  final String? error;

  /// Consecutive failed fetches of this item since it last entered the fetch
  /// window, the connection was re-established, or [JamGuestEngine.retryFetch].
  final int failures;

  /// [JamPrefetchPhase.failed] with an automatic retry scheduled. False on a
  /// failed item means it gave up: offer [JamGuestEngine.retryFetch].
  final bool willRetry;

  /// Whether the item is fully fetched and playable.
  bool get ready => path != null;

  @override
  String toString() =>
      'JamPrefetchState(${phase.name}'
      '${phase == JamPrefetchPhase.fetching ? ' $progress' : ''}'
      '${error == null ? '' : ', error: $error'}'
      '${failures == 0 ? '' : ', failures: $failures'}'
      '${willRetry ? ', retrying' : ''})';
}

/// Thrown by guest operations that need the host — an upload — while
/// requests cannot reach it ([JamGuestEngine.canSendCommands] false:
/// mid-reconnect, ended, or the host's phone asleep). Transport/queue
/// intents never throw this; they answer false instead.
class JamNotConnectedException implements Exception {
  const JamNotConnectedException(this.state, {this.hostAway = false});

  /// The connection state the operation found.
  final JamConnectionState state;

  /// Connected, but the host said it is away (§3.5): its app may be
  /// suspended, and a request would sit in its socket until it wakes.
  final bool hostAway;

  @override
  String toString() => hostAway
      ? 'JamNotConnectedException: the host is away (its app may be asleep)'
      : 'JamNotConnectedException: not connected to the host (${state.name})';
}

/// One joined guest: session + clock sync + prefetch + synchronized playback.
///
/// On app resume the inherited lifecycle guard re-verifies playback sync
/// (see [JamEngine.handleLifecycleState]). Clock-sync freshness after a
/// background gap: a device that SLEPT (its monotonic clock stopped while
/// the host's ran on — detected as wall-clock time passing faster than
/// monotonic time, checked every second, on resume, and before any new
/// schedule) sends a fresh §4 ping burst and holds its output silent until
/// `ClockSync` has confirmed the jump and re-synced, accepted a few of the
/// burst's readings as consistent with its estimate (no jump: the clock is
/// fine), the connection was replaced, or — the fallback when the burst
/// proves nothing either way — [clockWakeTimeout] passed on a live
/// connection — rather than playing at a position off by the whole
/// sleep. A device that was audibly playing a moment before cannot have
/// slept (audio output keeps it awake): that gap is the wall clock being
/// stepped (NTP, a manual change), so output carries on and only new
/// schedules wait for the clock to be re-confirmed.
///
/// Create with [join]; release with [close]. The engine feeds every
/// authoritative snapshot into its [AudioSyncController] — holding the first
/// one back until the §4 clock-sync join burst lands, since scheduling needs
/// a session→local mapping — prefetches per its [prefetchPolicy] into its
/// [JamMediaStore], and resolves media for the controller from that store.
/// Natively the store is the persistent sha256-keyed [JamMediaCache]: files
/// are keyed by content hash, so rejoining a jam (or joining another jam
/// playing the same files) re-fetches nothing. In a browser it is memory
/// ([JamMemoryMediaStore]), and an item is `ready` (§6.3) only once it has
/// also decoded: the bytes are probed with [LocaljamAudio.probeDurationUs],
/// which decodes without touching playback, one item at a time in the
/// prefetch order (the current track, then the next). An item that will not
/// decode is [JamPrefetchPhase.unplayable], reported `none`, and dropped.
class JamGuestEngine extends JamEngine {
  JamGuestEngine._(
    this._session,
    this.player,
    this._store, {
    required this.prefetchPolicy,
    required this.hostGoneTimeout,
    required this.hostAwayTimeout,
    required this.fetchRetryBackoff,
    required this.maxFetchRetries,
    required this.clockWakeTimeout,
  }) {
    sync = AudioSyncController(
      player: player,
      sessionNowUs: () => _session.sessionNowUs,
      localNowUs: () => _session.localNowUs,
      sessionToLocalUs: (sessionUs) => _session.clock.hostToLocalUs(sessionUs),
      resolveMediaPath: _resolveMediaPath,
      // §4: schedule only on a trusted session clock, and re-schedule when
      // the estimator steps (needsHardResync) — holding output through a
      // discontinuity until the fresh join burst lands.
      clockReady: _clockTrusted,
      clockStepPending: () => _session.clock.needsHardResync,
      acknowledgeClockStep: () => _session.clock.acknowledgeHardResync(),
    );
    _hostAway.value = _session.hostAway;
    _lastPlanMediaId = _session.snapshot.mediaId;
    _sleepMarkWall = wallClock();
    _sleepMarkLocalUs = monotonicNowUs();
    _sleepWatch = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _checkForSleep(),
    );
    _subs = [
      _session.states.listen(_onSnapshot),
      _session.playlistUpdates.listen((_) => _reevaluatePrefetch()),
      _session.connectionStates.listen(_onConnectionState),
      _session.hostAwayChanges.listen(_onHostAwayChanged),
    ];
    _reevaluatePrefetch();
    // Late join (§5.3): converge on whatever the host is doing right now, as
    // soon as the session clock is usable.
    unawaited(_feedAfterClockSync());
  }

  /// Connects to the host in [joinUri] — either join form (§1): a
  /// `localjam://join?...` URI or the 1.2 `http://host:port/join#...` URL,
  /// read by [JoinLink] — wires up player + sync controller, and starts
  /// prefetching per [prefetchPolicy].
  ///
  /// [mediaStore] is where prefetched media lives (the engine owns it and
  /// disposes it on [close]). Without one, [mediaCacheDir] names a
  /// persistent sha256-keyed cache directory ([JamFileMediaStore]); without
  /// either, the platform default is used: natively
  /// `getApplicationCacheDirectory()/localjam_media` (`path_provider`),
  /// shared across sessions so rejoining a jam re-fetches nothing; in a
  /// browser a [JamMemoryMediaStore]. Override it in tests (or to relocate
  /// the cache). [cacheMaxBytes] caps the store (default: 1 GB on disk,
  /// [JamMemoryMediaStore.defaultMaxBytes] in a browser): after each completed
  /// fetch, least-recently-used files are evicted — never the current track
  /// or the rest of the prefetch window (the whole playlist with
  /// [JamPrefetchPolicy.prefetchAll]); an evicted item stops being ready and
  /// is fetched again when the room comes back to it. [backoff] shapes the
  /// session's reconnect schedule
  /// (§3.3). [hostGoneTimeout] bounds how long the engine keeps reconnecting
  /// before declaring the host gone and publishing
  /// [JamSessionEndReason.hostGone] on [sessionEnded];
  /// [hostAwayTimeout] replaces it while the host has said it is away
  /// (§3.5 — a phone host asleep in a pocket, which iOS suspends by design).
  ///
  /// A failed fetch of an item in the prefetch window is retried after
  /// [fetchRetryBackoff] (attempt-indexed, jittered), at most
  /// [maxFetchRetries] times in a row — then it stays
  /// [JamPrefetchPhase.failed] until [retryFetch], a reconnect, or it
  /// becoming the current track. [clockWakeTimeout] bounds how long output
  /// stays silent after a device sleep when the wake's ping burst shows
  /// neither a jump nor a clock that still agrees with its estimate (see
  /// the class docs); keep it above the session's liveness timeout (6 s), so
  /// a connection still up when it expires has demonstrably been hearing the
  /// host's pongs.
  ///
  /// Throws [JamRejectedException] if the host rejects the join (a kicked
  /// device gets [RejectReason.kicked]), [SocketException] if no host
  /// candidate is reachable, or [FormatException] if [joinUri] is neither
  /// join form.
  static Future<JamGuestEngine> join(
    Uri joinUri, {

    /// Display name announced to the room (§3.1). Defaults to the device's
    /// persistent quirky [JamIdentity.displayName] ("Neon Walrus").
    String? clientName,
    String clientKind = 'flutter',
    Directory? mediaCacheDir,
    JamMediaStore? mediaStore,
    JamPrefetchPolicy prefetchPolicy = const JamPrefetchPolicy(),
    int? cacheMaxBytes,
    JamBackoff? backoff,
    Duration hostGoneTimeout = const Duration(seconds: 90),
    Duration hostAwayTimeout = const Duration(minutes: 10),
    JamBackoff? fetchRetryBackoff,
    int maxFetchRetries = 5,
    Duration clockWakeTimeout = const Duration(seconds: 8),

    /// Stable per-device id announced in `hello` (§3.3), so a host replaces
    /// this device's previous slot instead of keeping a ghost of it in the
    /// roster. Defaults to the persistent [JamIdentity.clientId].
    String? clientId,
  }) async {
    final session = await JamGuestSession.connect(
      joinUri, // Either form; a FormatException for neither.
      clientName: clientName ?? await JamIdentity.displayName(),
      clientKind: clientKind,
      backoff: backoff,
      clientId: clientId ?? await JamIdentity.clientId(),
    );
    final JamMediaStore store;
    try {
      if (mediaStore != null) {
        store = mediaStore;
      } else if (mediaCacheDir != null) {
        await mediaCacheDir.create(recursive: true);
        store = JamFileMediaStore(
          JamMediaCache(mediaCacheDir, maxBytes: cacheMaxBytes ?? 1 << 30),
        );
      } else {
        store = await openDefaultMediaStore(maxBytes: cacheMaxBytes);
      }
    } catch (_) {
      await session.close();
      rethrow;
    }
    final engine = JamGuestEngine._(
      session,
      LocaljamAudio(),
      store,
      prefetchPolicy: prefetchPolicy,
      hostGoneTimeout: hostGoneTimeout,
      hostAwayTimeout: hostAwayTimeout,
      fetchRetryBackoff:
          fetchRetryBackoff ??
          JamBackoff(
            initialDelay: const Duration(seconds: 1),
            maxDelay: const Duration(seconds: 30),
          ),
      maxFetchRetries: maxFetchRetries,
      clockWakeTimeout: clockWakeTimeout,
    )..joinUri = joinUri;
    await engine.restorePersistedNudge();
    await engine.startSessionGuards();
    return engine;
  }

  final JamGuestSession _session;
  final JamMediaStore _store;

  /// Where this guest keeps prefetched media (§6.2).
  JamMediaStore get mediaStore => _store;

  /// Items (by sha256) that decoded at least once this session — where the
  /// store [JamMediaStore.verifiesDecode] — so a lookup hit needs no second
  /// probe.
  final Set<String> _decoded = {};

  /// Items (by sha256) this device cannot decode: never fetched again this
  /// session, always [JamPrefetchPhase.unplayable].
  final Set<String> _undecodable = {};

  /// The ref a decode probe is reading right now, whose `blob:` URL must
  /// outlive any release.
  String? _probingRef;

  /// The join URI this engine joined with, in whichever form it was given
  /// ([JoinLink] reads both) — kept so a UI
  /// can offer "rejoin" after a terminal end (host suspension, §10 host
  /// death) by calling [join] again with it; the sha-keyed cache makes the
  /// rejoin re-fetch nothing.
  late final Uri joinUri;

  /// What this guest prefetches, and in what order (§6.2).
  final JamPrefetchPolicy prefetchPolicy;

  /// How long the session may sit in [JamConnectionState.reconnecting]
  /// before the engine gives up, stops the retries, and publishes
  /// [JamSessionEndReason.hostGone] on [sessionEnded]. A reconnect that
  /// succeeds within the window cancels the countdown.
  final Duration hostGoneTimeout;

  /// How long the session may sit in [JamConnectionState.reconnecting]
  /// while the host has said it is away (§3.5, [hostAway]) — its phone is
  /// asleep, not dead — before the engine gives up with
  /// [JamSessionEndReason.hostGone].
  final Duration hostAwayTimeout;

  /// Delay before each automatic retry of a failed fetch (attempt-indexed:
  /// the n-th consecutive failure waits `delay(n - 1)`, jittered).
  final JamBackoff fetchRetryBackoff;

  /// Automatic retries of one failed fetch before it waits for
  /// [retryFetch], a reconnect, or becoming the current track.
  final int maxFetchRetries;

  /// After a device sleep, the longest output stays silent before the clock
  /// is trusted again on a live connection (see the class docs). Normally
  /// the wake's ping burst ends the wait within about a second — a real
  /// sleep's jump is confirmed on its second reading, and a clock that did
  /// not jump has [_wakeConfirmSamples] readings accepted in ~0.3 s — so
  /// this is the fallback for a burst whose readings the estimator could
  /// neither accept nor act on (a network much worse than before).
  final Duration clockWakeTimeout;

  Timer? _hostGoneTimer;

  /// Running while the session is reconnecting: how long it has been.
  Stopwatch? _reconnectingFor;

  final ValueNotifier<bool> _hostAway = EngineValueNotifier<bool>(false);

  /// Whether the host last said it is away (§3.5): its app is in the
  /// background and its OS may suspend it. While true a dropped connection
  /// waits [hostAwayTimeout], not [hostGoneTimeout]; requests are not sent
  /// ([canSendCommands]), since they would sit in a sleeping host's socket
  /// until it wakes; and the UI should say "the host's phone is asleep"
  /// instead of "reconnecting…".
  ValueListenable<bool> get hostAway => _hostAway;

  RejectReason? _lastRejectReason;
  ErrorCode? _lastFatalErrorCode;

  /// The reason the host gave for refusing this guest's reconnect (§3.1),
  /// when that is what ended the session: [JamSessionEndReason.rejected]
  /// (or [JamSessionEndReason.kicked] for [RejectReason.kicked]). Null
  /// otherwise — including while the session lives. Set before
  /// [sessionEnded] publishes, so a listener can read it.
  ///
  /// The reason decides what to tell the person, and whether a manual
  /// rejoin with the same link could ever work: [RejectReason.badToken]
  /// (the room restarted under a new token) and [RejectReason.version] (one
  /// of you needs an update) never can; [RejectReason.full] may once
  /// someone leaves. A first join that is refused never gets this far —
  /// [join] throws [JamRejectedException] carrying the same reason.
  RejectReason? get lastRejectReason => _lastRejectReason;

  /// The code of the fatal `error` (§8) that ended the session, if one did —
  /// today that is [ErrorCode.kicked] (§5.6; [JamSessionEndReason.kicked]).
  /// Null otherwise: a fatal error the session recovered from by
  /// reconnecting did not end anything. Set before [sessionEnded] publishes.
  ErrorCode? get lastFatalErrorCode => _lastFatalErrorCode;

  /// Wall clock used to notice device sleep; a seam for tests.
  @visibleForTesting
  static DateTime Function() wallClock = DateTime.now;

  /// Wall time passing this much faster than monotonic time between two
  /// looks means the device slept (its monotonic clock stops while asleep;
  /// §4 "Clock jumps").
  static const Duration _sleepGapThreshold = Duration(milliseconds: 200);

  /// How recently the player must have been read producing audio for a
  /// wall/monotonic gap to count as a wall-clock step, not a sleep: a bit
  /// more than two drift checks.
  static const Duration _audibleWindow = Duration(milliseconds: 2500);

  /// While connected but not yet synchronized (the join burst in flight,
  /// under a second), how often the first snapshot's feed re-checks.
  static const Duration _clockPollInterval = Duration(milliseconds: 50);

  Timer? _sleepWatch;
  late DateTime _sleepMarkWall;
  late int _sleepMarkLocalUs;

  /// Set after a detected wake until the session clock is trusted again:
  /// the clock it distrusts, its [ClockSync.acceptedSampleCount] at the
  /// wake, when the distrust began, and how long it may last at most.
  ({ClockSync clock, int acceptedAtWake, Stopwatch since, Duration timeout})?
  _wake;

  /// How many readings the distrusted clock must accept after a wake before
  /// it is trusted again (§4): accepted means consistent with the estimate,
  /// and after a real sleep every fresh reading disagrees with it by the
  /// whole sleep — the jump is confirmed instead. The wake's burst (8 pings
  /// 100 ms apart) supplies them in ~0.3 s. More than one, because a pong
  /// that was already in flight when the device fell asleep reads the
  /// pre-sleep clock and is accepted without proving anything.
  static const int _wakeConfirmSamples = 3;

  /// After a gap while audibly playing — almost certainly a wall-clock step —
  /// the longest new schedules wait for the wake's ping burst (8 pings over
  /// 0.7 s) before the clock is trusted again; normally its accepted
  /// readings end the wait sooner.
  static const Duration _wallStepConfirmWindow = Duration(milliseconds: 1500);

  /// Per-item consecutive fetch failures, and the retries they scheduled.
  final Map<String, int> _fetchFailures = {};
  final Map<String, Timer> _fetchRetryTimers = {};

  @override
  final LocaljamAudio player;

  @override
  late final AudioSyncController sync;

  late final List<StreamSubscription<Object?>> _subs;

  /// The mediaId with a fetch currently in flight, if any. In-flight fetches
  /// are never cancelled by re-prioritization — a newly-current track just
  /// goes next.
  String? _fetchingId;

  /// The item behind [_fetchingId]: eviction must spare its destination
  /// even once it has left the window (or the playlist) mid-transfer.
  MediaItem? _fetchingItem;

  /// The last `media_status` state reported to the host for each mediaId on
  /// the CURRENT connection, so repeated prefetch re-evaluations don't spam
  /// duplicate reports (§6.3 says nothing about dedup — this is purely to
  /// avoid flooding the control plane). Cleared on every reconnect (see
  /// [_onConnectionState]), since PROTOCOL.md §3.3 has the host forget all
  /// readiness on drop — a resumed connection must re-report everything
  /// this guest already considers ready.
  final Map<String, MediaFetchState> _lastReportedMediaState = {};

  /// Re-entrancy guard for [_pumpPrefetch]: doubles as "one fetch in flight
  /// at a time".
  bool _pumping = false;

  /// The snapshot mediaId the current prefetch plan was built for; a change
  /// re-evaluates the plan.
  String? _lastPlanMediaId;

  bool _waitingForClock = false;
  bool _closed = false;

  /// Set once the session reached a terminal end ([_end]); [close] is still
  /// the app's to call.
  bool _ended = false;

  final ValueNotifier<Map<String, JamPrefetchState>> _prefetchStates =
      EngineValueNotifier<Map<String, JamPrefetchState>>(const {});
  final ValueNotifier<double?> _uploadProgress = EngineValueNotifier<double?>(
    null,
  );

  /// Prefetch state per mediaId (§6.2). The map is replaced (never mutated)
  /// on every change, so `ValueListenableBuilder` and plain listeners both
  /// work. Items outside the policy's fetch window report
  /// [JamPrefetchPhase.notQueued].
  ValueListenable<Map<String, JamPrefetchState>> get prefetchStates =>
      _prefetchStates;

  /// Progress of an in-flight [addMedia] upload in [0, 1]; null while no
  /// upload is running.
  ValueListenable<double?> get uploadProgress => _uploadProgress;

  // --- Session mirror ----------------------------------------------------

  /// The session name from `welcome` (§3.1).
  @override
  String get sessionName => _session.sessionName;

  /// The session id from `welcome` (§3.1).
  @override
  String get sessionId => _session.sessionId;

  /// This guest's peer id (§3.1); stable across resumed reconnects (§3.3).
  @override
  String get selfPeerId => _session.selfPeerId;

  @override
  PlaybackSnapshot get snapshot => _session.snapshot;

  @override
  Stream<PlaybackSnapshot> get states => _session.states;

  @override
  List<MediaItem> get playlist => _session.playlist;

  @override
  Stream<List<MediaItem>> get playlistUpdates => _session.playlistUpdates;

  /// Other peers currently in the session (excluding this guest, and never
  /// including the host — see [hostPeer]).
  @override
  List<PeerInfo> get peers => _session.peers;

  /// The host as a person (§3.1 `welcome.host`): the reserved host peer id
  /// plus its display name. Null against a host that shares no identity.
  @override
  PeerInfo? get hostPeer => _session.hostPeer;

  @override
  String? localPathFor(MediaItem item) =>
      prefetchStates.value[item.mediaId]?.path;

  /// Presence changes (§3.2).
  Stream<JamPeerEvent> get peerEvents => _session.peerEvents;

  @override
  JamPermissions get permissions => _session.permissions;

  @override
  Stream<JamPermissions> get permissionUpdates => _session.permissionUpdates;

  /// Host error reports (§8): transient denials (`not_allowed`) a UI can
  /// snackbar, and fatal ones ([sessionEnded] is the terminal signal).
  Stream<ErrorMessage> get errors => _session.errors;

  /// The current connection state (§3.3 reconnects included).
  JamConnectionState get connectionState => _session.connectionState;

  /// Connection state transitions.
  Stream<JamConnectionState> get connectionStates => _session.connectionStates;

  /// Whether the current connection's clock has synchronized (§4). Snapshots
  /// are held back from the sync controller until this turns true.
  bool get clockSynced => _session.clock.isSynchronized;

  /// The guest→host clock offset estimate (µs) as last applied, null while
  /// unsynchronized. Diagnostics only: the mapping is a line that slews and
  /// extrapolates along the clocks' skew (§4) — map instants with
  /// [clock]'s `hostToLocalUs`/`localToHostUs`, never with this.
  int? get clockOffsetUs => _session.clock.offsetUs;

  /// The current connection's clock estimator (§4), for diagnostics (RTT
  /// floor, skew). Replaced on every reconnect.
  ClockSync get clock => _session.clock;

  /// Whether requests can reach the host right now: connected, not ended,
  /// and the host not [hostAway] — a host that said it is going to sleep
  /// may already be suspended, and a request would wait in its socket until
  /// it wakes (a "play" landing minutes later surprises everyone). While
  /// false the intents and `request…` methods return false without sending,
  /// and [addMedia] throws [JamNotConnectedException]. Changes are announced
  /// on [connectionStates] and [hostAway].
  bool get canSendCommands =>
      !_closed &&
      _session.connectionState == JamConnectionState.connected &&
      !_session.hostAway;

  @override
  int? get sessionNowUsOrNull =>
      _session.clock.isSynchronized ? _session.sessionNowUs : null;

  // --- Requests (§5.2, §5.6) ----------------------------------------------
  //
  // Every request answers whether it was handed to the connection: true when
  // sent, false when it could not be ([canSendCommands]: mid-reconnect,
  // ended, the host asleep). They never throw for that, so a button handler
  // or a lock-screen command racing a Wi-Fi blip cannot crash anything. A
  // sent request may still be refused by the host (§5.6 `not_allowed`, on
  // [errors]); the authoritative answer is the next state broadcast. The
  // [JamEngine] intents (transportPlay, queueMove, ...) are the same
  // requests, written so one UI drives host and guest alike.

  /// Runs one §5.2/§5.6 send if it can reach the host; false when not (or
  /// when the connection dropped between the check and the send).
  Future<bool> _request(Future<void> Function() send) async {
    if (!canSendCommands) return false;
    try {
      await send();
      return true;
    } on StateError {
      return false; // The session left `connected` under us.
    }
  }

  /// Asks the host to start playback (§5.2). False when not sent.
  Future<bool> requestPlay() => _request(_session.requestPlay);

  /// Asks the host to pause playback (§5.2). False when not sent.
  Future<bool> requestPause() => _request(_session.requestPause);

  /// Asks the host to seek to [positionUs] (§5.2). False when not sent.
  Future<bool> requestSeek(int positionUs) =>
      _request(() => _session.requestSeek(positionUs));

  /// Asks the host to select [mediaId] (§5.2). False when not sent.
  Future<bool> requestSetMedia(String mediaId) =>
      _request(() => _session.requestSetMedia(mediaId));

  /// Asks the host to skip to the next queue item (§5.2). False when not
  /// sent.
  Future<bool> requestNext() => _request(_session.requestNext);

  /// Asks the host to skip to the previous queue item (§5.2). False when not
  /// sent.
  Future<bool> requestPrevious() => _request(_session.requestPrevious);

  /// Asks the host to move [mediaId] to queue position [toIndex] (§5.6).
  /// False when not sent.
  Future<bool> requestQueueMove(String mediaId, int toIndex) =>
      _request(() => _session.requestQueueMove(mediaId, toIndex));

  /// Asks the host to remove [mediaId] from the queue (§5.6). Your own
  /// contributions are always removable; others' need
  /// [JamCapability.editQueue]. False when not sent.
  Future<bool> requestQueueRemove(String mediaId) =>
      _request(() => _session.requestQueueRemove(mediaId));

  // --- Intents (guest = §5.2/§5.6 requests) -------------------------------

  /// Ends a local output suspension, and asks the host to play unless the
  /// room already is (a play while playing would re-anchor everyone; true
  /// without sending then). False once the session ended.
  @override
  Future<bool> transportPlay() async {
    if (_closed || _ended) return false;
    await resumeLocalOutput();
    if (snapshot.status == PlaybackStatus.playing) return true;
    if (!canSendCommands) return false;
    // This device asked to hear the room: wherever its sound goes now is
    // where it wants it, even if its headphones came out while paused.
    sync.acceptCurrentRoute();
    return requestPlay();
  }

  @override
  Future<bool> transportPause() => requestPause();

  @override
  Future<bool> transportNext() => requestNext();

  @override
  Future<bool> transportPrevious() => requestPrevious();

  @override
  Future<bool> transportSeek(int positionUs) => requestSeek(positionUs);

  /// False, sending nothing, for an id not in the playlist.
  @override
  Future<bool> transportSetMedia(String mediaId) async =>
      _inPlaylist(mediaId) && await requestSetMedia(mediaId);

  /// False, sending nothing, for an id not in the playlist.
  @override
  Future<bool> queueMove(String mediaId, int toIndex) async =>
      _inPlaylist(mediaId) && await requestQueueMove(mediaId, toIndex);

  /// False, sending nothing, for an id not in the playlist.
  @override
  Future<bool> queueRemove(String mediaId) async =>
      _inPlaylist(mediaId) && await requestQueueRemove(mediaId);

  bool _inPlaylist(String mediaId) =>
      playlist.any((item) => item.mediaId == mediaId);

  // --- Guest uploads (§6.4) --------------------------------------------------

  /// Contributes [file] to the jam: reads its duration from the file's
  /// headers ([LocaljamAudio.probeDurationUs], which leaves playback alone),
  /// then streams it to the host via `POST /media` (§6.4). The host derives the mediaId from
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
  /// Throws [HttpException] on a rejected upload (401/413/...),
  /// [TimeoutException] when the host stops reading or answering, or
  /// [JamNotConnectedException] while requests cannot reach the host
  /// ([canSendCommands]).
  ///
  /// Prefer [addMedia], which says whether the add actually added anything.
  Future<MediaItem> addMediaFile(File file, {String? name}) async =>
      (await addMedia(file, name: name)).item;

  /// [addMediaFile], plus what the add did (§6.4).
  ///
  /// Uploads are idempotent on content hash: re-adding a file the jam already
  /// has is answered 200 with the existing item and broadcasts no playlist,
  /// so from the app's side it is a no-op that looks exactly like a failure.
  /// `localjam_net`'s `uploadMedia` collapses the host's 200 and 201 into one
  /// `MediaItem`, so the distinction is recovered here: the playlist is
  /// snapshotted *before* the upload — the broadcast for a genuinely new item
  /// can beat the HTTP response — and an id that was already in it means the
  /// queue already had these bytes.
  @override
  Future<JamAddResult> addMedia(File file, {String? name}) async {
    if (!canSendCommands) throw _notConnected();
    final knownBefore = {for (final item in playlist) item.mediaId};
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
    // Seeding needs files: only the file-backed store has any to seed from
    // (a browser guest does not upload, WEB_GUEST.md D5).
    final store = _store;
    final cached = store is JamFileMediaStore
        ? await store.cache.seed(file, described)
        : null;
    if (!canSendCommands) throw _notConnected();
    _uploadProgress.value = 0;
    try {
      final MediaItem item;
      try {
        item = await _session.uploadMedia(
          file,
          kind: MediaKind.audio,
          name: name,
          mime: mime,
          durationUs: durationUs,
          onProgress: (progress) {
            if (!_closed) _uploadProgress.value = progress;
          },
        );
      } on StateError {
        // The session left `connected` between the check and the send.
        if (canSendCommands) rethrow;
        throw _notConnected();
      }
      if (_closed) {
        return JamAddResult(
          item,
          knownBefore.contains(item.mediaId)
              ? JamAddOutcome.alreadyQueued
              : JamAddOutcome.added,
        );
      }
      if (cached != null) {
        _setPrefetch(
          item.mediaId,
          JamPrefetchState(
            phase: JamPrefetchPhase.ready,
            progress: 1,
            path: cached.path,
          ),
        );
      }
      await sync.notifyMediaAvailable(item.mediaId);
      unawaited(_evictCache());
      return JamAddResult(
        item,
        knownBefore.contains(item.mediaId)
            ? JamAddOutcome.alreadyQueued
            : JamAddOutcome.added,
      );
    } finally {
      if (!_closed) _uploadProgress.value = null;
    }
  }

  JamNotConnectedException _notConnected() => JamNotConnectedException(
    _session.connectionState,
    hostAway:
        _session.connectionState == JamConnectionState.connected &&
        _session.hostAway,
  );

  /// The §5.5 duration from the file's headers — never through
  /// [LocaljamAudio.load], which would replace (and, with a snapshot landing
  /// mid-probe, play) the current track.
  Future<int?> _probeDurationUs(String path) async {
    try {
      return await player.probeDurationUs(path);
    } catch (_) {
      return null; // Native side unavailable; upload without a duration.
    }
  }

  // --- Artwork (§6.5) --------------------------------------------------------

  /// In-flight/completed artwork loads by artworkId, so concurrent UI
  /// requests for the same cover share one fetch. Values are never removed —
  /// artwork is small and deduped per album — but a failed load stores null
  /// and is retried on the next call.
  final Map<String, Future<Uint8List?>> _artworkLoads = {};

  /// Artwork bytes for [item] (§6.5): from the persistent cache when
  /// present (artwork ids are content-derived, so a disk hit needs no
  /// verification), else fetched from the host and cached. Null when the
  /// item has no artwork or the fetch fails (e.g. mid-reconnect) — a
  /// failure is not sticky, the next call retries. Never throws.
  @override
  Future<Uint8List?> artworkFor(MediaItem item) {
    final artworkId = item.artworkId;
    if (artworkId == null) return Future.value(null);
    final pending = _artworkLoads[artworkId];
    if (pending != null) return pending;
    final load = _loadArtwork(artworkId);
    _artworkLoads[artworkId] = load;
    return load;
  }

  Future<Uint8List?> _loadArtwork(String artworkId) async {
    try {
      final cached = await _store.readArtwork(artworkId);
      if (cached != null) return cached;
    } catch (_) {
      // Miss: fetch from the host.
    }
    try {
      final bytes = await _session.fetchArtwork(artworkId);
      try {
        await _store.writeArtwork(artworkId, bytes);
      } catch (_) {
        // Cache write failure: the bytes are still usable this session.
      }
      return bytes;
    } catch (_) {
      _artworkLoads.remove(artworkId); // Not sticky: retry next call.
      return null;
    }
  }

  // --- Snapshot plumbing ----------------------------------------------------

  void _onSnapshot(PlaybackSnapshot snapshot) {
    if (_closed) return;
    // A wake noticed here, not at the next 1 Hz look: a state frame that
    // lands first must not be scheduled on the pre-sleep mapping (§4).
    _checkForSleep();
    if (snapshot.mediaId != _lastPlanMediaId) {
      _lastPlanMediaId = snapshot.mediaId;
      // Only the current track's `blob:` URL is needed (a browser's `load`).
      _releaseUrlsExceptCurrent();
      _reevaluatePrefetch();
      // The track the room just moved to is worth another try even if it
      // failed while it was only "up next".
      final current = snapshot.mediaId;
      if (current != null &&
          prefetchStates.value[current]?.phase == JamPrefetchPhase.failed) {
        retryFetch(current);
      }
    }
    if (_session.clock.isSynchronized) {
      unawaited(sync.onSnapshot(snapshot));
    } else {
      // Fresh connection (initial join or reconnect): the §4 ping burst is
      // still in flight. Feed the latest snapshot once it lands.
      unawaited(_feedAfterClockSync());
    }
  }

  /// Feeds the latest snapshot to the sync controller once the session
  /// clock is synchronized. Polls only while connected — the join burst
  /// lands within about a second — and otherwise waits for the connection
  /// to change: a reconnect can take minutes, and nothing syncs without one.
  Future<void> _feedAfterClockSync() async {
    if (_waitingForClock) return;
    _waitingForClock = true;
    try {
      while (!_closed && !_session.clock.isSynchronized) {
        final state = _session.connectionState;
        if (state == JamConnectionState.closed ||
            state == JamConnectionState.failed) {
          return;
        }
        if (state == JamConnectionState.connected) {
          await Future<void>.delayed(_clockPollInterval);
        } else {
          await _nextConnectionChange();
        }
      }
      if (_closed) return;
      await sync.onSnapshot(_session.snapshot);
    } finally {
      _waitingForClock = false;
    }
  }

  /// Completes on the next connection-state transition, when the session
  /// closes, or after a few seconds (a safety net: the caller re-checks).
  Future<void> _nextConnectionChange() {
    final changed = Completer<void>();
    void done() {
      if (!changed.isCompleted) changed.complete();
    }

    final timer = Timer(const Duration(seconds: 5), done);
    final sub = _session.connectionStates.listen(
      (_) => done(),
      onDone: done,
      onError: (Object _) => done(),
    );
    return changed.future.whenComplete(() {
      timer.cancel();
      unawaited(sub.cancel());
    });
  }

  // --- Session clock trust (§4) ---------------------------------------------

  /// Whether the session clock may be scheduled on: synchronized, and — after
  /// a device sleep — re-validated. The pre-sleep offset is wrong by the
  /// whole sleep until `ClockSync` notices, so until then nothing new is
  /// scheduled (and, after a real sleep, output stays silent). Trust returns
  /// when the estimator confirmed the jump (it raised `needsHardResync`; the
  /// sync controller re-schedules on it), when it accepted
  /// [_wakeConfirmSamples] readings taken since the wake (they agree with
  /// the estimate, so the clock did not jump: the gap was the wall clock's,
  /// or too short to matter), or when the connection was replaced (a fresh
  /// join burst knows nothing stale). [clockWakeTimeout] is the upper bound
  /// when the burst shows neither: it re-trusts the clock only with the same
  /// connection still live — a connection that died meanwhile is no
  /// evidence, and trust waits for its replacement.
  bool _clockTrusted() {
    _checkForSleep();
    final clock = _session.clock;
    if (!clock.isSynchronized) return false;
    final wake = _wake;
    if (wake == null) return true;
    // The count restarts whenever the estimate is re-seeded. Below its value
    // at the wake, it restarted since — everything it counts is post-wake.
    // (One that restarted and climbed back past it is undercounted, which
    // only errs toward waiting.)
    final accepted = clock.acceptedSampleCount;
    final acceptedSinceWake = accepted >= wake.acceptedAtWake
        ? accepted - wake.acceptedAtWake
        : accepted;
    if (!identical(clock, wake.clock) ||
        clock.needsHardResync ||
        acceptedSinceWake >= _wakeConfirmSamples ||
        (wake.since.elapsed >= wake.timeout &&
            _session.connectionState == JamConnectionState.connected)) {
      _wake = null;
      return true;
    }
    return false;
  }

  /// Notices a device sleep: wall time ran on while the monotonic clock —
  /// which the session-clock mapping is built on — stood still. Checked every
  /// second, on app resume (before playback is re-verified), on every state
  /// frame, and before every new schedule; each look compares against the
  /// previous one, so it is cheap and only a jump between two looks counts.
  void _checkForSleep() {
    if (_closed || _ended) return;
    final wall = wallClock();
    final localUs = monotonicNowUs();
    final gapUs =
        wall.difference(_sleepMarkWall).inMicroseconds -
        (localUs - _sleepMarkLocalUs);
    _sleepMarkWall = wall;
    _sleepMarkLocalUs = localUs;
    if (gapUs <= _sleepGapThreshold.inMicroseconds) return;
    // A fresh §4 burst re-checks the mapping in under a second; the steady
    // schedule alone would take two pings, seconds apart.
    _session.resyncClock();
    final audible = sync.confirmedPlayingWithin(_audibleWindow);
    _wake = (
      clock: _session.clock,
      acceptedAtWake: _session.clock.acceptedSampleCount,
      since: Stopwatch()..start(),
      timeout: audible && _wallStepConfirmWindow < clockWakeTimeout
          ? _wallStepConfirmWindow
          : clockWakeTimeout,
    );
    if (audible) {
      // Audio was demonstrably coming out a moment ago, and a device that
      // plays audio does not sleep: the wall clock was stepped (NTP, a
      // time-zone or manual change). What plays keeps playing; only new
      // schedules wait, briefly, for the burst to re-confirm the clock.
      debugPrint(
        'localjam: wall clock stepped ~${gapUs ~/ 1000} ms while playing; '
        're-checking the session clock',
      );
      return;
    }
    debugPrint(
      'localjam: device slept ~${gapUs ~/ 1000} ms; holding output until '
      'the session clock re-syncs',
    );
    // Not from inside whoever noticed (the controller may be mid-schedule,
    // asking clockReady): the next microtask silences what still plays on
    // the stale mapping.
    scheduleMicrotask(() {
      if (!_closed) unawaited(sync.holdForClock());
    });
  }

  @override
  Future<void> onAppResumed() async {
    // Before the base re-verifies playback: a re-verify on the pre-sleep
    // offset is exactly the wrong-position restart this prevents.
    _checkForSleep();
    await super.onAppResumed();
  }

  // --- Session-end contract ------------------------------------------------

  void _onConnectionState(JamConnectionState state) {
    if (_closed) return;
    switch (state) {
      case JamConnectionState.connected:
        // A reconnect succeeded: the host is alive, cancel the countdown.
        _hostGoneTimer?.cancel();
        _hostGoneTimer = null;
        _reconnectingFor = null;
        // §3.3: the host forgot every readiness report on the drop. Clear
        // the dedup map so the re-emitted welcome playlist (which follows
        // this transition — see JamGuestSession._reconnectLoop) triggers
        // fresh `ready` reports for everything already local.
        _lastReportedMediaState.clear();
        // A fresh connection is a fresh chance for everything that failed:
        // retry it now rather than waiting out the backoff.
        _retryFailedFetchesNow();
      case JamConnectionState.reconnecting:
        // The flag that picks the timeout is the one the host last sent
        // before the drop (§3.5): `host_status` only travels on a live
        // connection, so it cannot change during the countdown.
        _reconnectingFor ??= Stopwatch()..start();
        _armHostGoneTimer();
      case JamConnectionState.failed:
        // Terminal, and which terminal matters to the copy on screen: the
        // host said goodbye (§3.4), removed this guest (§5.6 fatal `kicked`,
        // or a reconnect refused because this device was kicked meanwhile),
        // or refused the (re)join (§3.1 bad_token/full/version/unknown — a
        // reject is never retried). Which reject, or which fatal error, is
        // kept for the copy: `rejected` alone cannot tell a full room (worth
        // another try later) from a version mismatch (never).
        _lastRejectReason = _session.lastRejectReason;
        // A refused reconnect still holds the dropped connection, whose own
        // fatal error (if any) only caused the drop, not the end.
        if (_lastRejectReason == null && !_session.hostEnded) {
          _lastFatalErrorCode = _session.lastFatalError?.code;
        }
        _end(switch (_session) {
          _ when _session.hostEnded => JamSessionEndReason.hostEnded,
          _ when _session.lastFatalError?.code == ErrorCode.kicked =>
            JamSessionEndReason.kicked,
          _ when _session.lastRejectReason == RejectReason.kicked =>
            JamSessionEndReason.kicked,
          _ => JamSessionEndReason.rejected,
        });
      case JamConnectionState.closed:
        // Only reachable via a local close (ours or _end's); the reason has
        // already been published by whoever initiated it.
        break;
    }
  }

  void _onHostAwayChanged(bool away) {
    if (_closed) return;
    _hostAway.value = away;
  }

  /// Arms the host-gone countdown for the current reconnect: the remainder
  /// of [hostAwayTimeout] when the host said it is away, of
  /// [hostGoneTimeout] otherwise.
  void _armHostGoneTimer() {
    _hostGoneTimer?.cancel();
    final since = _reconnectingFor ??= Stopwatch()..start();
    final limit = _session.hostAway ? hostAwayTimeout : hostGoneTimeout;
    final remaining = limit - since.elapsed;
    _hostGoneTimer = Timer(
      remaining.isNegative ? Duration.zero : remaining,
      _onHostGoneTimeout,
    );
  }

  void _onHostGoneTimeout() {
    _hostGoneTimer = null;
    if (_closed) return;
    if (_session.connectionState != JamConnectionState.reconnecting) return;
    _end(JamSessionEndReason.hostGone);
  }

  /// Publishes the terminal [reason] (first writer wins), stops the
  /// underlying session's reconnect retries, and stops everything this
  /// guest ran for the session. The music belongs to the host's session
  /// (§10): an ended guest — the host gone or done, this device removed or
  /// refused — falls silent at once, whatever it was playing, and lets go of
  /// the keep-alive (on Android the foreground service and its wake/Wi-Fi
  /// locks), the OS media card, the lifecycle observer, history and every
  /// timer. What a terminal screen reads (snapshot, playlist, peers,
  /// prefetch state, [lastRejectReason]) stays readable until [close].
  void _end(JamSessionEndReason reason) {
    _ended = true;
    _hostGoneTimer?.cancel();
    _hostGoneTimer = null;
    _reconnectingFor = null;
    _cancelFetchRetries();
    _sleepWatch?.cancel();
    _sleepWatch = null;
    _wake = null;
    // Before anyone hears about the end: nothing may reach playAt after it.
    unawaited(sync.halt());
    publishSessionEnd(reason);
    if (_session.connectionState == JamConnectionState.reconnecting ||
        _session.connectionState == JamConnectionState.connected) {
      unawaited(_session.close());
    }
    unawaited(stopSessionGuards());
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

  /// The cache paths of [wanted] and of the [inFlight] fetch — each item's
  /// file and its `.part` — as [fileFor] names them: what the file-backed
  /// store ([JamFileMediaStore.protectedPathsFor]) spares when it evicts.
  @visibleForTesting
  static Set<String> protectedCachePathsFor(
    Iterable<MediaItem> wanted, {
    MediaItem? inFlight,
    required File? Function(MediaItem item) fileFor,
  }) => JamFileMediaStore.protectedPathsFor(
    wanted,
    inFlight: inFlight,
    fileFor: fileFor,
  );

  /// Trims the store to its cap, then un-readies whatever that evicted.
  /// Spared: everything the policy wants local — the current track and the
  /// ahead window, or with `prefetchAll` the whole playlist (evicting what
  /// the policy then fetches straight back would only churn the network) —
  /// plus the in-flight fetch.
  Future<void> _evictCache() async {
    final Set<String> deleted;
    try {
      deleted = await _store.evict(
        keep: _targetItems(),
        inFlight: _fetchingItem,
      );
    } catch (_) {
      return; // Best-effort: a cache we cannot trim is merely big.
    }
    _onCachedFilesGone(deleted);
  }

  /// The controller's media resolver: what the store resolves a ready
  /// item's ref to — natively its cache file, in a browser a `blob:` URL
  /// minted now (§6.2, WEB_GUEST.md D7). Checked, because a ready item's
  /// bytes can still vanish (natively: evicted by another session sharing
  /// the cache, cleared by the OS under storage pressure). Bytes that are
  /// gone un-ready their item, which is fetched again, and resolve to null:
  /// the controller waits for [AudioSyncController.notifyMediaAvailable]
  /// instead of failing the track as undecodable.
  Future<String?> _resolveMediaPath(String mediaId) async {
    final path = prefetchStates.value[mediaId]?.path;
    if (path == null) return null;
    String? resolved;
    try {
      resolved = await _store.resolve(path);
    } catch (_) {
      resolved = null;
    }
    if (resolved != null) return resolved;
    _onCachedFilesGone({path});
    return null;
  }

  /// Lets go of every minted `blob:` URL except the current track's (and a
  /// probe's in flight): only `load` needs one, and only for the current
  /// item. The bytes stay. A no-op natively.
  void _releaseUrlsExceptCurrent() {
    final current = _session.snapshot.mediaId;
    for (final entry in prefetchStates.value.entries) {
      final ref = entry.value.path;
      if (ref == null || entry.key == current || ref == _probingRef) continue;
      _store.release(ref);
    }
  }

  /// Items whose cache files are gone ([paths]) are not ready any more: back
  /// to queued inside the fetch window — so the pump fetches them again —
  /// or to notQueued outside it, and the host hears `none` (§6.3): its
  /// readiness gate must not count on a file this guest no longer has.
  void _onCachedFilesGone(Set<String> paths) {
    if (_closed || paths.isEmpty) return;
    final targetIds = {for (final t in _targetItems()) t.mediaId};
    final states = prefetchStates.value;
    final next = Map<String, JamPrefetchState>.of(states);
    final gone = <String>[];
    for (final entry in states.entries) {
      final path = entry.value.path;
      if (path == null || !paths.contains(path)) continue;
      gone.add(entry.key);
      next[entry.key] = targetIds.contains(entry.key)
          ? const JamPrefetchState()
          : const JamPrefetchState.notQueued();
    }
    if (gone.isEmpty) return;
    _prefetchStates.value = Map.unmodifiable(next);
    for (final id in gone) {
      _reportMediaStatus(id, MediaFetchState.none);
    }
    unawaited(_pumpPrefetch());
  }

  /// Rebuilds the prefetch plan: window items become queued (ready ones stay
  /// ready, the in-flight one stays fetching), everything else reports the
  /// distinct notQueued state. A failed item inside the window keeps its
  /// failed state — its own backoff timer re-queues it, or it waits for
  /// [retryFetch] / a reconnect — so a busy playlist cannot turn the backoff
  /// into a retry storm. An item leaving the window forgets its failures.
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
      } else if (_undecodable.contains(item.sha256)) {
        _forgetFailures(id);
        next[id] = _unplayableState;
      } else if (targetIds.contains(id)) {
        next[id] = existing?.phase == JamPrefetchPhase.failed
            ? existing!
            : JamPrefetchState(
                error: existing?.error,
                failures: existing?.failures ?? 0,
              );
      } else {
        _forgetFailures(id);
        next[id] = const JamPrefetchState.notQueued();
      }
    }
    // Items that left the playlist altogether.
    for (final id in previous.keys) {
      if (!next.containsKey(id)) _forgetFailures(id);
    }
    _prefetchStates.value = Map.unmodifiable(next);
    // Re-announce anything already ready (e.g. after a reconnect cleared the
    // dedup map below) and scan the WHOLE playlist — not just this window —
    // for cache hits the host doesn't know about yet (a rejoining guest may
    // have everything cached already).
    _reportReadyStates();
    unawaited(_reportCachedReadinessForAll());
    unawaited(_pumpPrefetch());
  }

  /// Fetches [mediaId] again now: clears its failure count and any pending
  /// backoff, re-queues it, and runs the pipeline. For a "Couldn't get this
  /// track — Retry" control on a [JamPrefetchPhase.failed] item. Returns
  /// false when there is nothing to retry: the item is ready, in flight,
  /// unplayable here, outside the prefetch window, or not in the playlist.
  bool retryFetch(String mediaId) {
    if (_closed || _ended) return false;
    final state = prefetchStates.value[mediaId];
    if (state == null || state.ready || mediaId == _fetchingId) return false;
    if (state.phase == JamPrefetchPhase.unplayable) return false;
    if (!_targetItems().any((i) => i.mediaId == mediaId)) return false;
    _forgetFailures(mediaId);
    _setPrefetch(mediaId, JamPrefetchState(error: state.error));
    unawaited(_pumpPrefetch());
    return true;
  }

  /// After a reconnect: every failed item in the window is retried at once
  /// with a fresh count — the failure may well have been the connection.
  void _retryFailedFetchesNow() {
    final states = prefetchStates.value;
    final targetIds = {for (final t in _targetItems()) t.mediaId};
    var changed = false;
    final next = Map<String, JamPrefetchState>.of(states);
    for (final entry in states.entries) {
      if (entry.value.phase != JamPrefetchPhase.failed) continue;
      _forgetFailures(entry.key);
      if (!targetIds.contains(entry.key)) continue;
      next[entry.key] = JamPrefetchState(error: entry.value.error);
      changed = true;
    }
    if (changed) _prefetchStates.value = Map.unmodifiable(next);
    unawaited(_pumpPrefetch());
  }

  void _forgetFailures(String mediaId) {
    _fetchFailures.remove(mediaId);
    _fetchRetryTimers.remove(mediaId)?.cancel();
  }

  void _cancelFetchRetries() {
    for (final timer in _fetchRetryTimers.values) {
      timer.cancel();
    }
    _fetchRetryTimers.clear();
  }

  /// Sends `ready` to the host for every mediaId currently marked
  /// [JamPrefetchState.ready] in [prefetchStates] — a no-op per id beyond
  /// the first call, thanks to [_lastReportedMediaState], except right
  /// after a reconnect clears that dedup map (§3.3: the host forgot).
  void _reportReadyStates() {
    for (final entry in prefetchStates.value.entries) {
      if (entry.value.ready) {
        _reportMediaStatus(entry.key, MediaFetchState.ready);
      }
    }
  }

  /// Checks every playlist item — not just the fetch window — against the
  /// local cache and reports `ready` (§6.3) for any hit that isn't already
  /// tracked, without ever triggering a network fetch for an out-of-window
  /// item. This is what lets a rejoining guest that already has the whole
  /// playlist cached from a previous session announce full readiness
  /// immediately, instead of waiting for the prefetch window to reach each
  /// item one at a time.
  Future<void> _reportCachedReadinessForAll() async {
    for (final item in _session.playlist) {
      if (_closed) return;
      final id = item.mediaId;
      if ((prefetchStates.value[id]?.ready ?? false) || id == _fetchingId) {
        continue;
      }
      // Bytes that have not decoded here yet are the pipeline's to probe
      // (§3.1: a browser reports `ready` only once an item decoded).
      if (_store.verifiesDecode && !_decoded.contains(item.sha256)) continue;
      String? cached;
      try {
        cached = await _store.lookup(item);
      } catch (_) {
        continue; // Cache probe failed: leave it to the ordinary pipeline.
      }
      if (cached == null || _closed) continue;
      // The pump may have resolved this item (via _fetchOne) while the
      // lookup above was in flight; re-check before clobbering its state.
      if ((prefetchStates.value[id]?.ready ?? false) || id == _fetchingId) {
        continue;
      }
      _forgetFailures(id);
      _setPrefetch(
        id,
        JamPrefetchState(
          phase: JamPrefetchPhase.ready,
          progress: 1,
          path: cached,
        ),
      );
      _reportMediaStatus(id, MediaFetchState.ready);
      unawaited(sync.notifyMediaAvailable(id));
    }
  }

  /// Reports [state] for [mediaId] to the host (§6.3) unless it's exactly
  /// what was last reported on this connection — see
  /// [_lastReportedMediaState].
  void _reportMediaStatus(String mediaId, MediaFetchState state) {
    if (_lastReportedMediaState[mediaId] == state) return;
    _lastReportedMediaState[mediaId] = state;
    _session.sendMediaStatus(mediaId, state);
  }

  /// Runs the fetch pipeline: one fetch in flight at a time, always picking
  /// the highest-priority queued item under the CURRENT plan — so a track
  /// that became current mid-fetch preempts the remaining queue without
  /// cancelling the in-flight transfer. Idle while not connected: queued
  /// items wait for the reconnect instead of failing one after another.
  Future<void> _pumpPrefetch() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (!_closed &&
          _session.connectionState == JamConnectionState.connected) {
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
        _fetchingItem = next;
        try {
          await _fetchOne(next);
        } finally {
          _fetchingId = null;
          _fetchingItem = null;
        }
      }
    } finally {
      _pumping = false;
    }
  }

  /// Fetches one item into the store — unless the store already holds it
  /// (natively: right name, right size), in which case the network is
  /// skipped entirely, the item reports ready immediately, and the host is
  /// told directly via [JamGuestSession.sendMediaStatus] (§6.3) since no
  /// fetch happens to report it for us. Where the store
  /// [JamMediaStore.verifiesDecode], the bytes must also decode once
  /// ([_settle]) before the item is ready.
  Future<void> _fetchOne(MediaItem item) async {
    final id = item.mediaId;
    try {
      final cached = await _store.lookup(item);
      if (cached != null) {
        if (_closed) return;
        _forgetFailures(id);
        await _settle(item, cached);
        return;
      }
    } catch (_) {
      // Cache probe failed: fall through to the network.
    }
    if (_closed) return;
    if (!_store.accepts(item)) {
      // §6.1 says a MediaItem carries a sha256; one that does not is not
      // fetchable (there is nothing to verify the bytes against) and never
      // touches the store. No retry would change that.
      _setPrefetch(
        id,
        const JamPrefetchState(
          phase: JamPrefetchPhase.failed,
          error: 'malformed sha256',
        ),
      );
      return;
    }
    final failuresBefore = _fetchFailures[id] ?? 0;
    _setPrefetch(
      id,
      JamPrefetchState(
        phase: JamPrefetchPhase.fetching,
        failures: failuresBefore,
      ),
    );
    final write = _store.open(item);
    try {
      // The fetch streams into the store's sink (natively a `.part` file,
      // never whole files in memory), verifies the sha256, and reports
      // media_status upstream (§6.3): `fetching` with progress, `none` when
      // it gives up — and `ready`, unless the bytes still have to decode
      // here. It is bounded: a host that stops answering mid-transfer
      // surfaces as a TimeoutException instead of hanging the pipeline, and
      // a connection that breaks mid-body leaves nothing behind.
      await _session.fetchMediaToSink(
        id,
        write.sink,
        reportReady: !_store.verifiesDecode,
        onProgress: (progress) {
          if (_closed) return;
          _setPrefetch(
            id,
            JamPrefetchState(
              phase: JamPrefetchPhase.fetching,
              progress: progress,
              failures: failuresBefore,
            ),
          );
        },
      );
      final ref = await write.commit();
      if (_closed) return;
      _forgetFailures(id);
      if (_store.verifiesDecode) {
        // The fetch said `fetching` and nothing since: the decode decides.
        _lastReportedMediaState[id] = MediaFetchState.fetching;
      } else {
        // The fetch already sent `ready` on the wire (§6.3); just record it
        // so the next _reportReadyStates() doesn't resend it.
        _lastReportedMediaState[id] = MediaFetchState.ready;
      }
      await _settle(item, ref);
      await _evictCache();
    } on Object catch (e) {
      try {
        await write.discard();
      } catch (_) {
        // Nothing to undo.
      }
      if (_closed) return;
      // Whatever the host last heard of this fetch, the fetch itself said
      // `none` when it gave up after the host's `200` (§6.2); a refusal
      // before it never said `fetching`.
      _lastReportedMediaState[id] = MediaFetchState.none;
      _onFetchFailed(id, e);
    }
  }

  /// Makes a stored item [JamPrefetchPhase.ready] — after a decode check
  /// where the store [JamMediaStore.verifiesDecode] — reports it (§6.3) and
  /// tells the controller. An item that will not decode becomes
  /// [JamPrefetchPhase.unplayable] instead: its bytes are dropped, the host
  /// hears `none`, and it is never fetched again this session.
  Future<void> _settle(MediaItem item, String ref) async {
    final id = item.mediaId;
    if (_store.verifiesDecode && !_decoded.contains(item.sha256)) {
      _setPrefetch(
        id,
        const JamPrefetchState(phase: JamPrefetchPhase.fetching, progress: 1),
      );
      final decodes = await _decodesHere(item, ref);
      if (_closed) return;
      if (decodes == null) {
        // The bytes left the store mid-probe: fetch them again.
        _setPrefetch(id, const JamPrefetchState());
        return;
      }
      if (!decodes) {
        _undecodable.add(item.sha256);
        try {
          await _store.remove(ref);
        } catch (_) {
          // Best effort: eviction gets it later.
        }
        _setPrefetch(id, _unplayableState);
        _reportMediaStatus(id, MediaFetchState.none);
        return;
      }
      _decoded.add(item.sha256);
    }
    _setPrefetch(
      id,
      JamPrefetchState(phase: JamPrefetchPhase.ready, progress: 1, path: ref),
    );
    _reportMediaStatus(id, MediaFetchState.ready);
    await sync.notifyMediaAvailable(id);
  }

  /// Whether [item]'s bytes ([ref]) decode on this device: a full decode
  /// through [LocaljamAudio.probeDurationUs], which never touches the loaded
  /// track or playback (the web player keeps one decoded buffer, D7, and
  /// this one is dropped as soon as the probe returns). The `blob:` URL the
  /// probe read is released afterwards unless the item is the current track
  /// (whose `load` wants it). Null when the bytes are gone from the store.
  Future<bool?> _decodesHere(MediaItem item, String ref) async {
    final String? url;
    try {
      url = await _store.resolve(ref);
    } catch (_) {
      return null;
    }
    if (url == null) return null;
    _probingRef = ref;
    int? durationUs;
    try {
      durationUs = await player.probeDurationUs(url);
    } catch (_) {
      durationUs = null;
    } finally {
      _probingRef = null;
      if (_session.snapshot.mediaId != item.mediaId) _store.release(ref);
    }
    if (durationUs != null && durationUs > 0) return true;
    // A failed probe of bytes that are no longer there says nothing about
    // the format.
    try {
      if (await _store.lookup(item) == null) return null;
    } catch (_) {
      return null;
    }
    return false;
  }

  static const JamPrefetchState _unplayableState = JamPrefetchState(
    phase: JamPrefetchPhase.unplayable,
    error: 'unsupported_format',
  );

  /// A fetch of [mediaId] failed. A dropped connection is not the item's
  /// fault: it goes back in the queue for the reconnect (which retries it at
  /// once). Otherwise the failure counts, and while retries remain one is
  /// scheduled after the backoff; after that the item waits for
  /// [retryFetch], a reconnect, or becoming the current track.
  void _onFetchFailed(String mediaId, Object error) {
    if (_session.connectionState != JamConnectionState.connected) {
      _setPrefetch(
        mediaId,
        JamPrefetchState(
          error: '$error',
          failures: _fetchFailures[mediaId] ?? 0,
        ),
      );
      return;
    }
    final failures = (_fetchFailures[mediaId] ?? 0) + 1;
    _fetchFailures[mediaId] = failures;
    final willRetry = failures <= maxFetchRetries;
    _setPrefetch(
      mediaId,
      JamPrefetchState(
        phase: JamPrefetchPhase.failed,
        error: '$error',
        failures: failures,
        willRetry: willRetry,
      ),
    );
    if (!willRetry) return;
    _fetchRetryTimers.remove(mediaId)?.cancel();
    _fetchRetryTimers[mediaId] = Timer(
      fetchRetryBackoff.delay(failures - 1),
      () => _onFetchRetryDue(mediaId),
    );
  }

  void _onFetchRetryDue(String mediaId) {
    _fetchRetryTimers.remove(mediaId);
    if (_closed) return;
    final state = prefetchStates.value[mediaId];
    if (state == null || state.phase != JamPrefetchPhase.failed) return;
    if (!_targetItems().any((i) => i.mediaId == mediaId)) return;
    _setPrefetch(
      mediaId,
      JamPrefetchState(error: state.error, failures: state.failures),
    );
    unawaited(_pumpPrefetch());
  }

  void _setPrefetch(String mediaId, JamPrefetchState state) {
    _prefetchStates.value = Map.unmodifiable({
      ...prefetchStates.value,
      mediaId: state,
    });
  }

  // --- Teardown ----------------------------------------------------------------

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    publishSessionEnd(JamSessionEndReason.closedLocally);
    _hostGoneTimer?.cancel();
    _hostGoneTimer = null;
    _sleepWatch?.cancel();
    _sleepWatch = null;
    _cancelFetchRetries();
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
    try {
      await _store.dispose();
    } catch (_) {
      // Best effort: nothing else holds it.
    }
    _prefetchStates.dispose();
    _uploadProgress.dispose();
    _hostAway.dispose();
    disposeEngineState();
  }
}
