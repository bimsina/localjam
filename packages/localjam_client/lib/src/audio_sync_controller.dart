/// The sync engine shared by host and guest playback (PROTOCOL.md §5, §7).
///
/// [AudioSyncController] turns authoritative [PlaybackSnapshot]s into
/// sample-accurate scheduling calls on a [LocaljamAudio] player, walking the
/// full clock-domain chain:
///
/// ```
/// session µs (host monotonic clock, anchor.hostTimeUs)
///   │  sessionToLocalUs — identity on the host,
///   │                     ClockSync.hostToLocalUs on a guest
///   ▼
/// local µs (this process's Dart monotonic clock)
///   │  + calibration.offsetUs   (Dart clock → native audio clock, measured
///   │                            once per session via LocaljamAudio.calibrate,
///   │                            re-measured on hard resync)
///   │  - outputLatencyUs        (platform-reported route latency, §7)
///   │  - manualOffsetUs         (user "nudge"; positive = play earlier, §7)
///   ▼
/// native µs — handed to LocaljamAudio.playAt
/// ```
///
/// While playing, a 1 Hz drift loop compares the player's measured position
/// against the anchor formula and feeds a [DriftPolicy] (§5.4): slews are
/// applied as a bounded rate multiplier and restored after their duration;
/// hard resyncs recalibrate and re-schedule from the current anchor, backing
/// off when they keep coming (an output that cannot keep up re-anchors every
/// ~10 s, not every second). Every
/// check is published as a [DriftSample] for telemetry UIs. The same loop
/// watches the session-clock estimator (§4): a stepped offset re-schedules
/// from the current anchor, a clock discontinuity holds output until the
/// fresh join burst lands.
///
/// The OS can take this device's output away while the room plays on — a
/// call, unplugged headphones, another app grabbing audio focus, a native
/// failure. That is LOCAL: the room's timeline does not stop. The controller
/// then enters an "output suspended" state ([outputSuspension]) in which no
/// snapshot, nudge, or engine event schedules audio — on Android every
/// `playAt` re-requests audio focus, so a re-apply would steal it back from
/// the call — until the OS ends the interruption with its resume hint, or the
/// user calls [AudioSyncController.resumeLocalOutput], which re-anchors to
/// wherever the room is now.
///
/// The class is pure-ish Dart: every clock, the media-path resolver, and the
/// player are injected, so it is fully unit-testable with scripted time.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:localjam_audio/localjam_audio.dart';
import 'package:localjam_net/localjam_net.dart';

import 'engine_notifier.dart';

/// Resolves a protocol `mediaId` to a local file path [LocaljamAudio.load]
/// can open, or null when the media is not available (yet).
typedef MediaPathResolver = Future<String?> Function(String mediaId);

/// One drift self-check measurement (§5.4), published on
/// [AudioSyncController.driftSamples] for telemetry.
@immutable
class DriftSample {
  const DriftSample({
    required this.expectedUs,
    required this.actualUs,
    required this.action,
  });

  /// Anchor-derived expected media position (µs) at the check instant.
  final int expectedUs;

  /// Player-measured media position (µs) at the check instant.
  final int actualUs;

  /// Signed error: `actual - expected` (positive = we are ahead).
  int get errorUs => actualUs - expectedUs;

  /// What the [DriftPolicy] decided about this error.
  final DriftAction action;

  @override
  String toString() =>
      'DriftSample(expected: $expectedUs, actual: $actualUs, '
      'error: $errorUs, action: $action)';
}

/// Why this device's own audio output is suspended while the room plays on.
enum JamOutputSuspendReason {
  /// The OS interrupted output — a phone or FaceTime call, Siri, an alarm,
  /// another app taking audio focus for a while — or refused to let playback
  /// start (e.g. during a call). Ends by itself, re-anchoring to the room,
  /// when the OS ends the interruption with its "resume" hint. A refused
  /// start may never end, so this can also last until
  /// [AudioSyncController.resumeLocalOutput]. Copy: "Paused for a call".
  interruption,

  /// Another app owns the audio now and the OS will not hand it back: an
  /// interruption that ended without the "resume" hint, or one the OS
  /// announced as permanent (`interruptionBegan` with `shouldResume: false`
  /// — Android's permanent audio-focus loss, the user starting another
  /// player). Waits for [AudioSyncController.resumeLocalOutput]. Copy:
  /// "Another app is playing".
  focusLost,

  /// The output device went away while the room was playing: headphones
  /// unplugged, Bluetooth disconnected, Android "becoming noisy". The native
  /// side already stopped so audio never jumps to the loudspeaker. Ends by
  /// itself when that same device comes back (headphones plugged in again),
  /// otherwise on [AudioSyncController.resumeLocalOutput]. An unplug while
  /// the room is paused suspends nothing yet — nothing was audible — but the
  /// next start this device did not ask for itself (someone else pressed
  /// play) enters this state instead of playing on the new route, the
  /// loudspeaker as like as not; this device's own play
  /// ([AudioSyncController.acceptCurrentRoute]) plays where it is now.
  /// Copy: "Headphones disconnected".
  outputLost,

  /// Native playback failed ([JamOutputSuspension.errorCode]): a
  /// `playbackError` event (`decode_failed`, `writer_failed`,
  /// `engine_start_failed`, or a later code), a `playAt`/`load` the native
  /// side refused (`engine_error`, `engine_not_running`, `load_failed`, ...),
  /// or an engine that restarted right after every schedule
  /// (`engine_restart_loop`). Transient failures are retried with capped
  /// exponential backoff while [JamOutputSuspension.willRetry] is true; a
  /// file that cannot be decoded (`decode_failed`, `load_failed`,
  /// `unsupported_format`, `no_file`) is never retried for that item — the
  /// next item, or [AudioSyncController.resumeLocalOutput], tries again —
  /// and neither is a failure that outlasted the retries. Copy: "Playback
  /// error" (+ "retrying…" while [JamOutputSuspension.willRetry]).
  playbackError,
}

/// The local "output suspended" state: why, and for a native failure, its
/// machine-readable code and detail.
@immutable
class JamOutputSuspension {
  const JamOutputSuspension(
    this.reason, {
    this.errorCode,
    this.message,
    this.willRetry = false,
  });

  final JamOutputSuspendReason reason;

  /// [JamOutputSuspendReason.playbackError]: the native error code (an open
  /// set — treat unknown codes generically). Null otherwise.
  final String? errorCode;

  /// [JamOutputSuspendReason.playbackError]: human-readable detail, for logs.
  final String? message;

  /// [JamOutputSuspendReason.playbackError]: a retry is scheduled (capped
  /// exponential backoff) — "audio hiccup, retrying". False once the failure
  /// needs the user.
  final bool willRetry;

  /// Whether the controller may still resume by itself: an OS interruption
  /// that has not ended yet (it can end with the OS's resume hint), or a
  /// transient failure with a retry scheduled. Everything else — another
  /// app's audio, lost headphones (unless they come back), a failure that
  /// needs the user — waits for [AudioSyncController.resumeLocalOutput].
  /// Either way "Resume audio" is offered whenever a suspension is shown.
  bool get mayAutoResume =>
      reason == JamOutputSuspendReason.interruption || willRetry;

  @override
  bool operator ==(Object other) =>
      other is JamOutputSuspension &&
      other.reason == reason &&
      other.errorCode == errorCode &&
      other.message == message &&
      other.willRetry == willRetry;

  @override
  int get hashCode => Object.hash(reason, errorCode, message, willRetry);

  @override
  String toString() =>
      'JamOutputSuspension(${reason.name}'
      '${errorCode == null ? '' : ', $errorCode'}'
      '${message == null ? '' : ': $message'}'
      '${willRetry ? ', retrying' : ''})';
}

/// What the player reported finishing ([LocaljamAudioEventKind.playbackFinished]):
/// the media and the snapshot rev of the schedule it was following — what a
/// host hands to `JamHostServer.reportHostPlaybackFinished` (§5.5).
typedef JamPlaybackFinished = ({String mediaId, int snapshotRev});

