/// Jam history: the on-disk store, and end-to-end recording from live
/// engines via the session guards.
library;

import 'dart:io';

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
  }) => JamHistoryRecord(
    sessionId: id,
    sessionName: 'Jam $id',
    wasHost: true,
    startedAt: updatedAt,
    updatedAt: updatedAt,
    tracks: tracks,
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
      // The host is a person in the record on both sides: named in the
      // byline, and counted among who was there (it is not a joined peer,
      // so a guest's roster alone would leave the room looking empty).
      expect(rec.peerNames, ['Silky Puffin']);
      final track = rec.tracks.single;
      expect(track.item.title, 'Cached Track');
      expect(track.addedByName, 'Silky Puffin');
      expect(track.existsLocally, isTrue);
      expect(rec.replayableTracks.single.localPath, track.localPath);
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

      expect((await store.list()).single.peerNames, isEmpty);
    });
  });
}
