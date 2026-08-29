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
  int leadTimeUs = 750_000,
  JamEndPolicy endPolicy = JamEndPolicy.pause,
  Duration silenceTimeout = const Duration(seconds: 10),
  Duration reconnectGrace = const Duration(seconds: 30),
  Duration livenessCheckInterval = const Duration(seconds: 1),
  int maxUploadBytes = 512 * 1024 * 1024,
}) async {
  final host = JamHostServer(
    sessionName: sessionName,
    leadTimeUs: leadTimeUs,
    endPolicy: endPolicy,
    silenceTimeout: silenceTimeout,
    reconnectGrace: reconnectGrace,
    livenessCheckInterval: livenessCheckInterval,
    maxUploadBytes: maxUploadBytes,
  );
  await host.start(address: InternetAddress.loopbackIPv4);
  addTearDown(host.close);
  return host;
}

Future<JamGuestClient> joinGuest(
  JamHostServer host, {
  String clientName = 'guest',
}) async {
  final guest = await JamGuestClient.connect(
    host.joinUriFor(InternetAddress.loopbackIPv4),
    clientName: clientName,
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

  group('tag metadata + artwork (§6.1 v0.2, §6.5)', () {
    final taggedFixture = File('../../test-media/track1_tagged.m4a');

    test('audio upload gets host-extracted tags, artwork, and tag duration '
        'when no duration header is sent', () async {
      final host = await startHost();
      final uploader = await joinGuest(host, clientName: 'uploader');

      final item = await uploader.uploadMedia(
        taggedFixture,
        kind: MediaKind.audio,
        name: 'track1_tagged.m4a',
        mime: 'audio/mp4',
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
        taggedFixture,
        kind: MediaKind.audio,
        mime: 'audio/mp4',
        durationUs: 1_234_567,
      );
      expect(item.durationUs, 1_234_567);
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

    test('artwork endpoint: 401 without token, 404 for unknown id, no Range',
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
    });

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

    test(
      'is permissive about a mediaId outside the current playlist',
      () async {
        final host = await startHost();
        final guest = await joinGuest(host);

        final statusEvent = host.events
            .firstWhere((e) => e.kind == JamHostEventKind.peerMediaStatus)
            .timeout(const Duration(seconds: 5));
        guest.sendMediaStatus(
          'm_not_in_playlist',
          MediaFetchState.fetching,
          progress: 0.3,
        );
        final event = await statusEvent;
        expect(event.mediaId, 'm_not_in_playlist');
        expect(event.progress, 0.3);
        expect(
          host.peerMediaState(guest.selfPeerId, 'm_not_in_playlist'),
          MediaReadiness.fetching,
        );
      },
    );
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
