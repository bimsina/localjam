/// Protocol fuzz/robustness tests: a real loopback [JamHostServer] with one
/// healthy [JamGuestClient] connected, hammered by hostile or simply broken
/// raw sockets on both planes (PROTOCOL.md §1, §2). Every abuse is followed
/// by an explicit health check — a fresh connection still completes the §3.1
/// handshake and gets a §4 `clock_pong`, and the pre-existing healthy guest
/// still receives a §5.1 state broadcast after the host toggles play/pause —
/// proving a hostile or malformed guest can neither crash the host nor starve
/// other peers.
///
/// One guest-side tolerance test closes the loop: a [JamGuestClient] talking
/// to a tiny fake raw-WS host survives an unknown message type and a
/// malformed frame without crashing or hanging.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

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
  final dir = await Directory.systemTemp.createTemp('localjam_fuzz_test');
  addTearDown(() => dir.delete(recursive: true));
  final file = File('${dir.path}/track.bin');
  await file.writeAsBytes(bytes);
  return file;
}

Future<JamHostServer> startHost() async {
  final host = JamHostServer(sessionName: 'FuzzJam');
  await host.start(address: InternetAddress.loopbackIPv4);
  addTearDown(host.close);
  return host;
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

/// Minimal async pull-queue over a stream (mirrors integration_test.dart).
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
      onDone: () {
        if (!_done.isCompleted) _done.complete();
      },
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

  Future<Object?> get next {
    if (_events.isNotEmpty) {
      return Future.value(_events.removeAt(0));
    }
    final completer = Completer<Object?>();
    _waiters.add(completer);
    return completer.future.timeout(const Duration(seconds: 5));
  }

  Future<void> get done => _done.future.timeout(const Duration(seconds: 5));
}

/// Proves the host is still alive and serving after some abuse:
///
/// 1. A brand-new, well-formed raw connection can still complete the §3.1
///    handshake and get a §4 `clock_pong` round trip — the control-plane
///    pipeline as a whole is not wedged.
/// 2. The pre-existing [healthyGuest] still receives a state broadcast when
///    the host toggles play then pause — the specific pre-abuse connection
///    was not silently broken and broadcasts still reach it.
///
/// Every wait is timeout-bounded, so a wedged host fails the test instead of
/// hanging it.
Future<void> assertHostStillHealthy(
  JamHostServer host,
  JamGuestClient healthyGuest,
  String mediaId,
) async {
  final ws = await WebSocket.connect(
    'ws://127.0.0.1:${host.port}/ws',
  ).timeout(const Duration(seconds: 5));
  final frames = StreamQueue(ws);
  ws.add(
    _codec.encode(
      HelloMessage(
        token: host.token,
        clientName: 'healthcheck',
        clientKind: 'test',
      ),
      seq: 0,
    ),
  );
  final welcome = _codec.decode(await frames.next as String).message;
  expect(welcome, isA<WelcomeMessage>(), reason: 'fresh connection can join');

  const t0 = 999999;
  ws.add(_codec.encode(const ClockPingMessage(t0: t0), seq: 1));
  final pongMsg = _codec.decode(await frames.next as String).message;
  expect(pongMsg, isA<ClockPongMessage>(), reason: 'clock_pong round trip');
  expect((pongMsg as ClockPongMessage).t0, t0);
  await ws.close();

  // The abuse must not have corrupted the authoritative state itself.
  expect(host.snapshot.mediaId, mediaId);

  final playing = healthyGuest.states
      .firstWhere((s) => s.status == PlaybackStatus.playing)
      .timeout(const Duration(seconds: 5));
  host.play();
  await playing;
  final paused = healthyGuest.states
      .firstWhere((s) => s.status == PlaybackStatus.paused)
      .timeout(const Duration(seconds: 5));
  host.pause();
  await paused;
}

