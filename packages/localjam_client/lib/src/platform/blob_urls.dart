/// `blob:` URLs for media bytes held in memory (docs/design/WEB_GUEST.md
/// D7): the browser's `URL.createObjectURL`/`revokeObjectURL` in a browser,
/// and nothing anywhere else — picked at compile time, so the VM never
/// sees `package:web`.
library;

import 'dart:typed_data';

import 'blob_urls_stub.dart'
    if (dart.library.js_interop) 'blob_urls_web.dart'
    as impl;

/// Mints and revokes URLs a player can `fetch` for bytes the page holds.
abstract class JamBlobUrls {
  const JamBlobUrls();

  /// A URL naming [bytes] (typed [mime]) until [revoke]d.
  String create(Uint8List bytes, String mime);

  /// Ends [url]; fetching it fails afterwards.
  void revoke(String url);
}

/// The platform's [JamBlobUrls]: the browser's object URLs in a browser; on
/// other platforms one whose [JamBlobUrls.create] throws [UnsupportedError]
/// (native guests store files, not blobs).
JamBlobUrls browserBlobUrls() => impl.platformBlobUrls();
