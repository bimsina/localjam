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
      final track = rec.tracks.single;
      expect(track.item.title, 'Night Drive');
      expect(track.addedByName, 'You');
      expect(track.existsLocally, isTrue);
      expect(rec.replayableTracks, hasLength(1));
    });

    test('a guest session records the cache path and wasHost=false', () async {
      mockAudioChannel();
      final store = JamHistoryStore(await makeTempDir());
      JamEngine.historyStoreProvider = () async => store;

      final host = JamHostServer(sessionName: 'GuestSideJam');
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
      final track = rec.tracks.single;
      expect(track.item.title, 'Cached Track');
      expect(track.addedByName, 'Host');
      expect(track.existsLocally, isTrue);
      expect(rec.replayableTracks.single.localPath, track.localPath);
    });
  });
}
