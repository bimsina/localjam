/// Persistent jam history: every session leaves a local record — the queue
/// with attribution ("added by Silky Puffin"), who was in the room, when —
/// and tracks that still sit in the local cache (or, on a host, at their
/// original paths) are replayable by seeding a new session with them.
///
/// This is deliberately the feature the incumbents skip (Spotify Jam's
/// queue evaporates when the session ends): guests already cache every
/// track by content hash, so the record is nearly free.
///
/// Storage: one JSON file per session under the app-support directory,
/// newest-N kept, with the jam's cover as a small picture beside it
/// (`<sessionId>.cover.<ext>`). A [JamHistoryRecorder] follows a live engine
/// (created by the session guards) and persists on every playlist/peer
/// change, debounced.
///
/// A record outlives the app's container: a track's file is kept as an
/// absolute path (what older app versions read) and, inside the app's own
/// folders, as a [JamPathRef] that is resolved against the current folders
/// when the record is read ([JamAppRoots]).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show immutable, visibleForTesting;
import 'package:localjam_net/localjam_net.dart';
import 'package:path_provider/path_provider.dart';

import 'guest_engine.dart';
import 'host_engine.dart';
import 'jam_app_roots.dart';
import 'jam_engine.dart';

/// One queue entry of a recorded session.
@immutable
class JamHistoryTrack {
  const JamHistoryTrack({
    required this.item,
    this.addedByName,
    this.localPath,
    this.localRef,
  });

  /// The full playlist item (title/artist/album/artwork id/sha256/...).
  final MediaItem item;

  /// Display label of the contributor, resolved while they were still in
  /// the room ("You", "Host", "Funky Walrus"); null when never resolved.
  final String? addedByName;

  /// Where the bytes live locally: a guest's cache path or a host's source
  /// path. On a track read from a [JamHistoryStore] this is where the file
  /// is *now* — [localRef] resolved against this run's folders, else the
  /// stored path, else that path re-based from an older app container
  /// ([JamAppRoots.locate]) — and the stored path when none of those is
  /// there. May go stale while the app runs — check [existsLocally].
  final String? localPath;

  /// [localPath] relative to one of the app's own folders, as stored; null
  /// for a path outside them (a desktop user's own music, an Android
  /// library path) and for records written before references existed. The
  /// store derives it from [localPath] whenever it saves.
  final JamPathRef? localRef;

  /// Whether [localPath] still points at a readable file.
  bool get existsLocally {
    final path = localPath;
    if (path == null) return false;
    try {
      return File(path).existsSync();
    } catch (_) {
      return false;
    }
  }

  /// The stored form. With [roots], a [localPath] inside one of the app's
  /// folders also gets its reference; the absolute path stays for older
  /// app versions, which read nothing else.
  Map<String, Object?> toJson({JamAppRoots? roots}) {
    final path = localPath;
    final ref = (path == null ? null : roots?.refFor(path)) ?? localRef;
    return {
      'item': item.toJson(),
      'addedByName': ?addedByName,
      'localPath': ?path,
      if (ref != null) 'localRef': ref.toJson(),
    };
  }

  /// The track in [json], its file found against [roots] (see [localPath]).
  static JamHistoryTrack? fromJson(Object? json, {JamAppRoots? roots}) {
    if (json is! Map) return null;
    final rawItem = json['item'];
    if (rawItem is! Map) return null;
    try {
      final stored = json['localPath'] as String?;
      final ref = JamPathRef.fromJson(json['localRef']);
      final here = roots?.locate(ref: ref, absolutePath: stored);
      return JamHistoryTrack(
        item: MediaItem.fromJson(rawItem.cast<String, Object?>()),
        addedByName: json['addedByName'] as String?,
        localPath: here ?? stored ?? (ref == null ? null : roots?.resolve(ref)),
        localRef: ref,
      );
    } catch (_) {
      return null; // One corrupt entry never poisons the record.
    }
  }
}

/// One recorded session.
@immutable
class JamHistoryRecord {
  const JamHistoryRecord({
    required this.sessionId,
    required this.sessionName,
    required this.wasHost,
    required this.startedAt,
    required this.updatedAt,
    this.peerNames = const [],
    this.hostName,
    this.tracks = const [],
    this.coverFile,
    this.coverMediaId,
    this.coverPath,
  });

  final String sessionId;
  final String sessionName;

  /// Whether this device hosted the session.
  final bool wasHost;

