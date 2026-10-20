/// The native [JamMediaStore]: the persistent sha256-keyed [JamMediaCache]
/// directory (PROTOCOL.md §6.2 "sha256 lets guests cache across sessions").
/// Refs are the cached files' paths, and [resolve] hands them to the player
/// as they are. Behaviour is exactly what the guest engine did with the
/// cache directly before the store existed: bodies stream into
/// `<sha256>.<ext>.part` and are renamed into place once verified, artwork
/// lives beside them under its id, and eviction spares the prefetch window
/// and the in-flight destination (both the file and its `.part`).
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:localjam_net/localjam_net.dart';

import 'media_cache.dart';
import 'media_store.dart';

/// A [JamMediaStore] over one [JamMediaCache] directory.
class JamFileMediaStore extends JamMediaStore {
  JamFileMediaStore(this.cache);

  /// The cache directory this store reads and writes.
  final JamMediaCache cache;

  @override
  bool get verifiesDecode => false;

  @override
  bool accepts(MediaItem item) => cache.fileFor(item) != null;

  @override
  Future<String?> lookup(MediaItem item) async =>
      (await cache.lookup(item))?.path;

  @override
  JamMediaWrite open(MediaItem item) {
    final dest = cache.fileFor(item);
    if (dest == null) {
      throw ArgumentError.value(item.sha256, 'item.sha256', 'not a sha256');
    }
    return _FileWrite(cache, dest);
  }

  /// The file at [ref] while it exists — a ready item's file can still
  /// vanish (evicted by another session sharing the cache, cleared by the
  /// OS under storage pressure).
  @override
  Future<String?> resolve(String ref) async {
    try {
      return await File(ref).exists() ? ref : null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> remove(String ref) async {
    try {
      await File(ref).delete();
    } catch (_) {
      // Already gone.
    }
  }

  @override
  Future<Set<String>> evict({
    required Iterable<MediaItem> keep,
    MediaItem? inFlight,
  }) => cache.evict(
    protectedPaths: protectedPathsFor(
      keep,
      inFlight: inFlight,
      fileFor: cache.fileFor,
    ),
  );

  /// The cache paths of [wanted] and of the [inFlight] fetch — each item's
  /// file and its `.part` — as [fileFor] names them. The in-flight one is
  /// spared whatever the window says now: the room moving on mid-transfer
  /// must not delete the `.part` being written (the rename that completes
  /// it would fail, and count against a track that did nothing wrong), nor
  /// the file it just became.
  static Set<String> protectedPathsFor(
    Iterable<MediaItem> wanted, {
    MediaItem? inFlight,
    required File? Function(MediaItem item) fileFor,
  }) => {
    for (final item in [...wanted, ?inFlight])
      if (fileFor(item) case final file?) ...[file.path, '${file.path}.part'],
  };

  @override
  Future<Uint8List?> readArtwork(String artworkId) async {
    // The id comes from the host and names a file: an id that is not a §6.5
    // artwork id is a permanent cache miss, and no path is built from it.
    final file = cache.artworkFileFor(artworkId);
    if (file == null) return null;
    try {
      final bytes = await file.readAsBytes();
      return bytes.isEmpty ? null : bytes;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> writeArtwork(String artworkId, Uint8List bytes) async {
    final file = cache.artworkFileFor(artworkId);
    if (file == null) return;
    try {
      await cache.dir.create(recursive: true);
      final tmp = File('${file.path}.part');
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(file.path);
    } catch (_) {
      // Cache write failure: the bytes are still usable this session.
    }
  }
}

class _FileWrite extends JamMediaWrite {
  _FileWrite(this._cache, this._dest)
    : _part = File('${_dest.path}.part'),
      sink = JamFileMediaSink(File('${_dest.path}.part'));

  final JamMediaCache _cache;
  final File _dest;
  final File _part;

  @override
  final JamFileMediaSink sink;

  @override
  Future<String> commit() async {
    final stored = await _part.rename(_dest.path);
    await _cache.touch(stored);
    return stored.path;
  }

  @override
  Future<void> discard() async {
    try {
      await _part.delete();
    } catch (_) {
      // Never written, or the sink already abandoned it.
    }
  }
}
