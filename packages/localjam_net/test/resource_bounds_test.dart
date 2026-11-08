/// Regression tests for what one LAN neighbour can make the host hold
/// (PROTOCOL.md §6.4, §9.1): uploads that stall, trickle, vanish or pile
/// up; connections that never authenticate, send megabytes of headers or
/// of a "hello", or simply open by the hundred; malformed upload headers.
/// Every limit is shrunk to milliseconds and kilobytes so the tests run in
/// real time without long sleeps.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:localjam_net/localjam_net.dart';
import 'package:test/test.dart';

import 'hardening_helpers.dart';

/// The upload key from a raw `welcome`.
String uploadKeyOf(List<Map<String, Object?>> frames) {
  final welcome = frames.firstWhere((f) => f['type'] == 'welcome');
  return ((welcome['payload'] as Map)['you'] as Map)['uploadKey'] as String;
}

/// A raw TCP connection to [host] that records everything it receives.
class RawConn {
  RawConn._(this.socket) {
    // Writes to a connection the host destroyed fail here, not in the test.
    socket.done.catchError((Object _) {});
    socket.listen(
      received.addAll,
      onError: (Object _) {},
      onDone: () {
        if (!closed.isCompleted) closed.complete();
      },
    );
  }

  static Future<RawConn> open(JamHostServer host) async {
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      host.port,
    );
    final conn = RawConn._(socket);
    addTearDown(socket.destroy);
    return conn;
  }

  final Socket socket;
  final List<int> received = [];
  final Completer<void> closed = Completer<void>();

  String get text => latin1.decode(received);

  /// The status code of the HTTP response received so far, if any.
  int? get status {
    final match = RegExp(r'^HTTP/1\.1 (\d{3})').firstMatch(text);
    return match == null ? null : int.parse(match.group(1)!);
  }

  Future<void> send(List<int> bytes) async {
    socket.add(bytes);
    await socket.flush();
  }
}

/// Opens a `POST /media` with [declared] as its Content-Length and sends
/// the first [send] body bytes, leaving the connection open.
Future<RawConn> startUpload(
  JamHostServer host,
  String uploadKey, {
  required int declared,
  int send = 0,
}) async {
  final conn = await RawConn.open(host);
  await conn.send(
    ascii.encode(
      'POST /media HTTP/1.1\r\n'
      'Host: 127.0.0.1\r\n'
      'Authorization: Bearer ${host.token}\r\n'
      '${JamGuestClient.uploadKeyHeader}: $uploadKey\r\n'
      'X-LocalJam-Kind: audio\r\n'
      'Content-Length: $declared\r\n\r\n',
    ),
  );
  if (send > 0) await conn.send(Uint8List(send));
  return conn;
}

List<File> partFiles(Directory dir) => dir
    .listSync()
    .whereType<File>()
    .where((f) => f.path.endsWith('.part'))
    .toList();

/// A WebSocket upgrade request for `/ws`, as raw bytes.
List<int> upgradeRequest() => ascii.encode(
  'GET /ws HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\n'
  'Connection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n'
  'Sec-WebSocket-Version: 13\r\n\r\n',
);

/// One masked client text frame carrying [text].
Uint8List wsTextFrame(String text) {
  final payload = utf8.encode(text);
  const mask = [1, 2, 3, 4];
  final frame = BytesBuilder()..addByte(0x81);
  final n = payload.length;
  if (n < 126) {
    frame.addByte(0x80 | n);
  } else if (n < 65536) {
    frame.add([0x80 | 126, n >> 8, n & 0xff]);
  } else {
    frame
      ..addByte(0x80 | 127)
      ..add((ByteData(8)..setUint64(0, n)).buffer.asUint8List());
  }
  frame
    ..add(mask)
    ..add([for (var i = 0; i < n; i++) payload[i] ^ mask[i % 4]]);
  return frame.takeBytes();
}

/// A raw `hello` frame presenting [token].
Uint8List helloFrame(String token, {String clientId = 'c_raw'}) => wsTextFrame(
  jsonEncode({
    'v': 1,
    'type': 'hello',
    'seq': 0,
    'payload': {
      'token': token,
      'clientName': 'raw',
      'clientKind': 'raw',
      'clientId': clientId,
    },
  }),
);

/// Opens a control socket, presents a wrong token, and waits for the host's
/// `reject` — leaving this side of the connection open, as a peer that
/// never answers the close handshake would. Null if the host refused the
/// connection outright (its status is then in the returned conn's text).
Future<RawConn?> rejectedJoin(JamHostServer host) async {
  final conn = await RawConn.open(host);
  await conn.send(upgradeRequest());
  await waitFor(
    () => conn.text.contains('\r\n\r\n') || conn.closed.isCompleted,
    reason: 'an answer to the upgrade',
  );
  if (conn.status != HttpStatus.switchingProtocols) return null;
  await conn.send(helloFrame('wrong'));
  await waitFor(
    () => conn.text.contains('bad_token') || conn.closed.isCompleted,
    reason: 'the reject',
  );
  return conn;
}

/// Sends a `POST /media` of [length] bytes from ANOTHER isolate, [chunk]
/// bytes every [every], and returns the status it is answered with — a
/// client the host's own event loop cannot hold up.
Future<int> pacedUpload(
  int port,
  String token,
  String uploadKey, {
  required int length,
  required int chunk,
  required Duration every,
}) => Isolate.run(() async {
  final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
  final received = <int>[];
  final done = Completer<void>();
  socket.listen(received.addAll, onError: (Object _) {}, onDone: done.complete);
  socket.add(
    ascii.encode(
      'POST /media HTTP/1.1\r\nHost: 127.0.0.1\r\n'
      'Authorization: Bearer $token\r\n'
      'X-LocalJam-Upload-Key: $uploadKey\r\n'
      'X-LocalJam-Kind: audio\r\nContent-Length: $length\r\n\r\n',
    ),
  );
  final rng = Random(7);
  for (var sent = 0; sent < length; sent += chunk) {
    final n = min(chunk, length - sent);
    socket.add([for (var i = 0; i < n; i++) rng.nextInt(256)]);
    await socket.flush();
    if (sent + n < length) await Future<void>.delayed(every);
  }
  await done.future.timeout(const Duration(seconds: 10));
  socket.destroy();
  final match = RegExp(
    r'^HTTP/1\.1 (\d{3})',
  ).firstMatch(latin1.decode(received));
  return match == null ? -1 : int.parse(match.group(1)!);
});

