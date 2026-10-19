/// [JamHostEngine.setDiscoverable]: a host turns "Show to People Nearby" off
/// and on while the jam runs. Off withdraws the advertisement (its goodbye)
/// and stays off across network changes; on starts it again the way
/// `start()` does; every change is bounded, ordered, and announced to the UI
/// before the responder has caught up.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_client/localjam_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'engine_test_utils.dart';

/// Counts what the engine asks of its advertiser, with nothing on the wire.
class _Responders {
  int starts = 0;
  int stops = 0;
  int get live => starts - stops;

  /// The transport each new advertiser reports.
  String transport = 'builtin';

  /// When set, a start answers only once this completes.
  Completer<void>? holdStart;

  /// When set, a stop never finishes (a platform channel that went away).
  bool stopHangs = false;

  Future<JamRoomAdvertiser?> start({
    required String sessionName,
    required int port,
    required String token,
    List<InternetAddress> addresses = const [],
    Duration timeout = JamRoomAdvertiser.defaultTimeout,
  }) async {
    final hold = holdStart;
    if (hold != null) await hold.future;
    starts++;
    return JamRoomAdvertiser.fake(
      transport: transport,
      onStop: () async {
        stops++;
        if (stopHangs) await Completer<void>().future;
      },
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => HttpOverrides.global = null);

  late _Responders responders;
  late List<NetworkInterface> interfaces;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    mockAudioChannel();
    responders = _Responders();
    interfaces = [
      FakeNetworkInterface('en0', ['192.168.1.7']),
    ];
    JamHostEngine.networkInterfaceLister = () async => interfaces;
    JamHostEngine.roomAdvertiserStarter = responders.start;
  });

  tearDown(() {
    JamHostEngine.networkInterfaceLister =
        JamHostEngine.defaultNetworkInterfaceLister;
    JamHostEngine.roomAdvertiserStarter = JamRoomAdvertiser.start;
  });

  Future<JamHostEngine> startEngine({bool discoverable = true}) async {
    final engine = await JamHostEngine.start(
      sessionName: 'Van Jam',
      hostName: 'Silky Puffin',
      discoverable: discoverable,
    );
    addTearDown(engine.close);
    return engine;
  }

  /// A network change: the reachable LAN moves, which is what makes the
  /// engine restart a built-in responder.
  Future<void> moveNetwork(JamHostEngine engine, String address) async {
    interfaces = [
      FakeNetworkInterface('en0', [address]),
    ];
    await engine.refreshLanAddresses();
  }

  test('off withdraws the advertisement and on brings it back, and the '
      'switch hears about it straight away', () async {
    final engine = await startEngine();
    expect(engine.discoverable, isTrue);
    expect(engine.discoveryEnabled, isTrue);
    expect(responders.live, 1);

    final heard = <bool>[];
    engine.discoveryEnabledListenable.addListener(
      () => heard.add(engine.discoveryEnabledListenable.value),
    );

    final off = engine.setDiscoverable(false);
    expect(heard, [false], reason: 'before the responder has caught up');
    await off;
    expect(responders.stops, 1);
    expect(responders.live, 0);
    expect(engine.discoverable, isFalse);
    expect(engine.discoveryEnabled, isFalse);

    await engine.setDiscoverable(true);
    expect(heard, [false, true]);
    expect(responders.starts, 2);
    expect(responders.live, 1);
    expect(engine.discoverable, isTrue);

    // Asking for what is already true changes nothing.
    await engine.setDiscoverable(true);
    expect(responders.starts, 2);
    expect(heard, [false, true]);
  });

  test('a room started invite-only can be shown mid-jam', () async {
    final engine = await startEngine(discoverable: false);
    expect(responders.starts, 0);
    expect(engine.discoveryEnabled, isFalse);

    await engine.setDiscoverable(true);
    expect(responders.live, 1);
    expect(engine.discoverable, isTrue);
  });

  test('a network change never turns a hidden room back on', () async {
    final engine = await startEngine();
    await engine.setDiscoverable(false);
    expect(responders.live, 0);

    await moveNetwork(engine, '10.0.0.5');
    await moveNetwork(engine, '10.0.0.6');
    expect(responders.starts, 1, reason: 'only the one start() made');
    expect(engine.discoverable, isFalse);

    // Shown again, the responder follows network changes as before.
    await engine.setDiscoverable(true);
    expect(responders.starts, 2);
    await moveNetwork(engine, '10.0.0.7');
    expect(responders.starts, 3);
    expect(responders.live, 1, reason: 'the old instance went first');
  });

  test('a host that hides the room while a network change is restarting the '
      'responder ends up hidden', () async {
    final engine = await startEngine();
    final hold = responders.holdStart = Completer<void>();

    // The re-scan stops the built-in responder and starts a new one, which
    // has not answered yet when the host turns visibility off.
    final rescan = moveNetwork(engine, '10.0.0.5');
    await pumpEventQueue();
    final off = engine.setDiscoverable(false);
    hold.complete();
    await Future.wait([rescan, off]);

    expect(engine.discoverable, isFalse);
    expect(engine.discoveryEnabled, isFalse);
    expect(responders.live, 0, reason: 'nothing left on the wire');
  });

  test(
    'a burst of toggles settles on the last one, with one advertisement',
    () async {
      final engine = await startEngine();
      final last = [
        engine.setDiscoverable(false),
        engine.setDiscoverable(true),
        engine.setDiscoverable(false),
        engine.setDiscoverable(true),
      ];
      await Future.wait(last);
      expect(engine.discoveryEnabled, isTrue);
      expect(engine.discoverable, isTrue);
      expect(responders.live, 1);
    },
  );

  test('a responder that never stops does not hold a toggle past the '
      'advertising budget', () async {
    final engine = await startEngine();
    responders.stopHangs = true;
    final stopwatch = Stopwatch()..start();
    await engine.setDiscoverable(false);
    stopwatch.stop();
    expect(
      stopwatch.elapsed,
      lessThan(JamRoomAdvertiser.totalTimeout + const Duration(seconds: 1)),
    );
    expect(engine.discoverable, isFalse);

    // And the next change is not stuck behind it.
    responders.stopHangs = false;
    await engine.setDiscoverable(true);
    expect(engine.discoverable, isTrue);
  });

  test('a responder that never starts gives up inside the budget, and the '
      'next re-scan tries again', () async {
    final engine = await startEngine(discoverable: false);
    responders.holdStart = Completer<void>(); // never completes
    final stopwatch = Stopwatch()..start();
    await engine.setDiscoverable(true);
    stopwatch.stop();
    expect(
      stopwatch.elapsed,
      lessThan(JamRoomAdvertiser.totalTimeout + const Duration(seconds: 1)),
    );
    expect(engine.discoveryEnabled, isTrue);
    expect(engine.discoverable, isFalse, reason: 'QR-only for now');

    responders.holdStart = null;
    await engine.refreshLanAddresses(); // Same network: retried anyway.
    expect(engine.discoverable, isTrue);
  });

  test('ending the room withdraws the advertisement, and a toggle after the '
      'end is a no-op', () async {
    final engine = await JamHostEngine.start(
      sessionName: 'Van Jam',
      hostName: 'Silky Puffin',
    );
    expect(responders.live, 1);
    await engine.close();
    expect(responders.live, 0);
    await engine.setDiscoverable(true);
    expect(responders.starts, 1);
  });
}
