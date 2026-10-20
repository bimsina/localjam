/// `localjam host --web-dir <path>`: a built web player directory loaded
/// into the [StaticSite] the host serves to browser guests (PROTOCOL.md
/// §1.1) — `flutter build web --base-href /web/` output, typically.
library;

import 'dart:io';

import 'package:localjam_net/localjam_net.dart';

/// Why a `--web-dir` could not be loaded.
class WebDirException implements Exception {
  const WebDirException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The default ceiling on a `--web-dir`'s total size. A Flutter web build is
/// a few megabytes; the whole site is held in memory for the room's life.
const int defaultMaxWebDirBytes = 64 * 1024 * 1024;

/// Reads every file under [dir], recursively, into a [StaticSite] keyed by
/// its path relative to [dir] with `/` separators (`index.html`,
/// `canvaskit/canvaskit.wasm`), each with [StaticSite.mimeFor]'s MIME type.
///
/// Links are not followed (a link inside a bundle that points out of it
/// would serve whatever it points at), and dot-files and dot-directories
/// (`.last_build_id`, `.DS_Store`) are left out. Throws [WebDirException]
/// when [dir] does not exist, or when the files add up to more than
/// [maxTotalBytes] — checked from each file's size before it is read, so an
/// oversized directory costs no memory.
Future<StaticSite> loadWebDir(
  Directory dir, {
  int maxTotalBytes = defaultMaxWebDirBytes,
}) async {
  if (!await dir.exists()) {
    throw WebDirException('no such directory: ${dir.path}');
  }
  final root = dir.absolute.path;
  final files = <String, StaticFile>{};
  var total = 0;
  final entries = await dir
      .list(recursive: true, followLinks: false)
      .where((e) => e is File)
      .cast<File>()
      .toList();
  // Deterministic order: the same directory always loads the same way.
  entries.sort((a, b) => a.path.compareTo(b.path));
  for (final file in entries) {
    final relative = _relative(root, file.absolute.path);
    if (relative == null) continue;
    if (relative.split('/').any((segment) => segment.startsWith('.'))) {
      continue;
    }
    total += await file.length();
    if (total > maxTotalBytes) {
      throw WebDirException(
        '${dir.path} is over the ${maxTotalBytes ~/ (1024 * 1024)} MB a web '
        'player may take',
      );
    }
    if (!StaticSite.isValidPath(relative)) continue; // `a?b`, control chars.
    files[relative] = StaticFile(
      await file.readAsBytes(),
      StaticSite.mimeFor(relative),
    );
  }
  return StaticSite(files);
}

String? _relative(String root, String path) {
  final prefix = root.endsWith(Platform.pathSeparator)
      ? root
      : '$root${Platform.pathSeparator}';
  if (!path.startsWith(prefix)) return null;
  return path.substring(prefix.length).replaceAll(Platform.pathSeparator, '/');
}
