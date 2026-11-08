/// The device music library, as a picker sheet (DESIGN_SPEC v3 §6.2).
///
/// Used by Start a Jam and by the in-room Add Songs: on Android most music is
/// in MediaStore, not in a folder DocumentsUI will show you.
///
/// Apple Music's "Add Songs" picker: a large sheet with Cancel and **Add**
/// (the verb the sheet commits — §10.2), the app's search field, plain song
/// rows (cover, title, "Artist · 3:42") and the app's selection check on
/// each chosen one. The title counts the selection.
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
import 'empty_state.dart';
import 'sheet.dart';
import 'switch.dart' show JamSelectionCheck;
import 'text_field.dart';
import 'track_row.dart';

/// Everything this sheet says out loud.
abstract final class LibrarySheetStrings {
  static const String title = 'Music library';
  static const String cancel = 'Cancel';

  /// The commit: what it does to the jam, not "Done".
  static const String add = 'Add';
  static const String search = 'Search';
  static const String selectAll = 'Select all';
  static const String deselectAll = 'Deselect all';
  static const String selected = 'Selected';
  static const String noResults = 'No results';

  /// Says what was searched for, rather than a stock "check the spelling".
  static String noResultsFor(String query) => 'No songs match “$query”.';

  /// "3 songs selected" — the title once something is chosen.
  static String selectedCount(int n) =>
      n == 1 ? '1 song selected' : '$n songs selected';

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
///
/// [reload] reads the library again: it runs whenever the app comes back to
/// the foreground with the sheet open, so songs that arrived meanwhile (a
/// download, a file copied over) show up without closing it.
Future<List<JamLibraryTrack>?> showJamLibrarySheet(
  BuildContext context,
  List<JamLibraryTrack> tracks, {
  Future<List<JamLibraryTrack>> Function()? reload,
}) {
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
        child: JamLibraryPicker(
          tracks: tracks,
          reload: reload,
          scrollController: controller,
        ),
      ),
    ),
  );
}

/// The picker's body: the header, the search, the list and the selection.
class JamLibraryPicker extends StatefulWidget {
  const JamLibraryPicker({
    super.key,
    required this.tracks,
    this.reload,
    this.scrollController,
  });

  /// The library as it was when the sheet opened.
  final List<JamLibraryTrack> tracks;

  /// Reads the library again, on every return to the foreground.
  final Future<List<JamLibraryTrack>> Function()? reload;

  /// The sheet's scroll controller, so a drag at the top of the list moves
  /// the sheet.
  final ScrollController? scrollController;

  @override
  State<JamLibraryPicker> createState() => _JamLibraryPickerState();
}

class _JamLibraryPickerState extends State<JamLibraryPicker> {
  final Set<int> _selected = {};
  final TextEditingController _query = TextEditingController();
  late List<JamLibraryTrack> _tracks = widget.tracks;
  AppLifecycleListener? _lifecycle;
  bool _reloading = false;

  @override
  void initState() {
    super.initState();
    _query.addListener(_onQuery);
    if (widget.reload != null) {
      _lifecycle = AppLifecycleListener(onResume: () => unawaited(_reload()));
    }
  }

  @override
  void didUpdateWidget(JamLibraryPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.tracks, widget.tracks)) _tracks = widget.tracks;
  }

  /// Picks up songs added to the library while the sheet was open. The
  /// selection keeps every song still there; one that has gone drops out.
  Future<void> _reload() async {
    final reload = widget.reload;
    if (reload == null || _reloading) return;
    _reloading = true;
    try {
      final fresh = await reload();
      if (!mounted || fresh.isEmpty) return;
      setState(() {
        _tracks = fresh;
        final ids = {for (final t in fresh) t.id};
        _selected.retainAll(ids);
      });
    } catch (e) {
      // The list on screen is still a fine list to pick from.
      debugPrint('localjam: library refresh failed: $e');
    } finally {
      _reloading = false;
    }
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    _query
      ..removeListener(_onQuery)
      ..dispose();
    super.dispose();
  }

  void _onQuery() => setState(() {});

  List<JamLibraryTrack> get _visible {
    final q = _query.text.trim().toLowerCase();
    if (q.isEmpty) return _tracks;
    bool has(String? s) => s != null && s.toLowerCase().contains(q);
    return [
      for (final t in _tracks)
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
    for (final track in _tracks)
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
        actions: JamSheetActions.confirm(
          label: LibrarySheetStrings.add,
          onConfirm: count == 0 ? null : _submit,
          onCancel: () => Navigator.of(context).pop(),
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
              // The app's one field, with its magnifier: the same shape,
              // placeholder and clear button as every other.
              child: JamTextField(
                controller: _query,
                placeholder: LibrarySheetStrings.search,
                search: true,
                textCapitalization: TextCapitalization.none,
              ),
            ),
          ),
          // No "0 songs" and no dead Select All over an empty result.
          if (visible.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                // The small plain button pads its label by 4, so 12 here puts
                // "Select all" on the same 16 trailing edge as the search field
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
                      onPressed: () => _toggleAll(visible),
                    ),
                  ],
                ),
              ),
            ),
          if (visible.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(top: JamSpace.huge),
                child: JamEmptyState(
                  icon: CupertinoIcons.search,
                  title: LibrarySheetStrings.noResults,
                  body: LibrarySheetStrings.noResultsFor(_query.text.trim()),
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

/// One library song: cover, title, "Artist · 3:42" and a selection check.
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
        // The one second line (N8): no "Unknown artist" filler.
        byline: jamSongByline(artist: track.artist, album: track.album),
        duration: ms == null ? null : Duration(milliseconds: ms),
        // Decoded at the size it is drawn, not at the file's 1400 px.
        artworkImage: cover == null
            ? null
            : ResizeImage(MemoryImage(cover), width: px, height: px),
        artworkId: cover == null ? null : identityHashCode(cover),
        artworkLoading: _loading,
        separator: widget.separator,
        onTap: widget.onTap,
        trailing: JamSelectionCheck(
          selected: selected,
          semanticLabel: LibrarySheetStrings.selected,
        ),
      ),
    );
  }
}
