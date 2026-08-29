/// [JamHostEngine] against its real [JamHostServer] on loopback, with the
/// `localjam_audio` method channel mocked (TestDefaultBinaryMessenger): the
/// native audio side does not exist under flutter_test, but everything above
/// it — server, sockets, controller plumbing — is real.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_client/localjam_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'engine_test_utils.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // The test binding fakes every HttpClient with a 400 stub; these tests
  // talk to a real loopback server.
  setUpAll(() => HttpOverrides.global = null);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<JamHostEngine> startEngine({
    JamEndPolicy endPolicy = JamEndPolicy.pause,
  }) async {
    final engine = await JamHostEngine.start(
      sessionName: 'HostJam',
      endPolicy: endPolicy,
      address: InternetAddress.loopbackIPv4,
    );
    addTearDown(engine.close);
    return engine;
  }

  test(
    'start → addMediaFile probes the duration → play broadcasts playing',
    () async {
      final log = mockAudioChannel(durationUs: 42_000_000);
      final engine = await startEngine();

      expect(engine.sessionName, 'HostJam');
      expect(engine.port, greaterThan(0));
      expect(engine.joinUri.scheme, 'localjam');
      expect(engine.joinUri.queryParameters['token'], engine.token);
      expect(engine.snapshot.status, PlaybackStatus.idle);

      // addMediaFile loads the file through the engine's player to obtain the
      // §5.5 duration, and registers + broadcasts the playlist item.
      final file = await writeTempMedia(makeMediaBytes(4096));
      final item = await engine.addMediaFile(file, name: 'Song A');
      expect(item.durationUs, 42_000_000);
      expect(item.name, 'Song A');
      expect(item.mime, 'audio/mpeg');
      expect(engine.playlist.map((i) => i.mediaId), [item.mediaId]);
      expect(
        log
            .where((c) => c.method == 'load')
            .map((c) => (c.arguments as Map)['path']),
        contains(file.path),
      );

      // A real guest sees the playing broadcast.
      final guest = await JamGuestClient.connect(
        engine.joinUriFor(InternetAddress.loopbackIPv4),
      );
      addTearDown(guest.close);

      final statesSeen = <PlaybackSnapshot>[];
      engine.states.listen(statesSeen.add);

      engine.setMedia(item.mediaId);
      engine.play();
      expect(engine.snapshot.status, PlaybackStatus.playing);
      expect(engine.snapshot.anchor, isNotNull);
      await waitFor(
        () =>
            statesSeen.isNotEmpty &&
            statesSeen.last.status == PlaybackStatus.playing,
        reason: 'states stream to carry the playing broadcast',
      );

      await waitFor(
        () => guest.snapshot.status == PlaybackStatus.playing,
        reason: 'guest to mirror the playing broadcast',
      );
      expect(guest.snapshot.rev, engine.snapshot.rev);

      // The host plays along: its own controller scheduled the anchor.
      await waitFor(
        () => log.any((c) => c.method == 'playAt'),
        reason: 'host-side playAt',
      );
    },
  );

  test(
    'addMediaFile extracts tags + artwork (§6.1 v0.2, §6.5); the native '
    'duration probe wins over the tag duration',
    () async {
      mockAudioChannel(durationUs: 42_000_000);
      final engine = await startEngine();

      final item = await engine.addMediaFile(
        File('../../test-media/track1_tagged.m4a'),
      );
      expect(item.title, 'Night Drive');
      expect(item.artist, 'The Localhosts');
      expect(item.album, 'Loopback Sessions');
      expect(item.displayTitle, 'Night Drive');
      // The mocked native probe answered 42 s; the tag claims ~42.68 s. The
      // probe wins (§6.1: a decoder probe beats a tag claim).
      expect(item.durationUs, 42_000_000);
      expect(item.artworkId, startsWith('a_'));

      // The host reads artwork from its own registry, no HTTP.
      final artwork = await engine.artworkFor(item);
      expect(artwork, isNotNull);
      expect(artwork, isNotEmpty);

      // An untagged file yields an item with null tags and no artwork.
      final untagged = await engine.addMediaFile(
        await writeTempMedia(makeMediaBytes(4096)),
        name: 'Untitled.mp3',
      );
      expect(untagged.title, isNull);
      expect(untagged.artworkId, isNull);
      expect(untagged.displayTitle, 'Untitled.mp3');
      expect(await engine.artworkFor(untagged), isNull);
    },
  );

  test(
    'next/previous wrap the playlist; transport mirrors the server',
    () async {
      mockAudioChannel();
      final engine = await startEngine();
      final a = await engine.addMediaFile(
        await writeTempMedia(makeMediaBytes(512, seed: 1), name: 'a.mp3'),
      );
      final b = await engine.addMediaFile(
        await writeTempMedia(makeMediaBytes(512, seed: 2), name: 'b.mp3'),
      );

      engine.setMedia(a.mediaId);
      engine.next();
      expect(engine.snapshot.mediaId, b.mediaId);
      engine.next();
      expect(engine.snapshot.mediaId, a.mediaId, reason: 'wraps forward');
      engine.previous();
      expect(engine.snapshot.mediaId, b.mediaId, reason: 'wraps backward');

      engine.play();
      expect(engine.snapshot.status, PlaybackStatus.playing);
      engine.pause();
      expect(engine.snapshot.status, PlaybackStatus.paused);
      engine.stop();
      expect(engine.snapshot.status, PlaybackStatus.idle);
    },
  );

  test('setNudgeUs applies to the controller and persists', () async {
    mockAudioChannel();
    final engine = await startEngine();

    await engine.setNudgeUs(30_000);
    expect(engine.sync.manualOffsetUs, 30_000);
    expect(engine.nudgeUs.value, 30_000);

    // The persisted value is keyed by output route (mocked latency: 0).
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('nudgeUs.route_0'), 30_000);
  });

  test(
    'positionUsNow is null with no media and clamps to the duration',
    () async {
      mockAudioChannel(durationUs: 1_000_000);
      final engine = await startEngine();
      expect(engine.positionUsNow(), isNull);

      final item = await engine.addMediaFile(
        await writeTempMedia(makeMediaBytes(256)),
      );
      engine.setMedia(item.mediaId);
      engine.seek(500_000);
      expect(engine.positionUsNow(), 500_000);

      engine.seek(999_999_000); // Server clamps the seek itself (§5.5)...
      expect(engine.positionUsNow(), lessThanOrEqualTo(1_000_000));
    },
  );
}
