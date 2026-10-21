/// Deterministic unit tests for [AudioSyncController]: the playAt time
/// conversion arithmetic (session → local → native, with calibration, output
/// latency, and manual nudge), pause propagation, drift slew apply/restore,
/// hard resync rescheduling, and a nudged schedule reading as in sync. All clocks are scripted; the player is a
/// fake that records calls and serves scripted positions; timer-driven paths
/// run under fake_async.
library;

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_audio/localjam_audio.dart';
import 'package:localjam_client/src/audio_sync_controller.dart';
import 'package:localjam_net/localjam_net.dart';

import 'sync_test_fakes.dart';

void main() {
  late FakeLocaljamAudio player;
  late ScriptedClock clock;

  AudioSyncController buildController({
    Future<String?> Function(String mediaId)? resolver,
  }) => AudioSyncController(
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
    test('session anchor maps through session→local→native with calibration, '
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
      await controller.onSnapshot(
        playingSnapshot(
          anchorHostTimeUs: anchorHostTimeUs,
          anchorPositionUs: anchorPositionUs,
          rate: 1.0,
        ),
      );

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
      await controller.onSnapshot(
        playingSnapshot(anchorHostTimeUs: 1000000, anchorPositionUs: 0),
      );
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
      final controller = buildController(resolver: (mediaId) async => resolved);
      await controller.onSnapshot(
        playingSnapshot(anchorHostTimeUs: 1000, anchorPositionUs: 0),
      );
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
        controller.onSnapshot(
          playingSnapshot(anchorHostTimeUs: 0, anchorPositionUs: 0),
        );
        async.flushMicrotasks();
        expect(player.playAtCalls, hasLength(1));

        player.scriptedPositionUs = 1000000;
        clock.localUs += 1000000;
        async.elapse(const Duration(seconds: 1));
        final pollsWhilePlaying = player.calls
            .where((c) => c == 'positionUs')
            .length;
        expect(pollsWhilePlaying, 1); // Drift loop ran while playing.

        controller.onSnapshot(
          const PlaybackSnapshot(
            rev: 2,
            status: PlaybackStatus.paused,
            mediaId: 'm_1',
            positionUs: 1000000,
          ),
        );
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
        controller.onSnapshot(
          playingSnapshot(anchorHostTimeUs: 0, anchorPositionUs: 0),
        );
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
        controller.onSnapshot(
          playingSnapshot(anchorHostTimeUs: 0, anchorPositionUs: 0),
        );
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
        controller.onSnapshot(
          playingSnapshot(anchorHostTimeUs: 0, anchorPositionUs: 0),
        );
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
        controller.onSnapshot(
          playingSnapshot(anchorHostTimeUs: 0, anchorPositionUs: 1000000),
        );
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
        controller.onSnapshot(
          playingSnapshot(anchorHostTimeUs: 0, anchorPositionUs: 0),
        );
        async.flushMicrotasks();

        player.scriptedPositionUs = 0;
        async.elapse(const Duration(seconds: 3));
        expect(player.calls.where((c) => c == 'positionUs').length, 3);

        controller.dispose();
        async.flushMicrotasks();
      });
    });
  });

  // The manual nudge (§7) moves the native schedule earlier on purpose, and
  // `positionUs` reports the HEARD position against the platform-reported
  // latency only (it cannot see the extra latency the nudge compensates).
  // A nudged schedule that landed on time therefore reads `nudge` ahead of
  // the room's anchor formula — the drift check must expect that. Before the
  // fix it compared against the bare anchor formula: a +60 ms nudge read as
  // +60 ms of drift on every check, past the 50 ms bound, so the controller
  // hard-resynced, re-applied the same nudge and landed at +60 ms again —
  // an audible skip every few seconds for anyone who nudged.
  group('manual nudge vs the drift check (§7, §5.4)', () {
    // Native clock = local + 250 µs; the route reports 30 ms of latency,
    // and the fake player maps its heard instant with that same 30 ms.
    const calibrationUs = 250;
    const latencyUs = 30000;

    void followSchedule() {
      player
        ..calibrationOffsetUs = calibrationUs
        ..scriptedOutputLatencyUs = latencyUs
        ..heardLatencyUs = latencyUs
        ..followScheduleNativeNowUs = () => clock.localUs + calibrationUs;
    }

    test('a +60 ms nudge reads ~0 drift: no slew, no resync, no re-apply', () {
      fakeAsync((async) {
        followSchedule();
        clock.sessionOffsetUs = 1000000;
        clock.localUs = 5000000;
        final controller = buildController();
        final samples = <DriftSample>[];
        controller.driftSamples.listen(samples.add);
        controller.setManualOffsetUs(60000);
        // Starts 750 ms from now, 45 s into the track.
        controller.onSnapshot(
          playingSnapshot(
            anchorHostTimeUs: 6750000,
            anchorPositionUs: 45000000,
          ),
        );
        async.flushMicrotasks();
        expect(player.playAtCalls, hasLength(1));

        for (var i = 1; i <= 10; i++) {
          clock.localUs = 5750000 + i * 1000000;
          controller.checkDriftNow();
          async.flushMicrotasks();
        }

        expect(samples, hasLength(10));
        for (final sample in samples) {
          expect(sample.errorUs.abs(), lessThan(1000));
          expect(sample.action, isA<DriftNone>());
        }
        // What the player reads IS the nudge ahead of the room — the +60 ms
        // the unfixed check took for drift.
        final roomUs = controller.snapshot!.positionAt(clock.sessionNowUs());
        expect(samples.last.actualUs - roomUs, 60000);
        expect(samples.last.expectedUs, roomUs + 60000);
        expect(controller.slewCount, 0);
        expect(controller.resyncCount, 0);
        expect(player.setRateCalls, isEmpty);
        expect(player.playAtCalls, hasLength(1), reason: 'never re-anchored');
        expect(player.calibrateCount, 1);

        controller.dispose();
        async.flushMicrotasks();
      });
    });

    test('a nudge scales with the playback rate', () {
      fakeAsync((async) {
        followSchedule();
        final controller = buildController();
        controller.setManualOffsetUs(60000);
        controller.onSnapshot(
          playingSnapshot(anchorHostTimeUs: 0, anchorPositionUs: 0, rate: 1.25),
        );
        async.flushMicrotasks();

        clock.localUs = 8000000;
        controller.checkDriftNow();
        async.flushMicrotasks();

        // 60 ms of native time is 75 ms of media at 1.25×.
        expect(controller.lastSample?.expectedUs, 10000000 + 75000);
        expect(controller.lastSample?.errorUs.abs(), lessThan(1000));
        expect(controller.lastSample?.action, isA<DriftNone>());
        expect(controller.resyncCount, 0);

        controller.dispose();
        async.flushMicrotasks();
      });
    });

    test('changing the nudge mid-track re-applies once, then reads 0', () {
      fakeAsync((async) {
        followSchedule();
        final controller = buildController();
        controller.onSnapshot(
          playingSnapshot(anchorHostTimeUs: 0, anchorPositionUs: 0),
        );
        async.flushMicrotasks();

        clock.localUs = 10000000;
        controller.checkDriftNow();
        async.flushMicrotasks();
        expect(controller.lastSample?.errorUs.abs(), lessThan(1000));

        for (final nudgeUs in [60000, -40000, 120000]) {
          final playAtsBefore = player.playAtCalls.length;
          controller.setManualOffsetUs(nudgeUs);
          async.flushMicrotasks();
          expect(
            player.playAtCalls,
            hasLength(playAtsBefore + 1),
            reason: 'the new nudge is heard at once',
          );

          for (var i = 0; i < 3; i++) {
            clock.localUs += 1000000;
            controller.checkDriftNow();
            async.flushMicrotasks();
            expect(controller.lastSample?.errorUs.abs(), lessThan(1000));
            expect(controller.lastSample?.action, isA<DriftNone>());
          }
          expect(
            player.playAtCalls,
            hasLength(playAtsBefore + 1),
            reason: 'and then left alone',
          );
        }
        expect(controller.slewCount, 0);
        expect(controller.resyncCount, 0);

        controller.dispose();
        async.flushMicrotasks();
      });
    });

    test('a nudged device back in the foreground does not re-anchor', () {
      fakeAsync((async) {
        followSchedule();
        final controller = buildController();
        controller.setManualOffsetUs(60000);
        controller.onSnapshot(
          playingSnapshot(anchorHostTimeUs: 0, anchorPositionUs: 0),
        );
        async.flushMicrotasks();

        clock.localUs = 30000000;
        controller.reverifySync();
        async.flushMicrotasks();

        expect(player.playAtCalls, hasLength(1));
        expect(controller.lastSample?.action, isA<DriftNone>());
        expect(controller.resyncCount, 0);

        controller.dispose();
        async.flushMicrotasks();
      });
    });

    test('a nudge that puts the heard position past the end finishes the '
        'track instead of resyncing', () {
      fakeAsync((async) {
        final controller = buildController();
        controller.setManualOffsetUs(60000);
        controller.onSnapshot(
          playingSnapshot(anchorHostTimeUs: 0, anchorPositionUs: 0),
        );
        async.flushMicrotasks();

        // The room is 30 ms short of the 180 s end; the nudged player has
        // run out and sits at the end — 90 ms behind the nudged expectation
        // were the end not taken into account.
        clock.localUs = 179970000;
        player.scriptedPositionUs = 179940000;
        controller.checkDriftNow();
        async.flushMicrotasks();

        expect(controller.trackFinished.value, isTrue);
        expect(controller.resyncCount, 0);
        expect(player.playAtCalls, hasLength(1));

        controller.dispose();
        async.flushMicrotasks();
      });
    });
  });

  group('player events (interruptions, route changes, end of file)', () {
    int playAtCount() => player.playAtCalls.length;
    int driftPolls() => player.calls.where((c) => c == 'positionUs').length;

    test('a burst of events coalesces into one recalibrate + re-playAt', () {
      fakeAsync((async) {
        final controller = buildController();
        controller.onSnapshot(
          playingSnapshot(anchorHostTimeUs: 0, anchorPositionUs: 0),
        );
        async.flushMicrotasks();
        expect(playAtCount(), 1);
        expect(player.calibrateCount, 1);

        // Route change + engine restart + interruption end arrive together.
        player.eventsController
          ..add(
            const LocaljamAudioEvent(kind: LocaljamAudioEventKind.routeChanged),
          )
          ..add(
            const LocaljamAudioEvent(
              kind: LocaljamAudioEventKind.engineRestarted,
            ),
          )
          ..add(
            const LocaljamAudioEvent(
              kind: LocaljamAudioEventKind.interruptionEnded,
            ),
          );
        async.flushMicrotasks();
        expect(playAtCount(), 1, reason: 'debounce still pending');

        async.elapse(const Duration(milliseconds: 250));
        expect(playAtCount(), 2, reason: 'exactly one re-apply per burst');
        expect(player.calibrateCount, 2, reason: 'calibration cache dropped');
        // Re-anchored from the SAME authoritative anchor.
        expect(player.playAtCalls[1].positionUs, 0);

        // No further re-applies without further events.
        player.scriptedPositionUs = 0;
        async.elapse(const Duration(seconds: 2));
        expect(playAtCount(), 2);

        controller.dispose();
        async.flushMicrotasks();
      });
    });

    test('events while paused refresh state but do not schedule', () {
      fakeAsync((async) {
        final controller = buildController();
        controller.onSnapshot(
          const PlaybackSnapshot(
            rev: 1,
            status: PlaybackStatus.paused,
            mediaId: 'm_1',
            positionUs: 1000,
          ),
        );
        async.flushMicrotasks();

        player.eventsController.add(
          const LocaljamAudioEvent(
            kind: LocaljamAudioEventKind.interruptionEnded,
          ),
        );
        async.elapse(const Duration(milliseconds: 500));
        expect(playAtCount(), 0);

        controller.dispose();
        async.flushMicrotasks();
      });
    });

    test(
      'interruptionBegan stops the drift loop; ended resumes via re-apply',
      () {
        fakeAsync((async) {
          final controller = buildController();
          controller.onSnapshot(
            playingSnapshot(anchorHostTimeUs: 0, anchorPositionUs: 0),
          );
          async.flushMicrotasks();
          player.scriptedPositionUs = 0;
          async.elapse(const Duration(seconds: 2));
          expect(driftPolls(), 2);

          player.eventsController.add(
            const LocaljamAudioEvent(
              kind: LocaljamAudioEventKind.interruptionBegan,
            ),
          );
          async.elapse(const Duration(seconds: 5));
          expect(driftPolls(), 2, reason: 'no drift polls while interrupted');
          expect(playAtCount(), 1, reason: 'no re-apply on began');

          player.eventsController.add(
            const LocaljamAudioEvent(
              kind: LocaljamAudioEventKind.interruptionEnded,
            ),
          );
          async.elapse(const Duration(milliseconds: 250));
          expect(playAtCount(), 2, reason: 're-applied after interruption');
          async.elapse(const Duration(seconds: 1));
          expect(driftPolls(), 3, reason: 'drift loop resumed');

          controller.dispose();
          async.flushMicrotasks();
        });
      },
    );

    test('routeChanged latency is used for the re-scheduled playAt', () {
      fakeAsync((async) {
        final controller = buildController();
        controller.onSnapshot(
          playingSnapshot(anchorHostTimeUs: 1000000, anchorPositionUs: 0),
        );
        async.flushMicrotasks();
        expect(playAtCount(), 1);

        player.eventsController.add(
          const LocaljamAudioEvent(
            kind: LocaljamAudioEventKind.routeChanged,
            outputLatencyUs: 120000,
          ),
        );
        async.elapse(const Duration(milliseconds: 250));
        expect(playAtCount(), 2);
        // Same anchor and calibration; only the route latency changed.
        expect(
          player.playAtCalls[1].nativeTimeUs,
          player.playAtCalls[0].nativeTimeUs - 120000,
        );

        controller.dispose();
        async.flushMicrotasks();
      });
    });

    test('manual nudge re-applies immediately despite a pending debounce', () {
      fakeAsync((async) {
        final controller = buildController();
        controller.onSnapshot(
          playingSnapshot(anchorHostTimeUs: 0, anchorPositionUs: 0),
        );
        async.flushMicrotasks();
        expect(playAtCount(), 1);

        player.eventsController.add(
          const LocaljamAudioEvent(kind: LocaljamAudioEventKind.routeChanged),
        );
        controller.setManualOffsetUs(50000);
        async.flushMicrotasks();
        expect(playAtCount(), 2, reason: 'nudge not swallowed by debounce');
        expect(
          player.playAtCalls[1].nativeTimeUs,
          player.playAtCalls[0].nativeTimeUs - 50000,
        );

        controller.dispose();
        async.flushMicrotasks();
      });
    });

    test('playbackFinished stops the drift loop and blocks re-playAt for the '
        'rev', () {
      fakeAsync((async) {
        final controller = buildController();
        controller.onSnapshot(
          playingSnapshot(anchorHostTimeUs: 0, anchorPositionUs: 0),
        );
        async.flushMicrotasks();
        expect(playAtCount(), 1);
        expect(controller.trackFinished.value, isFalse);

        player.eventsController.add(
          const LocaljamAudioEvent(
            kind: LocaljamAudioEventKind.playbackFinished,
          ),
        );
        async.flushMicrotasks();
        expect(controller.trackFinished.value, isTrue);

        player.scriptedPositionUs = 180000000;
        async.elapse(const Duration(seconds: 5));
        expect(driftPolls(), 0, reason: 'drift loop stopped');

        // A nudge re-apply must NOT re-schedule the finished rev.
        controller.setManualOffsetUs(10000);
        async.flushMicrotasks();
        expect(playAtCount(), 1);
        expect(controller.trackFinished.value, isTrue);

        controller.dispose();
        async.flushMicrotasks();
      });
    });

    test('expected position beyond the duration never calls playAt', () {
      fakeAsync((async) {
        player.scriptedDurationUs = 180000000; // 3 min
        final controller = buildController();
        // Anchor extrapolates to 200 s — past the end of the file.
        clock.localUs = 200000000;
        controller.onSnapshot(
          playingSnapshot(anchorHostTimeUs: 0, anchorPositionUs: 0),
        );
        async.flushMicrotasks();

        expect(player.loadedPaths, hasLength(1));
        expect(playAtCount(), 0, reason: 'no bad_position schedules');
        expect(controller.trackFinished.value, isTrue);
        async.elapse(const Duration(seconds: 5));
        expect(driftPolls(), 0);

        controller.dispose();
        async.flushMicrotasks();
      });
    });

    test(
      'drift check past the end enters trackFinished instead of resyncing',
      () {
        fakeAsync((async) {
          final controller = buildController();
          controller.onSnapshot(
            playingSnapshot(anchorHostTimeUs: 0, anchorPositionUs: 0),
          );
          async.flushMicrotasks();
          expect(playAtCount(), 1);

          // The anchor now extrapolates past the 180 s file; the player is
          // pinned at the end. Without the clamp this would hard-resync.
          clock.localUs = 181000000;
          player.scriptedPositionUs = 179000000;
          controller.checkDriftNow();
          async.flushMicrotasks();

          expect(controller.resyncCount, 0);
          expect(controller.trackFinished.value, isTrue);
          expect(playAtCount(), 1);

          controller.dispose();
          async.flushMicrotasks();
        });
      },
    );

    test('a fresh in-bounds snapshot recovers from trackFinished', () {
      fakeAsync((async) {
        final controller = buildController();
        controller.onSnapshot(
          playingSnapshot(anchorHostTimeUs: 0, anchorPositionUs: 0),
        );
        async.flushMicrotasks();
        player.eventsController.add(
          const LocaljamAudioEvent(
            kind: LocaljamAudioEventKind.playbackFinished,
          ),
        );
        async.flushMicrotasks();
        expect(controller.trackFinished.value, isTrue);
        expect(playAtCount(), 1);

        // Host seeks / starts the next track: new rev, in-bounds anchor.
        clock.localUs = 200000000;
        controller.onSnapshot(
          playingSnapshot(
            rev: 2,
            anchorHostTimeUs: 200750000,
            anchorPositionUs: 0,
          ),
        );
        async.flushMicrotasks();
        expect(playAtCount(), 2, reason: 'plays the re-anchored snapshot');
        expect(controller.trackFinished.value, isFalse);

        player.scriptedPositionUs = 0;
        async.elapse(const Duration(seconds: 1));
        expect(driftPolls(), 1, reason: 'drift loop running again');

        controller.dispose();
        async.flushMicrotasks();
      });
    });
  });
}
