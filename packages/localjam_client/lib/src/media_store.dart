/// Where a guest keeps the media it prefetched (PROTOCOL.md §6.2), behind
/// one interface so the same [JamGuestEngine] runs natively and in a
/// browser:
///
/// * natively, [JamFileMediaStore] — the persistent, sha256-keyed
///   [JamMediaCache] directory (files survive sessions, so a rejoin
///   re-fetches nothing);
/// * in a browser, [JamMemoryMediaStore] — the raw bytes of each item in
///   memory under a byte budget (docs/design/WEB_GUEST.md D7: no file
///   system, and the tab dies long before a disk would fill).
///
/// The engine never sees a path or a URL it did not get from the store. A
/// stored item is named by an opaque *ref* (a file path natively, a
/// `memory:` key in a browser); [JamMediaStore.resolve] turns a ref into
/// what `LocaljamAudio.load` opens — the file path itself, or a `blob:` URL
/// minted on demand.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:localjam_net/guest.dart';

/// One in-progress write of an item's body into a [JamMediaStore]: the
/// [sink] the fetch streams into (§6.2), then exactly one of [commit] (the
/// body arrived whole and verified) or [discard] (it did not).
abstract class JamMediaWrite {
  /// Receives the body as it arrives.
  JamMediaSink get sink;

  /// Stores the verified body; returns the item's ref.
  Future<String> commit();

  /// Drops whatever arrived. Safe after the sink already abandoned it.
  Future<void> discard();
}

/// A guest's media storage (§6.2). See the library docs.
abstract class JamMediaStore {
  /// Whether an item must also *decode* before the guest reports it `ready`
  /// (§3.1, §6.3). True in a browser: the page cannot know a format plays
  /// until `decodeAudioData` says so (Ogg in Safari never does). Natively
  /// the platform decoders play everything the host serves, and `ready`
  /// follows the verified bytes as it always has.
  bool get verifiesDecode;

  /// Whether [item] could ever be stored: its `sha256` is a well-formed
  /// digest (§6.1). Ids arrive over the wire; anything else is never stored
  /// and never names anything.
  bool accepts(MediaItem item);

  /// The ref of [item] when the store already holds it whole (a lookup is a
  /// use: it counts as recent for eviction), else null.
  Future<String?> lookup(MediaItem item);

  /// Starts a write of [item]'s body. Only for an item [accepts].
  JamMediaWrite open(MediaItem item);

  /// What `LocaljamAudio.load` (and `probeDurationUs`) opens for [ref], or
  /// null when the bytes are gone (evicted, deleted underneath us).
  Future<String?> resolve(String ref);

  /// Lets go of whatever [resolve] minted for [ref] that holds memory of its
  /// own (a `blob:` URL), keeping the bytes. A no-op natively.
  void release(String ref) {}

  /// Forgets [ref]'s bytes now (an item that will never play here).
  Future<void> remove(String ref);

  /// Trims the store to its budget, least recently used first, never
  /// touching the items in [keep] — the current track and the prefetch
  /// window — nor [inFlight], the fetch being written. Returns the refs it
  /// evicted: those items are not ready any more (§6.3).
  Future<Set<String>> evict({
    required Iterable<MediaItem> keep,
    MediaItem? inFlight,
  });

  /// Cached artwork bytes for a §6.5 artwork id, or null on a miss.
  Future<Uint8List?> readArtwork(String artworkId);

  /// Caches artwork bytes (best effort; artwork ids are content-derived).
  Future<void> writeArtwork(String artworkId, Uint8List bytes);

  /// Releases everything the store holds for this session. Idempotent.
  Future<void> dispose() async {}
}
