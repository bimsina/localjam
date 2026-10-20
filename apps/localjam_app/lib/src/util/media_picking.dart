/// Getting audio into a jam: the file picker, the device library, and the
/// choice between them.
///
/// Both call sites — host setup and the in-room queue — used to own a private
/// copy of this, which is how the queue sheet ended up with no Library button
/// at all and how the picker's type group drifted out of sync.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/cupertino.dart';
import 'package:localjam_client/localjam_client.dart';

import '../state/session_controller.dart';
import '../widgets/library_sheet.dart';
import '../widgets/list.dart';
import '../widgets/section.dart';
import '../widgets/sheet.dart';
import 'format.dart';
import 'permissions.dart';

/// Everything these flows say out loud.
abstract final class JamPickerStrings {
  static const String audioTypeLabel = 'Audio';

  static const String addFrom = 'Add songs from';
  static const String library = 'Music library';
  static const String libraryDetail = 'Songs saved on this phone';
  static const String files = 'Files';
  static const String filesDetail = 'Downloads and cloud storage';

  static const String pickerFailed = 'Couldn’t open the file picker.';
  static const String libraryReadFailed = 'Couldn’t read your music library.';
  static const String libraryEmpty =
      'No songs on this device yet. Add music to the phone, or use Files to '
      'pick from Downloads or cloud storage.';
  static const String openFailedOne = 'Couldn’t open that song.';
  static const String openFailedMany = 'Couldn’t open those songs.';
}

/// A song picked for a jam that has not started yet: its file, and what to
/// call it on screen.
///
/// Start a Jam lists songs before any engine has read them, and a path alone
/// put "neon" and "tide" — file names — where Apple Music shows the title,
/// the artist, the length and the cover. The library already knows the
/// first three; tags read off the file ([readPickedTrack]) fill in the rest.
@immutable
class JamPickedTrack {
  const JamPickedTrack({
    required this.path,
    this.title,
    this.artist,
    this.duration,
    this.artworkBytes,
    this.tagsRead = false,
  });

  /// From the device library, which knows title, artist and length.
  factory JamPickedTrack.fromLibrary(JamLibraryTrack track, String path) {
    final ms = track.durationMs;
    final title = track.title.trim();
    return JamPickedTrack(
      path: path,
      title: title.isEmpty ? null : stripAudioExtension(title),
      artist: track.artist,
      duration: ms == null || ms <= 0 ? null : Duration(milliseconds: ms),
    );
  }

  /// The file the jam will be started with.
  final String path;

  /// Tag (or library) title; null when the file has none.
  final String? title;
  final String? artist;
  final Duration? duration;

  /// The embedded cover, once the tags have been read.
  final Uint8List? artworkBytes;

  /// Whether [readPickedTrack] has been over this file — a song with no
  /// cover is then known to have none, rather than still loading.
  final bool tagsRead;

  /// The title on screen: the tag title, else the file name without its
  /// extension.
  String get displayTitle =>
      title ?? stripAudioExtension(path.split(Platform.pathSeparator).last);

  /// This song with [tags] filling in whatever it did not know yet. The
  /// library's own title, artist and length win: MediaStore has usually
  /// cleaned them up already.
  JamPickedTrack withTags(JamAudioTags tags) {
    final us = tags.durationUs;
    return JamPickedTrack(
      path: path,
      title: title ?? tags.title,
      artist: artist ?? tags.artist,
      duration: duration ?? (us == null ? null : Duration(microseconds: us)),
      artworkBytes:
          artworkBytes ?? (tags.hasArtwork ? tags.artworkBytes : null),
      tagsRead: true,
    );
  }
}

/// A cover is a picture, not a payload: a tag frame bigger than this is not
/// read (see [readAudioTags]).
const int _maxPickedTagBytes = 8 * 1024 * 1024;

/// Tag reads run two at a time, so picking 200 songs does not spawn 200
/// isolates at once.
const int _parallelTagReads = 2;
int _tagReadsRunning = 0;
final Queue<Completer<void>> _tagReadsWaiting = Queue<Completer<void>>();

