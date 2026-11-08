/// Integration tests: a real JamHostServer and JamGuestClient(s) talking over
/// 127.0.0.1 loopback, exercising PROTOCOL.md §1, §3–§6 end to end.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:localjam_net/localjam_net.dart';
import 'package:test/test.dart';

import 'test_fixtures.dart';

const _codec = MessageCodec();

/// Deterministic pseudo-random media payload.
Uint8List makeMediaBytes(int length, {int seed = 42}) {
  final rng = Random(seed);
  return Uint8List.fromList([
    for (var i = 0; i < length; i++) rng.nextInt(256),
  ]);
}

Future<File> writeTempMedia(Uint8List bytes) async {
  final dir = await Directory.systemTemp.createTemp('localjam_net_test');
  addTearDown(() => dir.delete(recursive: true));
  final file = File('${dir.path}/track.bin');
  await file.writeAsBytes(bytes);
  return file;
}

Future<JamHostServer> startHost({
  String sessionName = 'TestJam',
  String hostName = '',
  int leadTimeUs = 750_000,
  JamEndPolicy endPolicy = JamEndPolicy.pause,
  // Tests that are NOT about permissions run wide open; enforcement has its
  // own §5.6 group passing stricter policies explicitly.
  JamPolicy policy = JamPolicy.open,
  Duration silenceTimeout = const Duration(seconds: 10),
  Duration reconnectGrace = const Duration(seconds: 30),
  Duration livenessCheckInterval = const Duration(seconds: 1),
  int maxUploadBytes = 512 * 1024 * 1024,
  int uploadBudgetBytes = 2 * 1024 * 1024 * 1024,
  int maxPlaylistLength = 500,
  int maxPeers = 32,
  int maxUploadsPerPeer = 2,
}) async {
  final host = JamHostServer(
    sessionName: sessionName,
    hostName: hostName,
    leadTimeUs: leadTimeUs,
    endPolicy: endPolicy,
    policy: policy,
    silenceTimeout: silenceTimeout,
    reconnectGrace: reconnectGrace,
    livenessCheckInterval: livenessCheckInterval,
    maxUploadBytes: maxUploadBytes,
    uploadBudgetBytes: uploadBudgetBytes,
    maxPlaylistLength: maxPlaylistLength,
    maxPeers: maxPeers,
    maxUploadsPerPeer: maxUploadsPerPeer,
  );
  await host.start(address: InternetAddress.loopbackIPv4);
  addTearDown(host.close);
  return host;
}

Future<JamGuestClient> joinGuest(
  JamHostServer host, {
  String clientName = 'guest',
  String? clientId,
}) async {
  final guest = await JamGuestClient.connect(
    host.joinUriFor(InternetAddress.loopbackIPv4),
    clientName: clientName,
    clientId: clientId,
  );
  addTearDown(guest.close);
  return guest;
}

