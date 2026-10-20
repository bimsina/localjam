/// `localjam host --web-dir`: a directory becomes the [StaticSite] a host
/// serves browser guests (PROTOCOL.md §1.1).
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:localjam_cli/src/web_dir.dart';
import 'package:localjam_net/localjam_net.dart';
import 'package:test/test.dart';

Future<Directory> tempDir() async {
  final dir = await Directory.systemTemp.createTemp('localjam_webdir');
  addTearDown(() => dir.delete(recursive: true));
  return dir;
}

Future<void> put(Directory root, String path, List<int> bytes) async {
  final file = File('${root.path}/$path');
  await file.parent.create(recursive: true);
  await file.writeAsBytes(bytes);
}

void main() {
  test('loads a build recursively, keyed by relative path, MIME by '
      'extension', () async {
    final dir = await tempDir();
    await put(dir, 'index.html', utf8.encode('<!doctype html>'));
    await put(dir, 'main.dart.js', utf8.encode('main()'));
    await put(dir, 'canvaskit/canvaskit.wasm', [0, 0x61, 0x73, 0x6d]);
    await put(dir, 'assets/fonts/MaterialIcons-Regular.otf', [1, 2, 3]);
    await put(dir, 'assets/NOTICES', utf8.encode('licences'));

    final site = await loadWebDir(dir);
    expect(site.files.keys.toSet(), {
      'index.html',
      'main.dart.js',
      'canvaskit/canvaskit.wasm',
      'assets/fonts/MaterialIcons-Regular.otf',
      'assets/NOTICES',
    });
    expect(site.index!.bytes, utf8.encode('<!doctype html>'));
    expect(site.files['main.dart.js']!.mime, 'text/javascript; charset=utf-8');
    expect(site.files['canvaskit/canvaskit.wasm']!.mime, 'application/wasm');
    expect(
      site.files['assets/fonts/MaterialIcons-Regular.otf']!.mime,
      'font/otf',
    );
    expect(site.files['assets/NOTICES']!.mime, 'application/octet-stream');
    expect(site.totalBytes, 15 + 6 + 4 + 3 + 8);
  });

  test('leaves out dot-files and links', () async {
    final dir = await tempDir();
    final outside = await tempDir();
    await put(outside, 'secret.txt', utf8.encode('not yours'));
    await put(dir, 'index.html', utf8.encode('x'));
    await put(dir, '.last_build_id', utf8.encode('abc'));
    await put(dir, '.hidden/a.js', utf8.encode('a'));
    await Link('${dir.path}/escape.txt').create('${outside.path}/secret.txt');
    await Link('${dir.path}/out').create(outside.path);

    final site = await loadWebDir(dir);
    expect(site.files.keys, ['index.html']);
  });

  test('a directory over the budget is refused before it is read', () async {
    final dir = await tempDir();
    await put(dir, 'a.bin', Uint8List(600));
    await put(dir, 'b.bin', Uint8List(600));
    await expectLater(
      loadWebDir(dir, maxTotalBytes: 1000),
      throwsA(isA<WebDirException>()),
    );
    expect((await loadWebDir(dir, maxTotalBytes: 1200)).totalBytes, 1200);
  });

  test(
    'a missing directory is an error; one without index.html loads',
    () async {
      await expectLater(
        loadWebDir(Directory('${Directory.systemTemp.path}/no/such/dir/x')),
        throwsA(isA<WebDirException>()),
      );
      final dir = await tempDir();
      await put(dir, 'main.dart.js', utf8.encode('x'));
      final site = await loadWebDir(dir);
      expect(site.index, isNull, reason: 'the host serves its built-in page');
    },
  );

  test('a host serves what was loaded', () async {
    final dir = await tempDir();
    await put(dir, 'index.html', utf8.encode('<p>player</p>'));
    await put(dir, 'canvaskit/canvaskit.wasm', [0, 0x61, 0x73, 0x6d]);
    final host = JamHostServer(
      sessionName: 'Web',
      staticSite: await loadWebDir(dir),
    );
    await host.start(address: InternetAddress.loopbackIPv4);
    addTearDown(host.close);

    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    Future<HttpClientResponse> get(String path) async => (await client.getUrl(
      Uri.parse('http://127.0.0.1:${host.port}$path'),
    )).close();

    final page = await get('/join');
    expect(page.statusCode, 200);
    expect(await page.transform(utf8.decoder).join(), '<p>player</p>');
    final wasm = await get('/web/canvaskit/canvaskit.wasm');
    expect(wasm.statusCode, 200);
    expect(wasm.headers.contentType?.mimeType, 'application/wasm');
    await wasm.drain<void>();
  });
}