/// Reads [track]'s tags and cover, off the UI isolate, and returns it with
/// them filled in. Never throws; a file with no tags comes back as it went
/// in, marked read.
Future<JamPickedTrack> readPickedTrack(JamPickedTrack track) async {
  while (_tagReadsRunning >= _parallelTagReads) {
    final turn = Completer<void>();
    _tagReadsWaiting.add(turn);
    await turn.future;
  }
  _tagReadsRunning++;
  try {
    final file = File(track.path);
    // `readAudioTags` parses in a short-lived isolate and never throws.
    final tags = await readAudioTags(
      file,
      maxMetadataBytes: _maxPickedTagBytes,
    );
    return track.withTags(tags);
  } catch (e) {
    debugPrint('localjam: could not read tags of ${track.path}: $e');
    return track.withTags(const JamAudioTags());
  } finally {
    _tagReadsRunning--;
    if (_tagReadsWaiting.isNotEmpty) _tagReadsWaiting.removeFirst().complete();
  }
}

/// MIME types for the audio formats [supportedAudioExtensions] covers, plus
/// the `audio/*` catch-all.
///
/// Android's DocumentsUI filters on MIME type alone: a group carrying only
/// extensions and UTIs greys out every audio file on the device, `.m4a`
/// included, which looked exactly like "this app cannot read my music".
const List<String> jamAudioMimeTypes = [
  'audio/mpeg',
  'audio/mp4',
  'audio/x-m4a',
  'audio/aac',
  'audio/flac',
  'audio/x-flac',
  'audio/wav',
  'audio/x-wav',
  'audio/ogg',
  'audio/opus',
  // Providers that report an unusual subtype still have to come through.
  'audio/*',
];

/// The one audio type group every picker in the app opens with.
///
/// [supportedAudioExtensions] (in `localjam_client`) stays the source of truth
/// for what this build can actually play; the UTIs cover Apple platforms and
/// the MIME types cover Android.
XTypeGroup jamAudioTypeGroup() => XTypeGroup(
  label: JamPickerStrings.audioTypeLabel,
  extensions: supportedAudioExtensions,
  uniformTypeIdentifiers: const ['public.audio'],
  mimeTypes: jamAudioMimeTypes,
);

/// Whether this platform can list the device's music library.
bool get jamLibraryAvailable => JamMediaLibrary.isSupported;

/// Where a track is coming from.
enum JamAddSource { library, files }

/// Asks which source to add from, or answers [JamAddSource.files] outright on
/// platforms with no library to offer. Null means the user backed out.
Future<JamAddSource?> chooseAddSource(BuildContext context) async {
  if (!jamLibraryAvailable) return JamAddSource.files;
  _dismissKeyboard();
  return showJamAddSourceSheet(context);
}

/// The choice itself, on the app's own sheet rather than the system's grey
/// action sheet: sized to its two rows, floating like every other short
/// sheet, the xmark to back out. Each row says where its songs come from.
/// Resolves to the source picked, or null when dismissed.
Future<JamAddSource?> showJamAddSourceSheet(BuildContext context) =>
    showJamSheet<JamAddSource>(
      context,
      title: JamPickerStrings.addFrom,
      actions: const JamSheetActions.done(),
      grouped: true,
      scrollable: false,
      builder: (context) {
        void pick(JamAddSource source) => Navigator.of(context).pop(source);
        // Scrolls rather than clips at the largest text sizes.
        return SingleChildScrollView(
          child: JamSection(
            children: [
              JamRow(
                icon: CupertinoIcons.music_albums,
                title: JamPickerStrings.library,
                subtitle: JamPickerStrings.libraryDetail,
                onTap: () => pick(JamAddSource.library),
              ),
              JamRow(
                icon: CupertinoIcons.folder,
                title: JamPickerStrings.files,
                subtitle: JamPickerStrings.filesDetail,
                onTap: () => pick(JamAddSource.files),
              ),
            ],
          ),
        );
      },
    );