/// Drives one [LocaljamAudio] player to follow authoritative
/// [PlaybackSnapshot]s. See the library docs for the time-conversion chain.
class AudioSyncController {
  AudioSyncController({
    required this.player,
    required this.sessionNowUs,
    required this.localNowUs,
    required this.sessionToLocalUs,
    required this.resolveMediaPath,
    this.driftPolicy = const DriftPolicy(),
    this.driftInterval = const Duration(seconds: 1),
    this.eventReapplyDebounce = const Duration(milliseconds: 250),
    this.failureBackoffBase = const Duration(milliseconds: 250),
    this.failureBackoffCap = const Duration(seconds: 30),
    this.maxFailureRetries = 6,
    this.clockReady,
    this.clockStepPending,
    this.acknowledgeClockStep,
    @visibleForTesting Stream<LocaljamAudioEvent>? events,
  }) {
    _eventSub = (events ?? player.events).listen(_onPlayerEvent);
  }

  /// The scheduled-audio player this controller drives.
  final LocaljamAudio player;

  /// Current session-clock time (host monotonic µs). On the host this is
  /// `monotonicNowUs`; on a guest, `client.sessionNowUs`.
  final int Function() sessionNowUs;

  /// Current local Dart monotonic time (µs) — the timebase
  /// [LocaljamAudio.calibrate] measures against.
  final int Function() localNowUs;

  /// Maps a session-clock instant to the local Dart monotonic clock.
  /// Identity on the host; `ClockSync.hostToLocalUs` on a guest.
  final int Function(int sessionUs) sessionToLocalUs;

  /// Resolves mediaIds to local file paths (host: the original file; guest:
  /// the prefetched temp file). Returning null parks the controller until
  /// [notifyMediaAvailable] is called for that id.
  final MediaPathResolver resolveMediaPath;

  /// Drift-correction thresholds (§5.4).
  final DriftPolicy driftPolicy;

  /// How often the drift loop self-checks while playing (§5.4: ~1 Hz).
  final Duration driftInterval;

  /// How long to coalesce a burst of player events (route change +
  /// interruption end + engine restart often arrive together) into a single
  /// recalibrate-and-re-apply.
  final Duration eventReapplyDebounce;

  /// First delay of the failure backoff: after `n` consecutive failures
  /// (a refused `playAt`/`load`, a `playbackError`, an engine that restarted
  /// right after being scheduled) the next automatic re-apply waits
  /// `failureBackoffBase × 2^(n-1)`, capped at [failureBackoffCap] — so a
  /// failure that repeats never becomes a re-apply loop. A schedule that
  /// proves healthy (the drift loop reads a position) resets the count.
  final Duration failureBackoffBase;

  /// Upper bound of the failure backoff.
  final Duration failureBackoffCap;

  /// Consecutive failures retried automatically; one more and the
  /// controller stays suspended ([JamOutputSuspendReason.playbackError],
  /// `willRetry: false`) until [resumeLocalOutput].
  final int maxFailureRetries;

  /// Whether [sessionNowUs]/[sessionToLocalUs] can be used right now — a
  /// guest's `ClockSync.isSynchronized`. Null (the host) means always.
  /// While false nothing new is scheduled; an existing schedule keeps
  /// playing unless [clockStepPending] says the mapping jumped.
  final bool Function()? clockReady;

  /// Whether the session-clock mapping stepped since it was last
  /// acknowledged — a guest's `ClockSync.needsHardResync` (§4). Checked by
  /// the drift loop: playback is re-scheduled from the current anchor (or,
  /// while [clockReady] is false — a clock discontinuity — held until the
  /// fresh join burst lands) and [acknowledgeClockStep] is called once a
  /// schedule built on the new mapping is issued.
  final bool Function()? clockStepPending;

  /// Clears [clockStepPending] — a guest's `ClockSync.acknowledgeHardResync`.
  final void Function()? acknowledgeClockStep;

  PlaybackSnapshot? _snapshot;
  NativeClockCalibration? _calibration;

  /// The media the native engine holds, as far as completed loads say, and
  /// its duration. Only trusted while [_loadsInFlight] is 0: a load that has
  /// been issued but has not answered yet is about to replace it.
  String? _loadedMediaId;
  int? _loadedMediaDurationUs;
  int _loadsInFlight = 0;
  String? _waitingForMediaId;
  int _manualOffsetUs = 0;
  int _generation = 0;
  bool _disposed = false;

  StreamSubscription<LocaljamAudioEvent>? _eventSub;

  /// The one pending automatic re-apply: a debounced engine event, or a
  /// failure retry. Never sooner than the failure backoff allows.
  Timer? _eventReapplyTimer;

  /// Consecutive playback failures since the last healthy schedule.
  int _failures = 0;

  /// The media a `decode_failed`-class error was reported for: not retried
  /// until the snapshot moves to another item or the user resumes.
  String? _undecodableMediaId;

  /// Local time (µs) the last `playAt` was accepted — an engine restart
  /// right after it is a failure of that schedule, not a route change.
  int? _lastPlayAtLocalUs;

  /// Set from `interruptionBegan` until `interruptionEnded` (or the user's
  /// [resumeLocalOutput]): the OS holds the audio — a call, another app.
  /// Tracked apart from the displayed [outputSuspension], which a lost
  /// device or a native failure may replace meanwhile: whatever is shown,
  /// nothing automatic may `playAt` while this is set (on Android every
  /// `playAt` re-requests audio focus from whoever took it).
  bool _osHoldsAudio = false;

  /// The current output route's id, as far as route events (or one query
  /// at the first schedule) say, and the route lost to an unplug — when it
  /// comes back, [JamOutputSuspendReason.outputLost] ends by itself.
  String? _currentRouteId;
  bool _routeQueried = false;
  int _routeEvents = 0;
  String? _lostRouteId;

  /// Set by an unplug while the room was not playing, until this device
  /// itself asks to hear the room ([acceptCurrentRoute], [resumeLocalOutput])
  /// or the device it lost ([_pausedLostRouteId], when known) comes back:
  /// the next start is then held as [JamOutputSuspendReason.outputLost]
  /// rather than played on whatever route is left.
  bool _routeLostWhilePaused = false;
  String? _pausedLostRouteId;

  /// Set when the output refused a slew rate (`bad_args`: an Android output
  /// that cannot time-stretch it): drift in the slew band is then corrected
  /// by re-anchoring instead. Cleared by a route change or engine restart.
  bool _slewUnsupported = false;

  /// Local time (µs) of the last re-anchor that stood in for a slew the
  /// output refused; they are rate-limited (see [_reanchorForDrift]).
  int? _lastDriftReanchorLocalUs;

  /// The fewest µs between two re-anchors standing in for slews. A re-anchor
  /// is an audible skip, and an error in the slew band (≤ the policy's
  /// hard-resync threshold, 50 ms) is tolerable for that long; drift past it
  /// is a hard resync, which is never rate-limited.
  static const int _slewFallbackIntervalUs = 10000000;

  /// Drift-triggered hard resyncs in a row, and the local time (µs) of the
  /// last one run — the backoff of [_takeHardResync].
  int _hardResyncStreak = 0;
  int? _lastHardResyncLocalUs;

  /// The wait after the first hard resync of a run before another; it
  /// doubles with each further one up to [_hardResyncBackoffCapUs].
  static const int _hardResyncBackoffBaseUs = 2000000;
  static const int _hardResyncBackoffCapUs = 10000000;

  /// How long without a hard resync before the next counts as a first one.
  static const int _hardResyncHealthyUs = 60000000;

  /// Set by [halt]: the session ended, and nothing may schedule audio again.
  bool _halted = false;

  /// Re-entrancy guard for [checkDriftNow]: a check whose re-apply outlasts
  /// the drift interval must not be superseded by the next tick's.
  bool _checking = false;

