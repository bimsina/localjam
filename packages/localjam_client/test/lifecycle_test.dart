/// App-lifecycle survival plumbing: the engine-owned
/// [WidgetsBindingObserver] re-verifies sync on resume (re-applying the
/// snapshot when the player state is stale), and the engines hold/release
/// the `localjam/keepalive` platform channel around the session lifetime.
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_client/localjam_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'engine_test_utils.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => HttpOverrides.global = null);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<JamHostEngine> startHostEngine() async {
    final engine = await JamHostEngine.start(
      sessionName: 'LifecycleJam',
      address: InternetAddress.loopbackIPv4,
    );
    addTearDown(engine.close);
    return engine;
  }

  /// Plays one track on a fresh host engine and returns once the initial
  /// playAt landed on the mocked channel.
  Future<JamHostEngine> playingEngine(List<MethodCall> log) async {
    final engine = await startHostEngine();
    final file = await writeTempMedia(makeMediaBytes(2048));
    final item = await engine.addMediaFile(file);
    engine.setMedia(item.mediaId);
    engine.play();
    await waitFor(
      () => log.any((c) => c.method == 'playAt'),
      reason: 'initial playAt',
    );
    return engine;
  }

  test('resume re-applies the snapshot when the player state is stale', () async {
    // The mocked channel answers positionUs with null: "the OS killed audio
    // while we were backgrounded" — exactly the stale state resume must fix.
    final log = mockAudioChannel();
    final engine = await playingEngine(log);

    log.clear();
    await engine.handleLifecycleState(AppLifecycleState.resumed);
    expect(
      log.where((c) => c.method == 'playAt'),
      isNotEmpty,
      reason: 'stale player state must be re-anchored from the snapshot',
    );
  });

  test('non-resume lifecycle transitions do not touch the player', () async {
    final log = mockAudioChannel();
    final engine = await playingEngine(log);

    log.clear();
    await engine.handleLifecycleState(AppLifecycleState.paused);
    await engine.handleLifecycleState(AppLifecycleState.inactive);
    await engine.handleLifecycleState(AppLifecycleState.hidden);
    expect(log, isEmpty);
  });

  test('resume on a paused snapshot re-applies it (pause + preload)', () async {
    final log = mockAudioChannel();
    final engine = await playingEngine(log);
    engine.pause();
    await waitFor(
      () => engine.snapshot.status == PlaybackStatus.paused,
      reason: 'paused snapshot',
    );

    log.clear();
    await engine.handleLifecycleState(AppLifecycleState.resumed);
    expect(log.where((c) => c.method == 'pause'), isNotEmpty);
    expect(log.where((c) => c.method == 'playAt'), isEmpty);
  });

  test(
    'the observer is registered while the session lives and dispatches '
    'through the real widgets binding',
    () async {
      final log = mockAudioChannel();
      final engine = await playingEngine(log);
      expect(engine.lifecycleObserverAttached, isTrue);

      // Drive the binding's lifecycle channel like the platform does. Go
      // through paused first: the binding ignores a transition to the state
      // it is already in, and tests may start out resumed.
      log.clear();
      final messenger =
          TestWidgetsFlutterBinding.instance.defaultBinaryMessenger;
      Future<void> send(String state) => messenger.handlePlatformMessage(
        SystemChannels.lifecycle.name,
        const StringCodec().encodeMessage(state),
        (_) {},
      );
      await send('AppLifecycleState.paused');
      await send('AppLifecycleState.resumed');
      await waitFor(
        () => log.any((c) => c.method == 'playAt'),
        reason: 'observer-driven re-anchor on resume',
      );

      await engine.close();
      expect(engine.lifecycleObserverAttached, isFalse);
    },
  );

  test('engines acquire and release the keepalive around the session', () async {
    mockAudioChannel();
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(JamKeepAlive.channel, (call) async {
          calls.add(call.method);
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(JamKeepAlive.channel, null);
    });

    // flutter_test runs with defaultTargetPlatform == android, so the
    // JamKeepAlive platform gate is open.
    final host = await startHostEngine();
    expect(calls, ['acquire']);

    final guest = await JamGuestEngine.join(
      host.joinUriFor(InternetAddress.loopbackIPv4),
      clientName: 'lifecycle-guest',
      mediaCacheDir: await makeTempDir(),
    );
    addTearDown(guest.close);
    expect(calls, ['acquire', 'acquire']);

    await guest.close();
    expect(calls, ['acquire', 'acquire', 'release']);
    await host.close();
    expect(calls, ['acquire', 'acquire', 'release', 'release']);
  });
}