/// Opens the system file picker. Returns the chosen paths, empty when the
/// user cancelled or the picker could not open (which is reported as a
/// notice, not swallowed).
Future<List<String>> pickAudioFiles(BuildContext context) async {
  final session = JamSession.read(context);
  _dismissKeyboard();
  try {
    final files = await openFiles(acceptedTypeGroups: [jamAudioTypeGroup()]);
    return [for (final file in files) file.path];
  } catch (e) {
    debugPrint('localjam: file picker failed: $e');
    session.notify(JamPickerStrings.pickerFailed, tone: JamNoticeTone.error);
    return const [];
  }
}

/// Runs the device-library flow: permission, query, the picker sheet, and
/// resolving each chosen track to a readable path.
///
/// Every dead end reports itself through the controller's notice channel —
/// a silent return here is a button that does nothing.
Future<List<String>> pickLibraryTracks(BuildContext context) async => [
  for (final track in await pickLibraryTrackDetails(context)) track.path,
];

/// [pickLibraryTracks], keeping what the library already knows about each
/// song — title, artist, length — instead of throwing it away for a path.
Future<List<JamPickedTrack>> pickLibraryTrackDetails(
  BuildContext context,
) async {
  final session = JamSession.read(context);
  _dismissKeyboard();

  final outcome = await requestAudioLibraryPermission();
  // "Not now" on the rationale sheet is the user answering us, not the OS
  // refusing them: nothing to report, and nothing Settings could fix.
  if (outcome == JamPermissionOutcome.dismissed) return const [];
  if (outcome != JamPermissionOutcome.granted) {
    final permanent = outcome == JamPermissionOutcome.permanentlyDenied;
    session.notify(
      JamPermissionCopy.audioLibraryDenied,
      actionLabel: permanent ? JamPermissionCopy.openSettings : null,
      onAction: permanent ? () => unawaited(openAppSettings()) : null,
      tone: JamNoticeTone.warning,
    );
    return const [];
  }

  final List<JamLibraryTrack> tracks;
  try {
    tracks = await JamMediaLibrary.queryAudio();
  } catch (e) {
    debugPrint('localjam: media library query failed: $e');
    session.notify(
      JamPickerStrings.libraryReadFailed,
      tone: JamNoticeTone.error,
    );
    return const [];
  }
  if (tracks.isEmpty) {
    // An empty library used to bail without a word, which on a fresh phone
    // (or an emulator) is every single tap of the Library button.
    session.notify(JamPickerStrings.libraryEmpty, tone: JamNoticeTone.neutral);
    return const [];
  }

  if (!context.mounted) return const [];
  // The shared sheet chrome, not a bare `showModalBottomSheet`: the picker
  // is the same kind of surface as Queue and People and should not arrive
  // with a different header, radius and handle.
  final chosen = await showJamLibrarySheet(context, tracks);
  // Closing the sheet hands focus back to whatever had it — on host setup
  // that is the room-name field, and the keyboard shoots up over the result.
  _dismissKeyboard();
  if (chosen == null || chosen.isEmpty) return const [];

  final picked = <JamPickedTrack>[];
  for (final track in chosen) {
    try {
      final path = await JamMediaLibrary.resolve(track);
      if (path != null) picked.add(JamPickedTrack.fromLibrary(track, path));
    } catch (e) {
      debugPrint('localjam: could not resolve ${track.title}: $e');
    }
  }
  if (picked.isEmpty) {
    session.notify(
      chosen.length == 1
          ? JamPickerStrings.openFailedOne
          : JamPickerStrings.openFailedMany,
      tone: JamNoticeTone.error,
    );
  }
  return picked;
}

/// Drops focus so a picker or sheet does not open over a live keyboard — and,
/// on the way back, does not restore one.
void _dismissKeyboard() => FocusManager.instance.primaryFocus?.unfocus();
