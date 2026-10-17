import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_audio/localjam_audio.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('localjam_audio');
  final log = <MethodCall>[];

  /// Installs a mock handler that records every call in [log] and answers
  /// from [responses] (keyed by method name; a Function value is invoked
  /// per call for scripted sequences).
  void mockChannel(Map<String, Object?> responses) {
    log.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          log.add(call);
          final response = responses[call.method];
          if (response is Object? Function()) return response();
          return response;
        });
  }

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('nativeNowUs sends nowUs and returns the native clock value', () async {
    mockChannel({'nowUs': 123456789});
    final audio = LocaljamAudio();
    expect(await audio.nativeNowUs(), 123456789);
    expect(log, [isMethodCall('nowUs', arguments: null)]);
  });

  test('load sends the path and maps the duration', () async {
    mockChannel({'load': 32000000});
    final audio = LocaljamAudio();
    expect(await audio.load('/tmp/song.m4a'), 32000000);
    expect(log, [
      isMethodCall('load', arguments: {'path': '/tmp/song.m4a'}),
    ]);
  });

  test('playAt sends nativeTimeUs, positionUs and rate', () async {
    mockChannel({'playAt': null});
    final audio = LocaljamAudio();
    await audio.playAt(
      nativeTimeUs: 9876543210,
      positionUs: 45000000,
      rate: 1.005,
    );
    expect(log, [
      isMethodCall(
        'playAt',
        arguments: {
          'nativeTimeUs': 9876543210,
          'positionUs': 45000000,
          'rate': 1.005,
        },
      ),
    ]);
  });

  test('playAt defaults rate to 1.0', () async {
    mockChannel({'playAt': null});
    final audio = LocaljamAudio();
    await audio.playAt(nativeTimeUs: 1, positionUs: 0);
    expect(log, [
      isMethodCall(
        'playAt',
        arguments: {'nativeTimeUs': 1, 'positionUs': 0, 'rate': 1.0},
      ),
    ]);
  });

  test('pause, stop and dispose send bare method calls', () async {
    mockChannel({'pause': null, 'stop': null, 'dispose': null});
    final audio = LocaljamAudio();
    await audio.pause();
    await audio.stop();
    await audio.dispose();
    expect(log, [
      isMethodCall('pause', arguments: null),
      isMethodCall('stop', arguments: null),
      isMethodCall('dispose', arguments: null),
    ]);
  });

  test('setRate sends the rate', () async {
    mockChannel({'setRate': null});
    final audio = LocaljamAudio();
    await audio.setRate(0.995);
    expect(log, [
      isMethodCall('setRate', arguments: {'rate': 0.995}),
    ]);
  });

  test('positionUs maps a value and passes null through', () async {
    mockChannel({'positionUs': 7500000});
    final audio = LocaljamAudio();
    expect(await audio.positionUs(), 7500000);

    mockChannel({'positionUs': null});
    expect(await audio.positionUs(), isNull);
    expect(log, [isMethodCall('positionUs', arguments: null)]);
  });

  test('outputLatencyUs maps a value and coerces null to 0', () async {
    mockChannel({'outputLatencyUs': 14000});
    final audio = LocaljamAudio();
    expect(await audio.outputLatencyUs(), 14000);

    mockChannel({'outputLatencyUs': null});
    expect(await audio.outputLatencyUs(), 0);
  });

  group('probeDurationUs', () {
    test('sends the path and maps the duration', () async {
      mockChannel({'probeDuration': 215000000});
      final audio = LocaljamAudio();
      expect(await audio.probeDurationUs('/music/a.flac'), 215000000);
      expect(log, [
        isMethodCall('probeDuration', arguments: {'path': '/music/a.flac'}),
      ]);
    });

    test('passes null (unknown duration) through', () async {
      mockChannel({'probeDuration': null});
      expect(await LocaljamAudio().probeDurationUs('/music/a.m4a'), isNull);
    });

    test(
      'a native side without the method means unknown, not a crash',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              throw MissingPluginException();
            });
        expect(await LocaljamAudio().probeDurationUs('/music/a.flac'), isNull);
      },
    );

    test('bad-argument errors still surface', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            throw PlatformException(code: 'bad_args');
          });
      expect(
        LocaljamAudio().probeDurationUs(''),
        throwsA(
          isA<PlatformException>().having((e) => e.code, 'code', 'bad_args'),
        ),
      );
    });
  });

  group('currentRouteId', () {
    test('sends a bare call and maps the id', () async {
      mockChannel({'currentRouteId': 'Headphones:0123456789abcdef'});
      final audio = LocaljamAudio();
      expect(await audio.currentRouteId(), 'Headphones:0123456789abcdef');
      expect(log, [isMethodCall('currentRouteId', arguments: null)]);
    });

    test('passes null through', () async {
      mockChannel({'currentRouteId': null});
      expect(await LocaljamAudio().currentRouteId(), isNull);
    });

    test('a native side without the method means unknown', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            throw MissingPluginException();
          });
      expect(await LocaljamAudio().currentRouteId(), isNull);
    });
  });

  group('events', () {
    const eventChannel = EventChannel('localjam_audio/events');

    /// Installs a mock native stream handler that emits [events] (then ends)
    /// as soon as Dart subscribes.
    void mockEvents(List<Object?> events) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockStreamHandler(
            eventChannel,
            MockStreamHandler.inline(
              onListen: (arguments, sink) {
                for (final event in events) {
                  sink.success(event);
                }
                sink.endOfStream();
              },
            ),
          );
    }

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockStreamHandler(eventChannel, null);
    });

    test('decodes every known kind', () async {
      mockEvents(const [
        {'type': 'routeChanged', 'outputLatencyUs': 120000},
        {'type': 'interruptionBegan'},
        {'type': 'interruptionEnded'},
        {'type': 'engineRestarted'},
        {'type': 'playbackFinished'},
        {'type': 'playbackError', 'code': 'device_lost', 'message': 'gone'},
      ]);
      final audio = LocaljamAudio();
      final events = await audio.events.toList();
      expect(events.map((e) => e.kind), const [
        LocaljamAudioEventKind.routeChanged,
        LocaljamAudioEventKind.interruptionBegan,
        LocaljamAudioEventKind.interruptionEnded,
        LocaljamAudioEventKind.engineRestarted,
        LocaljamAudioEventKind.playbackFinished,
        LocaljamAudioEventKind.playbackError,
      ]);
      // Every kind on the wire is decodable: nothing native can send is lost.
      expect(events, hasLength(LocaljamAudioEventKind.values.length));
    });

    test('routeChanged carries routeId and oldDeviceUnavailable', () async {
      mockEvents(const [
        {
          'type': 'routeChanged',
          'outputLatencyUs': 4000,
          'routeId': 'Speaker:00000000deadbeef',
          'oldDeviceUnavailable': true,
        },
        {
          'type': 'routeChanged',
          'routeId': 'BluetoothA2DPOutput:0123456789abcdef',
          'oldDeviceUnavailable': false,
        },
      ]);
      final events = await LocaljamAudio().events.toList();
      expect(events[0].routeId, 'Speaker:00000000deadbeef');
      expect(events[0].oldDeviceUnavailable, isTrue);
      expect(events[0].outputLatencyUs, 4000);
      expect(events[1].routeId, 'BluetoothA2DPOutput:0123456789abcdef');
      expect(events[1].oldDeviceUnavailable, isFalse);
      expect(events[1].outputLatencyUs, isNull);
    });

    test('interruptionEnded carries shouldResume', () async {
      mockEvents(const [
        {'type': 'interruptionEnded', 'shouldResume': true},
        {'type': 'interruptionEnded', 'shouldResume': false},
      ]);
      final events = await LocaljamAudio().events.toList();
      expect(events.map((e) => e.shouldResume), [true, false]);
    });

    test('interruptionBegan carries shouldResume: false for a permanent '
        'focus loss, and none otherwise', () async {
      // Android's permanent AUDIOFOCUS_LOSS: no interruptionEnded follows,
      // and the client maps it to "another app is playing".
      mockEvents(const [
        {'type': 'interruptionBegan', 'shouldResume': false},
        {'type': 'interruptionBegan'},
      ]);
      final events = await LocaljamAudio().events.toList();
      expect(events.map((e) => e.kind), [
        LocaljamAudioEventKind.interruptionBegan,
        LocaljamAudioEventKind.interruptionBegan,
      ]);
      expect(events.map((e) => e.shouldResume), [false, null]);
    });

    test('playbackError carries code and message', () async {
      mockEvents(const [
        {
          'type': 'playbackError',
          'code': 'engine_start_failed',
          'message': 'AVAudioEngine could not restart',
        },
      ]);
      final event = (await LocaljamAudio().events.toList()).single;
      expect(event.kind, LocaljamAudioEventKind.playbackError);
      expect(event.code, 'engine_start_failed');
      expect(event.message, 'AVAudioEngine could not restart');
    });

    test('playbackError without a code decodes to the generic code', () async {
      mockEvents(const [
        {'type': 'playbackError'},
        {'type': 'playbackError', 'code': 7, 'message': 8},
      ]);
      final events = await LocaljamAudio().events.toList();
      expect(events.map((e) => e.code), ['unknown', 'unknown']);
      expect(events.map((e) => e.message), [null, null]);
    });

    test(
      'old-native payloads without the new keys decode to defaults',
      () async {
        mockEvents(const [
          {'type': 'routeChanged', 'outputLatencyUs': 120000},
          {'type': 'interruptionEnded'},
          {'type': 'interruptionBegan'},
        ]);
        final events = await LocaljamAudio().events.toList();
        for (final event in events) {
          expect(event.routeId, isNull);
          expect(event.oldDeviceUnavailable, isFalse);
          expect(event.shouldResume, isNull);
          expect(event.code, isNull);
          expect(event.message, isNull);
        }
        expect(events.first.outputLatencyUs, 120000);
      },
    );

    test('mistyped new keys decode to defaults instead of throwing', () async {
      mockEvents(const [
        {
          'type': 'routeChanged',
          'routeId': 42,
          'oldDeviceUnavailable': 'yes',
          'outputLatencyUs': 1.5,
        },
        {'type': 'interruptionEnded', 'shouldResume': 1},
      ]);
      final events = await LocaljamAudio().events.toList();
      expect(events, hasLength(2));
      expect(events[0].routeId, isNull);
      expect(events[0].oldDeviceUnavailable, isFalse);
      expect(events[0].outputLatencyUs, isNull);
      expect(events[1].shouldResume, isNull);
    });

    test('non-error kinds pass a stray code through untouched', () async {
      mockEvents(const [
        {'type': 'engineRestarted', 'code': 'x'},
        {'type': 'playbackFinished'},
      ]);
      final events = await LocaljamAudio().events.toList();
      expect(events[0].code, 'x');
      expect(events[1].code, isNull);
    });

    test('toString names the populated fields', () {
      expect(
        const LocaljamAudioEvent(
          kind: LocaljamAudioEventKind.routeChanged,
          routeId: 'r',
          oldDeviceUnavailable: true,
        ).toString(),
        'LocaljamAudioEvent(routeChanged, routeId: r, '
        'oldDeviceUnavailable: true)',
      );
    });

    test(
      'passes outputLatencyUs through and leaves it null when absent',
      () async {
        mockEvents(const [
          {'type': 'routeChanged', 'outputLatencyUs': 250000},
          {'type': 'routeChanged'},
          {'type': 'interruptionEnded', 'outputLatencyUs': null},
        ]);
        final audio = LocaljamAudio();
        final events = await audio.events.toList();
        expect(events.map((e) => e.outputLatencyUs), [250000, null, null]);
      },
    );

    test('ignores unknown event types and non-map payloads', () async {
      mockEvents(const [
        {'type': 'flyingSaucerDetected', 'outputLatencyUs': 1},
        'not-a-map',
        42,
        {'noType': true},
        {'type': 'playbackFinished'},
      ]);
      final audio = LocaljamAudio();
      final events = await audio.events.toList();
      expect(events, hasLength(1));
      expect(events.single.kind, LocaljamAudioEventKind.playbackFinished);
    });

    test('events stream is broadcast and injectable', () async {
      final raw = Stream<Object?>.fromIterable(const [
        {'type': 'engineRestarted'},
      ]).asBroadcastStream();
      final audio = LocaljamAudio(rawEvents: raw);
      expect(audio.events.isBroadcast, isTrue);
      expect(identical(audio.events, audio.events), isTrue);
      final events = await audio.events.toList();
      expect(events.single.kind, LocaljamAudioEventKind.engineRestarted);
    });
  });

  test('calibrate keeps the minimum-RTT sample', () async {
    // Three samples. Per sample, calibrate reads dartNowUs (t0), awaits
    // nowUs (native), reads dartNowUs again (t3):
    //   sample 0: t0=1000, native=500000, t3=1100  -> rtt=100
    //   sample 1: t0=2000, native=600000, t3=2040  -> rtt= 40  (winner)
    //   sample 2: t0=3000, native=700000, t3=3080  -> rtt= 80
    // Winner: offset = 600000 - (2000 + 40 ~/ 2) = 597980.
    final dartTimes = [1000, 1100, 2000, 2040, 3000, 3080];
    final nativeTimes = [500000, 600000, 700000];
    var dartIndex = 0;
    var nativeIndex = 0;
    mockChannel({'nowUs': () => nativeTimes[nativeIndex++]});

    final audio = LocaljamAudio();
    final calibration = await audio.calibrate(
      () => dartTimes[dartIndex++],
      samples: 3,
    );

    expect(calibration.rttUs, 40);
    expect(calibration.offsetUs, 597980);
    expect(log, List.filled(3, isMethodCall('nowUs', arguments: null)));
  });
}
