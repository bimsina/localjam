/// The host's side of a catalog (PROTOCOL.md §6.6): where the songs it
/// offers come from. The server owns everything on the wire — rev and
/// count, the routes, the adds — and asks a [JamCatalogProvider] only what
/// is in the library and where a song's file is.
library;

import 'dart:io';

import 'package:localjam_core/localjam_core.dart';

/// A host's music library offered to the room as a catalog (§6.6), set with
/// `JamHostServer.setCatalog`.
///
/// The server reads [entries] once per `setCatalog` call (call it again
/// with the same provider when the library changed: a new `rev` when the
/// listing differs, nothing at all when it does not), and calls [open]
/// only when a song is actually added, [openForArtwork] only when someone
/// scrolled to its row and asked for its cover. Nothing is hashed, probed
/// or copied before that.
///
/// The server never serves the bytes [open] returns as such: they reach the
/// room only as a §6.1 playlist item, once added.
abstract class JamCatalogProvider {
  const JamCatalogProvider();

  /// What the catalog holds, in the order guests should list it. Each
  /// [CatalogEntry.catalogId] must be stable for the session and never
  /// reused for a different song within it; the server keeps the first of
  /// two entries that share an id, and drops entries whose id it could not
  /// put in a URL path (a `/`, a `\`, `..`, a NUL, or over 128 characters).
  List<CatalogEntry> get entries;

  /// The file behind [catalogId], to add it to the queue, or null when it
  /// is gone (deleted from the device since the listing, or unreadable).
  /// Called once per add — an id already queued, or whose content is
  /// already in the queue, is not opened again — and the file it returns
  /// must stay readable for the rest of the session once the song has been
  /// added (the host plays it from there).
  Future<File?> open(String catalogId);

  /// The file to read [catalogId]'s cover from for
  /// `GET /catalog/{id}/artwork`, or null for "no cover" (not remembered:
  /// asked again after the cover cache forgets it). The only call a cover
  /// read makes — never [open]. Defaults to [open]; a provider whose [open]
  /// is expensive (a scoped-storage copy) should answer only what it can
  /// read in place, so a cover read never copies a file.
  Future<File?> openForArtwork(String catalogId) => open(catalogId);

  /// The decoder-probed duration of [file] in µs, or null when this
  /// provider cannot probe (the default). The server prefers it to the
  /// library's [CatalogEntry.durationUs] and that to the tag-declared one,
  /// exactly as the host's own files prefer a probe to a tag (§5.5).
  Future<int?> probeDurationUs(String catalogId, File file) async => null;

  /// The MIME type the added item carries (§6.1). Defaults to one from the
  /// file's extension (the same mapping as the reference app's).
  String mimeFor(String catalogId, File file) => jamAudioMimeForPath(file.path);
}

/// Best-effort audio MIME type from a file extension, the same mapping the
/// reference app and CLI use for the host's own files.
String jamAudioMimeForPath(String path) {
  final slash = path.lastIndexOf(RegExp(r'[/\\]'));
  final dot = path.lastIndexOf('.');
  final ext = dot <= slash ? '' : path.substring(dot + 1).toLowerCase();
  return switch (ext) {
    'mp3' => 'audio/mpeg',
    'wav' => 'audio/wav',
    'flac' => 'audio/flac',
    'm4a' || 'mp4' => 'audio/mp4',
    'aac' => 'audio/aac',
    'ogg' || 'oga' => 'audio/ogg',
    'opus' => 'audio/opus',
    _ => 'application/octet-stream',
  };
}
