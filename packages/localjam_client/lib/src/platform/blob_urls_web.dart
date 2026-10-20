/// Browser [JamBlobUrls]: `URL.createObjectURL(new Blob([bytes]))`, which
/// `localjam_audio`'s web `load` fetches and decodes like any same-origin
/// URL, and `URL.revokeObjectURL`.
library;

import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'blob_urls.dart';

JamBlobUrls platformBlobUrls() => const _BrowserBlobUrls();

class _BrowserBlobUrls extends JamBlobUrls {
  const _BrowserBlobUrls();

  @override
  String create(Uint8List bytes, String mime) {
    final blob = web.Blob(
      <JSAny>[bytes.toJS].toJS,
      web.BlobPropertyBag(type: mime),
    );
    return web.URL.createObjectURL(blob);
  }

  @override
  void revoke(String url) => web.URL.revokeObjectURL(url);
}