  final DateTime startedAt;
  final DateTime updatedAt;

  /// Everyone seen in the room over the session's lifetime (display names,
  /// this device excluded). Includes the host on a guest's record, and the
  /// guests on the host's: both sides record everyone but themselves.
  final List<String> peerNames;

  /// Who hosted, on a jam this device joined: the host's display name as
  /// the room showed it (one of [peerNames]), so a record can put the host
  /// first as the room did. Null on a jam this device hosted (it was you),
  /// against a host that shared no name, and on records written before it
  /// was kept.
  final String? hostName;

  /// The queue in its final order.
  final List<JamHistoryTrack> tracks;

  /// The jam's cover, kept as a small picture beside the record
  /// (`<sessionId>.cover.<ext>` in the store's folder): the first song with
  /// art, as everywhere a jam is drawn — and still there when that song's
  /// file is not. Null when the jam had no art, or the picture could not be
  /// made.
  final String? coverFile;

  /// Which track [coverFile] shows.
  final String? coverMediaId;

  /// Where [coverFile] is on disk, on a record read from a
  /// [JamHistoryStore]; null otherwise. Not stored: it is the store's
  /// folder now. Read it with [JamHistoryStore.coverFor] — or straight off
  /// disk, which is what this is for.
  final String? coverPath;

  /// The subset of [tracks] whose bytes are still readable locally — what a
  /// "play it again" flow can seed a new session with.
  List<JamHistoryTrack> get replayableTracks => [
    for (final t in tracks)
      if (t.existsLocally) t,
  ];

  /// The stored form; [roots] gives the tracks their references
  /// ([JamHistoryTrack.toJson]).
  Map<String, Object?> toJson({JamAppRoots? roots}) => {
    'sessionId': sessionId,
    'sessionName': sessionName,
    'wasHost': wasHost,
    'startedAt': startedAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'peerNames': peerNames,
    if (hostName != null) 'hostName': hostName,
    'tracks': [for (final t in tracks) t.toJson(roots: roots)],
    if (coverFile != null)
      'cover': {'file': coverFile, 'mediaId': ?coverMediaId},
  };

