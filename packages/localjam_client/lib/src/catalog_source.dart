/// Where a host's catalog (PROTOCOL.md §6.6) comes from: the songs the host
/// offers the room to browse and add, without hashing, probing or copying
/// any of them until someone actually adds one.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:localjam_audio/localjam_audio.dart';
import 'package:localjam_net/localjam_net.dart';

/// A music library a host can offer the room as a catalog (§6.6), handed to
/// [JamHostEngine.shareCatalog].
///
/// The engine calls [list] once per `shareCatalog` (call it again to
/// refresh), and [open] only when a song is actually needed: someone added
/// it, or someone scrolled to its row and the room asked for its cover.
abstract class JamCatalogSource {
  const JamCatalogSource();

  /// What the library holds, in the order guests should list it. Each
  /// [CatalogEntry.catalogId] must be stable for the session and never
  /// reused for a different song within it. May throw (a missing OS
  /// permission, say): [JamHostEngine.shareCatalog] passes that on and
  /// leaves the room's catalog as it was.
  Future<List<CatalogEntry>> list();

  /// The readable file behind [catalogId], or null when it is gone (deleted
  /// since the listing, unreadable, an id this source never listed). Called
  /// more than once for one id — to add it, and to read its cover — so it
  /// should be cheap when it can be, and a file it returned must stay
  /// readable for the rest of the session once the song has been added (the
  /// host plays it from there).
  Future<File?> open(String catalogId);

  /// The file to read [catalogId]'s cover from when the room asks for it
  /// (`GET /catalog/{id}/artwork`), or null for "no cover". Defaults to
  /// [open]; a source whose [open] is expensive (a scoped-storage copy)
  /// answers only what it can read in place, so browsing never copies.
  Future<File?> openForArtwork(String catalogId) => open(catalogId);
}

/// The device's music library ([JamMediaLibrary]: Android MediaStore) as a
/// catalog source.
///
/// [list] queries the library ([JamMediaLibrary.queryAudio]) and maps every
/// track with [entryFor] — `catalogId` `c_<MediaStore id>`, the library's
/// title/artist/album, its duration (ms → µs) and size, and `hasArtwork`
/// left unknown: nothing is opened at listing time. [open] resolves a track
/// to a readable file with [JamMediaLibrary.resolve], which uses the direct
/// path when the OS exposes one and otherwise copies the content into the
/// app's cache (scoped storage), exactly as the library picker does; the
/// result is remembered for the session, so adding a song twice copies it
/// once. Covers ([openForArtwork]) are read only from a direct path that
/// exists and is readable: a song without one shows no cover rather than
/// being copied just to be browsed.
///
/// On a platform without a library ([JamMediaLibrary.isSupported] false:
/// iOS, desktop, the web) [list] returns an empty list rather than
/// throwing — sharing it offers an empty catalog, which guests read as
/// "nothing to browse" — so an app should only offer "Share my music
/// library" where [JamMediaLibrary.isSupported] is true. A missing audio
/// permission makes [list] throw [JamLibraryPermissionException]; asking
/// for it is the app's.
class JamMediaLibraryCatalogSource extends JamCatalogSource {
  /// [query] and [resolve] default to [JamMediaLibrary.queryAudio] and
  /// [JamMediaLibrary.resolve]; tests hand in their own.
  JamMediaLibraryCatalogSource({
    @visibleForTesting Future<List<JamLibraryTrack>> Function()? query,
    @visibleForTesting Future<String?> Function(JamLibraryTrack track)? resolve,
  }) : _query = query ?? JamMediaLibrary.queryAudio,
       _resolve = resolve ?? JamMediaLibrary.resolve;

  final Future<List<JamLibraryTrack>> Function() _query;
  final Future<String?> Function(JamLibraryTrack track) _resolve;

  /// catalogId → the library track it names, as of the last [list].
  Map<String, JamLibraryTrack> _tracks = const {};

  /// catalogId → the path [open] resolved it to (or is resolving it to).
  final Map<String, Future<String?>> _resolved = {};

  /// The catalog id of [track]: `c_<MediaStore id>` (§6.6).
  static String catalogIdFor(JamLibraryTrack track) => 'c_${track.id}';

