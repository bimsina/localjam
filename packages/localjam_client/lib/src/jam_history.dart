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
/// newest-N kept. A [JamHistoryRecorder] follows a live engine (created by
/// the session guards) and persists on every playlist/peer change,
/// debounced.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show immutable;
import 'package:localjam_net/localjam_net.dart';
import 'package:path_provider/path_provider.dart';

import 'guest_engine.dart';
import 'host_engine.dart';
import 'jam_engine.dart';

/// One queue entry of a recorded session.
@immutable
class JamHistoryTrack {
  const JamHistoryTrack({
    required this.item,
    this.addedByName,
    this.localPath,
  });

  /// The full playlist item (title/artist/album/artwork id/sha256/...).
  final MediaItem item;

  /// Display label of the contributor, resolved while they were still in
  /// the room ("You", "Host", "Funky Walrus"); null when never resolved.
  final String? addedByName;

  /// Where the bytes lived locally when last seen: a guest's cache path or
  /// a host's source path. May be stale — check [existsLocally].
  final String? localPath;

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

  Map<String, Object?> toJson() => {
        'item': item.toJson(),
        if (addedByName != null) 'addedByName': addedByName,
        if (localPath != null) 'localPath': localPath,
      };

  static JamHistoryTrack? fromJson(Object? json) {
    if (json is! Map) return null;
    final rawItem = json['item'];
    if (rawItem is! Map) return null;
    try {
      return JamHistoryTrack(
        item: MediaItem.fromJson(rawItem.cast<String, Object?>()),
        addedByName: json['addedByName'] as String?,
        localPath: json['localPath'] as String?,
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
    this.tracks = const [],
  });

  final String sessionId;
  final String sessionName;

  /// Whether this device hosted the session.
  final bool wasHost;

  final DateTime startedAt;
  final DateTime updatedAt;

  /// Everyone seen in the room over the session's lifetime (display names,
  /// this device excluded).
  final List<String> peerNames;

  /// The queue in its final order.
  final List<JamHistoryTrack> tracks;

  /// The subset of [tracks] whose bytes are still readable locally — what a
  /// "play it again" flow can seed a new session with.
  List<JamHistoryTrack> get replayableTracks =>
      [for (final t in tracks) if (t.existsLocally) t];

  Map<String, Object?> toJson() => {
        'sessionId': sessionId,
        'sessionName': sessionName,
        'wasHost': wasHost,
        'startedAt': startedAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'peerNames': peerNames,
        'tracks': [for (final t in tracks) t.toJson()],
      };

  static JamHistoryRecord? fromJson(Object? json) {
    if (json is! Map) return null;
    final sessionId = json['sessionId'];
    if (sessionId is! String || sessionId.isEmpty) return null;
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
      tracks: [
        if (json['tracks'] is List)
          for (final t in json['tracks'] as List) ?JamHistoryTrack.fromJson(t),
      ],
    );
  }
}

/// The on-disk history: one `<sessionId>.json` per record in [dir], pruned
/// to the newest [maxRecords] by `updatedAt`.
class JamHistoryStore {
  JamHistoryStore(this.dir, {this.maxRecords = 50})
      : assert(maxRecords > 0, 'maxRecords must be positive');

  /// The store directory. Created lazily on first save.
  final Directory dir;

  final int maxRecords;

  /// The default persistent store
  /// (`<application support>/localjam_history`), or null when the platform
  /// provides no storage (tests, headless embeddings).
  static Future<JamHistoryStore?> open() async {
    try {
      final base = await getApplicationSupportDirectory();
      return JamHistoryStore(Directory('${base.path}/localjam_history'));
    } catch (_) {
      return null;
    }
  }

  File _fileFor(String sessionId) =>
      File('${dir.path}/${sessionId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')}.json');

  /// Writes (or overwrites) [record] and prunes to [maxRecords].
  Future<void> save(JamHistoryRecord record) async {
    await dir.create(recursive: true);
    final file = _fileFor(record.sessionId);
    final tmp = File('${file.path}.part');
    await tmp.writeAsString(jsonEncode(record.toJson()), flush: true);
    await tmp.rename(file.path);
    await _prune();
  }

  /// All records, newest `updatedAt` first. Unreadable files are skipped.
  Future<List<JamHistoryRecord>> list() async {
    final records = <JamHistoryRecord>[];
    try {
      await for (final entity in dir.list()) {
        if (entity is! File || !entity.path.endsWith('.json')) continue;
        try {
          final record =
              JamHistoryRecord.fromJson(jsonDecode(await entity.readAsString()));
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

  /// Removes one record. Missing is fine.
  Future<void> delete(String sessionId) async {
    try {
      await _fileFor(sessionId).delete();
    } catch (_) {}
  }

  Future<void> _prune() async {
    final records = await list();
    for (final record in records.skip(maxRecords)) {
      await delete(record.sessionId);
    }
  }
}

/// Follows one live [JamEngine] and keeps its history record current:
/// tracks mirror the playlist (attribution resolved while contributors are
/// still present), peers accumulate over the session, saves are debounced.
/// Created by the engine's session guards; [dispose] flushes.
class JamHistoryRecorder {
  JamHistoryRecorder(this._engine, this._store)
      : _startedAt = DateTime.now();

  final JamEngine _engine;
  final JamHistoryStore _store;
  final DateTime _startedAt;

  final List<StreamSubscription<Object?>> _subs = [];

  /// Everyone ever seen in the room this session.
  final Set<String> _peerNames = {};

  /// Best attribution label seen per mediaId (contributors can leave;
  /// the first resolution sticks).
  final Map<String, String> _addedByNames = {};

  /// Last known local path per mediaId (a guest's fetch can complete after
  /// the playlist update that introduced the track).
  final Map<String, String> _localPaths = {};

  Timer? _debounce;
  bool _dirty = false;
  bool _disposed = false;

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
      _subs.add(engine.events.listen((event) {
        if (event.kind == JamHostEventKind.peerJoined) _markDirty();
      }));
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
      if (peer.clientName.trim().isNotEmpty) _peerNames.add(peer.clientName);
    }
    for (final item in _engine.playlist) {
      final label = _engine.addedByLabel(item, peers);
      if (label != null) _addedByNames.putIfAbsent(item.mediaId, () => label);
    }
    _refreshLocalPaths();
  }

  void _refreshLocalPaths() {
    if (_disposed) return;
    for (final item in _engine.playlist) {
      final path = _engine.localPathFor(item);
      if (path != null) _localPaths[item.mediaId] = path;
    }
  }

  JamHistoryRecord _buildRecord() => JamHistoryRecord(
        sessionId: _engine.sessionId,
        sessionName: _engine.sessionName,
        wasHost: _engine.selfPeerId == JamPermissions.hostPeerId,
        startedAt: _startedAt,
        updatedAt: DateTime.now(),
        peerNames: [..._peerNames]..sort(),
        tracks: [
          for (final item in _engine.playlist)
            JamHistoryTrack(
              item: item,
              addedByName: _addedByNames[item.mediaId],
              localPath: _localPaths[item.mediaId],
            ),
        ],
      );

  Future<void> _flush() async {
    if (!_dirty) return;
    _dirty = false;
    try {
      _collect();
      await _store.save(_buildRecord());
    } catch (_) {
      // History must never break a session.
    }
  }

  /// Stops following and writes the final record.
  Future<void> dispose() async {
    if (_disposed) return;
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