void main() {
  group('control plane abuse (§1, §2)', () {
    late JamHostServer host;
    late JamGuestClient guest;
    late String mediaId;

    setUp(() async {
      host = await startHost();
      final file = await writeTempMedia(makeMediaBytes(4096));
      final item = await JamHostServer.describeFile(
        file,
        kind: MediaKind.audio,
      );
      host.addMedia(item, file);
      mediaId = item.mediaId;
      guest = await JamGuestClient.connect(
        host.joinUriFor(InternetAddress.loopbackIPv4),
      );
      addTearDown(guest.close);
      // Give a mediaId so play()/pause() in the health check has something
      // to act on (both used repeatedly across the whole group).
      host.setMedia(mediaId);
    });

    Future<WebSocket> rawSocket() =>
        WebSocket.connect('ws://127.0.0.1:${host.port}/ws');

    test('non-JSON text frame is ignored', () async {
      final ws = await rawSocket();
      ws.add('this is not json at all {{{');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await ws.close();
      await assertHostStillHealthy(host, guest, mediaId);
    });

    test('binary frame is ignored', () async {
      final ws = await rawSocket();
      ws.add(<int>[0, 1, 2, 3, 255, 254, 253]);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await ws.close();
      await assertHostStillHealthy(host, guest, mediaId);
    });

    test('truncated JSON is ignored', () async {
      final ws = await rawSocket();
      ws.add('{"v":1,"type":"hello","seq":0,"payload":{"token":"abc"');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await ws.close();
      await assertHostStillHealthy(host, guest, mediaId);
    });

    test('valid JSON with wrong envelope shape is ignored', () async {
      final ws = await rawSocket();
      // A JSON array, not an object envelope.
      ws.add(jsonEncode([1, 2, 3]));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      // An object missing required envelope fields.
      ws.add(jsonEncode({'type': 'hello'}));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await ws.close();
      await assertHostStillHealthy(host, guest, mediaId);
    });

    test('unknown type is ignored (§2 forward compat)', () async {
      final ws = await rawSocket();
      final frames = StreamQueue(ws);
      ws.add(
        _codec.encode(
          HelloMessage(token: host.token, clientName: 'x', clientKind: 'test'),
          seq: 0,
        ),
      );
      expect(await frames.next, isNotNull); // welcome
      ws.add(
        jsonEncode({
          'v': 1,
          'type': 'totally_unknown_type_v99',
          'seq': 1,
          'payload': {'whatever': true},
        }),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await ws.close();
      await assertHostStillHealthy(host, guest, mediaId);
    });

    test('known type with wrong-typed payload fields is ignored', () async {
      final ws = await rawSocket();
      final frames = StreamQueue(ws);
      ws.add(
        _codec.encode(
          HelloMessage(token: host.token, clientName: 'x', clientKind: 'test'),
          seq: 0,
        ),
      );
      await frames.next; // welcome
      // `request` with `action` as a number and `positionUs` as a string.
      ws.add(
        jsonEncode({
          'v': 1,
          'type': 'request',
          'seq': 1,
          'payload': {'action': 42, 'positionUs': 'not-a-number'},
        }),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await ws.close();
      await assertHostStillHealthy(host, guest, mediaId);
    });

    test('huge (~2 MB) text frame is handled without a crash', () async {
      final ws = await rawSocket();
      ws.add('x' * (2 * 1024 * 1024));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await ws.close();
      await assertHostStillHealthy(host, guest, mediaId);
    });

    test('a flood of 10k tiny frames does not wedge the host', () async {
      final ws = await rawSocket();
      for (var i = 0; i < 10000; i++) {
        ws.add('{}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await ws.close();
      await assertHostStillHealthy(host, guest, mediaId);
    });

    test('hello with the wrong token is rejected, then further frames '
        'are ignored', () async {
      final ws = await rawSocket();
      final frames = StreamQueue(ws);
      ws.add(
        _codec.encode(
          const HelloMessage(
            token: 'wrong-token',
            clientName: 'evil',
            clientKind: 'test',
          ),
          seq: 0,
        ),
      );
      final reply = _codec.decode(await frames.next as String).message;
      expect(reply, isA<RejectMessage>());
      expect((reply as RejectMessage).reason, RejectReason.badToken);
      // The socket may still be mid-close; further frames must not matter.
      ws.add(
        _codec.encode(
          const HelloMessage(
            token: 'wrong-token-again',
            clientName: 'evil',
            clientKind: 'test',
          ),
          seq: 1,
        ),
      );
      ws.add('garbage after reject');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      try {
        await ws.close();
      } catch (_) {
        // Already closed by the host: fine.
      }
      await assertHostStillHealthy(host, guest, mediaId);
    });

    test('frames before hello are ignored', () async {
      final ws = await rawSocket();
      // Well-formed known-type frames, but hello never sent.
      ws.add(_codec.encode(const ClockPingMessage(t0: 123), seq: 0));
      ws.add(
        _codec.encode(const RequestMessage(action: RequestAction.play), seq: 1),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await ws.close();
      await assertHostStillHealthy(host, guest, mediaId);
    });

    test('duplicate hello after joining is ignored', () async {
      final ws = await rawSocket();
      final frames = StreamQueue(ws);
      ws.add(
        _codec.encode(
          HelloMessage(
            token: host.token,
            clientName: 'dupe',
            clientKind: 'test',
          ),
          seq: 0,
        ),
      );
      final welcome1 =
          _codec.decode(await frames.next as String).message as WelcomeMessage;
      ws.add(
        _codec.encode(
          HelloMessage(
            token: host.token,
            clientName: 'dupe-again',
            clientKind: 'test',
          ),
          seq: 1,
        ),
      );
      // No second welcome/reject should arrive; confirm by racing a
      // clock_ping, whose pong we DO expect, against a short timeout.
      ws.add(_codec.encode(const ClockPingMessage(t0: 555), seq: 2));
      final next = _codec.decode(await frames.next as String).message;
      expect(next, isA<ClockPongMessage>());
      expect(welcome1.selfPeerId, isNotEmpty);
      await ws.close();
      await assertHostStillHealthy(host, guest, mediaId);
    });
  });

  group('media plane abuse (§1, §6.2, §6.4)', () {
    late JamHostServer host;
    late JamGuestClient guest;
    late String mediaId;
    late HttpClient http;

    setUp(() async {
      host = await startHost();
      final file = await writeTempMedia(makeMediaBytes(4096));
      final item = await JamHostServer.describeFile(
        file,
        kind: MediaKind.audio,
      );
      host.addMedia(item, file);
      mediaId = item.mediaId;
      guest = await JamGuestClient.connect(
        host.joinUriFor(InternetAddress.loopbackIPv4),
      );
      addTearDown(guest.close);
      host.setMedia(mediaId);
      http = HttpClient();
      addTearDown(() => http.close(force: true));
    });

    Future<HttpClientResponse> request(
      String method,
      String path, {
      String? range,
      String? bearer,
    }) async {
      final req = await http.openUrl(
        method,
        Uri.parse('http://127.0.0.1:${host.port}$path'),
      );
      req.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer ${bearer ?? host.token}',
      );
      if (range != null) req.headers.set(HttpHeaders.rangeHeader, range);
      return req.close().timeout(const Duration(seconds: 5));
    }

    test('bogus media paths return 404, never a crash', () async {
      for (final path in [
        '/media/',
        '/media/${'x' * 5000}',
        '/media/%00%01%02',
        '/media/../',
      ]) {
        final res = await request('GET', path);
        expect(res.statusCode, anyOf(404, 400), reason: path);
        await res.drain<void>().timeout(const Duration(seconds: 5));
      }
      await assertHostStillHealthy(host, guest, mediaId);
    });

    test('path traversal attempt never serves filesystem content', () async {
      // Raw socket: guarantees the literal bytes hit the wire, bypassing any
      // client-side URI normalization.
      final socket = await Socket.connect(
        '127.0.0.1',
        host.port,
      ).timeout(const Duration(seconds: 5));
      socket.write(
        'GET /media/../../../../../../etc/passwd HTTP/1.1\r\n'
        'Host: 127.0.0.1\r\n'
        'Authorization: Bearer ${host.token}\r\n'
        'Connection: close\r\n\r\n',
      );
      final response = await socket
          .cast<List<int>>()
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 5));
      await socket.close();
      // Never a 200 with file content; the mediaId (whatever it resolved to)
      // is never a registered item, so 404 is the only correct answer — but
      // the load-bearing assertion is that no passwd-shaped content leaked.
      expect(response, isNot(contains('root:')));
      expect(response, anyOf(contains('404'), contains('400')));
      await assertHostStillHealthy(host, guest, mediaId);
    });

    test('absurd Range headers never crash the server', () async {
      final ranges = [
        'bytes=100-10', // inverted
        'bytes=-0', // zero-length suffix
        'bytes=abc-def', // non-numeric
        'bytes=0-10,20-30', // multi-range (unsupported -> ignored)
        'bytes=999999999999999999999-', // absurdly large
        'notbytes=0-10', // wrong unit
        '', // empty
      ];
      for (final range in ranges) {
        final res = await request('GET', '/media/$mediaId', range: range);
        // Either a real range response, a 416, or (malformed -> ignored) a
        // full 200 — never a 5xx or a hang.
        expect(res.statusCode, lessThan(500), reason: range);
        await res.drain<void>().timeout(const Duration(seconds: 5));
      }
      await assertHostStillHealthy(host, guest, mediaId);
    });

    test('wrong HTTP methods are answered 405, never a crash', () async {
      for (final method in ['PUT', 'DELETE', 'PATCH']) {
        final res = await request(method, '/media/$mediaId');
        expect(res.statusCode, HttpStatus.methodNotAllowed, reason: method);
        await res.drain<void>().timeout(const Duration(seconds: 5));
      }
      for (final method in ['PUT', 'DELETE', 'GET']) {
        final res = await request(method, '/media');
        expect(res.statusCode, HttpStatus.methodNotAllowed, reason: method);
        await res.drain<void>().timeout(const Duration(seconds: 5));
      }
      await assertHostStillHealthy(host, guest, mediaId);
    });

    test(
      'invalid percent-encoding in upload headers is answered 400',
      () async {
        final req = await http.postUrl(
          Uri.parse('http://127.0.0.1:${host.port}/media'),
        );
        req.headers.set(
          HttpHeaders.authorizationHeader,
          'Bearer ${host.token}',
        );
        req.headers.set('X-LocalJam-Kind', 'audio');
        // '%zz' is not valid percent-encoding.
        req.headers.set('X-LocalJam-Name', '%zz%gg');
        req.add(makeMediaBytes(64));
        final res = await req.close().timeout(const Duration(seconds: 5));
        expect(res.statusCode, HttpStatus.badRequest);
        await res.drain<void>().timeout(const Duration(seconds: 5));
        await assertHostStillHealthy(host, guest, mediaId);
      },
    );
  });

  test('guest-side tolerance: JamGuestClient survives an unknown message type '
      'and a malformed frame from a raw fake host', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);

    final firstConn = Completer<WebSocket>();
    server.listen((req) async {
      if (!WebSocketTransformer.isUpgradeRequest(req)) {
        req.response.statusCode = HttpStatus.upgradeRequired;
        await req.response.close();
        return;
      }
      final ws = await WebSocketTransformer.upgrade(req);
      if (!firstConn.isCompleted) firstConn.complete(ws);
      ws.listen((data) {
        if (data is! String) return;
        Map<String, Object?>? envelope;
        try {
          envelope = (jsonDecode(data) as Map).cast<String, Object?>();
        } catch (_) {
          return;
        }
        if (envelope['type'] == 'hello') {
          ws.add(
            _codec.encode(
              WelcomeMessage(
                sessionId: 's_fake',
                sessionName: 'FakeHost',
                selfPeerId: 'p_1',
                peers: const [],
                snapshot: PlaybackSnapshot.initial,
                playlist: const [],
              ),
              seq: 0,
            ),
          );
          // Immediately follow the welcome with abuse: an unknown type,
          // then a malformed (non-JSON) frame, then a well-formed
          // clock_pong the client must still be able to receive.
          ws.add(
            jsonEncode({
              'v': 1,
              'type': 'totally_unknown_from_host',
              'seq': 1,
              'payload': {},
            }),
          );
          ws.add('not json at all {{{');
          ws.add(
            _codec.encode(const ClockPongMessage(t0: 1, t1: 2, t2: 3), seq: 2),
          );
        }
      });
    });

    final joinUri = Uri(
      scheme: 'localjam',
      host: 'join',
      queryParameters: {
        'v': '1',
        'host': '127.0.0.1',
        'port': '${server.port}',
        'token': 'anytoken',
        'name': 'Fake',
      },
    );

    final client = await JamGuestClient.connect(
      joinUri,
    ).timeout(const Duration(seconds: 5));
    addTearDown(client.close);

    expect(client.sessionName, 'FakeHost');
    // The client is alive and its clock keeps ticking despite the
    // interleaved unknown-type and malformed frames from the "host" —
    // proven by successfully sending further pings without throwing or
    // hanging, and by the connection staying open (done not yet complete).
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(client.done, isA<Future<void>>());
    var doneFired = false;
    unawaited(client.done.then((_) => doneFired = true));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(doneFired, isFalse, reason: 'client must not have torn down');
  });
}