  /// Local time (µs) the drift loop last read a live position — audio
  /// demonstrably coming out. Cleared whenever the drift loop stops.
  int? _lastAudioConfirmedLocalUs;

  /// Latest route output latency (µs) learned from a player event; null means
  /// "query the player". Overwritten (possibly back to null) by every
  /// route/interruption/restart event so it always describes the CURRENT
  /// route.
  int? _routeOutputLatencyUs;

  /// The snapshot rev the player finished (end of file); no further playAt is
  /// issued for this rev — a fresh rev clears it.
  int? _finishedRev;

  /// The media and rev of the last schedule the player accepted — what a
  /// `playbackFinished` event refers to.
  JamPlaybackFinished? _scheduled;

  /// Set when a schedule could not be built on the session clock (not ready,
  /// or held across a discontinuity): the drift loop re-applies once it is.
  bool _pendingClockReapply = false;

  /// Output paused across a session-clock discontinuity (§4).
  bool _clockHeld = false;

  Timer? _driftTimer;
  Timer? _slewRestoreTimer;
  bool _slewing = false;
  int _slewCount = 0;
  int _resyncCount = 0;
  DriftSample? _lastSample;

  final StreamController<DriftSample> _samples =
      StreamController<DriftSample>.broadcast();
  final StreamController<JamOutputSuspension?> _suspensionChanges =
      StreamController<JamOutputSuspension?>.broadcast();
  final StreamController<String?> _routeChanges =
      StreamController<String?>.broadcast();
  final StreamController<JamPlaybackFinished> _playbackFinished =
      StreamController<JamPlaybackFinished>.broadcast();

  /// Duration (µs) of the current item's media, from [LocaljamAudio.load].
  /// Null until that item's load completes — including while its file is
  /// not available yet or would not load — so a UI should fall back to the
  /// item's declared duration (§5.5), never keep the previous item's.
  final ValueNotifier<int?> loadedDurationUs = EngineValueNotifier<int?>(null);

  /// Last player/platform error, for surfacing in the UI while the plugin's
  /// native side is still landing. Cleared on the next successful schedule.
  final ValueNotifier<String?> lastError = EngineValueNotifier<String?>(null);

  /// True when the current track ran to its end — either the player reported
  /// [LocaljamAudioEventKind.playbackFinished] or the anchor extrapolates
  /// to/past the loaded duration. While true the drift loop is stopped and no
  /// playAt is issued; a fresh snapshot that re-anchors within bounds
  /// (seek/new track) clears it and plays normally. UI can show "finished".
  final ValueNotifier<bool> trackFinished = EngineValueNotifier<bool>(false);

  /// Non-null while this device's output is suspended (see the library
  /// docs): the room plays on, this device is silent, and nothing schedules
  /// audio until the OS ends an interruption with its resume hint or
  /// [resumeLocalOutput] is called. Null while output follows the room.
  final ValueNotifier<JamOutputSuspension?> outputSuspension =
      EngineValueNotifier<JamOutputSuspension?>(null);

  /// Every change of [outputSuspension] (null = output follows the room
  /// again).
  Stream<JamOutputSuspension?> get outputSuspensionChanges =>
      _suspensionChanges.stream;

  /// Whether this device's output is suspended ([outputSuspension] non-null).
  bool get isOutputSuspended => outputSuspension.value != null;

  /// The new route's id ([LocaljamAudioEvent.routeId], null when the platform
  /// cannot tell) after every [LocaljamAudioEventKind.routeChanged] — what
  /// per-route state such as the §7 nudge is keyed on.
  Stream<String?> get routeChanges => _routeChanges.stream;

  /// Each time the player reports it played through to the end of the file
  /// (§5.5), with the media and snapshot rev of the schedule that finished.
  Stream<JamPlaybackFinished> get playbackFinished => _playbackFinished.stream;

  /// Every drift self-check while playing (§5.4), ~1 per [driftInterval].
  Stream<DriftSample> get driftSamples => _samples.stream;

  /// The most recent drift self-check, if any.
  DriftSample? get lastSample => _lastSample;

  /// How many slews have been initiated this session.
  int get slewCount => _slewCount;

  /// How many hard resyncs have been performed this session — drift- and
  /// clock-step-triggered alike.
  int get resyncCount => _resyncCount;

  /// Whether a slew is currently in flight.
  bool get isSlewing => _slewing;

  /// The snapshot the controller is currently following.
  PlaybackSnapshot? get snapshot => _snapshot;

  /// The rev of the snapshot whose media ran to its end ([trackFinished]),
  /// null while not finished. Compare it with the room's current rev: a
  /// newer rev (the room already advanced) is not finished, it is loading.
  int? get finishedSnapshotRev => trackFinished.value ? _finishedRev : null;

  /// Whether this device is audibly following a playing room right now:
  /// not suspended, not held for the clock, not finished, and the drift loop
  /// read a live position from the player within [window]. A device in that
  /// state cannot have been asleep (audio output keeps it awake), which is
  /// how a guest tells a wall-clock step from a device sleep.
  bool confirmedPlayingWithin(Duration window) {
    final confirmed = _lastAudioConfirmedLocalUs;
    return !_stopped &&
        confirmed != null &&
        _snapshot?.status == PlaybackStatus.playing &&
        outputSuspension.value == null &&
        !_clockHeld &&
        !trackFinished.value &&
        localNowUs() - confirmed <= window.inMicroseconds;
  }

  /// The cached Dart↔native clock calibration, if measured.
  NativeClockCalibration? get calibration => _calibration;

  /// The user "nudge" (§7): µs subtracted from the native schedule time, so a
  /// positive value makes audio come out *earlier* (compensates extra output
  /// latency, e.g. Bluetooth).
  int get manualOffsetUs => _manualOffsetUs;

  bool get _clockIsReady => clockReady?.call() ?? true;
  bool get _clockStepped => clockStepPending?.call() ?? false;

  /// Disposed, or [halt]ed: either way nothing schedules audio any more.
  bool get _stopped => _disposed || _halted;

  /// Whether [halt] stopped this controller for good.
  bool get isHalted => _halted;

  /// Sets the manual nudge and, if currently playing, re-schedules from the
  /// current anchor so the change takes effect immediately (not while output
  /// is suspended — the new value is used when it resumes).
  ///
  /// With [coalesce], an automatic re-apply already pending (the route
  /// change whose saved nudge this is, say) carries the new value instead:
  /// one re-anchor rather than two. A user's nudge leaves it false — it
  /// must be heard at once, whatever is pending.
  Future<void> setManualOffsetUs(int offsetUs, {bool coalesce = false}) async {
    if (_manualOffsetUs == offsetUs) return;
    _manualOffsetUs = offsetUs;
    if (coalesce && _eventReapplyTimer != null) return;
    if (_snapshot?.status == PlaybackStatus.playing) {
      await _apply();
    }
  }

  /// Feeds a new authoritative snapshot (from `welcome`, a `state` broadcast,
  /// or the host's own mutation).
  Future<void> onSnapshot(PlaybackSnapshot snapshot) async {
    if (_stopped) return;
    final previous = _snapshot;
    _snapshot = snapshot;
    if (snapshot.mediaId != previous?.mediaId) _onItemChanged(snapshot);
    await _apply();
  }

  /// A new item gets a clean slate: failures were about the old one, and a
  /// file the old item could not decode says nothing about this one.
  ///
  /// Its duration is published at once too: the engine's own when it
  /// already holds this item, otherwise none until its load lands. Leaving
  /// the previous item's in place until then showed the old track's length
  /// on this one — and kept showing it for good when this item's file never
  /// resolved or would not load.
  void _onItemChanged(PlaybackSnapshot snapshot) {
    loadedDurationUs.value =
        _loadsInFlight == 0 && _loadedMediaId == snapshot.mediaId
        ? _loadedMediaDurationUs
        : null;
    _failures = 0;
    final undecodable = _undecodableMediaId;
    if (undecodable == null || undecodable == snapshot.mediaId) return;
    _undecodableMediaId = null;
    final current = outputSuspension.value;
    if (current?.reason == JamOutputSuspendReason.playbackError) {
      _clearSuspension();
    }
  }

