/// The device music library, as a picker sheet (DESIGN_SPEC v3 §6.2).
///
/// Used by Start a Jam and by the in-room Add Songs: on Android most music is
/// in MediaStore, not in a folder DocumentsUI will show you.
///
/// Apple Music's "Add Songs" picker: a large sheet with Cancel and Done, a
/// search field, plain song rows (cover, title, "Artist · 3:42") and a
/// checkmark circle on each chosen one. The title counts the selection.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:localjam_client/localjam_client.dart';

import '../design/tokens.dart';
import '../design/typography.dart';
import '../util/format.dart';
import '../util/media_picking.dart';
import 'buttons.dart';
import 'sheet.dart';
import 'track_row.dart';

/// Everything this sheet says out loud.
abstract final class LibrarySheetStrings {
  static const String title = 'Music Library';
  static const String cancel = 'Cancel';
  static const String done = 'Done';
  static const String search = 'Search';
  static const String selectAll = 'Select All';
  static const String deselectAll = 'Deselect All';
  static const String unknownArtist = 'Unknown Artist';
  static const String selected = 'Selected';
  static const String noResults = 'No Results';

  /// "3 Songs Selected" — the title once something is chosen.
  static String selectedCount(int n) =>
      n == 1 ? '1 Song Selected' : '$n Songs Selected';

  /// "214 songs" — a count line, so sentence case (§10.9).
  static String available(int n) => n == 1 ? '1 song' : '$n songs';
}

/// Library covers, read out of each song's file the first time its row is
/// built and kept by MediaStore id, so scrolling back never reads a file
/// twice. MediaStore has no art column; the cover is in the file.
abstract final class _LibraryCovers {
  static final LinkedHashMap<int, Future<Uint8List?>> _cache =
      LinkedHashMap<int, Future<Uint8List?>>();
  static const int _capacity = 160;

  static Future<Uint8List?>? peek(JamLibraryTrack track) => _cache[track.id];

  static Future<Uint8List?> load(JamLibraryTrack track) {
    final hit = _cache.remove(track.id);
    if (hit != null) return _cache[track.id] = hit;
    final path = track.path;
    final Future<Uint8List?> read = path == null
        ? Future<Uint8List?>.value()
        // Off the UI isolate, and two at a time (see [readPickedTrack]).
        : readPickedTrack(
            JamPickedTrack(path: path),
          ).then((t) => t.artworkBytes);
    _cache[track.id] = read;
    while (_cache.length > _capacity) {
      _cache.remove(_cache.keys.first);
    }
    return read;
  }
}

/// Opens the library picker. Pops the chosen tracks, or null when cancelled.
Future<List<JamLibraryTrack>?> showJamLibrarySheet(
  BuildContext context,
  List<JamLibraryTrack> tracks,
) {
  // The shared sheet pieces, assembled here rather than through
  // `showJamSheet`: the header's title and Done follow the selection, so the
  // picker owns its own header.
  return showJamModalSheet<List<JamLibraryTrack>>(
    context,
    builder: (context) => buildJamDraggableSheet(
      initialChildSize: kJamSheetLargeSize,
      maxChildSize: kJamSheetLargeSize,
      minChildSize: kJamSheetMinSize,
      builder: (context, controller) => JamSheetSurface(
        child: JamLibraryPicker(tracks: tracks, scrollController: controller),
      ),
    ),
  );
}

/// The picker's body: the header, the search, the list and the selection.
class JamLibraryPicker extends StatefulWidget {
  const JamLibraryPicker({
    super.key,
    required this.tracks,
    this.scrollController,
  });

  final List<JamLibraryTrack> tracks;

  /// The sheet's scroll controller, so a drag at the top of the list moves
  /// the sheet.
  final ScrollController? scrollController;

  @override
  State<JamLibraryPicker> createState() => _JamLibraryPickerState();
}

class _JamLibraryPickerState extends State<JamLibraryPicker> {
  final Set<int> _selected = {};
  final TextEditingController _query = TextEditingController();

  @override
  void initState() {
    super.initState();
    _query.addListener(_onQuery);
  }

  @override
  void dispose() {
    _query
      ..removeListener(_onQuery)
      ..dispose();
    super.dispose();
  }

  void _onQuery() => setState(() {});

  List<JamLibraryTrack> get _visible {
    final q = _query.text.trim().toLowerCase();
    if (q.isEmpty) return widget.tracks;
    bool has(String? s) => s != null && s.toLowerCase().contains(q);
    return [
      for (final t in widget.tracks)
        if (has(t.title) || has(t.artist) || has(t.album)) t,
    ];
  }

