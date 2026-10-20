/// The guest's default [JamMediaStore], picked at compile time: natively the
/// persistent cache directory under `getApplicationCacheDirectory()`
/// (`path_provider`), in a browser the in-memory store (docs/design/
/// WEB_GUEST.md D7). Only the native half imports `path_provider`.
library;

import '../media_store.dart';
import 'default_media_store_io.dart'
    if (dart.library.js_interop) 'default_media_store_web.dart'
    as impl;

/// Opens the platform's default guest media store. [maxBytes] caps it; null
/// is the platform's default (1 GB on disk natively,
/// `JamMemoryMediaStore.defaultMaxBytes` in a browser).
Future<JamMediaStore> openDefaultMediaStore({int? maxBytes}) =>
    impl.openPlatformMediaStore(maxBytes: maxBytes);
