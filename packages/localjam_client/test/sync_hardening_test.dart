/// [AudioSyncController] against the native audio contract (localjam_audio
/// README "Events") and the §4 clock estimator: local output suspension
/// (interruptions, lost output, native failures and their backoff), clock
/// steps and discontinuities, past-anchor mapping on a skewed clock, load
/// bookkeeping, and end-of-media attribution. Scripted clocks, a fake
/// player, fake_async for every timer.
library;

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_audio/localjam_audio.dart';
import 'package:localjam_client/src/audio_sync_controller.dart';

import 'sync_test_fakes.dart';

const _began = LocaljamAudioEvent(
  kind: LocaljamAudioEventKind.interruptionBegan,
);
LocaljamAudioEvent _ended({bool? shouldResume}) => LocaljamAudioEvent(
  kind: LocaljamAudioEventKind.interruptionEnded,
  shouldResume: shouldResume,
);
const _restarted = LocaljamAudioEvent(
  kind: LocaljamAudioEventKind.engineRestarted,
);
const _unplugged = LocaljamAudioEvent(
  kind: LocaljamAudioEventKind.routeChanged,
  routeId: 'speaker',
  oldDeviceUnavailable: true,
);
const _finished = LocaljamAudioEvent(
  kind: LocaljamAudioEventKind.playbackFinished,
);
LocaljamAudioEvent _error(String code) => LocaljamAudioEvent(
  kind: LocaljamAudioEventKind.playbackError,
  code: code,
  message: 'native said no',
);

