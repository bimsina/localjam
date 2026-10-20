/// A jam's one cover (D4, N5): the first song in its queue that has art.
///
/// One jam used to wear several covers on the same phone: the page it ended
/// on showed the song that was playing, Home and Invite followed the playing
/// song too, and Recent and Past jams showed the first song with art. Every
/// place that draws a live or just-ended jam now asks this, and Past jams
/// applies the same rule to the record it reads back.
library;

import 'dart:typed_data';

import 'package:localjam_client/localjam_client.dart';

/// The songs that could give [queue] its cover, in queue order.
Iterable<MediaItem> jamCoverCandidates(Iterable<MediaItem> queue) =>
    queue.where((item) => item.artworkId != null);

/// What [jamCoverOf] depends on: the artwork ids in queue order. A reader
/// re-reads only when this changes.
String jamCoverKey(JamEngine engine) => [
  for (final item in jamCoverCandidates(engine.playlist)) item.artworkId,
].join('|');

/// The cover of [engine]'s jam: the first song in the queue whose art can
/// be read (a song whose art cannot be read hands over to the next). Null
/// when no song has any. Never throws.
Future<Uint8List?> jamCoverOf(JamEngine engine) async {
  for (final item in jamCoverCandidates(List.of(engine.playlist))) {
    try {
      final bytes = await engine.artworkFor(item);
      if (bytes != null && bytes.isNotEmpty) return bytes;
    } catch (_) {
      // Unreadable: the next song with art speaks for the jam.
    }
  }
  return null;
}
