/// Paths that survive the app's container moving.
///
/// iOS gives an app a new container (`.../Data/Application/<UUID>/`) on
/// every reinstall and some updates, and Android names one app directory
/// both `/data/user/0/<pkg>` and `/data/data/<pkg>`. A stored absolute path
/// into the app's own folders — a guest's cache, a host's kept imports —
/// then points at nothing although the file is still there.
///
/// So a stored path is kept twice: absolute (what older app versions read)
/// and, when it sits under one of the app's own folders, as a [JamPathRef]
/// relative to that folder. Reading tries the reference against the
/// *current* folders first, then the absolute path, then re-bases an
/// absolute path from an older container onto the current one
/// ([JamAppRoots.locate]). A path outside the app's folders — a desktop
/// user's own music, an Android library path — stays absolute.
library;

import 'dart:io';

import 'package:flutter/foundation.dart' show immutable;
import 'package:path_provider/path_provider.dart';

/// The app-owned folders a stored path can be relative to.
enum JamAppRoot {
  /// `getApplicationSupportDirectory()` (kept imports, the history store).
  support('support'),

  /// `getApplicationCacheDirectory()` (a guest's media cache).
  cache('cache'),

  /// `getApplicationDocumentsDirectory()`.
  documents('documents'),

  /// `getTemporaryDirectory()`.
  temp('temp');

  const JamAppRoot(this.wire);

  /// The name a [JamPathRef] is stored under.
  final String wire;

  static JamAppRoot? fromWire(Object? wire) {
    for (final root in values) {
      if (root.wire == wire) return root;
    }
    return null;
  }
}

/// A path relative to one of the app's folders: `{root: support, path:
/// imports/Night Drive.mp3}`. The relative part is `/`-separated on every
/// platform and never climbs out of its root.
@immutable
class JamPathRef {
  const JamPathRef(this.root, this.path);

  final JamAppRoot root;

  /// The part under [root], `/`-separated.
  final String path;

  Map<String, Object?> toJson() => {'root': root.wire, 'path': path};

  /// The reference in [json], or null when it is missing, names an unknown
  /// root, or is not a plain path under it (absolute, empty, or with `..`).
  static JamPathRef? fromJson(Object? json) {
    if (json is! Map) return null;
    final root = JamAppRoot.fromWire(json['root']);
    final path = json['path'];
    if (root == null || path is! String) return null;
    final segments = _segments(path);
    if (segments.isEmpty ||
        path.startsWith('/') ||
        path.startsWith(r'\') ||
        segments.first.endsWith(':') ||
        segments.any(_climbs)) {
      return null;
    }
    return JamPathRef(root, segments.join('/'));
  }

  @override
  bool operator ==(Object other) =>
      other is JamPathRef && other.root == root && other.path == path;

  @override
  int get hashCode => Object.hash(root, path);

  @override
  String toString() => 'JamPathRef(${root.wire}: $path)';
}

/// The app's folders as they are in this run, and what a stored path means
/// against them. Injectable: tests and headless embeddings (no
/// path_provider) hand in their own, or use [JamAppRoots.none].
class JamAppRoots {
  JamAppRoots(Map<JamAppRoot, String> roots, {String? separator})
    : _roots = {
        for (final MapEntry(:key, :value) in roots.entries)
          if (_segments(value).isNotEmpty) key: _trimTrailing(value),
      },
      _separator = separator ?? Platform.pathSeparator;

  /// No known folders: every path stays absolute.
  static final JamAppRoots none = JamAppRoots(const {});

  final Map<JamAppRoot, String> _roots;
  final String _separator;

  static Future<JamAppRoots>? _current;

  /// This run's folders, from path_provider. Each is optional: one the
  /// platform does not provide is simply not a root. Cached for the process
  /// (the folders do not move while the app runs).
  static Future<JamAppRoots> current() => _current ??= _load();

  static Future<JamAppRoots> _load() async {
    Future<String?> tryPath(Future<Directory> Function() get) async {
      try {
        return (await get()).path;
      } catch (_) {
        return null; // Unsupported here, or no platform (tests).
      }
    }

    final roots = {
      JamAppRoot.support: await tryPath(getApplicationSupportDirectory),
      JamAppRoot.cache: await tryPath(getApplicationCacheDirectory),
      JamAppRoot.documents: await tryPath(getApplicationDocumentsDirectory),
      JamAppRoot.temp: await tryPath(getTemporaryDirectory),
    };
    return JamAppRoots({
      for (final MapEntry(:key, :value) in roots.entries) key: ?value,
    });
  }

  /// [root]'s current path, if this run has one.
  String? pathOf(JamAppRoot root) => _roots[root];

  /// The segments the distinct roots share — the app's container (iOS's
  /// `.../Application/<UUID>`, Android's `/data/user/0/<pkg>`) — or empty
  /// when there are fewer than two distinct roots or they share nothing.
  late final List<String> _container = () {
    final distinct = <String, List<String>>{
      for (final path in _roots.values)
        _segments(path).join('/'): _segments(path),
    }.values.toList();
    if (distinct.length < 2) return const <String>[];
    var prefix = distinct.first;
    for (final path in distinct.skip(1)) {
      var n = 0;
      while (n < prefix.length && n < path.length && prefix[n] == path[n]) {
        n++;
      }
      prefix = prefix.sublist(0, n);
    }
    return prefix;
  }();

