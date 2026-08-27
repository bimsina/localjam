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
  Duration silenceTimeout = const Duration(seconds: 10),
  Duration reconnectGrace = const Duration(seconds: 30),
  Duration livenessCheckInterval = const Duration(seconds: 1),
}) async {
  final host = JamHostServer(
    sessionName: sessionName,
    silenceTimeout: silenceTimeout,
    reconnectGrace: reconnectGrace,
    livenessCheckInterval: livenessCheckInterval,
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
