/// Deterministic unit tests for [AudioSyncController]: the playAt time
/// conversion arithmetic (session → local → native, with calibration, output
/// latency, and manual nudge), pause propagation, drift slew apply/restore,
/// and hard resync rescheduling. All clocks are scripted; the player is a
/// fake that records calls and serves scripted positions; timer-driven paths
/// run under fake_async.
library;

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/sync/audio_sync_controller.dart';
import 'package:localjam_audio/localjam_audio.dart';
import 'package:localjam_net/localjam_net.dart';

/// Records every call and answers from scripted values. Extends the pinned
/// [LocaljamAudio] API so the controller stays coupled only to that class.
class FakeLocaljamAudio extends LocaljamAudio {
  FakeLocaljamAudio();

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

  int calibrateCount = 0;

  @override
  Future<NativeClockCalibration> calibrate(
    int Function() dartNowUs, {
    int samples = 10,
  }) async {
    calls.add('calibrate');
    calibrateCount++;
    return NativeClockCalibration(
      offsetUs: calibrationOffsetUs,
      rttUs: calibrationRttUs,
    );
  }

  @override
  Future<int> load(String filePath) async {
    calls.add('load');
    loadedPaths.add(filePath);
    return scriptedDurationUs;
  }

  @override
  Future<void> playAt({
    required int nativeTimeUs,
    required int positionUs,
    double rate = 1.0,
  }) async {
    calls.add('playAt');
    playAtCalls.add(
      (nativeTimeUs: nativeTimeUs, positionUs: positionUs, rate: rate),
    );
  }

  @override
  Future<void> pause() async => calls.add('pause');

  @override
  Future<void> stop() async => calls.add('stop');

  @override
  Future<int?> positionUs() async {
    calls.add('positionUs');
    return scriptedPositionUs;
  }

