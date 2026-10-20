/// The web guest's page (PROTOCOL.md §1.1, protocol 1.2): `GET /` and
/// `GET /join` serve the page, `GET /web/<path>` the bundle, from memory,
/// without a token — and under every §9.1 bound the rest of the host lives
/// by. The media plane and the control plane are untouched.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:localjam_net/localjam_net.dart';
import 'package:test/test.dart';

import 'hardening_helpers.dart';

/// One parsed HTTP/1.1 response read off a raw socket — so the test sees
/// exactly what the host wrote, with no client normalising the request
/// path (`..`) or the response on the way.
class RawResponse {
  RawResponse(this.status, this.headers, this.body);

  final int status;
  final Map<String, String> headers; // Lower-cased names.
  final Uint8List body;

  String get text => utf8.decode(body);
}

Future<RawResponse> raw(
  JamHostServer host,
  String method,
  String path, {
  Map<String, String> headers = const {},
}) async {
  final socket = await Socket.connect(InternetAddress.loopbackIPv4, host.port);
  addTearDown(socket.destroy);
  final received = BytesBuilder(copy: false);
  final done = Completer<void>();
  socket.listen(received.add, onError: (Object _) {}, onDone: done.complete);
  final head = StringBuffer('$method $path HTTP/1.1\r\nHost: x\r\n');
  headers.forEach((k, v) => head.write('$k: $v\r\n'));
  head.write('\r\n');
  socket.add(latin1.encode('$head'));
  await socket.flush();
  // Connection: close (§9.1) — the host ends every exchange.
  await done.future.timeout(const Duration(seconds: 5));
  final bytes = received.takeBytes();
  final split = _indexOf(bytes, latin1.encode('\r\n\r\n'));
  final lines = latin1.decode(bytes.sublist(0, split)).split('\r\n');
  final status = int.parse(lines.first.split(' ')[1]);
  final parsed = <String, String>{};
  for (final line in lines.skip(1)) {
    final colon = line.indexOf(':');
    parsed[line.substring(0, colon).trim().toLowerCase()] = line
        .substring(colon + 1)
        .trim();
  }
  return RawResponse(status, parsed, Uint8List.sublistView(bytes, split + 4));
}

int _indexOf(List<int> haystack, List<int> needle) {
  outer:
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  throw StateError('no header terminator');
}

String etagOf(List<int> bytes) =>
    '"${sha256.convert(bytes).toString().substring(0, 16)}"';

final _indexHtml = '<!doctype html><title>Player</title>';
final _mainJs = 'console.log("jam");';
final _wasm = Uint8List.fromList([0x00, 0x61, 0x73, 0x6d, 1, 0, 0, 0]);

StaticSite site({bool withIndex = true}) => StaticSite({
  // A loader's MIME for index.html is ignored: the page is always html.
  if (withIndex) 'index.html': StaticFile.text(_indexHtml, 'text/plain'),
  'main.dart.js': StaticFile.text(_mainJs, StaticSite.mimeFor('main.dart.js')),
  'canvaskit/canvaskit.wasm': StaticFile(
    _wasm,
    StaticSite.mimeFor('canvaskit/canvaskit.wasm'),
  ),
});

Future<JamHostServer> hostWith(StaticSite? staticSite) async {
  final host = JamHostServer(sessionName: 'Web', staticSite: staticSite);
  await host.start(address: InternetAddress.loopbackIPv4);
  addTearDown(host.close);
  return host;
}

