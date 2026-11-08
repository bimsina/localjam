/// The host's library as a catalog (PROTOCOL.md §6.6) through the engines:
/// a [JamHostEngine] sharing a [JamCatalogSource] (a temp dir of generated
/// media, [FakeCatalogSource]) and a real loopback [JamGuestEngine] that
/// browses it, asks for covers and adds songs; plus the Android library
/// source's mapping, which has no Android to run against here.
library;

import 'dart:async';
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

  Future<JamHostEngine> startHost({
    JamPolicy policy = JamPolicy.jam,
    int maxPlaylistLength = JamHostServer.defaultMaxPlaylistLength,
  }) async {
    final host = await JamHostEngine.start(
      sessionName: 'CatalogJam',
      hostName: 'Silky Puffin',
      address: InternetAddress.loopbackIPv4,
      discoverable: false,
      policy: policy,
      maxPlaylistLength: maxPlaylistLength,
    );
    addTearDown(host.close);
    return host;
  }

  Future<JamGuestEngine> joinGuest(
    JamHostEngine host, {
    String clientId = 'c_browser',
  }) async {
    final guest = await JamGuestEngine.join(
      host.joinUriFor(InternetAddress.loopbackIPv4),
      clientName: 'browser',
      clientId: clientId,
      mediaCacheDir: await makeTempDir(),
    );
    addTearDown(guest.close);
    return guest;
  }

  /// A library of [count] untagged songs (distinct bytes), plus their ids.
  Future<(FakeCatalogSource, List<String>)> library(
    int count, {
    int seed = 500,
    String ext = 'mp3',
  }) async {
    final source = FakeCatalogSource();
    final ids = <String>[];
    for (var i = 0; i < count; i++) {
      final file = await writeTempMedia(
        makeMediaBytes(4096, seed: seed + i),
        name: 'song_$i.$ext',
      );
      ids.add(
        source.add(
          file,
          title: 'Song $i',
          artist: 'Artist $i',
          album: 'Album',
          durationUs: 99_000_000,
        ),
      );
    }
    return (source, ids);
  }

  group('JamHostEngine.shareCatalog + JamGuestEngine', () {
    test('a guest browses and adds: the item is credited to the guest, '
        'the host plays it from the library file and serves it', () async {
      final log = mockAudioChannel(durationUs: 42_000_000);
      final host = await startHost();
      final (source, ids) = await library(2, ext: 'flac');
      final tagged = await makeTaggedMp3();
      final taggedId = source.add(tagged, title: 'tagged.mp3');

      final adds = <JamCatalogAdd>[];
      host.catalogAdds.listen(adds.add);
      expect(host.catalog.value, isNull, reason: 'off by default');

      await host.shareCatalog(source);
      expect(host.catalog.value, isNotNull);
      expect(host.catalog.value!.count, 3);
      expect(host.catalogEntries.map((e) => e.catalogId), [...ids, taggedId]);
      expect(source.opens, isEmpty, reason: 'nothing opened to list');

      final guest = await joinGuest(host);
      expect(
        guest.catalog.value,
        host.catalog.value,
        reason: 'welcome.catalog carries the summary',
      );
      final entries = await guest.fetchCatalog();
      expect(entries.map((e) => e.catalogId), [...ids, taggedId]);
      expect(entries.first.title, 'Song 0');
      expect(entries.first.artist, 'Artist 0');
      expect(entries.first.durationUs, 99_000_000);

      expect(await guest.requestCatalogAdd([ids[0], taggedId]), isTrue);
      await waitFor(
        () => host.playlist.length == 2 && guest.playlist.length == 2,
        reason: 'both catalog adds to land everywhere',
      );
      final untagged = host.playlist[0];
      final fromTags = host.playlist[1];
      for (final item in host.playlist) {
        expect(item.addedBy, guest.selfPeerId, reason: 'the requester');
      }
      // The engine's probe and MIME mapping, as for the host's own files.
      expect(untagged.durationUs, 42_000_000, reason: 'probed natively');
      expect(untagged.mime, 'audio/flac');
      expect(fromTags.mime, 'audio/mpeg');
      // No tags: the row the guest picked; tags: the file's own.
      expect(untagged.title, 'Song 0');
      expect(untagged.artist, 'Artist 0');
      expect(fromTags.title, 'Night Drive');
      expect(fromTags.artworkId, isNotNull);
      // Each names the row it came from, on the guest too (§6.1 catalogId),
      // so a browse sheet can mark those rows as queued.
      expect(untagged.catalogId, ids[0]);
      expect(fromTags.catalogId, taggedId);
      expect(guest.playlist.map((i) => i.catalogId), [ids[0], taggedId]);

      await waitFor(() => adds.length == 2, reason: 'catalogAdds events');
      expect(adds[0].peerId, guest.selfPeerId);
      expect(adds[0].byHost, isFalse);
      expect(adds[0].catalogId, ids[0]);
      expect(adds[0].mediaId, untagged.mediaId);
      expect(adds[0].entry?.title, 'Song 0');
      expect(adds[1].catalogId, taggedId);

      // The host's own copy is the library file — what it plays and what
      // jam history may replay.
      expect(host.localPathFor(untagged), source.fileOf(ids[0]).path);

      // Served to the room like any item (§6.2).
      await waitFor(
        () => guest.prefetchStates.value[untagged.mediaId]?.ready ?? false,
        reason: 'guest fetched the catalog-added item',
      );
      expect(
        await File(
          guest.prefetchStates.value[untagged.mediaId]!.path!,
        ).readAsBytes(),
        await source.fileOf(ids[0]).readAsBytes(),
      );

      // And the host's player plays it from the library file.
      host.setMedia(untagged.mediaId);
      host.play();
      await waitFor(
        () => log.any(
          (c) =>
              c.method == 'load' &&
              (c.arguments as Map)['path'] == source.fileOf(ids[0]).path,
        ),
        timeout: const Duration(seconds: 10),
        reason: 'host loads the library file',
      );
    });

    test('the host adds from its own library: credited to the host, '
        'idempotent, and null for what cannot be added', () async {
      mockAudioChannel();
      final host = await startHost();
      final (source, ids) = await library(2);
      final adds = <JamCatalogAdd>[];
      host.catalogAdds.listen(adds.add);

      expect(
        await host.addFromCatalog(ids[0]),
        isNull,
        reason: 'nothing shared yet',
      );
      await host.shareCatalog(source);

      final first = await host.addFromCatalog(ids[0]);
      expect(first, isNotNull);
      expect(first!.outcome, JamAddOutcome.added);
      expect(first.item.addedBy, JamPermissions.hostPeerId);
      expect(first.item.catalogId, ids[0]);
      expect(host.playlist.map((i) => i.mediaId), [first.item.mediaId]);
      expect(host.localPathFor(first.item), source.fileOf(ids[0]).path);
      await waitFor(() => adds.isNotEmpty, reason: 'catalogAdds event');
      expect(adds.single.byHost, isTrue);
      expect(adds.single.mediaId, first.item.mediaId);

      final again = await host.addFromCatalog(ids[0]);
      expect(again!.outcome, JamAddOutcome.alreadyQueued);
      expect(again.alreadyQueued, isTrue);
      expect(host.playlist, hasLength(1));

      expect(await host.addFromCatalog('c_nope'), isNull);

      // A song deleted from the device since the listing.
      await source.fileOf(ids[1]).delete();
      expect(await host.addFromCatalog(ids[1]), isNull);

      await host.shareCatalog(null);
      expect(host.catalog.value, isNull);
      expect(host.catalogEntries, isEmpty);
      expect(await host.addFromCatalog(ids[0]), isNull);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(adds, hasLength(1), reason: 'no event for a no-op');
    });

    test('a request past the queue cap is answered busy on errors, '
        'non-fatal; the ids that fit still land', () async {
      mockAudioChannel();
      final host = await startHost(maxPlaylistLength: 1);
      final (source, ids) = await library(3);
      await host.shareCatalog(source);
      final guest = await joinGuest(host);
      final errors = <ErrorMessage>[];
      guest.errors.listen(errors.add);

      expect(await guest.requestCatalogAdd(ids), isTrue);
      await waitFor(() => errors.isNotEmpty, reason: 'busy');
      expect(errors.single.code, ErrorCode.busy);
      expect(errors.single.fatal, isFalse);
      await waitFor(() => guest.playlist.length == 1, reason: 'one landed');
      expect(guest.playlist.single.title, 'Song 0');
      expect(guest.connectionState, JamConnectionState.connected);
    });

    test('a guest without add_tracks may browse but its add is refused '
        'with not_allowed', () async {
      mockAudioChannel();
      final host = await startHost(policy: JamPolicy.listenOnly);
      final (source, ids) = await library(1);
      await host.shareCatalog(source);
      final guest = await joinGuest(host);
      final errors = <ErrorMessage>[];
      guest.errors.listen(errors.add);

      expect(await guest.fetchCatalog(), hasLength(1));
      expect(guest.can(JamCapability.addTracks), isFalse);
      expect(await guest.requestCatalogAdd(ids), isTrue, reason: 'sent');
      await waitFor(() => errors.isNotEmpty, reason: 'not_allowed');
      expect(errors.single.code, ErrorCode.notAllowed);
      expect(host.playlist, isEmpty);
      expect(source.opens, isEmpty);
    });

    test('a refresh republishes under a new rev; stopping drops the '
        "guest's catalog; a failed listing leaves it as it was", () async {
      mockAudioChannel();
      final host = await startHost();
      final (source, ids) = await library(2);
      await host.shareCatalog(source);
      final guest = await joinGuest(host);
      final firstRev = guest.catalog.value!.rev;
      expect(await guest.fetchCatalog(), hasLength(2));
      expect(await guest.requestCatalogAdd([]), isFalse, reason: 'no ids');

      final newFile = await writeTempMedia(
        makeMediaBytes(4096, seed: 9),
        name: 'new.mp3',
      );
      final newId = source.add(newFile, title: 'Fresh');
      source.remove(ids[0]);
      await host.shareCatalog(source);
      await waitFor(
        () => (guest.catalog.value?.rev ?? 0) > firstRev,
        reason: 'the new rev',
      );
      expect(guest.catalog.value!.count, 2);
      expect((await guest.fetchCatalog()).map((e) => e.catalogId), [
        ids[1],
        newId,
      ]);

      // A listing that throws (a revoked permission) changes nothing.
      final revBefore = host.catalog.value!.rev;
      source.failList = StateError('permission revoked');
      await expectLater(host.shareCatalog(source), throwsStateError);
      expect(host.catalog.value!.rev, revBefore);

      await host.shareCatalog(null);
      await waitFor(() => guest.catalog.value == null, reason: 'catalog off');
      expect(await guest.fetchCatalog(), isEmpty);

      // An empty library is shared, but there is nothing to browse.
      await host.shareCatalog(FakeCatalogSource());
      expect(host.catalog.value, isNotNull);
      expect(host.catalog.value!.isOffered, isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(guest.catalog.value, isNull);
    });

    test('a share overtaken while listing changes nothing', () async {
      mockAudioChannel();
      final host = await startHost();
      final slow = _GatedSource();
      final pending = host.shareCatalog(slow);
      await host.shareCatalog(null);
      slow.gate.complete();
      await pending;
      expect(host.catalog.value, isNull);
    });

    test(
      'a selection past the per-call cap is sent capped and says so; '
      'the rest, asked for while those are landing, is answered busy',
      () async {
        mockAudioChannel();
        final host = await startHost();
        final (source, ids) = await library(55);
        source.openGate = Completer<void>(); // Nothing lands until released.
        await host.shareCatalog(source);
        final guest = await joinGuest(host);
        final errors = <ErrorMessage>[];
        guest.errors.listen(errors.add);
        expect(JamGuestEngine.maxCatalogAddsPerCall, 50);

        final first = await guest.requestCatalogAddCounted([...ids, ids[0]]);
        expect(first.delivered, isTrue);
        expect(first.sent, 50);
        expect(first.dropped, 5, reason: 'the repeat is not counted');

        // This device's share is full until those land.
        final rest = await guest.requestCatalogAddCounted(ids.sublist(50));
        expect(rest.sent, 5);
        expect(rest.dropped, 0);
        await waitFor(() => errors.isNotEmpty, reason: 'busy for the rest');
        expect(errors.single.code, ErrorCode.busy);
        expect(errors.single.fatal, isFalse);

        source.openGate!.complete();
        await waitFor(
          () => host.playlist.length == 50,
          timeout: const Duration(seconds: 30),
          reason: 'the 50 sent',
        );
        expect(host.playlist.map((i) => i.title), [
          for (var i = 0; i < 50; i++) 'Song $i',
        ], reason: 'in the order asked');
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(host.playlist, hasLength(50));
        expect(guest.connectionState, JamConnectionState.connected);

        // Once landed there is room again: the rest goes in.
        expect(await guest.requestCatalogAdd(ids.sublist(50)), isTrue);
        await waitFor(
          () => host.playlist.length == 55,
          timeout: const Duration(seconds: 10),
          reason: 'the rest',
        );
        expect(
          await guest.requestCatalogAddCounted(const []),
          isA<JamCatalogAddRequest>().having(
            (r) => r.delivered,
            'delivered',
            false,
          ),
        );
      },
    );

    test('a cover the host is too busy to read (503) is not remembered as '
        'none: the next call fetches it', () async {
      mockAudioChannel();
      final host = await startHost();
      final source = FakeCatalogSource()..artGate = Completer<void>();
      final cover = await makeTaggedMp3();
      // 4 guests × 6 connections each = 24 distinct cover reads at once:
      // 3 reading, 16 waiting, the rest 503 (§6.6, §9.1).
      final ids = [
        for (var i = 0; i < 24; i++) source.add(cover, title: 'S$i'),
      ];
      await host.shareCatalog(source);
      final guests = [
        for (var g = 0; g < 4; g++) await joinGuest(host, clientId: 'c_g$g'),
      ];
      final listings = [for (final g in guests) await g.fetchCatalog()];
      final byId = {for (final e in listings.first) e.catalogId: e};

      final firstRound = <Future<Uint8List?>>[
        for (var g = 0; g < 4; g++)
          for (var i = 0; i < 6; i++)
            guests[g].catalogArtworkFor(byId[ids[g * 6 + i]]!),
      ];
      // Let every request reach the host before the reads are released.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      source.artGate!.complete();
      final results = await Future.wait(firstRound);
      final refused = [
        for (var k = 0; k < results.length; k++)
          if (results[k] == null) k,
      ];
      expect(refused, isNotEmpty, reason: 'some reads were answered 503');
      for (final k in refused) {
        final again = await guests[k ~/ 6].catalogArtworkFor(byId[ids[k]]!);
        expect(again, tinyPngBytes, reason: 'retried, not cached as none');
      }
    });

    test('catalog covers: fetched on demand, memoised, skipped for '
        'hasArtwork false, dropped on a new rev', () async {
      mockAudioChannel();
      final host = await startHost();
      final source = FakeCatalogSource();
      final coverId = source.add(await makeTaggedMp3(), title: 'Cover');
      final plainId = source.add(
        await writeTempMedia(makeMediaBytes(2048), name: 'plain.mp3'),
      );
      final noneId = source.add(
        await writeTempMedia(makeMediaBytes(2048, seed: 3), name: 'x.mp3'),
        hasArtwork: false,
      );
      await host.shareCatalog(source);
      final guest = await joinGuest(host);
      final entries = {
        for (final e in await guest.fetchCatalog()) e.catalogId: e,
      };

      final first = guest.catalogArtworkFor(entries[coverId]!);
      expect(
        identical(guest.catalogArtworkFor(entries[coverId]!), first),
        isTrue,
        reason: 'one fetch for concurrent callers',
      );
      expect(await first, tinyPngBytes);
      expect(source.opens[coverId], 1, reason: 'read from the file once');
      expect(await guest.catalogArtworkFor(entries[coverId]!), tinyPngBytes);
      expect(source.opens[coverId], 1, reason: 'memoised');

      expect(await guest.catalogArtworkFor(entries[plainId]!), isNull);
      expect(await guest.catalogArtworkFor(entries[noneId]!), isNull);
      expect(source.opens[noneId], isNull, reason: 'never asked for');

      // An unchanged refresh is a no-op for the room: same rev, same memo.
      final rev = guest.catalog.value!.rev;
      await host.shareCatalog(source);
      expect(host.catalog.value!.rev, rev);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(guest.catalog.value!.rev, rev);
      expect(
        identical(guest.catalogArtworkFor(entries[coverId]!), first),
        isTrue,
      );

      // A changed listing is a new rev: covers are asked for again.
      source.add(
        await writeTempMedia(makeMediaBytes(2048, seed: 4), name: 'new.mp3'),
        title: 'New',
      );
      await host.shareCatalog(source);
      await waitFor(() => guest.catalog.value!.rev > rev, reason: 'new rev');
      final after = guest.catalogArtworkFor(entries[coverId]!);
      expect(identical(after, first), isFalse);
      expect(await after, tinyPngBytes);
    });

    test('a closed guest cannot browse', () async {
      mockAudioChannel();
      final host = await startHost();
      final (source, ids) = await library(1);
      await host.shareCatalog(source);
      final guest = await joinGuest(host);
      final entry = (await guest.fetchCatalog()).single;
      await guest.close();
      await expectLater(
        guest.fetchCatalog(),
        throwsA(isA<JamNotConnectedException>()),
      );
      expect(await guest.requestCatalogAdd(ids), isFalse);
      expect(await guest.catalogArtworkFor(entry), isNull);
    });

    test('closing the host ends the catalog', () async {
      mockAudioChannel();
      final host = await JamHostEngine.start(
        sessionName: 'Closing',
        address: InternetAddress.loopbackIPv4,
        discoverable: false,
      );
      final (source, ids) = await library(1);
      await host.shareCatalog(source);
      final done = expectLater(host.catalogAdds, emitsDone);
      await host.close();
      await done;
      expect(await host.addFromCatalog(ids[0]), isNull);
      await host.shareCatalog(source); // A no-op, not a throw.
    });
  });

  group('JamMediaLibraryCatalogSource', () {
    JamLibraryTrack track(
      int id, {
      String title = 'Song',
      String? artist = 'Artist',
      String? album = 'Album',
      int? durationMs = 215_000,
      int sizeBytes = 5_000_000,
      String? path,
    }) => JamLibraryTrack(
      id: id,
      title: title,
      artist: artist,
      album: album,
      durationMs: durationMs,
      sizeBytes: sizeBytes,
      contentUri: 'content://media/external/audio/media/$id',
      path: path,
    );

    test('maps a library track to a catalog entry', () {
      final entry = JamMediaLibraryCatalogSource.entryFor(track(1234));
      expect(entry.catalogId, 'c_1234');
      expect(entry.title, 'Song');
      expect(entry.artist, 'Artist');
      expect(entry.album, 'Album');
      expect(entry.durationUs, 215_000_000, reason: 'ms → µs');
      expect(entry.sizeBytes, 5_000_000);
      expect(entry.hasArtwork, isNull, reason: 'unknown until asked');

      final bare = JamMediaLibraryCatalogSource.entryFor(
        track(7, artist: '<unknown>', album: '  ', durationMs: 0, sizeBytes: 0),
      );
      expect(bare.catalogId, 'c_7');
      expect(bare.artist, isNull, reason: "MediaStore's placeholder");
      expect(bare.album, isNull);
      expect(bare.durationUs, isNull);
      expect(bare.sizeBytes, isNull);
      expect(
        JamMediaLibraryCatalogSource.entryFor(
          track(8, durationMs: null),
        ).durationUs,
        isNull,
      );
    });

    test('cleans up library metadata the way the host reads tags', () {
      final multi = JamMediaLibraryCatalogSource.entryFor(
        track(
          1,
          title: 'Kun Faya Kun',
          artist: 'A.R. Rahman/Javed Ali/Mohit Chauhan',
          album: 'Rockstar',
          path: '/storage/emulated/0/Music/Rockstar/04 Kun Faya Kun.mp3',
        ),
      );
      expect(multi.artist, 'A.R. Rahman, Javed Ali, Mohit Chauhan');
      expect(
        multi.album,
        'Rockstar',
        reason: 'a tagged album that names its folder is still the album',
      );

      // An untagged file: MediaStore titles it after the file and albums it
      // after the folder.
      final untagged = JamMediaLibraryCatalogSource.entryFor(
        track(
          2,
          title: 'voice memo.mp3',
          artist: '<unknown>',
          album: 'Music',
          path: '/storage/emulated/0/Music/voice memo.mp3',
        ),
      );
      expect(untagged.title, 'voice memo');
      expect(untagged.artist, isNull);
      expect(untagged.album, isNull, reason: "the folder's name, not an album");

      final blank = JamMediaLibraryCatalogSource.entryFor(
        track(3, title: '  ', path: '/sdcard/Music/Night Drive.flac'),
      );
      expect(blank.title, 'Night Drive');
      expect(
        JamMediaLibraryCatalogSource.entryFor(track(4, title: 'Vol. 2')).title,
        'Vol. 2',
      );
    });

    test('lists through the query and opens through resolve, once per '
        'song', () async {
      final dir = await makeTempDir();
      final a = File('${dir.path}/a.mp3')..writeAsBytesSync([1, 2, 3]);
      final cacheCopy = File('${dir.path}/copy_2.mp3');
      final resolves = <int>[];
      final source = JamMediaLibraryCatalogSource(
        query: () async => [
          track(1, title: 'A', path: a.path),
          track(2, title: 'B'),
          track(1, title: 'A again'), // The first of two wins.
          track(3, title: 'Broken'),
        ],
        resolve: (t) async {
          resolves.add(t.id);
          if (t.id == 3) throw PlatformException(code: 'io');
          if (t.id == 2) {
            // Scoped storage: a copy into the app's cache.
            cacheCopy.writeAsBytesSync([4, 5]);
            return cacheCopy.path;
          }
          return t.path;
        },
      );
      expect(await source.open('c_1'), isNull, reason: 'not listed yet');

      final entries = await source.list();
      expect(entries.map((e) => e.catalogId), ['c_1', 'c_2', 'c_3']);
      expect(entries.first.title, 'A');

      expect((await source.open('c_1'))!.path, a.path);
      expect((await source.open('c_2'))!.path, cacheCopy.path);
      expect((await source.open('c_2'))!.path, cacheCopy.path);
      expect(resolves.where((id) => id == 2), hasLength(1), reason: 'memo');
      expect(await source.open('c_3'), isNull, reason: 'unreadable');
      expect(await source.open('c_9'), isNull, reason: 'unknown');

      // The cache copy cleared: resolved (copied) again.
      cacheCopy.deleteSync();
      expect((await source.open('c_2'))!.path, cacheCopy.path);
      expect(resolves.where((id) => id == 2), hasLength(2));
    });

    test('covers are read only in place: never a cache copy', () async {
      final dir = await makeTempDir();
      final direct = File('${dir.path}/direct.mp3')..writeAsBytesSync([1]);
      final resolves = <int>[];
      final source = JamMediaLibraryCatalogSource(
        query: () async => [
          track(1, path: direct.path),
          track(2), // Scoped storage: no direct path.
          track(3, path: '${dir.path}/gone.mp3'),
        ],
        resolve: (t) async {
          resolves.add(t.id);
          return t.path;
        },
      );
      await source.list();
      expect((await source.openForArtwork('c_1'))!.path, direct.path);
      expect(await source.openForArtwork('c_2'), isNull);
      expect(await source.openForArtwork('c_3'), isNull);
      expect(await source.openForArtwork('c_9'), isNull);
      expect(resolves, isEmpty, reason: 'browsing copies nothing');
    });

    test('without a native library it lists nothing', () async {
      expect(await JamMediaLibraryCatalogSource().list(), isEmpty);
    });
  });
}

/// A source whose listing waits for [gate].
class _GatedSource extends JamCatalogSource {
  final Completer<void> gate = Completer<void>();

  @override
  Future<List<CatalogEntry>> list() async {
    await gate.future;
    return const [CatalogEntry(catalogId: 'c_1', title: 'Late')];
  }

  @override
  Future<File?> open(String catalogId) async => null;
}
