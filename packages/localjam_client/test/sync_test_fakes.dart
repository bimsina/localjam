/// Scripted stand-ins for [AudioSyncController] unit tests: a fake player
/// that records calls and serves scripted values (and, on demand, scripted
/// failures and slow loads), and a scripted session/local clock pair.
library;

import 'dart:async';

import 'package:localjam_audio/localjam_audio.dart';
import 'package:localjam_net/localjam_net.dart';

/// Records every call and answers from scripted values. Extends the pinned
/// [LocaljamAudio] API so the controller stays coupled only to that class.
class FakeLocaljamAudio extends LocaljamAudio {
  FakeLocaljamAudio();

  /// Test-scripted player events; [events] serves this instead of the real
  /// event channel.
  final StreamController<LocaljamAudioEvent> eventsController =
      StreamController<LocaljamAudioEvent>.broadcast(sync: true);

  @override
  Stream<LocaljamAudioEvent> get events => eventsController.stream;

  /// Shorthand for pushing one event.
  void emit(LocaljamAudioEvent event) => eventsController.add(event);

  final List<String> calls = [];
  final List<({int nativeTimeUs, int positionUs, double rate})> playAtCalls =
      [];
  final List<double> setRateCalls = [];
  final List<String> loadedPaths = [];

  int calibrationOffsetUs = 0;
  int calibrationRttUs = 100;
  int scriptedDurationUs = 180000000; // 3 min
  int scriptedOutputLatencyUs = 0;

  /// Position served by [positionUs]; null = "nothing playing".
  int? scriptedPositionUs;

  /// When set, [positionUs] ignores [scriptedPositionUs] and reports the
  /// position a real player would report as HEARD (the
  /// [LocaljamAudio.positionUs] contract) for the last [playAt] it was
  /// given: the schedule's position at this native time, shifted back by
  /// [heardLatencyUs] — the latency the platform maps its heard instant
  /// with. Null before the first [playAt].
  int Function()? followScheduleNativeNowUs;

  /// See [followScheduleNativeNowUs].
  int heardLatencyUs = 0;

  /// Thrown by the next [playAt] calls, one per call (then they succeed).
  final List<Object> playAtErrors = [];

  /// When set, [load] waits for this to answer (a slow native load).
  Future<int> Function(String path)? loadHandler;

  /// Answer native method calls in the order they were made, as the real
  /// plugin does (one platform thread): a load issued after a slow one
  /// completes after it, however fast its own [loadHandler] answer is.
  bool serializeLoads = false;
  Future<void>? _loadQueue;

  /// Served by [currentRouteId].
  String? scriptedRouteId;

  /// When set, [setRate] waits for / fails with this.
  Future<void> Function(double rate)? setRateHandler;

  /// When set, [calibrate] waits for it (a slow re-apply in flight).
  Completer<void>? calibrateGate;

  /// Runs inside [playAt], before it returns (e.g. an OS refusal reported
  /// while the call is in flight).
  void Function()? onPlayAt;

  int calibrateCount = 0;

  int countOf(String call) => calls.where((c) => c == call).length;

  @override
  Future<NativeClockCalibration> calibrate(
    int Function() dartNowUs, {
    int samples = 10,
  }) async {
    calls.add('calibrate');
    calibrateCount++;
    final gate = calibrateGate;
    if (gate != null) await gate.future;
    return NativeClockCalibration(
      offsetUs: calibrationOffsetUs,
      rttUs: calibrationRttUs,
    );
  }

  @override
  Future<int> load(String filePath) async {
    calls.add('load');
    loadedPaths.add(filePath);
    final handler = loadHandler;
    Future<int> answer() async =>
        handler != null ? handler(filePath) : scriptedDurationUs;
    if (!serializeLoads) return answer();
    final previous = _loadQueue;
    final mine = Completer<void>();
    _loadQueue = mine.future;
    try {
      if (previous != null) await previous;
      return await answer();
    } finally {
      mine.complete();
    }
  }

  @override
  Future<String?> currentRouteId() async {
    calls.add('currentRouteId');
    return scriptedRouteId;
  }

  @override
  Future<void> playAt({
    required int nativeTimeUs,
    required int positionUs,
    double rate = 1.0,
  }) async {
    calls.add('playAt');
    onPlayAt?.call();
    if (playAtErrors.isNotEmpty) throw playAtErrors.removeAt(0);
    playAtCalls.add((
      nativeTimeUs: nativeTimeUs,
      positionUs: positionUs,
      rate: rate,
    ));
  }

  @override
  Future<void> pause() async => calls.add('pause');

  @override
  Future<void> stop() async => calls.add('stop');

  @override
  Future<int?> positionUs() async {
    calls.add('positionUs');
    final nativeNowUs = followScheduleNativeNowUs;
    if (nativeNowUs == null) return scriptedPositionUs;
    if (playAtCalls.isEmpty) return null;
    final last = playAtCalls.last;
    final heardSinceStartUs =
        nativeNowUs() - heardLatencyUs - last.nativeTimeUs;
    if (heardSinceStartUs <= 0) return last.positionUs;
    return last.positionUs + (heardSinceStartUs * last.rate).round();
  }

  @override
  Future<void> setRate(double rate) async {
    calls.add('setRate');
    setRateCalls.add(rate);
    await setRateHandler?.call(rate);
  }

  @override
  Future<int> outputLatencyUs() async {
    calls.add('outputLatencyUs');
    return scriptedOutputLatencyUs;
  }

  @override
  Future<void> dispose() async => calls.add('dispose');
}

/// Scripted clock pair: `sessionNow = localNow + sessionOffsetUs`.
class ScriptedClock {
  int localUs = 0;
  int sessionOffsetUs = 0;

  int localNowUs() => localUs;
  int sessionNowUs() => localUs + sessionOffsetUs;
  int sessionToLocalUs(int sessionUs) => sessionUs - sessionOffsetUs;
}

PlaybackSnapshot playingSnapshot({
  int rev = 1,
  String mediaId = 'm_1',
  required int anchorHostTimeUs,
  required int anchorPositionUs,
  double rate = 1.0,
}) => PlaybackSnapshot(
  rev: rev,
  status: PlaybackStatus.playing,
  mediaId: mediaId,
  anchor: PlaybackAnchor(
    hostTimeUs: anchorHostTimeUs,
    positionUs: anchorPositionUs,
  ),
  positionUs: anchorPositionUs,
  rate: rate,
);