  /// The catalog entry for [track]: its library metadata, nothing read from
  /// the file. A MediaStore placeholder (`<unknown>`) or blank artist or
  /// album reads as absent, as do a zero duration or size.
  static CatalogEntry entryFor(JamLibraryTrack track) {
    final durationMs = track.durationMs;
    return CatalogEntry(
      catalogId: catalogIdFor(track),
      title: track.title,
      artist: _known(track.artist),
      album: _known(track.album),
      durationUs: durationMs != null && durationMs > 0
          ? durationMs * 1000
          : null,
      sizeBytes: track.sizeBytes > 0 ? track.sizeBytes : null,
    );
  }

  static String? _known(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty || trimmed == '<unknown>') {
      return null;
    }
    return trimmed;
  }

  @override
  Future<List<CatalogEntry>> list() async {
    final tracks = await _query();
    final byId = <String, JamLibraryTrack>{};
    final entries = <CatalogEntry>[];
    for (final track in tracks) {
      final id = catalogIdFor(track);
      if (byId.containsKey(id)) continue; // First of two wins, as on the wire.
      byId[id] = track;
      entries.add(entryFor(track));
    }
    // A track whose content changed under the same id resolves afresh.
    _resolved.removeWhere(
      (id, _) => byId[id]?.contentUri != _tracks[id]?.contentUri,
    );
    _tracks = byId;
    return entries;
  }

  @override
  Future<File?> open(String catalogId) async {
    final track = _tracks[catalogId];
    if (track == null) return null;
    var pending = _resolved[catalogId];
    if (pending != null) {
      final path = await pending;
      if (path != null && File(path).existsSync()) return File(path);
      // Gone since (a cache copy cleared): resolve again.
      if (identical(_resolved[catalogId], pending)) _resolved.remove(catalogId);
    }
    pending = _resolveQuietly(track);
    _resolved[catalogId] = pending;
    final path = await pending;
    if (path == null || !File(path).existsSync()) {
      if (identical(_resolved[catalogId], pending)) _resolved.remove(catalogId);
      return null;
    }
    return File(path);
  }

  @override
  Future<File?> openForArtwork(String catalogId) async {
    final path = _tracks[catalogId]?.path;
    if (path == null) return null;
    final file = File(path);
    try {
      final handle = await file.open();
      await handle.close();
      return file;
    } catch (_) {
      return null; // Missing or unreadable in place: no cover.
    }
  }

  Future<String?> _resolveQuietly(JamLibraryTrack track) async {
    try {
      return await _resolve(track);
    } catch (error) {
      debugPrint('localjam: could not open library track ${track.id} ($error)');
      return null;
    }
  }
}

/// One catalog add that landed on a host ([JamHostEngine.catalogAdds]): an
/// entry of the host's library became a playlist item — "Mia added Night
/// Drive from your library".
@immutable
class JamCatalogAdd {
  const JamCatalogAdd({
    required this.peerId,
    required this.mediaId,
    required this.catalogId,
    this.entry,
  });

  /// Who the item is credited to: the requesting guest's peerId, or
  /// [JamPermissions.hostPeerId] for the host's own
  /// [JamHostEngine.addFromCatalog].
  final String peerId;

  /// The playlist item it became (already in the playlist when this is
  /// delivered).
  final String mediaId;

  /// The catalog entry that was added.
  final String catalogId;

  /// That entry as the catalog listed it, when it still does.
  final CatalogEntry? entry;

  /// Whether the host added it itself.
  bool get byHost => peerId == JamPermissions.hostPeerId;

  @override
  String toString() => 'JamCatalogAdd($catalogId -> $mediaId by $peerId)';
}

/// What one [JamGuestEngine.requestCatalogAddCounted] asked the host for
/// (§6.6). The host's answer is the playlist (and a `busy` on
/// [JamGuestEngine.errors] for what did not fit).
@immutable
class JamCatalogAddRequest {
  const JamCatalogAddRequest({required this.sent, this.dropped = 0});

  /// How many ids the request carried: 0 when nothing was sent.
  final int sent;

  /// How many distinct ids were left out because the call carried more
  /// than [JamGuestEngine.maxCatalogAddsPerCall]; not sent, so not added.
  final int dropped;

  /// Whether a request reached the connection.
  bool get delivered => sent > 0;

  @override
  String toString() => 'JamCatalogAddRequest(sent: $sent, dropped: $dropped)';
}