void main() {
  group('StaticSite', () {
    test('ETag is the quoted sha256 prefix, computed from the bytes', () {
      final file = StaticFile(_wasm, 'application/wasm');
      expect(file.etag, etagOf(_wasm));
      expect(file.etag, matches(RegExp(r'^"[0-9a-f]{16}"$')));
      expect(file.length, _wasm.length);
    });

    test('files and bytes are read-only', () {
      final s = site();
      expect(
        () => s.files['x'] = StaticFile.text('', 'text/plain'),
        throwsUnsupportedError,
      );
      expect(() => s.files['main.dart.js']!.bytes[0] = 0, throwsA(anything));
      expect(s.index, isNotNull);
      expect(s.totalBytes, greaterThan(0));
    });

    test('refuses keys that could never be a bundle path', () {
      for (final bad in [
        '',
        '/index.html',
        'a//b.js',
        '../secret',
        'a/../b',
        './a',
        'a/',
        r'a\b',
        'a?b',
        'a#b',
        'a\u0000b',
      ]) {
        expect(
          () => StaticSite({bad: StaticFile.text('', 'text/plain')}),
          throwsArgumentError,
          reason: bad,
        );
      }
      expect(StaticSite.isValidPath('assets/fonts/MaterialIcons.otf'), isTrue);
    });

    test('mimeFor covers a Flutter web build', () {
      expect(StaticSite.mimeFor('index.html'), 'text/html; charset=utf-8');
      expect(
        StaticSite.mimeFor('main.dart.js'),
        'text/javascript; charset=utf-8',
      );
      expect(
        StaticSite.mimeFor('canvaskit/canvaskit.wasm'),
        'application/wasm',
      );
      expect(
        StaticSite.mimeFor('assets/FontManifest.json'),
        'application/json',
      );
      expect(StaticSite.mimeFor('icons/Icon-192.PNG'), 'image/png');
      expect(StaticSite.mimeFor('fonts/x.woff2'), 'font/woff2');
      expect(StaticSite.mimeFor('NOTICES'), 'application/octet-stream');
      expect(StaticSite.mimeFor('a.unknown'), 'application/octet-stream');
    });
  });

  group('no site: the built-in page (§1.1)', () {
    test('/ and /join say there is no browser player, with nothing '
        'off-origin', () async {
      final host = await hostWith(null);
      for (final path in ['/', '/join', '/join?x=1']) {
        final res = await raw(host, 'GET', path);
        expect(res.status, HttpStatus.ok, reason: path);
        expect(res.headers['content-type'], 'text/html; charset=utf-8');
        expect(res.headers['cache-control'], 'no-store');
        expect(res.headers['connection'], 'close');
        expect(res.text, contains('This LocalJam room has no browser player'));
        expect(res.text, contains('Install the app.'));
        expect(res.text, isNot(contains('http')), reason: 'no external URL');
        expect(res.text, isNot(contains('src=')));
        expect(res.headers['content-length'], '${res.body.length}');
      }
    });

    test('nothing is served under /web/', () async {
      final host = await hostWith(null);
      expect(
        (await raw(host, 'GET', '/web/main.dart.js')).status,
        HttpStatus.notFound,
      );
    });

    test('a site without index.html still serves the built-in page', () async {
      final host = await hostWith(site(withIndex: false));
      final res = await raw(host, 'GET', '/join');
      expect(res.text, contains('no browser player'));
      expect(
        (await raw(host, 'GET', '/web/main.dart.js')).status,
        HttpStatus.ok,
      );
    });
  });

  group('with a site (§1.1)', () {
    test('/ and /join serve index.html as html, never stored', () async {
      final host = await hostWith(site());
      for (final path in ['/', '/join']) {
        final res = await raw(host, 'GET', path);
        expect(res.status, HttpStatus.ok);
        expect(res.text, _indexHtml);
        expect(res.headers['content-type'], 'text/html; charset=utf-8');
        expect(res.headers['cache-control'], 'no-store');
        expect(res.headers['connection'], 'close');
      }
    });

    test('/web/<path> serves the exact key with its MIME, no-cache and its '
        'ETag', () async {
      final host = await hostWith(site());
      final js = await raw(host, 'GET', '/web/main.dart.js');
      expect(js.status, HttpStatus.ok);
      expect(js.text, _mainJs);
      expect(js.headers['content-type'], 'text/javascript; charset=utf-8');
      expect(js.headers['cache-control'], 'no-cache');
      expect(js.headers['etag'], etagOf(utf8.encode(_mainJs)));
      expect(js.headers['content-length'], '${utf8.encode(_mainJs).length}');
      expect(js.headers['connection'], 'close');

      final wasm = await raw(host, 'GET', '/web/canvaskit/canvaskit.wasm');
      expect(wasm.status, HttpStatus.ok);
      expect(wasm.body, _wasm);
      expect(wasm.headers['content-type'], 'application/wasm');
      expect(wasm.headers['etag'], etagOf(_wasm));

      // The query string is not part of the key (cache busters).
      final busted = await raw(host, 'GET', '/web/main.dart.js?v=123');
      expect(busted.status, HttpStatus.ok);
    });

    test('a matching If-None-Match is a 304 with no body', () async {
      final host = await hostWith(site());
      final etag = etagOf(utf8.encode(_mainJs));
      for (final header in [
        etag,
        'W/$etag',
        '"0000000000000000", $etag',
        '*',
      ]) {
        final res = await raw(
          host,
          'GET',
          '/web/main.dart.js',
          headers: {'If-None-Match': header},
        );
        expect(res.status, HttpStatus.notModified, reason: header);
        expect(res.body, isEmpty);
        expect(res.headers['etag'], etag);
        expect(res.headers['cache-control'], 'no-cache');
      }
      final stale = await raw(
        host,
        'GET',
        '/web/main.dart.js',
        headers: {'If-None-Match': '"0000000000000000"'},
      );
      expect(stale.status, HttpStatus.ok);
      expect(stale.text, _mainJs);
    });

    test('HEAD mirrors GET without a body', () async {
      final host = await hostWith(site());
      final head = await raw(host, 'HEAD', '/web/main.dart.js');
      expect(head.status, HttpStatus.ok);
      expect(head.body, isEmpty);
      expect(head.headers['etag'], etagOf(utf8.encode(_mainJs)));
      expect(head.headers['content-length'], '${utf8.encode(_mainJs).length}');
      final page = await raw(host, 'HEAD', '/join');
      expect(page.status, HttpStatus.ok);
      expect(page.body, isEmpty);
    });

    test('anything but GET or HEAD is 405', () async {
      final host = await hostWith(site());
      for (final method in ['POST', 'PUT', 'DELETE', 'OPTIONS', 'PATCH']) {
        for (final path in ['/', '/join', '/web/main.dart.js', '/web/nope']) {
          final res = await raw(host, method, path);
          expect(
            res.status,
            HttpStatus.methodNotAllowed,
            reason: '$method $path',
          );
          expect(res.headers['allow'], 'GET, HEAD');
        }
      }
    });

    test('only exact keys are served: everything else is 404', () async {
      final host = await hostWith(site());
      for (final path in [
        '/web/',
        '/web',
        '/web/nope.js',
        '/web/MAIN.dart.js',
        '/web//main.dart.js',
        // dart:io removes dot segments before routing (RFC 3986 §5.2.4), so
        // these climb out of /web/ — to paths that are not routes at all.
        '/web/../index.html',
        '/web/../../etc/passwd',
        '/web/%2e%2e/index.html',
        '/web/canvaskit%2F..%2Findex.html',
        '/web/%zz',
        '/web/canvaskit',
        '/web/canvaskit/',
        '/index.html',
        '/main.dart.js',
        '/joinx',
        '/join/',
        '/favicon.ico',
      ]) {
        final res = await raw(host, 'GET', path);
        expect(res.status, HttpStatus.notFound, reason: path);
      }
      // A percent-encoded spelling of a real key names that key.
      expect(
        (await raw(host, 'GET', '/web/canvaskit%2Fcanvaskit.wasm')).status,
        HttpStatus.ok,
      );
    });

    test('no token is needed, and a wrong one does not matter', () async {
      final host = await hostWith(site());
      final res = await raw(
        host,
        'GET',
        '/web/main.dart.js',
        headers: {'Authorization': 'Bearer wrong'},
      );
      expect(res.status, HttpStatus.ok);
    });

    test('a site set after start is served from then on', () async {
      final host = await hostWith(null);
      expect((await raw(host, 'GET', '/')).text, contains('no browser'));
      host.staticSite = site();
      expect((await raw(host, 'GET', '/')).text, _indexHtml);
      host.staticSite = null;
      expect((await raw(host, 'GET', '/')).text, contains('no browser'));
    });
  });

  group('the other planes are unchanged', () {
    test('media and artwork still need the token; /ws still upgrades and '
        'joins', () async {
      final host = await hostWith(site());
      expect(
        (await raw(host, 'GET', '/media/m_x')).status,
        HttpStatus.unauthorized,
      );
      expect(
        (await raw(host, 'GET', '/artwork/a_x')).status,
        HttpStatus.unauthorized,
      );
      expect(
        (await raw(
          host,
          'GET',
          '/media/m_x',
          headers: {'Authorization': 'Bearer ${host.token}'},
        )).status,
        HttpStatus.notFound,
      );
      expect(
        (await raw(host, 'GET', '/ws')).status,
        HttpStatus.upgradeRequired,
      );
      final guest = await joinGuest(host);
      expect(guest.selfPeerId, isNotEmpty);
    });
  });

  group('§9.1 bounds hold for the page too', () {
    test(
      'a header block past the cap loses the connection mid-headers',
      () async {
        final host = JamHostServer(
          sessionName: 'Web',
          staticSite: site(),
          maxRequestHeaderBytes: 4096,
        );
        await host.start(address: InternetAddress.loopbackIPv4);
        addTearDown(host.close);
        final socket = await Socket.connect(
          InternetAddress.loopbackIPv4,
          host.port,
        );
        addTearDown(socket.destroy);
        final received = <int>[];
        final closed = Completer<void>();
        socket.done.catchError((Object _) => socket);
        socket.listen(
          received.addAll,
          onError: (Object _) {},
          onDone: () {
            if (!closed.isCompleted) closed.complete();
          },
        );
        socket.add(ascii.encode('GET /join HTTP/1.1\r\nX-Pad: '));
        final pad = Uint8List(64 * 1024)..fillRange(0, 64 * 1024, 0x61);
        try {
          for (var i = 0; i < 16 && !closed.isCompleted; i++) {
            socket.add(pad);
            await socket.flush();
          }
        } catch (_) {
          // Destroyed under our feet: the point.
        }
        await closed.future.timeout(const Duration(seconds: 3));
        expect(received, isEmpty, reason: 'nothing parsed, nothing answered');
        await waitFor(() => host.debugOpenConnections == 0, reason: 'released');
      },
    );

    test('connections past the per-remote cap are refused before the page '
        'is served', () async {
      final host = JamHostServer(
        sessionName: 'Web',
        staticSite: site(),
        maxConnectionsPerRemote: 2,
      );
      await host.start(address: InternetAddress.loopbackIPv4);
      addTearDown(host.close);
      final held = [
        for (var i = 0; i < 2; i++)
          await Socket.connect(InternetAddress.loopbackIPv4, host.port),
      ];
      for (final s in held) {
        addTearDown(s.destroy);
      }
      await waitFor(() => host.debugOpenConnections == 2, reason: 'held');
      final res = await raw(host, 'GET', '/join');
      expect(res.status, HttpStatus.serviceUnavailable);
    });

    test('a POST that declares a huge body is answered 405 at once', () async {
      final host = await hostWith(site());
      final res = await raw(
        host,
        'POST',
        '/join',
        headers: {'Content-Length': '1000000000'},
      );
      expect(res.status, HttpStatus.methodNotAllowed);
      await waitFor(() => host.debugOpenConnections == 0, reason: 'released');
    });
  });
}
