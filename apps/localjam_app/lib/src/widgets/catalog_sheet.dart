/// The host's shared music library (PROTOCOL.md §6.6), as a picker sheet.
///
/// The library picker's chrome (DESIGN_SPEC v3 §6.2) over a different list:
/// the songs on the host's phone, browsed from any phone in the jam. Cancel
/// and **Add** (the verb the sheet commits — §10.2), the app's search field
/// (title, artist and album, filtered on this phone), plain song rows with
/// their covers fetched for the rows on screen only, the selection check,
/// and Select all over what the search left. The title counts the
/// selection.
///
/// Nothing here adds anything: the sheet pops what was chosen and the
/// caller hands it to [JamSessionController.addFromCatalog].
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/foundation.dart' show ValueListenable, debugPrint;
import 'package:localjam_client/localjam_client.dart';

import '../design/tokens.dart';
import '../design/typography.dart';
import '../state/session_controller.dart';
import '../util/format.dart';
import '../util/media_picking.dart';
import 'buttons.dart';
import 'empty_state.dart';
import 'library_sheet.dart' show LibrarySheetStrings;
import 'progress.dart';
import 'room_sheet.dart' show RoomSheetStrings;
import 'sheet.dart';
import 'switch.dart' show JamSelectionCheck;
import 'text_field.dart';
import 'track_row.dart';

/// Everything this sheet says out loud that the library picker does not.
abstract final class CatalogSheetStrings {
  /// While the song list is on its way from the host.
  static const String loading = 'Getting the song list…';

  static const String emptyTitle = 'No songs yet';

  /// The sheet over an empty library, naming whose phone it is.
  static String emptyBody(String host) =>
      'There’s no music on $host’s phone yet.';

  static const String failedTitle = 'Couldn’t get the song list';
  static const String failedBody =
      'Check you’re still connected to the jam, then try again.';
  static const String retry = 'Try again';

  /// Why nothing can be chosen for a guest without `add_tracks` — the
  /// queue's own words for the same rule.
  static const String cantAdd = 'Only the host can add songs.';

  /// On a row whose song is already in the queue (§6.1 `catalogId`).
  static const String inQueue = 'In queue';

  /// The host turned sharing off while the sheet was open: the sheet
  /// closes and says why, rather than claiming the library is empty.
  static String stoppedSharing(String host) =>
      '$host stopped sharing their library.';
}

/// What the add-source sheet calls the host's shared library on a guest
/// ("Silky Puffin’s library", as the host's byline names them), or null
/// while there is none to browse (§6.6) — and always on the host, whose
/// own Music library already lists the same songs.
JamCatalogLabel? jamCatalogLabel(JamEngine engine) {
  if (engine is! JamGuestEngine || engine.catalog.value == null) return null;
  final host = jamCatalogHostName(engine);
  return (
    title: JamPickerStrings.catalogOf(host),
    detail: JamPickerStrings.catalogDetail(host),
  );
}

/// The host's display name, from a guest — or the role word when the host
/// shared none.
String jamCatalogHostName(JamEngine engine) {
  final name = engine.hostPeer?.clientName.trim() ?? '';
  return name.isEmpty ? RoomSheetStrings.host : name;
}

/// Opens the browse sheet over the host's shared library and hands what was
/// chosen to [JamSessionController.addFromCatalog] — the one path from
/// "Add songs" and from the Browse row alike, so a guest granted
/// `add_tracks` while browsing can add from there too. The add is not
/// awaited: songs land one at a time, and the caller's spinner must not
/// wait for them.
Future<void> jamAddFromCatalog(
  BuildContext context,
  JamGuestEngine engine,
) async {
  final session = JamSession.read(context);
  final chosen = await showJamCatalogSheet(context, engine);
  if (chosen == null || chosen.isEmpty) return;
  unawaited(session.addFromCatalog(chosen));
}

/// Opens the browse sheet over [engine]'s host's shared library. Pops the
/// songs chosen, or null when cancelled — or when the host stopped sharing
/// meanwhile, which closes the sheet with a notice.
Future<List<CatalogEntry>?> showJamCatalogSheet(
  BuildContext context,
  JamGuestEngine engine,
) {
  final session = JamSession.read(context);
  return showJamModalSheet<List<CatalogEntry>>(
    context,
    builder: (context) => buildJamDraggableSheet(
      initialChildSize: kJamSheetLargeSize,
      maxChildSize: kJamSheetLargeSize,
      minChildSize: kJamSheetMinSize,
      builder: (context, controller) => JamSheetSurface(
        child: _CatalogSheetBody(
          engine: engine,
          session: session,
          scrollController: controller,
        ),
      ),
    ),
  );
}