  @override
  Future<void> setRate(double rate) async {
    calls.add('setRate');
    setRateCalls.add(rate);
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
}) =>
    PlaybackSnapshot(
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

void main() {
  late FakeLocaljamAudio player;
  late ScriptedClock clock;

  AudioSyncController buildController({
    Future<String?> Function(String mediaId)? resolver,
  }) =>
      AudioSyncController(
        player: player,
        sessionNowUs: clock.sessionNowUs,
        localNowUs: clock.localNowUs,
        sessionToLocalUs: clock.sessionToLocalUs,
        resolveMediaPath: resolver ?? (mediaId) async => '/tmp/$mediaId.mp3',
      );

  setUp(() {
    player = FakeLocaljamAudio();
    clock = ScriptedClock();
  });

  group('playAt conversion arithmetic', () {
    test(
        'session anchor maps through session→local→native with calibration, '
        'output latency, and manual offset', () async {
      // Session clock is 1_000_000 µs ahead of local; native clock is 250 µs
      // ahead of local; the route adds 30 ms output latency; the user nudged
      // +20 ms (play earlier).
      clock.localUs = 5000000;
      clock.sessionOffsetUs = 1000000;
      player.calibrationOffsetUs = 250;
      player.scriptedOutputLatencyUs = 30000;

      final controller = buildController();
      await controller.setManualOffsetUs(20000);

      const anchorHostTimeUs = 6750000; // session µs (~now + 750 ms lead)
      const anchorPositionUs = 45000000;
      await controller.onSnapshot(playingSnapshot(
        anchorHostTimeUs: anchorHostTimeUs,
        anchorPositionUs: anchorPositionUs,
        rate: 1.0,
      ));

      expect(player.loadedPaths, ['/tmp/m_1.mp3']);
      expect(player.playAtCalls, hasLength(1));
      final call = player.playAtCalls.single;
      // local = session - sessionOffset; native = local + cal - lat - nudge.
      const expectedLocalUs = anchorHostTimeUs - 1000000;
      const expectedNativeUs = expectedLocalUs + 250 - 30000 - 20000;
      expect(call.nativeTimeUs, expectedNativeUs);
      expect(call.positionUs, anchorPositionUs);
      expect(call.rate, 1.0);

      await controller.dispose();
    });

    test('calibration is cached across snapshots (per session)', () async {
      final controller = buildController();
      await controller.onSnapshot(
        playingSnapshot(rev: 1, anchorHostTimeUs: 100, anchorPositionUs: 0),
      );
      await controller.onSnapshot(
        playingSnapshot(rev: 2, anchorHostTimeUs: 200, anchorPositionUs: 10),
      );
      expect(player.calibrateCount, 1);
      expect(player.playAtCalls, hasLength(2));
      await controller.dispose();
    });

    test('changing the manual offset while playing re-anchors', () async {
      final controller = buildController();
      await controller.onSnapshot(playingSnapshot(
        anchorHostTimeUs: 1000000,
        anchorPositionUs: 0,
      ));
      expect(player.playAtCalls, hasLength(1));

      await controller.setManualOffsetUs(50000);
      expect(player.playAtCalls, hasLength(2));
      expect(
        player.playAtCalls[1].nativeTimeUs,
        player.playAtCalls[0].nativeTimeUs - 50000,
      );
      await controller.dispose();
    });

    test('parks when media is unresolved, schedules on notify', () async {
      String? resolved;
      final controller = buildController(
        resolver: (mediaId) async => resolved,
      );
      await controller.onSnapshot(playingSnapshot(
        anchorHostTimeUs: 1000,
        anchorPositionUs: 0,
      ));
      expect(player.playAtCalls, isEmpty);

      resolved = '/tmp/fetched.mp3';
      await controller.notifyMediaAvailable('m_1');
      expect(player.loadedPaths, ['/tmp/fetched.mp3']);
      expect(player.playAtCalls, hasLength(1));
      await controller.dispose();
    });
  });

  group('pause propagation', () {
    test('paused snapshot pauses the player and stops the drift loop', () {
      fakeAsync((async) {
        final controller = buildController();
        controller.onSnapshot(playingSnapshot(
          anchorHostTimeUs: 0,
          anchorPositionUs: 0,
        ));
        async.flushMicrotasks();
        expect(player.playAtCalls, hasLength(1));

        player.scriptedPositionUs = 1000000;
        clock.localUs += 1000000;
        async.elapse(const Duration(seconds: 1));
        final pollsWhilePlaying =
            player.calls.where((c) => c == 'positionUs').length;
        expect(pollsWhilePlaying, 1); // Drift loop ran while playing.

        controller.onSnapshot(const PlaybackSnapshot(
          rev: 2,
          status: PlaybackStatus.paused,
          mediaId: 'm_1',
          positionUs: 1000000,
        ));
        async.flushMicrotasks();
        expect(player.calls, contains('pause'));

        // No more drift polls after pause.
        async.elapse(const Duration(seconds: 5));
        expect(
          player.calls.where((c) => c == 'positionUs').length,
          pollsWhilePlaying,
        );

        controller.dispose();
        async.flushMicrotasks();
      });
    });

    test('idle snapshot stops the player', () async {
      final controller = buildController();
      await controller.onSnapshot(PlaybackSnapshot.initial);
      expect(player.calls, contains('stop'));
      await controller.dispose();
    });
  });

  group('drift correction (§5.4)', () {
    test('slew is applied and restored after its duration', () {
      fakeAsync((async) {
        final controller = buildController();
        // Anchor at session 0, position 0; play from the start.
        controller.onSnapshot(playingSnapshot(
          anchorHostTimeUs: 0,
          anchorPositionUs: 0,
        ));
        async.flushMicrotasks();

        // 10 s in, the player is 20 ms ahead → slew down at 0.995 for
        // 20 ms / 0.005 = 4 s.
        clock.localUs = 10000000;
        player.scriptedPositionUs = 10020000;
        controller.checkDriftNow();
        async.flushMicrotasks();

        expect(controller.slewCount, 1);
        expect(controller.isSlewing, isTrue);
        expect(player.setRateCalls, [0.995]);
        expect(controller.lastSample?.errorUs, 20000);
        expect(controller.lastSample?.action, isA<DriftSlew>());

        // While slewing, further slew decisions are not re-applied.
        player.scriptedPositionUs = 10520000; // Still drifted at next check.
        clock.localUs = 10500000;
        controller.checkDriftNow();
        async.flushMicrotasks();
        expect(player.setRateCalls, [0.995]);

        // After durationUs the nominal rate is restored.
        async.elapse(const Duration(seconds: 4));
        expect(player.setRateCalls, [0.995, 1.0]);
        expect(controller.isSlewing, isFalse);

        controller.dispose();
        async.flushMicrotasks();
      });
    });

    test('within-threshold error does nothing', () {
      fakeAsync((async) {
        final controller = buildController();
        controller.onSnapshot(playingSnapshot(
          anchorHostTimeUs: 0,
          anchorPositionUs: 0,
        ));
        async.flushMicrotasks();

        clock.localUs = 5000000;
        player.scriptedPositionUs = 5004000; // +4 ms: below 15 ms floor.
        controller.checkDriftNow();
        async.flushMicrotasks();

        expect(controller.lastSample?.action, isA<DriftNone>());
        expect(player.setRateCalls, isEmpty);
        expect(controller.slewCount, 0);
        expect(controller.resyncCount, 0);

        controller.dispose();
        async.flushMicrotasks();
      });
    });

    test('hard resync recalibrates and re-schedules from the anchor', () {
      fakeAsync((async) {
        final controller = buildController();
        controller.onSnapshot(playingSnapshot(
          anchorHostTimeUs: 0,
          anchorPositionUs: 0,
        ));
        async.flushMicrotasks();
        expect(player.playAtCalls, hasLength(1));
        expect(player.calibrateCount, 1);

        // 100 ms behind → beyond the 50 ms hard-resync threshold.
        clock.localUs = 20000000;
        player.scriptedPositionUs = 19900000;
        controller.checkDriftNow();
        async.flushMicrotasks();

        expect(controller.resyncCount, 1);
        expect(controller.lastSample?.action, isA<DriftHardResync>());
        expect(player.playAtCalls, hasLength(2), reason: 're-scheduled');
        expect(player.calibrateCount, 2, reason: 'recalibrated on resync');
        // Re-anchored from the SAME authoritative anchor (session 0 → pos 0).
        expect(player.playAtCalls[1].positionUs, 0);

        controller.dispose();
        async.flushMicrotasks();
      });
    });

    test('drift samples stream carries expected/actual/error', () {
      fakeAsync((async) {
        final controller = buildController();
        final samples = <DriftSample>[];
        controller.driftSamples.listen(samples.add);
        controller.onSnapshot(playingSnapshot(
          anchorHostTimeUs: 0,
          anchorPositionUs: 1000000,
        ));
        async.flushMicrotasks();

        clock.localUs = 2000000;
        player.scriptedPositionUs = 3016000; // expected 3_000_000 → +16 ms.
        controller.checkDriftNow();
        async.flushMicrotasks();

        expect(samples, hasLength(1));
        expect(samples.single.expectedUs, 3000000);
        expect(samples.single.actualUs, 3016000);
        expect(samples.single.errorUs, 16000);
        expect(samples.single.action, isA<DriftSlew>());

        controller.dispose();
        async.flushMicrotasks();
      });
    });

    test('periodic drift loop ticks once per interval while playing', () {
      fakeAsync((async) {
        final controller = buildController();
        controller.onSnapshot(playingSnapshot(
          anchorHostTimeUs: 0,
          anchorPositionUs: 0,
        ));
        async.flushMicrotasks();

        player.scriptedPositionUs = 0;
        async.elapse(const Duration(seconds: 3));
        expect(player.calls.where((c) => c == 'positionUs').length, 3);

        controller.dispose();
        async.flushMicrotasks();
      });
    });
  });
}
