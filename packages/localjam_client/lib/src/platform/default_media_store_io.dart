/// Native default store: `getApplicationCacheDirectory()/localjam_media`,
/// shared across sessions so rejoining a jam re-fetches nothing (§6.2).
library;

import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../media_cache.dart';
import '../media_store.dart';
import '../media_store_file.dart';

Future<JamMediaStore> openPlatformMediaStore({int? maxBytes}) async {
  final dir = Directory(
    '${(await getApplicationCacheDirectory()).path}/localjam_media',
  );
  await dir.create(recursive: true);
  return JamFileMediaStore(JamMediaCache(dir, maxBytes: maxBytes ?? 1 << 30));
}
