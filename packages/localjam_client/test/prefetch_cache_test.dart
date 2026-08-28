/// The guest engine's prefetch policy and sha-keyed persistent cache against
/// a real loopback host: window ordering, re-prioritization on track change,
/// cache hits that skip the network, LRU eviction, guest uploads seeding the
/// cache, and end-to-end playback with the default (windowed) policy.
library;

import 'dart:io';

import 'package:flutter/services.dart';
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

  Future<JamHostServer> startHost({String sessionName = 'PrefetchJam'}) async {
    final host = JamHostServer(sessionName: sessionName);
    await host.start(address: InternetAddress.loopbackIPv4);
    addTearDown(host.close);
    return host;
  }

  Future<({MediaItem item, File file})> addTrack(
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
    return (item: item, file: file);
  }

  Future<List<MediaItem>> addTracks(JamHostServer host, int count) async => [
    for (var i = 0; i < count; i++) (await addTrack(host, seed: 100 + i)).item,
  ];

  Future<JamGuestEngine> joinEngine(
    JamHostServer host, {
    required Directory cacheDir,
    JamPrefetchPolicy policy = const JamPrefetchPolicy(),
    int cacheMaxBytes = 1 << 30,
    JamBackoff? backoff,
  }) async {
    final engine = await JamGuestEngine.join(
      host.joinUriFor(InternetAddress.loopbackIPv4),
      clientName: 'prefetch-guest',
      mediaCacheDir: cacheDir,
      prefetchPolicy: policy,
      cacheMaxBytes: cacheMaxBytes,
      backoff: backoff,
    );
    addTearDown(engine.close);
    return engine;
  }

  /// Records, in order, each mediaId the host sees a `ready` media_status
  /// for (§6.3). With one fetch in flight at a time this is the fetch
  /// completion order.
  List<String> recordReadyOrder(JamHostServer host) {
    final order = <String>[];
    host.events.listen((event) {
      if (event.kind == JamHostEventKind.peerMediaStatus &&
          event.mediaState == MediaFetchState.ready) {
        order.add(event.mediaId!);
      }
    });
    return order;
  }

  bool ready(JamGuestEngine engine, MediaItem item) =>
      engine.prefetchStates.value[item.mediaId]?.ready ?? false;

  test('policy fetches current-then-ahead in order and not the rest '
      '(playlist of 5, aheadCount 2)', () async {
    mockAudioChannel();
    final host = await startHost();
    final items = await addTracks(host, 5);
    host.setMedia(items[1].mediaId); // Current = index 1.
    final readyOrder = recordReadyOrder(host);

    final engine = await joinEngine(host, cacheDir: await makeTempDir());
    // Window: current (1), then ahead (2, 3).
    await waitFor(
      () => [1, 2, 3].every((i) => ready(engine, items[i])),
      reason: 'window (current + 2 ahead) to be fetched',
    );
    expect(readyOrder, [
      items[1].mediaId,
      items[2].mediaId,
      items[3].mediaId,
    ], reason: 'current at top priority, then the ahead items in order');

    // The rest report the distinct notQueued state and were never fetched.
    for (final i in [4, 0]) {
      final state = engine.prefetchStates.value[items[i].mediaId];
      expect(state?.phase, JamPrefetchPhase.notQueued);
      expect(state?.ready, isFalse);
      expect(
        host.peerMediaState(engine.selfPeerId, items[i].mediaId),
        MediaReadiness.none,
      );
    }

    // Files land in the cache keyed by sha256.
    final path = engine.prefetchStates.value[items[1].mediaId]!.path!;
    expect(path, endsWith('/${items[1].sha256}.mp3'));
  });

  test('a mediaId change re-prioritizes the plan', () async {
    mockAudioChannel();
    final host = await startHost();
    final items = await addTracks(host, 5);
    host.setMedia(items[0].mediaId);
    final readyOrder = recordReadyOrder(host);

    final engine = await joinEngine(
      host,
      cacheDir: await makeTempDir(),
      policy: const JamPrefetchPolicy(aheadCount: 0),
    );
    await waitFor(() => ready(engine, items[0]), reason: 'current fetched');

    // Jumping to a far track pulls it into the window immediately.
    host.setMedia(items[3].mediaId);
    await waitFor(
      () => ready(engine, items[3]),
      reason: 'newly-current track fetched after re-prioritization',
    );
    expect(readyOrder, [items[0].mediaId, items[3].mediaId]);
    for (final i in [1, 2, 4]) {
      expect(
        engine.prefetchStates.value[items[i].mediaId]?.phase,
        JamPrefetchPhase.notQueued,
        reason: 'out-of-window items stay unfetched',
      );
    }
  });

  test('a cache hit skips the network entirely and still reports ready, '
      'making the host allPeersReady with no fetch', () async {
    mockAudioChannel();
    final host = await startHost();
    final track = await addTrack(host, seed: 9);
    host.setMedia(track.item.mediaId);

    // Populate the sha-keyed cache up front (as a previous session would
    // have), then delete the host's backing file: a real fetch CANNOT
    // succeed, so reaching ready proves the network was skipped.
    final cacheDir = await makeTempDir();
    final cached = File('${cacheDir.path}/${track.item.sha256}.mp3');
    await cached.writeAsBytes(await track.file.readAsBytes(), flush: true);
    await track.file.delete();

    final statuses = <JamHostEvent>[];
    host.events.listen((event) {
      if (event.kind == JamHostEventKind.peerMediaStatus) {
        statuses.add(event);
      }
    });

    final engine = await joinEngine(host, cacheDir: cacheDir);
    await waitFor(
      () => ready(engine, track.item),
      reason: 'cache hit to report ready',
    );
    final state = engine.prefetchStates.value[track.item.mediaId]!;
    expect(state.path, cached.path);
    expect(state.progress, 1.0);

    // The host's readiness gate learns this directly (sendMediaStatus,
    // §6.3) — no fetch happened (the backing file was deleted above), yet
    // the host still sees the guest as ready.
    await waitFor(
      () => host.allPeersReady(track.item.mediaId),
      reason: 'host to record readiness from the cache-hit report',
    );

    // Settle, then confirm exactly one report reached the host — a
    // `ready`, no `fetching` progress (the network was never touched),
    // and no duplicate from the concurrent whole-playlist cache scan.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(statuses, hasLength(1));
    expect(statuses.single.mediaId, track.item.mediaId);
    expect(statuses.single.mediaState, MediaFetchState.ready);
  });

  test(
    'readiness is re-reported to the host after a kick + resume reconnect',
    () async {
      mockAudioChannel();
      final host = await startHost();
      final track = await addTrack(host);
      host.setMedia(track.item.mediaId);

      final engine = await joinEngine(
        host,
        cacheDir: await makeTempDir(),
        backoff: JamBackoff(
          initialDelay: const Duration(milliseconds: 20),
          maxDelay: const Duration(milliseconds: 50),
          jitterRatio: 0,
        ),
      );
      await waitFor(() => ready(engine, track.item), reason: 'track fetched');
      await waitFor(
        () => host.allPeersReady(track.item.mediaId),
        reason: 'host sees ready before the kick',
      );

      final peerId = engine.selfPeerId;
      host.kickPeer(peerId);
      await waitFor(
        () =>
            host.peerMediaState(peerId, track.item.mediaId) ==
            MediaReadiness.none,
        reason: '§3.3: host forgets readiness on drop',
      );

      await waitFor(
        () => engine.connectionState == JamConnectionState.connected,
        reason: 'resume completes',
      );
      expect(engine.selfPeerId, peerId, reason: 'resumed the same slot');
      // The file never left the local cache (prefetchStates still shows it
      // ready) — the engine must re-announce it without re-fetching.
      await waitFor(
        () => host.allPeersReady(track.item.mediaId),
        reason: 'readiness re-reported after resume',
      );
    },
  );

  test('repeated prefetch re-evaluations do not spam duplicate media_status '
      'reports', () async {
    mockAudioChannel();
    final host = await startHost();
    final items = await addTracks(host, 3);
    host.setMedia(items[0].mediaId);

    final readyEvents = <JamHostEvent>[];
    host.events.listen((e) {
      if (e.kind == JamHostEventKind.peerMediaStatus &&
          e.mediaState == MediaFetchState.ready) {
        readyEvents.add(e);
      }
    });

    final engine = await joinEngine(host, cacheDir: await makeTempDir());
    await waitFor(
      () => items.every((i) => ready(engine, i)),
      reason: 'whole (small) playlist fetched',
    );
    final countAfterFetch = readyEvents.length;
    expect(countAfterFetch, greaterThanOrEqualTo(1));

    // Re-evaluations with no new local state: cycling the current track
    // re-triggers _reevaluatePrefetch repeatedly with nothing new to
    // report.
    for (var i = 0; i < 6; i++) {
      host.setMedia(items[i % items.length].mediaId);
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(
      readyEvents.length,
      countAfterFetch,
      reason: 'no duplicate ready reports from re-evaluation',
    );
  });

  test('LRU eviction respects the cap and evicts oldest first', () async {
    mockAudioChannel();
    final host = await startHost();
    final track = await addTrack(host, size: 8192);
    host.setMedia(track.item.mediaId);

    final cacheDir = await makeTempDir();
    final staleOld = File('${cacheDir.path}/${'a' * 64}.mp3');
    final staleNew = File('${cacheDir.path}/${'b' * 64}.mp3');
    await staleOld.writeAsBytes(makeMediaBytes(4096, seed: 1));
    await staleNew.writeAsBytes(makeMediaBytes(4096, seed: 2));
    final now = DateTime.now();
    await staleOld.setLastModified(now.subtract(const Duration(days: 2)));
    await staleNew.setLastModified(now.subtract(const Duration(days: 1)));

    // Cap fits the track + one stale file: the older stale file must go.
    final engine = await joinEngine(
      host,
      cacheDir: cacheDir,
      cacheMaxBytes: 8192 + 4096,
    );
    await waitFor(() => ready(engine, track.item), reason: 'track fetched');
    await waitFor(
      () => !staleOld.existsSync(),
      reason: 'oldest stale file evicted after the fetch',
    );
    expect(staleNew.existsSync(), isTrue, reason: 'newer file kept (LRU)');
    expect(
      File(engine.prefetchStates.value[track.item.mediaId]!.path!).existsSync(),
      isTrue,
    );
  });

  test(
    'eviction never removes the current track or the ahead window',
    () async {
      mockAudioChannel();
      final host = await startHost();
      final items = await addTracks(host, 2); // 8192 bytes each.
      host.setMedia(items[0].mediaId);

      final cacheDir = await makeTempDir();
      final stale = File('${cacheDir.path}/${'c' * 64}.mp3');
      await stale.writeAsBytes(makeMediaBytes(4096, seed: 3));
      await stale.setLastModified(
        DateTime.now().subtract(const Duration(days: 3)),
      );

      // Cap smaller than even one track: the window is protected anyway.
      final engine = await joinEngine(
        host,
        cacheDir: cacheDir,
        cacheMaxBytes: 1000,
      );
      await waitFor(
        () => ready(engine, items[0]) && ready(engine, items[1]),
        reason: 'both window items fetched',
      );
      await waitFor(() => !stale.existsSync(), reason: 'stale file evicted');
      for (final item in items) {
        expect(
          File(engine.prefetchStates.value[item.mediaId]!.path!).existsSync(),
          isTrue,
          reason: 'window files survive even over the cap',
        );
      }
    },
  );

  test(
    'guest addMediaFile uploads to the host and seeds the local cache',
    () async {
      mockAudioChannel(durationUs: 33_000_000);
      final hostEngine = await JamHostEngine.start(
        sessionName: 'UploadJam',
        address: InternetAddress.loopbackIPv4,
      );
      addTearDown(hostEngine.close);

      final uploads = <({String mediaId, String? peerId})>[];
      hostEngine.mediaUploads.listen(uploads.add);

      final cacheDir = await makeTempDir();
      final guest = await JamGuestEngine.join(
        hostEngine.joinUriFor(InternetAddress.loopbackIPv4),
        clientName: 'uploader',
        mediaCacheDir: cacheDir,
      );
      addTearDown(guest.close);

      final bytes = makeMediaBytes(16384, seed: 77);
      final file = await writeTempMedia(bytes, name: 'guest_song.mp3');
      final item = await guest.addMediaFile(file, name: 'Guest Song');

      expect(item.name, 'Guest Song');
      expect(item.mime, 'audio/mpeg');
      expect(item.durationUs, 33_000_000, reason: 'probed via the player');
      expect(item.sizeBytes, bytes.length);
      expect(guest.uploadProgress.value, isNull, reason: 'reset after upload');

      // The host gained the item and surfaced the upload event.
      await waitFor(
        () => hostEngine.playlist.any((i) => i.mediaId == item.mediaId),
        reason: 'host playlist to gain the uploaded item',
      );
      await waitFor(() => uploads.isNotEmpty, reason: 'mediaUploads event');
      expect(uploads.single.mediaId, item.mediaId);
      expect(uploads.single.peerId, guest.selfPeerId);

      // The uploader's own cache is seeded — it never re-downloads its song.
      final cached = File('${cacheDir.path}/${item.sha256}.mp3');
      expect(cached.existsSync(), isTrue);
      expect(await cached.readAsBytes(), bytes);
      await waitFor(
        () => guest.prefetchStates.value[item.mediaId]?.ready ?? false,
        reason: 'uploaded item to report ready locally',
      );
      expect(guest.prefetchStates.value[item.mediaId]!.path, cached.path);

      // The playlist broadcast flowed to the guest via the normal plumbing.
      await waitFor(
        () => guest.playlist.any((i) => i.mediaId == item.mediaId),
        reason: 'guest playlist to include the upload',
      );
    },
  );

  test('default (windowed) policy still plays end to end: the controller '
      'resolves the current track from the cache', () async {
    final List<MethodCall> log = mockAudioChannel();
    final host = await startHost();
    final items = await addTracks(host, 3);
    final cacheDir = await makeTempDir();
    final engine = await joinEngine(host, cacheDir: cacheDir);

    await waitFor(() => engine.clockSynced, reason: 'clock sync');
    host.setMedia(items[0].mediaId);
    await waitFor(
      () => ready(engine, items[0]),
      reason: 'current track fetched',
    );
    host.play();
    await waitFor(
      () => engine.snapshot.status == PlaybackStatus.playing,
      reason: 'guest mirrors the playing broadcast',
    );

    // The controller loaded a resolvable cache path and scheduled playback.
    await waitFor(
      () => log.any((c) => c.method == 'playAt'),
      reason: 'guest-side playAt',
    );
    final loads = log
        .where((c) => c.method == 'load')
        .map((c) => (c.arguments as Map)['path'] as String);
    expect(
      loads,
      contains('${cacheDir.path}/${items[0].sha256}.mp3'),
      reason: 'load came from the sha-keyed cache',
    );
  });
}
