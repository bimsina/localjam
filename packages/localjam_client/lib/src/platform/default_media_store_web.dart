/// Browser default store: bytes in memory under a budget (D7), no
/// `path_provider`.
library;

import '../media_store.dart';
import '../media_store_memory.dart';

Future<JamMediaStore> openPlatformMediaStore({int? maxBytes}) async =>
    JamMemoryMediaStore(
      maxBytes: maxBytes ?? JamMemoryMediaStore.defaultMaxBytes,
    );
