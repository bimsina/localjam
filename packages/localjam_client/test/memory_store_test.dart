/// The browser guest's media store and readiness rule (docs/design/
/// WEB_GUEST.md D7, PROTOCOL.md §3.1, §6.2, §6.3), on the VM: the
/// [JamMemoryMediaStore]'s budget, LRU order, protected items and `blob:`
/// URL lifecycle with a recording [JamBlobUrls]; and a [JamGuestEngine] on
/// that store against a real loopback host, where `ready` waits for the
/// decode probe and an item that will not decode is unplayable, reported
/// `none`, dropped, and never blocks the room.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_client/localjam_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'engine_test_utils.dart';

/// Mints `blob:test/<n>#<mime>` and records what was revoked.
class RecordingBlobUrls extends JamBlobUrls {
  final Map<String, Uint8List> live = {};
  final List<String> revoked = [];
  int _next = 0;

  @override
  String create(Uint8List bytes, String mime) {
    final url = 'blob:test/${_next++}#$mime';
    live[url] = bytes;
    return url;
  }

  @override
  void revoke(String url) {
    live.remove(url);
    revoked.add(url);
  }
}

MediaItem _item(String tag, int size, {String mime = 'audio/mpeg'}) =>
    MediaItem(
      mediaId: 'm_$tag',
      kind: MediaKind.audio,
      name: '$tag.mp3',
      mime: mime,
      sizeBytes: size,
      // A well-formed digest per tag (the store keys on it).
      sha256: tag.codeUnitAt(0).toRadixString(16).padLeft(2, '0') * 32,
    );