  /// Tells the controller that [mediaId] became locally available (e.g. a
  /// guest prefetch finished). Re-applies the current snapshot if playback
  /// was parked waiting on it.
  Future<void> notifyMediaAvailable(String mediaId) async {
    if (_waitingForMediaId == mediaId) {
      await _apply();
    }
  }

  /// Forgets which media is loaded in the [player] and re-applies the current
  /// snapshot, so the snapshot's media is reloaded (and re-scheduled from its
  /// anchor when playing).
  ///
  /// Only needed after loading a *different* file into the shared [player]
  /// behind the controller's back. Duration probes no longer do that — they
  /// go through [LocaljamAudio.probeDurationUs], which never touches the
  /// engine.
  Future<void> invalidateLoadedMedia() async {
    if (_stopped) return;
    _loadedMediaId = null;
    _loadedMediaDurationUs = null;
    loadedDurationUs.value = null;
    if (_snapshot != null) await _apply();
  }

  /// Ends a local output suspension and re-anchors to the room: playback is
  /// re-scheduled from the current snapshot's anchor (re-measuring the
  /// native clock), so this device joins the room wherever it is now, not
  /// where it was when output stopped. A no-op while output is not
  /// suspended.
  ///
  /// If the OS still holds the audio (a call in progress) the native side
  /// reports the refusal and the controller is suspended again.
  Future<void> resumeLocalOutput() async {
    if (_stopped || outputSuspension.value == null) return;
    _eventReapplyTimer?.cancel();
    _eventReapplyTimer = null;
    _failures = 0; // The user asked: a fresh set of retries.
    _undecodableMediaId = null;
    _forgetPausedLoss(); // This device asked to hear the room, here.
    // Taken at its word: if the OS still holds the audio, native refuses
    // this playAt and says so with a fresh interruptionBegan.
    _osHoldsAudio = false;
    _lostRouteId = null;
    _setSuspension(null);
    _calibration = null;
    await _apply();
  }

  /// This device itself asked to hear the room — its own play — so the
  /// route it is on now is where it wants the sound. Forgets an output
  /// device lost while the room was paused, which would otherwise hold the
  /// next start silent ([JamOutputSuspendReason.outputLost]): someone else
  /// pressing play must never bring this device's audio up on its
  /// loudspeaker after its headphones came out. Call it before the start
  /// lands. A no-op when nothing was lost.
  void acceptCurrentRoute() {
    if (_stopped) return;
    _forgetPausedLoss();
  }

  void _forgetPausedLoss() {
    _routeLostWhilePaused = false;
    _pausedLostRouteId = null;
  }

  /// Stops following the room for good: the session ended (§3.4, §10 — the
  /// music belongs to the host's session). Native output stops, every timer
  /// is cancelled, and nothing later — a snapshot, a player event, a nudge,
  /// [resumeLocalOutput] — schedules audio again. Unlike [dispose], the
  /// listenables stay readable (a terminal screen may still show them)
  /// until [dispose] releases them. Idempotent.
  Future<void> halt() async {
    if (_stopped) return;
    _halted = true;
    _generation++; // Nothing in flight may reach playAt.
    _stopDriftLoop();
    _cancelSlew();
    _eventReapplyTimer?.cancel();
    _eventReapplyTimer = null;
    await _stopNative();
  }

  /// Re-verifies playback after the app returns to the foreground.
  ///
  /// While backgrounded the OS may have suspended timers or killed the audio
  /// engine, so the drift loop's knowledge is stale. This runs one immediate
  /// check against the anchor formula:
  ///
  /// * snapshot `playing` but the player reports no position (audio died
  ///   while backgrounded), or the measured error exceeds the [driftPolicy]'s
  ///   hard-resync threshold → the snapshot is re-applied from scratch (the
  ///   native clock calibration is re-measured, playback re-scheduled from
  ///   the authoritative anchor);
  /// * smaller errors → one ordinary drift check ([checkDriftNow]), letting
  ///   the policy slew as usual;
  /// * `paused`/`loading`/`idle` snapshots → a cheap idempotent re-apply so
  ///   the loaded media and player mode still match the snapshot.
  ///
  /// Does nothing while output is suspended: silence is what the OS or the
  /// user asked for, and only [resumeLocalOutput] ends it.
  ///
  /// Either way the Dart↔native clock calibration is dropped, so the next
  /// schedule re-measures it: across a device sleep the Dart monotonic clock
  /// and the native audio clock need not have stopped alike (whether they do
  /// is platform behaviour), and a stale offset would misplace every
  /// schedule by the difference.
  Future<void> reverifySync() async {
    if (_stopped) return;
    _calibration = null;
    final snapshot = _snapshot;
    if (snapshot == null || outputSuspension.value != null) return;
    // No trustworthy session clock (a guest re-syncing after a reconnect or
    // a device sleep): nothing to verify against, and nothing may be
    // scheduled on a stale mapping. The drift loop takes over once it is.
    if (!_clockIsReady) return;
    if (snapshot.status != PlaybackStatus.playing) {
      await _apply();
      return;
    }
    if (trackFinished.value) return;
    int? actualUs;
    try {
      actualUs = await player.positionUs();
    } catch (_) {
      actualUs = null; // Player unreachable: treat as stale.
    }
    if (_stopped) return;
    final int expectedUs;
    try {
      expectedUs = snapshot.positionAt(sessionNowUs());
    } catch (_) {
      // Session clock unknown (a guest mid-reconnect): nothing to verify
      // against yet — the snapshot is re-fed once the clock re-syncs.
      return;
    }
    // The anchor ran past the end while backgrounded: the track is over.
    final durationUs = loadedDurationUs.value;
    if (durationUs != null && expectedUs >= durationUs) {
      _enterTrackFinished();
      return;
    }
    final stale =
        actualUs == null ||
        (actualUs - expectedUs).abs() > driftPolicy.hardResyncAboveUs;
    if (stale) {
      await _apply();
    } else {
      await checkDriftNow();
    }
  }

  // --- Player events (interruptions, route changes, end of file) ----------
  //
  // The native contract (localjam_audio README, "Events"): interruptions and
  // a lost output device STOP native output and nothing native restarts it;
  // engine restarts and plain route changes leave it to us to re-schedule.

