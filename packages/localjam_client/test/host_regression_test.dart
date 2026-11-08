/// [JamHostEngine] regressions from the adversarial review: a room that
/// starts with no LAN (an iPhone hotspot before anyone joined it) becomes
/// reachable on its own; connections arriving on the host's own cellular or
/// tunnel addresses are refused, following every re-scan; the away signal
/// follows track transitions and the
/// Android keep-alive; the mDNS responder survives a failed restart and
/// ignores reshuffled interfaces; the resume probe and the listener watcher
/// each repair a dead socket on their own; the nudge follows routes with
/// one re-anchor and is saved under the route it was set on; kicked lists
/// follow the server; and the intents never throw.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_client/localjam_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'engine_test_utils.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => HttpOverrides.global = null);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  tearDown(() {
    JamHostEngine.networkInterfaceLister =
        JamHostEngine.defaultNetworkInterfaceLister;
    JamHostEngine.roomAdvertiserStarter = JamRoomAdvertiser.start;
    JamHostEngine.listenerRestarter = JamHostEngine.defaultListenerRestarter;
    JamHostEngine.listenerProber = JamHostEngine.defaultListenerProber;
    JamHostEngine.localAddressSeen = JamHostEngine.defaultLocalAddressSeen;
    JamHostEngine.noLanAddressRefreshInterval = const Duration(seconds: 2);
    JamHostEngine.addressRefreshInterval = const Duration(seconds: 10);
    JamKeepAlive.active.value = false;
    debugDefaultTargetPlatformOverride = null;
  });

  Future<JamHostEngine> startEngine({
    InternetAddress? address,
    bool discoverable = false,
  }) async {
    final engine = await JamHostEngine.start(
      sessionName: 'RegHostJam',
      hostName: 'Silky Puffin',
      address: address,
      discoverable: discoverable,
    );
    addTearDown(engine.close);
    return engine;
  }

  List<String> hosts(JamHostEngine engine) => engine.joinLink.hosts;

  group('a room with no LAN yet (§9)', () {
    test(
      'listens on every interface, and the QR appears by itself once a '
      'LAN does — e.g. the first device joining this phone\'s hotspot',
      () async {
        mockAudioChannel();
        JamHostEngine.noLanAddressRefreshInterval = const Duration(
          milliseconds: 50,
        );
        var interfaces = <NetworkInterface>[
          FakeNetworkInterface('pdp_ip0', ['10.1.1.1']),
        ];
        JamHostEngine.networkInterfaceLister = () async => interfaces;
        final engine = await startEngine();
        expect(engine.boundAddress, InternetAddress.anyIPv4);
        expect(engine.hasLanAddress, isFalse);
        expect(hosts(engine), ['127.0.0.1']);

        // iOS only creates bridge100 once a device joins the hotspot.
        interfaces = [
          FakeNetworkInterface('pdp_ip0', ['10.1.1.1']),
          FakeNetworkInterface('bridge100', ['172.20.10.1']),
        ];
        await waitFor(() => engine.hasLanAddress, reason: 're-scan');
        expect(hosts(engine), ['172.20.10.1']);
        expect(engine.lanAddresses.value.single.address, '172.20.10.1');

        // And the room really is open (here: over loopback).
        final guest = await JamGuestClient.connect(
          engine.joinUriFor(InternetAddress.loopbackIPv4),
          clientName: 'Funky Walrus',
        );
        addTearDown(guest.close);
        expect(guest.sessionName, 'RegHostJam');
      },
    );

    test('reshuffled interfaces are the same networks: no new QR', () async {
      mockAudioChannel();
      var interfaces = [
        FakeNetworkInterface('en0', ['192.168.1.7']),
        FakeNetworkInterface('bridge100', ['172.20.10.1']),
      ];
      JamHostEngine.networkInterfaceLister = () async => interfaces;
      final engine = await startEngine();
      final uris = <Uri>[];
      engine.joinUriListenable.addListener(
        () => uris.add(engine.joinUriListenable.value),
      );
      interfaces = interfaces.reversed.toList();
      await engine.refreshLanAddresses();
      expect(uris, isEmpty);
    });

    test('concurrent re-scans share one interface enumeration', () async {
      mockAudioChannel();
      final engine = await startEngine();
      var scans = 0;
      final answer = Completer<List<NetworkInterface>>();
      JamHostEngine.networkInterfaceLister = () {
        scans++;
        return answer.future;
      };
      final first = engine.refreshLanAddresses();
      final second = engine.refreshLanAddresses();
      answer.complete([
        FakeNetworkInterface('wlan0', ['10.0.0.5']),
      ]);
      await Future.wait([first, second]);
      expect(scans, 1);
      expect(hosts(engine), ['10.0.0.5']);
    });

    test('a failed mDNS restart after an address change is retried on the '
        'next re-scan: the room does not stay undiscoverable', () async {
      mockAudioChannel();
      var interfaces = [
        FakeNetworkInterface('en0', ['192.168.1.7']),
      ];
      JamHostEngine.networkInterfaceLister = () async => interfaces;
      var starts = 0;
      var refuse = false;
      JamHostEngine.roomAdvertiserStarter =
          ({
            required String sessionName,
            required int port,
            required String token,
            String? hostName,
            List<InternetAddress> addresses = const [],
            Duration timeout = JamRoomAdvertiser.defaultTimeout,
          }) async {
            starts++;
            if (refuse) return null;
            return JamRoomAdvertiser.start(
              sessionName: sessionName,
              port: port,
              token: token,
              hostName: hostName,
              addresses: addresses,
              timeout: timeout,
            );
          };
      final engine = await startEngine(discoverable: true);
      expect(engine.discoverable, isTrue);
      expect(starts, 1);

      refuse = true;
      interfaces = [
        FakeNetworkInterface('wlan0', ['10.0.0.5']),
      ];
      await engine.refreshLanAddresses();
      expect(starts, 2);
      expect(engine.discoverable, isFalse);

      refuse = false;
      await engine.refreshLanAddresses(); // Same addresses: retried anyway.
      expect(starts, 3);
      expect(engine.discoverable, isTrue);

      await engine.refreshLanAddresses(); // Healthy and unchanged: left be.
      expect(starts, 3);
    });
  });

  group('connections on a cellular or tunnel link are refused (§9)', () {
    // The room binds the wildcard address, so it also listens on cellular
    // and tunnel links — where a carrier-NAT stranger has an RFC1918
    // address the remote filter admits. The filter on the LOCAL address a
    // connection arrived on is what keeps them out.

    /// Whether the server would serve a connection that arrived on [local].
    bool admits(JamHostEngine engine, String local) =>
        engine.debugServer.admitLocalAddress!(InternetAddress(local));

    /// The status line a bare request to [host]:[port] is answered with.
    ///
    /// The connect is retried: on a machine loaded far past its cores a
    /// loopback connect is now and then reset before the server has even
    /// accepted it — before anything this test is about has happened.
    Future<String> statusLine(InternetAddress host, int port) async {
      Socket? connected;
      for (var attempt = 1; connected == null; attempt++) {
        try {
          connected = await Socket.connect(
            host,
            port,
            timeout: const Duration(seconds: 2),
          );
        } on SocketException {
          if (attempt == 3) rethrow;
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
      final socket = connected;
      try {
        socket.write('GET /not-a-route HTTP/1.1\r\nHost: jam\r\n\r\n');
        final bytes = await socket
            .fold<List<int>>([], (all, chunk) => all..addAll(chunk))
            .timeout(const Duration(seconds: 5));
        return utf8.decode(bytes, allowMalformed: true).split('\r\n').first;
      } finally {
        socket.destroy();
      }
    }

    test('from the first scan, and following every periodic re-scan; '
        'loopback and the LAN are never refused', () async {
      mockAudioChannel();
      JamHostEngine.addressRefreshInterval = const Duration(milliseconds: 50);
      var interfaces = <NetworkInterface>[
        FakeNetworkInterface('en0', ['192.168.1.7']),
        FakeNetworkInterface('pdp_ip0', ['10.1.1.1']), // Carrier NAT.
        FakeNetworkInterface('utun3', ['10.8.0.2']), // A VPN.
      ];
      JamHostEngine.networkInterfaceLister = () async => interfaces;
      final engine = await startEngine();
      expect(engine.boundAddress, InternetAddress.anyIPv4);
      expect(admits(engine, '10.1.1.1'), isFalse, reason: 'cellular');
      expect(admits(engine, '10.8.0.2'), isFalse, reason: 'tunnel');
      expect(admits(engine, '192.168.1.7'), isTrue, reason: 'Wi-Fi');
      expect(admits(engine, '127.0.0.1'), isTrue, reason: 'loopback');

      // The carrier hands out a new address and the VPN drops; the old ones
      // are no longer this device's (the Wi-Fi may well reuse one).
      interfaces = [
        FakeNetworkInterface('en0', ['192.168.1.7']),
        FakeNetworkInterface('rmnet_data0', ['10.1.1.9']),
      ];
      await waitFor(() => !admits(engine, '10.1.1.9'), reason: 're-scan');
      expect(admits(engine, '10.1.1.1'), isTrue, reason: 'stale entry gone');
      expect(admits(engine, '10.8.0.2'), isTrue, reason: 'stale entry gone');
      expect(admits(engine, '192.168.1.7'), isTrue);

      // A scan that fails is an unknown network, not an absent one: the
      // refusals stand.
      JamHostEngine.networkInterfaceLister = () async =>
          throw const SocketException('no');
      await engine.refreshLanAddresses();
      expect(admits(engine, '10.1.1.9'), isFalse);
    });

    test('resume re-scans the filter, and the room still answers over '
        'loopback', () async {
      mockAudioChannel();
      var interfaces = <NetworkInterface>[
        FakeNetworkInterface('wlan0', ['10.0.0.5']),
      ];
      var scans = 0;
      JamHostEngine.networkInterfaceLister = () async {
        scans++;
        return interfaces;
      };
      final engine = await startEngine(); // Periodic re-scan: 10 s away.
      expect(admits(engine, '10.64.0.7'), isTrue);
      await engine.handleLifecycleState(AppLifecycleState.paused);

      // Wi-Fi gone in the background; the phone fell back to cellular.
      interfaces = [
        FakeNetworkInterface('ccmni0', ['10.64.0.7']),
      ];
      final before = scans;
      await engine.handleLifecycleState(AppLifecycleState.resumed);
      await waitFor(() => !admits(engine, '10.64.0.7'), reason: 'resume scan');
      expect(scans, before + 1);
      expect(
        await statusLine(InternetAddress.loopbackIPv4, engine.port),
        'HTTP/1.1 404 Not Found',
        reason: 'loopback is served: the self-probe and local guests',
      );
    });

    /// One of this machine's own LAN addresses, for a real socket to arrive
    /// on: a socket's local address cannot be faked, so the test below
    /// borrows a real one. Only the (skipped) wildcard test still needs it.
    Future<InternetAddress?> borrowLanAddress() async {
      final real = JamHostEngine.lanAddressesOf(
        await JamHostEngine.defaultNetworkInterfaceLister(),
      );
      if (real.isEmpty) {
        markTestSkipped('this machine has no LAN address to borrow');
        return null;
      }
      return real.first;
    }

    test('a real connection arriving on an address the last scan put on a '
        'cellular link is answered 403 before it is parsed; on Wi-Fi it is '
        'served', () async {
      // It used to borrow one of the machine's own LAN addresses, which made
      // it hostage to the runner's network (no Wi-Fi: skipped; a flapping
      // NIC under load: a reset). Instead the connection is real but comes
      // over loopback, and the filter is told it arrived on an address
      // whose link the fake interface list decides — the one thing a test
      // machine cannot arrange with a real socket.
      mockAudioChannel();
      const arrivedOn = '10.20.30.40';
      JamHostEngine.localAddressSeen = (local) =>
          local.isLoopback ? InternetAddress(arrivedOn) : local;
      var link = 'en0';
      JamHostEngine.networkInterfaceLister = () async => [
        FakeNetworkInterface(link, [arrivedOn]),
      ];
      final engine = await startEngine(address: InternetAddress.loopbackIPv4);
      final loopback = InternetAddress.loopbackIPv4;
      expect(
        await statusLine(loopback, engine.port),
        'HTTP/1.1 404 Not Found',
        reason: 'on Wi-Fi: served (refused only by route)',
      );

      link = 'pdp_ip0'; // The same address, now on a cellular link.
      await engine.refreshLanAddresses();
      expect(await statusLine(loopback, engine.port), 'HTTP/1.1 403 Forbidden');

      link = 'wlan0'; // And back on a LAN.
      await engine.refreshLanAddresses();
      expect(await statusLine(loopback, engine.port), 'HTTP/1.1 404 Not Found');
    });

    test(
      'behind the wildcard bind, a connection arriving on a cellular '
      'address is not served',
      () async {
        final local = await borrowLanAddress();
        if (local == null) return;
        mockAudioChannel();
        JamHostEngine.networkInterfaceLister = () async => [
          FakeNetworkInterface('pdp_ip0', [local.address]),
        ];
        final engine = await startEngine();
        expect(engine.boundAddress, InternetAddress.anyIPv4);
        String outcome;
        try {
          outcome = await statusLine(local, engine.port);
        } on SocketException {
          outcome = 'not listening there';
        }
        expect(outcome, anyOf('HTTP/1.1 403 Forbidden', 'not listening there'));
        expect(
          await statusLine(InternetAddress.loopbackIPv4, engine.port),
          'HTTP/1.1 404 Not Found',
        );
      },
      // dart:io gives an accepted socket its LISTENER's address
      // (`_NativeSocket.accept` → `_NativeSocket.normal(address)`), so behind
      // `anyIPv4` every connection reports `0.0.0.0` as the address it
      // arrived on and JamHostServer.admitLocalAddress cannot refuse it.
      // Un-skip once localjam_net learns the real local address or listens
      // per interface.
      skip:
          'localjam_net: an accepted socket reports 0.0.0.0 as its local '
          'address behind the wildcard bind',
    );

    test('nonLanLocalAddressesOf: cellular and tunnel addresses only — never '
        'loopback, never one a LAN interface also carries', () {
      expect(
        JamHostEngine.nonLanLocalAddressesOf([
          FakeNetworkInterface('en0', ['192.168.1.7']),
          FakeNetworkInterface('pdp_ip0', ['10.1.1.1', '127.0.0.1']),
          FakeNetworkInterface('v4-rmnet_data0', ['192.0.0.4']),
          FakeNetworkInterface('wg0', ['192.168.1.7']), // Also on en0.
          FakeNetworkInterface('bridge100', ['172.20.10.1']),
        ]),
        {'10.1.1.1', '192.0.0.4'},
      );
    });
  });

  group('host away (§3.5)', () {
    test('an iOS host playing in the background is not away at a natural '
        'track transition, nor while it plays the next track', () async {
      final log = mockAudioChannel(probeKnowsDuration: false);
      final push = mockAudioEvents();
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final engine = await startEngine(address: InternetAddress.loopbackIPv4);
      final away = <bool>[];
      engine.announcedAway.addListener(
        () => away.add(engine.announcedAway.value),
      );
      final a = await engine.addMediaFile(
        await writeTempMedia(makeMediaBytes(1024, seed: 1), name: 'a.mp3'),
      );
      await engine.addMediaFile(
        await writeTempMedia(makeMediaBytes(1024, seed: 2), name: 'b.mp3'),
      );
      engine.setMedia(a.mediaId);
      engine.play();
      await waitFor(() => log.any((c) => c.method == 'playAt'), reason: 'A');
      await engine.handleLifecycleState(AppLifecycleState.paused);
      expect(engine.announcedAway.value, isFalse, reason: 'playing');

      await waitFor(
        () => monotonicNowUs() > engine.snapshot.anchor!.hostTimeUs,
        reason: 'start passed',
      );
      final playAtsBefore = log.where((c) => c.method == 'playAt').length;
      push({'type': 'playbackFinished'}); // A ran out: the room advances.
      await waitFor(
        () => log.where((c) => c.method == 'playAt').length > playAtsBefore,
        reason: 'B scheduled',
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(engine.snapshot.status, PlaybackStatus.playing);
      expect(engine.sync.trackFinished.value, isFalse);
      expect(away, isEmpty, reason: 'never announced, not even briefly');

      // The room pausing in the background does make it away.
      engine.pause();
      await waitFor(() => engine.announcedAway.value, reason: 'paused');
    });

    test('an iOS host whose file ran out while the room plays on (the '
        'report was not believed) is silent: away', () async {
      // The declared duration says a minute; the local file ends at once.
      final log = mockAudioChannel();
      final push = mockAudioEvents();
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final engine = await startEngine(address: InternetAddress.loopbackIPv4);
      final item = await engine.addMediaFile(
        await writeTempMedia(makeMediaBytes(1024, seed: 3), name: 'c.mp3'),
      );
      engine.setMedia(item.mediaId);
      engine.play();
      await waitFor(() => log.any((c) => c.method == 'playAt'), reason: 'up');
      await engine.handleLifecycleState(AppLifecycleState.paused);
      await waitFor(
        () => monotonicNowUs() > engine.snapshot.anchor!.hostTimeUs,
        reason: 'start passed',
      );
      expect(engine.announcedAway.value, isFalse);

      push({'type': 'playbackFinished'});
      await waitFor(() => engine.announcedAway.value, reason: 'silent');
      expect(
        engine.snapshot.status,
        PlaybackStatus.playing,
        reason: 'the room itself never moved',
      );
    });

    test('an Android host in the background is away exactly while its '
        'foreground service is not held', () async {
      mockAudioChannel();
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final engine = await startEngine(address: InternetAddress.loopbackIPv4);
      JamKeepAlive.active.value = true;
      await engine.handleLifecycleState(AppLifecycleState.paused);
      expect(engine.announcedAway.value, isFalse);

      JamKeepAlive.active.value = false; // The OS took the service away.
      await waitFor(() => engine.announcedAway.value, reason: 'away');
      JamKeepAlive.active.value = true;
      await waitFor(() => !engine.announcedAway.value, reason: 'back');
    });
  });

  group('listener health', () {
    test(
      'the watcher alone reopens a socket that died under the room',
      () async {
        mockAudioChannel();
        final engine = await startEngine(address: InternetAddress.loopbackIPv4);
        final port = engine.port;
        await engine.debugServer.debugKillListener(); // No lifecycle event.
        await waitFor(() => engine.isListening, reason: 'reopened');
        expect(engine.port, port);
        expect(engine.sessionEnded.value, isNull);
      },
    );

    test('the resume probe alone reopens a socket the OS took without a '
        'word', () async {
      mockAudioChannel();
      var restarts = 0;
      JamHostEngine.listenerRestarter = (server) {
        restarts++;
        return server.restartListener();
      };
      final engine = await startEngine(address: InternetAddress.loopbackIPv4);
      await engine.handleLifecycleState(AppLifecycleState.paused);
      expect(restarts, 0);
      JamHostEngine.listenerProber = (_) async => false; // Silently dead.
      await engine.handleLifecycleState(AppLifecycleState.resumed);
      expect(restarts, 1);
      expect(engine.isListening, isTrue);
      expect(engine.sessionEnded.value, isNull);
    });
  });

  group('the nudge follows the output route (§7)', () {
    test(
      'a route change re-anchors once, with that route\'s saved nudge',
      () async {
        SharedPreferences.setMockInitialValues({
          'nudgeUs.routeId.speaker:builtin': 50000,
        });
        var route = 'bt:headphones';
        final log = mockAudioChannel(routeId: () => route);
        final push = mockAudioEvents();
        final engine = await startEngine(address: InternetAddress.loopbackIPv4);
        final item = await engine.addMediaFile(
          await writeTempMedia(makeMediaBytes(512)),
        );
        engine.setMedia(item.mediaId);
        engine.play();
        await waitFor(() => log.any((c) => c.method == 'playAt'), reason: 'up');
        await Future<void>.delayed(const Duration(milliseconds: 100));
        log.clear();

        route = 'speaker:builtin';
        push({'type': 'routeChanged', 'routeId': route});
        await waitFor(() => engine.nudgeUs.value == 50000, reason: 'nudge');
        await Future<void>.delayed(const Duration(milliseconds: 800));
        expect(
          log.where((c) => c.method == 'playAt'),
          hasLength(1),
          reason: 'one re-anchor, not one per cause',
        );
        expect(engine.sync.manualOffsetUs, 50000);
      },
    );

    test('a nudge is saved under the route it was set on, not whatever the '
        'output is by the time the write lands', () async {
      var route = 'bt:headphones';
      mockAudioChannel(routeId: () => route);
      final engine = await startEngine(address: InternetAddress.loopbackIPv4);
      // The output changes natively; its event has not arrived yet.
      route = 'speaker:builtin';
      await engine.setNudgeUs(70000);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('nudgeUs.routeId.bt:headphones'), 70000);
      expect(prefs.getInt('nudgeUs.routeId.speaker:builtin'), isNull);
    });
  });

  test(
    'kickedPeersListenable follows kicks made on the server directly',
    () async {
      mockAudioChannel();
      final engine = await startEngine(address: InternetAddress.loopbackIPv4);
      final guest = await JamGuestClient.connect(
        engine.joinUriFor(InternetAddress.loopbackIPv4),
        clientName: 'Restless Otter',
        clientId: 'c_restless_otter', // Kicks are per device.
      );
      addTearDown(guest.close);
      await waitFor(() => engine.peers.isNotEmpty, reason: 'joined');
      engine.debugServer.kickPeer(engine.peers.single.peerId);
      await waitFor(
        () => engine.kickedPeersListenable.value.isNotEmpty,
        reason: 'listenable updated',
      );
      expect(
        engine.kickedPeersListenable.value.single.clientName,
        'Restless Otter',
      );
    },
  );

  test('host intents never throw: refused ids and a closed room answer '
      'false; play on a playing room re-sends nothing and resumes local '
      'output', () async {
    final log = mockAudioChannel();
    final push = mockAudioEvents();
    final engine = await startEngine(address: InternetAddress.loopbackIPv4);
    expect(await engine.transportPlay(), isFalse, reason: 'nothing selected');
    expect(await engine.transportSetMedia('m_not_here'), isFalse);
    expect(await engine.queueMove('m_not_here', 0), isFalse);
    expect(await engine.queueRemove('m_not_here'), isFalse);

    final item = await engine.addMediaFile(
      await writeTempMedia(makeMediaBytes(512)),
    );
    expect(await engine.transportSetMedia(item.mediaId), isTrue);
    expect(await engine.transportPlay(), isTrue);
    expect(engine.snapshot.status, PlaybackStatus.playing);
    await waitFor(() => log.any((c) => c.method == 'playAt'), reason: 'up');
    final rev = engine.snapshot.rev;

    push({'type': 'routeChanged', 'oldDeviceUnavailable': true});
    await waitFor(
      () => engine.outputSuspension.value != null,
      reason: 'output lost',
    );
    log.clear();
    expect(await engine.transportPlay(), isTrue);
    expect(engine.outputSuspension.value, isNull);
    await waitFor(
      () => log.any((c) => c.method == 'playAt'),
      reason: 'local re-anchor',
    );
    expect(engine.snapshot.rev, rev, reason: 'the room was not re-anchored');

    await engine.close();
    expect(await engine.transportPause(), isFalse);
    expect(await engine.transportPlay(), isFalse);
  });

  group('an add that outlives its room', () {
    /// The audio channel with `probeDuration` held until [release] — the
    /// first await of a host add, where a long import spends its time.
    Completer<void> holdProbes() {
      final release = Completer<void>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(audioChannel, (call) async {
            if (call.method == 'probeDuration') {
              await release.future;
              return 60000000;
            }
            if (call.method == 'nowUs') return 1000000;
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(audioChannel, null),
      );
      return release;
    }

    test('ending the room mid-add registers nothing', () async {
      mockAudioChannel();
      final engine = await startEngine(address: InternetAddress.loopbackIPv4);
      final release = holdProbes();
      final file = await writeTempMedia(makeMediaBytes(512, seed: 7));

      final add = engine.addMedia(file);
      final outcome = add.then<Object?>((r) => r, onError: (Object e) => e);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await engine.close();
      release.complete();

      expect(await outcome, isA<StateError>());
      expect(engine.playlist, isEmpty, reason: 'the closed registry');
      expect(engine.debugServer.playlist, isEmpty);
    });

    test('a tagged add abandoned by the end of the room writes no '
        'artwork', () async {
      mockAudioChannel();
      final engine = await startEngine(address: InternetAddress.loopbackIPv4);
      final release = holdProbes();
      final file = await makeTaggedMp3();

      final add = engine.addMedia(file);
      final outcome = add.then<Object?>((r) => r, onError: (Object e) => e);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await engine.close();
      release.complete();

      // Not a file-system error from a cover written into the swept upload
      // directory: the add stopped before it wrote anything.
      expect(await outcome, isA<StateError>());
      expect(engine.playlist, isEmpty);
    });

    test('importFiles stops with the room, and what was in flight does not '
        'land', () async {
      mockAudioChannel();
      final engine = await startEngine(address: InternetAddress.loopbackIPv4);
      final release = holdProbes();
      final a = await writeTempMedia(makeMediaBytes(512, seed: 8));
      final b = await writeTempMedia(makeMediaBytes(512, seed: 9));

      final job = engine.importFiles([a, b]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await engine.close();
      release.complete();

      final outcomes = await job.done;
      expect(outcomes, hasLength(1));
      expect(outcomes.single.error, isA<StateError>());
      expect(job.progress.value.cancelled, isTrue);
      expect(engine.playlist, isEmpty);
    });
  });
}
