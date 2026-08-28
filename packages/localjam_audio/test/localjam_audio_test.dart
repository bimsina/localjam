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
      isMethodCall('playAt', arguments: {
        'nativeTimeUs': 9876543210,
        'positionUs': 45000000,
        'rate': 1.005,
      }),
    ]);
  });

  test('playAt defaults rate to 1.0', () async {
    mockChannel({'playAt': null});
    final audio = LocaljamAudio();
    await audio.playAt(nativeTimeUs: 1, positionUs: 0);
    expect(log, [
      isMethodCall('playAt', arguments: {
        'nativeTimeUs': 1,
        'positionUs': 0,
        'rate': 1.0,
      }),
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
      ]);
      final audio = LocaljamAudio();
      final events = await audio.events.toList();
      expect(events.map((e) => e.kind), const [
        LocaljamAudioEventKind.routeChanged,
        LocaljamAudioEventKind.interruptionBegan,
        LocaljamAudioEventKind.interruptionEnded,
        LocaljamAudioEventKind.engineRestarted,
        LocaljamAudioEventKind.playbackFinished,
      ]);
    });

    test('passes outputLatencyUs through and leaves it null when absent',
        () async {
      mockEvents(const [
        {'type': 'routeChanged', 'outputLatencyUs': 250000},
        {'type': 'routeChanged'},
        {'type': 'interruptionEnded', 'outputLatencyUs': null},
      ]);
      final audio = LocaljamAudio();
      final events = await audio.events.toList();
      expect(events.map((e) => e.outputLatencyUs), [250000, null, null]);
    });

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
    final calibration =
        await audio.calibrate(() => dartTimes[dartIndex++], samples: 3);

    expect(calibration.rttUs, 40);
    expect(calibration.offsetUs, 597980);
    expect(log, List.filled(3, isMethodCall('nowUs', arguments: null)));
  });
}
