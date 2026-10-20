/// Jam history: the on-disk store, and end-to-end recording from live
/// engines via the session guards.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

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
    JamEngine.historyStoreProvider = JamHistoryStore.open;
  });

  JamHistoryRecord record({
    required String id,
    required DateTime updatedAt,
    List<JamHistoryTrack> tracks = const [],
    String? coverFile,
  }) => JamHistoryRecord(
    sessionId: id,
    sessionName: 'Jam $id',
    wasHost: true,
    startedAt: updatedAt,
    updatedAt: updatedAt,
    tracks: tracks,
    coverFile: coverFile,
  );

  group('JamHistoryStore', () {
    test(
      'round-trips records, lists newest first, prunes to maxRecords',
      () async {
        final store = JamHistoryStore(await makeTempDir(), maxRecords: 2);
        final t0 = DateTime(2026, 8, 1);
        await store.save(record(id: 's_a', updatedAt: t0));
        await store.save(
          record(id: 's_b', updatedAt: t0.add(const Duration(hours: 1))),
        );
        expect((await store.list()).map((r) => r.sessionId), ['s_b', 's_a']);

        // A third record evicts the oldest.
        await store.save(
          record(id: 's_c', updatedAt: t0.add(const Duration(hours: 2))),
        );
        expect((await store.list()).map((r) => r.sessionId), ['s_c', 's_b']);

        // Re-saving an existing session updates in place (no duplicate).
        await store.save(
          record(id: 's_c', updatedAt: t0.add(const Duration(hours: 3))),
        );
        expect(await store.list(), hasLength(2));

        await store.delete('s_c');
        expect((await store.list()).map((r) => r.sessionId), ['s_b']);
      },
    );

    test('corrupt files are skipped; tracks round-trip with attribution and '
        'replayability', () async {
      final dir = await makeTempDir();
      final store = JamHistoryStore(dir);
      final playable = await writeTempMedia(makeMediaBytes(512));
      const item = MediaItem(
        mediaId: 'm_1',
        kind: MediaKind.audio,
        name: 'a.mp3',
        mime: 'audio/mpeg',
        sizeBytes: 512,
        sha256: 'aa',
        title: 'Night Drive',
        artist: 'The Localhosts',
        addedBy: 'p_2',
      );
      await store.save(
        record(
          id: 's_x',
          updatedAt: DateTime(2026, 8, 2),
          tracks: [
            JamHistoryTrack(
              item: item,
              addedByName: 'Funky Walrus',
              localPath: playable.path,
            ),
            const JamHistoryTrack(item: item, localPath: '/gone/nope.mp3'),
          ],
        ),
      );
      await File('${dir.path}/garbage.json').writeAsString('{nope');

      final records = await store.list();
      expect(records, hasLength(1));
      final loaded = records.single;
      expect(loaded.tracks, hasLength(2));
      expect(loaded.tracks.first.item, item);
      expect(loaded.tracks.first.addedByName, 'Funky Walrus');
      expect(loaded.tracks.first.existsLocally, isTrue);
      expect(loaded.tracks.last.existsLocally, isFalse);
      expect(loaded.replayableTracks, hasLength(1));
    });
  });

  group('JamHistoryRecorder (via session guards)', () {
    test('a hosted session lands in the store with tracks, attribution, '
        'paths, and peer names', () async {
      mockAudioChannel();
      final store = JamHistoryStore(await makeTempDir());
      JamEngine.historyStoreProvider = () async => store;

      final engine = await JamHostEngine.start(
        sessionName: 'HistoryJam',
        hostName: 'Silky Puffin',
        address: InternetAddress.loopbackIPv4,
        discoverable: false,
      );
      final item = await engine.addMediaFile(await makeTaggedMp3());
      final guest = await JamGuestClient.connect(
        engine.joinUriFor(InternetAddress.loopbackIPv4),
        clientName: 'Funky Walrus',
      );
      await waitFor(() => engine.peers.isNotEmpty, reason: 'guest to join');
      // Nudge the recorder past the initial snapshot (state change).
      engine.setMedia(item.mediaId);
      await guest.close();
      // Close flushes the final record regardless of the debounce window.
      await engine.close();

      final records = await store.list();
      expect(records, hasLength(1));
      final rec = records.single;
      expect(rec.sessionName, 'HistoryJam');
      expect(rec.sessionId, engine.sessionId);
      expect(rec.wasHost, isTrue);
      expect(rec.peerNames, contains('Funky Walrus'));
      // Attendees are everyone BUT this device — the host does not attend
      // its own room.
      expect(rec.peerNames, isNot(contains('Silky Puffin')));
      // The host was you: a host's own record names no host.
      expect(rec.hostName, isNull);
      final track = rec.tracks.single;
      expect(track.item.title, 'Night Drive');
      expect(track.addedByName, 'You');
      expect(track.existsLocally, isTrue);
      expect(rec.replayableTracks, hasLength(1));
    });

    test('a track from a guest who shared no name is recorded as "Guest", '
        'not its peer id', () async {
      // The recorder snapshots JamEngine.addedByLabel, which fell back to
      // the peer id — so the record said "added by p_2" for good.
      mockAudioChannel();
      final store = JamHistoryStore(await makeTempDir());
      JamEngine.historyStoreProvider = () async => store;

      final engine = await JamHostEngine.start(
        sessionName: 'NamelessJam',
        hostName: 'Silky Puffin',
        address: InternetAddress.loopbackIPv4,
        discoverable: false,
      );
      final guest = await JamGuestClient.connect(
        engine.joinUriFor(InternetAddress.loopbackIPv4),
        clientName: '',
      );
      await waitFor(() => engine.peers.isNotEmpty, reason: 'guest to join');
      final file = await writeTempMedia(makeMediaBytes(2048));
      final item = await JamHostServer.describeFile(
        file,
        kind: MediaKind.audio,
        mime: 'audio/mpeg',
        durationUs: 60_000_000,
        addedBy: guest.selfPeerId,
      );
      engine.debugServer.addMedia(item, file);
      await waitFor(
        () => engine.playlist.isNotEmpty,
        reason: 'the playlist broadcast',
      );
      engine.setMedia(item.mediaId);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await guest.close();
      await engine.close();

      final track = (await store.list()).single.tracks.single;
      expect(track.addedByName, 'Guest');
      expect(track.addedByName, isNot(guest.selfPeerId));
    });

    test('a guest session records the cache path and wasHost=false', () async {
      mockAudioChannel();
      final store = JamHistoryStore(await makeTempDir());
      JamEngine.historyStoreProvider = () async => store;

      final host = JamHostServer(
        sessionName: 'GuestSideJam',
        hostName: 'Silky Puffin',
      );
      await host.start(address: InternetAddress.loopbackIPv4);
      addTearDown(host.close);
      final file = await writeTempMedia(makeMediaBytes(4096));
      final item = await JamHostServer.describeFile(
        file,
        kind: MediaKind.audio,
        mime: 'audio/mpeg',
        durationUs: 60_000_000,
        title: 'Cached Track',
        addedBy: 'host',
      );
      host.addMedia(item, file);
      // A second song with art: the jam's cover, fetched from the host.
      final coverFile = await writeTempMedia(
        makeMediaBytes(2048, seed: 7),
        name: 'cover-song.mp3',
      );
      final coverItem = await JamHostServer.describeFile(
        coverFile,
        kind: MediaKind.audio,
        mime: 'audio/mpeg',
        durationUs: 60_000_000,
        title: 'Cover Song',
        artworkId: await host.addArtwork(tinyPngBytes, mime: 'image/png'),
        addedBy: 'host',
      );
      host.addMedia(coverItem, coverFile);

      final engine = await JamGuestEngine.join(
        host.joinUriFor(InternetAddress.loopbackIPv4),
        mediaCacheDir: await makeTempDir(),
      );
      await waitFor(
        () => engine.prefetchStates.value[item.mediaId]?.ready ?? false,
        reason: 'prefetch to land in the cache',
      );
      await engine.close();

      final rec = (await store.list()).single;
      expect(rec.wasHost, isFalse);
      expect(rec.sessionName, 'GuestSideJam');
      // Who hosted, so Past jams can put them first as the room did.
      expect(rec.hostName, 'Silky Puffin');
      // The cover, fetched from the host and kept as it came (it is tiny).
      expect(rec.coverMediaId, coverItem.mediaId);
      expect(rec.coverFile, endsWith('.cover.png'));
      expect(await store.coverFor(rec), tinyPngBytes);
      // The host is a person in the record on both sides: named in the
      // byline, and counted among who was there (it is not a joined peer,
      // so a guest's roster alone would leave the room looking empty).
      expect(rec.peerNames, ['Silky Puffin']);
      final track = rec.tracks.first;
      expect(track.item.title, 'Cached Track');
      expect(track.addedByName, 'Silky Puffin');
      expect(track.existsLocally, isTrue);
      expect(rec.replayableTracks.first.localPath, track.localPath);
    });

    test('an anonymous host is still the role word, and no attendee', () async {
      mockAudioChannel();
      final store = JamHistoryStore(await makeTempDir());
      JamEngine.historyStoreProvider = () async => store;

      final host = JamHostServer(sessionName: 'AnonJam');
      await host.start(address: InternetAddress.loopbackIPv4);
      addTearDown(() => host.close());
      final file = await writeTempMedia(makeMediaBytes(1024));
      final item = await JamHostServer.describeFile(
        file,
        kind: MediaKind.audio,
        mime: 'audio/mpeg',
        durationUs: 60_000_000,
        addedBy: JamPermissions.hostPeerId,
      );
      host.addMedia(item, file);

      final engine = await JamGuestEngine.join(
        host.joinUriFor(InternetAddress.loopbackIPv4),
        mediaCacheDir: await makeTempDir(),
      );
      expect(engine.hostPeer?.clientName, isEmpty);
      expect(engine.addedByLabel(item, engine.peers), 'Host');
      await engine.close();

      final rec = (await store.list()).single;
      expect(rec.peerNames, isEmpty);
      // No name to put first: the record says nothing about who hosted.
      expect(rec.hostName, isNull);
    });
  });

  group('Record format', () {
    test('an older record reads as it always did: no host, no cover, its '
        'paths as stored', () async {
      final dir = await makeTempDir();
      final song = await writeTempMedia(makeMediaBytes(256));
      // Exactly what the store wrote before host names, references and
      // covers existed.
      await File('${dir.path}/s_old.json').writeAsString(
        jsonEncode({
          'sessionId': 's_old',
          'sessionName': 'Old Jam',
          'wasHost': false,
          'startedAt': '2026-08-01T20:00:00.000',
          'updatedAt': '2026-08-01T21:00:00.000',
          'peerNames': ['Mia', 'Silky Puffin'],
          'tracks': [
            {
              'item': _item('m_1').toJson(),
              'addedByName': 'Mia',
              'localPath': song.path,
            },
          ],
        }),
      );
      final store = JamHistoryStore(dir, roots: JamAppRoots.none);
      final rec = (await store.list()).single;
      expect(rec.sessionName, 'Old Jam');
      expect(rec.peerNames, ['Mia', 'Silky Puffin']);
      expect(rec.hostName, isNull);
      expect(rec.coverFile, isNull);
      expect(rec.coverMediaId, isNull);
      expect(rec.coverPath, isNull);
      final track = rec.tracks.single;
      expect(track.localPath, song.path);
      expect(track.localRef, isNull);
      expect(track.existsLocally, isTrue);
    });

    test('host name, references and cover round-trip; the absolute path '
        'stays for older app versions', () async {
      final base = await makeTempDir();
      final roots = _iosRoots('${base.path}/Application/NEW');
      final song = _touch('${roots.pathOf(JamAppRoot.support)}/imports/a.mp3');
      final dir = Directory('${base.path}/history')..createSync();
      final store = JamHistoryStore(dir, roots: roots);
      await store.save(
        JamHistoryRecord(
          sessionId: 's_new',
          sessionName: 'New Jam',
          wasHost: false,
          startedAt: DateTime(2026, 10, 1),
          updatedAt: DateTime(2026, 10, 1),
          peerNames: const ['Mia', 'Silky Puffin'],
          hostName: 'Silky Puffin',
          tracks: [JamHistoryTrack(item: _item('m_1'), localPath: song.path)],
          coverFile: 's_new.cover.png',
          coverMediaId: 'm_1',
        ),
      );

      final raw =
          jsonDecode(File('${dir.path}/s_new.json').readAsStringSync())
              as Map<String, Object?>;
      expect(raw['hostName'], 'Silky Puffin');
      expect(raw['cover'], {'file': 's_new.cover.png', 'mediaId': 'm_1'});
      final rawTrack = (raw['tracks']! as List).single as Map;
      expect(rawTrack['localPath'], song.path);
      expect(rawTrack['localRef'], {
        'root': 'support',
        'path': 'imports/a.mp3',
      });

      final rec = (await store.list()).single;
      expect(rec.hostName, 'Silky Puffin');
      expect(rec.coverFile, 's_new.cover.png');
      expect(rec.coverMediaId, 'm_1');
      expect(
        rec.coverPath,
        '${dir.path}${Platform.pathSeparator}s_new.cover.png',
      );
      expect(
        rec.tracks.single.localRef,
        const JamPathRef(JamAppRoot.support, 'imports/a.mp3'),
      );
    });

    test('a cover name that is not the record\'s own is not followed', () {
      for (final file in [
        '../../secrets.png',
        's_other.cover.png',
        's_x.cover.png/../../x',
        's_x.json',
      ]) {
        final rec = JamHistoryRecord.fromJson({
          'sessionId': 's_x',
          'cover': {'file': file, 'mediaId': 'm_1'},
        }, dir: Directory('/store'));
        expect(rec!.coverFile, isNull, reason: file);
        expect(rec.coverPath, isNull, reason: file);
        expect(rec.coverMediaId, isNull, reason: file);
      }
    });
  });

  group('Portable paths', () {
    test('iOS: a record from an older container finds its files in this '
        'one', () async {
      final base = await makeTempDir();
      final old = '${base.path}/Containers/Data/Application/OLD-UUID';
      final now = '${base.path}/Containers/Data/Application/NEW-UUID';
      final roots = _iosRoots(now);
      // The files moved with the reinstall; the record still names the old
      // container.
      _touch('$now/Library/Application Support/imports/a.mp3');
      _touch('$now/Library/Caches/localjam_media/b');
      _touch('$now/Documents/c.mp3');
      _touch('$now/tmp/d.mp3');
      final outside = _touch('${base.path}/Music/e.mp3');
      final dir = Directory('${base.path}/history')..createSync();
      await File('${dir.path}/s_ios.json').writeAsString(
        jsonEncode({
          'sessionId': 's_ios',
          'sessionName': 'Moved Jam',
          'wasHost': true,
          'startedAt': '2026-08-01T20:00:00.000',
          'updatedAt': '2026-08-01T21:00:00.000',
          'tracks': [
            for (final (id, path) in [
              ('a', '$old/Library/Application Support/imports/a.mp3'),
              ('b', '$old/Library/Caches/localjam_media/b'),
              ('c', '$old/Documents/c.mp3'),
              ('d', '$old/tmp/d.mp3'),
              ('e', outside.path),
              ('gone', '$old/Library/Application Support/imports/gone.mp3'),
            ])
              {'item': _item(id).toJson(), 'localPath': path},
          ],
        }),
      );
      final store = JamHistoryStore(dir, roots: roots);
      final rec = (await store.list()).single;
      final paths = {for (final t in rec.tracks) t.item.mediaId: t.localPath};
      expect(paths['a'], '$now/Library/Application Support/imports/a.mp3');
      expect(paths['b'], '$now/Library/Caches/localjam_media/b');
      expect(paths['c'], '$now/Documents/c.mp3');
      // No root of its own on iOS (temp is the cache there), but the same
      // container under a new name.
      expect(paths['d'], '$now/tmp/d.mp3');
      // Not the app's: left exactly where it was.
      expect(paths['e'], outside.path);
      // Only a re-based file that is there counts; otherwise the stored path
      // is kept as it was.
      expect(
        paths['gone'],
        '$old/Library/Application Support/imports/gone.mp3',
      );
      expect(rec.replayableTracks.map((t) => t.item.mediaId), [
        'a',
        'b',
        'c',
        'd',
        'e',
      ]);

      // Saved again (Undo, a re-save), the record carries the paths found
      // and their references.
      await store.save(rec);
      final raw =
          jsonDecode(File('${dir.path}/s_ios.json').readAsStringSync())
              as Map<String, Object?>;
      final rawTracks = [for (final t in raw['tracks']! as List) t as Map];
      expect(rawTracks[0]['localPath'], paths['a']);
      expect(rawTracks[0]['localRef'], {
        'root': 'support',
        'path': 'imports/a.mp3',
      });
      expect(rawTracks[1]['localRef'], {
        'root': 'cache',
        'path': 'localjam_media/b',
      });
      expect(rawTracks[4].containsKey('localRef'), isFalse);
    });

    test('a reference is tried first, against this run\'s folders', () async {
      final base = await makeTempDir();
      final old = '${base.path}/Application/OLD';
      final now = '${base.path}/Application/NEW';
      // Both copies exist: the reference, resolved now, wins over the stale
      // absolute path.
      _touch('$old/Library/Application Support/imports/a.mp3');
      _touch('$now/Library/Application Support/imports/a.mp3');
      final track = JamHistoryTrack.fromJson({
        'item': _item('a').toJson(),
        'localPath': '$old/Library/Application Support/imports/a.mp3',
        'localRef': {'root': 'support', 'path': 'imports/a.mp3'},
      }, roots: _iosRoots(now))!;
      expect(track.localPath, '$now/Library/Application Support/imports/a.mp3');
      expect(track.existsLocally, isTrue);

      // Not there now: the absolute path is next.
      final stale = JamHistoryTrack.fromJson({
        'item': _item('b').toJson(),
        'localPath': '$old/Library/Application Support/imports/a.mp3',
        'localRef': {'root': 'support', 'path': 'imports/b.mp3'},
      }, roots: _iosRoots(now))!;
      expect(stale.localPath, '$old/Library/Application Support/imports/a.mp3');
    });
  });

  group('Cover pictures', () {
    test('a small picture is kept as it came; a big one is made smaller; '
        'one that cannot be made is no cover', () async {
      final dir = await makeTempDir();
      final calls = <(int, int)>[];
      var fail = false;
      final store = JamHistoryStore(
        dir,
        downscaleCover: (image, maxEdge) async {
          calls.add((image.length, maxEdge));
          if (fail) throw StateError('no codec');
          return _fakePng(calls.length);
        },
      );

      // Small, and a known format: kept byte for byte, never decoded.
      expect(await store.writeCover('s_1', tinyPngBytes), 's_1.cover.png');
      expect(File('${dir.path}/s_1.cover.png').readAsBytesSync(), tinyPngBytes);
      final smallJpeg = _jpeg(1024);
      expect(await store.writeCover('s_1', smallJpeg), 's_1.cover.jpg');
      // One picture per jam: the PNG it replaced is gone.
      expect(_covers(dir), ['s_1.cover.jpg']);
      expect(calls, isEmpty);

      // Big: made smaller, to the long edge, as PNG.
      final big = _jpeg(JamHistoryStore.keepCoverBytes + 1);
      expect(await store.writeCover('s_1', big), 's_1.cover.png');
      expect(calls, [(big.length, JamHistoryStore.coverEdge)]);
      expect(File('${dir.path}/s_1.cover.png').readAsBytesSync(), _fakePng(1));
      expect(_covers(dir), ['s_1.cover.png']);

      // Small but not a picture this knows: decoded too.
      await store.writeCover('s_2', Uint8List.fromList([1, 2, 3, 4]));
      expect(calls, hasLength(2));

      // A downscaler that throws: no cover, nothing half-written, no throw.
      fail = true;
      expect(await store.writeCover('s_3', big), isNull);
      expect(_covers(dir).where((f) => f.startsWith('s_3')), isEmpty);
      expect(dir.listSync().where((e) => e.path.endsWith('.part')), isEmpty);
    });

    test('the real downscaler keeps the aspect, at 256 on the long '
        'edge', () async {
      for (final (width, height, expected) in [
        (800, 400, (256, 128)),
        (300, 600, (128, 256)),
      ]) {
        final png = await _noisePng(width, height);
        expect(png.length, greaterThan(JamHistoryStore.keepCoverBytes));
        final smaller = await jamDownscaleCover(png, JamHistoryStore.coverEdge);
        expect(smaller, isNotNull);
        final codec = await ui.instantiateImageCodec(smaller!);
        final image = (await codec.getNextFrame()).image;
        expect((image.width, image.height), expected);
        image.dispose();
        codec.dispose();
      }
    });

    test('a cover goes with its record: forgotten, pruned — and back with an '
        'Undo', () async {
      final dir = await makeTempDir();
      final store = JamHistoryStore(dir, maxRecords: 2);
      Future<JamHistoryRecord> saveWithCover(String id, DateTime at) async {
        final file = await store.writeCover(id, tinyPngBytes);
        final rec = record(id: id, updatedAt: at, coverFile: file);
        await store.save(rec);
        return rec;
      }

      final t0 = DateTime(2026, 8, 1);
      final a = await saveWithCover('s_a', t0);
      await saveWithCover('s_b', t0.add(const Duration(hours: 1)));
      expect(_covers(dir), ['s_a.cover.png', 's_b.cover.png']);
      final listed = await store.list();
      expect(await store.coverFor(listed.last), tinyPngBytes);
      expect(File(listed.last.coverPath!).existsSync(), isTrue);

      // Forget: the picture goes too...
      await store.delete('s_a');
      expect(_covers(dir), ['s_b.cover.png']);
      expect(await store.coverFor(a), isNull);
      // ...and Undo (saving the same record again) brings it back.
      await store.save(a);
      expect(_covers(dir), ['s_a.cover.png', 's_b.cover.png']);
      expect(await store.coverFor(a), tinyPngBytes);

      // Pruned past maxRecords: the oldest record's picture goes with it.
      await saveWithCover('s_c', t0.add(const Duration(hours: 2)));
      expect((await store.list()).map((r) => r.sessionId), ['s_c', 's_b']);
      expect(_covers(dir), ['s_b.cover.png', 's_c.cover.png']);
    });

    test('a live jam\'s cover is made once, made again when the cover song '
        'changes, and dropped when no song has art', () async {
      mockAudioChannel();
      final calls = <int>[];
      final dir = await makeTempDir();
      final store = JamHistoryStore(
        dir,
        downscaleCover: (image, maxEdge) async {
          calls.add(image.length);
          return _fakePng(calls.length);
        },
      );
      JamEngine.historyStoreProvider = () async => store;

      final engine = await JamHostEngine.start(
        sessionName: 'CoverJam',
        hostName: 'Silky Puffin',
        address: InternetAddress.loopbackIPv4,
        discoverable: false,
      );
      addTearDown(engine.close);
      await waitFor(
        () => engine.historyRecorder != null,
        reason: 'the recorder',
      );
      final recorder = engine.historyRecorder!;
      Future<MediaItem> addSong(String name, {Uint8List? art}) async {
        final file = await writeTempMedia(
          makeMediaBytes(1024, seed: name.hashCode),
          name: '$name.mp3',
        );
        final item = await JamHostServer.describeFile(
          file,
          kind: MediaKind.audio,
          mime: 'audio/mpeg',
          durationUs: 60_000_000,
          title: name,
          artworkId: art == null
              ? null
              : await engine.debugServer.addArtwork(art, mime: 'image/jpeg'),
          addedBy: JamPermissions.hostPeerId,
        );
        final before = engine.playlist.length;
        engine.debugServer.addMedia(item, file);
        await waitFor(
          () => engine.playlist.length > before,
          reason: 'the playlist broadcast',
        );
        return item;
      }

      Future<JamHistoryRecord> flushed() async {
        await recorder.flushNow();
        return (await store.list()).single;
      }

      // No art yet: no cover.
      final plain = await addSong('Plain');
      expect((await flushed()).coverFile, isNull);

      // The first song with art is the cover — made once, however many
      // times the record is written.
      final artA = _jpeg(JamHistoryStore.keepCoverBytes + 10, seed: 1);
      final a = await addSong('A', art: artA);
      var rec = await flushed();
      expect(rec.coverMediaId, a.mediaId);
      expect(rec.coverFile, '${engine.sessionId}.cover.png');
      expect(await store.coverFor(rec), _fakePng(1));
      expect(calls, [artA.length]);
      await flushed();
      await flushed();
      expect(calls, hasLength(1));

      // Another song with art moves to the front: the cover is made again,
      // in place of the old one.
      final artB = _jpeg(JamHistoryStore.keepCoverBytes + 20, seed: 2);
      final b = await addSong('B', art: artB);
      expect((await flushed()).coverMediaId, a.mediaId);
      expect(calls, hasLength(1));
      engine.moveMediaItem(b.mediaId, 0);
      await waitFor(
        () => engine.playlist.first.mediaId == b.mediaId,
        reason: 'the move',
      );
      rec = await flushed();
      expect(rec.coverMediaId, b.mediaId);
      expect(await store.coverFor(rec), _fakePng(2));
      expect(calls, [artA.length, artB.length]);
      expect(_covers(dir), ['${engine.sessionId}.cover.png']);

      // A song with the same picture in front: nothing to redraw.
      final c = await addSong('C', art: artB);
      engine.moveMediaItem(c.mediaId, 0);
      await waitFor(
        () => engine.playlist.first.mediaId == c.mediaId,
        reason: 'the move',
      );
      rec = await flushed();
      expect(rec.coverMediaId, c.mediaId);
      expect(calls, hasLength(2));

      // Every song with art gone: no cover, and no picture left behind.
      for (final item in [a, b, c]) {
        engine.removeMediaItem(item.mediaId);
      }
      await waitFor(() => engine.playlist.length == 1, reason: 'the removals');
      expect(engine.playlist.single.mediaId, plain.mediaId);
      rec = await flushed();
      expect(rec.coverFile, isNull);
      expect(rec.coverMediaId, isNull);
      expect(_covers(dir), isEmpty);
    });

    test('a failing picture never breaks the session or its record', () async {
      mockAudioChannel();
      final dir = await makeTempDir();
      final store = JamHistoryStore(
        dir,
        downscaleCover: (image, maxEdge) async => throw StateError('no codec'),
      );
      JamEngine.historyStoreProvider = () async => store;
      final engine = await JamHostEngine.start(
        sessionName: 'NoCoverJam',
        address: InternetAddress.loopbackIPv4,
        discoverable: false,
      );
      final file = await writeTempMedia(makeMediaBytes(1024));
      final item = await JamHostServer.describeFile(
        file,
        kind: MediaKind.audio,
        mime: 'audio/mpeg',
        durationUs: 60_000_000,
        artworkId: await engine.debugServer.addArtwork(
          _jpeg(JamHistoryStore.keepCoverBytes + 1),
          mime: 'image/jpeg',
        ),
        addedBy: JamPermissions.hostPeerId,
      );
      engine.debugServer.addMedia(item, file);
      await waitFor(() => engine.playlist.isNotEmpty, reason: 'the playlist');
      await waitFor(
        () => engine.historyRecorder != null,
        reason: 'the recorder',
      );
      await engine.historyRecorder!.flushNow();
      // The session carries on: still playing what it was asked to.
      engine.setMedia(item.mediaId);
      await engine.close();

      final rec = (await store.list()).single;
      expect(rec.tracks.single.item.mediaId, item.mediaId);
      expect(rec.coverFile, isNull);
      expect(_covers(dir), isEmpty);
    });
  });
}

