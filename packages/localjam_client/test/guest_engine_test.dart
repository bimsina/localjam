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

  Future<JamHostServer> startHost({
    String sessionName = 'TestJam',
    // Transport-focused tests run wide open; §5.6 enforcement is covered in
    // localjam_net's integration suite and the dedicated tests below.
    JamPolicy policy = JamPolicy.open,
  }) async {
    final host = JamHostServer(sessionName: sessionName, policy: policy);
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

  test('joins from either join form (§1): the 1.2 http URL a QR carries '
      'and the localjam:// deep link', () async {
    mockAudioChannel();
    final host = await startHost(sessionName: 'Both Forms');
    final link = host.joinLinkFor(InternetAddress.loopbackIPv4);
    for (final uri in [link.toHttpUri(), link.toLocaljamUri()]) {
      final engine = await JamGuestEngine.join(
        uri,
        clientName: 'form-guest',
        mediaCacheDir: await makeTempDir(),
      );
      expect(engine.sessionName, 'Both Forms', reason: '$uri');
      expect(engine.joinUri, uri, reason: 'kept as given, for rejoin');
      await engine.close();
    }
    await expectLater(
      JamGuestEngine.join(
        Uri.parse('https://example.com/join#token=t'),
        mediaCacheDir: await makeTempDir(),
      ),
      throwsFormatException,
    );
  });

  test('a relaunched guest rejoins as one peer, not two (§3.3)', () async {
    mockAudioChannel();
    JamIdentity.resetCacheForTesting();
    addTearDown(JamIdentity.resetCacheForTesting);
    SharedPreferences.setMockInitialValues({
      'localjam.displayName': 'Quirky Toucan',
      'localjam.clientId': 'c_this_device',
    });
    // Long enough that the host's silence sweep cannot quietly clean up
    // after us: this device is back before its corpse could be reaped.
    final host = JamHostServer(
      sessionName: 'RelaunchJam',
      silenceTimeout: const Duration(seconds: 30),
    );
    await host.start(address: InternetAddress.loopbackIPv4);
    addTearDown(host.close);
    final joinUri = host.joinUriFor(InternetAddress.loopbackIPv4);

    final first = await JamGuestEngine.join(
      joinUri,
      mediaCacheDir: await makeTempDir(),
    );
    await waitFor(() => host.peers.isNotEmpty, reason: 'the first join');

    // The app is force-quit: no goodbye reaches the host, and the device
    // comes back as a brand new engine with the same persisted identity.
    final back = await JamGuestEngine.join(
      joinUri,
      mediaCacheDir: await makeTempDir(),
    );
    addTearDown(back.close);

    expect(host.peers.map((p) => p.peerId), [back.selfPeerId]);
    expect(back.peers, isEmpty, reason: 'no ghost of itself in the roster');
    expect(back.selfPeerId, isNot(first.selfPeerId));
    await first.close();
  });

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

  test('artworkFor fetches over HTTP, caches to disk, and survives a new '
      'engine on the same cache (§6.5)', () async {
    mockAudioChannel();
    final host = await startHost();
    final artworkBytes = makeMediaBytes(600, seed: 5);
    final artworkId = await host.addArtwork(artworkBytes, mime: 'image/png');

    final file = await writeTempMedia(makeMediaBytes(8192));
    final item = await JamHostServer.describeFile(
      file,
      kind: MediaKind.audio,
      mime: 'audio/mpeg',
      durationUs: 60_000_000,
      title: 'Night Drive',
      artist: 'The Localhosts',
      artworkId: artworkId,
    );
    host.addMedia(item, file);

    final cacheDir = await makeTempDir();
    final engine = await JamGuestEngine.join(
      host.joinUriFor(InternetAddress.loopbackIPv4),
      mediaCacheDir: cacheDir,
    );
    addTearDown(engine.close);
    await waitFor(
      () => engine.playlist.isNotEmpty,
      reason: 'playlist to arrive',
    );
    final mirrored = engine.playlist.single;
    expect(mirrored.title, 'Night Drive');
    expect(mirrored.artist, 'The Localhosts');
    expect(mirrored.artworkId, artworkId);

    // First call fetches from the host; concurrent calls share one load.
    final loads = await Future.wait([
      engine.artworkFor(mirrored),
      engine.artworkFor(mirrored),
    ]);
    expect(loads[0], equals(artworkBytes));
    expect(loads[1], equals(artworkBytes));
    // The bytes landed in the persistent cache under the artworkId.
    expect(
      await File('${cacheDir.path}/$artworkId').readAsBytes(),
      equals(artworkBytes),
    );

    // A fresh engine on the same cache dir serves it from disk — even after
    // the artwork disappears host-side.
    await engine.close();
    host.artworkFile(artworkId)!.deleteSync();
    final engine2 = await JamGuestEngine.join(
      host.joinUriFor(InternetAddress.loopbackIPv4),
      mediaCacheDir: cacheDir,
    );
    addTearDown(engine2.close);
    await waitFor(
      () => engine2.playlist.isNotEmpty,
      reason: 'playlist to arrive on rejoin',
    );
    expect(
      await engine2.artworkFor(engine2.playlist.single),
      equals(artworkBytes),
    );

    // An item without artwork resolves null.
    final bare = await JamHostServer.describeFile(
      file,
      kind: MediaKind.audio,
      mediaId: 'm_bare',
      mime: 'audio/mpeg',
    );
    expect(await engine2.artworkFor(bare), isNull);
  });

  test('permissions surface (§5.6): mirroring, denial errors, kicked end '
      'reason', () async {
    mockAudioChannel();
    final host = await startHost(policy: JamPolicy.listenOnly);
    await addTrack(host);
    final engine = await joinEngine(host);

    expect(engine.permissions.policy, JamPolicy.listenOnly);
    expect(engine.myCapabilities, isEmpty);
    expect(engine.can(JamCapability.controlPlayback), isFalse);

    final docs = <JamPermissions>[];
    engine.permissionUpdates.listen(docs.add);
    final errors = <ErrorMessage>[];
    engine.errors.listen(errors.add);

    // A denied request surfaces as a transient not_allowed error.
    await engine.requestPlay();
    await waitFor(() => errors.isNotEmpty, reason: 'not_allowed to arrive');
    expect(errors.single.code, ErrorCode.notAllowed);
    expect(engine.sessionEnded.value, isNull);

    // Promotion flows through the update stream and flips capabilities.
    host.promotePeer(engine.selfPeerId);
    await waitFor(() => docs.isNotEmpty, reason: 'permissions broadcast');
    expect(engine.can(JamCapability.controlPlayback), isTrue);

    // A real kick lands the terminal kicked reason, not hostGone/rejected.
    host.kickPeer(engine.selfPeerId);
    await waitFor(
      () => engine.sessionEnded.value != null,
      reason: 'terminal session end after kick',
    );
    expect(engine.sessionEnded.value, JamSessionEndReason.kicked);
  });

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
  test('re-adding a file the jam already has reports alreadyQueued instead '
      'of silently doing nothing (§6.4)', () async {
    // Media ids are content-derived, so the host answers a duplicate upload
    // 200-with-the-existing-item and broadcasts no playlist. Correct, and
    // indistinguishable from a failure to whoever just picked the file.
    mockAudioChannel();
    final host = await startHost();
    final engine = await joinEngine(host);
    final file = await writeTempMedia(makeMediaBytes(4096, seed: 11));

    final first = await engine.addMedia(file, name: 'Song.mp3');
    expect(first.outcome, JamAddOutcome.added);
    expect(first.alreadyQueued, isFalse);
    await waitFor(
      () => engine.playlist.any((i) => i.mediaId == first.item.mediaId),
      reason: 'the playlist broadcast for the new item',
    );

    final again = await engine.addMedia(file, name: 'Song.mp3');
    expect(again.item.mediaId, first.item.mediaId);
    expect(again.outcome, JamAddOutcome.alreadyQueued);
    expect(host.playlist, hasLength(1), reason: 'nothing was duplicated');

    // The legacy entry point still returns the item, unchanged.
    expect((await engine.addMediaFile(file)).mediaId, first.item.mediaId);

    // Different bytes are a genuine add, even under the same name.
    final other = await engine.addMedia(
      await writeTempMedia(makeMediaBytes(4096, seed: 12)),
      name: 'Song.mp3',
    );
    expect(other.outcome, JamAddOutcome.added);
  });

  test('the host reports the same outcome for its own duplicate add', () async {
    mockAudioChannel();
    final engine = await JamHostEngine.start(
      sessionName: 'DupeJam',
      address: InternetAddress.loopbackIPv4,
    );
    addTearDown(engine.close);
    final file = await writeTempMedia(makeMediaBytes(2048, seed: 3));
    expect((await engine.addMedia(file)).outcome, JamAddOutcome.added);
    final again = await engine.addMedia(file);
    expect(again.outcome, JamAddOutcome.alreadyQueued);
    expect(engine.playlist, hasLength(1));
  });
}
