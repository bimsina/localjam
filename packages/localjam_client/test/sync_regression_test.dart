/// [AudioSyncController] regressions from the adversarial review of the
/// suspension/backoff/clock work: interruptions that outlive a native
/// failure, engines that restart a little later than "right after", loads a
/// suspension superseded, slow re-applies vs the drift loop, unplugs while
/// the room is paused (and headphones coming back), permanent focus loss,
/// slews the output refuses, and route-change re-anchors. Scripted clocks, a
/// fake player, fake_async for every timer.
library;

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_audio/localjam_audio.dart';
import 'package:localjam_client/src/audio_sync_controller.dart';
import 'package:localjam_net/localjam_net.dart';

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
LocaljamAudioEvent _route(String? routeId, {bool lost = false}) =>
    LocaljamAudioEvent(
      kind: LocaljamAudioEventKind.routeChanged,
      routeId: routeId,
      oldDeviceUnavailable: lost,
    );
LocaljamAudioEvent _error(String code) => LocaljamAudioEvent(
  kind: LocaljamAudioEventKind.playbackError,
  code: code,
  message: 'native said no',
);

PlaybackSnapshot _paused({int rev = 1, String mediaId = 'm_1'}) =>
    PlaybackSnapshot(
      rev: rev,
      status: PlaybackStatus.paused,
      mediaId: mediaId,
      positionUs: 0,
      rate: 1.0,
    );

