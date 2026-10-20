/// The browser player a host serves to web guests (PROTOCOL.md §1.1, 1.2):
/// an immutable, in-memory map of bundle files the embedder loads once —
/// the app from its asset bundle, the CLI from `--web-dir`.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';

/// One file of a [StaticSite]: its bytes, its MIME type, and the `ETag` the
/// host answers conditional requests with (§1.1) — the quoted first 16 hex
/// characters of the bytes' sha256, computed once, here.
@immutable
class StaticFile {
  /// [bytes] are held as an unmodifiable view: the caller must not mutate
  /// the underlying buffer afterwards (it is not copied — a web bundle is
  /// megabytes).
  StaticFile(Uint8List bytes, this.mime)
    : bytes = bytes.asUnmodifiableView(),
      etag = '"${sha256.convert(bytes).toString().substring(0, 16)}"';

  /// A UTF-8 text file (tests, small generated pages).
  factory StaticFile.text(String text, String mime) =>
      StaticFile(Uint8List.fromList(utf8.encode(text)), mime);

  final Uint8List bytes;

  /// The `Content-Type` it is served with, e.g. `text/javascript`.
  final String mime;

  /// Strong validator, quotes included: `"0123456789abcdef"`.
  final String etag;

  int get length => bytes.length;

  @override
  String toString() => 'StaticFile($mime, $length bytes, $etag)';
}

/// The web player bundle as the host serves it (§1.1): `GET /` and
/// `GET /join` answer with `index.html`, `GET /web/<path>` with the file
/// whose key is exactly `<path>`.
///
/// Keys are relative bundle paths with `/` separators — `index.html`,
/// `main.dart.js`, `canvaskit/canvaskit.wasm` — and nothing else is ever
/// served: the map is the whole site, so a path that is not one of its keys
/// (`../`, `%2e%2e`, a leading slash, a backslash) is a `404` by
/// construction, and the constructor refuses keys that could only be
/// mistakes.
@immutable
class StaticSite {
  StaticSite(Map<String, StaticFile> files) : files = Map.unmodifiable(files) {
    for (final path in this.files.keys) {
      if (!isValidPath(path)) {
        throw ArgumentError.value(path, 'files', 'is not a bundle path');
      }
    }
  }

  /// Every file, keyed by its bundle path. Unmodifiable.
  final Map<String, StaticFile> files;

  /// The page itself, served at `/` and `/join`. A site without one serves
  /// the built-in "no browser player" page there instead.
  StaticFile? get index => files['index.html'];

  /// Sum of every file's size.
  int get totalBytes => files.values.fold(0, (sum, f) => sum + f.length);

  /// A relative path of non-empty segments, none of them `.` or `..`, with
  /// no backslash, control character, `?` or `#`.
  static bool isValidPath(String path) {
    if (path.isEmpty || path.length > 1024) return false;
    if (path.contains(_forbidden)) return false;
    for (final segment in path.split('/')) {
      if (segment.isEmpty || segment == '.' || segment == '..') return false;
    }
    return true;
  }

  static final RegExp _forbidden = RegExp(r'[\\?#\x00-\x1f\x7f]');

  /// The MIME type for [path] by extension — what a loader without one of
  /// its own (the CLI's `--web-dir`, the app's asset bundle) should use.
  /// Unknown extensions are `application/octet-stream`.
  static String mimeFor(String path) {
    final slash = path.lastIndexOf('/');
    final name = path.substring(slash + 1).toLowerCase();
    final dot = name.lastIndexOf('.');
    if (dot < 0) return _octetStream;
    return _mimeByExtension[name.substring(dot + 1)] ?? _octetStream;
  }

  static const String _octetStream = 'application/octet-stream';

  /// What a Flutter web build contains, plus the usual web suspects. Files
  /// of a page only: a playlist item's MIME is not read from here but from
  /// `mimeForPath` (localjam_client's `media_mime.dart`, the CLI's `tui.dart`),
  /// which hosts must agree on because it is part of what an item describes.
  static const Map<String, String> _mimeByExtension = {
    'html': 'text/html; charset=utf-8',
    'htm': 'text/html; charset=utf-8',
    'js': 'text/javascript; charset=utf-8',
    'mjs': 'text/javascript; charset=utf-8',
    'css': 'text/css; charset=utf-8',
    'json': 'application/json',
    'map': 'application/json',
    'webmanifest': 'application/manifest+json',
    'txt': 'text/plain; charset=utf-8',
    'wasm': 'application/wasm',
    'png': 'image/png',
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'gif': 'image/gif',
    'webp': 'image/webp',
    'svg': 'image/svg+xml',
    'ico': 'image/x-icon',
    'woff': 'font/woff',
    'woff2': 'font/woff2',
    'ttf': 'font/ttf',
    'otf': 'font/otf',
    'mp3': 'audio/mpeg',
    'm4a': 'audio/mp4',
    'ogg': 'audio/ogg',
    'wav': 'audio/wav',
    // Flutter's asset manifest and font manifest ship as `.bin` / `.json`;
    // CanvasKit's ICU data and Skwasm's symbols are opaque.
    'bin': _octetStream,
    'symbols': 'text/plain; charset=utf-8',
  };

  @override
  String toString() => 'StaticSite(${files.length} files, $totalBytes bytes)';
}

/// The page a host with no [StaticSite] (or one without `index.html`)
/// serves at `/` and `/join` (§1.1): the room name is not known to it, so
/// it says only what the visitor can do. No external resources (D8: the
/// room has no internet).
const String builtInNoPlayerPage = '''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>LocalJam</title>
<style>
body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;font:17px/1.4 -apple-system,system-ui,sans-serif;background:#fff;color:#000;text-align:center}
@media (prefers-color-scheme:dark){body{background:#000;color:#fff}}
main{max-width:22rem;padding:1.5rem}
h1{font-size:1.5rem;margin:0 0 .5rem}
p{margin:0;opacity:.7}
</style>
</head>
<body>
<main>
<h1>LocalJam</h1>
<p>This LocalJam room has no browser player. Install the app.</p>
</main>
</body>
</html>
''';