  /// The record in [json]: its tracks' files found against [roots], its
  /// cover placed in [dir] (the store's folder).
  static JamHistoryRecord? fromJson(
    Object? json, {
    JamAppRoots? roots,
    Directory? dir,
  }) {
    if (json is! Map) return null;
    final sessionId = json['sessionId'];
    if (sessionId is! String || sessionId.isEmpty) return null;
    final hostName = json['hostName'];
    final cover = json['cover'];
    final coverFile = cover is Map ? cover['file'] : null;
    final coverMediaId = cover is Map ? cover['mediaId'] : null;
    // Only this record's own picture, by its own name: a file name from
    // disk never reaches outside the store or into another record's.
    final ownCover = coverFile is String && _isCoverFileOf(sessionId, coverFile)
        ? coverFile
        : null;
    return JamHistoryRecord(
      sessionId: sessionId,
      sessionName: (json['sessionName'] as String?) ?? 'Jam',
      wasHost: (json['wasHost'] as bool?) ?? false,
      startedAt:
          DateTime.tryParse(json['startedAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      updatedAt:
          DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      peerNames: [
        if (json['peerNames'] is List)
          ...(json['peerNames'] as List).whereType<String>(),
      ],
      hostName: hostName is String && hostName.trim().isNotEmpty
          ? hostName
          : null,
      tracks: [
        if (json['tracks'] is List)
          for (final t in json['tracks'] as List)
            ?JamHistoryTrack.fromJson(t, roots: roots),
      ],
      coverFile: ownCover,
      coverMediaId: ownCover != null && coverMediaId is String
          ? coverMediaId
          : null,
      coverPath: ownCover != null && dir != null
          ? '${dir.path}${Platform.pathSeparator}$ownCover'
          : null,
    );
  }
}

/// [sessionId] as a file-name stem: anything but letters, digits, `_` and
/// `-` becomes `_` (so it never holds a `.`, and `<stem>.cover.` is
/// unambiguous).
String _safeId(String sessionId) =>
    sessionId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');

bool _isCoverFileOf(String sessionId, String file) =>
    file.startsWith('${_safeId(sessionId)}.cover.') &&
    RegExp(r'^[A-Za-z0-9_-]+\.cover\.[a-z0-9]{2,5}$').hasMatch(file);

/// Makes a smaller picture of [image]: at most [maxEdge] pixels on its long
/// edge, encoded as PNG. Null (or a throw) when it cannot. See
/// [jamDownscaleCover].
typedef JamCoverDownscaler =
    Future<Uint8List?> Function(Uint8List image, int maxEdge);

/// The default [JamCoverDownscaler]: decodes [image] straight to at most
/// [maxEdge] on the long edge (`dart:ui`, the aspect kept) and encodes PNG.
Future<Uint8List?> jamDownscaleCover(Uint8List image, int maxEdge) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(image);
  // Takes the buffer and disposes of it.
  final codec = await ui.instantiateImageCodecWithSize(
    buffer,
    getTargetSize: (width, height) {
      if (math.max(width, height) <= maxEdge) return const ui.TargetImageSize();
      return width >= height
          ? ui.TargetImageSize(width: maxEdge)
          : ui.TargetImageSize(height: maxEdge);
    },
  );
  try {
    final frame = await codec.getNextFrame();
    try {
      final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
      return data?.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } finally {
      frame.image.dispose();
    }
  } finally {
    codec.dispose();
  }
}

/// The file extension for [bytes]' image format, by signature; null for
/// one this does not know.
String? _imageExtension(Uint8List bytes) {
  bool at(int offset, List<int> signature) {
    if (bytes.length < offset + signature.length) return false;
    for (var i = 0; i < signature.length; i++) {
      if (bytes[offset + i] != signature[i]) return false;
    }
    return true;
  }

  if (at(0, const [0xFF, 0xD8, 0xFF])) return 'jpg';
  if (at(0, const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) {
    return 'png';
  }
  if (at(0, const [0x47, 0x49, 0x46, 0x38])) return 'gif';
  if (at(0, const [0x52, 0x49, 0x46, 0x46]) &&
      at(8, const [0x57, 0x45, 0x42, 0x50])) {
    return 'webp';
  }
  return null;
}

/// The on-disk history: one `<sessionId>.json` per record in [dir], pruned
/// to the newest [maxRecords] by `updatedAt`, each with its cover picture
/// (`<sessionId>.cover.<ext>`) beside it.
class JamHistoryStore {
  JamHistoryStore(
    this.dir, {
    this.maxRecords = 50,
    JamAppRoots? roots,
    JamCoverDownscaler? downscaleCover,
  }) : assert(maxRecords > 0, 'maxRecords must be positive'),
       roots = roots ?? JamAppRoots.none,
       _downscale = downscaleCover ?? jamDownscaleCover;

  /// The store directory. Created lazily on first save.
  final Directory dir;

  final int maxRecords;

  /// The app's folders in this run: what tracks' paths are stored relative
  /// to, and resolved against when read ([JamHistoryTrack.localPath]).
  final JamAppRoots roots;

  final JamCoverDownscaler _downscale;

  /// A cover at or under this many bytes is kept as it came; a bigger one
  /// is made smaller ([coverEdge]).
  static const int keepCoverBytes = 64 * 1024;

  /// The long edge, in pixels, a cover is made smaller to.
  static const int coverEdge = 256;

  /// The default persistent store
  /// (`<application support>/localjam_history`), or null when the platform
  /// provides no storage (tests, headless embeddings).
  static Future<JamHistoryStore?> open() async {
    try {
      final base = await getApplicationSupportDirectory();
      return JamHistoryStore(
        Directory('${base.path}/localjam_history'),
        roots: await JamAppRoots.current(),
      );
    } catch (_) {
      return null;
    }
  }

  File _fileFor(String sessionId) =>
      File('${dir.path}/${_safeId(sessionId)}.json');

  /// Covers of records forgotten through this store, by session id, so an
  /// Undo that saves the record again brings its picture back too. A few,
  /// newest last.
  final Map<String, ({String file, Uint8List bytes})> _forgottenCovers = {};
  static const int _forgottenCoversKept = 4;

  /// Writes (or overwrites) [record] and prunes to [maxRecords].
  Future<void> save(JamHistoryRecord record) async {
    await dir.create(recursive: true);
    await _restoreForgottenCover(record);
    await _writeAtomically(
      _fileFor(record.sessionId),
      utf8.encode(jsonEncode(record.toJson(roots: roots))),
    );
    await _prune();
  }

  /// All records, newest `updatedAt` first, their tracks' files found in
  /// this run's folders. Unreadable files are skipped.
  Future<List<JamHistoryRecord>> list() async {
    final records = <JamHistoryRecord>[];
    try {
      await for (final entity in dir.list()) {
        if (entity is! File || !entity.path.endsWith('.json')) continue;
        try {
          final record = JamHistoryRecord.fromJson(
            jsonDecode(await entity.readAsString()),
            roots: roots,
            dir: dir,
          );
          if (record != null) records.add(record);
        } catch (_) {
          // Corrupt/partial file: skip.
        }
      }
    } catch (_) {
      return const []; // Directory missing: no history yet.
    }
    records.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return records;
  }

  /// Removes one record and its cover. Missing is fine. The cover is held
  /// in memory for a moment, so saving the record again (Undo) restores it.
  Future<void> delete(String sessionId) async {
    try {
      final record = _fileFor(sessionId);
      final json = jsonDecode(await record.readAsString());
      final cover = json is Map ? json['cover'] : null;
      final name = cover is Map ? cover['file'] : null;
      if (name is String && _isCoverFileOf(sessionId, name)) {
        final bytes = await File('${dir.path}/$name').readAsBytes();
        _forgottenCovers
          ..remove(sessionId)
          ..[sessionId] = (file: name, bytes: bytes);
        while (_forgottenCovers.length > _forgottenCoversKept) {
          _forgottenCovers.remove(_forgottenCovers.keys.first);
        }
      }
    } catch (_) {
      // No record, or no cover: nothing to hold on to.
    }
    await _remove(sessionId);
  }

  /// The cover picture of [record] ([JamHistoryRecord.coverFile]), or null
  /// when it has none or the file is gone.
  Future<Uint8List?> coverFor(JamHistoryRecord record) async {
    final name = record.coverFile;
    if (name == null || !_isCoverFileOf(record.sessionId, name)) return null;
    try {
      final bytes = await File('${dir.path}/$name').readAsBytes();
      return bytes.isEmpty ? null : bytes;
    } catch (_) {
      return null;
    }
  }

  /// Whether [sessionId]'s cover [file] is on disk.
  bool hasCover(String sessionId, String file) {
    if (!_isCoverFileOf(sessionId, file)) return false;
    try {
      return File('${dir.path}/$file').existsSync();
    } catch (_) {
      return false;
    }
  }

  /// Writes [artwork] as [sessionId]'s cover and returns its file name, or
  /// null when no picture could be made (the record then has no cover).
  /// Artwork at or under [keepCoverBytes] in a known format is kept as it
  /// is; anything else is made smaller ([coverEdge], PNG). Replaces any
  /// earlier cover of the session. Never throws.
  Future<String?> writeCover(String sessionId, Uint8List artwork) async {
    try {
      if (artwork.isEmpty) return null;
      final kept = artwork.length <= keepCoverBytes
          ? _imageExtension(artwork)
          : null;
      final Uint8List bytes;
      final String extension;
      if (kept != null) {
        bytes = artwork;
        extension = kept;
      } else {
        final smaller = await _downscale(artwork, coverEdge);
        if (smaller == null || smaller.isEmpty) return null;
        bytes = smaller;
        extension = 'png';
      }
      final name = '${_safeId(sessionId)}.cover.$extension';
      await dir.create(recursive: true);
      await _writeAtomically(File('${dir.path}/$name'), bytes);
      await _removeCovers(sessionId, except: name);
      return name;
    } catch (_) {
      return null;
    }
  }

  /// Removes [sessionId]'s cover, if any.
  Future<void> deleteCover(String sessionId) => _removeCovers(sessionId);

  Future<void> _remove(String sessionId) async {
    try {
      await _fileFor(sessionId).delete();
    } catch (_) {}
    await _removeCovers(sessionId);
  }

  Future<void> _removeCovers(String sessionId, {String? except}) async {
    final prefix = '${_safeId(sessionId)}.cover.';
    try {
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (!name.startsWith(prefix) || name == except) continue;
        try {
          await entity.delete();
        } catch (_) {}
      }
    } catch (_) {
      // No folder: no covers.
    }
  }

  Future<void> _restoreForgottenCover(JamHistoryRecord record) async {
    final forgotten = _forgottenCovers.remove(record.sessionId);
    if (forgotten == null || forgotten.file != record.coverFile) return;
    final file = File('${dir.path}/${forgotten.file}');
    try {
      if (!file.existsSync()) await _writeAtomically(file, forgotten.bytes);
    } catch (_) {
      // The record comes back without its picture.
    }
  }

  /// Temp + rename, so a crash never leaves a partial file under [file]'s
  /// name.
  static Future<void> _writeAtomically(File file, List<int> bytes) async {
    final tmp = File('${file.path}.part');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(file.path);
  }

  Future<void> _prune() async {
    final records = await list();
    for (final record in records.skip(maxRecords)) {
      await _remove(record.sessionId);
    }
  }
}

/// Follows one live [JamEngine] and keeps its history record current:
/// tracks mirror the playlist (attribution resolved while contributors are
/// still present), peers accumulate over the session, the host's name is
/// kept on a guest, the jam's cover is kept as a picture, saves are
/// debounced. Created by the engine's session guards; [dispose] flushes.
class JamHistoryRecorder {
  JamHistoryRecorder(this._engine, this._store) : _startedAt = DateTime.now();

