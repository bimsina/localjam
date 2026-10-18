/// The device music library, as a picker sheet.
///
/// Lifted out of the host-setup screen so the in-room "Add" button can offer
/// the same thing: on Android most music is in MediaStore, not in a folder
/// DocumentsUI will show you.
///
/// Restyled to §4: the same [JamTrackRow] the queue uses, so picking a track
/// and seeing it in the room look like one continuous thing rather than a
/// system list handing off to an app.
library;

import 'package:flutter/material.dart';
import 'package:localjam_client/localjam_client.dart';

import '../design/tokens.dart';
import '../design/typography.dart';
import '../util/format.dart';
import 'buttons.dart';
import 'sheet.dart';
import 'track_row.dart';

/// Everything this sheet says out loud.
abstract final class LibrarySheetStrings {
  static const String title = 'Your music';
  static const String selectAll = 'Select all';
  static const String clear = 'Clear';
  static const String unknownArtist = 'Unknown artist';
  static const String select = 'Select';

  /// "Add 3".
  static String addCount(int n) => n == 0 ? 'Add' : 'Add $n';

  /// "12 tracks on this device".
  static String available(int n) =>
      '$n ${n == 1 ? 'track' : 'tracks'} on this device';
}

/// Opens the library picker. Pops the chosen tracks, or null when cancelled.
Future<List<JamLibraryTrack>?> showJamLibrarySheet(
  BuildContext context,
  List<JamLibraryTrack> tracks,
) {
  return showJamSheet<List<JamLibraryTrack>>(
    context,
    title: LibrarySheetStrings.title,
    builder: (context) => JamLibraryPicker(tracks: tracks),
  );
}

/// The picker's body: the list, the selection, and the one primary action.
class JamLibraryPicker extends StatefulWidget {
  const JamLibraryPicker({super.key, required this.tracks});

  final List<JamLibraryTrack> tracks;

  @override
  State<JamLibraryPicker> createState() => _JamLibraryPickerState();
}

class _JamLibraryPickerState extends State<JamLibraryPicker> {
  final Set<int> _selected = {};

  bool get _allSelected =>
      widget.tracks.isNotEmpty && _selected.length == widget.tracks.length;

  void _toggleAll() => setState(() {
    if (_allSelected) {
      _selected.clear();
    } else {
      _selected.addAll(widget.tracks.map((t) => t.id));
    }
  });

  void _toggle(int id) => setState(() {
    if (!_selected.remove(id)) _selected.add(id);
  });

  void _submit() => Navigator.of(context).pop([
    for (final track in widget.tracks)
      if (_selected.contains(track.id)) track,
  ]);

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            JamSpace.page,
            JamSpace.sm,
            JamSpace.md,
            0,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  LibrarySheetStrings.available(widget.tracks.length),
                  style: context.jamFootnote.copyWith(
                    color: context.jamColors.secondaryLabel,
                  ),
                ),
              ),
              JamButton.plain(
                label: _allSelected
                    ? LibrarySheetStrings.clear
                    : LibrarySheetStrings.selectAll,
                onPressed: widget.tracks.isEmpty ? null : _toggleAll,
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            controller: JamSheetScrollController.maybeOf(context),
            padding: const EdgeInsets.only(bottom: JamSpace.md),
            itemCount: widget.tracks.length,
            itemBuilder: (context, index) {
              final track = widget.tracks[index];
              final selected = _selected.contains(track.id);
              return JamTrackRow(
                key: ValueKey(track.id),
                title: stripAudioExtension(track.title),
                byline: track.artist ?? LibrarySheetStrings.unknownArtist,
                addedByYou: true,
                onTap: () => _toggle(track.id),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // MediaStore hands us a duration; the queue shows one, so
                    // a list without them reads as a different kind of row.
                    if (track.durationMs case final ms?)
                      Text(
                        formatPositionUs(ms * 1000),
                        style: jamNumericStyle(colors.tertiaryLabel),
                      ),
                    const SizedBox(width: JamSpace.md),
                    Semantics(
                      checked: selected,
                      label: LibrarySheetStrings.select,
                      child: Icon(
                        selected
                            ? Icons.check_circle_rounded
                            : Icons.circle_outlined,
                        size: 22,
                        color: selected ? colors.tint : colors.tertiaryLabel,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
        Container(
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(color: colors.separator, width: 0.5),
            ),
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(JamSpace.md),
              child: JamButton.filled(
                label: LibrarySheetStrings.addCount(_selected.length),
                expand: true,
                onPressed: _selected.isEmpty ? null : _submit,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