/// Polls [condition] every 10 ms until true or [timeout] elapses.
Future<void> waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
  String reason = 'condition',
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for $reason');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  test('join handshake delivers welcome with snapshot and playlist', () async {
    final host = await startHost(sessionName: 'RoadTrip');
    final bytes = makeMediaBytes(4096);
    final file = await writeTempMedia(bytes);
    final item = await JamHostServer.describeFile(
      file,
      kind: MediaKind.audio,
      mime: 'audio/mpeg',
      durationUs: 1_000_000,
    );
    host.addMedia(item, file);

    final joinUri = host.joinUriFor(InternetAddress.loopbackIPv4);
    expect(joinUri.scheme, 'localjam');
    expect(joinUri.queryParameters['name'], 'RoadTrip');
    expect(joinUri.queryParameters['token'], host.token);

    final guest = await joinGuest(host);
    expect(guest.sessionName, 'RoadTrip');
    expect(guest.selfPeerId, startsWith('p_'));
    expect(guest.snapshot.status, PlaybackStatus.idle);
    expect(guest.snapshot.rev, 0);
    expect(guest.playlist, hasLength(1));
    expect(guest.playlist.single.mediaId, item.mediaId);
    expect(guest.playlist.single.sha256, item.sha256);
  });

  test('connect reads either join form, and neither is a FormatException '
      'that does not echo the token', () async {
    final host = await startHost(sessionName: 'RoadTrip');
    final link = host.joinLinkFor(InternetAddress.loopbackIPv4);
    final viaHttp = await JamGuestClient.connect(
      link.toHttpUri(),
      clientName: 'browser-shaped',
    );
    addTearDown(viaHttp.close);
    expect(viaHttp.sessionName, 'RoadTrip');

    await expectLater(
      JamGuestClient.connect(
        Uri.parse('http://127.0.0.1:${host.port}/ws#token=${host.token}'),
      ),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          isNot(contains(host.token)),
        ),
      ),
    );
  });

  test('two guests see each other via peers list and peer_joined', () async {
    final host = await startHost();
    final g1 = await joinGuest(host, clientName: 'alice');

    final joinedEvent = g1.peerEvents
        .firstWhere((e) => e.kind == JamPeerEventKind.joined)
        .timeout(const Duration(seconds: 5));
    final g2 = await joinGuest(host, clientName: 'bob');

    final event = await joinedEvent;
    expect(event.peer!.clientName, 'bob');
    expect(event.peerId, g2.selfPeerId);

    // The late joiner's welcome carried the existing peer.
    expect(g2.peers.map((p) => p.peerId), contains(g1.selfPeerId));
    await waitFor(() => g1.peers.length == 1, reason: 'g1 to see bob');
  });

  test('guest clock synchronizes with sane offset on loopback', () async {
    final host = await startHost();
    final guest = await joinGuest(host);

    await waitFor(
      () => guest.clock.isSynchronized,
      reason: 'clock sync after join burst',
    );
    // Host and guest share one process-wide monotonic clock in tests, so the
    // true offset is ~0; allow generous slack for scheduling jitter.
    expect(guest.clock.offsetUs!.abs(), lessThan(20_000));
    expect(guest.sessionNowUs, greaterThan(0));
  });

  test('addMedia broadcasts an updated playlist to joined guests', () async {
    final host = await startHost();
    final guest = await joinGuest(host);
    expect(guest.playlist, isEmpty);

    final update = guest.playlistUpdates.first.timeout(
      const Duration(seconds: 5),
    );
    final file = await writeTempMedia(makeMediaBytes(1024));
    final item = await JamHostServer.describeFile(file, kind: MediaKind.audio);
    host.addMedia(item, file);

    final items = await update;
    expect(items.map((i) => i.mediaId), [item.mediaId]);
    expect(guest.playlist, hasLength(1));
  });

  test('guest fetches media, verifies sha256, host sees it ready', () async {
    final host = await startHost();
    final bytes = makeMediaBytes(64 * 1024);
    final file = await writeTempMedia(bytes);
    final item = await JamHostServer.describeFile(file, kind: MediaKind.audio);
    host.addMedia(item, file);
    final guest = await joinGuest(host);

    final progresses = <double>[];
    final fetched = await guest.fetchMedia(
      item.mediaId,
      onProgress: progresses.add,
    );
    expect(fetched, equals(bytes));
    expect(sha256.convert(fetched).toString(), item.sha256);
    expect(progresses.last, 1.0);

    await waitFor(
      () => host.allPeersReady(item.mediaId),
      reason: 'host to record readiness',
    );
  });

  test('fetchMedia rejects unknown media id', () async {
    final host = await startHost();
    final guest = await joinGuest(host);
    expect(() => guest.fetchMedia('m_nope'), throwsArgumentError);
  });

  test(
    'requestPlay broadcasts playing state with a future anchor to all',
    () async {
      final host = await startHost();
      final file = await writeTempMedia(makeMediaBytes(2048));
      final item = await JamHostServer.describeFile(
        file,
        kind: MediaKind.audio,
      );
      host.addMedia(item, file);

      final g1 = await joinGuest(host, clientName: 'alice');
      final g2 = await joinGuest(host, clientName: 'bob');
      await waitFor(
        () => g1.clock.isSynchronized && g2.clock.isSynchronized,
        reason: 'both guests synced',
      );

      final g1Playing = g1.states
          .firstWhere((s) => s.status == PlaybackStatus.playing)
          .timeout(const Duration(seconds: 5));
      final g2Playing = g2.states
          .firstWhere((s) => s.status == PlaybackStatus.playing)
          .timeout(const Duration(seconds: 5));

      await g1.requestSetMedia(item.mediaId);
      await g1.requestPlay();

      final s1 = await g1Playing;
      final s2 = await g2Playing;
      expect(s1, equals(s2));
      expect(s1.mediaId, item.mediaId);
      expect(s1.anchor, isNotNull);
      // §5.3: the anchor is scheduled leadTime (750 ms default) in the future.
      // At receipt (a few ms after the host applied it) it must still be well
      // in the future on the session clock, and not further than leadTime.
      final untilAnchorUs = s1.anchor!.hostTimeUs - g1.sessionNowUs;
      expect(untilAnchorUs, greaterThan(400_000));
      expect(untilAnchorUs, lessThan(800_000));
    },
  );

  test('pause and seek round-trip through guest requests', () async {
    final host = await startHost();
    final file = await writeTempMedia(makeMediaBytes(2048));
    final item = await JamHostServer.describeFile(file, kind: MediaKind.audio);
    host.addMedia(item, file);
    final guest = await joinGuest(host);

    await guest.requestSetMedia(item.mediaId);
    await guest.requestPlay();
    await waitFor(
      () => guest.snapshot.status == PlaybackStatus.playing,
      reason: 'playing state',
    );

    await guest.requestPause();
    await waitFor(
      () => guest.snapshot.status == PlaybackStatus.paused,
      reason: 'paused state',
    );
    expect(guest.snapshot.anchor, isNull);

    await guest.requestSeek(5_000_000);
    await waitFor(
      () => guest.snapshot.positionUs == 5_000_000,
      reason: 'seek to 5 s',
    );
    expect(guest.snapshot.status, PlaybackStatus.paused);
    expect(host.snapshot.positionUs, 5_000_000);
  });

  test('host-initiated controls broadcast state too', () async {
    final host = await startHost();
    final file = await writeTempMedia(makeMediaBytes(2048));
    final item = await JamHostServer.describeFile(file, kind: MediaKind.audio);
    host.addMedia(item, file);
    final guest = await joinGuest(host);

    host.setMedia(item.mediaId);
    host.play();
    await waitFor(
      () => guest.snapshot.status == PlaybackStatus.playing,
      reason: 'playing after host.play()',
    );
    host.pause();
    await waitFor(
      () => guest.snapshot.status == PlaybackStatus.paused,
      reason: 'paused after host.pause()',
    );
  });

  group('media plane HTTP semantics', () {
    late JamHostServer host;
    late Uint8List bytes;
    late MediaItem item;
    late HttpClient http;

    setUp(() async {
      host = await startHost();
      bytes = makeMediaBytes(1000);
      final file = await writeTempMedia(bytes);
      item = await JamHostServer.describeFile(file, kind: MediaKind.audio);
      host.addMedia(item, file);
      http = HttpClient();
      addTearDown(() => http.close(force: true));
    });

    Future<HttpClientResponse> get(
      String path, {
      String? range,
      String? bearer,
    }) async {
      final req = await http.getUrl(
        Uri.parse('http://127.0.0.1:${host.port}$path'),
      );
      req.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer ${bearer ?? host.token}',
      );
      if (range != null) req.headers.set(HttpHeaders.rangeHeader, range);
      return req.close();
    }

    test('full GET returns 200 with the exact bytes', () async {
      final res = await get('/media/${item.mediaId}');
      expect(res.statusCode, 200);
      expect(res.headers.value(HttpHeaders.acceptRangesHeader), 'bytes');
      final body = await res.fold<BytesBuilder>(
        BytesBuilder(),
        (b, chunk) => b..add(chunk),
      );
      expect(body.takeBytes(), equals(bytes));
    });

    test('Range request returns the correct 206 slice', () async {
      final res = await get('/media/${item.mediaId}', range: 'bytes=10-19');
      expect(res.statusCode, 206);
      expect(
        res.headers.value(HttpHeaders.contentRangeHeader),
        'bytes 10-19/1000',
      );
      final body = await res.fold<BytesBuilder>(
        BytesBuilder(),
        (b, chunk) => b..add(chunk),
      );
      expect(body.takeBytes(), equals(bytes.sublist(10, 20)));
    });

    test('open-ended and suffix ranges resolve correctly', () async {
      final tail = await get('/media/${item.mediaId}', range: 'bytes=990-');
      expect(tail.statusCode, 206);
      final tailBody = await tail.fold<BytesBuilder>(
        BytesBuilder(),
        (b, chunk) => b..add(chunk),
      );
      expect(tailBody.takeBytes(), equals(bytes.sublist(990)));

      final suffix = await get('/media/${item.mediaId}', range: 'bytes=-5');
      expect(suffix.statusCode, 206);
      expect(
        suffix.headers.value(HttpHeaders.contentRangeHeader),
        'bytes 995-999/1000',
      );
      final suffixBody = await suffix.fold<BytesBuilder>(
        BytesBuilder(),
        (b, chunk) => b..add(chunk),
      );
      expect(suffixBody.takeBytes(), equals(bytes.sublist(995)));
    });

    test('unsatisfiable range returns 416 with total size', () async {
      final res = await get('/media/${item.mediaId}', range: 'bytes=5000-');
      expect(res.statusCode, 416);
      expect(res.headers.value(HttpHeaders.contentRangeHeader), 'bytes */1000');
      await res.drain<void>();
    });

    test('unknown media id returns 404', () async {
      final res = await get('/media/m_missing');
      expect(res.statusCode, 404);
      await res.drain<void>();
    });

    test('wrong bearer token returns 401', () async {
      final res = await get('/media/${item.mediaId}', bearer: 'wrong');
      expect(res.statusCode, 401);
      await res.drain<void>();
    });
  });

  group('guest uploads (§6.4)', () {
    test('upload round trip: playlist broadcast, event, idempotent re-upload, '
        'other guest fetches to file', () async {
      final host = await startHost();
      final bytes = makeMediaBytes(48 * 1024, seed: 7);
      final file = await writeTempMedia(bytes);
      final expectedSha = sha256.convert(bytes).toString();

      final uploader = await joinGuest(host, clientName: 'uploader');
      final listener = await joinGuest(host, clientName: 'listener');

      final hostEvents = <JamHostEvent>[];
      host.events.listen(hostEvents.add);
      final playlistUpdate = listener.playlistUpdates.first.timeout(
        const Duration(seconds: 5),
      );

      final progresses = <double>[];
      final item = await uploader.uploadMedia(
        file,
        kind: MediaKind.audio,
        name: 'My Song.mp3',
        mime: 'audio/mpeg',
        durationUs: 1_000_000,
        onProgress: progresses.add,
      );

      // The host computed sha/size/id itself; metadata came from headers.
      expect(item.sha256, expectedSha);
      expect(item.mediaId, 'm_${expectedSha.substring(0, 12)}');
      expect(item.sizeBytes, bytes.length);
      expect(item.durationUs, 1_000_000);
      expect(item.name, 'My Song.mp3');
      expect(item.mime, 'audio/mpeg');
      expect(item.kind, MediaKind.audio);
      expect(progresses.last, 1.0);

      // The playlist broadcast reached the other guest with the same item.
      final items = await playlistUpdate;
      expect(items.map((i) => i.mediaId), [item.mediaId]);
      expect(items.single.sha256, expectedSha);
      expect(items.single.durationUs, 1_000_000);
      expect(host.playlist, hasLength(1));

      // mediaUploaded fired with the uploader's peerId, before the
      // playlist broadcast.
      final uploadedIdx = hostEvents.indexWhere(
        (e) => e.kind == JamHostEventKind.mediaUploaded,
      );
      expect(uploadedIdx, isNonNegative);
      expect(hostEvents[uploadedIdx].peerId, uploader.selfPeerId);
      expect(hostEvents[uploadedIdx].mediaId, item.mediaId);
      final broadcastIdx = hostEvents.indexWhere(
        (e) => e.kind == JamHostEventKind.playlistBroadcast,
      );
      expect(broadcastIdx, greaterThan(uploadedIdx));

      // A second identical upload is idempotent: 200 with the existing
      // item (first upload's metadata wins), no duplicate playlist entry,
      // no second mediaUploaded event.
      final again = await uploader.uploadMedia(
        file,
        kind: MediaKind.audio,
        name: 'Renamed.mp3',
      );
      expect(again.mediaId, item.mediaId);
      expect(again.name, 'My Song.mp3');
      expect(host.playlist, hasLength(1));
      expect(
        hostEvents.where((e) => e.kind == JamHostEventKind.mediaUploaded),
        hasLength(1),
      );

      // Another guest can stream-fetch the uploaded item byte-for-byte.
      final dir = await Directory.systemTemp.createTemp('localjam_dl');
      addTearDown(() => dir.delete(recursive: true));
      final dest = File('${dir.path}/fetched.bin');
      await listener.fetchMediaToFile(item.mediaId, dest);
      expect(await dest.readAsBytes(), equals(bytes));
    });

    test('uploads past the session upload budget are answered 507', () async {
      // Two uploads fit the per-file cap; together they do not fit the
      // session budget (§6.4 hardening: the per-file cap bounds one file,
      // not a guest looping just-under-the-cap files).
      final host = await startHost(
        maxUploadBytes: 4096,
        uploadBudgetBytes: 3000,
      );
      final guest = await joinGuest(host);
      final first = await guest.uploadMedia(
        await writeTempMedia(makeMediaBytes(2000, seed: 1)),
        kind: MediaKind.audio,
      );
      expect(host.playlist.map((i) => i.mediaId), [first.mediaId]);
      expect(host.uploadedBytes, 2000);

      await expectLater(
        guest.uploadMedia(
          await writeTempMedia(makeMediaBytes(2000, seed: 2)),
          kind: MediaKind.audio,
        ),
        throwsA(
          isA<HttpException>().having(
            (e) => e.message,
            'message',
            contains('507'),
          ),
        ),
      );
      expect(host.playlist, hasLength(1));
      expect(host.uploadedBytes, 2000);
    });

    test('parallel uploads cannot outrun the budget between them', () async {
      // The TOCTOU the reservation exists for: five uploads that each read
      // the budget before any of them had written to it. Checking only
      // already-stored bytes lets all five pass and the session land at
      // 5000 bytes against a 3000-byte budget.
      final host = await startHost(
        maxUploadBytes: 4096,
        uploadBudgetBytes: 3000,
        // All five from one guest at once: this is about the budget, not
        // the per-peer concurrency cap (which would 429 three of them).
        maxUploadsPerPeer: 5,
      );
      final guest = await joinGuest(host);
      final files = [
        for (var i = 0; i < 5; i++)
          await writeTempMedia(makeMediaBytes(1000, seed: 100 + i)),
      ];
      final results = await Future.wait([
        for (final file in files)
          guest
              .uploadMedia(file, kind: MediaKind.audio)
              .then<Object?>((item) => item)
              .catchError((Object e) => e),
      ]);
      final accepted = results.whereType<MediaItem>().toList();
      final refused = results.whereType<HttpException>().toList();
      expect(accepted, hasLength(3), reason: 'only what fits the budget');
      expect(refused, hasLength(2));
      for (final e in refused) {
        expect(e.message, contains('507'));
      }
      expect(host.uploadedBytes, 3000);
      expect(host.playlist, hasLength(3));
    });

    test('an upload that dies mid-body refunds its reservation', () async {
      // A reservation that leaked on failure would be a slower version of
      // the same bug: the budget would drain without a byte being stored.
      final host = await startHost(
        maxUploadBytes: 4096,
        uploadBudgetBytes: 3000,
      );
      final guest = await joinGuest(host);

      final client = HttpClient();
      final req = await client.postUrl(
        Uri.parse('http://127.0.0.1:${host.port}/media'),
      );
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${host.token}');
      req.headers.set(JamGuestClient.uploadKeyHeader, guest.uploadKey!);
      req.headers.set('X-LocalJam-Kind', 'audio');
      req.contentLength = 2000;
      req.add(Uint8List(500));
      await req.flush();
      client.close(force: true); // Vanishes with 1500 bytes still promised.

      // The whole budget is available again, so a 2000-byte upload fits.
      await waitFor(() => host.uploadedBytes == 0, reason: 'nothing stored');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final item = await guest.uploadMedia(
        await writeTempMedia(makeMediaBytes(2000, seed: 7)),
        kind: MediaKind.audio,
      );
      expect(host.playlist.map((i) => i.mediaId), [item.mediaId]);
      expect(host.uploadedBytes, 2000);
    });

    test('uploads past maxPlaylistLength are answered 507', () async {
      final host = await startHost(maxPlaylistLength: 1);
      final guest = await joinGuest(host);
      await guest.uploadMedia(
        await writeTempMedia(makeMediaBytes(64, seed: 3)),
        kind: MediaKind.audio,
      );
      await expectLater(
        guest.uploadMedia(
          await writeTempMedia(makeMediaBytes(64, seed: 4)),
          kind: MediaKind.audio,
        ),
        throwsA(
          isA<HttpException>().having(
            (e) => e.message,
            'message',
            contains('507'),
          ),
        ),
      );
      expect(host.playlist, hasLength(1));
    });

    test('upload without a Content-Length is answered 411', () async {
      // A chunked body cannot be checked against any cap before it is read,
      // so it is refused outright — every LocalJam client declares a length.
      final host = await startHost();
      final guest = await joinGuest(host);
      final http = HttpClient();
      addTearDown(() => http.close(force: true));
      final req = await http.postUrl(
        Uri.parse('http://127.0.0.1:${host.port}/media'),
      );
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${host.token}');
      req.headers.set(JamGuestClient.uploadKeyHeader, guest.uploadKey!);
      req.headers.set('X-LocalJam-Kind', 'audio');
      req.add(makeMediaBytes(64));
      final res = await req.close();
      expect(res.statusCode, HttpStatus.lengthRequired);
      await res.drain<void>();
      expect(host.playlist, isEmpty);
    });

    test('upload over maxUploadBytes is answered 413', () async {
      final host = await startHost(maxUploadBytes: 100);
      final guest = await joinGuest(host);
      final file = await writeTempMedia(makeMediaBytes(1000));
      await expectLater(
        guest.uploadMedia(file, kind: MediaKind.audio),
        throwsA(
          isA<HttpException>().having(
            (e) => e.message,
            'message',
            contains('413'),
          ),
        ),
      );
      expect(host.playlist, isEmpty);
    });

    test('upload with a bad bearer token is answered 401', () async {
      final host = await startHost();
      final http = HttpClient();
      addTearDown(() => http.close(force: true));
      final req = await http.postUrl(
        Uri.parse('http://127.0.0.1:${host.port}/media'),
      );
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer wrong');
      req.headers.set('X-LocalJam-Kind', 'audio');
      req.add(makeMediaBytes(64));
      final res = await req.close();
      expect(res.statusCode, 401);
      await res.drain<void>();
      expect(host.playlist, isEmpty);
    });

    test('upload without a valid X-LocalJam-Kind is answered 400', () async {
      final host = await startHost();
      final http = HttpClient();
      addTearDown(() => http.close(force: true));
      final req = await http.postUrl(
        Uri.parse('http://127.0.0.1:${host.port}/media'),
      );
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${host.token}');
      req.add(makeMediaBytes(64));
      final res = await req.close();
      expect(res.statusCode, 400);
      await res.drain<void>();
      expect(host.playlist, isEmpty);
    });
  });

  group('permissions + queue (§5.6)', () {
    Future<MediaItem> addTrack(
      JamHostServer host, {
      int seed = 1,
      String? addedBy,
    }) async {
      final file = await writeTempMedia(makeMediaBytes(2048, seed: seed));
      final item = await JamHostServer.describeFile(
        file,
        kind: MediaKind.audio,
        mime: 'audio/mpeg',
        durationUs: 60_000_000,
        addedBy: addedBy,
      );
      host.addMedia(item, file);
      return item;
    }

    test(
      'welcome carries the document; guests derive their own caps',
      () async {
        final host = await startHost(policy: JamPolicy.jam);
        final guest = await joinGuest(host);
        expect(guest.permissions.rev, 0);
        expect(guest.permissions.policy, JamPolicy.jam);
        expect(guest.myCapabilities, {
          JamCapability.addTracks,
          JamCapability.editQueue,
        });
      },
    );

    test('playback request without controlPlayback: not_allowed error, '
        'requestDenied event, state untouched', () async {
      final host = await startHost(policy: JamPolicy.jam);
      await addTrack(host);
      host.setMedia(host.playlist.single.mediaId);
      final revBefore = host.snapshot.rev;

      final guest = await joinGuest(host);
      final errors = <ErrorMessage>[];
      guest.errors.listen(errors.add);
      final denied = <JamHostEvent>[];
      host.events.listen((e) {
        if (e.kind == JamHostEventKind.requestDenied) denied.add(e);
      });

      await guest.requestPlay();
      await waitFor(() => errors.isNotEmpty, reason: 'not_allowed error');
      expect(errors.single.code, ErrorCode.notAllowed);
      expect(errors.single.fatal, isFalse);
      expect(host.snapshot.rev, revBefore);
      expect(denied.single.peerId, guest.selfPeerId);
      expect(denied.single.deniedAction, RequestAction.play);
    });

    test('promote → cohost controls playback; demote revokes it; broadcasts '
        'reach guests in rev order', () async {
      final host = await startHost(policy: JamPolicy.listenOnly);
      await addTrack(host);
      host.setMedia(host.playlist.single.mediaId);

      final guest = await joinGuest(host);
      final docs = <JamPermissions>[];
      guest.permissionUpdates.listen(docs.add);
      final errors = <ErrorMessage>[];
      guest.errors.listen(errors.add);

      host.promotePeer(guest.selfPeerId);
      await waitFor(() => docs.isNotEmpty, reason: 'permissions broadcast');
      expect(docs.last.rev, 1);
      expect(guest.myCapabilities, JamPermissions.cohostCapabilities);

      await guest.requestPlay();
      await waitFor(
        () => guest.snapshot.status == PlaybackStatus.playing,
        reason: 'cohost play to apply',
      );
      expect(errors, isEmpty);

      host.demotePeer(guest.selfPeerId);
      await waitFor(() => docs.length >= 2, reason: 'demote broadcast');
      expect(guest.myCapabilities, isEmpty);
      await guest.requestPause();
      await waitFor(() => errors.isNotEmpty, reason: 'denied after demote');
      expect(errors.single.code, ErrorCode.notAllowed);
      expect(guest.snapshot.status, PlaybackStatus.playing);
    });

    test('upload gate (§6.4): listen-only guests get 403; overrides revoke '
        'one peer under an open policy', () async {
      final locked = await startHost(policy: JamPolicy.listenOnly);
      final guest = await joinGuest(locked);
      final file = await writeTempMedia(makeMediaBytes(512, seed: 3));
      await expectLater(
        guest.uploadMedia(file, kind: MediaKind.audio),
        throwsA(
          isA<HttpException>().having(
            (e) => e.message,
            'message',
            contains('403'),
          ),
        ),
      );
      expect(locked.playlist, isEmpty);

      final open = await startHost();
      final restricted = await joinGuest(open, clientName: 'restricted');
      final free = await joinGuest(open, clientName: 'free');
      open.setCapabilityOverride(
        restricted.selfPeerId,
        JamCapability.addTracks,
        allowed: false,
      );
      await expectLater(
        restricted.uploadMedia(file, kind: MediaKind.audio),
        throwsA(isA<HttpException>()),
      );
      final item = await free.uploadMedia(file, kind: MediaKind.audio);
      expect(item.addedBy, free.selfPeerId);
      expect(open.playlist.single.addedBy, free.selfPeerId);
    });

    test('queue ops: move reorders, remove drops, removing the current item '
        'advances and keeps playing', () async {
      final host = await startHost();
      final a = await addTrack(host, seed: 1);
      final b = await addTrack(host, seed: 2);
      final c = await addTrack(host, seed: 3);

      final guest = await joinGuest(host);
      await guest.requestQueueMove(c.mediaId, 0);
      await waitFor(
        () => guest.playlist.isNotEmpty && guest.playlist.first == c,
        reason: 'reordered playlist to reach the guest',
      );
      expect(host.playlist.map((i) => i.mediaId), [
        c.mediaId,
        a.mediaId,
        b.mediaId,
      ]);

      host.setMedia(a.mediaId);
      host.play();
      expect(host.snapshot.status, PlaybackStatus.playing);
      host.removeMediaItem(a.mediaId);
      // The item that slid into a's slot is next: b. Still playing.
      expect(host.snapshot.mediaId, b.mediaId);
      expect(host.snapshot.status, PlaybackStatus.playing);
      expect(host.playlist.map((i) => i.mediaId), [c.mediaId, b.mediaId]);

      // Removing the last remaining current item stops playback.
      host.removeMediaItem(b.mediaId);
      expect(host.snapshot.mediaId, c.mediaId);
      host.removeMediaItem(c.mediaId);
      expect(host.snapshot.status, PlaybackStatus.idle);
      expect(host.snapshot.mediaId, isNull);
    });

    test('queueRemove of your OWN track is allowed without editQueue; '
        'others\' tracks are refused', () async {
      final host = await startHost(policy: JamPolicy.listenOnly);
      final hostItem = await addTrack(host, seed: 9, addedBy: 'host');
      final guest = await joinGuest(host);

      // Simulate the guest's own earlier contribution.
      final own = await addTrack(host, seed: 10, addedBy: guest.selfPeerId);
      final errors = <ErrorMessage>[];
      guest.errors.listen(errors.add);

      await guest.requestQueueRemove(own.mediaId);
      await waitFor(
        () => host.playlist.every((i) => i.mediaId != own.mediaId),
        reason: 'own track removal to apply',
      );
      expect(errors, isEmpty);

      await guest.requestQueueRemove(hostItem.mediaId);
      await waitFor(() => errors.isNotEmpty, reason: 'denied removal');
      expect(errors.single.code, ErrorCode.notAllowed);
      expect(host.playlist.map((i) => i.mediaId), [hostItem.mediaId]);
    });

    test('next/previous requests skip under controlPlayback', () async {
      final host = await startHost();
      final a = await addTrack(host, seed: 1);
      final b = await addTrack(host, seed: 2);
      host.setMedia(a.mediaId);

      final guest = await joinGuest(host);
      await guest.requestNext();
      await waitFor(
        () => guest.snapshot.mediaId == b.mediaId,
        reason: 'next to apply',
      );
      await guest.requestPrevious();
      await waitFor(
        () => guest.snapshot.mediaId == a.mediaId,
        reason: 'previous to apply',
      );
      expect(host.snapshot.mediaId, a.mediaId);
    });

    test('next/previous keep a playing session playing, from 0 with a fresh '
        'anchor (§5.5 ADVANCE parity)', () async {
      final host = await startHost();
      final a = await addTrack(host, seed: 1);
      final b = await addTrack(host, seed: 2);
      final c = await addTrack(host, seed: 3);
      final guest = await joinGuest(host);

      host.setMedia(a.mediaId);
      host.play();
      await waitFor(
        () => guest.snapshot.status == PlaybackStatus.playing,
        reason: 'playing on a',
      );

      // The reported bug: next() selected the track and left the state at
      // `loading`, so every follower stopped and the transport flipped to
      // the play glyph.
      host.next();
      expect(host.snapshot.mediaId, b.mediaId);
      expect(host.snapshot.status, PlaybackStatus.playing);
      expect(host.snapshot.anchor, isNotNull);
      // A fresh scheduled start at position 0 (§5.3), not a carried-over one.
      expect(host.snapshot.anchor!.positionUs, 0);
      expect(host.snapshot.positionUs, 0);
      final untilAnchorUs = host.snapshot.anchor!.hostTimeUs - monotonicNowUs();
      expect(untilAnchorUs, greaterThan(400_000));
      expect(untilAnchorUs, lessThanOrEqualTo(750_000));
      // The position the anchor formula yields right now is still ~0: the
      // scheduled start has not arrived yet.
      expect(host.snapshot.positionAt(monotonicNowUs()), 0);

      // Guests land on the same playing state, not on `loading`.
      await waitFor(
        () =>
            guest.snapshot.mediaId == b.mediaId &&
            guest.snapshot.status == PlaybackStatus.playing,
        reason: 'guest playing b',
      );
      expect(guest.snapshot.anchor, isNotNull);

      // Previous is the same transition in the other direction, and wraps.
      host.previous();
      expect(host.snapshot.mediaId, a.mediaId);
      expect(host.snapshot.status, PlaybackStatus.playing);
      host.previous();
      expect(host.snapshot.mediaId, c.mediaId);
      expect(host.snapshot.status, PlaybackStatus.playing);

      // A guest's request travels the same path.
      await guest.requestNext();
      await waitFor(
        () =>
            guest.snapshot.mediaId == a.mediaId &&
            guest.snapshot.status == PlaybackStatus.playing,
        reason: 'guest-requested next keeps playing',
      );

      // Paused stays paused: skipping selects the track and does not start it.
      host.pause();
      expect(host.snapshot.status, PlaybackStatus.paused);
      host.next();
      expect(host.snapshot.mediaId, b.mediaId);
      expect(host.snapshot.status, isNot(PlaybackStatus.playing));
      expect(host.snapshot.anchor, isNull);
      expect(host.snapshot.positionUs, 0);
    });

    test(
      'a kicked peer\'s role is forgotten but a resumable drop keeps it',
      () async {
        final host = await startHost();
        final guest = await joinGuest(host);
        host.promotePeer(guest.selfPeerId);
        final revAfterPromote = host.permissions.rev;

        // A resumable drop (grace kept) leaves the role in place.
        host.kickPeer(guest.selfPeerId, allowResume: true);
        expect(host.permissions.cohosts, contains(guest.selfPeerId));
        expect(host.permissions.rev, revAfterPromote);
      },
    );
  });

  group('tag metadata + artwork (§6.1 v0.2, §6.5)', () {
    test('audio upload gets host-extracted tags, artwork, and tag duration '
        'when no duration header is sent', () async {
      final host = await startHost();
      final uploader = await joinGuest(host, clientName: 'uploader');

      final item = await uploader.uploadMedia(
        await makeTaggedMp3(),
        kind: MediaKind.audio,
        name: 'tagged.mp3',
        mime: 'audio/mpeg',
        // No durationUs: the host falls back to the tag-declared duration.
      );
      expect(item.title, 'Night Drive');
      expect(item.artist, 'The Localhosts');
      expect(item.album, 'Loopback Sessions');
      expect(item.durationUs, isNotNull);
      expect(item.durationUs, greaterThan(0));
      expect(item.artworkId, startsWith('a_'));
      expect(item.displayTitle, 'Night Drive');

      // The broadcast playlist carries the same tagged item.
      expect(host.playlist.single.title, 'Night Drive');
      expect(host.playlist.single.artworkId, item.artworkId);

      // A guest fetches the artwork bytes over the artwork plane.
      final artwork = await uploader.fetchArtwork(item.artworkId!);
      expect(artwork, isNotEmpty);
      // artworkId is content-derived from those exact bytes.
      final digest = sha256.convert(artwork).toString();
      expect(item.artworkId, 'a_${digest.substring(0, 12)}');
    });

    test('a declared upload duration wins over the tag duration', () async {
      final host = await startHost();
      final uploader = await joinGuest(host);
      final item = await uploader.uploadMedia(
        await makeTaggedMp3(),
        kind: MediaKind.audio,
        mime: 'audio/mpeg',
        durationUs: 1_234_567,
      );
      expect(item.durationUs, 1_234_567);
    });

    test('an untagged audio file is titled after its name, without the '
        'extension', () async {
      final host = await startHost();
      final uploader = await joinGuest(host);
      final uploaded = await uploader.uploadMedia(
        await makeUntaggedMp3(name: 'voice memo.mp3'),
        kind: MediaKind.audio,
        mime: 'audio/mpeg',
      );
      expect(uploaded.name, 'voice memo.mp3');
      expect(uploaded.title, 'voice memo');

      final described = await JamHostServer.describeFile(
        await makeUntaggedMp3(name: 'Night Drive.flac'),
        kind: MediaKind.audio,
      );
      expect(described.title, 'Night Drive');
      final tagged = await JamHostServer.describeFile(
        await makeUntaggedMp3(name: 'x.mp3'),
        kind: MediaKind.audio,
        title: 'Tagged',
      );
      expect(tagged.title, 'Tagged');
    });

    test('a non-audio upload skips tag extraction', () async {
      final host = await startHost();
      final uploader = await joinGuest(host);
      final item = await uploader.uploadMedia(
        await writeTempMedia(makeMediaBytes(256)),
        kind: MediaKind.image,
        mime: 'image/png',
      );
      expect(item.title, isNull);
      expect(item.artworkId, isNull);
    });

    test(
      'artwork endpoint: 401 without token, 404 for unknown id, no Range',
      () async {
        final host = await startHost();

        final http = HttpClient();
        addTearDown(() => http.close(force: true));
        Future<int> status(String path, {String? token}) async {
          final req = await http.getUrl(
            Uri(
              scheme: 'http',
              host: InternetAddress.loopbackIPv4.address,
              port: host.port,
              path: path,
            ),
          );
          if (token != null) {
            req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
          }
          final res = await req.close();
          await res.drain<void>();
          return res.statusCode;
        }

        expect(await status('/artwork/a_0123456789ab'), 401);
        expect(await status('/artwork/a_0123456789ab', token: 'wrong'), 401);
        expect(await status('/artwork/a_0123456789ab', token: host.token), 404);
      },
    );

    test('addArtwork is idempotent by content and serves the right bytes '
        'with the right Content-Type', () async {
      final host = await startHost();
      final bytes = makeMediaBytes(512, seed: 99);
      final id1 = await host.addArtwork(bytes, mime: 'image/jpeg');
      final id2 = await host.addArtwork(bytes, mime: 'image/jpeg');
      expect(id1, id2);
      expect(host.artworkFile(id1), isNotNull);

      final http = HttpClient();
      addTearDown(() => http.close(force: true));
      final req = await http.getUrl(
        Uri(
          scheme: 'http',
          host: InternetAddress.loopbackIPv4.address,
          port: host.port,
          path: '/artwork/$id1',
        ),
      );
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${host.token}');
      final res = await req.close();
      expect(res.statusCode, 200);
      expect(res.headers.contentType?.mimeType, 'image/jpeg');
      final body = <int>[];
      await for (final chunk in res) {
        body.addAll(chunk);
      }
      expect(body, equals(bytes));
    });
  });

  group('fetchMediaToFile', () {
    test('streams to disk, progress reaches 1.0, host sees ready', () async {
      final host = await startHost();
      final bytes = makeMediaBytes(64 * 1024);
      final file = await writeTempMedia(bytes);
      final item = await JamHostServer.describeFile(
        file,
        kind: MediaKind.audio,
      );
      host.addMedia(item, file);
      final guest = await joinGuest(host);

      final dir = await Directory.systemTemp.createTemp('localjam_dl');
      addTearDown(() => dir.delete(recursive: true));
      final dest = File('${dir.path}/track.bin');

      final progresses = <double>[];
      final result = await guest.fetchMediaToFile(
        item.mediaId,
        dest,
        onProgress: progresses.add,
      );
      expect(result.path, dest.path);
      expect(await dest.readAsBytes(), equals(bytes));
      expect(progresses.last, 1.0);

      await waitFor(
        () => host.allPeersReady(item.mediaId),
        reason: 'host to record readiness',
      );
    });

    test(
      'sha256 mismatch deletes the destination, reports none, throws',
      () async {
        final host = await startHost();
        final bytes = makeMediaBytes(8 * 1024);
        final file = await writeTempMedia(bytes);
        final honest = await JamHostServer.describeFile(
          file,
          kind: MediaKind.audio,
        );
        // Playlist advertises a digest the served bytes cannot match.
        final tampered = MediaItem(
          mediaId: honest.mediaId,
          kind: honest.kind,
          name: honest.name,
          mime: honest.mime,
          sizeBytes: honest.sizeBytes,
          durationUs: honest.durationUs,
          sha256: 'deadbeef' * 8,
        );
        host.addMedia(tampered, file);
        final guest = await joinGuest(host);

        final statuses = <JamHostEvent>[];
        host.events.listen((e) {
          if (e.kind == JamHostEventKind.peerMediaStatus) statuses.add(e);
        });

        final dir = await Directory.systemTemp.createTemp('localjam_dl');
        addTearDown(() => dir.delete(recursive: true));
        final dest = File('${dir.path}/track.bin');

        await expectLater(
          guest.fetchMediaToFile(tampered.mediaId, dest),
          throwsStateError,
        );
        // The partial file was cleaned up.
        expect(dest.existsSync(), isFalse);
        // The guest reported media_status none (§6.3), exactly like
        // fetchMedia.
        await waitFor(
          () => statuses.any((e) => e.mediaState == MediaFetchState.none),
          reason: 'none media_status after the mismatch',
        );
      },
    );

    test('rejects unknown media id', () async {
      final host = await startHost();
      final guest = await joinGuest(host);
      final dest = File('${Directory.systemTemp.path}/never_written.bin');
      expect(() => guest.fetchMediaToFile('m_nope', dest), throwsArgumentError);
    });

    test(
      'a body past the declared sizeBytes is abandoned mid-stream',
      () async {
        final host = await startHost();
        // The playlist under-declares by more than the slack: the guest must
        // stop writing rather than take whatever the host keeps sending.
        final bytes = makeMediaBytes(512 * 1024);
        final file = await writeTempMedia(bytes);
        final honest = await JamHostServer.describeFile(
          file,
          kind: MediaKind.audio,
        );
        final lying = MediaItem(
          mediaId: honest.mediaId,
          kind: honest.kind,
          name: honest.name,
          mime: honest.mime,
          sizeBytes: 1024,
          // Empty digest: the size check is what must fire, not the hash.
          sha256: '',
        );
        host.addMedia(lying, file);
        final guest = await joinGuest(host);

        final dir = await Directory.systemTemp.createTemp('localjam_dl');
        addTearDown(() => dir.delete(recursive: true));
        final dest = File('${dir.path}/track.bin');
        await expectLater(
          guest.fetchMediaToFile(lying.mediaId, dest),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('declared size'),
            ),
          ),
        );
        expect(dest.existsSync(), isFalse);
      },
    );
  });

  test('artwork past the guest-side cap is abandoned (§6.5)', () async {
    // Artwork is the one response a guest buffers whole, and nothing on the
    // wire declares its size — so the cap is the only bound.
    final host = await startHost();
    final oversized = Uint8List(JamGuestClient.maxArtworkBytes + 1024);
    final artworkId = await host.addArtwork(oversized, mime: 'image/png');
    final guest = await joinGuest(host);
    await expectLater(
      guest.fetchArtwork(artworkId),
      throwsA(
        isA<StateError>().having((e) => e.message, 'message', contains('cap')),
      ),
    );
  });

  test('wrong token on the control plane is rejected', () async {
    final host = await startHost();
    final ws = await WebSocket.connect('ws://127.0.0.1:${host.port}/ws');
    final frames = StreamQueue(ws);
    ws.add(
      _codec.encode(
        const HelloMessage(
          token: 'wrong',
          clientName: 'evil',
          clientKind: 'test',
        ),
        seq: 0,
      ),
    );
    final decoded = _codec.decode(await frames.next as String);
    expect(decoded.message, isA<RejectMessage>());
    expect((decoded.message as RejectMessage).reason, RejectReason.badToken);
    await frames.done; // Host closes after the reject.
    await ws.close();
  });

  group('returning devices (§3.3 clientId)', () {
    /// A socket that says hello and then never speaks again: an app
    /// force-quit or killed while backgrounded, whose FIN never arrives. The
    /// host cannot know it is dead until the silence timeout — which is the
    /// whole window in which a phantom can exist.
    Future<void> joinAndPlayDead(
      JamHostServer host, {
      required String clientName,
      String? clientId,
    }) async {
      final ws = await WebSocket.connect('ws://127.0.0.1:${host.port}/ws');
      ws.listen((_) {});
      addTearDown(() => ws.close().catchError((Object _) {}));
      ws.add(
        _codec.encode(
          HelloMessage(
            token: host.token,
            clientName: clientName,
            clientKind: 'flutter',
            clientId: clientId,
          ),
          seq: 0,
        ),
      );
      await waitFor(
        () => host.peers.any((p) => p.clientName == clientName),
        reason: '$clientName to join',
      );
    }

    test('a device that force-quits and rejoins replaces its own ghost, '
        'instead of haunting the roster next to itself', () async {
      // Long enough that the silence sweep cannot rescue us: the ghost is
      // still "connected" as far as the host knows when the device returns.
      final host = await startHost(silenceTimeout: const Duration(seconds: 30));
      await joinAndPlayDead(
        host,
        clientName: 'Quirky Toucan',
        clientId: 'c_device_a',
      );
      expect(host.peers, hasLength(1));

      // Same device, new process, new peerId — and the same clientId.
      final back = await joinGuest(
        host,
        clientName: 'Quirky Toucan',
        clientId: 'c_device_a',
      );

      expect(host.peers.map((p) => p.peerId), [
        back.selfPeerId,
      ], reason: 'the room is exactly {host, the returning guest}');
      expect(
        back.peers,
        isEmpty,
        reason: 'the rejoining guest is not handed a copy of itself',
      );
    });

    test('a kicked device stays out for the session; un-kicked, it rejoins '
        'as one plain peer (§5.6)', () async {
      final host = await startHost(silenceTimeout: const Duration(seconds: 30));
      final first = await joinGuest(
        host,
        clientName: 'Quirky Toucan',
        clientId: 'c_device_a',
      );
      final kickedId = first.selfPeerId;
      host.promotePeer(kickedId);
      host.kickPeer(kickedId);
      await waitFor(() => host.peers.isEmpty, reason: 'the kick to land');
      expect(host.kickedPeers.map((p) => p.peerId), [kickedId]);
      expect(host.kickedPeers.single.clientName, 'Quirky Toucan');

      // Rejoining immediately is refused with a reject a guest treats as
      // final — not a dropped socket it would retry forever.
      await expectLater(
        joinGuest(host, clientName: 'Quirky Toucan', clientId: 'c_device_a'),
        throwsA(
          isA<JamRejectedException>().having(
            (e) => e.reason,
            'reason',
            RejectReason.kicked,
          ),
        ),
      );
      expect(host.peers, isEmpty);
      // Other devices are unaffected.
      final other = await joinGuest(host, clientId: 'c_device_b');
      expect(host.peers.map((p) => p.peerId), [other.selfPeerId]);

      expect(host.unkickPeer('p_unknown'), isFalse);
      expect(host.unkickPeer(kickedId), isTrue);
      expect(host.kickedPeers, isEmpty);
      final back = await joinGuest(
        host,
        clientName: 'Quirky Toucan',
        clientId: 'c_device_a',
      );
      expect(host.peers, hasLength(2));
      expect(back.peers.map((p) => p.peerId), [other.selfPeerId]);
      // The kick took the co-host role with it.
      expect(host.permissions.cohosts, isEmpty);
    });

    test('two different devices sharing a display name both stay', () async {
      final host = await startHost();
      final a = await joinGuest(
        host,
        clientName: 'Quirky Toucan',
        clientId: 'c_device_a',
      );
      final b = await joinGuest(
        host,
        clientName: 'Quirky Toucan',
        clientId: 'c_device_b',
      );
      expect(host.peers, hasLength(2));
      expect(b.peers.map((p) => p.peerId), [a.selfPeerId]);
    });

    test('a v0.1 client without a clientId is left alone', () async {
      final host = await startHost();
      final a = await joinGuest(host, clientName: 'Quirky Toucan');
      final b = await joinGuest(host, clientName: 'Quirky Toucan');
      expect(host.peers, hasLength(2));
      expect(a.selfPeerId, isNot(b.selfPeerId));
    });
  });

  group('deliberate session end (§3.4)', () {
    test('close() announces session_ended and closes normally', () async {
      final host = await startHost();
      final guest = await joinGuest(host);
      expect(guest.sessionEnded, isNull);

      await host.close();

      await waitFor(
        () => guest.sessionEnded != null,
        timeout: const Duration(seconds: 1),
        reason: 'the goodbye to arrive within a second',
      );
      expect(guest.sessionEnded!.reason, SessionEndedReason.hostEnded);
      await guest.done;
    });

    test('close(announce: false) is a crash: silence only', () async {
      final host = await startHost();
      final guest = await joinGuest(host);

      await host.close(announce: false);
      await guest.done;
      expect(guest.sessionEnded, isNull);
    });

    test('an announced end is terminal for a reconnecting session', () async {
      final host = await startHost();
      final session = await JamGuestSession.connect(
        host.joinUriFor(InternetAddress.loopbackIPv4),
        backoff: JamBackoff(
          initialDelay: const Duration(milliseconds: 20),
          maxDelay: const Duration(milliseconds: 50),
          jitterRatio: 0,
        ),
      );
      addTearDown(session.close);

      await host.close();
      await waitFor(
        () => session.connectionState == JamConnectionState.failed,
        timeout: const Duration(seconds: 1),
        reason: 'the session to end without a reconnect round',
      );
      expect(session.hostEnded, isTrue);
    });
  });

  group('the host is a person (§3.1 welcome.host)', () {
    test('welcome carries the host identity, outside the peer list', () async {
      final host = await startHost(hostName: 'Silky Puffin');
      final guest = await joinGuest(host);

      expect(guest.hostPeer?.clientName, 'Silky Puffin');
      expect(guest.hostPeer?.peerId, JamPermissions.hostPeerId);
      expect(
        guest.peers,
        isEmpty,
        reason: 'the host is not a joined peer (§5.6)',
      );
    });

    test('an anonymous host sends an empty name, not a fake one', () async {
      final host = await startHost();
      final guest = await joinGuest(host);
      expect(guest.hostPeer?.clientName, isEmpty);
    });
  });

  test('peer_left is broadcast after a guest closes', () async {
    final host = await startHost();
    final g1 = await joinGuest(host, clientName: 'alice');
    final g2 = await joinGuest(host, clientName: 'bob');
    final g2Id = g2.selfPeerId;

    final leftEvent = g1.peerEvents
        .firstWhere((e) => e.kind == JamPeerEventKind.left)
        .timeout(const Duration(seconds: 5));
    final hostLeft = host.events
        .firstWhere((e) => e.kind == JamHostEventKind.peerLeft)
        .timeout(const Duration(seconds: 5));

    await g2.close();
    expect((await leftEvent).peerId, g2Id);
    expect((await hostLeft).peerId, g2Id);
    expect(g1.peers, isEmpty);
  });

  test(
    'silent peer is dropped after silenceTimeout and can resume in grace',
    () async {
      final host = await startHost(
        silenceTimeout: const Duration(milliseconds: 300),
        reconnectGrace: const Duration(seconds: 5),
        livenessCheckInterval: const Duration(milliseconds: 50),
      );

      // Raw socket that says hello and then goes silent (no clock pings).
      final ws = await WebSocket.connect('ws://127.0.0.1:${host.port}/ws');
      final frames = StreamQueue(ws);
      ws.add(
        _codec.encode(
          HelloMessage(
            token: host.token,
            clientName: 'sleepy',
            clientKind: 'test',
            clientId: 'device-sleepy',
          ),
          seq: 0,
        ),
      );
      final welcome =
          _codec.decode(await frames.next as String).message as WelcomeMessage;
      final peerId = welcome.selfPeerId;

      final dropped = host.events
          .firstWhere((e) => e.kind == JamHostEventKind.peerLeft)
          .timeout(const Duration(seconds: 3));
      expect((await dropped).peerId, peerId);
      await ws.close();

      // §3.3: reconnect with the same token + resumePeerId in hello resumes
      // the slot.
      final ws2 = await WebSocket.connect('ws://127.0.0.1:${host.port}/ws');
      final frames2 = StreamQueue(ws2);
      ws2.add(
        _codec.encode(
          HelloMessage(
            token: host.token,
            clientName: 'sleepy',
            clientKind: 'test',
            resumePeerId: peerId,
            // §3.3: the slot belongs to the device that held it, and this
            // is how the device proves it is that one.
            clientId: 'device-sleepy',
          ),
          seq: 0,
        ),
      );
      final welcome2 =
          _codec.decode(await frames2.next as String).message as WelcomeMessage;
      expect(welcome2.selfPeerId, peerId);
      await ws2.close();
    },
  );

  test(
    'a resume without the slot\'s clientId gets a fresh peer, not the role',
    () async {
      // §3.3/§9: peerIds are public — they ride `welcome.peers`,
      // `peer_joined` and `peer_left` — so any guest in the room can name a
      // co-host's id the moment it drops. If naming it were enough, the
      // grace window would be a 30-second offer of someone else's role.
      final host = await startHost(
        silenceTimeout: const Duration(milliseconds: 300),
        reconnectGrace: const Duration(seconds: 5),
        livenessCheckInterval: const Duration(milliseconds: 50),
      );

      Future<(WebSocket, StreamQueue, WelcomeMessage)> sayHello({
        required String name,
        String? clientId,
        String? resumePeerId,
      }) async {
        final ws = await WebSocket.connect('ws://127.0.0.1:${host.port}/ws');
        final frames = StreamQueue(ws);
        ws.add(
          _codec.encode(
            HelloMessage(
              token: host.token,
              clientName: name,
              clientKind: 'test',
              clientId: clientId,
              resumePeerId: resumePeerId,
            ),
            seq: 0,
          ),
        );
        final welcome =
            _codec.decode(await frames.next as String).message
                as WelcomeMessage;
        return (ws, frames, welcome);
      }

      // Guest A joins and is promoted to co-host, then dies without a FIN
      // (force-quit, phone off the network): the silence timeout reaps it and
      // its slot — role and all — sits in the grace window.
      final (wsA, _, welcomeA) = await sayHello(
        name: 'A',
        clientId: 'device-a',
      );
      final aId = welcomeA.selfPeerId;
      host.promotePeer(aId);
      expect(host.permissions.roleOf(aId), JamRole.cohost);
      final dropped = host.events
          .firstWhere((e) => e.kind == JamHostEventKind.peerLeft)
          .timeout(const Duration(seconds: 3));
      expect((await dropped).peerId, aId);

      // Guest B — a different device, holding the same room token, which is
      // all "possession of the QR" ever proved — claims A's slot.
      final (wsB, _, welcomeB) = await sayHello(
        name: 'B',
        clientId: 'device-b',
        resumePeerId: aId,
      );
      expect(
        welcomeB.selfPeerId,
        isNot(aId),
        reason: 'an unproven resume is a fresh join, not an inheritance',
      );
      expect(host.permissions.roleOf(welcomeB.selfPeerId), JamRole.guest);
      expect(
        host.permissions.allows(
          welcomeB.selfPeerId,
          JamCapability.manageMembers,
        ),
        isFalse,
      );
      // A's slot survived the theft attempt, role intact.
      expect(host.permissions.roleOf(aId), JamRole.cohost);

      // ...and A, back on the network, still gets it.
      final (wsA2, _, welcomeA2) = await sayHello(
        name: 'A',
        clientId: 'device-a',
        resumePeerId: aId,
      );
      expect(welcomeA2.selfPeerId, aId);
      expect(host.permissions.roleOf(aId), JamRole.cohost);

      await wsA.close();
      await wsB.close();
      await wsA2.close();
    },
  );

  test('a v0.1 client (no clientId) never resumes a slot', () async {
    // Documented in §3.3: proving identity is what a resume is now, and a
    // client that carries no identity cannot. It joins fresh instead.
    final host = await startHost(
      silenceTimeout: const Duration(milliseconds: 300),
      reconnectGrace: const Duration(seconds: 5),
      livenessCheckInterval: const Duration(milliseconds: 50),
    );
    final ws = await WebSocket.connect('ws://127.0.0.1:${host.port}/ws');
    final frames = StreamQueue(ws);
    ws.add(
      _codec.encode(
        HelloMessage(token: host.token, clientName: 'old', clientKind: 'test'),
        seq: 0,
      ),
    );
    final peerId =
        (_codec.decode(await frames.next as String).message as WelcomeMessage)
            .selfPeerId;
    await host.events
        .firstWhere((e) => e.kind == JamHostEventKind.peerLeft)
        .timeout(const Duration(seconds: 3));

    final ws2 = await WebSocket.connect('ws://127.0.0.1:${host.port}/ws');
    final frames2 = StreamQueue(ws2);
    ws2.add(
      _codec.encode(
        HelloMessage(
          token: host.token,
          clientName: 'old',
          clientKind: 'test',
          resumePeerId: peerId,
        ),
        seq: 0,
      ),
    );
    final welcome2 =
        _codec.decode(await frames2.next as String).message as WelcomeMessage;
    expect(welcome2.selfPeerId, isNot(peerId));
    await ws.close();
    await ws2.close();
  });

  test('per-peer readiness is retained across setMedia switches', () async {
    final host = await startHost();
    final file1 = await writeTempMedia(makeMediaBytes(2048, seed: 1));
    final file2 = await writeTempMedia(makeMediaBytes(2048, seed: 2));
    final item1 = await JamHostServer.describeFile(
      file1,
      kind: MediaKind.audio,
    );
    final item2 = await JamHostServer.describeFile(
      file2,
      kind: MediaKind.audio,
    );
    host.addMedia(item1, file1);
    host.addMedia(item2, file2);

    // g1 is a real guest that fully fetches m1 (-> ready).
    final g1 = await joinGuest(host, clientName: 'alice');
    await g1.fetchMedia(item1.mediaId);

    // g2 is a raw socket so we can hold it in `fetching` for m2.
    final ws = await WebSocket.connect('ws://127.0.0.1:${host.port}/ws');
    addTearDown(ws.close);
    final frames = StreamQueue(ws);
    ws.add(
      _codec.encode(
        HelloMessage(token: host.token, clientName: 'bob', clientKind: 'test'),
        seq: 0,
      ),
    );
    final welcome =
        _codec.decode(await frames.next as String).message as WelcomeMessage;
    final g2Id = welcome.selfPeerId;
    ws.add(
      _codec.encode(
        MediaStatusMessage(
          mediaId: item1.mediaId,
          state: MediaFetchState.ready,
        ),
        seq: 1,
      ),
    );
    await waitFor(
      () => host.allPeersReady(item1.mediaId),
      reason: 'both peers ready for m1',
    );

    // Switch tracks; g2 starts fetching m2.
    host.setMedia(item2.mediaId);
    ws.add(
      _codec.encode(
        MediaStatusMessage(
          mediaId: item2.mediaId,
          state: MediaFetchState.fetching,
          progress: 0.5,
        ),
        seq: 2,
      ),
    );
    await waitFor(
      () => host.peerMediaState(g2Id, item2.mediaId) == MediaReadiness.fetching,
      reason: 'g2 fetching m2',
    );

    // Readiness for m1 survived the switch and the m2 report.
    expect(host.allPeersReady(item1.mediaId), isTrue);
    expect(
      host.peerMediaState(g1.selfPeerId, item1.mediaId),
      MediaReadiness.ready,
    );
    expect(host.peerMediaState(g2Id, item1.mediaId), MediaReadiness.ready);
    expect(host.peerMediaStates(item1.mediaId), {
      g1.selfPeerId: MediaReadiness.ready,
      g2Id: MediaReadiness.ready,
    });
    expect(host.peerMediaStates(item2.mediaId), {
      g1.selfPeerId: MediaReadiness.none,
      g2Id: MediaReadiness.fetching,
    });
    expect(host.allPeersReady(item2.mediaId), isFalse);

    // Switching back changes nothing: readiness is per-file possession.
    host.setMedia(item1.mediaId);
    expect(host.allPeersReady(item1.mediaId), isTrue);
  });

  test('peerMediaStatus events carry the reported fetch progress', () async {
    final host = await startHost();
    final bytes = makeMediaBytes(64 * 1024);
    final file = await writeTempMedia(bytes);
    final item = await JamHostServer.describeFile(file, kind: MediaKind.audio);
    host.addMedia(item, file);
    final guest = await joinGuest(host);

    final statuses = <JamHostEvent>[];
    host.events.listen((e) {
      if (e.kind == JamHostEventKind.peerMediaStatus) statuses.add(e);
    });
    await guest.fetchMedia(item.mediaId);
    await waitFor(
      () => statuses.any((e) => e.mediaState == MediaFetchState.ready),
      reason: 'ready media_status event',
    );

    final fetching = statuses.firstWhere(
      (e) => e.mediaState == MediaFetchState.fetching,
    );
    expect(fetching.progress, isNotNull);
    expect(fetching.progress, inInclusiveRange(0.0, 1.0));
    final ready = statuses.firstWhere(
      (e) => e.mediaState == MediaFetchState.ready,
    );
    expect(ready.progress, isNull); // The ready report carries no progress.
  });

  group('sendMediaStatus (§6.3, direct report)', () {
    test(
      'reaches the host: peerMediaState updated, event carries it',
      () async {
        final host = await startHost();
        final file = await writeTempMedia(makeMediaBytes(2048));
        final item = await JamHostServer.describeFile(
          file,
          kind: MediaKind.audio,
        );
        host.addMedia(item, file);
        final guest = await joinGuest(host);

        final statusEvent = host.events
            .firstWhere((e) => e.kind == JamHostEventKind.peerMediaStatus)
            .timeout(const Duration(seconds: 5));

        guest.sendMediaStatus(item.mediaId, MediaFetchState.ready);

        final event = await statusEvent;
        expect(event.peerId, guest.selfPeerId);
        expect(event.mediaId, item.mediaId);
        expect(event.mediaState, MediaFetchState.ready);
        expect(
          host.peerMediaState(guest.selfPeerId, item.mediaId),
          MediaReadiness.ready,
        );
        expect(host.allPeersReady(item.mediaId), isTrue);
      },
    );

    test('the client sends any id; the host ignores ids it does not serve, '
        'so the readiness table cannot be grown with made-up ids', () async {
      final host = await startHost();
      final file = await writeTempMedia(makeMediaBytes(512));
      final item = await JamHostServer.describeFile(
        file,
        kind: MediaKind.audio,
      );
      host.addMedia(item, file);
      final guest = await joinGuest(host);

      final events = <JamHostEvent>[];
      host.events
          .where((e) => e.kind == JamHostEventKind.peerMediaStatus)
          .listen(events.add);
      for (var i = 0; i < 50; i++) {
        guest.sendMediaStatus(
          'm_made_up_$i',
          MediaFetchState.fetching,
          progress: 0.3,
        );
      }
      // Ordered after the junk on the same socket: once it lands, the junk
      // has been processed too.
      guest.sendMediaStatus(item.mediaId, MediaFetchState.ready);
      await waitFor(() => events.isNotEmpty, reason: 'the real report');

      expect(events.map((e) => e.mediaId), [item.mediaId]);
      expect(
        host.peerMediaState(guest.selfPeerId, 'm_made_up_0'),
        MediaReadiness.none,
      );
      expect(
        host.peerMediaState(guest.selfPeerId, item.mediaId),
        MediaReadiness.ready,
      );
    });
  });

  test('guest.done completes when the host closes', () async {
    final host = await startHost();
    final guest = await joinGuest(host);
    await host.close();
    await guest.done.timeout(const Duration(seconds: 5));
  });

  test('guest.done completes on local close()', () async {
    final host = await startHost();
    final guest = await joinGuest(host);
    await guest.close();
    await guest.done.timeout(const Duration(seconds: 5));
    // Idempotent: awaiting again (and closing again) is harmless.
    await guest.close();
    await guest.done;
  });

  group('end of media (§5.5)', () {
    // Short synthetic track: 300 ms duration, no scheduled-start lead, end
    // check every 20 ms.
    const durationUs = 300_000;
    const checkInterval = Duration(milliseconds: 20);

    Future<(JamHostServer, List<MediaItem>)> startEndedHost(
      JamEndPolicy policy, {
      int tracks = 1,
    }) async {
      final host = await startHost(
        leadTimeUs: 0,
        endPolicy: policy,
        livenessCheckInterval: checkInterval,
      );
      final items = <MediaItem>[];
      for (var i = 0; i < tracks; i++) {
        final file = await writeTempMedia(makeMediaBytes(1024, seed: i));
        final item = await JamHostServer.describeFile(
          file,
          kind: MediaKind.audio,
          durationUs: durationUs,
        );
        host.addMedia(item, file);
        items.add(item);
      }
      return (host, items);
    }

    test('pause policy freezes at exactly the duration', () async {
      final (host, items) = await startEndedHost(JamEndPolicy.pause);
      final guest = await joinGuest(host);

      final ended = <JamHostEvent>[];
      host.events.listen((e) {
        if (e.kind == JamHostEventKind.mediaEnded) ended.add(e);
      });

      host.setMedia(items.single.mediaId);
      host.play();
      await waitFor(
        () => host.snapshot.status == PlaybackStatus.paused,
        reason: 'end policy to pause',
      );
      expect(host.snapshot.positionUs, durationUs);
      expect(host.snapshot.anchor, isNull);
      expect(ended, hasLength(1));
      expect(ended.single.mediaId, items.single.mediaId);

      // Guests see only the ordinary state broadcast.
      await waitFor(
        () => guest.snapshot.status == PlaybackStatus.paused,
        reason: 'guest to converge on the paused-at-end state',
      );
      expect(guest.snapshot.positionUs, durationUs);
    });

    test('mediaEnded fires exactly once per end (no repeat firing)', () async {
      final (host, items) = await startEndedHost(JamEndPolicy.pause);
      final events = <JamHostEvent>[];
      host.events.listen(events.add);

      host.setMedia(items.single.mediaId);
      host.play();
      await waitFor(
        () => host.snapshot.status == PlaybackStatus.paused,
        reason: 'end policy to pause',
      );
      // The session stays ended (paused at the duration) across many further
      // check ticks; the event and the pause must not re-fire.
      final revAfterEnd = host.snapshot.rev;
      await Future<void>.delayed(checkInterval * 10);
      final ended = events.where((e) => e.kind == JamHostEventKind.mediaEnded);
      expect(ended, hasLength(1));
      expect(host.snapshot.rev, revAfterEnd);

      // A new end (replaying the same track) fires a fresh event.
      host.seek(0);
      host.play();
      await waitFor(
        () =>
            events.where((e) => e.kind == JamHostEventKind.mediaEnded).length ==
            2,
        reason: 'second end of the replayed track',
      );
    });

    test(
      'advance policy broadcasts setMedia(next) + playing, wrapping',
      () async {
        final (host, items) = await startEndedHost(
          JamEndPolicy.advance,
          tracks: 2,
        );
        final guest = await joinGuest(host);
        final events = <JamHostEvent>[];
        host.events.listen(events.add);

        host.setMedia(items[0].mediaId);
        host.play();
        await waitFor(
          () =>
              host.snapshot.mediaId == items[1].mediaId &&
              host.snapshot.status == PlaybackStatus.playing,
          reason: 'advance to track 2',
        );

        // The end event precedes the policy's state broadcasts (§5.5).
        final endedIdx = events.indexWhere(
          (e) => e.kind == JamHostEventKind.mediaEnded,
        );
        expect(endedIdx, isNonNegative);
        expect(events[endedIdx].mediaId, items[0].mediaId);
        final loadingIdx = events.indexWhere(
          (e) =>
              e.kind == JamHostEventKind.stateBroadcast &&
              e.snapshot!.mediaId == items[1].mediaId,
        );
        expect(loadingIdx, greaterThan(endedIdx));

        // Guests just see ordinary state broadcasts.
        await waitFor(
          () =>
              guest.snapshot.mediaId == items[1].mediaId &&
              guest.snapshot.status == PlaybackStatus.playing,
          reason: 'guest to follow the advance',
        );

        // Track 2 ends too: the playlist wraps back to track 1.
        await waitFor(
          () =>
              events
                  .where((e) => e.kind == JamHostEventKind.mediaEnded)
                  .length ==
              2,
          reason: 'track 2 to end',
        );
        await waitFor(
          () =>
              host.snapshot.mediaId == items[0].mediaId &&
              host.snapshot.status == PlaybackStatus.playing,
          reason: 'wrap back to track 1',
        );
      },
    );

    test('stop policy returns to idle with no media', () async {
      final (host, items) = await startEndedHost(JamEndPolicy.stop);
      host.setMedia(items.single.mediaId);
      host.play();
      await waitFor(
        () => host.snapshot.status == PlaybackStatus.idle,
        reason: 'end policy to stop',
      );
      expect(host.snapshot.mediaId, isNull);
      expect(host.snapshot.positionUs, 0);
    });

    test('request-driven seek beyond the duration clamps', () async {
      final (host, items) = await startEndedHost(JamEndPolicy.pause);
      final guest = await joinGuest(host);

      host.setMedia(items.single.mediaId);
      await guest.requestSeek(durationUs + 60_000_000);
      await waitFor(
        () => host.snapshot.positionUs == durationUs,
        reason: 'seek to clamp to the duration',
      );
      await waitFor(
        () => guest.snapshot.positionUs == durationUs,
        reason: 'guest to see the clamped position',
      );
    });
  });

  test('long-lived guest is kept alive by its clock-ping heartbeat', () async {
    final host = await startHost(
      silenceTimeout: const Duration(milliseconds: 600),
      livenessCheckInterval: const Duration(milliseconds: 50),
    );
    final guest = await JamGuestClient.connect(
      host.joinUriFor(InternetAddress.loopbackIPv4),
      pingInterval: const Duration(milliseconds: 200),
    );
    addTearDown(guest.close);

    var dropped = false;
    host.events.listen((e) {
      if (e.kind == JamHostEventKind.peerLeft) dropped = true;
    });
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    expect(dropped, isFalse);
    expect(host.peers, hasLength(1));
  });
}

/// Minimal async pull-queue over a stream (avoids a package:async dep).
class StreamQueue {
  StreamQueue(Stream<Object?> stream) {
    stream.listen(
      (data) {
        if (_waiters.isNotEmpty) {
          _waiters.removeAt(0).complete(data);
        } else {
          _events.add(data);
        }
      },
      onDone: _done.complete,
      onError: (Object e) {
        if (_waiters.isNotEmpty) {
          _waiters.removeAt(0).completeError(e);
        }
      },
    );
  }

  final List<Object?> _events = [];
  final List<Completer<Object?>> _waiters = [];
  final Completer<void> _done = Completer<void>();

  /// The next frame (waits up to 5 s).
  Future<Object?> get next {
    if (_events.isNotEmpty) {
      return Future.value(_events.removeAt(0));
    }
    final completer = Completer<Object?>();
    _waiters.add(completer);
    return completer.future.timeout(const Duration(seconds: 5));
  }

  /// Completes when the stream closes.
  Future<void> get done => _done.future.timeout(const Duration(seconds: 5));
}