  void _onPlayerEvent(LocaljamAudioEvent event) {
    if (_stopped) return;
    switch (event.kind) {
      case LocaljamAudioEventKind.interruptionBegan:
        // A call, Siri, another app's focus — or a playAt the OS refused,
        // which may never be followed by interruptionEnded. An OS that
        // already knows it will not hand the audio back (Android's
        // permanent focus loss) says so with shouldResume: false.
        _osHoldsAudio = true;
        _suspend(
          JamOutputSuspension(
            event.shouldResume == false
                ? JamOutputSuspendReason.focusLost
                : JamOutputSuspendReason.interruption,
          ),
        );
      case LocaljamAudioEventKind.interruptionEnded:
        _osHoldsAudio = false;
        _routeOutputLatencyUs = event.outputLatencyUs;
        _calibration = null;
        final current = outputSuspension.value;
        if (current == null) {
          // An end we never saw begin: re-apply, as for any engine event.
          _scheduleEventReapply();
        } else if (current.reason == JamOutputSuspendReason.interruption) {
          // Native never resumes by itself — the room moved on — so the
          // re-anchor is ours to do, when the OS says it is appropriate. No
          // hint at all (desktop) is taken as yes.
          if (event.shouldResume == false) {
            _setSuspension(
              const JamOutputSuspension(JamOutputSuspendReason.focusLost),
            );
          } else {
            _setSuspension(null);
            _scheduleEventReapply();
          }
        } else {
          // Lost output, a native failure or declined focus outlived the
          // interruption that happened meanwhile: they wait for the user.
        }
      case LocaljamAudioEventKind.routeChanged:
        _routeOutputLatencyUs = event.outputLatencyUs;
        _calibration = null;
        _slewUnsupported = false; // A new output may time-stretch fine.
        final previousRouteId = _currentRouteId;
        _currentRouteId = event.routeId;
        _routeEvents++;
        if (!_routeChanges.isClosed) _routeChanges.add(event.routeId);
        if (!event.oldDeviceUnavailable &&
            _routeLostWhilePaused &&
            event.routeId != null &&
            event.routeId == _pausedLostRouteId) {
          // The device lost while the room was paused is back before anyone
          // played: the next start plays on it, as if it never left.
          _forgetPausedLoss();
        }
        if (event.oldDeviceUnavailable) {
          _onOutputLost(previousRouteId);
        } else if (outputSuspension.value?.reason ==
                JamOutputSuspendReason.outputLost &&
            event.routeId != null &&
            event.routeId == _lostRouteId) {
          // The device that went away is back (headphones plugged in again,
          // Bluetooth reconnected): this is where the user was listening, so
          // rejoin the room wherever it is now. Still silent if the OS holds
          // the audio meanwhile — the interruption's end re-applies.
          _lostRouteId = null;
          _clearSuspension();
          if (outputSuspension.value == null) _scheduleEventReapply();
        } else if (outputSuspension.value == null) {
          // Playback continues on the new route; re-schedule with its latency
          // — debounced, since a route change usually restarts the engine too.
          _scheduleEventReapply();
        }
      case LocaljamAudioEventKind.engineRestarted:
        _routeOutputLatencyUs = event.outputLatencyUs;
        _calibration = null;
        _slewUnsupported = false;
        // The schedule the engine held is gone: nothing to measure until the
        // re-apply below re-schedules — and a position read meanwhile must
        // not pass for a healthy schedule.
        _stopDriftLoop();
        _cancelSlew();
        if (outputSuspension.value != null) break;
        final scheduledAt = _lastPlayAtLocalUs;
        if (scheduledAt != null &&
            localNowUs() - scheduledAt < _restartAfterPlayAtUs) {
          // The engine fell over right after we scheduled it: more likely
          // the schedule itself than a route change (Android reports decode
          // failures this way). Count it, so a repeat backs off instead of
          // looping, and give up once it outlasts the retries.
          _failures++;
          if (_failures > maxFailureRetries) {
            _failPlayback(
              'engine_restart_loop',
              'the audio engine restarted right after every schedule',
            );
            break;
          }
        }
        _scheduleEventReapply();
      case LocaljamAudioEventKind.playbackError:
        // Output is stopped. Retried with backoff when it may be transient;
        // never for a file that cannot be decoded — that would fail again on
        // every re-apply, forever.
        _failures++;
        _failPlayback(
          event.code ?? 'unknown',
          event.message,
          mediaId: _scheduled?.mediaId ?? _snapshot?.mediaId,
        );
        unawaited(_stopNative());
      case LocaljamAudioEventKind.playbackFinished:
        _onPlaybackFinished();
    }
  }

  /// An engine restart this soon after an accepted `playAt` counts as a
  /// failure of that schedule — and a schedule only proves healthy (the
  /// failure count resets) once it has played for longer than this.
  static const int _restartAfterPlayAtUs = 2000000;

  /// Native codes that mean THIS FILE cannot be played here: never retried
  /// for the item (§ localjam_audio README error codes). A file that is
  /// merely missing is re-resolved first (see [_ensureLoaded]) — a guest
  /// re-fetches an evicted cache file — so these only stick to a file that
  /// is there and still will not load.
  static const Set<String> _itemFatalCodes = {
    'decode_failed',
    'load_failed',
    'unsupported_format',
    'no_file',
  };

  /// The output device went away ([LocaljamAudioEvent.oldDeviceUnavailable];
  /// [previousRouteId] was the route in use). Native already stopped so
  /// audio never jumps to the speaker; a re-apply now would put it there.
  /// That includes one already debounced or in flight: on Apple platforms
  /// the engine restart this same route change causes can arrive FIRST (the
  /// two notifications are not ordered), so its re-apply is cancelled here,
  /// and an explicit stop follows any playAt already sent.
  ///
  /// Only a room that is playing (or starting) suspends at once. With the
  /// room paused nothing was audible, so nothing is shown — but the loss is
  /// remembered: the next start this device did not ask for itself is held
  /// as [JamOutputSuspendReason.outputLost] (see [_apply]) rather than
  /// played on whatever route is left, until this device plays
  /// ([acceptCurrentRoute]) or the lost device comes back.
  void _onOutputLost(String? previousRouteId) {
    final status = _snapshot?.status;
    if (status == PlaybackStatus.playing || status == PlaybackStatus.loading) {
      // Android re-reports the unplug for a playAt it holds back; the device
      // to wait for is still the first one lost.
      if (outputSuspension.value?.reason != JamOutputSuspendReason.outputLost) {
        _lostRouteId = previousRouteId;
      }
      _suspend(const JamOutputSuspension(JamOutputSuspendReason.outputLost));
    } else {
      // Re-reported unplugs keep the first device lost, as above.
      if (!_routeLostWhilePaused) _pausedLostRouteId = previousRouteId;
      _routeLostWhilePaused = true;
    }
    unawaited(_stopNative());
  }

  /// A start this device did not ask for, after its output device went away
  /// while the room was paused: held as [JamOutputSuspendReason.outputLost]
  /// — waiting for the same device to come back, or for "Resume audio" —
  /// instead of playing on the new route.
  void _holdStartForLostRoute() {
    _lostRouteId = _pausedLostRouteId;
    _forgetPausedLoss();
    _suspend(const JamOutputSuspension(JamOutputSuspendReason.outputLost));
  }

  /// A playback failure ([code]), counted in [_failures] by the caller:
  /// suspends output and, when it may be transient and retries remain,
  /// schedules the retry after the backoff. A file that cannot be decoded is
  /// remembered so it is not retried until the item changes.
  ///
  /// [mediaId] is the media that failed: the snapshot's for a refused
  /// load/schedule, the last schedule's for a native event. A decode
  /// failure of media the room already moved away from says nothing about
  /// the current item, so it is retried like any transient failure.
  void _failPlayback(String code, String? message, {String? mediaId}) {
    lastError.value =
        'playback error $code${message == null ? '' : ': $message'}';
    final itemFatal =
        _itemFatalCodes.contains(code) &&
        mediaId != null &&
        mediaId == _snapshot?.mediaId;
    if (itemFatal) {
      _undecodableMediaId = mediaId;
    } else if (_osHoldsAudio) {
      // The OS holds the audio (a call): output is stopped either way, and
      // the interruption's end re-applies from scratch. A retry now would
      // playAt into the call — the interruption stays what is shown.
      _suspend(const JamOutputSuspension(JamOutputSuspendReason.interruption));
      return;
    }
    final retry = !itemFatal && _failures <= maxFailureRetries;
    final next = JamOutputSuspension(
      JamOutputSuspendReason.playbackError,
      errorCode: code,
      message: message,
      willRetry: retry,
    );
    _suspend(next);
    // _suspend keeps a suspension that needs the user over one that would
    // clear itself (unplugged headphones stay unplugged): no retry then.
    if (retry && outputSuspension.value == next) {
      _scheduleReapply(_failureDelay());
    }
  }

  /// Stops native output, for when it must be silent whatever was in flight.
  Future<void> _stopNative() async {
    try {
      await player.stop();
    } catch (_) {
      // Already stopped, or no native side: silent either way.
    }
  }

