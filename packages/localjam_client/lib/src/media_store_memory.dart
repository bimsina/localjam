/// The browser's [JamMediaStore] (docs/design/WEB_GUEST.md D7): each
/// prefetched item's raw bytes as one [Uint8List] in memory, under a byte
/// budget, evicted least recently used first — never an item the engine
/// says it still wants (the current track and the next, PROTOCOL.md §6.2's
/// prefetch window) and never the one being fetched.
///
/// Nothing here is decoded: the player decodes one item at a time (`load`
/// replaces its single `AudioBuffer`), and a 5-minute track's PCM is
/// ~100 MB where its mp3 is ~5 MB. What the player opens is a `blob:` URL,
/// minted by [JamMemoryMediaStore.resolve] only when asked (a `load` or a
/// decode probe), released with [JamMemoryMediaStore.release] once a probe
/// is done with it, and revoked whenever its bytes leave the store, so a
/// URL never outlives the bytes it names — nor keeps them alive.
///
/// Pure Dart: the URL minting is a [JamBlobUrls] the caller injects (the
/// browser's `URL.createObjectURL` by default), so the budget and eviction
/// rules are unit-tested on the VM.
library;

import 'dart:typed_data';

import 'package:localjam_net/guest.dart';

import 'media_store.dart';
import 'platform/blob_urls.dart';

export 'platform/blob_urls.dart' show JamBlobUrls;

/// A [JamMediaStore] that keeps every body in memory under [maxBytes].
class JamMemoryMediaStore extends JamMediaStore {
  JamMemoryMediaStore({
    this.maxBytes = defaultMaxBytes,
    JamBlobUrls? blobUrls,
    this.verifiesDecode = true,
  }) : assert(maxBytes > 0, 'maxBytes must be positive'),
       _urls = blobUrls ?? browserBlobUrls();

  /// The default budget: room for a handful of compressed tracks next to
  /// the one decoded buffer (~100 MB for 5 minutes) and a decode probe's
  /// transient one, well under where mobile tabs are killed (~1 GB).
  static const int defaultMaxBytes = 192 << 20;

  /// Budget for the raw bytes held. Items the engine protects may keep the
  /// store above it (the current and next track alone can exceed it).
  final int maxBytes;

  @override
  final bool verifiesDecode;

  final JamBlobUrls _urls;

  /// Entries by sha256, in insertion order; recency is [_Entry.lastUse].
  final Map<String, _Entry> _entries = {};
  final Map<String, Uint8List> _artwork = {};
  int _clock = 0;
  bool _disposed = false;

  /// Artwork kept per session at most (covers are small and deduped per
  /// album, §6.5; this only bounds a hostile playlist).
  static const int _maxArtwork = 64;

  static const String _scheme = 'memory:';

  static final RegExp _sha256 = RegExp(r'^[0-9a-f]{64}$');

  /// Bytes currently held (raw bodies only).
  int get totalBytes {
    var total = 0;
    for (final entry in _entries.values) {
      total += entry.bytes.length;
    }
    return total;
  }

  /// The refs currently held, least recently used first (for tests and
  /// diagnostics).
  List<String> get refsByRecency {
    final entries = _entries.entries.toList()
      ..sort((a, b) => a.value.lastUse.compareTo(b.value.lastUse));
    return [for (final e in entries) '$_scheme${e.key}'];
  }

  /// The ref an item is stored under.
  static String refFor(MediaItem item) => '$_scheme${item.sha256}';

  static String? _keyOf(String ref) =>
      ref.startsWith(_scheme) ? ref.substring(_scheme.length) : null;

  @override
  bool accepts(MediaItem item) => _sha256.hasMatch(item.sha256);

  @override
  Future<String?> lookup(MediaItem item) async {
    final entry = _entries[item.sha256];
    if (entry == null) return null;
    if (item.sizeBytes > 0 && entry.bytes.length != item.sizeBytes) {
      return null;
    }
    entry.lastUse = ++_clock;
    return refFor(item);
  }

  @override
  JamMediaWrite open(MediaItem item) {
    if (!accepts(item)) {
      throw ArgumentError.value(item.sha256, 'item.sha256', 'not a sha256');
    }
    return _MemoryWrite(this, item);
  }

  void _store(MediaItem item, Uint8List bytes) {
    if (_disposed) return;
    _drop(item.sha256);
    _entries[item.sha256] = _Entry(bytes, item.mime, ++_clock);
  }

  @override
  Future<String?> resolve(String ref) async {
    final key = _keyOf(ref);
    final entry = key == null ? null : _entries[key];
    if (entry == null) return null;
    entry.lastUse = ++_clock;
    return entry.url ??= _urls.create(entry.bytes, entry.mime);
  }

  @override
  void release(String ref) {
    final key = _keyOf(ref);
    final entry = key == null ? null : _entries[key];
    final url = entry?.url;
    if (url == null) return;
    entry!.url = null;
    _urls.revoke(url);
  }

  @override
  Future<void> remove(String ref) async {
    final key = _keyOf(ref);
    if (key != null) _drop(key);
  }

  void _drop(String key) {
    final entry = _entries.remove(key);
    final url = entry?.url;
    if (url != null) _urls.revoke(url);
  }

  @override
  Future<Set<String>> evict({
    required Iterable<MediaItem> keep,
    MediaItem? inFlight,
  }) async {
    final protected = {
      for (final item in [...keep, ?inFlight]) item.sha256,
    };
    var total = totalBytes;
    final evicted = <String>{};
    if (total <= maxBytes) return evicted;
    final candidates = _entries.entries.toList()
      ..sort((a, b) => a.value.lastUse.compareTo(b.value.lastUse));
    for (final candidate in candidates) {
      if (total <= maxBytes) break;
      if (protected.contains(candidate.key)) continue;
      total -= candidate.value.bytes.length;
      _drop(candidate.key);
      evicted.add('$_scheme${candidate.key}');
    }
    return evicted;
  }

  @override
  Future<Uint8List?> readArtwork(String artworkId) async => _artwork[artworkId];

  @override
  Future<void> writeArtwork(String artworkId, Uint8List bytes) async {
    if (_disposed) return;
    if (_artwork.length >= _maxArtwork) _artwork.remove(_artwork.keys.first);
    _artwork[artworkId] = bytes;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final key in _entries.keys.toList()) {
      _drop(key);
    }
    _artwork.clear();
  }
}

class _Entry {
  _Entry(this.bytes, this.mime, this.lastUse);

  final Uint8List bytes;
  final String mime;
  int lastUse;

  /// The `blob:` URL minted for [bytes], while one is live.
  String? url;
}

class _MemoryWrite extends JamMediaWrite {
  _MemoryWrite(this._store, this._item);

  final JamMemoryMediaStore _store;
  final MediaItem _item;

  @override
  final JamBytesMediaSink sink = JamBytesMediaSink();

  @override
  Future<String> commit() async {
    _store._store(_item, sink.takeBytes());
    return JamMemoryMediaStore.refFor(_item);
  }

  @override
  Future<void> discard() async => sink.takeBytes();
}
