/// [JamGuestEngine] against a real loopback [JamHostServer]: join, clock
/// sync, real-HTTP prefetch into a cache directory, snapshot mirroring into
/// the (channel-mocked) audio controller, and the §5.2 request path.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_client/localjam_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'engine_test_utils.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // The test binding fakes every HttpClient with a 400 stub; these tests
  // exercise the real media plane over loopback.
  setUpAll(() => HttpOverrides.global = null);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<JamHostServer> startHost({String sessionName = 'TestJam'}) async {
    final host = JamHostServer(sessionName: sessionName);
    await host.start(address: InternetAddress.loopbackIPv4);
    addTearDown(host.close);
    return host;
  }

  Future<MediaItem> addTrack(
    JamHostServer host, {
    int size = 8192,
    int seed = 42,
    int durationUs = 60_000_000,
  }) async {
    final file = await writeTempMedia(makeMediaBytes(size, seed: seed));
    final item = await JamHostServer.describeFile(
      file,
      kind: MediaKind.audio,
      mime: 'audio/mpeg',
      durationUs: durationUs,
    );
    host.addMedia(item, file);
    return item;
  }

  Future<JamGuestEngine> joinEngine(JamHostServer host) async {
    final engine = await JamGuestEngine.join(
      host.joinUriFor(InternetAddress.loopbackIPv4),
      clientName: 'engine-guest',
      mediaCacheDir: await makeTempDir(),
    );
    addTearDown(engine.close);
    return engine;
  }

  test(
    'join → prefetches the playlist over real HTTP and reports ready',
    () async {
      mockAudioChannel();
      final host = await startHost(sessionName: 'RoadTrip');
      final bytes = makeMediaBytes(8192);
      final item = await addTrack(host);

      final engine = await joinEngine(host);
      expect(engine.sessionName, 'RoadTrip');
      expect(engine.selfPeerId, startsWith('p_'));
      expect(engine.playlist.single.mediaId, item.mediaId);
      expect(engine.connectionState, JamConnectionState.connected);

      await waitFor(
        () => engine.prefetchStates.value[item.mediaId]?.ready ?? false,
        reason: 'prefetch to finish',
      );
      final fetched = engine.prefetchStates.value[item.mediaId]!;
      expect(fetched.progress, 1.0);
      expect(fetched.path, endsWith('.mp3'));
      expect(await File(fetched.path!).readAsBytes(), bytes);

      // The host learned readiness via media_status (§6.3).
      await waitFor(
        () =>
            host.peerMediaState(engine.selfPeerId, item.mediaId) ==
            MediaReadiness.ready,
        reason: 'host to see media_status ready',
      );
      expect(host.allPeersReady(item.mediaId), isTrue);
    },
  );

  test('a playlist item added after joining is prefetched too', () async {
    mockAudioChannel();
    final host = await startHost();
    final engine = await joinEngine(host);
    expect(engine.playlist, isEmpty);

    final item = await addTrack(host, seed: 7);
    await waitFor(
      () => engine.prefetchStates.value[item.mediaId]?.ready ?? false,
      reason: 'late-added item to prefetch',
    );
  });

  test(
    'snapshot mirrors the host and feeds the controller after clock sync',
    () async {
      final log = mockAudioChannel(durationUs: 60_000_000);
      final host = await startHost();
      final item = await addTrack(host);
      final engine = await joinEngine(host);

      await waitFor(() => engine.clockSynced, reason: 'clock sync join burst');
      expect(engine.clockOffsetUs, isNotNull);
      // Host and guest share one process-wide monotonic clock in tests.
      expect(engine.clockOffsetUs!.abs(), lessThan(20_000));

      await waitFor(
        () => engine.prefetchStates.value[item.mediaId]?.ready ?? false,
        reason: 'prefetch before playing (§6.2)',
      );

      host.setMedia(item.mediaId);
      host.play();
      await waitFor(
        () => engine.snapshot.status == PlaybackStatus.playing,
        reason: 'guest to mirror the playing broadcast',
      );
      expect(engine.snapshot.rev, host.snapshot.rev);
      expect(engine.currentItem?.mediaId, item.mediaId);

      // The controller scheduled the anchor on the (mocked) native player.
      await waitFor(
        () => log.any((c) => c.method == 'playAt'),
        reason: 'guest-side playAt',
      );
      final playAt = log.lastWhere((c) => c.method == 'playAt');
      final args = playAt.arguments as Map<Object?, Object?>;
      expect(args['positionUs'], host.snapshot.anchor!.positionUs);

      final position = engine.positionUsNow();
      expect(position, isNotNull);
      expect(position, inInclusiveRange(0, 60_000_000));
    },
  );

  test('request path works end to end (§5.2)', () async {
    mockAudioChannel();
    final host = await startHost();
    final item = await addTrack(host);
    final engine = await joinEngine(host);

    await waitFor(() => engine.clockSynced, reason: 'clock sync');

    await engine.requestSetMedia(item.mediaId);
    await waitFor(
      () => engine.snapshot.mediaId == item.mediaId,
      reason: 'set_media round trip',
    );

    await engine.requestPlay();
    await waitFor(
      () => engine.snapshot.status == PlaybackStatus.playing,
      reason: 'play round trip',
    );
    expect(host.snapshot.status, PlaybackStatus.playing);

    await engine.requestSeek(5_000_000);
    await waitFor(
      () => engine.snapshot.anchor?.positionUs == 5_000_000,
      reason: 'seek round trip',
    );

    await engine.requestPause();
    await waitFor(
      () => engine.snapshot.status == PlaybackStatus.paused,
      reason: 'pause round trip',
    );
    expect(host.snapshot.status, PlaybackStatus.paused);
  });
}
