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

  /// A sha256 as the protocol defines it (§6.1): 64 lowercase hex digits.
  static final RegExp _sha256 = RegExp(r'^[0-9a-f]{64}$');

  /// An artworkId as the host derives it (§6.5): `a_` + the first 12 hex
  /// digits of the artwork's sha256.
  static final RegExp _artworkId = RegExp(r'^a_[0-9a-f]{12}$');

  /// The cache path for [item] (`<sha256>.<ext>`, extension from the item's
  /// MIME type), or null when [MediaItem.sha256] is not a sha256.
  ///
  /// Ids arrive over the wire and end up naming files, so they are attacker
  /// input as far as a guest is concerned: `sha256: "../../../.bashrc"`
  /// would otherwise let a hostile host on the LAN choose where the guest
  /// writes. Sanitising such a string into *some* filename answers the
  /// traversal but keeps the premise — that a host gets to invent cache
  /// keys. These ids have exactly one legal shape each, so anything else is
  /// simply not a cache entry: it misses, and no path is ever built from it.
  File? fileFor(MediaItem item) => _sha256.hasMatch(item.sha256)
      ? File('${dir.path}/${item.sha256}.${extensionForMime(item.mime)}')
      : null;

  /// The cache path for content-addressed artwork (§6.5), or null when
  /// [artworkId] is not one — see [fileFor].
  File? artworkFileFor(String artworkId) => _artworkId.hasMatch(artworkId)
      ? File('${dir.path}/$artworkId')
      : null;

  /// Whether [sha256] is a well-formed digest, and so cacheable.
  static bool isCacheableSha256(String sha256) => _sha256.hasMatch(sha256);

  /// Whether [artworkId] is a well-formed §6.5 artwork id.
  static bool isCacheableArtworkId(String artworkId) =>
      _artworkId.hasMatch(artworkId);

  /// Returns the cached file for [item] if it exists with the expected size
  /// (touching its mtime, since a lookup is a use), or null on a miss. A
  /// wrong-sized file (interrupted write, stale partial) is treated as a
  /// miss; the caller's fetch overwrites it.
  Future<File?> lookup(MediaItem item) async {
    final file = fileFor(item);
    if (file == null) return null; // Not a digest: not a cache entry.
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
  /// returns the cached file — null, caching nothing, when the item's sha256
  /// is malformed. A same-sized existing entry is reused untouched-but-
  /// touched. Used to seed an uploader's own file so it never re-downloads
  /// its own song.
  Future<File?> seed(File source, MediaItem item) async {
    final dest = fileFor(item);
    if (dest == null) return null;
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