void main() {
  late FakeLocaljamAudio player;
  late ScriptedClock clock;

  setUp(() {
    player = FakeLocaljamAudio();
    clock = ScriptedClock();
  });

  AudioSyncController build({
    bool Function()? clockReady,
    bool Function()? clockStepPending,
    void Function()? acknowledgeClockStep,
    int maxFailureRetries = 6,
    MediaPathResolver? resolveMediaPath,
  }) => AudioSyncController(
    player: player,
    sessionNowUs: clock.sessionNowUs,
    localNowUs: clock.localNowUs,
    sessionToLocalUs: clock.sessionToLocalUs,
    resolveMediaPath:
        resolveMediaPath ?? (mediaId) async => '/tmp/$mediaId.mp3',
    clockReady: clockReady,
    clockStepPending: clockStepPending,
    acknowledgeClockStep: acknowledgeClockStep,
    maxFailureRetries: maxFailureRetries,
  );

  int playAts() => player.playAtCalls.length;

  void finish(FakeAsync async, AudioSyncController controller) {
    controller.dispose();
    async.flushMicrotasks();
  }

  group('interruptions', () {
    test('a retryable native error during an interruption never playAts '
        'while the OS holds the audio; the interruption end re-applies', () {
      fakeAsync((async) {
        final controller = build();
        controller.onSnapshot(
          playingSnapshot(anchorHostTimeUs: 0, anchorPositionUs: 0),
        );
        async.flushMicrotasks();
        expect(playAts(), 1);

        player.emit(_began); // A call: native stopped, no end yet.
        async.flushMicrotasks();
        player.emit(_error('writer_failed')); // A stray failure meanwhile.
        async.elapse(const Duration(minutes: 1));
        expect(playAts(), 1, reason: 'no playAt into the call');
        expect(
          controller.outputSuspension.value?.reason,
          JamOutputSuspendReason.interruption,
          reason: 'what the user sees is still the call',
        );
        expect(controller.lastError.value, contains('writer_failed'));

        player.emit(_ended(shouldResume: true));
        async.elapse(const Duration(seconds: 1));
        expect(controller.outputSuspension.value, isNull);
        expect(playAts(), 2);
        finish(async, controller);
      });
    });

    test('"Resume audio" during a call is taken at its word: a retryable '
        'failure after it is retried, not mistaken for the call', () {
      fakeAsync((async) {
        final controller = build();
        controller.onSnapshot(
          playingSnapshot(anchorHostTimeUs: 0, anchorPositionUs: 0),
        );
        async.flushMicrotasks();
        player.emit(_began);
        async.flushMicrotasks();
        expect(
          controller.outputSuspension.value?.reason,
          JamOutputSuspendReason.interruption,
        );

        controller.resumeLocalOutput(); // The user, mid-call or after it.
        async.flushMicrotasks();
        expect(controller.outputSuspension.value, isNull);
        expect(playAts(), 2);

        player.emit(_error('writer_failed'));
        async.flushMicrotasks();
        expect(
          controller.outputSuspension.value?.reason,
          JamOutputSuspendReason.playbackError,
          reason: 'the OS no longer holds the audio as far as we know',
        );
        expect(controller.outputSuspension.value?.willRetry, isTrue);
        async.elapse(const Duration(seconds: 2));
        expect(controller.outputSuspension.value, isNull);
        expect(playAts(), 3, reason: 'retried after the backoff');
        finish(async, controller);
      });
    });

    test('an item that cannot be decoded during a call stays the call once '
        'the room moves on to a playable item', () {
      fakeAsync((async) {
        final controller = build();
        controller.onSnapshot(
          playingSnapshot(anchorHostTimeUs: 0, anchorPositionUs: 0),
        );
        async.flushMicrotasks();
        player
          ..emit(_began)
          ..emit(_error('decode_failed'));
        async.flushMicrotasks();
        expect(controller.outputSuspension.value?.willRetry, isFalse);

        controller.onSnapshot(
          playingSnapshot(
            rev: 2,
            mediaId: 'm_2',
            anchorHostTimeUs: 0,
            anchorPositionUs: 0,
          ),
        );
        async.elapse(const Duration(seconds: 5));
        expect(
          controller.outputSuspension.value?.reason,
          JamOutputSuspendReason.interruption,
        );
        expect(playAts(), 1, reason: 'the OS still holds the audio');
        finish(async, controller);
      });
    });

    test('a permanent focus loss (interruptionBegan shouldResume: false) is '
        'another app playing: it never resumes by itself', () {
      fakeAsync((async) {
        final controller = build();
        controller.onSnapshot(
          playingSnapshot(anchorHostTimeUs: 0, anchorPositionUs: 0),
        );
        async.flushMicrotasks();
        player.emit(
          const LocaljamAudioEvent(
            kind: LocaljamAudioEventKind.interruptionBegan,
            shouldResume: false,
          ),
        );
        async.elapse(const Duration(minutes: 1));
        final suspension = controller.outputSuspension.value!;
        expect(suspension.reason, JamOutputSuspendReason.focusLost);
        expect(suspension.mayAutoResume, isFalse);
        expect(playAts(), 1);

        controller.resumeLocalOutput();
        async.flushMicrotasks();
        expect(playAts(), 2);
        expect(controller.outputSuspension.value, isNull);
        finish(async, controller);
      });
    });
  });

  group('failure accounting', () {
    test('an engine that restarts ~1.5 s after every schedule is given up '
        'on: reading a position in between is not "healthy"', () {
      fakeAsync((async) {
        final controller = build();
        player.scriptedPositionUs = 0;
        controller.onSnapshot(
          playingSnapshot(anchorHostTimeUs: 0, anchorPositionUs: 0),
        );
        async.flushMicrotasks();
        for (var i = 0; i < 40; i++) {
          async.elapse(const Duration(milliseconds: 1500));
          clock.localUs += 1500000;
          player.scriptedPositionUs = clock.localUs; // healthy-looking
          player.emit(_restarted);
          async.flushMicrotasks();
          if (controller.outputSuspension.value != null) break;
        }
        expect(
          controller.outputSuspension.value?.errorCode,
          'engine_restart_loop',
          reason: 'playAts: ${playAts()}',
        );
        expect(controller.outputSuspension.value?.willRetry, isFalse);
        finish(async, controller);
      });
    });

    test('decode_failed reported while a NEW item\'s playAt is in flight is '
        'blamed on the new item, not retried', () {
      fakeAsync((async) {
        final controller = build();
        controller.onSnapshot(
          playingSnapshot(
            mediaId: 'm_a',
            anchorHostTimeUs: 0,
            anchorPositionUs: 0,
          ),
        );
        async.flushMicrotasks();
        player.onPlayAt = () {
          player.onPlayAt = null;
          player.emit(_error('decode_failed'));
        };
        controller.onSnapshot(
          playingSnapshot(
            rev: 2,
            mediaId: 'm_b',
            anchorHostTimeUs: 0,
            anchorPositionUs: 0,
          ),
        );
        async.elapse(const Duration(seconds: 30));
        final suspension = controller.outputSuspension.value;
        expect(suspension?.errorCode, 'decode_failed');
        expect(suspension?.willRetry, isFalse, reason: '$suspension');
        expect(player.countOf('playAt'), 2, reason: 'no decode loop');
        finish(async, controller);
      });
    });
  });

  group('loads', () {
    test('a load a suspension superseded still publishes its own duration '
        'on resume — not the previous item\'s', () {
      fakeAsync((async) {
        final slowB = Completer<int>();
        player.loadHandler = (path) =>
            path.endsWith('m_b.mp3') ? slowB.future : Future.value(10000000);
        final controller = build();
        controller.onSnapshot(
          playingSnapshot(
            mediaId: 'm_a',
            anchorHostTimeUs: 0,
            anchorPositionUs: 0,
          ),
        );
        async.flushMicrotasks();
        expect(controller.loadedDurationUs.value, 10000000);

        // The room moves to B (3 min long), 60 s in; B loads slowly, and a
        // call lands meanwhile.
        controller.onSnapshot(
          playingSnapshot(
            rev: 2,
            mediaId: 'm_b',
            anchorHostTimeUs: 0,
            anchorPositionUs: 60000000,
          ),
        );
        async.flushMicrotasks();
        player.emit(_began);
        async.flushMicrotasks();
        slowB.complete(180000000);
        async.flushMicrotasks();
        player.emit(_ended(shouldResume: true));
        async.elapse(const Duration(seconds: 1));

        expect(controller.loadedDurationUs.value, 180000000);
        expect(controller.trackFinished.value, isFalse, reason: 'mid-track');
        expect(playAts(), 2, reason: 'B is scheduled');
        expect(player.playAtCalls.last.positionUs, 60000000);
        finish(async, controller);
      });
    });

    test('a file that vanished between resolving and loading is asked for '
        'again: parked until it is available, not failed for good', () {
      fakeAsync((async) {
        var available = true;
        final controller = AudioSyncController(
          player: player,
          sessionNowUs: clock.sessionNowUs,
          localNowUs: clock.localNowUs,
          sessionToLocalUs: clock.sessionToLocalUs,
          resolveMediaPath: (mediaId) async =>
              available ? '/cache/$mediaId.mp3' : null,
        );
        player.loadHandler = (_) async {
          // The cache evicts the file right as it is opened.
          available = false;
          throw PlatformException(code: 'load_failed');
        };
        controller.onSnapshot(
          playingSnapshot(anchorHostTimeUs: 0, anchorPositionUs: 0),
        );
        async.elapse(const Duration(seconds: 5));
        expect(controller.outputSuspension.value, isNull);
        expect(controller.lastError.value, isNull);
        expect(player.countOf('load'), 1, reason: 'parked, not retried');

        // Fetched again.
        available = true;
        player.loadHandler = null;
        controller.notifyMediaAvailable('m_1');
        async.flushMicrotasks();
        expect(playAts(), 1);
        finish(async, controller);
      });
    });

    test('drift ticks never supersede their own re-apply when a load takes '
        'longer than the drift interval', () {
      fakeAsync((async) {
        var ready = false;
        final controller = build(clockReady: () => ready);
        player.loadHandler = (_) => Future<int>.delayed(
          const Duration(milliseconds: 1500),
          () => 180000000,
        );
        controller.onSnapshot(
          playingSnapshot(anchorHostTimeUs: 0, anchorPositionUs: 0),
        );
        async.elapse(const Duration(seconds: 2)); // Loaded; clock not ready.
        expect(player.playAtCalls, isEmpty);
        controller.invalidateLoadedMedia(); // The next re-apply must load.
        ready = true;
        async.elapse(const Duration(seconds: 10));
        expect(player.playAtCalls, isNotEmpty, reason: 'never scheduled');
        expect(
          player.countOf('load'),
          lessThanOrEqualTo(4),
          reason: 'loads are not re-issued every tick',
        );
        finish(async, controller);
      });
    });

    test('A → B → A with loads answered in order (as the native thread '
        'does): A is what ends up loaded and scheduled', () {
      fakeAsync((async) {
        final slowB = Completer<int>();
        player
          ..serializeLoads = true
          ..loadHandler = (path) => path.endsWith('m_b.mp3')
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
        expect(playAts(), 1, reason: 'A waits behind B on the native thread');
        slowB.complete(player.scriptedDurationUs);
        async.flushMicrotasks();
        expect(player.loadedPaths, [
          '/tmp/m_a.mp3',
          '/tmp/m_b.mp3',
          '/tmp/m_a.mp3',
        ]);
        expect(playAts(), 2);

        // A seek within A trusts what is loaded: no reload.
        controller.onSnapshot(
          playingSnapshot(
            rev: 4,
            mediaId: 'm_a',
            anchorHostTimeUs: 0,
            anchorPositionUs: 5000000,
          ),
        );
        async.flushMicrotasks();
        expect(player.countOf('load'), 3);
        expect(playAts(), 3);
        finish(async, controller);
      });
    });
  });

  group('lost output', () {
    test('headphones unplugged while the room is PAUSED suspend nothing '
        'then — but someone else starting the room does not put this '
        'device on the loudspeaker: the start is held as outputLost', () {
      fakeAsync((async) {
        player.scriptedRouteId = 'wired:abc';
        final controller = build();
        controller.onSnapshot(_paused());
        async.flushMicrotasks();
        player.emit(_route('speaker', lost: true));
        async.flushMicrotasks();
        expect(controller.outputSuspension.value, isNull);
        expect(player.countOf('stop'), 1, reason: 'native stopped anyway');

        // Another guest presses play.
        controller.onSnapshot(
          playingSnapshot(rev: 2, anchorHostTimeUs: 0, anchorPositionUs: 0),
        );
        async.elapse(const Duration(seconds: 2));
        expect(playAts(), 0, reason: 'never on the speaker unasked');
        expect(
          controller.outputSuspension.value?.reason,
          JamOutputSuspendReason.outputLost,
        );

        // The same headphones back in: this device joins the room.
        clock.localUs = 30000000;
        player.emit(_route('wired:abc'));
        async.elapse(const Duration(seconds: 1));
        expect(controller.outputSuspension.value, isNull);
        expect(playAts(), 1);
        finish(async, controller);
      });
    });

    test('after a pause-time unplug, this device\'s own play '
        '(acceptCurrentRoute) plays on the new route', () {
      fakeAsync((async) {
        final controller = build();
        controller.onSnapshot(_paused());
        async.flushMicrotasks();
        player.emit(_route('speaker', lost: true));
        async.flushMicrotasks();

        controller.acceptCurrentRoute(); // This device pressed play.
        controller.onSnapshot(
          playingSnapshot(rev: 2, anchorHostTimeUs: 0, anchorPositionUs: 0),
        );
        async.elapse(const Duration(seconds: 2));
        expect(controller.outputSuspension.value, isNull);
        expect(playAts(), 1);
        finish(async, controller);
      });
    });

    test('headphones unplugged and plugged back in while paused: the next '
        'start plays on them as if they never left', () {
      fakeAsync((async) {
        player.scriptedRouteId = 'wired:abc';
        final controller = build();
        controller.onSnapshot(_paused());
        async.flushMicrotasks();
        player.emit(_route('speaker', lost: true));
        async.flushMicrotasks();
        // Another route is not the one lost.
        player.emit(_route('bt:xyz'));
        async.flushMicrotasks();
        player.emit(_route('wired:abc'));
        async.elapse(const Duration(seconds: 1));

        controller.onSnapshot(
          playingSnapshot(rev: 2, anchorHostTimeUs: 0, anchorPositionUs: 0),
        );
        async.elapse(const Duration(seconds: 2));
        expect(controller.outputSuspension.value, isNull);
        expect(playAts(), 1);
        finish(async, controller);
      });
    });

    test('the lost headphones coming back resume by themselves; another '
        'route does not', () {
      fakeAsync((async) {
        player.scriptedRouteId = 'wired:abc';
        final controller = build();
        controller.onSnapshot(
          playingSnapshot(anchorHostTimeUs: 0, anchorPositionUs: 0),
        );
        async.flushMicrotasks();
        expect(playAts(), 1);

        player.emit(_route('speaker', lost: true));
        async.flushMicrotasks();
        expect(
          controller.outputSuspension.value?.reason,
          JamOutputSuspendReason.outputLost,
        );
        // Bluetooth earbuds connect instead: still not where the user was.
        player.emit(_route('bt:xyz'));
        async.elapse(const Duration(seconds: 2));
        expect(playAts(), 1);
        expect(controller.isOutputSuspended, isTrue);

        // The wired headphones are plugged back in: rejoin the room.
        clock.localUs = 30000000;
        player.emit(_route('wired:abc'));
        async.elapse(const Duration(seconds: 1));
        expect(controller.outputSuspension.value, isNull);
        expect(playAts(), 2);
        finish(async, controller);
      });
    });
  });

  group('slews the output refuses', () {
    test('a setRate that throws leaves no slew stuck "in flight"', () {
      fakeAsync((async) {
        final controller = build();
        controller.onSnapshot(
          playingSnapshot(anchorHostTimeUs: 0, anchorPositionUs: 0),
        );
        async.flushMicrotasks();
        player.setRateHandler = (_) async =>
            throw PlatformException(code: 'engine_error');
        player.scriptedPositionUs = 20000; // 20 ms ahead: slew band.
        controller.checkDriftNow();
        async.flushMicrotasks();
        expect(controller.isSlewing, isFalse);
        expect(controller.lastError.value, contains('engine_error'));

        player.setRateHandler = null;
        controller.checkDriftNow();
        async.flushMicrotasks();
        expect(controller.isSlewing, isTrue, reason: 'slewing works again');
        expect(controller.slewCount, 1);
        finish(async, controller);
      });
    });

    test('bad_args for an in-range rate (an Android output that cannot '
        'time-stretch it) re-anchors instead, until the route changes', () {
      fakeAsync((async) {
        final controller = build();
        controller.onSnapshot(
          playingSnapshot(anchorHostTimeUs: 0, anchorPositionUs: 0),
        );
        async.flushMicrotasks();
        player.setRateHandler = (_) async =>
            throw PlatformException(code: 'bad_args');
        player.scriptedPositionUs = 20000;
        controller.checkDriftNow();
        async.flushMicrotasks();
        expect(playAts(), 2, reason: 're-anchored');
        expect(controller.isSlewing, isFalse);
        expect(controller.resyncCount, 1);

        // Next time the output is not asked again — and the band's error is
        // lived with for a while rather than skipped over every second.
        final setRates = player.countOf('setRate');
        controller.checkDriftNow();
        async.flushMicrotasks();
        expect(player.countOf('setRate'), setRates);
        expect(playAts(), 2, reason: 'one re-anchor per 10 s at most');
        clock.localUs = 10000000;
        player.scriptedPositionUs = clock.localUs + 20000;
        controller.checkDriftNow();
        async.flushMicrotasks();
        expect(player.countOf('setRate'), setRates);
        expect(playAts(), 3);

        // A new route may stretch fine: slews are tried again.
        player.setRateHandler = null;
        player.emit(_route('bt:xyz'));
        async.elapse(const Duration(milliseconds: 300));
        controller.checkDriftNow();
        async.flushMicrotasks();
        expect(controller.isSlewing, isTrue);
        finish(async, controller);
      });
    });

    test('with slews refused, a drift that stays in the slew band re-anchors '
        'at most once every 10 s — not an audible skip every second', () {
      fakeAsync((async) {
        final controller = build();
        controller.onSnapshot(
          playingSnapshot(anchorHostTimeUs: 0, anchorPositionUs: 0),
        );
        async.flushMicrotasks();
        expect(playAts(), 1);
        player.setRateHandler = (_) async =>
            throw PlatformException(code: 'bad_args');
        // 25 ms ahead at every look, for 25 s of 1 Hz drift checks.
        for (var second = 1; second <= 25; second++) {
          clock.localUs = second * 1000000;
          player.scriptedPositionUs = clock.localUs + 25000;
          async.elapse(const Duration(seconds: 1));
        }
        // The refusal itself (1 s), then 11 s and 21 s.
        expect(playAts(), 1 + 3);
        expect(controller.resyncCount, 3);

        // Past the band is a hard resync, never held back.
        clock.localUs = 25500000;
        player.scriptedPositionUs = clock.localUs + 80000;
        controller.checkDriftNow();
        async.flushMicrotasks();
        expect(playAts(), 1 + 4);
        finish(async, controller);
      });
    });

    test('a re-apply during an in-flight setRate arms no restore timer', () {
      fakeAsync((async) {
        final controller = build();
        controller.onSnapshot(
          playingSnapshot(anchorHostTimeUs: 0, anchorPositionUs: 0),
        );
        async.flushMicrotasks();
        final gate = Completer<void>();
        player.setRateHandler = (_) => gate.future;
        player.scriptedPositionUs = 20000;
        controller.checkDriftNow();
        async.flushMicrotasks();
        // A seek lands while the slew's setRate is in flight.
        controller.onSnapshot(
          playingSnapshot(rev: 2, anchorHostTimeUs: 0, anchorPositionUs: 9),
        );
        async.flushMicrotasks();
        player
          ..setRateHandler = null
          ..scriptedPositionUs = null; // Nothing more to correct.
        gate.complete();
        async.elapse(const Duration(seconds: 30));
        expect(
          player.setRateCalls,
          hasLength(1),
          reason: 'playAt already restored the nominal rate',
        );
        expect(controller.slewCount, 0);
        finish(async, controller);
      });
    });
  });

  group('clock holds', () {
    test('a re-apply already in flight when the clock is held never '
        'reaches playAt on the stale mapping', () {
      fakeAsync((async) {
        var ready = true;
        final controller = build(clockReady: () => ready);
        controller.onSnapshot(
          playingSnapshot(anchorHostTimeUs: 0, anchorPositionUs: 0),
        );
        async.flushMicrotasks();
        expect(playAts(), 1);

        // A route change's re-apply passes the clock check, then stalls in
        // calibrate (the route change dropped the calibration)...
        clock.localUs = 5000000;
        final gate = Completer<void>();
        player.calibrateGate = gate;
        player.emit(_route('bt:xyz'));
        async.elapse(const Duration(milliseconds: 300));
        expect(player.countOf('calibrate'), 2, reason: 're-apply in flight');

        // ...when the device turns out to have just woken: the mapping is
        // stale by the sleep.
        ready = false;
        controller.holdForClock();
        async.flushMicrotasks();
        gate.complete();
        async.elapse(const Duration(seconds: 3));
        expect(playAts(), 1, reason: 'nothing scheduled on the stale mapping');
        expect(player.countOf('pause'), 1);

        ready = true;
        async.elapse(const Duration(seconds: 1));
        expect(playAts(), 2, reason: 're-anchored once trusted');
        finish(async, controller);
      });
    });
  });

  group('app resume', () {
    test('every resume re-measures the native clock for the next schedule, '
        'even when playback checked out fine', () {
      fakeAsync((async) {
        final controller = build();
        controller.onSnapshot(
          playingSnapshot(anchorHostTimeUs: 0, anchorPositionUs: 0),
        );
        async.flushMicrotasks();
        expect(player.calibrateCount, 1);

        player.scriptedPositionUs = 0; // In sync: nothing to re-apply.
        controller.reverifySync();
        async.flushMicrotasks();
        expect(playAts(), 1);

        controller.setManualOffsetUs(10000);
        async.flushMicrotasks();
        expect(playAts(), 2);
        expect(player.calibrateCount, 2, reason: 're-measured after resume');
        finish(async, controller);
      });
    });
  });

  group('re-anchors', () {
    test('a route change whose saved nudge lands while its re-apply is '
        'pending re-anchors once, with that nudge', () {
      fakeAsync((async) {
        final controller = build();
        controller.onSnapshot(
          playingSnapshot(anchorHostTimeUs: 0, anchorPositionUs: 0),
        );
        async.flushMicrotasks();
        player.emit(_route('bt:xyz'));
        async.flushMicrotasks();
        controller.setManualOffsetUs(120000, coalesce: true);
        async.elapse(const Duration(seconds: 1));
        expect(playAts(), 2, reason: 'one re-anchor, not two');
        expect(
          player.playAtCalls.last.nativeTimeUs,
          player.playAtCalls.first.nativeTimeUs - 120000,
        );

        // Nothing pending: a coalesced value applies at once.
        controller.setManualOffsetUs(0, coalesce: true);
        async.flushMicrotasks();
        expect(playAts(), 3);
        finish(async, controller);
      });
    });

    test('a clock step flagged while paused is acknowledged by the next '
        'schedule, without an extra resync', () {
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
        controller.onSnapshot(_paused());
        async.flushMicrotasks();
        stepped = true; // e.g. the join burst refining after sync (§4)
        async.elapse(const Duration(seconds: 3));
        expect(playAts(), 0);

        controller.onSnapshot(
          playingSnapshot(rev: 2, anchorHostTimeUs: 0, anchorPositionUs: 0),
        );
        async.elapse(const Duration(seconds: 3));
        expect(playAts(), 1);
        expect(acks, 1);
        expect(controller.resyncCount, 0);
        finish(async, controller);
      });
    });
  });

  // From the 2026-10-17 simulator run: a track that could not load showed
  // the previous track's length (00:35 for a 30 s file) — and kept it.
  group('the current item\'s duration', () {
    test('an item whose file is not available yet has no duration — not the '
        'previous item\'s — until its file arrives, paused or not', () {
      fakeAsync((async) {
        var bAvailable = false;
        player.loadHandler = (path) async =>
            path.endsWith('m_b.mp3') ? 30000000 : 35000000;
        final controller = build(
          resolveMediaPath: (mediaId) async =>
              mediaId == 'm_b' && !bAvailable ? null : '/tmp/$mediaId.mp3',
        );
        controller.onSnapshot(_paused(mediaId: 'm_a'));
        async.flushMicrotasks();
        expect(controller.loadedDurationUs.value, 35000000);

        controller.onSnapshot(_paused(rev: 2, mediaId: 'm_b'));
        async.flushMicrotasks();
        expect(controller.loadedDurationUs.value, isNull);

        // The file lands (a guest's Retry) while the room is still paused.
        bAvailable = true;
        controller.notifyMediaAvailable('m_b');
        async.flushMicrotasks();
        expect(controller.loadedDurationUs.value, 30000000);
        finish(async, controller);
      });
    });

    test('an item whose file will not load has no duration, playing or '
        'paused', () {
      fakeAsync((async) {
        player.loadHandler = (path) async {
          if (path.endsWith('m_b.mp3')) {
            throw PlatformException(code: 'load_failed');
          }
          return 35000000;
        };
        final controller = build();
        controller.onSnapshot(
          playingSnapshot(
            mediaId: 'm_a',
            anchorHostTimeUs: 0,
            anchorPositionUs: 0,
          ),
        );
        async.flushMicrotasks();
        expect(controller.loadedDurationUs.value, 35000000);

        controller.onSnapshot(
          playingSnapshot(
            rev: 2,
            mediaId: 'm_b',
            anchorHostTimeUs: 0,
            anchorPositionUs: 0,
          ),
        );
        async.elapse(const Duration(seconds: 1));
        expect(controller.loadedDurationUs.value, isNull);

        controller.onSnapshot(_paused(rev: 3, mediaId: 'm_b'));
        async.elapse(const Duration(seconds: 1));
        expect(controller.loadedDurationUs.value, isNull);

        // Back to the track that loads: its own length again.
        controller.onSnapshot(_paused(rev: 4, mediaId: 'm_a'));
        async.flushMicrotasks();
        expect(controller.loadedDurationUs.value, 35000000);
        finish(async, controller);
      });
    });

    test('an item still loading has no duration until its load lands, then '
        'its own', () {
      fakeAsync((async) {
        final gate = Completer<int>();
        player.loadHandler = (path) =>
            path.endsWith('m_b.mp3') ? gate.future : Future.value(35000000);
        final controller = build();
        controller.onSnapshot(_paused(mediaId: 'm_a'));
        async.flushMicrotasks();
        controller.onSnapshot(_paused(rev: 2, mediaId: 'm_b'));
        async.flushMicrotasks();
        expect(controller.loadedDurationUs.value, isNull, reason: 'B loading');
        gate.complete(30000000);
        async.flushMicrotasks();
        expect(controller.loadedDurationUs.value, 30000000);
        finish(async, controller);
      });
    });
  });

  // From the 2026-10-17 run: an Android guest on an overloaded emulator
  // hard-resynced every 1–5 s — each one an audible restart.
  group('hard resync backoff', () {
    /// Plays from 0 and then, from [fromS] to [toS], has the output fall
    /// [behindUs] behind the anchor at every 1 Hz drift check. Returns the
    /// seconds at which a hard resync re-scheduled.
    List<int> stall(
      FakeAsync async,
      AudioSyncController controller, {
      required int fromS,
      required int toS,
      int behindUs = 100000,
    }) {
      final at = <int>[];
      for (var second = fromS; second <= toS; second++) {
        clock.localUs = second * 1000000;
        player.scriptedPositionUs = clock.localUs - behindUs;
        final before = playAts();
        async.elapse(const Duration(seconds: 1));
        if (playAts() > before) at.add(second);
      }
      return at;
    }

    test('the first hard resync is immediate; when they keep coming they back '
        'off to ~10 s apart; a healthy minute starts the count over', () {
      fakeAsync((async) {
        final controller = build();
        controller.onSnapshot(
          playingSnapshot(anchorHostTimeUs: 0, anchorPositionUs: 0),
        );
        async.flushMicrotasks();
        expect(playAts(), 1);

        // 100 ms behind at every look for 40 s: 2, 4, 8, then 10 s apart —
        // not 40 restarts.
        expect(stall(async, controller, fromS: 1, toS: 40), [
          1,
          3,
          7,
          15,
          25,
          35,
        ]);
        expect(controller.resyncCount, 6);
        expect(
          controller.lastSample?.action,
          isA<DriftHardResync>(),
          reason: 'what was held back is still reported',
        );

        // The output keeps up for over a minute...
        for (var second = 41; second <= 100; second++) {
          clock.localUs = second * 1000000;
          player.scriptedPositionUs = clock.localUs;
          async.elapse(const Duration(seconds: 1));
        }
        // ...so the next stall is a first one again: at once, then 2 s.
        expect(stall(async, controller, fromS: 101, toS: 104), [101, 103]);
        finish(async, controller);
      });
    });
  });
}
