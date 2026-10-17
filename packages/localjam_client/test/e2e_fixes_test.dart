/// Engine regressions from the 2026-10-17 three-device simulator run (iOS
/// host, iOS guest, Android guest — DEVICE_TESTING.md): the host hearing
/// its guests' uploads, and what a UI still holding an engine's listenables
/// may do after the jam ended.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MethodCall;
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_client/localjam_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'engine_test_utils.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => HttpOverrides.global = null);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  /// Every listenable [engine] hands out, by name.
  Map<String, ValueListenable<Object?>> listenablesOf(JamEngine engine) => {
    'sessionEnded': engine.sessionEnded,
    'nudgeUs': engine.nudgeUs,
    'trackFinished': engine.trackFinished,
    'loadedDurationUs': engine.loadedDurationUs,
    'lastPlayerError': engine.lastPlayerError,
    'outputSuspension': engine.outputSuspension,
    if (engine is JamHostEngine) ...{
      'lanAddresses': engine.lanAddresses,
      'joinUriListenable': engine.joinUriListenable,
      'announcedAway': engine.announcedAway,
      'awaitingReadiness': engine.awaitingReadiness,
      'kickedPeersListenable': engine.kickedPeersListenable,
    },
    if (engine is JamGuestEngine) ...{
      'hostAway': engine.hostAway,
      'prefetchStates': engine.prefetchStates,
      'uploadProgress': engine.uploadProgress,
    },
  };

  /// Subscribes to and unsubscribes from every listenable after close, the
  /// way a `ValueListenableBuilder` mounting on a closing sheet does.
  void subscribeLate(JamEngine engine) {
    for (final MapEntry(key: name, value: listenable) in listenablesOf(
      engine,
    ).entries) {
      void listener() => fail('$name notified after close');
      expect(
        () => listenable
          ..addListener(listener)
          ..removeListener(listener),
        returnsNormally,
        reason: '$name: subscribing after close',
      );
      expect(() => listenable.value, returnsNormally, reason: name);
    }
  }

  group('listenables outlive close (a sheet still open as the jam ends)', () {
    test('host: a widget mounting after close() subscribes harmlessly, and '
        'reads the last values', () async {
      mockAudioChannel();
      final engine = await JamHostEngine.start(
        sessionName: 'EndJam',
        hostName: 'Nimble Toucan',
        address: InternetAddress.loopbackIPv4,
        discoverable: false,
      );
      final joinUri = engine.joinUri;
      await engine.close();

      subscribeLate(engine);
      expect(engine.joinUriListenable.value, joinUri);
      expect(engine.sessionEnded.value, JamSessionEndReason.closedLocally);
      await engine.close(); // Still idempotent.
    });

    test('guest: the same after close()', () async {
      mockAudioChannel();
      final host = JamHostServer(sessionName: 'EndJam');
      await host.start(address: InternetAddress.loopbackIPv4);
      addTearDown(host.close);
      final engine = await JamGuestEngine.join(
        host.joinUriFor(InternetAddress.loopbackIPv4),
        clientName: 'Electric Mongoose',
        mediaCacheDir: await makeTempDir(),
      );
      await engine.close();

      subscribeLate(engine);
      expect(engine.sessionEnded.value, JamSessionEndReason.closedLocally);
    });
  });

  group('a guest\'s upload is heard on the host (§6.4)', () {
    // The host's player resolved media only through the paths it had
    // registered itself; an upload never got one, so the room played every
    // guest's track to everyone but the host.
    Future<JamHostEngine> startHost() async {
      final engine = await JamHostEngine.start(
        sessionName: 'UploadJam',
        hostName: 'Nimble Toucan',
        address: InternetAddress.loopbackIPv4,
        discoverable: false,
      );
      addTearDown(engine.close);
      return engine;
    }

    Future<({JamGuestClient guest, MediaItem item})> upload(
      JamHostEngine host, {
      int seed = 5,
    }) async {
      final guest = await JamGuestClient.connect(
        host.joinUriFor(InternetAddress.loopbackIPv4),
        clientName: 'Silky Narwhal',
      );
      addTearDown(guest.close);
      final item = await guest.uploadMedia(
        await writeTempMedia(makeMediaBytes(4096, seed: seed), name: 'g.mp3'),
        kind: MediaKind.audio,
        mime: 'audio/mpeg',
        durationUs: 30000000,
      );
      await waitFor(
        () => host.playlist.any((i) => i.mediaId == item.mediaId),
        reason: 'the upload in the queue',
      );
      return (guest: guest, item: item);
    }

    test('the room plays it: the host\'s own player loads the file the '
        'server stored and schedules it', () async {
      final log = mockAudioChannel(durationUs: 30000000);
      final host = await startHost();
      final (:guest, :item) = await upload(host);
      final stored = host.debugServer.storedUploadFile(item.mediaId);
      expect(stored, isNotNull);

      log.clear();
      host.setMedia(item.mediaId);
      host.play();
      await waitFor(
        () => log.any((c) => c.method == 'playAt'),
        reason: 'the host to schedule the guest\'s track',
      );
      final loads = [
        for (final MethodCall call in log)
          if (call.method == 'load') (call.arguments as Map)['path'],
      ];
      expect(loads, [stored!.path]);
      expect(
        log.indexWhere((c) => c.method == 'load'),
        lessThan(log.indexWhere((c) => c.method == 'playAt')),
      );
      // Its own length, not the previous track's.
      expect(host.loadedDurationUs.value, 30000000);
      expect(host.sync.outputSuspension.value, isNull);
      await guest.close();
    });

    test('jam history keeps the track and its credit, but not as replayable '
        'on the host: the upload store goes with the room', () async {
      mockAudioChannel();
      final store = JamHistoryStore(await makeTempDir());
      final previous = JamEngine.historyStoreProvider;
      JamEngine.historyStoreProvider = () async => store;
      addTearDown(() => JamEngine.historyStoreProvider = previous);

      final host = await startHost();
      final own = await host.addMediaFile(
        await writeTempMedia(makeMediaBytes(2048, seed: 9), name: 'h.mp3'),
      );
      final (:guest, :item) = await upload(host);
      expect(host.localPathFor(item), isNull);
      host.setMedia(item.mediaId);
      await guest.close();
      await host.close();
      expect(
        host.debugServer.storedUploadFile(item.mediaId),
        isNull,
        reason: 'deleted with the room',
      );

      final record = (await store.list()).single;
      final uploaded = record.tracks.singleWhere(
        (t) => t.item.mediaId == item.mediaId,
      );
      expect(uploaded.addedByName, 'Silky Narwhal');
      expect(uploaded.localPath, isNull);
      expect(uploaded.existsLocally, isFalse);
      expect(record.replayableTracks.map((t) => t.item.mediaId), [own.mediaId]);
    });
  });
}
