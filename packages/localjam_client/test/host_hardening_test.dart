/// [JamHostEngine] hardening: the away signal around backgrounding (§3.5),
/// listener health (a socket the OS took is reopened, or the room ends with
/// a reason), LAN candidates that exclude cellular/tunnels and follow
/// network changes (§9), the host's own end-of-media report (§5.5),
/// moderation (kick/unkick), close ordering, per-route nudges (§7) and the
/// background import.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
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

  tearDown(() {
    JamHostEngine.networkInterfaceLister =
        JamHostEngine.defaultNetworkInterfaceLister;
    JamHostEngine.backgroundSuspendPolicy =
        JamHostEngine.defaultBackgroundSuspendPolicy;
    JamHostEngine.listenerRestarter = JamHostEngine.defaultListenerRestarter;
    debugDefaultTargetPlatformOverride = null;
  });

  Future<JamHostEngine> startEngine({
    InternetAddress? address,
    JamEndPolicy endPolicy = JamEndPolicy.advance,
  }) async {
    final engine = await JamHostEngine.start(
      sessionName: 'HardHostJam',
      hostName: 'Silky Puffin',
      address: address ?? InternetAddress.loopbackIPv4,
      discoverable: false,
      endPolicy: endPolicy,
    );
    addTearDown(engine.close);
    return engine;
  }

  Future<JamGuestClient> connectGuest(JamHostEngine engine) async {
    final guest = await JamGuestClient.connect(
      engine.joinUriFor(InternetAddress.loopbackIPv4),
      clientName: 'Funky Walrus',
    );
    addTearDown(guest.close);
    return guest;
  }

  group('host away (§3.5)', () {
    test('backgrounding where the OS may suspend announces away; resuming '
        'announces back', () async {
      mockAudioChannel();
      JamHostEngine.backgroundSuspendPolicy = (_) => true;
      final engine = await startEngine();
      final guest = await connectGuest(engine);

      await engine.handleLifecycleState(AppLifecycleState.hidden);
      await engine.handleLifecycleState(AppLifecycleState.paused);
      expect(engine.announcedAway.value, isTrue);
      await waitFor(() => guest.hostAway, reason: 'guest told away');

      await engine.handleLifecycleState(AppLifecycleState.resumed);
      expect(engine.announcedAway.value, isFalse);
      await waitFor(() => !guest.hostAway, reason: 'guest told back');
    });

    test('on iOS a playing host is not away; it is once the room pauses in '
        'the background', () async {
      final log = mockAudioChannel();
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final engine = await startEngine();
      final guest = await connectGuest(engine);
      final item = await engine.addMediaFile(
        await writeTempMedia(makeMediaBytes(1024)),
      );
      engine.setMedia(item.mediaId);
      engine.play();
      await waitFor(
        () => log.any((c) => c.method == 'playAt'),
        reason: 'host playing',
      );

      await engine.handleLifecycleState(AppLifecycleState.paused);
      expect(
        engine.announcedAway.value,
        isFalse,
        reason: 'background audio keeps an iOS app running',
      );

      engine.pause(); // e.g. a guest paused the room
      await waitFor(() => engine.announcedAway.value, reason: 'away');
      await waitFor(() => guest.hostAway, reason: 'guest told away');

      await engine.handleLifecycleState(AppLifecycleState.resumed);
      expect(engine.announcedAway.value, isFalse);
    });
  });

  group('readiness hold, listenable (§6.3)', () {
    // isAwaitingReadiness had no change notification, and the server
    // announces nothing when it holds a start: the room just stays
    // `loading`. A "waiting for everyone's download" line built on the bare
    // getter never appeared for a hold a guest's play request started.

    /// A room `loading` [MediaItem] that one guest reports `fetching` — a
    /// play now is held.
    Future<(JamHostEngine, JamGuestClient, MediaItem)> holdableRoom() async {
      mockAudioChannel();
      final engine = await startEngine();
      engine.setPolicy(JamPolicy.open); // Guests may press play too.
      final item = await engine.addMediaFile(
        await writeTempMedia(makeMediaBytes(1024, seed: 7)),
      );
      final guest = await connectGuest(engine);
      guest.sendMediaStatus(
        item.mediaId,
        MediaFetchState.fetching,
        progress: .5,
      );
      await waitFor(
        () => engine
            .peerMediaStates(item.mediaId)
            .containsValue(MediaReadiness.fetching),
        reason: 'the fetching report',
      );
      engine.setMedia(item.mediaId);
      expect(engine.snapshot.status, PlaybackStatus.loading);
      return (engine, guest, item);
    }

    test("the host's own held play notifies at once; the release "
        'notifies again', () async {
      final (engine, guest, item) = await holdableRoom();
      final seen = <bool>[];
      engine.awaitingReadiness.addListener(
        () => seen.add(engine.awaitingReadiness.value),
      );

      engine.play();
      expect(engine.isAwaitingReadiness, isTrue);
      expect(engine.awaitingReadiness.value, isTrue);
      expect(seen, [true]);

      guest.sendMediaStatus(item.mediaId, MediaFetchState.ready);
      await waitFor(
        () => !engine.awaitingReadiness.value,
        reason: 'the release',
      );
      expect(engine.snapshot.status, PlaybackStatus.playing);
      expect(seen, [true, false]);
    });

    test("a guest's held play request — which no event announces — still "
        'reaches the listenable', () async {
      final (engine, guest, item) = await holdableRoom();
      expect(engine.awaitingReadiness.value, isFalse);

      await guest.requestPlay();
      await waitFor(
        () => engine.awaitingReadiness.value,
        timeout: const Duration(seconds: 2), // Inside the 2.5 s hold.
        reason: 'the held start to be seen',
      );
      expect(engine.snapshot.status, PlaybackStatus.loading);

      guest.sendMediaStatus(item.mediaId, MediaFetchState.ready);
      await waitFor(
        () => !engine.awaitingReadiness.value,
        reason: 'the release',
      );
      expect(engine.snapshot.status, PlaybackStatus.playing);
    });

    test(
      'pausing drops the hold at once; closing the room clears it',
      () async {
        final (engine, _, _) = await holdableRoom();
        engine.play();
        expect(engine.awaitingReadiness.value, isTrue);
        engine.pause();
        expect(engine.awaitingReadiness.value, isFalse);

        engine.play();
        expect(engine.awaitingReadiness.value, isTrue);
        final seen = <bool>[];
        engine.awaitingReadiness.addListener(
          () => seen.add(engine.awaitingReadiness.value),
        );
        await engine.close();
        expect(seen, [false], reason: 'a room that is over holds nothing');
      },
    );
  });

  group('listener health', () {
    test('a listening socket the OS took is reopened on the same port: '
        'the QR still works', () async {
      mockAudioChannel();
      final engine = await startEngine();
      final port = engine.port;
      await connectGuest(engine);

      await engine.handleLifecycleState(AppLifecycleState.paused);
      await engine.debugServer.debugKillListener();
      await engine.handleLifecycleState(AppLifecycleState.resumed);

      await waitFor(() => engine.isListening, reason: 'listener reopened');
      expect(engine.port, port);
      expect(engine.sessionEnded.value, isNull);
      final late = await connectGuest(engine);
      expect(late.sessionName, 'HardHostJam');
    });

    test('a listener that cannot be reopened ends the room with a reason, '
        'and guests are told; the host lets go of its guards', () async {
      mockAudioChannel();
      final keepAlive = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(JamKeepAlive.channel, (call) async {
            keepAlive.add(call.method);
            return call.method == 'acquire' ? true : null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(JamKeepAlive.channel, null),
      );
      JamHostEngine.listenerRestarter = (_) async =>
          throw const SocketException('port taken');
      final engine = await startEngine();
      expect(keepAlive, ['acquire']);
      final guest = await JamGuestEngine.join(
        engine.joinUriFor(InternetAddress.loopbackIPv4),
        clientName: 'told-guest',
        mediaCacheDir: await makeTempDir(),
      );
      addTearDown(guest.close);

      JamSessionEndReason? ended;
      engine.sessionEnded.addListener(() => ended = engine.sessionEnded.value);
      await engine.debugServer.debugKillListener();
      await waitFor(() => ended != null, reason: 'the room to end');
      expect(ended, JamSessionEndReason.listenerFailed);
      await waitFor(
        () => guest.sessionEnded.value != null,
        reason: 'session_ended to reach the guest',
      );
      expect(guest.sessionEnded.value, JamSessionEndReason.hostEnded);
      // Ended, not yet closed by the app: nothing is held for a dead room —
      // no foreground service, no media card, no lifecycle observer. (One
      // process plays both parts here: the host's release and the told
      // guest's.)
      await waitFor(
        () => keepAlive.where((c) => c == 'release').length == 2,
        reason: 'both keep-alives released',
      );
      expect(engine.lifecycleObserverAttached, isFalse);
      expect(engine.mediaSessionController, isNull);
      await engine.close();
    });
  });

  group('LAN candidates (§9)', () {
    test('cellular links and tunnels are never candidates; Wi-Fi, '
        'Ethernet, hotspot and tethering are', () {
      for (final name in [
        'rmnet0',
        'rmnet_data0',
        'ccmni1',
        'pdp_ip0',
        'wwan0',
        'v4-rmnet_data0',
        'tun0',
        'utun3',
        'ipsec0',
        'ppp0',
        'wg0',
      ]) {
        expect(JamHostEngine.isLanInterface(name), isFalse, reason: name);
      }
      for (final name in [
        'wlan0',
        'en0',
        'eth0',
        'ap0',
        'swlan0',
        'bridge100',
        'rndis0',
      ]) {
        expect(JamHostEngine.isLanInterface(name), isTrue, reason: name);
      }
      final lan = JamHostEngine.lanAddressesOf([
        FakeNetworkInterface('wlan0', ['192.168.1.7', '100.64.3.4']),
        FakeNetworkInterface('rmnet_data0', ['10.20.30.40']),
        FakeNetworkInterface('pdp_ip0', ['10.1.1.1']),
        FakeNetworkInterface('lo0', ['127.0.0.1']),
      ]);
      expect(lan.map((a) => a.address), ['192.168.1.7']);
    });

    test('the join URI follows network changes, and a device with no LAN '
        'says so', () async {
      mockAudioChannel();
      var interfaces = [
        FakeNetworkInterface('en0', ['192.168.1.7']),
      ];
      JamHostEngine.networkInterfaceLister = () async => interfaces;
      final engine = await JamHostEngine.start(
        sessionName: 'RoamJam',
        hostName: 'Silky Puffin',
        discoverable: false,
      );
      addTearDown(engine.close);
      List<String> hosts() => engine.joinLink.hosts;
      expect(engine.hasLanAddress, isTrue);
      expect(hosts(), ['192.168.1.7', '127.0.0.1']);

      final uris = <Uri>[];
      engine.joinUriListenable.addListener(
        () => uris.add(engine.joinUriListenable.value),
      );
      interfaces = [
        FakeNetworkInterface('wlan0', ['10.0.0.5']),
        FakeNetworkInterface('rmnet0', ['10.20.30.40']),
      ];
      await engine.refreshLanAddresses();
      expect(hosts(), ['10.0.0.5', '127.0.0.1']);
      expect(uris, hasLength(1));
      expect(engine.lanAddresses.value.map((a) => a.address), ['10.0.0.5']);

      // Wi-Fi off, cellular only: nothing another device could reach.
      interfaces = [
        FakeNetworkInterface('rmnet_data0', ['10.1.1.1']),
      ];
      await engine.refreshLanAddresses();
      expect(engine.hasLanAddress, isFalse);
      expect(hosts(), ['127.0.0.1']);

      // A failed scan is an unknown LAN, not an absent one: keep what we had.
      interfaces = [
        FakeNetworkInterface('wlan0', ['10.0.0.9']),
      ];
      await engine.refreshLanAddresses();
      JamHostEngine.networkInterfaceLister = () async =>
          throw const SocketException('refused');
      await engine.refreshLanAddresses();
      expect(hosts(), ['10.0.0.9', '127.0.0.1']);
    });

    test('a cellular-only device has no LAN address to offer (yet), and '
        'listens on every interface for when it does', () async {
      mockAudioChannel();
      JamHostEngine.networkInterfaceLister = () async => [
        FakeNetworkInterface('rmnet_data0', ['10.1.1.1']),
        FakeNetworkInterface('pdp_ip0', ['100.70.1.2']),
      ];
      final engine = await JamHostEngine.start(
        sessionName: 'CellJam',
        hostName: 'Silky Puffin',
        discoverable: false,
      );
      addTearDown(engine.close);
      expect(engine.hasLanAddress, isFalse);
      expect(engine.joinLink.hosts, ['127.0.0.1']);
      expect(engine.boundAddress, InternetAddress.anyIPv4);
    });
  });

  test(
    "the host's own player ends an item with no known duration (§5.5)",
    () async {
      final log = mockAudioChannel(probeKnowsDuration: false);
      final push = mockAudioEvents();
      final engine = await startEngine();
      final a = await engine.addMediaFile(
        await writeTempMedia(makeMediaBytes(1024, seed: 1), name: 'a.mp3'),
      );
      final b = await engine.addMediaFile(
        await writeTempMedia(makeMediaBytes(1024, seed: 2), name: 'b.mp3'),
      );
      expect(a.durationUs, isNull, reason: 'unknown duration: no anchor end');
      final ended = <String?>[];
      engine.mediaEnded.listen(ended.add);
      engine.setMedia(a.mediaId);
      engine.play();
      await waitFor(
        () => log.any((c) => c.method == 'playAt'),
        reason: 'host playing',
      );
      // Past the scheduled start (the §5.3 lead), the host's player runs
      // out of file.
      await waitFor(
        () => monotonicNowUs() > engine.snapshot.anchor!.hostTimeUs,
        reason: 'the scheduled start to pass',
      );
      push({'type': 'playbackFinished'});
      await waitFor(() => ended.isNotEmpty, reason: 'mediaEnded');
      expect(ended.single, a.mediaId);
      expect(engine.snapshot.mediaId, b.mediaId, reason: 'advanced');
    },
  );

  test('kicked devices are listed and can be let back in', () async {
    mockAudioChannel();
    final engine = await startEngine();
    final joinUri = engine.joinUriFor(InternetAddress.loopbackIPv4);
    final first = await JamGuestEngine.join(
      joinUri,
      clientId: 'c_kicked',
      clientName: 'Restless Otter',
      mediaCacheDir: await makeTempDir(),
    );
    addTearDown(first.close);

    engine.kickPeer(first.selfPeerId);
    expect(engine.kickedPeers.single.clientName, 'Restless Otter');
    expect(engine.kickedPeersListenable.value, hasLength(1));
    await expectLater(
      JamGuestEngine.join(
        joinUri,
        clientId: 'c_kicked',
        mediaCacheDir: await makeTempDir(),
      ),
      throwsA(
        isA<JamRejectedException>().having(
          (e) => e.reason,
          'reason',
          RejectReason.kicked,
        ),
      ),
    );

    expect(engine.unkickPeer(engine.kickedPeers.single.peerId), isTrue);
    expect(engine.kickedPeersListenable.value, isEmpty);
    final again = await JamGuestEngine.join(
      joinUri,
      clientId: 'c_kicked',
      mediaCacheDir: await makeTempDir(),
    );
    addTearDown(again.close);
    expect(again.connectionState, JamConnectionState.connected);
  });

  test('close tells guests first, and a failing step does not skip the '
      'rest', () async {
    mockAudioChannel();
    final engine = await startEngine();
    bool? listeningWhenAudioReleased;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(audioChannel, (call) async {
          if (call.method == 'dispose') {
            listeningWhenAudioReleased = engine.isListening;
            throw PlatformException(code: 'engine_error');
          }
          return null;
        });
    final guest = await JamGuestEngine.join(
      engine.joinUriFor(InternetAddress.loopbackIPv4),
      clientName: 'goodbye-guest',
      mediaCacheDir: await makeTempDir(),
    );
    addTearDown(guest.close);
    final statesDone = engine.states.toList();

    await engine.close();
    expect(listeningWhenAudioReleased, isFalse, reason: 'server closed first');
    await statesDone.timeout(const Duration(seconds: 2)); // streams closed
    await waitFor(
      () => guest.sessionEnded.value != null,
      reason: 'session_ended',
    );
    expect(guest.sessionEnded.value, JamSessionEndReason.hostEnded);
  });

  test('the nudge follows the output route (§7)', () async {
    var route = 'bt:headphones';
    mockAudioChannel(routeId: () => route);
    final push = mockAudioEvents();
    final engine = await startEngine();

    await engine.setNudgeUs(120000);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('nudgeUs.routeId.bt:headphones'), 120000);

    // Headphones off: the speaker has no nudge of its own.
    route = 'speaker:builtin';
    push({'type': 'routeChanged', 'routeId': route});
    await waitFor(() => engine.nudgeUs.value == 0, reason: 'speaker nudge');
    expect(engine.sync.manualOffsetUs, 0);
    await engine.setNudgeUs(10000);
    expect(prefs.getInt('nudgeUs.routeId.speaker:builtin'), 10000);

    // Back on: theirs comes back.
    route = 'bt:headphones';
    push({'type': 'routeChanged', 'routeId': route});
    await waitFor(
      () => engine.nudgeUs.value == 120000,
      reason: 'headphones nudge restored',
    );
    expect(engine.sync.manualOffsetUs, 120000);
  });

  test('importFiles opens the queue in the background: progress, per-file '
      'outcomes, the first track cued and playing', () async {
    mockAudioChannel();
    final engine = await startEngine();
    final dir = await makeTempDir();
    final a = await writeTempMedia(makeMediaBytes(512, seed: 1), name: 'a.mp3');
    final b = await writeTempMedia(makeMediaBytes(512, seed: 2), name: 'b.mp3');
    final missing = File('${dir.path}/gone.mp3');

    final job = engine.importFiles([a, missing, b, a], autoPlay: true);
    expect(job.progress.value.total, 4);
    final outcomes = await job.done;
    final progress = job.progress.value;
    expect(progress.isDone, isTrue);
    expect(progress.added, 2);
    expect(progress.failed, 1);
    expect(progress.alreadyQueued, 1);
    expect(outcomes[1].error, isNotNull);
    expect(outcomes[0].result?.outcome, JamAddOutcome.added);
    expect(engine.playlist, hasLength(2));
    expect(engine.snapshot.mediaId, outcomes[0].result!.item.mediaId);
    expect(engine.snapshot.status, PlaybackStatus.playing);
  });
}