  /// Enters (or keeps) the suspended state: cancels any pending re-apply,
  /// abandons any in-flight schedule before it reaches `playAt`, and stops
  /// correcting. A suspension that would clear itself (an interruption, a
  /// failure being retried) never masks one that needs the user — unplugged
  /// headphones are still unplugged after the call ends, and a retry must
  /// not put audio on the speaker — while one that needs the user replaces
  /// whatever was there.
  void _suspend(JamOutputSuspension next) {
    _eventReapplyTimer?.cancel();
    _eventReapplyTimer = null;
    _generation++;
    _stopDriftLoop();
    _cancelSlew();
    final current = outputSuspension.value;
    if (current != null && !current.mayAutoResume && next.mayAutoResume) {
      return;
    }
    _setSuspension(next);
  }

  void _setSuspension(JamOutputSuspension? next) {
    if (outputSuspension.value == next) return;
    outputSuspension.value = next;
    if (!_suspensionChanges.isClosed) _suspensionChanges.add(next);
  }

  /// Ends whatever suspension is shown — back to following the room, unless
  /// the OS still holds the audio, in which case that is what is shown.
  void _clearSuspension() => _setSuspension(
    _osHoldsAudio
        ? const JamOutputSuspension(JamOutputSuspendReason.interruption)
        : null,
  );

  /// Coalesces a burst of player events into one re-apply after
  /// [eventReapplyDebounce] — or after the failure backoff, when failures are
  /// pending, so an event can never shorten it, nor postpone a retry already
  /// armed (an engine that keeps restarting must not keep pushing the retry
  /// out). Manual nudges and fresh snapshots bypass this entirely (they call
  /// [_apply] directly), so the debounce never delays them.
  void _scheduleEventReapply() {
    if (_failures == 0) {
      _scheduleReapply(eventReapplyDebounce);
    } else if (_eventReapplyTimer == null) {
      _scheduleReapply(_failureDelay());
    }
  }

  /// `failureBackoffBase × 2^(failures-1)`, capped, never under the debounce.
  Duration _failureDelay() {
    final exponent = (_failures - 1).clamp(0, 30);
    final us = failureBackoffBase.inMicroseconds * (1 << exponent);
    final capped = us > failureBackoffCap.inMicroseconds
        ? failureBackoffCap.inMicroseconds
        : us;
    return Duration(
      microseconds: capped < eventReapplyDebounce.inMicroseconds
          ? eventReapplyDebounce.inMicroseconds
          : capped,
    );
  }

  /// Arms the single automatic re-apply. When it fires, a failure being
  /// retried is cleared first; any other suspension keeps it silent.
  void _scheduleReapply(Duration delay) {
    _eventReapplyTimer?.cancel();
    _eventReapplyTimer = Timer(delay, () {
      _eventReapplyTimer = null;
      if (_stopped) return;
      final current = outputSuspension.value;
      if (current != null) {
        if (current.reason != JamOutputSuspendReason.playbackError ||
            !current.willRetry) {
          return;
        }
        _clearSuspension();
        _calibration = null;
      }
      if (_snapshot?.status == PlaybackStatus.playing) {
        unawaited(_apply());
      }
    });
  }

  /// The player ran the scheduled segment to the end of the file. Reported
  /// (§5.5) for the schedule it was following; the local trackFinished state
  /// only applies while that schedule is still the snapshot being followed —
  /// a newer one (the host already advanced) schedules on its own.
  void _onPlaybackFinished() {
    final finished = _scheduled;
    if (finished == null) return; // Nothing of ours was playing.
    if (!_playbackFinished.isClosed) _playbackFinished.add(finished);
    if (_snapshot?.rev == finished.snapshotRev) _enterTrackFinished();
  }

  /// Enters the local trackFinished state: stop correcting, stop scheduling
  /// for this snapshot rev, and tell the UI. Cleared by the next snapshot
  /// that schedules within bounds.
  void _enterTrackFinished() {
    _finishedRev = _snapshot?.rev;
    _stopDriftLoop();
    _cancelSlew();
    trackFinished.value = true;
  }

  // --- Snapshot application ----------------------------------------------

  Future<void> _apply() async {
    if (_stopped) return;
    if (_routeLostWhilePaused &&
        _snapshot?.status == PlaybackStatus.playing &&
        outputSuspension.value == null) {
      // The room started, and not at this device's asking (its own play
      // forgets the loss first): its headphones went while it was paused.
      _holdStartForLostRoute();
    }
    final generation = ++_generation;
    final snapshot = _snapshot;
    if (snapshot == null) return;
    try {
      switch (snapshot.status) {
        case PlaybackStatus.playing:
          if (outputSuspension.value != null) {
            // The room plays on; this device stays silent. Preload so the
            // resume only has to schedule — but never playAt: on Android
            // that re-requests audio focus from the call that took it.
            _stopDriftLoop();
            _cancelSlew();
            if (snapshot.mediaId != _undecodableMediaId) {
              await _ensureLoaded(snapshot, generation);
            }
          } else {
            await _schedule(snapshot, generation);
          }
        case PlaybackStatus.paused:
        case PlaybackStatus.loading:
          _stopDriftLoop();
          _cancelSlew();
          await player.pause();
          // Preload so the next scheduled start (§5.3) only has to schedule,
          // and so the UI learns the duration before playback.
          await _ensureLoaded(snapshot, generation);
          // And learn the route, so an unplug before anyone plays knows which
          // device to wait for.
          await _learnRoute();
        case PlaybackStatus.idle:
          _stopDriftLoop();
          _cancelSlew();
          await player.stop();
      }
      if (generation == _generation) lastError.value = null;
    } on PlatformException catch (e) {
      lastError.value = '$e';
      // The native side refused to load or schedule (engine_error,
      // engine_not_running, load_failed, ...): back off and retry while it
      // may be transient, so the next event cannot loop into the same
      // failure. Only for a schedule this call was making — a preload while
      // paused or suspended is retried by whatever plays next.
      if (e.code != 'disposed' &&
          generation == _generation &&
          snapshot.status == PlaybackStatus.playing &&
          outputSuspension.value == null) {
        _failures++;
        _failPlayback(e.code, e.message, mediaId: snapshot.mediaId);
      }
    } catch (e) {
      // Keep the controller alive across plugin stubs (no native side at
      // all) and other non-platform errors; the UI surfaces the message.
      lastError.value = '$e';
    }
  }

  /// Loads the snapshot's media if it differs from what's loaded.
  /// Returns false when the media path is not resolvable yet.
  Future<bool> _ensureLoaded(PlaybackSnapshot snapshot, int generation) async {
    final mediaId = snapshot.mediaId;
    if (mediaId == null) return false;
    // A load still in flight is about to replace whatever completed last, so
    // the bookkeeping only counts once the engine has caught up with every
    // load issued (a back-and-forth A → B → A must not skip reloading A while
    // B is on its way in).
    if (_loadsInFlight == 0 && _loadedMediaId == mediaId) {
      // A load superseded before it could publish (a suspension or a clock
      // hold landed mid-load) still recorded what it loaded: publish its
      // duration now, or the previous item's would stand and clamp this one
      // into "finished" mid-track.
      loadedDurationUs.value = _loadedMediaDurationUs;
      return true;
    }
    final path = await resolveMediaPath(mediaId);
    if (generation != _generation) return false;
    if (path == null) {
      _waitingForMediaId = mediaId;
      loadedDurationUs.value = null; // Nothing of this item's is loaded.
      return false;
    }
    _waitingForMediaId = null;
    _loadedMediaId = null;
    _loadedMediaDurationUs = null;
    _loadsInFlight++;
    int durationUs;
    try {
      try {
        durationUs = await player.load(path);
      } on PlatformException {
        // Transient native load failures happen (observed once in a
        // 35-minute soak: the outgoing track's decoder had not fully released
        // its codec at the moment of a track transition). One short-delay
        // retry recovers; a second failure is real and propagates to
        // lastPlayerError as before.
        await Future<void>.delayed(const Duration(milliseconds: 250));
        if (generation != _generation) return false;
        // The file may also have gone between resolving and loading — a
        // guest's cache evicted it. Asking again lets a resolver that knows
        // re-fetch it and answer null: parked until notifyMediaAvailable,
        // not failed for good.
        final again = await resolveMediaPath(mediaId);
        if (generation != _generation) return false;
        if (again == null) {
          _waitingForMediaId = mediaId;
          loadedDurationUs.value = null;
          return false;
        }
        durationUs = await player.load(again);
      }
    } catch (_) {
      // The file would not load: whatever duration is showing is not this
      // item's.
      if (generation == _generation) loadedDurationUs.value = null;
      rethrow;
    } finally {
      _loadsInFlight--;
    }
    // Native method calls run in order, so with nothing else in flight this
    // file is what the engine holds now — whichever generation asked for it.
    // (A current generation never has a newer load behind it: only a newer
    // generation can issue one.)
    if (_loadsInFlight == 0) {
      _loadedMediaId = mediaId;
      _loadedMediaDurationUs = durationUs;
    }
    if (generation != _generation) return false;
    loadedDurationUs.value = durationUs;
    return true;
  }

