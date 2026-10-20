/// Keeping picked songs alive after the picker has closed.
///
/// A picker often hands back a copy, not the song: iOS's Files picker (import
/// mode) copies into `tmp/<bundle>-Inbox/`, Android's DocumentsUI path copies
/// into the cache, and the library's content-URI fallback caches there too.
/// The OS empties those folders whenever it likes — on an iOS simulator about
/// a minute after the pick — and a jam that stored such a path played its
/// first song and then failed on the next, served a 500 to guests, and left a
/// history that could not play again.
///
/// So a song whose path is temporary is copied into the app's own container
/// (`<application support>/imports/`) the moment it is picked, and that copy
/// is what the queue and the history keep. A path that is already the
/// person's own file (Documents, a desktop folder, a MediaStore path) is left
/// where it is.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Copies picked files out of temporary folders into [importsDir].
///
/// The filesystem is real; what makes it testable is that both ends are
/// handed in: the folder copies go to, and the folders that count as
/// temporary.
class JamPickedFileKeeper {
  JamPickedFileKeeper({required this.importsDir, required this.temporaryRoots});

  /// Where kept copies live. Created on the first copy.
  final Directory importsDir;

  /// Folders the OS may empty behind the app's back. A path inside any of
  /// them is copied.
  final List<String> temporaryRoots;

  /// Whether [path] lives somewhere the OS may purge: under one of
  /// [temporaryRoots], or in an "Inbox" — iOS's `tmp/<bundle>-Inbox/` and the
  /// older `Documents/Inbox/` both hold copies the system hands over and
  /// later deletes.
  bool isTemporary(String path) {
    final normal = _normalise(path);
    if (_within(normal, _normalise(importsDir.path))) return false;
    for (final root in temporaryRoots) {
      if (_within(normal, _normalise(root))) return true;
    }
    final segments = normal.split('/');
    // The last segment is the file itself; only its folders count.
    for (final folder in segments.take(segments.length - 1)) {
      if (folder == 'Inbox' || folder.endsWith('-Inbox')) return true;
    }
    return false;
  }

  /// The path the jam should keep for [path]: a copy in [importsDir] when
  /// [path] is temporary, else [path] itself.
  ///
  /// The same song picked twice — same name, same size — is kept once:
  /// the existing copy is reused. A different song with the same name gets
  /// "Name 2.mp3". If the copy fails (no space, the file already gone) the
  /// original path comes back, so the pick still works for as long as the
  /// OS leaves it there.
  Future<String> keep(String path) async {
    if (!isTemporary(path)) return path;
    try {
      final source = File(path);
      final size = await source.length();
      await importsDir.create(recursive: true);
      final name = path.split(RegExp(r'[/\\]')).last;
      final dot = name.lastIndexOf('.');
      final stem = dot > 0 ? name.substring(0, dot) : name;
      final extension = dot > 0 ? name.substring(dot) : '';
      for (var n = 1; ; n++) {
        final candidate = File(
          '${importsDir.path}${Platform.pathSeparator}'
          '${n == 1 ? stem : '$stem $n'}$extension',
        );
        if (await candidate.exists()) {
          if (await candidate.length() == size) return candidate.path;
          continue;
        }
        // Copy beside the target and rename, so a copy cut short (the app
        // killed mid-write) never passes for the song next time.
        final part = File('${candidate.path}.part');
        await source.copy(part.path);
        await part.rename(candidate.path);
        return candidate.path;
      }
    } catch (e) {
      debugPrint('localjam: could not keep $path: $e');
      return path;
    }
  }

  /// [keep] for each of [paths], in order.
  Future<List<String>> keepAll(Iterable<String> paths) async => [
    for (final path in paths) await keep(path),
  ];

  static String _normalise(String path) {
    var out = path.replaceAll('\\', '/');
    // iOS reports the same container through /private/var and /var.
    if (out.startsWith('/private/')) out = out.substring('/private'.length);
    while (out.length > 1 && out.endsWith('/')) {
      out = out.substring(0, out.length - 1);
    }
    return out;
  }

  static bool _within(String path, String root) =>
      root.isNotEmpty && path.startsWith('$root/');
}

JamPickedFileKeeper? _keeper;

/// The app's keeper: copies go to `<application support>/imports/`, and the
/// platform's temporary and cache folders count as temporary. Null where the
/// platform has no such folders (tests, headless runs).
Future<JamPickedFileKeeper?> _defaultKeeper() async {
  final cached = _keeper;
  if (cached != null) return cached;
  try {
    final support = await getApplicationSupportDirectory();
    final roots = <String>[Directory.systemTemp.path];
    try {
      roots.add((await getTemporaryDirectory()).path);
    } catch (_) {
      // The system temp folder and the Inbox rule still cover iOS's picks.
    }
    return _keeper = JamPickedFileKeeper(
      importsDir: Directory('${support.path}${Platform.pathSeparator}imports'),
      temporaryRoots: roots,
    );
  } catch (e) {
    debugPrint('localjam: no folder to keep picked songs in: $e');
    return null;
  }
}

/// [paths] as the jam should keep them: every temporary pick copied into the
/// app's container, everything else unchanged. Never throws.
Future<List<String>> keepPickedFiles(List<String> paths) async {
  if (paths.isEmpty) return paths;
  final keeper = await _defaultKeeper();
  if (keeper == null) return paths;
  return keeper.keepAll(paths);
}
