/// Queue intents across both sides of a jam.
///
/// [JamEngine] abstracts the transport (`transportPlay`, `transportSeek`, …)
/// but not queue mutation: a host calls `setMedia`/`moveMediaItem`/
/// `removeMediaItem` directly, a guest sends the §5.2 request equivalents.
/// These four adapters close that gap in the app rather than widening the
/// engine's tested surface, so one queue UI drives either side.
library;

import 'dart:io';

import 'package:localjam_client/localjam_client.dart';

/// Selects [mediaId] as the current track.
Future<void> jamSetMedia(JamEngine engine, String mediaId) async {
  switch (engine) {
    case JamHostEngine():
      engine.setMedia(mediaId);
    case JamGuestEngine():
      await engine.requestSetMedia(mediaId);
  }
}

/// Moves [mediaId] to [toIndex].
Future<void> jamMoveItem(JamEngine engine, String mediaId, int toIndex) async {
  switch (engine) {
    case JamHostEngine():
      engine.moveMediaItem(mediaId, toIndex);
    case JamGuestEngine():
      await engine.requestQueueMove(mediaId, toIndex);
  }
}

/// Drops [mediaId] from the queue.
Future<void> jamRemoveItem(JamEngine engine, String mediaId) async {
  switch (engine) {
    case JamHostEngine():
      engine.removeMediaItem(mediaId);
    case JamGuestEngine():
      await engine.requestQueueRemove(mediaId);
  }
}

/// Contributes [file] to the room. On a host this registers the file in
/// place; on a guest it uploads (watch `JamGuestEngine.uploadProgress`).
///
/// [JamAddResult], not the bare [MediaItem]: media ids are content hashes, so
/// re-adding the same bytes is a no-op the protocol answers with the item it
/// already had (§6.4). That is indistinguishable from a silent failure to
/// whoever just picked the file — the caller needs to be able to say
/// "already in the queue".
Future<JamAddResult?> jamAddFile(JamEngine engine, File file) async {
  return switch (engine) {
    JamHostEngine() => engine.addMedia(file),
    JamGuestEngine() => engine.addMedia(file),
    _ => null,
  };
}

/// Whether this side may remove [item]: the room's `editQueue` capability,
/// or it being your own contribution — removing what you added is always
/// allowed (§5.6).
bool jamCanRemove(JamEngine engine, MediaItem item) =>
    engine.can(JamCapability.editQueue) || item.addedBy == engine.selfPeerId;