  Future<void> _schedule(PlaybackSnapshot snapshot, int generation) async {
    // The player already ran this rev to the end of the file: nothing left to
    // schedule (a nudge or player event would otherwise re-playAt at/past the
    // end). A fresh rev — seek, new track — schedules normally.
    if (_finishedRev == snapshot.rev) return;
    if (!await _ensureLoaded(snapshot, generation)) return;
    if (generation != _generation) return;

    // §4: no session→local mapping yet (a guest's join burst after a
    // reconnect, or a discontinuity re-converging). Whatever is already
    // scheduled keeps playing; the drift loop re-applies once it is back.
    if (!_clockIsReady) {
      _pendingClockReapply = true;
      _startDriftLoop();
      return;
    }
    // This schedule is built on the current mapping, so a pending step is
    // accounted for. A step after this point raises the flag again.
    if (_clockStepped) acknowledgeClockStep?.call();
    _pendingClockReapply = false;

    // End-of-media clamp: when the anchor extrapolates to/past the loaded
    // duration there is nothing left to play — scheduling would only produce
    // native bad_position errors. Treat it as the track having finished.
    final durationUs = loadedDurationUs.value;
    if (durationUs != null &&
        snapshot.positionAt(sessionNowUs()) >= durationUs) {
      _enterTrackFinished();
      return;
    }

    // Calibrate the Dart↔native clock offset once per session; a hard resync
    // or player event clears the cache so it re-measures (§5.4).
    final calibration = _calibration ??= await player.calibrate(localNowUs);
    if (generation != _generation) return;

    // Prefer the route latency reported by the most recent routeChanged
    // event (it is the NEW route's, §7); re-query when no event supplied one.
    final outputLatencyUs =
        _routeOutputLatencyUs ?? await player.outputLatencyUs();
    if (generation != _generation) return;

    // The route this schedule plays on, so a later unplug knows which device
    // to wait for.
    if (!_routeQueried) {
      await _learnRoute();
      if (generation != _generation) return;
    }

    // A playing snapshot always carries an anchor (§5.1); if one is somehow
    // missing, synthesize "start now at the frozen position".
    final anchor =
        snapshot.anchor ??
        PlaybackAnchor(
          hostTimeUs: sessionNowUs(),
          positionUs: snapshot.positionUs,
        );

    // session µs → local µs → native µs (see library docs).
    //
    // A PAST anchor (late join, resume, any re-apply mid-track) is mapped
    // relative to now. `playAt` with a past native time starts at once,
    // advanced by the LOCAL µs since that time; the room's position advances
    // by SESSION µs. `sessionToLocalUs` extrapolates along the clocks' skew,
    // so the anchor's true local instant is off from "its session age ago" by
    // skew × age — 60 ms for a 10-minute-old anchor at 100 ppm, far past the
    // hard-resync threshold, and every re-apply would land there again.
    // Measuring the age in session µs makes the native advance exactly the
    // room's. A future anchor is a genuine instant to start at: extrapolate.
    final sessionNow = sessionNowUs();
    final localAnchorUs = anchor.hostTimeUs <= sessionNow
        ? localNowUs() - (sessionNow - anchor.hostTimeUs)
        : sessionToLocalUs(anchor.hostTimeUs);
    final nativeAnchorUs =
        localAnchorUs +
        calibration.offsetUs -
        outputLatencyUs -
        _manualOffsetUs;

    // A fresh schedule supersedes any in-flight slew.
    _cancelSlew();
    // Recorded BEFORE the call: native can report this schedule's failure
    // (decode_failed) before playAt returns, and it must be blamed on this
    // item, not on the one the engine played before. The engine follows
    // this schedule from here on, whatever happens to this generation: a
    // later playbackFinished refers to it.
    _scheduled = (mediaId: snapshot.mediaId!, snapshotRev: snapshot.rev);
    try {
      await player.playAt(
        nativeTimeUs: nativeAnchorUs,
        positionUs: anchor.positionUs,
        rate: snapshot.rate,
      );
    } catch (_) {
      _scheduled = null; // A refused playAt leaves nothing scheduled.
      rethrow;
    }
    _lastPlayAtLocalUs = localNowUs();
    if (generation != _generation) return;
    _clockHeld = false;
    // An in-bounds schedule leaves any earlier trackFinished state.
    _finishedRev = null;
    trackFinished.value = false;
    _startDriftLoop();
  }

  /// Asks the player for the current route, once: route events keep
  /// [_currentRouteId] current after that. An event that lands while the
  /// query is in flight knows better than its answer.
  Future<void> _learnRoute() async {
    if (_routeQueried) return;
    _routeQueried = true;
    final eventsBefore = _routeEvents;
    String? routeId;
    try {
      routeId = await player.currentRouteId();
    } catch (_) {
      routeId = null; // No native side: an unplug just waits for the user.
    }
    if (_routeEvents == eventsBefore) _currentRouteId = routeId;
  }

  // --- Drift loop (§5.4) ---------------------------------------------------

  /// Ticks from [JamTicker] (natively a plain `Timer.periodic`): in a
  /// browser tab the page's own timers are throttled to one a minute while
  /// it is hidden and inaudible — a room playing too quietly to count, or
  /// held across a clock discontinuity — and a once-a-minute check lets
  /// drift grow for a minute before it is corrected. A late check is never
  /// a spurious resync, though: the expected position comes from the anchor
  /// at the moment of the check and the actual one from the player at that
  /// same moment, so lateness alone measures no error.
  void _startDriftLoop() {
    _driftTimer?.cancel();
    _driftTimer = JamTicker.periodic(driftInterval, (_) {
      unawaited(checkDriftNow());
    });
  }

  void _stopDriftLoop() {
    _driftTimer?.cancel();
    _driftTimer = null;
    _lastAudioConfirmedLocalUs = null;
  }