  final JamEngine _engine;
  final JamHistoryStore _store;
  final DateTime _startedAt;

  final List<StreamSubscription<Object?>> _subs = [];

  /// Everyone ever seen in the room this session.
  final Set<String> _peerNames = {};

  /// The host's display name, on a guest: the last one it showed.
  String? _hostName;

  /// Best attribution label seen per mediaId (contributors can leave;
  /// the first resolution sticks).
  final Map<String, String> _addedByNames = {};

  /// Last known local path per mediaId (a guest's fetch can complete after
  /// the playlist update that introduced the track).
  final Map<String, String> _localPaths = {};

  /// The cover picture written for this session, and the track it shows.
  String? _coverFile;
  String? _coverMediaId;
  String? _coverArtworkId;

  /// Tries at the picture per track: a guest's artwork fetch can fail
  /// mid-reconnect and succeed on the next flush, but a track whose art
  /// never comes is not asked for forever.
  final Map<String, int> _coverTries = {};
  static const int _maxCoverTries = 3;

  /// How long one artwork read may take: a guest's fetch over a dying
  /// connection must not hold up a flush (or the session's close).
  static const _artworkTimeout = Duration(seconds: 5);
  static const _closingArtworkTimeout = Duration(seconds: 1);

  Timer? _debounce;
  bool _dirty = false;
  bool _disposing = false;
  bool _disposed = false;

