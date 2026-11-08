/// [AudioSyncController] against two platform contracts the drift loop
/// depends on:
///
///  * a slew the playing track refuses is reported, never answered success —
///    `rate_needs_reanchor` (an Android low-latency track without a
///    time-stretcher) re-anchors at once, through the real method channel;
///  * a position is compared with the room's position at the instant the
///    player sampled it, when the player says when that was — a slow reply
///    is not drift.
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_audio/localjam_audio.dart';
import 'package:localjam_client/src/audio_sync_controller.dart';
import 'package:localjam_net/localjam_net.dart';

import 'sync_test_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScriptedClock clock;

  setUp(() => clock = ScriptedClock());

  group('setRate refused by the playing track (method channel)', () {
    const channel = MethodChannel('localjam_audio');
    late List<MethodCall> calls;

    /// Heard position the mocked native side reports, and how its setRate
    /// answers (null = accepts).
    late int Function() heardUs;
    late String? Function() setRateRefusal;

    setUp(() {
      calls = [];
      heardUs = () => clock.localUs - 10000000; // on time
      setRateRefusal = () => null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            switch (call.method) {
              case 'nowUs':
                return clock.localUs; // native clock = local clock
              case 'load':
                return 180000000;
              case 'outputLatencyUs':
                return 0;
              case 'currentRouteId':
                return 'speaker:1';
              case 'positionUs':
                // Android's answer to {withTime: true}.
                return {'positionUs': heardUs(), 'nativeTimeUs': clock.localUs};
              case 'setRate':
                final code = setRateRefusal();
                if (code != null) {
                  throw PlatformException(code: code, message: 'refused');
                }
                return null;
              default:
                return null;
            }
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    int count(String method) => calls.where((c) => c.method == method).length;

    Future<AudioSyncController> playing() async {
      final controller = AudioSyncController(
        player: LocaljamAudio(channel: channel),
        sessionNowUs: clock.sessionNowUs,
        localNowUs: clock.localNowUs,
        sessionToLocalUs: clock.sessionToLocalUs,
        resolveMediaPath: (mediaId) async => '/tmp/$mediaId.mp3',
        driftInterval: const Duration(hours: 1), // Checks are driven here.
        events: const Stream<LocaljamAudioEvent>.empty(),
      );
      clock.localUs = 10000000;
      await controller.onSnapshot(
        playingSnapshot(anchorHostTimeUs: 10000000, anchorPositionUs: 0),
      );
      expect(count('playAt'), 1);
      return controller;
    }

    test(
      'rate_needs_reanchor re-anchors at once, and slews work after',
      () async {
        final controller = await playing();
        // 25 ms ahead: the slew band.
        clock.localUs = 12000000;
        heardUs = () => clock.localUs - 10000000 + 25000;
        setRateRefusal = () => 'rate_needs_reanchor';

        await controller.checkDriftNow();
        expect(count('setRate'), 1);
        expect(count('playAt'), 2, reason: 're-anchored at once');
        expect(controller.isSlewing, isFalse);
        expect(controller.slewCount, 0);
        expect(controller.resyncCount, 1);
        expect(controller.lastError.value, isNull);

        // The re-anchor's track (a normal one) time-stretches: the next check
        // in the band slews, rather than being written off as unsupported.
        setRateRefusal = () => null;
        clock.localUs = 13000000;
        await controller.checkDriftNow();
        expect(count('setRate'), 2);
        expect(controller.isSlewing, isTrue);
        expect(controller.slewCount, 1);
        expect(count('playAt'), 2);
        await controller.dispose();
      },
    );

    test('a second rate_needs_reanchor treats slews as unsupported '
        '(rate-limited re-anchors, no more setRate)', () async {
      final controller = await playing();
      clock.localUs = 12000000;
      heardUs = () => clock.localUs - 10000000 + 25000;
      setRateRefusal = () => 'rate_needs_reanchor';

      await controller.checkDriftNow();
      expect(count('playAt'), 2);

      // The re-anchor did not help: same refusal. Not a re-anchor every
      // second — the unsupported path's 10 s limit applies.
      clock.localUs = 13000000;
      await controller.checkDriftNow();
      expect(count('setRate'), 2);
      expect(count('playAt'), 2, reason: 'within 10 s of the last re-anchor');

      clock.localUs = 14000000;
      await controller.checkDriftNow();
      expect(count('setRate'), 2, reason: 'slews are not tried again');
      expect(count('playAt'), 2);

      clock.localUs = 22500000;
      await controller.checkDriftNow();
      expect(count('setRate'), 2);
      expect(count('playAt'), 3);
      await controller.dispose();
    });

    test('positionSample asks for the sample instant', () async {
      final controller = await playing();
      clock.localUs = 11000000;
      await controller.checkDriftNow();
      final position = calls.lastWhere((c) => c.method == 'positionUs');
      expect(position.arguments, {'withTime': true});
      expect(controller.lastSample?.errorUs, 0);
      await controller.dispose();
    });
  });

  group('a slow position reply', () {
    late FakeLocaljamAudio player;

    setUp(() => player = FakeLocaljamAudio());

    Future<AudioSyncController> playing({int nativeOffsetUs = 0}) async {
      player.calibrationOffsetUs = nativeOffsetUs;
      final controller = AudioSyncController(
        player: player,
        sessionNowUs: clock.sessionNowUs,
        localNowUs: clock.localNowUs,
        sessionToLocalUs: clock.sessionToLocalUs,
        resolveMediaPath: (mediaId) async => '/tmp/$mediaId.mp3',
        driftInterval: const Duration(hours: 1),
      );
      clock
        ..localUs = 0
        ..sessionOffsetUs = 3000000;
      await controller.onSnapshot(
        playingSnapshot(anchorHostTimeUs: 3000000, anchorPositionUs: 0),
      );
      // Exactly on time at every sample instant…
      clock.localUs = 5000000;
      player.scriptedPositionUs = 5000000;
      // …answered 30 ms later (a busy platform thread).
      player.onPositionSampled = () => clock.localUs += 30000;
      return controller;
    }

    test('is compared at the instant the player sampled', () async {
      const offset = 1234567; // native clock ahead of local
      final controller = await playing(nativeOffsetUs: offset);
      player.sampleNativeTimeUs = () => clock.localUs + offset;

      await controller.checkDriftNow();
      expect(controller.lastSample?.errorUs, 0);
      expect(controller.lastSample?.action, isA<DriftNone>());
      expect(player.setRateCalls, isEmpty);
      await controller.dispose();
    });

    test('without a sample instant (iOS/macOS/desktop/web) it is compared '
        'on arrival, as before', () async {
      final controller = await playing();
      await controller.checkDriftNow();
      expect(controller.lastSample?.errorUs, -30000);
      await controller.dispose();
    });

    test('an implausible sample instant is ignored', () async {
      final controller = await playing();
      // Older than a second: a stale calibration more likely than a delay.
      player.sampleNativeTimeUs = () => clock.localUs - 2000000;
      await controller.checkDriftNow();
      expect(controller.lastSample?.errorUs, -30000);
      // In the future: the same.
      clock.localUs = 6000000;
      player.scriptedPositionUs = 6000000;
      player.sampleNativeTimeUs = () => clock.localUs + 500000;
      await controller.checkDriftNow();
      expect(controller.lastSample?.errorUs, -30000);
      await controller.dispose();
    });
  });
}