  /// One drift self-check (§5.4). Called by the internal 1 Hz loop while
  /// playing; exposed so tests can tick deterministically.
  ///
  /// Also where session-clock trouble is noticed (§4): a stepped mapping
  /// re-schedules from the current anchor; a discontinuity (stepped and no
  /// longer synchronized — a device that slept) pauses output until the
  /// fresh join burst lands, then re-schedules.
  ///
  /// One check at a time: a tick that lands while the previous check's
  /// re-apply is still loading (a big file, a busy native queue) is skipped
  /// rather than superseding it — or every re-apply slower than the drift
  /// interval would be abandoned by the next, forever.
  Future<void> checkDriftNow() async {
    if (_stopped || _checking) return;
    final snapshot = _snapshot;
    if (snapshot == null || snapshot.status != PlaybackStatus.playing) return;
    if (trackFinished.value || outputSuspension.value != null) return;
    final generation = _generation;
    _checking = true;
    try {
      final ready = _clockIsReady;
      final stepped = _clockStepped;
      if (stepped && !ready) {
        await _holdForClock();
        return;
      }
      if (!ready) return; // A join burst in flight: nothing to measure yet.
      if (stepped || _pendingClockReapply || _clockHeld) {
        if (stepped) _resyncCount++;
        await _apply(); // Re-schedule from the current anchor.
        return;
      }
      final actualUs = await player.positionUs();
      if (actualUs == null || generation != _generation) return;
      final nowLocalUs = localNowUs();
      _lastAudioConfirmedLocalUs = nowLocalUs;
      // The schedule is producing audio. Once it has done so for longer than
      // an engine restart would still be blamed on it, whatever failed
      // before is behind us — not sooner, or an engine that falls over a
      // second or two after every schedule would reset its own count
      // between restarts and never be given up on.
      final scheduledAt = _lastPlayAtLocalUs;
      if (scheduledAt == null ||
          nowLocalUs - scheduledAt >= _restartAfterPlayAtUs) {
        _failures = 0;
      }
      final expectedUs = snapshot.positionAt(sessionNowUs());
      // The anchor ran past the end of the file: the track is over, not
      // drifting — a hard resync here would just re-schedule out of bounds.
      final durationUs = loadedDurationUs.value;
      if (durationUs != null && expectedUs >= durationUs) {
        _enterTrackFinished();
        return;
      }
      final action = driftPolicy.decide(
        expectedPositionUs: expectedUs,
        actualPositionUs: actualUs,
      );
      final sample = DriftSample(
        expectedUs: expectedUs,
        actualUs: actualUs,
        action: action,
      );
      _lastSample = sample;
      if (!_samples.isClosed) _samples.add(sample);

      switch (action) {
        case DriftNone():
          break;
        case DriftSlew(:final rateMultiplier, :final durationUs):
          // One slew at a time: let an in-flight correction finish before
          // measuring again — new corrections would double-count the error.
          if (_slewing) break;
          if (_slewUnsupported) {
            await _reanchorForDrift();
            break;
          }
          _slewing = true;
          try {
            await player.setRate(snapshot.rate * rateMultiplier);
          } catch (e) {
            _slewing = false; // Never left "in flight" with no restore.
            if (e is! PlatformException || e.code != 'bad_args') rethrow;
            // The output cannot time-stretch that rate (some Android
            // outputs refuse in-range rates and keep the old one): correct
            // by re-anchoring instead, now and for the rest of this route.
            _slewUnsupported = true;
            if (generation == _generation) await _reanchorForDrift();
            break;
          }
          // A re-apply, suspension or hold during the call already put the
          // nominal rate back (playAt carries it): nothing to restore.
          if (!_slewing || generation != _generation) break;
          _slewCount++;
          _slewRestoreTimer?.cancel();
          // Same source as the drift loop: a throttled restore would hold
          // a 3–10 s slew for up to a minute, and 0.5 % for 60 s is 300 ms —
          // six times the §5.4 hard-resync bound, the other way.
          _slewRestoreTimer = JamTicker.after(
            Duration(microseconds: durationUs),
            () => unawaited(_restoreNominalRate()),
          );
        case DriftHardResync():
          if (!_takeHardResync(nowLocalUs)) break; // Backing off (see there).
          _resyncCount++;
          _calibration = null; // Re-measure the native clock on hard resync.
          await _apply(); // Re-schedule from the current anchor.
      }
    } catch (e) {
      lastError.value = '$e';
    } finally {
      _checking = false;
    }
  }

  /// Whether a hard resync the drift policy asked for at [nowLocalUs] runs
  /// now (and is counted as run). The first one always does. An output that
  /// keeps falling behind however often it is re-anchored — a stalling
  /// device (an overloaded phone, an emulator on software rendering) — would
  /// otherwise restart its audio every drift check; each further one in a
  /// row waits [_hardResyncBackoffBaseUs] × 2^(n-1) after the previous,
  /// capped at [_hardResyncBackoffCapUs], so a device that cannot keep up
  /// re-anchors every ~10 s instead of every second. The error stands in
  /// between — it would come straight back anyway. A healthy stretch of
  /// [_hardResyncHealthyUs] without one starts the count over.
  bool _takeHardResync(int nowLocalUs) {
    final last = _lastHardResyncLocalUs;
    if (last != null && nowLocalUs - last >= _hardResyncHealthyUs) {
      _hardResyncStreak = 0;
    }
    if (last != null && _hardResyncStreak > 0) {
      final backoffUs = _hardResyncBackoffBaseUs << (_hardResyncStreak - 1);
      final waitUs = backoffUs > _hardResyncBackoffCapUs || backoffUs <= 0
          ? _hardResyncBackoffCapUs
          : backoffUs;
      if (nowLocalUs - last < waitUs) return false;
    }
    _hardResyncStreak++;
    _lastHardResyncLocalUs = nowLocalUs;
    return true;
  }

  /// Corrects slew-band drift without a rate change: re-schedules from the
  /// current anchor (the native clock calibration stands — the error is
  /// drift, not calibration). At most once per [_slewFallbackIntervalUs]: a
  /// re-anchor is an audible skip, and every 1 Hz check in the band doing
  /// one would skip every second. The band's error is tolerable meanwhile;
  /// past it the policy hard-resyncs, unthrottled.
  Future<void> _reanchorForDrift() async {
    final nowLocalUs = localNowUs();
    final last = _lastDriftReanchorLocalUs;
    if (last != null && nowLocalUs - last < _slewFallbackIntervalUs) return;
    _lastDriftReanchorLocalUs = nowLocalUs;
    _resyncCount++;
    await _apply();
  }

  /// Silences output until [clockReady] is true again — for a caller that
  /// knows the session-clock mapping is stale before the estimator does: a
  /// guest waking from a device sleep, whose monotonic clock stopped while
  /// the host's ran on, would otherwise re-schedule at a position off by the
  /// whole sleep for the seconds it takes `ClockSync` to confirm the jump
  /// (§4). Pauses the player, drops the native-clock calibration (the native
  /// clock slept too), and leaves the drift loop polling: once [clockReady]
  /// answers true the current snapshot is re-applied from its anchor. A
  /// no-op unless the room is playing and this device is following it.
  Future<void> holdForClock() async {
    if (_stopped) return;
    _calibration = null;
    final snapshot = _snapshot;
    if (snapshot == null ||
        snapshot.status != PlaybackStatus.playing ||
        trackFinished.value ||
        outputSuspension.value != null) {
      return;
    }
    _startDriftLoop();
    try {
      await _holdForClock();
    } catch (e) {
      lastError.value = '$e';
    }
  }

  /// Pauses output across a session-clock discontinuity: the schedule it
  /// was following is off by however long the device slept. The drift loop
  /// keeps ticking, and re-schedules once the clock is synchronized again.
  Future<void> _holdForClock() async {
    _pendingClockReapply = true;
    if (_clockHeld) return;
    _clockHeld = true;
    _generation++; // Nothing in flight may schedule on the stale mapping.
    _cancelSlew();
    await player.pause();
  }

  Future<void> _restoreNominalRate() async {
    _slewRestoreTimer = null;
    if (!_slewing) return;
    _slewing = false;
    final snapshot = _snapshot;
    if (_stopped ||
        snapshot == null ||
        snapshot.status != PlaybackStatus.playing ||
        outputSuspension.value != null) {
      return;
    }
    try {
      await player.setRate(snapshot.rate);
    } catch (e) {
      lastError.value = '$e';
    }
  }

  void _cancelSlew() {
    _slewRestoreTimer?.cancel();
    _slewRestoreTimer = null;
    _slewing = false;
  }

  /// Stops timers and closes the telemetry stream. Does NOT dispose the
  /// injected [player]; its owner does that.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _stopDriftLoop();
    _cancelSlew();
    _eventReapplyTimer?.cancel();
    _eventReapplyTimer = null;
    await _eventSub?.cancel();
    _eventSub = null;
    loadedDurationUs.dispose();
    lastError.dispose();
    trackFinished.dispose();
    outputSuspension.dispose();
    await _samples.close();
    await _suspensionChanges.close();
    await _routeChanges.close();
    await _playbackFinished.close();
  }
}