  /// Writes run one after another, never two at once.
  Future<void> _writes = Future<void>.value();

  /// Debounce for coalescing bursts of playlist/peer events into one write.
  static const _saveDelay = Duration(seconds: 2);

  void start() {
    _subs.addAll([
      _engine.playlistUpdates.listen((_) => _markDirty()),
      // States drive local-path refreshes (a guest's fetch completing shows
      // up in prefetch state around track changes) AND peer-name capture —
      // peers ping through the playlist/state cadence often enough that a
      // dedicated per-engine presence stream isn't worth the coupling.
      _engine.states.listen((_) => _markDirty()),
    ]);
    _observePeers();
    _markDirty();
  }

  void _observePeers() {
    // Both engines expose a presence signal, just differently shaped.
    final engine = _engine;
    if (engine is JamGuestEngine) {
      _subs.add(engine.peerEvents.listen((_) => _markDirty()));
    } else if (engine is JamHostEngine) {
      _subs.add(
        engine.events.listen((event) {
          if (event.kind == JamHostEventKind.peerJoined ||
              event.kind == JamHostEventKind.peerLeft) {
            _markDirty();
          }
        }),
      );
    }
  }

  void _markDirty() {
    if (_disposed) return;
    _collect();
    _dirty = true;
    _debounce ??= Timer(_saveDelay, () {
      _debounce = null;
      unawaited(_flush());
    });
  }

  /// Snapshots what can only be resolved while the session is live.
  void _collect() {
    final peers = _engine.peers;
    for (final peer in peers) {
      _rememberAttendee(peer);
    }
    // The host is not a joined peer (§5.6), so a guest's roster leaves it
    // out — and a guest's record used to say a room of two had nobody in
    // it. On a host engine this is the device itself and stays excluded.
    final host = _engine.hostPeer;
    if (host != null && host.peerId != _engine.selfPeerId) {
      _rememberAttendee(host);
      final name = host.clientName.trim();
      if (name.isNotEmpty) _hostName = name;
    }
    for (final item in _engine.playlist) {
      final label = _engine.addedByLabel(item, peers);
      if (label != null) _addedByNames.putIfAbsent(item.mediaId, () => label);
    }
    _refreshLocalPaths();
  }

