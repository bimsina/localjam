/// Where a media fetch (PROTOCOL.md §6.2) puts the body as it arrives: the
/// platform-neutral half of `JamGuestClient.fetchMediaToSink`. Natively the
/// file-backed sink (`fetchMediaToFile`) streams to disk; in a browser, with
/// no file system, [JamBytesMediaSink] keeps the body in memory, and a
/// caller with its own store (IndexedDB, an in-memory cache with a budget)
/// implements [JamMediaSink] itself.
library;

import 'dart:typed_data';

/// The receiving end of one media fetch (§6.2).
///
/// The guest drives it in a fixed order: [open] once the host has answered
/// `200` (never for a refused request, so a failed request leaves nothing
/// behind), [add] for each body chunk, [close] once the body has ended or
/// the transfer stopped — always, even on failure — and then, only when the
/// transfer failed (a stall, an over-size body, a sha256 mismatch, a
/// connection that broke mid-body), [abandon] before `media_status: none` is
/// reported (§6.3). A sink that saw [close] without [abandon] holds the
/// whole, verified body.
abstract class JamMediaSink {
  /// Prepares to receive the body. Called once, before the first [add].
  Future<void> open() async {}

  /// One chunk of the body, in order. The chunk is the sink's to keep.
  void add(List<int> chunk);

  /// The body has ended (or the transfer stopped): flush and release.
  Future<void> close() async {}

  /// The transfer failed after [close]: discard whatever was received.
  Future<void> abandon() async {}
}

/// A [JamMediaSink] that keeps the body in memory — what `fetchMedia` uses,
/// and the natural sink in a browser. A fetch can only grow it to the size
/// the host gave (the playlist entry's `sizeBytes` or the `Content-Length`)
/// plus `JamGuestClient.sizeSlackBytes`, and never past the fetch's
/// `maxBytes` (§6.2), so its size is the host's claim, bounded.
class JamBytesMediaSink extends JamMediaSink {
  final BytesBuilder _builder = BytesBuilder(copy: false);

  /// Bytes received so far.
  int get length => _builder.length;

  @override
  void add(List<int> chunk) => _builder.add(chunk);

  @override
  Future<void> abandon() async => _builder.clear();

  /// The body received, handed over without a copy; the sink is empty
  /// afterwards.
  Uint8List takeBytes() => _builder.takeBytes();
}