  /// [absolutePath] as a reference to the innermost app folder holding it,
  /// or null when it is under none of them (it then stays absolute). Where
  /// two roots are the same folder (iOS's cache and temp), the one listed
  /// first in [JamAppRoot] names it.
  JamPathRef? refFor(String absolutePath) {
    final segments = _segments(absolutePath);
    JamAppRoot? best;
    var bestLength = -1;
    for (final root in JamAppRoot.values) {
      final rootPath = _roots[root];
      if (rootPath == null) continue;
      final prefix = _segments(rootPath);
      if (prefix.length >= segments.length) continue;
      if (!_startsWith(segments, prefix, 0)) continue;
      if (prefix.length > bestLength) {
        best = root;
        bestLength = prefix.length;
      }
    }
    if (best == null) return null;
    final rest = segments.sublist(bestLength);
    if (rest.any(_climbs)) return null;
    return JamPathRef(best, rest.join('/'));
  }

  /// Where [ref] is in this run, or null when its root is unknown here.
  /// Does not check that anything is there.
  String? resolve(JamPathRef ref) {
    final root = _roots[ref.root];
    if (root == null) return null;
    return '$root$_separator${ref.path.split('/').join(_separator)}';
  }

  /// The readable file a stored track's bytes are at now, or null:
  ///
  /// 1. [ref] against this run's folders;
  /// 2. [absolutePath] as stored;
  /// 3. [absolutePath] re-based from an older container ([rebase]).
  String? locate({
    JamPathRef? ref,
    String? absolutePath,
    bool Function(String path) exists = _fileExists,
  }) {
    if (ref != null) {
      final current = resolve(ref);
      if (current != null && exists(current)) return current;
    }
    if (absolutePath == null || absolutePath.isEmpty) return null;
    if (exists(absolutePath)) return absolutePath;
    return rebase(absolutePath, exists: exists);
  }

  /// [absolutePath] from an older container, moved onto this run's — when
  /// the moved path [exists]. Two ways to recognise one, both derived from
  /// this run's folders rather than from a list of platform paths:
  ///
  /// * **A root's place in the container.** Each root's segments past the
  ///   container (`Library/Application Support`, `Library/Caches`,
  ///   `Documents`; Android's `files`, `cache`) are looked for in the old
  ///   path, and what follows is placed under that root now — so
  ///   `/data/data/<pkg>/files/x` finds `/data/user/0/<pkg>/files/x`, and
  ///   an iOS path from another simulator device finds this one's.
  /// * **The same container, renamed.** An old path that runs through a
  ///   folder exactly like the container but for one segment (iOS's
  ///   `Application/<UUID>`, Android's user number) is placed under the
  ///   container now — which also covers folders that are no root, such
  ///   as iOS's `tmp`.
  String? rebase(
    String absolutePath, {
    bool Function(String path) exists = _fileExists,
  }) {
    final container = _container;
    final segments = _segments(absolutePath);
    if (container.isEmpty || segments.isEmpty) return null;
    final stored = _fromSegments(_rootPrefix(absolutePath), segments);

    String? accept(String candidate) =>
        candidate != absolutePath && candidate != stored && exists(candidate)
        ? candidate
        : null;

    // The longest suffixes first: `Library/Caches/<bundle>` before
    // `Library/Caches`.
    final byRoot = [
      for (final path in _roots.values)
        (path: path, suffix: _segments(path).sublist(container.length)),
    ]..sort((a, b) => b.suffix.length.compareTo(a.suffix.length));
    for (final (:path, :suffix) in byRoot) {
      if (suffix.isEmpty) continue;
      for (var i = 0; i + suffix.length < segments.length; i++) {
        if (!_startsWith(segments, suffix, i)) continue;
        final found = accept(
          _fromSegments(_rootPrefix(path), [
            ..._segments(path),
            ...segments.sublist(i + suffix.length),
          ]),
        );
        if (found != null) return found;
      }
    }

    // Renamed: a container of at least two segments, so a shallow one is
    // never guessed at.
    if (container.length >= 2 && segments.length > container.length) {
      var differing = 0;
      for (var i = 0; i < container.length; i++) {
        if (segments[i] != container[i]) differing++;
      }
      if (differing == 1) {
        return accept(
          _fromSegments(_rootPrefix(_roots.values.first), [
            ...container,
            ...segments.sublist(container.length),
          ]),
        );
      }
    }
    return null;
  }

  String _fromSegments(String prefix, List<String> segments) =>
      '$prefix${segments.join(_separator)}';

  /// What precedes the first segment: the separator for a POSIX path,
  /// nothing for a Windows drive path (whose first segment is `C:`).
  String _rootPrefix(String path) =>
      path.startsWith('/') || path.startsWith(r'\') ? _separator : '';

  @override
  String toString() =>
      'JamAppRoots(${{for (final MapEntry(:key, :value) in _roots.entries) key.wire: value}})';
}

bool _fileExists(String path) {
  try {
    return File(path).existsSync();
  } catch (_) {
    return false;
  }
}

bool _climbs(String segment) => segment == '..' || segment == '.';

List<String> _segments(String path) => [
  for (final s in path.split(RegExp(r'[/\\]')))
    if (s.isNotEmpty) s,
];

String _trimTrailing(String path) {
  var end = path.length;
  while (end > 1 && (path[end - 1] == '/' || path[end - 1] == r'\')) {
    end--;
  }
  return path.substring(0, end);
}

bool _startsWith(List<String> segments, List<String> prefix, int at) {
  if (at + prefix.length > segments.length) return false;
  for (var i = 0; i < prefix.length; i++) {
    if (segments[at + i] != prefix[i]) return false;
  }
  return true;
}
