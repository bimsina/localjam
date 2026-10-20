/// The web player read out of the asset bundle (PROTOCOL.md §1.1): the
/// files under `assets/web/` keyed as the host serves them, `.gitkeep`
/// placeholders left out, no `index.html` meaning no player, and the same
/// 64 MB ceiling and MIME types as the CLI's `--web-dir`.
library;

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/state/error_log.dart';
import 'package:localjam_app/src/state/web_guest_bundle.dart';
import 'package:localjam_client/localjam_client.dart';

import 'fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('every file under assets/web/, keyed as the host serves it', () async {
    final site = await WebGuestBundle.read(FakeAssetBundle(webPlayerAssets()));
    expect(site, isNotNull);
    expect(site!.files.keys, [
      'assets/NOTICES',
      'assets/fonts/MaterialIcons-Regular.otf',
      'canvaskit/canvaskit.wasm',
      'index.html',
      'main.dart.js',
    ]);
    expect(utf8.decode(site.index!.bytes), '<!doctype html>player');
    expect(utf8.decode(site.files['canvaskit/canvaskit.wasm']!.bytes), 'wasm');
  });

  test(
    'each file carries StaticSite.mimeFor\'s type, as --web-dir does',
    () async {
      final site = await WebGuestBundle.read(
        FakeAssetBundle(webPlayerAssets()),
      );
      for (final MapEntry(key: path, value: file) in site!.files.entries) {
        expect(file.mime, StaticSite.mimeFor(path), reason: path);
      }
      expect(site.index!.mime, 'text/html; charset=utf-8');
      expect(
        site.files['main.dart.js']!.mime,
        'text/javascript; charset=utf-8',
      );
      expect(site.files['canvaskit/canvaskit.wasm']!.mime, 'application/wasm');
      expect(
        site.files['assets/fonts/MaterialIcons-Regular.otf']!.mime,
        'font/otf',
      );
    },
  );

  test('no index.html is no player: rooms keep the built-in page', () async {
    final assets = FakeAssetBundle(
      webPlayerAssets()..remove('assets/web/index.html'),
    );
    expect(await WebGuestBundle.read(assets), isNull);
    expect(
      assets.loads,
      0,
      reason: 'nothing read for a player that is not there',
    );
    // Only the placeholders a fresh checkout has.
    expect(
      await WebGuestBundle.read(
        FakeAssetBundle({
          'assets/web/.gitkeep': '',
          'assets/web/canvaskit/.gitkeep': '',
        }),
      ),
      isNull,
    );
  });

  test('over the bound is refused, and the reading stops there', () async {
    final files = webPlayerAssets();
    final total = [
      for (final MapEntry(:key, :value) in files.entries)
        if (key.startsWith('assets/web/') && !key.endsWith('.gitkeep'))
          utf8.encode(value).length,
    ].reduce((a, b) => a + b);

    expect(
      await WebGuestBundle.read(FakeAssetBundle(files), maxTotalBytes: total),
      isNotNull,
      reason: 'exactly at the bound is within it',
    );

    final before = JamErrorLog.entries.length;
    final assets = FakeAssetBundle(files);
    expect(await WebGuestBundle.read(assets, maxTotalBytes: total - 1), isNull);
    expect(JamErrorLog.entries.length, before + 1);
    expect(JamErrorLog.entries.last.context, 'web player');

    final early = FakeAssetBundle(files);
    expect(await WebGuestBundle.read(early, maxTotalBytes: 5), isNull);
    expect(early.loads, lessThan(3), reason: 'stops at the first file over');
  });

  test('the default bound is the CLI\'s', () {
    expect(maxWebGuestBundleBytes, 64 * 1024 * 1024);
    expect(WebGuestBundle().maxTotalBytes, maxWebGuestBundleBytes);
  });

  test('load reads once and keeps the answer', () async {
    final assets = FakeAssetBundle(webPlayerAssets());
    final bundle = WebGuestBundle(assets: assets);
    expect(bundle.site, isNull);
    final first = await bundle.load();
    final reads = assets.loads;
    expect(first, isNotNull);
    expect(bundle.site, same(first));
    expect(await bundle.load(), same(first));
    expect(assets.loads, reads, reason: 'not read again');
  });

  test('a bundle that cannot be read is no player, never an error', () async {
    final bundle = WebGuestBundle(
      assets: FakeAssetBundle(
        webPlayerAssets(),
        manifestError: const FormatException('torn manifest'),
      ),
    );
    final before = JamErrorLog.entries.length;
    expect(await bundle.load(), isNull);
    expect(bundle.site, isNull);
    expect(JamErrorLog.entries.length, before + 1);
  });

  test('a settled bundle answers without an asset bundle', () async {
    final site = StaticSite({
      'index.html': StaticFile.text('<p>', 'text/html; charset=utf-8'),
    });
    final bundle = WebGuestBundle.loaded(site);
    expect(bundle.site, same(site));
    expect(await bundle.load(), same(site));
    expect(await WebGuestBundle.loaded(null).load(), isNull);
  });

  test('the app bundles every declared assets/web/ directory, and its '
      'placeholders never reach the site', () async {
    // The placeholders are what keep the pubspec's directories buildable on
    // a checkout that never ran tool/build_web_guest.sh.
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final keys = manifest.listAssets();
    for (final dir in [
      '',
      'assets/',
      'assets/assets/fonts/',
      'assets/fonts/',
      'assets/fonts/fallback/',
      'assets/packages/cupertino_icons/assets/',
      'assets/shaders/',
      'canvaskit/',
      'canvaskit/chromium/',
      'icons/',
    ]) {
      expect(keys, contains('assets/web/$dir.gitkeep'));
    }
    // Whichever this checkout has — the placeholders alone, or a built
    // player — what loads is consistent with it.
    final site = await WebGuestBundle.read(rootBundle);
    if (!keys.contains('assets/web/index.html')) {
      expect(site, isNull);
    } else {
      expect(site!.index, isNotNull);
      expect(site.files.keys.where((k) => k.contains('.gitkeep')), isEmpty);
    }
  });
}
