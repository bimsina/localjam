/// Persistent, sha256-keyed media cache shared across jam sessions.
///
/// Files are stored as `<sha256>.<ext>` in one directory, so the same content
/// fetched in any session lands on the same path — rejoining a jam (or
/// joining a different jam that plays the same file) re-fetches nothing
/// (PROTOCOL.md §6.2: "sha256 lets guests cache across sessions").
///
/// Recency is tracked via file mtimes: every hit/seed touches the file, and
/// [evict] removes least-recently-used files once the directory exceeds
/// [maxBytes] — except protected paths (the current track and the prefetch
/// ahead window), which are never evicted even when the cap is exceeded.
library;

import 'dart:io';

import 'package:localjam_net/localjam_net.dart';

import 'media_mime.dart';

/// One sha256-keyed on-disk media cache directory.
class JamMediaCache {
  JamMediaCache(this.dir, {this.maxBytes = 1 << 30})
    : assert(maxBytes > 0, 'maxBytes must be positive');

  /// The cache directory. Created lazily on first write.
  final Directory dir;

  /// Soft size cap enforced by [evict] (default 1 GB). Protected paths may
  /// keep the directory above the cap.
  final int maxBytes;

  /// The cache path for [item]: `<sha256>.<ext>`, extension derived from the
  /// item's MIME type.
  File fileFor(MediaItem item) =>
      File('${dir.path}/${item.sha256}.${extensionForMime(item.mime)}');

  /// Returns the cached file for [item] if it exists with the expected size
  /// (touching its mtime, since a lookup is a use), or null on a miss. A
  /// wrong-sized file (interrupted write, stale partial) is treated as a
  /// miss; the caller's fetch overwrites it.
  Future<File?> lookup(MediaItem item) async {
    final file = fileFor(item);
    try {
      if (await file.length() != item.sizeBytes) return null;
    } catch (_) {
      return null; // Missing or unreadable: a miss.
    }
    await touch(file);
    return file;
  }

  /// Marks [file] as just-used for LRU purposes. Best-effort.
  Future<void> touch(File file) async {
    try {
      await file.setLastModified(DateTime.now());
    } catch (_) {
      // Filesystems that refuse mtime updates just get FIFO-ish eviction.
    }
  }

  /// Copies [source] into the cache under [item]'s sha-keyed name (via a
  /// temp file + rename, so a crash never leaves a full-sized partial), and
  /// returns the cached file. A same-sized existing entry is reused
  /// untouched-but-touched. Used to seed an uploader's own file so it never
  /// re-downloads its own song.
  Future<File> seed(File source, MediaItem item) async {
    final dest = fileFor(item);
    try {
      if (await dest.length() == item.sizeBytes) {
        await touch(dest);
        return dest;
      }
    } catch (_) {
      // Missing: fall through to the copy.
    }
    await dir.create(recursive: true);
    final tmp = File('${dest.path}.part');
    await source.copy(tmp.path);
    final stored = await tmp.rename(dest.path);
    await touch(stored);
    return stored;
  }

  /// Evicts least-recently-used files (by mtime) until the directory's total
  /// size is at most [maxBytes]. Paths in [protectedPaths] — the current
  /// track and the prefetch ahead window — are never evicted, so the total
  /// may stay above the cap when the protected set alone exceeds it.
  /// Best-effort: filesystem races are swallowed.
  Future<void> evict({Set<String> protectedPaths = const {}}) async {
    final entries = <({File file, int size, DateTime mtime})>[];
    var total = 0;
    try {
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        try {
          final stat = await entity.stat();
          total += stat.size;
          entries.add((file: entity, size: stat.size, mtime: stat.modified));
        } catch (_) {
          // Deleted underneath us: skip.
        }
      }
    } catch (_) {
      return; // Directory missing/unreadable: nothing to evict.
    }
    if (total <= maxBytes) return;
    entries.sort((a, b) => a.mtime.compareTo(b.mtime)); // Oldest first.
    for (final entry in entries) {
      if (total <= maxBytes) break;
      if (protectedPaths.contains(entry.file.path)) continue;
      try {
        await entry.file.delete();
        total -= entry.size;
      } catch (_) {
        // Already gone or busy: leave it for the next pass.
      }
    }
  }
}