/// The browse sheet wired to a guest engine: what to list, where covers
/// come from, and whether this phone may add — kept live, so a host who
/// grants `add_tracks` while the sheet is open lights Add up.
class _CatalogSheetBody extends StatefulWidget {
  const _CatalogSheetBody({
    required this.engine,
    required this.session,
    this.scrollController,
  });

  final JamGuestEngine engine;
  final JamSessionController session;
  final ScrollController? scrollController;

  @override
  State<_CatalogSheetBody> createState() => _CatalogSheetBodyState();
}

class _CatalogSheetBodyState extends State<_CatalogSheetBody> {
  final List<StreamSubscription<Object?>> _subs = [];

  @override
  void initState() {
    super.initState();
    void refresh(Object? _) {
      if (mounted) setState(() {});
    }

    _subs
      ..add(widget.engine.permissionUpdates.listen(refresh))
      // What is already in the queue is marked on its row.
      ..add(widget.engine.playlistUpdates.listen(refresh));
  }

  @override
  void dispose() {
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    super.dispose();
  }

  void _withdrawn() {
    if (!mounted) return;
    final name = jamCatalogHostName(widget.engine);
    Navigator.of(context).pop();
    widget.session.notify(CatalogSheetStrings.stoppedSharing(name));
  }

  @override
  Widget build(BuildContext context) {
    final engine = widget.engine;
    final name = jamCatalogHostName(engine);
    return JamCatalogPicker(
      title: JamPickerStrings.catalogOf(name),
      emptyBody: CatalogSheetStrings.emptyBody(name),
      revision: engine.catalog,
      onWithdrawn: _withdrawn,
      load: engine.fetchCatalog,
      coverFor: engine.catalogArtworkFor,
      canAdd: engine.can(JamCapability.addTracks),
      queued: {for (final item in engine.playlist) ?item.catalogId},
      scrollController: widget.scrollController,
    );
  }
}

/// The browse sheet's body: the header, the search, the list and the
/// selection, over whatever [load] lists. Engine-free, so it can be tested
/// on its own.
class JamCatalogPicker extends StatefulWidget {
  const JamCatalogPicker({
    super.key,
    required this.title,
    required this.load,
    this.revision,
    this.coverFor,
    this.canAdd = true,
    this.queued = const {},
    this.emptyBody = '',
    this.onWithdrawn,
    this.scrollController,
  });

  /// The sheet's title while nothing is selected: whose library this is.
  final String title;

  /// The listing. Called once, again on every new [revision], and on Try
  /// again after a failure.
  final Future<List<CatalogEntry>> Function() load;

  /// The catalog's summary (§6.6): a new `rev` while the sheet is open
  /// lists it again, keeping whatever is still there selected.
  final ValueListenable<CatalogSummary?>? revision;

  /// A song's cover, asked for the first time its row is built (the rows
  /// on screen, not the whole library). Null: no covers.
  final Future<Uint8List?> Function(CatalogEntry entry)? coverFor;

  /// Whether this phone may add songs (`add_tracks`, §5.6). Without it the
  /// library can still be browsed, the rows are not selectable and Add is
  /// grey, with the reason under the search.
  final bool canAdd;

  /// Catalog ids whose songs are already in the queue (§6.1 `catalogId`):
  /// marked "In queue", not selectable, and left out of Select all.
  final Set<String> queued;

  /// The empty state's sentence, naming whose phone has no music.
  final String emptyBody;

  /// Called when [revision] goes null while the sheet is open — the host
  /// stopped sharing — instead of listing again. Null: list again.
  final VoidCallback? onWithdrawn;

  /// The sheet's scroll controller, so a drag at the top of the list moves
  /// the sheet.
  final ScrollController? scrollController;

  @override
  State<JamCatalogPicker> createState() => _JamCatalogPickerState();
}

class _JamCatalogPickerState extends State<JamCatalogPicker> {
  final Set<String> _selected = {};
  final TextEditingController _query = TextEditingController();

  List<CatalogEntry>? _entries;
  Object? _error;
  int? _rev;