  /// Records one attendee's display name. Unnamed peers are skipped rather
  /// than recorded as an id: a history entry nobody recognizes is noise.
  void _rememberAttendee(PeerInfo peer) {
    final name = peer.clientName.trim();
    if (name.isNotEmpty) _peerNames.add(name);
  }

  void _refreshLocalPaths() {
    if (_disposed) return;
    for (final item in _engine.playlist) {
      final path = _engine.localPathFor(item);
      if (path != null) _localPaths[item.mediaId] = path;
    }
  }

  /// Keeps the cover picture on the jam's cover — the first song with art —
  /// making it only when that changes (or its file went missing). Failure
  /// means no picture, never a broken session.
  Future<void> _refreshCover() async {
    MediaItem? cover;
    for (final item in _engine.playlist) {
      if (item.artworkId != null) {
        cover = item;
        break;
      }
    }
    final current = _coverFile;
    final sessionId = _engine.sessionId;
    if (cover == null) {
      if (current != null) await _dropCover();
      return;
    }
    final present = current != null && _store.hasCover(sessionId, current);
    if (present && cover.mediaId == _coverMediaId) return;
    if (present && cover.artworkId == _coverArtworkId) {
      // Another song with the same picture (an album): nothing to redraw.
      _coverMediaId = cover.mediaId;
      return;
    }
    final tries = _coverTries[cover.mediaId] ?? 0;
    if (tries >= _maxCoverTries) {
      if (current != null) await _dropCover();
      return;
    }
    _coverTries[cover.mediaId] = tries + 1;
    Uint8List? art;
    try {
      art = await _engine
          .artworkFor(cover)
          .timeout(
            _disposing ? _closingArtworkTimeout : _artworkTimeout,
            onTimeout: () => null,
          );
    } catch (_) {
      art = null;
    }
    final written = art == null || art.isEmpty
        ? null
        : await _store.writeCover(sessionId, art);
    if (written == null) {
      // A picture of a song that is no longer the cover would be wrong.
      if (current != null) await _dropCover();
      return;
    }
    _coverFile = written;
    _coverMediaId = cover.mediaId;
    _coverArtworkId = cover.artworkId;
  }

  Future<void> _dropCover() async {
    _coverFile = null;
    _coverMediaId = null;
    _coverArtworkId = null;
    await _store.deleteCover(_engine.sessionId);
  }

  JamHistoryRecord _buildRecord() {
    final wasHost = _engine.selfPeerId == JamPermissions.hostPeerId;
    return JamHistoryRecord(
      sessionId: _engine.sessionId,
      sessionName: _engine.sessionName,
      wasHost: wasHost,
      startedAt: _startedAt,
      updatedAt: DateTime.now(),
      peerNames: [..._peerNames]..sort(),
      // A host's own record leaves it out: the host was you.
      hostName: wasHost ? null : _hostName,
      tracks: [
        for (final item in _engine.playlist)
          JamHistoryTrack(
            item: item,
            addedByName: _addedByNames[item.mediaId],
            localPath: _localPaths[item.mediaId],
          ),
      ],
      coverFile: _coverFile,
      coverMediaId: _coverFile == null ? null : _coverMediaId,
    );
  }

  Future<void> _flush() => _writes = _writes.then((_) => _write());

  Future<void> _write() async {
    if (!_dirty) return;
    _dirty = false;
    try {
      _collect();
      try {
        await _refreshCover();
      } catch (_) {
        // No picture this time.
      }
      await _store.save(_buildRecord());
    } catch (_) {
      // History must never break a session.
    }
  }

  /// Writes the record now rather than after the debounce — for tests that
  /// follow a record through a live session.
  @visibleForTesting
  Future<void> flushNow() {
    if (_disposed) return Future<void>.value();
    _dirty = true;
    return _flush();
  }

  /// Stops following and writes the final record.
  Future<void> dispose() async {
    if (_disposed || _disposing) return;
    _disposing = true;
    _debounce?.cancel();
    _debounce = null;
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    _subs.clear();
    // Final flush with everything the session ended with — force-dirty so
    // an empty debounce window still writes the closing state.
    _dirty = true;
    await _flush();
    _disposed = true;
  }
}