  void _toggleAll(List<JamLibraryTrack> visible) => setState(() {
    final all = visible.every((t) => _selected.contains(t.id));
    if (all) {
      _selected.removeAll(visible.map((t) => t.id));
    } else {
      _selected.addAll(visible.map((t) => t.id));
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
    final visible = _visible;
    final allVisibleSelected =
        visible.isNotEmpty && visible.every((t) => _selected.contains(t.id));
    final count = _selected.length;

    return JamSheetScaffold(
      scrollController: widget.scrollController,
      header: JamSheetHeader(
        title: count == 0
            ? LibrarySheetStrings.title
            : LibrarySheetStrings.selectedCount(count),
        leading: JamTextButton(
          label: LibrarySheetStrings.cancel,
          onPressed: () => Navigator.of(context).pop(),
        ),
        trailing: JamTextButton(
          label: LibrarySheetStrings.done,
          bold: true,
          onPressed: count == 0 ? null : _submit,
        ),
      ),
      child: CustomScrollView(
        controller: widget.scrollController,
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                JamSpace.page,
                JamSpace.xs,
                JamSpace.page,
                0,
              ),
              child: CupertinoSearchTextField(
                controller: _query,
                placeholder: LibrarySheetStrings.search,
                style: context.jamBody,
                placeholderStyle: context.jamBody.copyWith(
                  color: colors.secondaryLabel,
                ),
                backgroundColor: colors.fillSecondary,
                itemColor: colors.secondaryLabel,
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              // The small plain button pads its label by 4, so 12 here puts
              // "Select All" on the same 16 trailing edge as the search field
              // and the checkmarks.
              padding: const EdgeInsetsDirectional.fromSTEB(
                JamSpace.page,
                JamSpace.xs,
                JamSpace.page - JamSpace.xs,
                0,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      LibrarySheetStrings.available(visible.length),
                      style: context.jamFootnote.copyWith(
                        color: colors.secondaryLabel,
                      ),
                    ),
                  ),
                  JamButton.plain(
                    label: allVisibleSelected
                        ? LibrarySheetStrings.deselectAll
                        : LibrarySheetStrings.selectAll,
                    size: JamButtonSize.small,
                    onPressed: visible.isEmpty
                        ? null
                        : () => _toggleAll(visible),
                  ),
                ],
              ),
            ),
          ),
          if (visible.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(top: JamSpace.huge),
                child: Text(
                  LibrarySheetStrings.noResults,
                  textAlign: TextAlign.center,
                  style: context.jamTitle3.copyWith(
                    color: colors.secondaryLabel,
                  ),
                ),
              ),
            ),
          SliverPadding(
            padding: EdgeInsets.only(
              bottom: JamSpace.lg + MediaQuery.paddingOf(context).bottom,
            ),
            sliver: SliverList.builder(
              itemCount: visible.length,
              itemBuilder: (context, index) {
                final track = visible[index];
                return _LibraryRow(
                  key: ValueKey(track.id),
                  track: track,
                  selected: _selected.contains(track.id),
                  separator: index < visible.length - 1,
                  onTap: () => _toggle(track.id),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// One library song: cover, title, "Artist · 3:42" and a checkmark circle.
/// The cover is read the first time the row is built.
class _LibraryRow extends StatefulWidget {
  const _LibraryRow({
    super.key,
    required this.track,
    required this.selected,
    required this.separator,
    required this.onTap,
  });

  final JamLibraryTrack track;
  final bool selected;
  final bool separator;
  final VoidCallback onTap;

  @override
  State<_LibraryRow> createState() => _LibraryRowState();
}

class _LibraryRowState extends State<_LibraryRow> {
  Uint8List? _cover;
  late bool _loading = widget.track.path != null;

  @override
  void initState() {
    super.initState();
    final pending =
        _LibraryCovers.peek(widget.track) ?? _LibraryCovers.load(widget.track);
    unawaited(
      pending.then((bytes) {
        if (!mounted) return;
        setState(() {
          _cover = bytes;
          _loading = false;
        });
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final track = widget.track;
    final selected = widget.selected;
    final ms = track.durationMs;
    final cover = _cover;
    final px = (JamArtworkSize.row * MediaQuery.devicePixelRatioOf(context))
        .round();
    return Semantics(
      selected: selected,
      child: JamTrackRow(
        title: stripAudioExtension(track.title),
        byline: track.artist ?? LibrarySheetStrings.unknownArtist,
        duration: ms == null ? null : Duration(milliseconds: ms),
        // Decoded at the size it is drawn, not at the file's 1400 px.
        artworkImage: cover == null
            ? null
            : ResizeImage(MemoryImage(cover), width: px, height: px),
        artworkId: cover == null ? null : identityHashCode(cover),
        artworkLoading: _loading,
        separator: widget.separator,
        onTap: widget.onTap,
        trailing: Icon(
          selected
              ? CupertinoIcons.checkmark_circle_fill
              : CupertinoIcons.circle,
          size: 24,
          semanticLabel: selected ? LibrarySheetStrings.selected : null,
          color: selected ? colors.tint : colors.tertiaryLabel,
        ),
      ),
    );
  }
}