Future<String> _put(JamMemoryMediaStore store, MediaItem item) async {
  final write = store.open(item);
  await write.sink.open();
  write.sink.add(Uint8List(item.sizeBytes));
  await write.sink.close();
  return write.commit();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('JamMemoryMediaStore', () {
    late RecordingBlobUrls urls;
    setUp(() => urls = RecordingBlobUrls());

    test(
      'holds bodies by sha256 and refuses ids that are not digests',
      () async {
        final store = JamMemoryMediaStore(maxBytes: 1000, blobUrls: urls);
        final a = _item('a', 10);
        expect(await store.lookup(a), isNull);
        final ref = await _put(store, a);
        expect(await store.lookup(a), ref);
        expect(store.totalBytes, 10);
        final bogus = MediaItem(
          mediaId: 'm_x',
          kind: MediaKind.audio,
          name: 'x',
          mime: 'audio/mpeg',
          sizeBytes: 1,
          sha256: '../../etc/passwd',
        );
        expect(store.accepts(bogus), isFalse);
        expect(() => store.open(bogus), throwsArgumentError);
        // A body of the wrong size is not the item.
        expect(await store.lookup(_item('a', 11)), isNull);
      },
    );

    test('a discarded write leaves nothing behind', () async {
      final store = JamMemoryMediaStore(maxBytes: 1000, blobUrls: urls);
      final a = _item('a', 10);
      final write = store.open(a);
      write.sink.add(Uint8List(5));
      await write.discard();
      expect(await store.lookup(a), isNull);
      expect(store.totalBytes, 0);
    });

    test('evicts least recently used first, down to the budget', () async {
      final store = JamMemoryMediaStore(maxBytes: 100, blobUrls: urls);
      final a = _item('a', 40), b = _item('b', 40), c = _item('c', 40);
      final refA = await _put(store, a);
      final refB = await _put(store, b);
      final refC = await _put(store, c);
      // A use makes a recent: b is now the oldest.
      await store.lookup(a);
      expect(store.refsByRecency, [refB, refC, refA]);
      final evicted = await store.evict(keep: const []);
      expect(evicted, {refB});
      expect(store.totalBytes, 80);
      expect(await store.lookup(b), isNull);
      // Under budget: nothing more goes.
      expect(await store.evict(keep: const []), isEmpty);
    });

    test('never evicts the current and next items, nor the one in flight, '
        'even over budget', () async {
      final store = JamMemoryMediaStore(maxBytes: 50, blobUrls: urls);
      final a = _item('a', 40), b = _item('b', 40), c = _item('c', 40);
      await _put(store, a);
      await _put(store, b);
      final refC = await _put(store, c);
      final evicted = await store.evict(keep: [a], inFlight: b);
      expect(evicted, {refC});
      expect(store.totalBytes, 80, reason: 'protected items keep it over');
      expect(await store.lookup(a), isNotNull);
      expect(await store.lookup(b), isNotNull);
    });

    test('blob: URLs are minted on demand, once, and revoked on release, '
        'eviction, removal and dispose', () async {
      final store = JamMemoryMediaStore(maxBytes: 100, blobUrls: urls);
      final a = _item('a', 40), b = _item('b', 40), c = _item('c', 40);
      final refA = await _put(store, a);
      expect(urls.live, isEmpty, reason: 'no URL until someone asks');
      final urlA = await store.resolve(refA);
      expect(urlA, startsWith('blob:'));
      expect(urls.live[urlA]!.length, 40);
      expect(await store.resolve(refA), urlA, reason: 'one URL per item');

      store.release(refA);
      expect(urls.revoked, [urlA]);
      final again = await store.resolve(refA);
      expect(again, isNot(urlA), reason: 'a fresh URL after a release');

      final refB = await _put(store, b);
      final urlB = await store.resolve(refB);
      await store.remove(refB);
      expect(urls.revoked, contains(urlB));
      expect(await store.resolve(refB), isNull);

      final refC = await _put(store, c);
      await _put(store, b);
      await store.lookup(c);
      await store.lookup(b);
      // a is the oldest: evicting it revokes its URL with it.
      expect(await store.evict(keep: const []), {refA});
      expect(urls.revoked, contains(again));
      expect(await store.resolve(refA), isNull);

      final urlC = await store.resolve(refC);
      await store.dispose();
      expect(urls.revoked, contains(urlC));
      expect(urls.live, isEmpty);
    });

    test('a re-stored item replaces its old body and URL', () async {
      final store = JamMemoryMediaStore(maxBytes: 1000, blobUrls: urls);
      final a = _item('a', 10);
      final ref = await _put(store, a);
      final url = await store.resolve(ref);
      await _put(store, a);
      expect(urls.revoked, [url]);
      expect(store.totalBytes, 10);
    });
  });

  group('JamGuestEngine on the memory store (§3.1 browser readiness)', () {
    setUpAll(() => HttpOverrides.global = null);
    setUp(() => SharedPreferences.setMockInitialValues({}));

    Future<(JamHostServer, MediaItem)> hostWith(
      List<(int seed, String mime)> tracks,
    ) async {
      final host = JamHostServer(sessionName: 'Web', policy: JamPolicy.open);
      await host.start(address: InternetAddress.loopbackIPv4);
      addTearDown(host.close);
      MediaItem? first;
      for (final (seed, mime) in tracks) {
        final file = await writeTempMedia(
          makeMediaBytes(4096, seed: seed),
          name: 'track$seed.${mime == 'audio/ogg' ? 'ogg' : 'mp3'}',
        );
        final item = await JamHostServer.describeFile(
          file,
          kind: MediaKind.audio,
          mime: mime,
          durationUs: 10_000_000,
        );
        host.addMedia(item, file);
        first ??= item;
      }
      return (host, first!);
    }

    /// The audio channel, with `probeDuration` held until [gate] completes
    /// and failing (null) for Ogg, as Safari's `decodeAudioData` does.
    List<String> mockProbes({Completer<void>? gate}) {
      final probes = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(audioChannel, (call) async {
            switch (call.method) {
              case 'probeDuration':
                final path = (call.arguments as Map)['path'] as String;
                probes.add(path);
                await gate?.future;
                return path.endsWith('audio/ogg') ? null : 10_000_000;
              case 'nowUs':
                return 1;
              case 'load':
                return 10_000_000;
              case 'outputLatencyUs':
                return 0;
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(audioChannel, null),
      );
      return probes;
    }

    test('ready is reported only after the bytes decode', () async {
      final gate = Completer<void>();
      final probes = mockProbes(gate: gate);
      final (host, item) = await hostWith([(1, 'audio/mpeg')]);
      final urls = RecordingBlobUrls();
      final store = JamMemoryMediaStore(blobUrls: urls);
      final engine = await JamGuestEngine.join(
        host.joinUriFor(InternetAddress.loopbackIPv4),
        clientName: 'browser',
        clientKind: 'web',
        mediaStore: store,
      );
      addTearDown(engine.close);

      await waitFor(() => probes.isNotEmpty, reason: 'the decode probe');
      expect(probes.single, startsWith('blob:'));
      final probing = engine.prefetchStates.value[item.mediaId]!;
      expect(probing.phase, JamPrefetchPhase.fetching);
      expect(probing.progress, 1.0);
      expect(probing.ready, isFalse);
      // Every byte arrived and verified, yet the host has not heard `ready`.
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(
        host.peerMediaState(engine.selfPeerId, item.mediaId),
        MediaReadiness.fetching,
      );

      gate.complete();
      await waitFor(
        () => engine.prefetchStates.value[item.mediaId]?.ready ?? false,
        reason: 'ready after the probe',
      );
      await waitFor(
        () =>
            host.peerMediaState(engine.selfPeerId, item.mediaId) ==
            MediaReadiness.ready,
        reason: 'the host to hear ready',
      );
      // The probe's URL is let go (nothing is current): only `load` keeps
      // one.
      expect(engine.snapshot.mediaId, isNull);
      expect(urls.revoked, [probes.single]);
      expect(urls.live, isEmpty);
    });

    test('the current track keeps its probed URL for load; the next one '
        'lets it go', () async {
      final probes = mockProbes();
      final (host, first) = await hostWith([
        (4, 'audio/mpeg'),
        (5, 'audio/mpeg'),
      ]);
      final second = host.playlist[1];
      host.setMedia(first.mediaId);
      final urls = RecordingBlobUrls();
      final engine = await JamGuestEngine.join(
        host.joinUriFor(InternetAddress.loopbackIPv4),
        clientName: 'browser',
        clientKind: 'web',
        mediaStore: JamMemoryMediaStore(blobUrls: urls),
        prefetchPolicy: const JamPrefetchPolicy(aheadCount: 1),
      );
      addTearDown(engine.close);
      await waitFor(
        () => engine.prefetchStates.value[second.mediaId]?.ready ?? false,
        reason: 'the next item to get ready',
      );
      expect(engine.snapshot.mediaId, first.mediaId);
      expect(probes, hasLength(2));
      expect(urls.revoked, [probes.last]);
      expect(urls.live.keys, [probes.first]);
    });

    test('an item that will not decode is unplayable, reported none, '
        'dropped, and the next item still gets ready', () async {
      final probes = mockProbes();
      final (host, ogg) = await hostWith([(2, 'audio/ogg'), (3, 'audio/mpeg')]);
      final mp3 = host.playlist[1];
      final store = JamMemoryMediaStore(blobUrls: RecordingBlobUrls());
      final engine = await JamGuestEngine.join(
        host.joinUriFor(InternetAddress.loopbackIPv4),
        clientName: 'safari',
        clientKind: 'web',
        mediaStore: store,
        prefetchPolicy: const JamPrefetchPolicy(aheadCount: 1),
      );
      addTearDown(engine.close);

      await waitFor(
        () =>
            engine.prefetchStates.value[ogg.mediaId]?.phase ==
            JamPrefetchPhase.unplayable,
        reason: 'the Ogg item to be unplayable',
      );
      await waitFor(
        () => engine.prefetchStates.value[mp3.mediaId]?.ready ?? false,
        reason: 'the next item to get ready',
      );
      // What the guest reports reaches the host a moment later, so a busy
      // machine must not fail on a report still in flight.
      await waitFor(
        () => host.allPeersReady(mp3.mediaId),
        reason: 'the host to hear the next item ready',
      );
      await waitFor(
        () =>
            host.peerMediaState(engine.selfPeerId, ogg.mediaId) ==
            MediaReadiness.none,
        reason: 'the host to hear the Ogg item is not coming',
      );
      expect(await store.lookup(ogg), isNull, reason: 'its bytes are dropped');
      expect(engine.retryFetch(ogg.mediaId), isFalse);

      // It stays unplayable through re-plans, and is never fetched again.
      final probesBefore = probes.length;
      final extra = await writeTempMedia(makeMediaBytes(512, seed: 9));
      host.addMedia(
        await JamHostServer.describeFile(
          extra,
          kind: MediaKind.audio,
          mime: 'audio/mpeg',
        ),
        extra,
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(
        engine.prefetchStates.value[ogg.mediaId]?.phase,
        JamPrefetchPhase.unplayable,
      );
      expect(
        probes.skip(probesBefore).where((p) => p.endsWith('audio/ogg')),
        isEmpty,
      );
    });

    /// The audio channel with `probeDuration` answered by [probe], every
    /// call's arguments recorded.
    List<Map<Object?, Object?>> mockProbeWith(
      Future<Object?> Function(Map<Object?, Object?> args, int call) probe,
    ) {
      final calls = <Map<Object?, Object?>>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(audioChannel, (call) async {
            switch (call.method) {
              case 'probeDuration':
                final args = call.arguments as Map<Object?, Object?>;
                calls.add(args);
                return probe(args, calls.length);
              case 'nowUs':
                return 1;
              case 'load':
                return 10_000_000;
              case 'outputLatencyUs':
                return 0;
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(audioChannel, null),
      );
      return calls;
    }

    JamBackoff fastRetry() => JamBackoff(
      initialDelay: const Duration(milliseconds: 50),
      maxDelay: const Duration(milliseconds: 100),
      jitterRatio: 0,
    );

    test('a probe that fails for a reason other than the format is retried, '
        'not unplayable, and the room does not wait on it', () async {
      // The first check fails the way a context closed under the decode
      // does; the second one decodes.
      final calls = mockProbeWith((args, call) async {
        if (call == 1) {
          throw PlatformException(code: 'engine_error', message: 'closed');
        }
        return 10_000_000;
      });
      final (host, item) = await hostWith([(6, 'audio/mpeg')]);
      final engine = await JamGuestEngine.join(
        host.joinUriFor(InternetAddress.loopbackIPv4),
        clientName: 'browser',
        clientKind: 'web',
        mediaStore: JamMemoryMediaStore(blobUrls: RecordingBlobUrls()),
        fetchRetryBackoff: fastRetry(),
      );
      addTearDown(engine.close);

      final seen = <JamPrefetchPhase>[];
      engine.prefetchStates.addListener(() {
        final phase = engine.prefetchStates.value[item.mediaId]?.phase;
        if (phase != null && (seen.isEmpty || seen.last != phase)) {
          seen.add(phase);
        }
      });
      await waitFor(
        () => engine.prefetchStates.value[item.mediaId]?.ready ?? false,
        reason: 'ready after the retried check',
      );
      expect(calls, hasLength(2));
      expect(seen, contains(JamPrefetchPhase.failed));
      expect(seen, isNot(contains(JamPrefetchPhase.unplayable)));
      await waitFor(
        () =>
            host.peerMediaState(engine.selfPeerId, item.mediaId) ==
            MediaReadiness.ready,
        reason: 'the host to hear ready',
      );
    });

    test('a probe that never answers times out into a bounded retry instead '
        'of stalling the pipeline', () async {
      final calls = mockProbeWith((args, call) {
        final path = args['path']! as String;
        // The first track's decode hangs, every time.
        if (path.contains('#audio/ogg')) return Completer<Object?>().future;
        return Future<Object?>.value(10_000_000);
      });
      final (host, hung) = await hostWith([
        (7, 'audio/ogg'),
        (8, 'audio/mpeg'),
      ]);
      final next = host.playlist[1];
      final engine = await JamGuestEngine.join(
        host.joinUriFor(InternetAddress.loopbackIPv4),
        clientName: 'browser',
        clientKind: 'web',
        mediaStore: JamMemoryMediaStore(blobUrls: RecordingBlobUrls()),
        prefetchPolicy: const JamPrefetchPolicy(aheadCount: 1),
        fetchRetryBackoff: fastRetry(),
        maxFetchRetries: 2,
        decodeProbeTimeout: const Duration(milliseconds: 100),
      );
      addTearDown(engine.close);

      // The next item is not stuck behind the hung one.
      await waitFor(
        () => engine.prefetchStates.value[next.mediaId]?.ready ?? false,
        reason: 'the next item to get ready',
      );
      // The hung one runs out of retries: failed, never unplayable.
      await waitFor(() {
        final state = engine.prefetchStates.value[hung.mediaId];
        return state?.phase == JamPrefetchPhase.failed && !state!.willRetry;
      }, reason: 'the retries to run out');
      final hungChecks = calls.where(
        (c) => (c['path']! as String).contains('#audio/ogg'),
      );
      expect(hungChecks, hasLength(3), reason: 'first check + 2 retries');
      await waitFor(
        () =>
            host.peerMediaState(engine.selfPeerId, hung.mediaId) ==
            MediaReadiness.none,
        reason: 'the host to hear the hung item is not coming',
      );
      // Its bytes are kept, and a manual retry checks them again.
      expect(engine.retryFetch(hung.mediaId), isTrue);
    });

    test('the current track\'s probe keeps its decode for load; the next '
        'track\'s does not', () async {
      final calls = mockProbeWith((args, call) async => 10_000_000);
      final (host, first) = await hostWith([
        (10, 'audio/mpeg'),
        (11, 'audio/mpeg'),
      ]);
      final second = host.playlist[1];
      host.setMedia(first.mediaId);
      final engine = await JamGuestEngine.join(
        host.joinUriFor(InternetAddress.loopbackIPv4),
        clientName: 'browser',
        clientKind: 'web',
        mediaStore: JamMemoryMediaStore(blobUrls: RecordingBlobUrls()),
        prefetchPolicy: const JamPrefetchPolicy(aheadCount: 1),
      );
      addTearDown(engine.close);
      await waitFor(
        () => engine.prefetchStates.value[second.mediaId]?.ready ?? false,
        reason: 'both items ready',
      );
      expect(calls, hasLength(2));
      expect(calls[0]['keep'], isTrue, reason: 'the current track');
      expect(calls[1].containsKey('keep'), isFalse, reason: 'the next one');
    });

    test('an item bigger than the budget or longer than a tab can decode is '
        'unplayable without being fetched', () async {
      final calls = mockProbeWith((args, call) async => 10_000_000);
      final host = JamHostServer(sessionName: 'Web', policy: JamPolicy.open);
      await host.start(address: InternetAddress.loopbackIPv4);
      addTearDown(host.close);
      Future<MediaItem> add(int seed, int size, int durationUs) async {
        final file = await writeTempMedia(
          makeMediaBytes(size, seed: seed),
          name: 'track$seed.mp3',
        );
        final item = await JamHostServer.describeFile(
          file,
          kind: MediaKind.audio,
          mime: 'audio/mpeg',
          durationUs: durationUs,
        );
        host.addMedia(item, file);
        return item;
      }

      final big = await add(12, 8192, 10_000_000);
      final long = await add(13, 1024, JamMemoryMediaStore.maxDecodeUs + 1);
      final fine = await add(14, 1024, 10_000_000);
      final store = JamMemoryMediaStore(
        maxBytes: 4096,
        blobUrls: RecordingBlobUrls(),
      );
      final engine = await JamGuestEngine.join(
        host.joinUriFor(InternetAddress.loopbackIPv4),
        clientName: 'browser',
        clientKind: 'web',
        mediaStore: store,
        prefetchPolicy: const JamPrefetchPolicy(prefetchAll: true),
      );
      addTearDown(engine.close);
      await waitFor(
        () => engine.prefetchStates.value[fine.mediaId]?.ready ?? false,
        reason: 'the item that fits to get ready',
      );
      final states = engine.prefetchStates.value;
      expect(states[big.mediaId]?.phase, JamPrefetchPhase.unplayable);
      expect(states[big.mediaId]?.error, JamMediaStore.tooLarge);
      expect(states[long.mediaId]?.phase, JamPrefetchPhase.unplayable);
      expect(states[long.mediaId]?.error, JamMediaStore.tooLong);
      // Never fetched: the host never heard of them, the store holds none.
      for (final refused in [big, long]) {
        expect(
          host.peerMediaState(engine.selfPeerId, refused.mediaId),
          MediaReadiness.none,
        );
        expect(await store.lookup(refused), isNull);
      }
      expect(calls, hasLength(1));
      expect(engine.retryFetch(big.mediaId), isFalse);
      expect(store.refuses(fine), isNull);
    });

    test('a track removed from the playlist while current lets go of its '
        'blob URL', () async {
      mockProbeWith((args, call) async => 10_000_000);
      final (host, first) = await hostWith([
        (15, 'audio/mpeg'),
        (16, 'audio/mpeg'),
      ]);
      final second = host.playlist[1];
      host.setMedia(first.mediaId);
      final urls = RecordingBlobUrls();
      final engine = await JamGuestEngine.join(
        host.joinUriFor(InternetAddress.loopbackIPv4),
        clientName: 'browser',
        clientKind: 'web',
        mediaStore: JamMemoryMediaStore(blobUrls: urls),
        prefetchPolicy: const JamPrefetchPolicy(aheadCount: 1),
      );
      addTearDown(engine.close);
      await waitFor(
        () => engine.prefetchStates.value[second.mediaId]?.ready ?? false,
        reason: 'both items ready',
      );
      expect(urls.live, hasLength(1), reason: "the current track's URL");
      final currentUrl = urls.live.keys.single;

      host.removeMediaItem(first.mediaId);
      await waitFor(
        () => !urls.live.containsKey(currentUrl),
        reason: "the removed track's URL to be revoked",
      );
    });
  });
}