void main() {
  late FakeLocaljamAudio player;
  late ScriptedClock clock;

  setUp(() {
    player = FakeLocaljamAudio();
    clock = ScriptedClock();
  });

  AudioSyncController build({
    Future<String?> Function(String mediaId)? resolver,
    bool Function()? clockReady,
    bool Function()? clockStepPending,
    void Function()? acknowledgeClockStep,
    Duration failureBackoffBase = const Duration(milliseconds: 250),
    Duration failureBackoffCap = const Duration(seconds: 30),
    int maxFailureRetries = 6,
  }) => AudioSyncController(
    player: player,
    sessionNowUs: clock.sessionNowUs,
    localNowUs: clock.localNowUs,
    sessionToLocalUs: clock.sessionToLocalUs,
    resolveMediaPath: resolver ?? (mediaId) async => '/tmp/$mediaId.mp3',
    clockReady: clockReady,
    clockStepPending: clockStepPending,
    acknowledgeClockStep: acknowledgeClockStep,
    failureBackoffBase: failureBackoffBase,
    failureBackoffCap: failureBackoffCap,
    maxFailureRetries: maxFailureRetries,
  );

  int playAts() => player.playAtCalls.length;

  group('local output suspension', () {
    test('an interruption suspends output, nothing schedules meanwhile, and '
        'the OS resume hint re-anchors to where the room is now', () {
      fakeAsync((async) {
        final controller = build();
        final changes = <JamOutputSuspension?>[];
        controller.outputSuspensionChanges.listen(changes.add);
        controller.onSnapshot(
          playingSnapshot(anchorHostTimeUs: 0, anchorPositionUs: 0),
        );
        async.flushMicrotasks();
        expect(playAts(), 1);

        player.emit(_began);
        async.flushMicrotasks();
        expect(
          controller.outputSuspension.value?.reason,
          JamOutputSuspendReason.interruption,
        );
        expect(controller.outputSuspension.value?.mayAutoResume, isTrue);

        // The room moves on — a seek, a nudge, an engine restart. On Android
        // every playAt re-requests audio focus from the call that took it.
        clock.localUs = 10000000;
        controller.onSnapshot(
          playingSnapshot(
            rev: 2,
            anchorHostTimeUs: 10000000,
            anchorPositionUs: 5000000,
          ),
        );
        controller.setManualOffsetUs(20000);
        player.emit(_restarted);
        async.elapse(const Duration(seconds: 1));
        expect(playAts(), 1, reason: 'no playAt while suspended');

        player.emit(_ended(shouldResume: true));
        async.elapse(const Duration(milliseconds: 250));
        expect(controller.outputSuspension.value, isNull);
        expect(playAts(), 2);
        final resumed = player.playAtCalls.last;
        expect(resumed.positionUs, 5000000);
        expect(resumed.nativeTimeUs, 10000000 - 20000);
        expect(changes, [
          const JamOutputSuspension(JamOutputSuspendReason.interruption),
          null,
        ]);

        controller.dispose();
        async.flushMicrotasks();
      });
    });

    test('an interruption ended without the resume hint waits for '
        'resumeLocalOutput, which re-anchors and recalibrates', () {
      fakeAsync((async) {
        final controller = build();
        controller.onSnapshot(
          playingSnapshot(anchorHostTimeUs: 0, anchorPositionUs: 0),
        );
        async.flushMicrotasks();
        player
          ..emit(_began)
          ..emit(_ended(shouldResume: false));
        async.elapse(const Duration(seconds: 5));
        expect(
          controller.outputSuspension.value?.reason,
          JamOutputSuspendReason.focusLost,
        );
        expect(controller.outputSuspension.value?.mayAutoResume, isFalse);
        expect(playAts(), 1);

        clock.localUs = 30000000;
        controller.resumeLocalOutput();
        async.flushMicrotasks();
        expect(controller.outputSuspension.value, isNull);
        expect(playAts(), 2);
        // Re-anchored from the room's anchor: native starts 30 s in.
        expect(player.playAtCalls.last.positionUs, 0);
        expect(player.playAtCalls.last.nativeTimeUs, 0);
        expect(player.calibrateCount, 2);

        controller.dispose();
        async.flushMicrotasks();
      });
    });

    test('a playAt the OS refuses (interruption reported mid-call) leaves '
        'no drift loop running', () {
      fakeAsync((async) {
        final controller = build();
        player.onPlayAt = () => player.emit(_began);
        player.scriptedPositionUs = 0;
        controller.onSnapshot(
          playingSnapshot(anchorHostTimeUs: 0, anchorPositionUs: 0),
        );
        async.elapse(const Duration(seconds: 3));
        expect(controller.isOutputSuspended, isTrue);
        expect(player.countOf('positionUs'), 0);

        controller.dispose();
        async.flushMicrotasks();
      });
    });

    test('unplugged headphones stop native output, cancel an engine-restart '
        're-apply that arrived first, and never resume onto the speaker', () {
      fakeAsync((async) {
        final controller = build();
        controller.onSnapshot(
          playingSnapshot(anchorHostTimeUs: 0, anchorPositionUs: 0),
        );
        async.flushMicrotasks();

        // Apple platforms do not order the two notifications: the engine
        // restart caused by the route change can come first.
        player.emit(_restarted);
        async.elapse(const Duration(milliseconds: 100));
        player.emit(_unplugged);
        async.flushMicrotasks();
        expect(player.countOf('stop'), 1);
        expect(
          controller.outputSuspension.value?.reason,
          JamOutputSuspendReason.outputLost,
        );
        async.elapse(const Duration(seconds: 2));
        expect(playAts(), 1, reason: 'no re-apply onto the speaker');

        // A call meanwhile does not end it either.
        player
          ..emit(_began)
          ..emit(_ended(shouldResume: true));
        async.elapse(const Duration(seconds: 2));
        expect(
          controller.outputSuspension.value?.reason,
          JamOutputSuspendReason.outputLost,
        );
        expect(playAts(), 1);

        controller.resumeLocalOutput();
        async.flushMicrotasks();
        expect(playAts(), 2);
        expect(controller.outputSuspension.value, isNull);

        controller.dispose();
        async.flushMicrotasks();
      });
    });

    test('a re-apply already in flight when the output is lost never reaches '
        'playAt', () {
      fakeAsync((async) {
        final controller = build();
        controller.onSnapshot(
          playingSnapshot(anchorHostTimeUs: 0, anchorPositionUs: 0),
        );
        async.flushMicrotasks();
        clock.localUs = 5000000; // Not "right after" the schedule.

        // The restart's debounced re-apply fires and stalls in calibrate.
        final gate = Completer<void>();
        player.calibrateGate = gate;
        player.emit(_restarted);
        async.elapse(const Duration(milliseconds: 250));
        expect(player.countOf('calibrate'), 2, reason: 're-apply in flight');

        player.emit(_unplugged);
        gate.complete();
        async.elapse(const Duration(seconds: 1));
        expect(player.countOf('playAt'), 1);
        expect(player.countOf('stop'), 1);

        controller.dispose();
        async.flushMicrotasks();
      });
    });

    test('decode_failed is terminal for the item: native stopped, never '
        'retried, cleared by the next item', () {
      fakeAsync((async) {
        final controller = build();
        controller.onSnapshot(
          playingSnapshot(anchorHostTimeUs: 0, anchorPositionUs: 0),
        );
        async.flushMicrotasks();
        player.emit(_error('decode_failed'));
        async.flushMicrotasks();
        final suspension = controller.outputSuspension.value!;
        expect(suspension.reason, JamOutputSuspendReason.playbackError);
        expect(suspension.errorCode, 'decode_failed');
        expect(suspension.willRetry, isFalse);
        expect(player.countOf('stop'), 1);
        expect(controller.lastError.value, contains('decode_failed'));

        async.elapse(const Duration(minutes: 1));
        expect(player.countOf('playAt'), 1, reason: 'no decode loop');

        // A seek within the same item: still the undecodable file.
        controller.onSnapshot(
          playingSnapshot(rev: 2, anchorHostTimeUs: 0, anchorPositionUs: 9),
        );
        async.elapse(const Duration(seconds: 5));
        expect(player.countOf('playAt'), 1);
        expect(controller.isOutputSuspended, isTrue);

        // The room moved to another item: a clean slate.
        clock.localUs = 70000000;
        controller.onSnapshot(
          playingSnapshot(
            rev: 3,
            mediaId: 'm_2',
            anchorHostTimeUs: 70000000,
            anchorPositionUs: 0,
          ),
        );
        async.flushMicrotasks();
        expect(controller.outputSuspension.value, isNull);
        expect(playAts(), 2);
        expect(player.loadedPaths.last, '/tmp/m_2.mp3');

        controller.dispose();
        async.flushMicrotasks();
      });
    });

    test('a file the engine cannot load is terminal for that item only, '
        'even right after a different item played fine', () {
      fakeAsync((async) {
        final controller = build();
        controller.onSnapshot(
          playingSnapshot(anchorHostTimeUs: 0, anchorPositionUs: 0),
        );
        async.flushMicrotasks();
        expect(playAts(), 1);

        player.loadHandler = (path) async => path.endsWith('m_bad.mp3')
            ? throw PlatformException(code: 'load_failed')
            : player.scriptedDurationUs;
        controller.onSnapshot(
          playingSnapshot(
            rev: 2,
            mediaId: 'm_bad',
            anchorHostTimeUs: 0,
            anchorPositionUs: 0,
          ),
        );
        async.elapse(const Duration(seconds: 30));
        expect(controller.outputSuspension.value?.errorCode, 'load_failed');
        expect(controller.outputSuspension.value?.willRetry, isFalse);
        expect(
          player.loadedPaths.where((p) => p.endsWith('m_bad.mp3')),
          hasLength(2),
          reason: 'one short native retry, then never again',
        );

        controller.onSnapshot(
          playingSnapshot(
            rev: 3,
            mediaId: 'm_3',
            anchorHostTimeUs: 0,
            anchorPositionUs: 0,
          ),
        );
        async.flushMicrotasks();
        expect(controller.outputSuspension.value, isNull);
        expect(playAts(), 2);

        controller.dispose();
        async.flushMicrotasks();
      });
    });

    test('a decode failure of media the room already left does not block '
        'the current item', () {
      fakeAsync((async) {
        var m2Ready = false;
        final controller = build(
          resolver: (mediaId) async =>
              mediaId == 'm_2' && !m2Ready ? null : '/tmp/$mediaId.mp3',
        );
        controller.onSnapshot(
          playingSnapshot(anchorHostTimeUs: 0, anchorPositionUs: 0),
        );
        async.flushMicrotasks();
        controller.onSnapshot(
          playingSnapshot(
            rev: 2,
            mediaId: 'm_2',
            anchorHostTimeUs: 0,
            anchorPositionUs: 0,
          ),
        );
        async.flushMicrotasks();
        player.emit(_error('decode_failed')); // m_1's late failure
        async.flushMicrotasks();
        expect(controller.outputSuspension.value?.willRetry, isTrue);

        async.elapse(const Duration(milliseconds: 250));
        expect(controller.outputSuspension.value, isNull);
        m2Ready = true;
        controller.notifyMediaAvailable('m_2');
        async.flushMicrotasks();
        expect(playAts(), 2);

        controller.dispose();
        async.flushMicrotasks();
      });
    });

    test('a transient native failure is retried with capped exponential '
        'backoff, then waits for the user', () {
      fakeAsync((async) {
        final controller = build(
          failureBackoffCap: const Duration(seconds: 1),
          maxFailureRetries: 3,
        );
        controller.onSnapshot(
          playingSnapshot(anchorHostTimeUs: 0, anchorPositionUs: 0),
        );
        async.flushMicrotasks();
        expect(playAts(), 1);

        // 250 ms, 500 ms, then the 1 s cap.
        for (final (delayMs, after) in [(250, 2), (500, 3), (1000, 4)]) {
          player.emit(_error('writer_failed'));
          async.flushMicrotasks();
          expect(controller.outputSuspension.value?.willRetry, isTrue);
          expect(player.countOf('stop'), after - 1);
          async.elapse(Duration(milliseconds: delayMs - 1));
          expect(playAts(), after - 1, reason: 'still backing off');
          async.elapse(const Duration(milliseconds: 1));
          expect(playAts(), after);
          expect(controller.outputSuspension.value, isNull);
        }

        // One failure more than the retries allow: it is the user's call.
        player.emit(_error('writer_failed'));
        async.elapse(const Duration(minutes: 1));
        expect(playAts(), 4);
        expect(controller.outputSuspension.value?.willRetry, isFalse);
        expect(controller.outputSuspension.value?.mayAutoResume, isFalse);

        controller.resumeLocalOutput();
        async.flushMicrotasks();
        expect(playAts(), 5);

        controller.dispose();
        async.flushMicrotasks();
      });
    });

    test('a schedule that proves healthy resets the backoff', () {
      fakeAsync((async) {
        final controller = build();
        controller.onSnapshot(
          playingSnapshot(anchorHostTimeUs: 0, anchorPositionUs: 0),
        );
        async.flushMicrotasks();
        player.emit(_error('writer_failed'));
        async.elapse(const Duration(milliseconds: 250));
        player.emit(_error('writer_failed'));
        async.elapse(const Duration(milliseconds: 500));
        expect(playAts(), 3);

        // Audio flows, but only for a second: an engine that falls over that
        // soon after its schedule has not proven anything yet.
        clock.localUs = 1000000;
        player.scriptedPositionUs = 1000000;
        async.elapse(const Duration(seconds: 1));
        player.emit(_error('writer_failed'));
        async.elapse(const Duration(milliseconds: 999));
        expect(playAts(), 3, reason: 'still the third backoff step (1 s)');
        async.elapse(const Duration(milliseconds: 1));
        expect(playAts(), 4);

        // Audio flows for longer than a restart is blamed on its schedule:
        // whatever failed before is behind us.
        clock.localUs = 3000000;
        player.scriptedPositionUs = 3000000;
        async.elapse(const Duration(seconds: 1));

        player.emit(_error('writer_failed'));
        async.elapse(const Duration(milliseconds: 250));
        expect(playAts(), 5, reason: 'back to the first backoff step');

        controller.dispose();
        async.flushMicrotasks();
      });
    });

    test('a refused playAt backs off instead of looping on engine events; '
        'a platform without a native side is left alone', () {
      fakeAsync((async) {
        final controller = build();
        player.playAtErrors.addAll([
          PlatformException(code: 'engine_error'),
          PlatformException(code: 'engine_not_running'),
        ]);
        controller.onSnapshot(
          playingSnapshot(anchorHostTimeUs: 0, anchorPositionUs: 0),
        );
        async.flushMicrotasks();
        expect(
          controller.outputSuspension.value,
          isA<JamOutputSuspension>()
              .having((s) => s.errorCode, 'errorCode', 'engine_error')
              .having((s) => s.willRetry, 'willRetry', true),
        );
        // An engine event while backing off cannot shorten the wait.
        player.emit(_restarted);
        async.elapse(const Duration(milliseconds: 249));
        expect(player.countOf('playAt'), 1);
        async.elapse(const Duration(milliseconds: 1));
        expect(player.countOf('playAt'), 2); // engine_not_running
        async.elapse(const Duration(milliseconds: 499));
        expect(player.countOf('playAt'), 2);
        async.elapse(const Duration(milliseconds: 1));
        expect(playAts(), 1, reason: 'the third attempt plays');
        expect(controller.outputSuspension.value, isNull);
        controller.dispose();
        async.flushMicrotasks();

        // No native side at all (tests, a stub platform): nothing to retry.
        final bare = FakeLocaljamAudio()
          ..playAtErrors.add(MissingPluginException());
        final stub = AudioSyncController(
          player: bare,
          sessionNowUs: clock.sessionNowUs,
          localNowUs: clock.localNowUs,
          sessionToLocalUs: clock.sessionToLocalUs,
          resolveMediaPath: (mediaId) async => '/tmp/$mediaId.mp3',
        );
        stub.onSnapshot(
          playingSnapshot(anchorHostTimeUs: 0, anchorPositionUs: 0),
        );
        async.elapse(const Duration(seconds: 10));
        expect(bare.countOf('playAt'), 1);
        expect(stub.isOutputSuspended, isFalse);
        expect(stub.lastError.value, isNotNull);
        stub.dispose();
        async.flushMicrotasks();
      });
    });

    test('engine restarts right after every schedule (Android decode '
        'failures) back off and then give up', () {
      fakeAsync((async) {
        final controller = build(maxFailureRetries: 3);
        controller.onSnapshot(
          playingSnapshot(anchorHostTimeUs: 0, anchorPositionUs: 0),
        );
        async.flushMicrotasks();
        for (final (delayMs, after) in [(250, 2), (500, 3), (1000, 4)]) {
          player.emit(_restarted); // clock.localUs never moves: "right after"
          async.elapse(Duration(milliseconds: delayMs - 1));
          expect(playAts(), after - 1);
          async.elapse(const Duration(milliseconds: 1));
          expect(playAts(), after);
        }
        player.emit(_restarted);
        async.elapse(const Duration(minutes: 1));
        expect(playAts(), 4);
        expect(
          controller.outputSuspension.value?.errorCode,
          'engine_restart_loop',
        );
        expect(controller.outputSuspension.value?.willRetry, isFalse);

        controller.dispose();
        async.flushMicrotasks();
      });
    });

    test(
      'nudges and resume re-verification never schedule while suspended',
      () {
        fakeAsync((async) {
          final controller = build();
          controller.onSnapshot(
            playingSnapshot(anchorHostTimeUs: 0, anchorPositionUs: 0),
          );
          async.flushMicrotasks();
          player.emit(_unplugged);
          async.flushMicrotasks();
          controller.setManualOffsetUs(40000);
          controller.reverifySync();
          controller.checkDriftNow();
          async.elapse(const Duration(seconds: 3));
          expect(player.countOf('playAt'), 1);
          expect(controller.manualOffsetUs, 40000, reason: 'kept for resume');

          controller.dispose();
          async.flushMicrotasks();
        });
      },
    );
  });

  group('session clock (§4)', () {
    test('a stepped clock re-schedules from the current anchor on the next '
        'drift tick, and the step is acknowledged', () {
      fakeAsync((async) {
        var stepped = false;
        var acks = 0;
        final controller = build(
          clockStepPending: () => stepped,
          acknowledgeClockStep: () {
            stepped = false;
            acks++;
          },
        );
        controller.onSnapshot(
          playingSnapshot(anchorHostTimeUs: 0, anchorPositionUs: 0),
        );
        async.flushMicrotasks();
        expect(playAts(), 1);

        // The estimator stepped the offset by 80 ms.
        clock.sessionOffsetUs += 80000;
        stepped = true;
        async.elapse(const Duration(seconds: 1));
        expect(playAts(), 2);
        expect(acks, 1);
        expect(stepped, isFalse);
        expect(controller.resyncCount, 1);
        expect(
          player.playAtCalls[1].nativeTimeUs,
          player.playAtCalls[0].nativeTimeUs - 80000,
        );

        controller.dispose();
        async.flushMicrotasks();
      });
    });

    test('a discontinuity silences output until the clock is back, then '
        're-schedules', () {
      fakeAsync((async) {
        var ready = true;
        var stepped = false;
        final controller = build(
          clockReady: () => ready,
          clockStepPending: () => stepped,
          acknowledgeClockStep: () => stepped = false,
        );
        controller.onSnapshot(
          playingSnapshot(anchorHostTimeUs: 0, anchorPositionUs: 0),
        );
        async.flushMicrotasks();

        ready = false;
        stepped = true;
        async.elapse(const Duration(seconds: 4));
        expect(player.countOf('pause'), 1, reason: 'paused once, at the jump');
        expect(player.countOf('playAt'), 1);
        expect(controller.lastError.value, isNull);

        ready = true;
        async.elapse(const Duration(seconds: 1));
        expect(playAts(), 2);
        expect(stepped, isFalse);

        controller.dispose();
        async.flushMicrotasks();
      });
    });

    test('a reconnect burst (not ready, no step) leaves the running schedule '
        'alone and defers new ones until the clock is back', () {
      fakeAsync((async) {
        var ready = true;
        final controller = build(clockReady: () => ready);
        controller.onSnapshot(
          playingSnapshot(anchorHostTimeUs: 0, anchorPositionUs: 0),
        );
        async.flushMicrotasks();

        ready = false;
        controller.setManualOffsetUs(10000);
        async.elapse(const Duration(seconds: 3));
        expect(player.countOf('pause'), 0);
        expect(player.countOf('playAt'), 1);
        expect(controller.lastError.value, isNull);

        ready = true;
        async.elapse(const Duration(seconds: 1));
        expect(playAts(), 2);
        expect(
          player.playAtCalls[1].nativeTimeUs,
          player.playAtCalls[0].nativeTimeUs - 10000,
        );

        controller.dispose();
        async.flushMicrotasks();
      });
    });

    test('holdForClock silences output until the clock is trusted again', () {
      fakeAsync((async) {
        var ready = true;
        final controller = build(clockReady: () => ready);
        controller.onSnapshot(
          playingSnapshot(anchorHostTimeUs: 0, anchorPositionUs: 0),
        );
        async.flushMicrotasks();

        // A guest that just woke from a device sleep: the offset is stale
        // by the sleep, and the estimator has not noticed yet.
        ready = false;
        controller.holdForClock();
        async.flushMicrotasks();
        expect(player.countOf('pause'), 1);
        controller.reverifySync();
        async.elapse(const Duration(seconds: 3));
        expect(player.countOf('playAt'), 1);

        ready = true;
        async.elapse(const Duration(seconds: 1));
        expect(playAts(), 2);
        expect(player.calibrateCount, 2, reason: 'native clock re-measured');

        controller.dispose();
        async.flushMicrotasks();
      });
    });

    test('a 10-minute-old anchor on a 100 ppm clock lands within 1 ms of the '
        'room', () {
      // A skewed guest clock: session = local × (1 + 100 ppm) + offset, and
      // sessionToLocalUs extrapolates along that skew, as ClockSync does.
      const skew = 100e-6;
      const offsetUs = 123456789;
      var localUs = 700000000;
      int sessionNow() => (localUs * (1 + skew)).round() + offsetUs;
      int sessionToLocal(int sessionUs) =>
          ((sessionUs - offsetUs) / (1 + skew)).round();
      player.scriptedDurationUs = 3600000000; // an hour-long set
      fakeAsync((async) {
        // Native time is local time (calibration 0, no output latency).
        final controller = AudioSyncController(
          player: player,
          sessionNowUs: sessionNow,
          localNowUs: () => localUs,
          sessionToLocalUs: sessionToLocal,
          resolveMediaPath: (mediaId) async => '/tmp/$mediaId.mp3',
        );
        final snapshot = playingSnapshot(
          anchorHostTimeUs: sessionNow() - 600000000, // 10 minutes ago
          anchorPositionUs: 0,
        );
        controller.onSnapshot(snapshot);
        async.flushMicrotasks();
        final call = player.playAtCalls.single;
        // playAt semantics: a past native time starts at once, advanced by
        // the native (= local) µs since that time.
        final nativePositionUs =
            call.positionUs + ((localUs - call.nativeTimeUs) * call.rate);
        final roomPositionUs = snapshot.positionAt(sessionNow());
        expect(
          (nativePositionUs - roomPositionUs).abs(),
          lessThan(1000),
          reason: 'a skew × age error would be ~60 ms here',
        );

        // A FUTURE anchor is a real instant to start at: extrapolated.
        localUs += 1000000;
        final future = sessionNow() + 500000;
        controller.onSnapshot(
          playingSnapshot(
            rev: 2,
            anchorHostTimeUs: future,
            anchorPositionUs: 0,
          ),
        );
        async.flushMicrotasks();
        expect(player.playAtCalls.last.nativeTimeUs, sessionToLocal(future));

        controller.dispose();
        async.flushMicrotasks();
      });
    });
  });

  group('loads and end of media', () {
    test('a back-and-forth A → B → A reloads A instead of trusting a load '
        'that B is replacing', () {
      fakeAsync((async) {
        final slowB = Completer<int>();
        player.loadHandler = (path) => path.endsWith('m_b.mp3')
            ? slowB.future
            : Future.value(player.scriptedDurationUs);
        final controller = build();
        controller.onSnapshot(
          playingSnapshot(
            mediaId: 'm_a',
            anchorHostTimeUs: 0,
            anchorPositionUs: 0,
          ),
        );
        async.flushMicrotasks();
        expect(playAts(), 1);

        controller.onSnapshot(
          playingSnapshot(
            rev: 2,
            mediaId: 'm_b',
            anchorHostTimeUs: 0,
            anchorPositionUs: 0,
          ),
        );
        async.flushMicrotasks();
        controller.onSnapshot(
          playingSnapshot(
            rev: 3,
            mediaId: 'm_a',
            anchorHostTimeUs: 0,
            anchorPositionUs: 0,
          ),
        );
        async.flushMicrotasks();
        slowB.complete(player.scriptedDurationUs);
        async.flushMicrotasks();

        expect(player.loadedPaths, [
          '/tmp/m_a.mp3',
          '/tmp/m_b.mp3',
          '/tmp/m_a.mp3',
        ]);
        // The last thing loaded before the last playAt is A.
        final lastPlay = player.calls.lastIndexOf('playAt');
        final lastLoad = player.calls.lastIndexOf('load');
        expect(lastLoad, lessThan(lastPlay));
        expect(playAts(), 2);

        controller.dispose();
        async.flushMicrotasks();
      });
    });

    test('playbackFinished names the schedule that finished, and a newer '
        'snapshot waiting for its media is not marked finished', () {
      fakeAsync((async) {
        var m2Available = false;
        final controller = build(
          resolver: (mediaId) async =>
              mediaId == 'm_2' && !m2Available ? null : '/tmp/$mediaId.mp3',
        );
        final finished = <JamPlaybackFinished>[];
        controller.playbackFinished.listen(finished.add);
        controller.onSnapshot(
          playingSnapshot(rev: 4, anchorHostTimeUs: 0, anchorPositionUs: 0),
        );
        async.flushMicrotasks();

        // The host already moved on; m_2 is still being fetched.
        controller.onSnapshot(
          playingSnapshot(
            rev: 5,
            mediaId: 'm_2',
            anchorHostTimeUs: 0,
            anchorPositionUs: 0,
          ),
        );
        async.flushMicrotasks();
        player.emit(_finished); // m_1's schedule ran out.
        async.flushMicrotasks();
        expect(finished, [(mediaId: 'm_1', snapshotRev: 4)]);
        expect(controller.trackFinished.value, isFalse);

        m2Available = true;
        controller.notifyMediaAvailable('m_2');
        async.flushMicrotasks();
        expect(playAts(), 2, reason: 'rev 5 still plays');

        controller.dispose();
        async.flushMicrotasks();
      });
    });
  });
}
