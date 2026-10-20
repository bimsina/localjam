/// The browser player a host serves to web guests (PROTOCOL.md §1.1,
/// docs/design/WEB_GUEST.md "Packaging"): `apps/localjam_web`'s release
/// build, copied into `assets/web/` by `tool/build_web_guest.sh`, read back
/// out of the asset bundle once, into the [StaticSite] the host engine
/// serves from memory.
///
/// The build is not committed, so a checkout that never ran the script has
/// only the `.gitkeep` placeholders there: no `index.html`, no site, and a
/// room that answers its http join URL with the server's built-in "install
/// the app" page. Nothing about hosting waits on this or fails because of it.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:localjam_client/localjam_client.dart';

import 'error_log.dart';

/// Where the build sits in the asset bundle; bundle paths are the keys with
/// this cut off (`index.html`, `canvaskit/canvaskit.wasm`).
const String webGuestAssetPrefix = 'assets/web/';

/// The most the player may take, all files together — the same ceiling as
/// the CLI's `--web-dir` (`defaultMaxWebDirBytes`) and the build script's.
/// A Flutter web build is a few tens of megabytes; the whole site is held in
/// memory for the life of the process.
const int maxWebGuestBundleBytes = 64 * 1024 * 1024;

/// The app's web player, loaded at most once per process.
///
/// [load] is lazy: nothing is read until the first room starts, so a device
/// that only ever joins never holds the player's megabytes, and the first
/// frame never waits on them. The result — a site or null — is kept for the
/// process: the bundle cannot change under a running app.
class WebGuestBundle {
  /// Reads [assets] (the app's own [rootBundle] by default).
  WebGuestBundle({this.assets, this.maxTotalBytes = maxWebGuestBundleBytes});

  /// Already settled to [site] — tests, and anything that must not touch an
  /// asset bundle.
  WebGuestBundle.loaded(StaticSite? site)
    : assets = null,
      maxTotalBytes = maxWebGuestBundleBytes,
      _site = site,
      _loading = SynchronousFuture<StaticSite?>(site);

  /// The one the app uses.
  static final WebGuestBundle app = WebGuestBundle();

  /// Where the player is read from; null for [rootBundle].
  final AssetBundle? assets;

  /// Refused (null, logged) above this many bytes in all.
  final int maxTotalBytes;

  Future<StaticSite?>? _loading;
  StaticSite? _site;

  /// The player, once [load] has found one; null before that and when there
  /// is none.
  StaticSite? get site => _site;

  /// Reads the player out of the asset bundle the first time it is called;
  /// every call after that returns the same answer. Never throws: a bundle
  /// that cannot be read is no player, and the reason is logged.
  Future<StaticSite?> load() => _loading ??= _load();

  Future<StaticSite?> _load() async {
    try {
      final site = await read(
        assets ?? rootBundle,
        maxTotalBytes: maxTotalBytes,
      );
      if (site != null) {
        debugPrint('localjam: web player loaded: $site');
      }
      return _site = site;
    } catch (e, stack) {
      debugPrint('localjam: web player could not be loaded: $e');
      JamErrorLog.record(e, stack: stack, context: 'web player');
      return null;
    }
  }

  /// Every asset under [webGuestAssetPrefix] in [assets], keyed by its path
  /// below it, each with [StaticSite.mimeFor]'s MIME type — or null when
  /// there is no `index.html` among them, or when they add up to more than
  /// [maxTotalBytes].
  ///
  /// Kept in step with the CLI's `loadWebDir`: dot-files and anything under
  /// a dot-directory are left out (the `.gitkeep` placeholders), and so is a
  /// key [StaticSite.isValidPath] would refuse. An asset bundle has no sizes
  /// to check up front, so files are read one at a time and the load stops
  /// at the first that crosses the line: an oversized bundle costs at most
  /// the bound plus one file, and only until it is dropped.
  @visibleForTesting
  static Future<StaticSite?> read(
    AssetBundle assets, {
    int maxTotalBytes = maxWebGuestBundleBytes,
  }) async {
    final manifest = await AssetManifest.loadFromAssetBundle(assets);
    final keys = [
      for (final key in manifest.listAssets())
        if (key.startsWith(webGuestAssetPrefix)) key,
    ]..sort(); // Deterministic, as `--web-dir` is.
    if (!keys.contains('${webGuestAssetPrefix}index.html')) {
      debugPrint(
        'localjam: no web player bundled; rooms serve the built-in page',
      );
      return null;
    }
    final files = <String, StaticFile>{};
    var total = 0;
    for (final key in keys) {
      final path = key.substring(webGuestAssetPrefix.length);
      if (path.split('/').any((segment) => segment.startsWith('.'))) continue;
      if (!StaticSite.isValidPath(path)) continue;
      final data = await assets.load(key);
      total += data.lengthInBytes;
      if (total > maxTotalBytes) {
        final message =
            'web player is over the ${maxTotalBytes ~/ (1024 * 1024)} MB a '
            'host may hold; rooms serve the built-in page';
        debugPrint('localjam: $message');
        JamErrorLog.record(message, context: 'web player');
        return null;
      }
      files[path] = StaticFile(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        StaticSite.mimeFor(path),
      );
    }
    return StaticSite(files);
  }
}
