/// Getting audio into a jam: the file picker, the device library, and the
/// choice between them.
///
/// Both call sites — host setup and the in-room queue — used to own a private
/// copy of this, which is how the queue sheet ended up with no Library button
/// at all and how the picker's type group drifted out of sync.
library;

import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/cupertino.dart';
import 'package:localjam_client/localjam_client.dart';

import '../design/tokens.dart';
import '../state/session_controller.dart';
import '../widgets/library_sheet.dart';
import 'permissions.dart';

/// Everything these flows say out loud.
abstract final class JamPickerStrings {
  static const String audioTypeLabel = 'Audio';

  static const String addFrom = 'Add Songs From';
  static const String library = 'Music Library';
  static const String files = 'Files';
  static const String cancel = 'Cancel';

  static const String pickerFailed = 'Could not open the file picker.';
  static const String libraryReadFailed = 'Could not read your music library.';
  static const String libraryEmpty =
      'No audio files on this device yet. Add music to the phone, or use '
      'Files to pick from Downloads or cloud storage.';
  static const String openFailedOne = 'Could not open that track.';
  static const String openFailedMany = 'Could not open those tracks.';
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
  // An iOS action sheet on every platform (D2): the choice between two
  // sources is exactly what one is for.
  return showCupertinoModalPopup<JamAddSource>(
    context: context,
    builder: (context) {
      final colors = context.jamColors;
      Widget action(String label, JamAddSource source) =>
          CupertinoActionSheetAction(
            onPressed: () => Navigator.of(context).pop(source),
            child: Text(label, style: TextStyle(color: colors.tint)),
          );
      return CupertinoActionSheet(
        title: const Text(JamPickerStrings.addFrom),
        actions: [
          action(JamPickerStrings.library, JamAddSource.library),
          action(JamPickerStrings.files, JamAddSource.files),
        ],
        cancelButton: CupertinoActionSheetAction(
          isDefaultAction: true,
          onPressed: () => Navigator.of(context).pop(),
          child: Text(
            JamPickerStrings.cancel,
            style: TextStyle(color: colors.tint),
          ),
        ),
      );
    },
  );
}

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
    session.notify(JamPickerStrings.pickerFailed);
    return const [];
  }
}

/// Runs the device-library flow: permission, query, the picker sheet, and
/// resolving each chosen track to a readable path.
///
/// Every dead end reports itself through the controller's notice channel —
/// a silent return here is a button that does nothing.
Future<List<String>> pickLibraryTracks(BuildContext context) async {
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
    );
    return const [];
  }

  final List<JamLibraryTrack> tracks;
  try {
    tracks = await JamMediaLibrary.queryAudio();
  } catch (e) {
    debugPrint('localjam: media library query failed: $e');
    session.notify(JamPickerStrings.libraryReadFailed);
    return const [];
  }
  if (tracks.isEmpty) {
    // An empty library used to bail without a word, which on a fresh phone
    // (or an emulator) is every single tap of the Library button.
    session.notify(JamPickerStrings.libraryEmpty);
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

  final paths = <String>[];
  for (final track in chosen) {
    try {
      final path = await JamMediaLibrary.resolve(track);
      if (path != null) paths.add(path);
    } catch (e) {
      debugPrint('localjam: could not resolve ${track.title}: $e');
    }
  }
  if (paths.isEmpty) {
    session.notify(
      chosen.length == 1
          ? JamPickerStrings.openFailedOne
          : JamPickerStrings.openFailedMany,
    );
  }
  return paths;
}

/// Drops focus so a picker or sheet does not open over a live keyboard — and,
/// on the way back, does not restore one.
void _dismissKeyboard() => FocusManager.instance.primaryFocus?.unfocus();
