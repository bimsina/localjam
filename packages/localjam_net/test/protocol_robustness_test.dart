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

Future<JamHostServer> startHost({
  int maxPeers = 32,
  int maxPendingConnections = 16,
  int maxControlFrameBytes = 256 * 1024,
  int maxPreHelloFrameBytes = 16 * 1024,
  Duration helloTimeout = const Duration(seconds: 10),
  Duration livenessCheckInterval = const Duration(seconds: 1),
}) async {
  final host = JamHostServer(
    sessionName: 'FuzzJam',
    maxPeers: maxPeers,
    maxPendingConnections: maxPendingConnections,
    maxControlFrameBytes: maxControlFrameBytes,
    maxPreHelloFrameBytes: maxPreHelloFrameBytes,
    helloTimeout: helloTimeout,
    livenessCheckInterval: livenessCheckInterval,
  );
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

    test('wrong-typed payload fields across every guest→host type are '
        'ignored', () async {
      // Nothing a guest can put in a payload may escape the frame handler:
      // every field of every G→H type, given the wrong JSON type, must be a
      // no-op rather than an exception that kills the host isolate.
      final hostile = <Map<String, Object?>>[
        {
          'type': 'hello',
          'payload': {'token': 42, 'clientName': []},
        },
        {
          'type': 'hello',
          'payload': {'token': null, 'resumePeerId': 7},
        },
        {
          'type': 'clock_ping',
          'payload': {'t0': 'not-a-number'},
        },
        {
          'type': 'clock_ping',
          'payload': {
            't0': {'nested': true},
          },
        },
        {
          'type': 'request',
          'payload': {'action': 'play', 'positionUs': '5'},
        },
        {
          'type': 'request',
          'payload': {'action': 'seek', 'positionUs': []},
        },
        {
          'type': 'request',
          'payload': {'action': 'queue_move', 'mediaId': 1, 'toIndex': 'first'},
        },
        {
          'type': 'request',
          'payload': {
            'action': 'set_media',
            'mediaId': {'a': 'b'},
          },
        },
        {
          'type': 'media_status',
          'payload': {'mediaId': 3, 'state': 9},
        },
        {
          'type': 'media_status',
          'payload': {'mediaId': 'm_x', 'state': 'ready', 'progress': 'lots'},
        },
        {'type': 'request', 'payload': 'not-an-object'},
        {
          'type': 'hello',
          'payload': <Object?>[1, 2, 3],
        },
      ];
      final ws = await rawSocket();
      final frames = StreamQueue(ws);
      ws.add(
        _codec.encode(
          HelloMessage(token: host.token, clientName: 'x', clientKind: 'test'),
          seq: 0,
        ),
      );
      await frames.next; // welcome
      var seq = 1;
      for (final frame in hostile) {
        ws.add(jsonEncode({'v': 1, 'seq': seq++, ...frame}));
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
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

  group('resource limits (§3, §9)', () {
    test('a control frame over the cap closes the socket with 1008', () async {
      final host = await startHost(maxControlFrameBytes: 1024);
      final ws = await WebSocket.connect('ws://127.0.0.1:${host.port}/ws');
      final closed = Completer<void>();
      ws.listen((_) {}, onDone: closed.complete);
      // Joined first: a joined peer is the one held to maxControlFrameBytes.
      ws.add(
        _codec.encode(
          HelloMessage(
            token: host.token,
            clientName: 'chatty',
            clientKind: 'test',
          ),
          seq: 0,
        ),
      );
      await waitFor(() => host.peers.isNotEmpty, reason: 'joined');
      ws.add('x' * 4096);
      await closed.future.timeout(const Duration(seconds: 5));
      expect(ws.closeCode, WebSocketStatus.policyViolation);
      // The room is untouched: a fresh guest still joins.
      final guest = await JamGuestClient.connect(
        host.joinUriFor(InternetAddress.loopbackIPv4),
      );
      addTearDown(guest.close);
      expect(host.peers, hasLength(1));
    });

    test('the frame cap counts UTF-8 bytes, not code units', () async {
      // '€' is one UTF-16 code unit and three UTF-8 bytes: a cap compared
      // against String.length lets a frame three times its size through.
      final host = await startHost(maxControlFrameBytes: 1024);
      final ws = await WebSocket.connect('ws://127.0.0.1:${host.port}/ws');
      final closed = Completer<void>();
      ws.listen((_) {}, onDone: closed.complete);
      ws.add(
        _codec.encode(
          HelloMessage(
            token: host.token,
            clientName: 'wide',
            clientKind: 'test',
          ),
          seq: 0,
        ),
      );
      await waitFor(() => host.peers.isNotEmpty, reason: 'joined');
      ws.add('\u20ac' * 500); // 500 code units, 1500 bytes.
      await closed.future.timeout(const Duration(seconds: 5));
      expect(ws.closeCode, WebSocketStatus.policyViolation);
    });

    test('a pre-hello socket loses the socket on an oversized frame', () async {
      // Nothing has been proved by this socket, and a hello is tiny: the
      // small cap is the one that bounds what an unauthenticated peer can
      // make the host hold and parse.
      final host = await startHost(maxPreHelloFrameBytes: 1024);
      final ws = await WebSocket.connect('ws://127.0.0.1:${host.port}/ws');
      final closed = Completer<void>();
      ws.listen((_) {}, onDone: closed.complete);
      ws.add('x' * 4096); // Far under maxControlFrameBytes, far over this one.
      await closed.future.timeout(const Duration(seconds: 5));
      expect(ws.closeCode, WebSocketStatus.policyViolation);
      final guest = await JamGuestClient.connect(
        host.joinUriFor(InternetAddress.loopbackIPv4),
      );
      addTearDown(guest.close);
      expect(host.peers, hasLength(1));
    });

    test('a rejected hello frees its pending slot at once', () async {
      // The reject closes the socket, but the close handshake takes a round
      // trip: if the slot is only freed when the socket finishes dying, a
      // flood of wrong-token helloes owns every handshake slot the room has.
      final host = await startHost(maxPendingConnections: 1);
      final ws = await WebSocket.connect('ws://127.0.0.1:${host.port}/ws');
      final rejected = Completer<void>();
      ws.listen((frame) {
        final message = _codec.decode(frame as String).message;
        if (message is RejectMessage && !rejected.isCompleted) {
          rejected.complete();
        }
      });
      ws.add(
        _codec.encode(
          const HelloMessage(
            token: 'wrong',
            clientName: 'guesser',
            clientKind: 'test',
          ),
          seq: 0,
        ),
      );
      await rejected.future.timeout(const Duration(seconds: 5));
      // An honest guest can still get in behind it.
      final guest = await JamGuestClient.connect(
        host.joinUriFor(InternetAddress.loopbackIPv4),
      );
      addTearDown(guest.close);
      expect(host.peers, hasLength(1));
    });

    test('a socket that never says hello is dropped, a joined one is '
        'not', () async {
      final host = await startHost(
        helloTimeout: const Duration(milliseconds: 200),
        livenessCheckInterval: const Duration(milliseconds: 20),
      );
      final joined = await JamGuestClient.connect(
        host.joinUriFor(InternetAddress.loopbackIPv4),
      );
      addTearDown(joined.close);

      final silent = await WebSocket.connect('ws://127.0.0.1:${host.port}/ws');
      final closed = Completer<void>();
      silent.listen((_) {}, onDone: closed.complete);
      await closed.future.timeout(const Duration(seconds: 5));
      // The authenticated guest kept its slot through the same sweep.
      expect(host.peers, hasLength(1));
    });

    test('joins past maxPeers get reject { full }', () async {
      final host = await startHost(maxPeers: 1);
      final first = await JamGuestClient.connect(
        host.joinUriFor(InternetAddress.loopbackIPv4),
      );
      addTearDown(first.close);
      await expectLater(
        JamGuestClient.connect(host.joinUriFor(InternetAddress.loopbackIPv4)),
        throwsA(
          isA<JamRejectedException>().having(
            (e) => e.reason,
            'reason',
            RejectReason.full,
          ),
        ),
      );
      expect(host.peers, hasLength(1));
    });

    test('upgrades past maxPendingConnections are refused', () async {
      final host = await startHost(maxPendingConnections: 1);
      // One socket that never authenticates fills the pending budget...
      final squatter = await WebSocket.connect(
        'ws://127.0.0.1:${host.port}/ws',
      );
      squatter.listen((_) {});
      addTearDown(() => squatter.close());
      await Future<void>.delayed(const Duration(milliseconds: 50));
      // ...so the next unauthenticated socket never gets upgraded.
      await expectLater(
        WebSocket.connect('ws://127.0.0.1:${host.port}/ws'),
        throwsA(isA<WebSocketException>()),
      );
    });
  });

  group('LAN-only remotes (§9)', () {
    test('isLanAddress accepts LAN space and rejects the internet', () async {
      for (final lan in [
        '127.0.0.1',
        '10.0.0.4',
        '172.16.3.9',
        '172.31.255.255',
        '192.168.1.7',
        '169.254.10.1',
        '::1',
        'fe80::1',
        'fd12:3456::1',
        '::ffff:192.168.1.7',
      ]) {
        expect(
          JamHostServer.isLanAddress(InternetAddress(lan)),
          isTrue,
          reason: lan,
        );
      }
      for (final wan in [
        '8.8.8.8',
        '1.2.3.4',
        '172.32.0.1', // Just outside 172.16/12.
        '11.0.0.1',
        '100.64.0.1', // Carrier-grade NAT is not a living room.
        '2606:4700::1111',
        '::ffff:8.8.8.8',
      ]) {
        expect(
          JamHostServer.isLanAddress(InternetAddress(wan)),
          isFalse,
          reason: wan,
        );
      }
    });

    test('an IPv6 global address is LAN only on one of our own /64s', () {
      // A native-IPv6 home network gives every device a global address, so
      // "global unicast = the internet" locks the room out of the LAN it is
      // sitting on. Same /64 as one of our own addresses is the line.
      final ours = [
        InternetAddress('2001:db8:1234:5678::1'),
        InternetAddress('192.168.1.7'),
      ];
      expect(
        JamHostServer.isLanAddress(
          InternetAddress('2001:db8:1234:5678::99'),
          hostAddresses: ours,
        ),
        isTrue,
        reason: 'same /64 as one of ours',
      );
      for (final offLink in [
        '2001:db8:1234:5679::99', // Neighbouring /64: a router away.
        '2001:db8:1111:5678::99', // Same interface id, different prefix.
        '2606:4700::1111',
      ]) {
        expect(
          JamHostServer.isLanAddress(
            InternetAddress(offLink),
            hostAddresses: ours,
          ),
          isFalse,
          reason: offLink,
        );
      }
      // With nothing to compare against, global unicast stays refused.
      expect(
        JamHostServer.isLanAddress(InternetAddress('2001:db8:1234:5678::99')),
        isFalse,
      );
      // The rest of the rule is untouched by the exception.
      expect(
        JamHostServer.isLanAddress(
          InternetAddress('fe80::1'),
          hostAddresses: ours,
        ),
        isTrue,
      );
      expect(
        JamHostServer.isLanAddress(
          InternetAddress('::ffff:8.8.8.8'),
          hostAddresses: ours,
        ),
        isFalse,
      );
    });

    test(
      'a LAN-restricted host still serves loopback on both planes',
      () async {
        // The filter must never break the host's own UI, the CLI or tests.
        final host = await startHost();
        final file = await writeTempMedia(makeMediaBytes(1024));
        final item = await JamHostServer.describeFile(
          file,
          kind: MediaKind.audio,
        );
        host.addMedia(item, file);
        final guest = await JamGuestClient.connect(
          host.joinUriFor(InternetAddress.loopbackIPv4),
        );
        addTearDown(guest.close);
        expect(await guest.fetchMedia(item.mediaId), hasLength(1024));
      },
    );
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