void main() {
  group('upload time and disk bounds (§6.4)', () {
    test('a stalled upload is abandoned: 408, reservation and slot released, '
        'partial file deleted', () async {
      // Review 2026-10-17 (B1a): a POST that declared 2 MB and went quiet
      // held its reservation forever, so N of them owned the whole budget.
      final dir = await Directory.systemTemp.createTemp('lj_stall');
      addTearDown(() => dir.delete(recursive: true));
      final host = await startHost(
        uploadDir: dir,
        uploadBudgetBytes: 3 * 1024 * 1024,
        uploadStallTimeout: const Duration(milliseconds: 300),
        minUploadBytesPerSecond: 0,
      );
      final (ws, frames) = await rawJoin(host, clientId: 'c1');
      final stalled = await startUpload(
        host,
        uploadKeyOf(frames),
        declared: 2 * 1024 * 1024,
        send: 10,
      );
      // Its uploader leaving (once the upload is under way) changes nothing
      // on its own; the stall rule is what bounds it.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await ws.close();
      await stalled.closed.future.timeout(const Duration(seconds: 3));
      expect(stalled.status, HttpStatus.requestTimeout);
      await waitFor(() => partFiles(dir).isEmpty, reason: 'partial deleted');

      final (_, frames2) = await rawJoin(host, clientId: 'c2');
      final status = await rawUpload(
        host,
        makeMediaBytes(1500 * 1024),
        uploadKey: uploadKeyOf(frames2),
      );
      expect(status, HttpStatus.created, reason: 'the whole budget is back');
      expect(host.uploadedBytes, 1500 * 1024);
    });

    test('a trickle is a stall too', () async {
      // A byte now and then defeats a pure idle timeout; the minimum rate
      // does not care how often bytes arrive, only how many.
      final host = await startHost(
        uploadStallTimeout: const Duration(milliseconds: 300),
        minUploadBytesPerSecond: 64 * 1024,
        maxUploadsPerPeer: 1,
      );
      final (_, frames) = await rawJoin(host, clientId: 'c1');
      final key = uploadKeyOf(frames);
      final trickle = await startUpload(host, key, declared: 1024 * 1024);
      final ticker = Timer.periodic(const Duration(milliseconds: 50), (_) {
        if (!trickle.closed.isCompleted) trickle.socket.add(Uint8List(16));
      });
      addTearDown(ticker.cancel);
      await trickle.closed.future.timeout(const Duration(seconds: 3));
      ticker.cancel();
      // The 408 goes out first, but a client still writing into a
      // connection the host has dropped may see the reset before it.
      expect(trickle.status, anyOf(isNull, HttpStatus.requestTimeout));
      expect(host.playlist, isEmpty);
      // Its slot is free again: the one upload this peer may have in
      // flight goes through.
      expect(
        await rawUpload(host, makeMediaBytes(100), uploadKey: key),
        HttpStatus.created,
      );
    });

    test('an honest upload slower than one window is not a stall', () async {
      // The rule is per window, and owes only what is left: a body that
      // keeps up the minimum rate finishes, however long it takes.
      final host = await startHost(
        uploadStallTimeout: const Duration(milliseconds: 200),
        minUploadBytesPerSecond: 8 * 1024,
      );
      final (_, frames) = await rawJoin(host, clientId: 'c1');
      final body = makeMediaBytes(16 * 1024, seed: 3);
      final upload = await startUpload(
        host,
        uploadKeyOf(frames),
        declared: body.length,
      );
      // 4 KB every 100 ms = 40 KB/s, five times the minimum, over ~400 ms.
      for (var offset = 0; offset < body.length; offset += 4096) {
        await upload.send(body.sublist(offset, offset + 4096));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      await waitFor(() => upload.status != null, reason: 'a response');
      expect(upload.status, HttpStatus.created);
      expect(host.playlist, hasLength(1));
    });

    test('a host that stalls mid-upload does not blame the client', () async {
      // Review 2026-10-17 (N1): the stall check ran on a periodic timer. A
      // host stall across a tick (a GC pause, a busy isolate) made that
      // tick late, the next one came on the old grid — a window cut short
      // that still owed a full window's bytes — and what the client had
      // sent meanwhile sat unread in the socket buffer: 408 for a client
      // sending at 1.5× the minimum.
      final dir = await Directory.systemTemp.createTemp('lj_hoststall');
      addTearDown(() => dir.delete(recursive: true));
      final host = await startHost(
        uploadDir: dir,
        uploadStallTimeout: const Duration(milliseconds: 400),
        minUploadBytesPerSecond: 32 * 1024, // 12.8 KB per window.
      );
      final (_, frames) = await rawJoin(host, clientId: 'c1');
      // 5 KB every 100 ms — 50 KB/s — for two seconds, from another
      // isolate, so the host's stall does not stall the client.
      final status = pacedUpload(
        host.port,
        host.token,
        uploadKeyOf(frames),
        length: 100 * 1024,
        chunk: 5 * 1024,
        every: const Duration(milliseconds: 100),
      );
      await waitFor(
        () => partFiles(dir).any((f) => f.lengthSync() > 0),
        reason: 'the first bytes on disk',
      );
      // The host stalls across the first window's check — with less than a
      // window's worth read before it.
      final stall = Stopwatch()..start();
      while (stall.elapsedMilliseconds < 750) {}
      expect(await status, HttpStatus.created);
      expect(host.playlist, hasLength(1));
    });

    test('an upload whose client vanishes mid-body leaves no partial file '
        'behind', () async {
      // Review 2026-10-17 (B1b): each aborted upload left its `.part` on
      // disk, outside the budget, forever (a caller-supplied dir is never
      // swept).
      final dir = await Directory.systemTemp.createTemp('lj_vanish');
      addTearDown(() => dir.delete(recursive: true));
      final host = await startHost(
        uploadDir: dir,
        uploadBudgetBytes: 3 * 1024 * 1024,
      );
      final (_, frames) = await rawJoin(host, clientId: 'c1');
      for (var i = 0; i < 3; i++) {
        final upload = await startUpload(
          host,
          uploadKeyOf(frames),
          declared: 2 * 1024 * 1024,
          send: 512 * 1024,
        );
        await Future<void>.delayed(const Duration(milliseconds: 100));
        upload.socket.destroy(); // Walked out of range mid-upload.
        await waitFor(() => partFiles(dir).isEmpty, reason: 'partial gone');
      }
      expect(host.uploadedBytes, 0);
      expect(host.playlist, isEmpty);
    });

    test('one peer\'s concurrent uploads are capped (429)', () async {
      final host = await startHost(maxUploadsPerPeer: 1);
      final (_, frames) = await rawJoin(host, clientId: 'c1');
      final key = uploadKeyOf(frames);
      final first = await startUpload(host, key, declared: 1000, send: 10);
      // Let the host take the first one's headers before the second's.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(
        await rawUpload(host, makeMediaBytes(100), uploadKey: key),
        HttpStatus.tooManyRequests,
      );
      // Another peer is not affected.
      final (_, frames2) = await rawJoin(host, clientId: 'c2');
      expect(
        await rawUpload(
          host,
          makeMediaBytes(100),
          uploadKey: uploadKeyOf(frames2),
        ),
        HttpStatus.created,
      );
      first.socket.destroy();
      // Its slot frees once the host has seen it go.
      var status = 0;
      for (var i = 0; i < 100; i++) {
        status = await rawUpload(
          host,
          makeMediaBytes(100, seed: 5),
          uploadKey: key,
        );
        if (status != HttpStatus.tooManyRequests) break;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(status, HttpStatus.created);
    });

    test('X-LocalJam-Name that is valid percent-encoding of invalid UTF-8 '
        'is answered 400', () async {
      // Review 2026-10-17 (N2): '%FF' threw a FormatException nobody
      // caught, and the client got an empty 200.
      final host = await startHost();
      final (_, frames) = await rawJoin(host, clientId: 'c1');
      final status = await rawUpload(
        host,
        makeMediaBytes(10),
        uploadKey: uploadKeyOf(frames),
        headers: {'X-LocalJam-Name': '%FF'},
      );
      expect(status, HttpStatus.badRequest);
      expect(host.playlist, isEmpty);
    });
  });

  group('refused uploads say why (§6.4)', () {
    // Review 2026-10-17 (S1): refusals were answered while the guest was
    // still sending its body, then the body was dropped — the connection
    // reset under the guest, which saw "Broken pipe" instead of the status
    // (it reads its response only after the whole body is out).
    test('a guest whose upload does not fit the budget sees 507', () async {
      final host = await startHost(uploadBudgetBytes: 1024 * 1024);
      final guest = await joinGuest(host, clientId: 'g1');
      final file = await writeTempMedia(Uint8List(20 * 1024 * 1024));
      for (var i = 0; i < 2; i++) {
        await expectLater(
          guest.uploadMedia(file, kind: MediaKind.audio),
          throwsA(
            isA<JamHttpStatusException>().having(
              (e) => e.statusCode,
              'statusCode',
              HttpStatus.insufficientStorage,
            ),
          ),
        );
      }
      expect(host.playlist, isEmpty);
      await waitFor(() => host.debugOpenConnections == 1, reason: 'released');
    });

    test('a guest\'s third concurrent upload sees 429', () async {
      final host = await startHost(maxUploadsPerPeer: 2);
      final guest = await joinGuest(host, clientId: 'g1');
      // Two of this peer's uploads in flight, under its own key.
      final key = guest.uploadKey!;
      final held = [
        for (var i = 0; i < 2; i++)
          await startUpload(host, key, declared: 1 << 20, send: 10),
      ];
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final file = await writeTempMedia(Uint8List(8 * 1024 * 1024));
      await expectLater(
        guest.uploadMedia(file, kind: MediaKind.audio),
        throwsA(
          isA<JamHttpStatusException>().having(
            (e) => e.statusCode,
            'statusCode',
            HttpStatus.tooManyRequests,
          ),
        ),
      );
      for (final conn in held) {
        conn.socket.destroy();
      }
    });

    test('an upload the host could not store is answered 507 at once — its '
        'body is already in', () async {
      // The body was read whole before the write failed: there is nothing
      // left to read first, and nothing to wait for.
      final dir = await Directory.systemTemp.createTemp('lj_gone');
      final host = await startHost(uploadDir: dir);
      final guest = await joinGuest(host, clientId: 'g1');
      await dir.delete(recursive: true); // The disk under the room is gone.
      final file = await writeTempMedia(makeMediaBytes(64 * 1024));
      final answered = Stopwatch()..start();
      await expectLater(
        guest.uploadMedia(file, kind: MediaKind.audio),
        throwsA(
          isA<JamHttpStatusException>().having(
            (e) => e.statusCode,
            'statusCode',
            HttpStatus.insufficientStorage,
          ),
        ),
      );
      expect(answered.elapsedMilliseconds, lessThan(3000));
    });

    test('a refused body that never arrives is answered after helloTimeout, '
        'not waited for', () async {
      // The read-it-first courtesy is bounded like everything else an
      // unproven connection gets (§9.1).
      final host = await startHost(
        helloTimeout: const Duration(milliseconds: 300),
      );
      final conn = await RawConn.open(host);
      final sent = Stopwatch()..start();
      await conn.send(
        ascii.encode(
          'POST /media HTTP/1.1\r\nHost: x\r\n'
          'Authorization: Bearer wrong\r\nContent-Length: 1000\r\n\r\n',
        ),
      );
      await conn.closed.future.timeout(const Duration(seconds: 3));
      expect(conn.status, HttpStatus.unauthorized);
      expect(sent.elapsedMilliseconds, lessThan(2000));
      await waitFor(() => host.debugOpenConnections == 0, reason: 'released');
    });
  });

  group('connection admission (§9.1)', () {
    test('connections past the per-remote cap are answered 503 before they '
        'are parsed, and the slot comes back', () async {
      final host = await startHost(maxConnectionsPerRemote: 3);
      final held = [for (var i = 0; i < 3; i++) await RawConn.open(host)];
      for (final conn in held) {
        await conn.send(ascii.encode('GET /media/x HTTP/1.1\r\n'));
      }
      final refused = await RawConn.open(host);
      await refused.closed.future.timeout(const Duration(seconds: 3));
      expect(refused.status, HttpStatus.serviceUnavailable);

      held.first.socket.destroy();
      await waitFor(() => host.debugOpenConnections == 2, reason: 'released');
      final admitted = await RawConn.open(host);
      await admitted.send(ascii.encode('GET /nope HTTP/1.1\r\n\r\n'));
      await admitted.closed.future.timeout(const Duration(seconds: 3));
      expect(admitted.status, HttpStatus.notFound);
    });

    test('a connection that arrives on a refused local address is answered '
        '403 before it is parsed', () async {
      // §9: a wildcard bind listens on cellular and tunnel interfaces too,
      // where an RFC1918 remote is the carrier's, not a neighbour.
      for (final admitted in [false, true]) {
        final locals = <String>[];
        final host = JamHostServer(
          sessionName: 'Local',
          admitLocalAddress: (local) {
            locals.add(local.address);
            return admitted;
          },
        );
        await host.start(address: InternetAddress.loopbackIPv4);
        addTearDown(host.close);
        final conn = await RawConn.open(host);
        try {
          await conn.send(ascii.encode('GET /nope HTTP/1.1\r\n\r\n'));
        } catch (_) {
          // Refused under our feet.
        }
        await conn.closed.future.timeout(const Duration(seconds: 3));
        expect(
          conn.status,
          admitted ? HttpStatus.notFound : HttpStatus.forbidden,
        );
        expect(locals, ['127.0.0.1']);
        await waitFor(() => host.debugOpenConnections == 0, reason: 'none');
      }
    });

    test('the global cap holds across remotes', () async {
      final host = await startHost(maxConnections: 2);
      final held = [for (var i = 0; i < 2; i++) await RawConn.open(host)];
      final refused = await RawConn.open(host);
      await refused.closed.future.timeout(const Duration(seconds: 3));
      expect(refused.status, HttpStatus.serviceUnavailable);
      expect(held.every((c) => !c.closed.isCompleted), isTrue);
    });

    test('a header block past maxRequestHeaderBytes loses the connection '
        'while it is still arriving', () async {
      // Review 2026-10-17 (S3): dart:io buffers a header block whole, eight
      // bytes of memory per byte, up to 1 MiB each — 100 connections × 1 MB
      // of "header" was ~880 MB of host RSS, no token needed.
      final host = await startHost(maxRequestHeaderBytes: 4096);
      final conn = await RawConn.open(host);
      await conn.send(ascii.encode('GET /media/x HTTP/1.1\r\nX-Pad: '));
      // Never terminated: without the cap this just keeps growing.
      final pad = Uint8List(64 * 1024)..fillRange(0, 64 * 1024, 0x61);
      try {
        for (var i = 0; i < 16 && !conn.closed.isCompleted; i++) {
          await conn.send(pad);
        }
      } catch (_) {
        // Destroyed under our feet: the point.
      }
      await conn.closed.future.timeout(const Duration(seconds: 3));
      expect(conn.status, isNull, reason: 'nothing parsed, nothing answered');
      await waitFor(() => host.debugOpenConnections == 0, reason: 'released');
    });

    test(
      'an honest request with headers well under the cap is served',
      () async {
        final host = await startHost(maxRequestHeaderBytes: 4096);
        final conn = await RawConn.open(host);
        await conn.send(
          ascii.encode(
            'GET /media/x HTTP/1.1\r\nX-Pad: ${'a' * 3000}\r\n'
            'Authorization: Bearer ${host.token}\r\n\r\n',
          ),
        );
        await conn.closed.future.timeout(const Duration(seconds: 3));
        expect(conn.status, HttpStatus.notFound);
      },
    );

    test('a refused request is answered at once, without waiting for the '
        'body it declared', () async {
      // dart:io drains an unread body before it sends the headers of a
      // response: a refusal of a request that declares a gigabyte and sends
      // nothing used to be never sent, and the connection held for good.
      final host = await startHost();
      for (final (path, expected) in [
        ('/media', HttpStatus.unauthorized), // Wrong token, upload path.
        ('/nope', HttpStatus.notFound),
        ('/media/m_x', HttpStatus.unauthorized),
      ]) {
        final conn = await RawConn.open(host);
        await conn.send(
          ascii.encode(
            'POST $path HTTP/1.1\r\nHost: x\r\n'
            'Authorization: Bearer wrong\r\n'
            'Content-Length: 1000000000\r\n\r\n',
          ),
        );
        await conn.closed.future.timeout(const Duration(seconds: 3));
        expect(conn.status, expected, reason: path);
      }
      await waitFor(() => host.debugOpenConnections == 0, reason: 'released');
    });

    test('a request whose headers never finish is dropped after '
        'helloTimeout', () async {
      final host = await startHost(
        helloTimeout: const Duration(milliseconds: 300),
      );
      final conn = await RawConn.open(host);
      await conn.send(ascii.encode('GET /media/x HTTP/1.1\r\nHost: a\r\n'));
      await conn.closed.future.timeout(const Duration(seconds: 3));
      await waitFor(() => host.debugOpenConnections == 0, reason: 'released');
    });

    test('a pre-hello WebSocket is cut off by raw bytes, not after the host '
        'has reassembled the whole message', () async {
      // A frame that declares 100 MB and starts sending it. Before, the
      // host buffered it all (the 16 KB cap only looked at complete
      // messages) and the socket lived until its hello timeout.
      final host = await startHost(maxPreHelloFrameBytes: 1024);
      final conn = await RawConn.open(host);
      final key = base64.encode(List<int>.generate(16, (i) => i));
      await conn.send(
        ascii.encode(
          'GET /ws HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\n'
          'Connection: Upgrade\r\nSec-WebSocket-Key: $key\r\n'
          'Sec-WebSocket-Version: 13\r\n\r\n',
        ),
      );
      await waitFor(
        () => conn.text.contains('\r\n\r\n'),
        reason: 'the upgrade',
      );
      expect(conn.status, HttpStatus.switchingProtocols);
      final upgradeLength = conn.received.length;
      // FIN + text, masked, 64-bit length = 100 MB, a zero mask key.
      final header = BytesBuilder()
        ..add([0x81, 0xff])
        ..add(
          (ByteData(8)..setUint64(0, 100 * 1024 * 1024)).buffer.asUint8List(),
        )
        ..add([0, 0, 0, 0]);
      await conn.send(header.takeBytes());
      try {
        for (var i = 0; i < 8 && !conn.closed.isCompleted; i++) {
          await conn.send(Uint8List(16 * 1024));
        }
      } catch (_) {
        // Destroyed under our feet: the point.
      }
      await conn.closed.future.timeout(const Duration(seconds: 4));
      // It was told why: a close frame (opcode 8) with 1008.
      final after = conn.received.sublist(upgradeLength);
      expect(after.length, greaterThanOrEqualTo(4));
      expect(after[0], 0x88);
      expect((after[2] << 8) | after[3], WebSocketStatus.policyViolation);
      await waitFor(() => host.debugOpenConnections == 0, reason: 'released');
    });

    test('every way a connection ends gives its slot back', () async {
      final host = await startHost(
        maxConnections: 64,
        helloTimeout: const Duration(milliseconds: 300),
      );
      await addTrack(host);
      // A joined guest that fetches, uploads and leaves.
      final guest = await joinGuest(host, clientId: 'g1');
      final item = host.playlist.single;
      await guest.fetchMedia(item.mediaId);
      await guest.uploadMedia(
        await writeTempMedia(makeMediaBytes(2048, seed: 77)),
        kind: MediaKind.audio,
      );
      // Unauthenticated requests of every flavour.
      for (final path in ['/ws', '/nope', '/media/${item.mediaId}']) {
        final client = HttpClient();
        final req = await client.getUrl(
          Uri.parse('http://127.0.0.1:${host.port}$path'),
        );
        final res = await req.close();
        await res.drain<void>();
        client.close(force: true);
      }
      // A wrong-token hello, and a socket that never says hello.
      final wrong = await WebSocket.connect('ws://127.0.0.1:${host.port}/ws');
      wrong.listen((_) {}, onError: (Object _) {});
      wrong.add(
        jsonEncode({
          'v': 1,
          'type': 'hello',
          'seq': 0,
          'payload': {'token': 'nope', 'clientName': 'x', 'clientKind': 'x'},
        }),
      );
      final silent = await WebSocket.connect('ws://127.0.0.1:${host.port}/ws');
      silent.listen((_) {}, onError: (Object _) {});
      expect(host.debugOpenConnections, greaterThan(0));
      await guest.close();
      await waitFor(
        () => host.debugOpenConnections == 0,
        timeout: const Duration(seconds: 10),
        reason: 'every slot back (now ${host.debugOpenConnections})',
      );
    });

    test('a connection the host closed keeps its slot until it is gone — '
        'and is gone soon', () async {
      // Review 2026-10-17 (B1): a host-side close freed the slot at once,
      // while the connection lived on half-closed (up to 5 s in dart:io's
      // WebSocket) for as long as the peer ignored the close. Cycling
      // wrong-token joins held 14k descriptors while the guard counted 13.
      final host = await startHost(maxConnectionsPerRemote: 4);
      final rejected = [
        for (var i = 0; i < 4; i++) (await rejectedJoin(host))!,
      ];
      // The host has closed its side of all four; no peer has answered.
      expect(host.debugOpenConnections, 4);
      final refused = await RawConn.open(host);
      await refused.closed.future.timeout(const Duration(seconds: 3));
      expect(refused.status, HttpStatus.serviceUnavailable);
      // It does not wait on the peers forever: each is destroyed within the
      // close linger (2 s, where dart:io alone would wait 5), and its slot
      // comes back.
      await waitFor(
        () => host.debugOpenConnections == 0,
        timeout: const Duration(seconds: 4),
        reason: 'released',
      );
      expect(rejected.every((c) => c.closed.isCompleted), isTrue);
      final admitted = await RawConn.open(host);
      await admitted.send(ascii.encode('GET /nope HTTP/1.1\r\n\r\n'));
      await admitted.closed.future.timeout(const Duration(seconds: 3));
      expect(admitted.status, HttpStatus.notFound);
    });

    test('a flood of rejected joins gets no more connections than the cap '
        'while the rejected ones linger', () async {
      // The review's shape: 16 workers cycling wrong-token joins from one
      // address and never answering the close. Each rejected connection
      // lingers half-closed until the host destroys it (2 s), and holds its
      // slot all that time — so a flood shorter than that is admitted
      // exactly `cap` times. Before, it was admitted ~1000 times a second.
      // (A peer sees the host's half-close as the end of its input, so
      // what the peer observes cannot tell lingering from gone.)
      const cap = 8;
      final host = await startHost(maxConnectionsPerRemote: cap);
      var admitted = 0;
      var refused = 0;
      final flood = Stopwatch()..start();
      Future<void> worker() async {
        while (flood.elapsedMilliseconds < 1500) {
          if (await rejectedJoin(host) != null) {
            admitted++;
          } else {
            refused++;
          }
        }
      }

      await Future.wait([for (var i = 0; i < 16; i++) worker()]);
      expect(admitted, lessThanOrEqualTo(cap));
      expect(refused, greaterThan(0));
      expect(host.debugOpenConnections, lessThanOrEqualTo(cap));
      await waitFor(
        () => host.debugOpenConnections == 0,
        reason: 'released (now ${host.debugOpenConnections})',
      );
    });

    test('frames sent with the upgrade request count against the pre-hello '
        'budget', () async {
      // Review 2026-10-17 (S2): bytes that arrived in the same read as the
      // upgrade's headers went to the WebSocket uncounted — headers, a
      // megabyte of frames and a hello in one write were welcomed.
      final host = await startHost();
      for (final filler in [40 * 1024, 256 * 1024, 1024 * 1024]) {
        final conn = await RawConn.open(host);
        conn.socket.setOption(SocketOption.tcpNoDelay, true);
        final junk = wsTextFrame('x' * 1000);
        final write = BytesBuilder()..add(upgradeRequest());
        for (var i = 0; i < filler ~/ 1000; i++) {
          write.add(junk);
        }
        write.add(helloFrame(host.token, clientId: 'c_$filler'));
        try {
          await conn.send(write.takeBytes());
        } catch (_) {
          // Destroyed under our feet: the point.
        }
        await conn.closed.future.timeout(const Duration(seconds: 4));
        expect(conn.text, isNot(contains('"welcome"')), reason: '$filler');
      }
      expect(host.peers, isEmpty);
      // Within the budget, the same shape is still served.
      final honest = await RawConn.open(host);
      await honest.send([
        ...upgradeRequest(),
        ...helloFrame(host.token, clientId: 'c_ok'),
      ]);
      await waitFor(
        () => honest.text.contains('"welcome"'),
        reason: 'a welcome',
      );
    });

    test('one guest\'s burst of artwork fetches stays under its per-address '
        'cap', () async {
      // Review 2026-10-17 (S3): the guest's HTTP client opened a connection
      // per request, so 40 covers at once ran into the host's 32-per-address
      // cap — seven 503s. Its connections are bounded now; the rest queue.
      final host = await startHost();
      final art = await host.addArtwork(
        Uint8List.fromList(List.filled(200 * 1024, 7)),
        mime: 'image/jpeg',
      );
      final guest = await joinGuest(host, clientId: 'g1');
      final fetched = await Future.wait([
        for (var i = 0; i < 80; i++) guest.fetchArtwork(art),
      ]);
      expect(fetched.every((b) => b.length == 200 * 1024), isTrue);
    });
  });

  group('tag reading of uploads is bounded (§6.5)', () {
    test('a cover far over the artwork cap is skipped unread; the title '
        'survives', () async {
      // Review 2026-10-17 (S4): a 200 MB APIC was read whole (+200 MB RSS)
      // before the 8 MB cap threw it away.
      final file = await writeId3Mp3(
        title: 'Big Cover',
        apicBytes: 3 * 1024 * 1024,
      );
      final bounded = readAudioTagsSync(file, maxMetadataBytes: 1024 * 1024);
      expect(bounded.title, 'Big Cover');
      expect(bounded.hasArtwork, isFalse);
      expect(bounded.durationUs, greaterThan(0));
      // Unbounded (the host's own library) still reads it all.
      final unbounded = readAudioTagsSync(file);
      expect(unbounded.title, 'Big Cover');
      expect(unbounded.artworkBytes, hasLength(3 * 1024 * 1024));
    });

    test('a cover under the cap is kept', () async {
      final file = await writeId3Mp3(title: 'Small', apicBytes: 100 * 1024);
      final tags = readAudioTagsSync(file, maxMetadataBytes: 1024 * 1024);
      expect(tags.title, 'Small');
      expect(tags.artworkBytes, hasLength(100 * 1024));
    });

    test('a text frame over the cap costs the tags, not the memory', () async {
      final file = await writeId3Mp3(
        title: 'x' * (3 * 1024 * 1024),
        apicBytes: 0,
      );
      final tags = readAudioTagsSync(file, maxMetadataBytes: 1024 * 1024);
      expect(tags.title, isNull);
      expect(tags.hasArtwork, isFalse);
    });

    test('an upload with an oversized cover is stored with its title and '
        'without the cover', () async {
      final host = await startHost(maxArtworkBytes: 512 * 1024);
      final guest = await joinGuest(host);
      final item = await guest.uploadMedia(
        await writeId3Mp3(title: 'Uploaded', apicBytes: 2 * 1024 * 1024),
        kind: MediaKind.audio,
      );
      expect(item.title, 'Uploaded');
      expect(item.artworkId, isNull);
    });
  });

  group('a joined peer is bounded too (§9.1)', () {
    // Review 2026-11 (release audit): after `hello` the guard stopped
    // counting, and the 256 KB cap was applied only to messages `dart:io`
    // had already reassembled — so anyone holding the token (which a
    // discoverable room hands to every neighbour) could stream one
    // fragmented message until the host ran out of memory.

    test('a message declaring more than the cap is cut off at its header, '
        'before the payload arrives', () async {
      final host = await startHost();
      final conn = await rawJoined(host);
      // A text fragment, then a continuation that declares a gigabyte: the
      // host must not wait for (or buffer) any of it.
      await conn.send([
        ...wsFrame(0x1, List.filled(1000, 0x78), fin: false),
        ...wsFrameHeader(0x0, 1024 * 1024 * 1024),
      ]);
      try {
        for (var i = 0; i < 4 && !conn.closed.isCompleted; i++) {
          await conn.send(Uint8List(16 * 1024));
        }
      } catch (_) {
        // Destroyed under our feet: the point.
      }
      await conn.closed.future.timeout(const Duration(seconds: 4));
      expect(closeCodeOf(conn), WebSocketStatus.policyViolation);
      expect(host.peers, isEmpty);
      await waitFor(() => host.debugOpenConnections == 0, reason: 'released');
    });

    test('fragments that add up past the cap are cut off too', () async {
      final host = await startHost(maxControlFrameBytes: 32 * 1024);
      final conn = await rawJoined(host);
      // Each fragment alone is small; the message they make is not.
      final fragment = List.filled(4 * 1024, 0x78);
      final write = BytesBuilder()..add(wsFrame(0x1, fragment, fin: false));
      for (var i = 0; i < 10; i++) {
        write.add(wsFrame(0x0, fragment, fin: false));
      }
      try {
        await conn.send(write.takeBytes());
      } catch (_) {}
      await conn.closed.future.timeout(const Duration(seconds: 4));
      expect(closeCodeOf(conn), WebSocketStatus.policyViolation);
      expect(host.peers, isEmpty);
    });

    test('a fragmented message under the cap is still served', () async {
      final host = await startHost(maxControlFrameBytes: 32 * 1024);
      final conn = await rawJoined(host);
      final ping = utf8.encode(
        jsonEncode({
          'v': 1,
          'type': 'clock_ping',
          'seq': 1,
          'payload': {'t0': 4242},
        }),
      );
      final third = ping.length ~/ 3;
      await conn.send([
        ...wsFrame(0x1, ping.sublist(0, third), fin: false),
        // A WebSocket ping between fragments is allowed (RFC 6455 §5.4).
        ...wsFrame(0x9, const []),
        ...wsFrame(0x0, ping.sublist(third, 2 * third), fin: false),
        ...wsFrame(0x0, ping.sublist(2 * third)),
      ]);
      await waitFor(
        () => conn.text.contains('"clock_pong"'),
        reason: 'the pong',
      );
      // And full-size messages, one after another, are fine as well.
      final padded = jsonEncode({
        'v': 1,
        'type': 'clock_ping',
        'seq': 2,
        'payload': {'t0': 4343, 'pad': 'x' * (31 * 1024)},
      });
      for (var i = 0; i < 3; i++) {
        await conn.send(wsTextFrame(padded));
      }
      await waitFor(
        () => conn.text.contains('4343'),
        reason: 'the padded pong',
      );
      expect(host.peers, hasLength(1));
      expect(conn.closed.isCompleted, isFalse);
    });

    test('a joined peer that floods bytes is closed', () async {
      final host = await startHost(maxInboundBytesPerSecond: 8 * 1024);
      final conn = await rawJoined(host);
      // 64 KB of small, valid frames: eight seconds' worth at once, twice
      // the burst allowance.
      final junk = wsTextFrame(jsonEncode({'pad': 'x' * 1000}));
      final write = BytesBuilder();
      for (var i = 0; i < 64; i++) {
        write.add(junk);
      }
      try {
        await conn.send(write.takeBytes());
      } catch (_) {}
      await conn.closed.future.timeout(const Duration(seconds: 4));
      expect(closeCodeOf(conn), WebSocketStatus.policyViolation);
      expect(host.peers, isEmpty);
    });

    test('a joined peer that floods frames (WebSocket pings included) is '
        'closed', () async {
      final host = await startHost(maxInboundFramesPerSecond: 10);
      final conn = await rawJoined(host);
      final write = BytesBuilder();
      for (var i = 0; i < 100; i++) {
        write.add(wsFrame(0x9, const []));
      }
      try {
        await conn.send(write.takeBytes());
      } catch (_) {}
      await conn.closed.future.timeout(const Duration(seconds: 4));
      expect(closeCodeOf(conn), WebSocketStatus.policyViolation);
      expect(host.peers, isEmpty);
    });

    test('an honest guest\'s join burst and chatter stay well inside the '
        'rates', () async {
      // The tightest rates a host should ever run with still admit what a
      // real guest does: a join, its eight-ping burst, and requests.
      final host = await startHost(
        maxInboundBytesPerSecond: 4 * 1024,
        maxInboundFramesPerSecond: 10,
      );
      await addTrack(host);
      final guest = await joinGuest(
        host,
        pingInterval: const Duration(milliseconds: 200),
      );
      for (var i = 0; i < 5; i++) {
        await guest.requestPause();
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(host.peers, hasLength(1));
    });
  });

  group('a joined peer\'s requests are rate-limited (§9.1)', () {
    /// A raw `request` frame for [action].
    Uint8List requestFrame(String action, int seq) => wsTextFrame(
      jsonEncode({
        'v': 1,
        'type': 'request',
        'seq': seq,
        'payload': {'action': action},
      }),
    );

    int busyCount(RawConn conn) =>
        RegExp('"code":"busy"').allMatches(conn.text).length;

    test('a burst within the allowance is all acted on; past it, requests '
        'are answered busy and the peer stays', () async {
      final host = await startHost(maxRequestsPerSecond: 10);
      final conn = await rawJoined(host);
      // 30 at once is the allowance (three seconds' worth): none is busy.
      final burst = BytesBuilder();
      for (var i = 0; i < 30; i++) {
        burst.add(requestFrame(i.isEven ? 'pause' : 'play', i + 1));
      }
      await conn.send(burst.takeBytes());
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(busyCount(conn), 0);
      // Ten more, at once: over the allowance, each answered busy (one may
      // have refilled while they were sent).
      final over = BytesBuilder();
      for (var i = 0; i < 10; i++) {
        over.add(requestFrame('pause', 100 + i));
      }
      await conn.send(over.takeBytes());
      await waitFor(() => busyCount(conn) >= 8, reason: 'busy answers');
      expect(busyCount(conn), inInclusiveRange(8, 10));
      // Not a flood: the peer is still here, and after a pause its
      // requests are acted on again.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final before = busyCount(conn);
      await conn.send(requestFrame('play', 200));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(busyCount(conn), before);
      expect(host.peers, hasLength(1));
      expect(conn.closed.isCompleted, isFalse);
    });

    test('a sustained flood is closed', () async {
      final host = await startHost(maxRequestsPerSecond: 10);
      final conn = await rawJoined(host);
      final flood = BytesBuilder();
      for (var i = 0; i < 200; i++) {
        flood.add(requestFrame('next', i + 1));
      }
      try {
        await conn.send(flood.takeBytes());
      } catch (_) {}
      await conn.closed.future.timeout(const Duration(seconds: 4));
      expect(closeCodeOf(conn), WebSocketStatus.policyViolation);
      expect(host.peers, isEmpty);
      // The 30 allowed and 60 answered busy, at most: nothing past that
      // was acted on or answered.
      expect(busyCount(conn), inInclusiveRange(55, 62));
    });
  });
}

/// A raw control socket that has said `hello` and been welcomed.
Future<RawConn> rawJoined(
  JamHostServer host, {
  String clientId = 'c_raw',
}) async {
  final conn = await RawConn.open(host);
  await conn.send([
    ...upgradeRequest(),
    ...helloFrame(host.token, clientId: clientId),
  ]);
  await waitFor(() => conn.text.contains('"welcome"'), reason: 'a welcome');
  return conn;
}

/// A masked client frame header for [opcode] declaring [length] bytes of
/// payload, under an all-zero mask (so the payload goes as it is).
Uint8List wsFrameHeader(int opcode, int length, {bool fin = true}) {
  final header = BytesBuilder()..addByte((fin ? 0x80 : 0) | opcode);
  if (length < 126) {
    header.addByte(0x80 | length);
  } else if (length < 65536) {
    header.add([0x80 | 126, length >> 8, length & 0xff]);
  } else {
    header
      ..addByte(0x80 | 127)
      ..add((ByteData(8)..setUint64(0, length)).buffer.asUint8List());
  }
  header.add(const [0, 0, 0, 0]);
  return header.takeBytes();
}

/// One whole masked client frame (all-zero mask).
Uint8List wsFrame(int opcode, List<int> payload, {bool fin = true}) =>
    (BytesBuilder()
          ..add(wsFrameHeader(opcode, payload.length, fin: fin))
          ..add(payload))
        .takeBytes();

/// The frames the host sent on [conn] after its upgrade response, as
/// (opcode, payload) — server frames are never masked.
List<(int, List<int>)> serverFrames(RawConn conn) {
  final bytes = conn.received;
  var i = conn.text.indexOf('\r\n\r\n');
  if (i < 0) return const [];
  i += 4;
  final frames = <(int, List<int>)>[];
  while (i + 2 <= bytes.length) {
    final opcode = bytes[i] & 0x0f;
    var length = bytes[i + 1] & 0x7f;
    var at = i + 2;
    if (length == 126) {
      if (at + 2 > bytes.length) break;
      length = (bytes[at] << 8) | bytes[at + 1];
      at += 2;
    } else if (length == 127) {
      if (at + 8 > bytes.length) break;
      length = 0;
      for (var k = 0; k < 8; k++) {
        length = (length << 8) | bytes[at + k];
      }
      at += 8;
    }
    if (at + length > bytes.length) break;
    frames.add((opcode, bytes.sublist(at, at + length)));
    i = at + length;
  }
  return frames;
}

/// The status code of the close frame the host sent on [conn], if any.
int? closeCodeOf(RawConn conn) {
  for (final (opcode, payload) in serverFrames(conn)) {
    if (opcode == 0x8 && payload.length >= 2) {
      return (payload[0] << 8) | payload[1];
    }
  }
  return null;
}

/// An ID3v2.3-tagged MP3: a TIT2 [title] frame, an APIC frame carrying
/// [apicBytes] bytes of "image" (none when 0), then 40 silent MPEG frames.
Future<File> writeId3Mp3({
  required String title,
  required int apicBytes,
}) async {
  List<int> be32(int n) => [
    (n >> 24) & 0xff,
    (n >> 16) & 0xff,
    (n >> 8) & 0xff,
    n & 0xff,
  ];
  List<int> syncsafe(int n) => [
    (n >> 21) & 0x7f,
    (n >> 14) & 0x7f,
    (n >> 7) & 0x7f,
    n & 0x7f,
  ];
  final frames = BytesBuilder();
  final titleBody = [0x00, ...latin1.encode(title)];
  frames
    ..add(ascii.encode('TIT2'))
    ..add(be32(titleBody.length))
    ..add([0, 0])
    ..add(titleBody);
  if (apicBytes > 0) {
    final apicHeader = [0x00, ...ascii.encode('image/png'), 0x00, 0x03, 0x00];
    final rng = Random(1);
    frames
      ..add(ascii.encode('APIC'))
      ..add(be32(apicHeader.length + apicBytes))
      ..add([0, 0])
      ..add(apicHeader)
      ..add(List<int>.generate(apicBytes, (_) => rng.nextInt(256)));
  }
  final tag = frames.takeBytes();
  final out = BytesBuilder()
    ..add([...ascii.encode('ID3'), 3, 0, 0, ...syncsafe(tag.length)])
    ..add(tag);
  final mpegFrame = Uint8List(417)..setRange(0, 4, [0xFF, 0xFB, 0x90, 0x00]);
  for (var i = 0; i < 40; i++) {
    out.add(mpegFrame);
  }
  final dir = await Directory.systemTemp.createTemp('localjam_id3');
  addTearDown(() => dir.delete(recursive: true));
  final file = File('${dir.path}/tagged.mp3');
  await file.writeAsBytes(out.takeBytes());
  return file;
}