MediaItem _item(String id) => MediaItem(
  mediaId: id,
  kind: MediaKind.audio,
  name: '$id.mp3',
  mime: 'audio/mpeg',
  sizeBytes: 256,
  sha256: 'aa',
  title: 'Song $id',
);

/// An iOS container's folders, as path_provider names them there: the cache
/// and temp are one folder (`Library/Caches`).
JamAppRoots _iosRoots(String container) => JamAppRoots({
  JamAppRoot.support: '$container/Library/Application Support',
  JamAppRoot.cache: '$container/Library/Caches',
  JamAppRoot.documents: '$container/Documents',
  JamAppRoot.temp: '$container/Library/Caches',
}, separator: '/');

/// Creates [path] (and its folders) with a few bytes in it.
File _touch(String path) => File(path)
  ..createSync(recursive: true)
  ..writeAsBytesSync(const [1, 2, 3]);

/// A JPEG-signed payload of [length] bytes.
Uint8List _jpeg(int length, {int seed = 42}) =>
    makeMediaBytes(length, seed: seed)
      ..setRange(0, 3, const [0xFF, 0xD8, 0xFF]);

/// What the fake downscaler hands back on its [n]th call.
Uint8List _fakePng(int n) => Uint8List.fromList([...tinyPngBytes, n]);

/// The cover pictures in [dir], by name.
List<String> _covers(Directory dir) => [
  for (final entity in dir.listSync())
    if (entity is File && entity.uri.pathSegments.last.contains('.cover.'))
      entity.uri.pathSegments.last,
]..sort();

/// A [width]×[height] PNG of noise — big, as a real cover is.
Future<Uint8List> _noisePng(int width, int height) async {
  final pixels = makeMediaBytes(width * height * 4, seed: 3);
  final buffer = await ui.ImmutableBuffer.fromUint8List(pixels);
  final descriptor = ui.ImageDescriptor.raw(
    buffer,
    width: width,
    height: height,
    pixelFormat: ui.PixelFormat.rgba8888,
  );
  final codec = await descriptor.instantiateCodec();
  final image = (await codec.getNextFrame()).image;
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  codec.dispose();
  descriptor.dispose();
  buffer.dispose();
  return data!.buffer.asUint8List();
}
