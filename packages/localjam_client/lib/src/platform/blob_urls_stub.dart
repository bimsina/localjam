/// Non-browser [JamBlobUrls]: there are no object URLs outside a browser.
library;

import 'dart:typed_data';

import 'blob_urls.dart';

JamBlobUrls platformBlobUrls() => const _NoBlobUrls();

class _NoBlobUrls extends JamBlobUrls {
  const _NoBlobUrls();

  @override
  String create(Uint8List bytes, String mime) =>
      throw UnsupportedError('blob: URLs exist only in a browser');

  @override
  void revoke(String url) {}
}
