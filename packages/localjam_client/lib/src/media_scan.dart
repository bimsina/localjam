/// Local media discovery helpers for host UIs.
library;

import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'media_mime.dart';

/// Audio files sitting in the app's Documents directory (sorted), so files
/// pushed via `xcrun simctl` or saved by other apps show up as host playlist
/// candidates. Returns an empty list when the directory is missing or
/// unreadable.
Future<List<String>> findAudioFilesInDocuments() async {
  try {
    final docs = await getApplicationDocumentsDirectory();
    final found = <String>[];
    await for (final entity in docs.list()) {
      if (entity is File && isSupportedAudioPath(entity.path)) {
        found.add(entity.path);
      }
    }
    found.sort();
    return found;
  } catch (_) {
    return const [];
  }
}