  /// Bumped by every [_reload]: a listing that lands after a newer one was
  /// asked for is dropped.
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _query.addListener(_onQuery);
    _rev = widget.revision?.value?.rev;
    widget.revision?.addListener(_onRevision);
    unawaited(_reload());
  }

  @override
  void didUpdateWidget(JamCatalogPicker old) {
    super.didUpdateWidget(old);
    if (!identical(old.revision, widget.revision)) {
      old.revision?.removeListener(_onRevision);
      widget.revision?.addListener(_onRevision);
    }
    if (!widget.canAdd && _selected.isNotEmpty) _selected.clear();
    // A song that landed meanwhile cannot be chosen again.
    _selected.removeAll(widget.queued);
  }

  @override
  void dispose() {
    widget.revision?.removeListener(_onRevision);
    _query
      ..removeListener(_onQuery)
      ..dispose();
    super.dispose();
  }

  void _onQuery() => setState(() {});

  void _onRevision() {
    final summary = widget.revision?.value;
    final withdrawn = widget.onWithdrawn;
    if (summary == null && withdrawn != null) {
      withdrawn();
      return;
    }
    final rev = summary?.rev;
    if (rev == _rev) return;
    _rev = rev;
    unawaited(_reload(keepShowing: true));
  }

  /// Lists the library. [keepShowing]: a refresh under a list already on
  /// screen keeps it there until the new one lands, rather than flashing
  /// the spinner.
  Future<void> _reload({bool keepShowing = false}) async {
    final generation = ++_generation;
    if (!keepShowing || _entries == null) {
      setState(() {
        _entries = null;
        _error = null;
      });
    }
    try {
      final entries = await widget.load();
      if (!mounted || generation != _generation) return;
      setState(() {
        _entries = entries;
        _error = null;
        // What is no longer in the library cannot stay chosen.
        final ids = {for (final e in entries) e.catalogId};
        _selected.retainAll(ids);
      });
    } catch (e) {
      debugPrint('localjam: could not list the shared library: $e');
      if (!mounted || generation != _generation) return;
      setState(() {
        // A failed refresh under a list on screen keeps the list.
        if (_entries == null) _error = e;
      });
    }
  }

  List<CatalogEntry> _visible(List<CatalogEntry> entries) {
    final q = _query.text.trim().toLowerCase();
    if (q.isEmpty) return entries;
    bool has(String? s) => s != null && s.toLowerCase().contains(q);
    return [
      for (final e in entries)
        if (has(e.title) || has(e.artist) || has(e.album)) e,
    ];
  }

  void _toggleAll(List<CatalogEntry> choosable) => setState(() {
    final all = choosable.every((e) => _selected.contains(e.catalogId));
    if (all) {
      _selected.removeAll(choosable.map((e) => e.catalogId));
    } else {
      _selected.addAll(choosable.map((e) => e.catalogId));
    }
  });

  void _toggle(String id) => setState(() {
    if (!_selected.remove(id)) _selected.add(id);
  });

  void _submit() => Navigator.of(context).pop([
    for (final entry in _entries ?? const <CatalogEntry>[])
      if (_selected.contains(entry.catalogId)) entry,
  ]);

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final entries = _entries;
    final visible = entries == null
        ? const <CatalogEntry>[]
        : _visible(entries);
    final canAdd = widget.canAdd;
    final queued = widget.queued;
    final choosable = [
      for (final e in visible)
        if (!queued.contains(e.catalogId)) e,
    ];
    final allVisibleSelected =
        choosable.isNotEmpty &&
        choosable.every((e) => _selected.contains(e.catalogId));
    final count = _selected.length;

    Widget centred(Widget child) => SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.only(top: JamSpace.huge),
        child: child,
      ),
    );

    return JamSheetScaffold(
      scrollController: widget.scrollController,
      header: JamSheetHeader(
        title: count == 0
            ? widget.title
            : LibrarySheetStrings.selectedCount(count),
        // Nothing to commit without `add_tracks`: a sheet that only shows
        // closes with Done, never a grey verb (§10.2, CR-24). Add arrives
        // with the permission.
        actions: canAdd
            ? JamSheetActions.confirm(
                label: LibrarySheetStrings.add,
                onConfirm: count == 0 ? null : _submit,
                onCancel: () => Navigator.of(context).pop(),
              )
            : const JamSheetActions.done(),
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
              child: JamTextField(
                controller: _query,
                placeholder: LibrarySheetStrings.search,
                search: true,
                textCapitalization: TextCapitalization.none,
              ),
            ),
          ),
          if (!canAdd)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  JamSpace.page,
                  JamSpace.sm,
                  JamSpace.page,
                  0,
                ),
                child: Text(
                  CatalogSheetStrings.cantAdd,
                  style: context.jamFootnote.copyWith(
                    color: colors.secondaryLabel,
                  ),
                ),
              ),
            ),
          if (entries == null && _error == null)
            centred(
              Semantics(
                liveRegion: true,
                label: CatalogSheetStrings.loading,
                excludeSemantics: true,
                child: Column(
                  children: [
                    const JamProgressRing(size: JamProgressRing.controlSize),
                    const SizedBox(height: JamSpace.md),
                    Text(
                      CatalogSheetStrings.loading,
                      textAlign: TextAlign.center,
                      style: context.jamSubheadline.copyWith(
                        color: colors.secondaryLabel,
                      ),
                    ),
                  ],
                ),
              ),
            )
          else if (entries == null)
            centred(
              JamEmptyState(
                icon: CupertinoIcons.exclamationmark_circle,
                title: CatalogSheetStrings.failedTitle,
                body: CatalogSheetStrings.failedBody,
                actionLabel: CatalogSheetStrings.retry,
                actionVariant: JamButtonVariant.gray,
                onAction: () => unawaited(_reload()),
              ),
            )
          else if (entries.isEmpty)
            centred(
              JamEmptyState(
                icon: CupertinoIcons.music_house,
                title: CatalogSheetStrings.emptyTitle,
                body: widget.emptyBody,
              ),
            )
          else if (visible.isEmpty)
            centred(
              JamEmptyState(
                icon: CupertinoIcons.search,
                title: LibrarySheetStrings.noResults,
                body: LibrarySheetStrings.noResultsFor(_query.text.trim()),
              ),
            )
          else ...[
            SliverToBoxAdapter(
              child: Padding(
                // As the library picker: "Select all" on the same 16
                // trailing edge as the search field and the checkmarks.
                padding: const EdgeInsetsDirectional.fromSTEB(
                  JamSpace.page,
                  JamSpace.xs,
                  JamSpace.page - JamSpace.xs,
                  0,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Padding(
                        padding: EdgeInsets.symmetric(
                          vertical: canAdd ? 0 : JamSpace.sm,
                        ),
                        child: Text(
                          LibrarySheetStrings.available(visible.length),
                          style: context.jamFootnote.copyWith(
                            color: colors.secondaryLabel,
                          ),
                        ),
                      ),
                    ),
                    if (canAdd && choosable.isNotEmpty)
                      JamButton.plain(
                        label: allVisibleSelected
                            ? LibrarySheetStrings.deselectAll
                            : LibrarySheetStrings.selectAll,
                        size: JamButtonSize.small,
                        onPressed: () => _toggleAll(choosable),
                      ),
                  ],
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
                  final entry = visible[index];
                  return _CatalogRow(
                    key: ValueKey(entry.catalogId),
                    entry: entry,
                    coverFor: widget.coverFor,
                    selectable: canAdd && !queued.contains(entry.catalogId),
                    inQueue: queued.contains(entry.catalogId),
                    selected: _selected.contains(entry.catalogId),
                    separator: index < visible.length - 1,
                    onTap: () => _toggle(entry.catalogId),
                  );
                },
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// One song of the shared library: cover, title, "Artist · 3:42" and a
/// selection check. The cover is asked for the first time the row is built
/// — the list builds the rows on screen, so a 3,000-song library costs the
/// host nothing until someone scrolls (§6.6).
class _CatalogRow extends StatefulWidget {
  const _CatalogRow({
    super.key,
    required this.entry,
    required this.coverFor,
    required this.selectable,
    this.inQueue = false,
    required this.selected,
    required this.separator,
    required this.onTap,
  });

  final CatalogEntry entry;
  final Future<Uint8List?> Function(CatalogEntry entry)? coverFor;
  final bool selectable;

  /// Already in the queue: says so where the check would be.
  final bool inQueue;
  final bool selected;
  final bool separator;
  final VoidCallback onTap;

  @override
  State<_CatalogRow> createState() => _CatalogRowState();
}

class _CatalogRowState extends State<_CatalogRow> {
  Uint8List? _cover;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    final coverFor = widget.coverFor;
    if (coverFor == null || widget.entry.hasArtwork == false) return;
    _loading = true;
    unawaited(
      coverFor(widget.entry).then(
        (bytes) {
          if (!mounted) return;
          setState(() {
            _cover = bytes;
            _loading = false;
          });
        },
        onError: (Object _) {
          if (mounted) setState(() => _loading = false);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final selected = widget.selected;
    final us = entry.durationUs;
    final cover = _cover;
    final px = (JamArtworkSize.row * MediaQuery.devicePixelRatioOf(context))
        .round();
    return Semantics(
      selected: widget.selectable && selected,
      child: JamTrackRow(
        title: stripAudioExtension(entry.title),
        byline: jamSongByline(artist: entry.artist, album: entry.album),
        duration: us == null ? null : Duration(microseconds: us),
        artworkImage: cover == null
            ? null
            : ResizeImage(MemoryImage(cover), width: px, height: px),
        artworkId: cover == null ? null : identityHashCode(cover),
        artworkLoading: _loading,
        separator: widget.separator,
        onTap: widget.selectable ? widget.onTap : null,
        trailing: widget.inQueue
            ? Text(
                CatalogSheetStrings.inQueue,
                style: context.jamFootnote.copyWith(
                  color: context.jamColors.secondaryLabel,
                ),
              )
            : widget.selectable
            ? JamSelectionCheck(
                selected: selected,
                semanticLabel: LibrarySheetStrings.selected,
              )
            : null,
      ),
    );
  }
}
