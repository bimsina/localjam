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
/// hard resyncs recalibrate and re-schedule from the current anchor. Every
/// check is published as a [DriftSample] for telemetry UIs.
///
/// The class is pure-ish Dart: every clock, the media-path resolver, and the
/// player are injected, so it is fully unit-testable with scripted time.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:localjam_audio/localjam_audio.dart';
import 'package:localjam_net/localjam_net.dart';

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

  PlaybackSnapshot? _snapshot;
  NativeClockCalibration? _calibration;
  String? _loadedMediaId;
  String? _waitingForMediaId;
  int _manualOffsetUs = 0;
  int _generation = 0;
  bool _disposed = false;

  StreamSubscription<LocaljamAudioEvent>? _eventSub;
  Timer? _eventReapplyTimer;

  /// Latest route output latency (µs) learned from a player event; null means
  /// "query the player". Overwritten (possibly back to null) by every
  /// route/interruption/restart event so it always describes the CURRENT
  /// route.
  int? _routeOutputLatencyUs;

  /// The snapshot rev the player finished (end of file); no further playAt is
  /// issued for this rev — a fresh rev clears it.
  int? _finishedRev;

  Timer? _driftTimer;
  Timer? _slewRestoreTimer;
  bool _slewing = false;
  int _slewCount = 0;
  int _resyncCount = 0;
  DriftSample? _lastSample;

  final StreamController<DriftSample> _samples =
      StreamController<DriftSample>.broadcast();

  /// Duration (µs) of the currently loaded media, from [LocaljamAudio.load].
  /// Null until the first load completes.
  final ValueNotifier<int?> loadedDurationUs = ValueNotifier<int?>(null);

  /// Last player/platform error, for surfacing in the UI while the plugin's
  /// native side is still landing. Cleared on the next successful schedule.
  final ValueNotifier<String?> lastError = ValueNotifier<String?>(null);

  /// True when the current track ran to its end — either the player reported
  /// [LocaljamAudioEventKind.playbackFinished] or the anchor extrapolates
  /// to/past the loaded duration. While true the drift loop is stopped and no
  /// playAt is issued; a fresh snapshot that re-anchors within bounds
  /// (seek/new track) clears it and plays normally. UI can show "finished".
  final ValueNotifier<bool> trackFinished = ValueNotifier<bool>(false);

  /// Every drift self-check while playing (§5.4), ~1 per [driftInterval].
  Stream<DriftSample> get driftSamples => _samples.stream;

  /// The most recent drift self-check, if any.
  DriftSample? get lastSample => _lastSample;

  /// How many slews have been initiated this session.
  int get slewCount => _slewCount;

  /// How many hard resyncs have been performed this session.
  int get resyncCount => _resyncCount;

  /// Whether a slew is currently in flight.
  bool get isSlewing => _slewing;

  /// The snapshot the controller is currently following.
  PlaybackSnapshot? get snapshot => _snapshot;

  /// The cached Dart↔native clock calibration, if measured.
  NativeClockCalibration? get calibration => _calibration;

  /// The user "nudge" (§7): µs subtracted from the native schedule time, so a
  /// positive value makes audio come out *earlier* (compensates extra output
  /// latency, e.g. Bluetooth).
  int get manualOffsetUs => _manualOffsetUs;

  /// Sets the manual nudge and, if currently playing, re-schedules from the
  /// current anchor so the change takes effect immediately.
  Future<void> setManualOffsetUs(int offsetUs) async {
    if (_manualOffsetUs == offsetUs) return;
    _manualOffsetUs = offsetUs;
    if (_snapshot?.status == PlaybackStatus.playing) {
      await _apply();
    }
  }

  /// Feeds a new authoritative snapshot (from `welcome`, a `state` broadcast,
  /// or the host's own mutation).
  Future<void> onSnapshot(PlaybackSnapshot snapshot) async {
    _snapshot = snapshot;
    await _apply();
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
  /// Call this after loading a *different* file into the shared [player]
  /// behind the controller's back — e.g. probing another file's duration
  /// through the same native engine (see `JamHostEngine.addMediaFile`).
  Future<void> invalidateLoadedMedia() async {
    if (_disposed) return;
    _loadedMediaId = null;
    loadedDurationUs.value = null;
    if (_snapshot != null) await _apply();
  }

  // --- Player events (interruptions, route changes, end of file) ----------

  void _onPlayerEvent(LocaljamAudioEvent event) {
    if (_disposed) return;
    switch (event.kind) {
      case LocaljamAudioEventKind.interruptionBegan:
        // The OS ducked/stopped playback; drift measurements are meaningless
        // until interruptionEnded re-applies the snapshot.
        _stopDriftLoop();
        _cancelSlew();
      case LocaljamAudioEventKind.interruptionEnded:
      case LocaljamAudioEventKind.engineRestarted:
      case LocaljamAudioEventKind.routeChanged:
        // The engine (and possibly the route) changed under us: remember the
        // event's route latency (null → re-query at schedule time), drop the
        // native-clock calibration so it is re-measured, and re-apply the
        // current snapshot — debounced, because these events arrive in
        // bursts (a route change typically also restarts the engine).
        _routeOutputLatencyUs = event.outputLatencyUs;
        _calibration = null;
        _scheduleEventReapply();
      case LocaljamAudioEventKind.playbackFinished:
        _enterTrackFinished();
    }
  }

  /// Coalesces a burst of player events into one re-apply after
  /// [eventReapplyDebounce]. Manual nudges and fresh snapshots bypass this
  /// entirely (they call [_apply] directly), so the debounce never delays
  /// them.
  void _scheduleEventReapply() {
    _eventReapplyTimer?.cancel();
    _eventReapplyTimer = Timer(eventReapplyDebounce, () {
      _eventReapplyTimer = null;
      if (_disposed) return;
      if (_snapshot?.status == PlaybackStatus.playing) {
        unawaited(_apply());
      }
    });
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
    if (_disposed) return;
    final generation = ++_generation;
    final snapshot = _snapshot;
    if (snapshot == null) return;
    try {
      switch (snapshot.status) {
        case PlaybackStatus.playing:
          await _schedule(snapshot, generation);
        case PlaybackStatus.paused:
        case PlaybackStatus.loading:
          _stopDriftLoop();
          _cancelSlew();
          await player.pause();
          // Preload so the next scheduled start (§5.3) only has to schedule,
          // and so the UI learns the duration before playback.
          await _ensureLoaded(snapshot, generation);
        case PlaybackStatus.idle:
          _stopDriftLoop();
          _cancelSlew();
          await player.stop();
      }
      if (generation == _generation) lastError.value = null;
    } catch (e) {
      // Keep the controller alive across plugin stubs / transient platform
      // errors; the UI surfaces the message.
      lastError.value = '$e';
    }
  }

  /// Loads the snapshot's media if it differs from what's loaded.
  /// Returns false when the media path is not resolvable yet.
  Future<bool> _ensureLoaded(PlaybackSnapshot snapshot, int generation) async {
    final mediaId = snapshot.mediaId;
    if (mediaId == null) return false;
    if (_loadedMediaId == mediaId) return true;
    final path = await resolveMediaPath(mediaId);
    if (generation != _generation) return false;
    if (path == null) {
      _waitingForMediaId = mediaId;
      return false;
    }
    _waitingForMediaId = null;
    final durationUs = await player.load(path);
    if (generation != _generation) return false;
    _loadedMediaId = mediaId;
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

    // A playing snapshot always carries an anchor (§5.1); if one is somehow
    // missing, synthesize "start now at the frozen position".
    final anchor =
        snapshot.anchor ??
        PlaybackAnchor(
          hostTimeUs: sessionNowUs(),
          positionUs: snapshot.positionUs,
        );

    // session µs → local µs → native µs (see library docs).
    final localAnchorUs = sessionToLocalUs(anchor.hostTimeUs);
    final nativeAnchorUs =
        localAnchorUs +
        calibration.offsetUs -
        outputLatencyUs -
        _manualOffsetUs;

    // A fresh schedule supersedes any in-flight slew.
    _cancelSlew();
    await player.playAt(
      nativeTimeUs: nativeAnchorUs,
      positionUs: anchor.positionUs,
      rate: snapshot.rate,
    );
    if (generation != _generation) return;
    // An in-bounds schedule leaves any earlier trackFinished state.
    _finishedRev = null;
    trackFinished.value = false;
    _startDriftLoop();
  }

  // --- Drift loop (§5.4) ---------------------------------------------------

  void _startDriftLoop() {
    _driftTimer?.cancel();
    _driftTimer = Timer.periodic(driftInterval, (_) {
      unawaited(checkDriftNow());
    });
  }

  void _stopDriftLoop() {
    _driftTimer?.cancel();
    _driftTimer = null;
  }

  /// One drift self-check (§5.4). Called by the internal 1 Hz loop while
  /// playing; exposed so tests can tick deterministically.
  Future<void> checkDriftNow() async {
    if (_disposed) return;
    final snapshot = _snapshot;
    if (snapshot == null || snapshot.status != PlaybackStatus.playing) return;
    if (trackFinished.value) return;
    final generation = _generation;
    try {
      final actualUs = await player.positionUs();
      if (actualUs == null || generation != _generation) return;
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
          _slewing = true;
          _slewCount++;
          await player.setRate(snapshot.rate * rateMultiplier);
          _slewRestoreTimer = Timer(
            Duration(microseconds: durationUs),
            () => unawaited(_restoreNominalRate()),
          );
        case DriftHardResync():
          _resyncCount++;
          _calibration = null; // Re-measure the native clock on hard resync.
          await _apply(); // Re-schedule from the current anchor.
      }
    } catch (e) {
      lastError.value = '$e';
    }
  }

  Future<void> _restoreNominalRate() async {
    _slewRestoreTimer = null;
    if (!_slewing) return;
    _slewing = false;
    final snapshot = _snapshot;
    if (_disposed ||
        snapshot == null ||
        snapshot.status != PlaybackStatus.playing) {
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
    await _samples.close();
  }
}
