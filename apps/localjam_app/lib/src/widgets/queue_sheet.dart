/// The queue — the room's social object.
///
/// One implementation for host and guest, capability-gated. Every row carries
/// attribution, because "who put this on" is most of what makes a shared queue
/// feel like a room rather than a playlist. Adding works while live on both
/// sides now; the old UI hid the host's add button once the session started,
/// which on a long drive meant the host could never extend their own queue.
///
/// Design spec §5 "Queue sheet": the current track is pinned under a NOW
/// PLAYING rule and the rest sit under NEXT UP; a guest's upload is a 3 dp
/// line under the header rather than a bar dropped into the list (§6.10); and
/// a guest who may not add sees the Add button *disabled with a reason*,
/// never a header that quietly lost a control.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:localjam_client/localjam_client.dart';

import '../design/tokens.dart';
import '../design/typography.dart';
import '../state/queue_actions.dart';
import '../state/session_controller.dart';
import '../util/format.dart';
import '../util/media_picking.dart';
import 'artwork.dart';
import 'buttons.dart';
import 'empty_state.dart';
import 'sheet.dart';
import 'track_row.dart';

/// Everything this sheet says out loud.
abstract final class QueueSheetStrings {
  static const String title = 'Queue';
  static const String add = 'Add';
  static const String addMusic = 'Add music';
  static const String nowPlaying = 'NOW PLAYING';
  static const String nextUp = 'NEXT UP';
  static const String remove = 'Remove from the queue';
  static const String swipeToRemove = 'Swipe left to remove';

  /// Confirmation after a swipe, so a removal is never silent.
  static String removed(String title) => 'Removed $title';
  static const String undo = 'Undo';
  static const String uploading = 'Sending your track to the room';
  static const String hostRunsQueue = 'The host is running this queue';
  static const String nowPlayingLocked =
      'The track that\u2019s playing stays at the top';
  static const String emptyTitle = 'Nothing queued';
  static const String emptyCanAdd =
      'Add tracks from this device and everyone in the room hears them.';
  static const String emptyCannotAdd = 'The host has not queued anything yet.';

  /// "1 track" / "12 tracks".
  static String count(int n) => '$n ${n == 1 ? 'track' : 'tracks'}';
}

/// Where the equaliser badge sits on the playing row's cover — bottom-right
/// of the 48 dp tile, inside [JamTrackRow]'s own artwork clip.
const double _badgeSize = 12;
const double _badgeInset = 4;

/// The height a queue of [rows] wants, as a fraction of [viewportHeight].
///
/// A fixed 0.82 opened three tracks over half a screen of nothing — the sheet
/// claimed the window and then had nothing to put in it. This measures the
/// content instead: header, section rules, the rows themselves and a little
/// air, floored at [kJamQueueMinSize] so a one-track queue still reads as a
/// sheet, and capped at the spec's 0.82 once there is enough to fill it.
double jamQueueSheetExtent({
  required int rows,
  required double viewportHeight,
}) {
  // An empty queue is not short content — it is the empty state, which wants
  // the room the spec's 0.82 gives it.
  if (rows == 0 || viewportHeight <= 0) return kJamSheetInitialSize;
  const chrome = 64.0 + 28.0 * 2 + JamSpace.xxxl;
  final wanted = chrome + kJamTrackRowHeight * rows;
  final fraction = wanted / viewportHeight;
  if (fraction < kJamQueueMinSize) return kJamQueueMinSize;
  return fraction > kJamSheetInitialSize ? kJamSheetInitialSize : fraction;
}

/// The floor for a short queue.
const double kJamQueueMinSize = 0.45;

/// Opens the queue as a modal sheet. Compact layouts only — wide ones keep
/// [QueuePanel] open beside the player instead.
Future<void> showQueueSheet(BuildContext context, JamEngine engine) {
  return showJamSheet<void>(
    context,
    title: QueueSheetStrings.title,
    trailing: QueueHeaderActions(engine: engine),
    initialChildSize: jamQueueSheetExtent(
      rows: engine.playlist.length,
      viewportHeight: MediaQuery.sizeOf(context).height,
    ),
    builder: (context) => QueuePanel(engine: engine, showHeader: false),
  );
}

/// The queue itself, laid out as a column so it works as both a sheet body
/// and a docked desktop panel.
class QueuePanel extends StatefulWidget {
  const QueuePanel({
    super.key,
    required this.engine,
    this.scrollController,
    this.showHeader = true,
  });

  final JamEngine engine;

  /// Supplied by a DraggableScrollableSheet; when null the enclosing sheet's
  /// controller is picked up from [JamSheetScrollController], and a docked
  /// panel simply scrolls on its own.
  final ScrollController? scrollController;

  /// Whether to draw the sheet header. False inside [showQueueSheet], which
  /// lets the sheet own it.
  final bool showHeader;

  @override
  State<QueuePanel> createState() => _QueuePanelState();
}

class _QueuePanelState extends State<QueuePanel> {
  final List<StreamSubscription<Object?>> _subs = [];

  /// mediaIds the list has already drawn, so only genuinely new rows play the
  /// insert animation (§5 "Adding").
  Set<String> _seen = const {};
  bool _drawnOnce = false;

  /// This device's display name, so your own rows carry your own face rather
  /// than a disc lettered from the word "You".
  String _selfName = '';

  JamEngine get _engine => widget.engine;

  Future<void> _loadIdentity() async {
    final name = await JamIdentity.displayName();
    if (mounted && name != _selfName) setState(() => _selfName = name);
  }

  @override
  void initState() {
    super.initState();
    unawaited(_loadIdentity());
    void refresh(Object? _) {
      if (mounted) setState(() {});
    }

    _subs
      ..add(_engine.playlistUpdates.listen(refresh))
      ..add(_engine.states.listen(refresh))
      ..add(_engine.permissionUpdates.listen(refresh));
    final guest = _engine;
    if (guest is JamGuestEngine) {
      guest.prefetchStates.addListener(_onPrefetch);
    }
  }

  void _onPrefetch() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    final guest = _engine;
    if (guest is JamGuestEngine) {
      guest.prefetchStates.removeListener(_onPrefetch);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final playlist = _engine.playlist;
    final peers = _engine.peers;
    final canAdd = _engine.can(JamCapability.addTracks);
    final canEdit = _engine.can(JamCapability.editQueue);
    final canControl = _engine.can(JamCapability.controlPlayback);
    final currentId = _engine.snapshot.mediaId;
    final playing = _engine.snapshot.status == PlaybackStatus.playing;

    final ids = {for (final item in playlist) item.mediaId};
    final fresh = _drawnOnce ? ids.difference(_seen) : const <String>{};
    _seen = ids;
    _drawnOnce = true;

    final current = playlist
        .where((item) => item.mediaId == currentId)
        .firstOrNull;
    final rest = [
      for (final item in playlist)
        if (item.mediaId != currentId) item,
    ];

    // The key rides on the outermost widget: `SliverReorderableList` looks
    // for it there, and the insert animation wraps the row.
    Widget row(MediaItem item, {required bool isCurrent, int? dragIndex}) =>
        KeyedSubtree(
          key: ValueKey(item.mediaId),
          child: _QueueRow(
            engine: _engine,
            item: item,
            peers: peers,
            selfName: _selfName,
            isCurrent: isCurrent,
            // The pinned row carries no grip, but it holds the grip's width
            // open so its duration lines up with everyone else's.
            reserveHandle: isCurrent && canEdit,
            playing: playing,
            animateIn: fresh.contains(item.mediaId),
            dragIndex: dragIndex,
            canRemove: jamCanRemove(_engine, item),
            onTap: canControl
                ? () => unawaited(jamSetMedia(_engine, item.mediaId))
                : null,
            onRemove: () => unawaited(jamRemoveItem(_engine, item.mediaId)),
          ),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.showHeader)
          JamSheetHeader(
            title: QueueSheetStrings.title,
            trailing: QueueHeaderActions(engine: _engine),
          ),
        // Pinned under the header rather than dropped into the flow, so a
        // running upload never shifts the list under a finger (§6.10).
        _UploadLine(engine: _engine),
        if (!canAdd) const _QueueGateNote(),
        Expanded(
          child: playlist.isEmpty
              ? JamEmptyState(
                  icon: Icons.queue_music_rounded,
                  gradientMark: true,
                  title: QueueSheetStrings.emptyTitle,
                  body: canAdd
                      ? QueueSheetStrings.emptyCanAdd
                      : QueueSheetStrings.emptyCannotAdd,
                  actionLabel: canAdd ? QueueSheetStrings.addMusic : null,
                  onAction: canAdd
                      ? () => unawaited(jamAddToQueue(context, _engine))
                      : null,
                )
              : CustomScrollView(
                  controller:
                      widget.scrollController ??
                      JamSheetScrollController.maybeOf(context),
                  slivers: [
                    if (current != null) ...[
                      SliverToBoxAdapter(
                        child: _SectionRule(
                          label: QueueSheetStrings.nowPlaying,
                        ),
                      ),
                      SliverToBoxAdapter(child: row(current, isCurrent: true)),
                    ],
                    if (rest.isNotEmpty)
                      SliverToBoxAdapter(
                        child: _SectionRule(label: QueueSheetStrings.nextUp),
                      ),
                    if (canEdit)
                      SliverReorderableList(
                        itemCount: rest.length,
                        // A reorder drag and the sheet's own drag-to-dismiss
                        // are one finger in two arenas; the lock keeps the
                        // sheet still while a row is in the air.
                        onReorderStart: (_) =>
                            JamSheetDragLock.maybeOf(context)?.lock(),
                        onReorderEnd: (_) =>
                            JamSheetDragLock.maybeOf(context)?.unlock(),
                        onReorderItem: (oldIndex, newIndex) {
                          JamSheetDragLock.maybeOf(context)?.unlock();
                          final move = queueReorderTarget(
                            playlist: playlist,
                            currentId: currentId,
                            oldIndex: oldIndex,
                            newIndex: newIndex,
                          );
                          if (move != null) {
                            unawaited(
                              jamMoveItem(_engine, move.mediaId, move.toIndex),
                            );
                          }
                        },
                        itemBuilder: (context, index) => row(
                          rest[index],
                          isCurrent: false,
                          dragIndex: index,
                        ),
                      )
                    else
                      SliverList.builder(
                        itemCount: rest.length,
                        itemBuilder: (context, index) =>
                            row(rest[index], isCurrent: false),
                      ),
                    // The header carries the count; the list only needs room
                    // to clear the home indicator.
                    SliverToBoxAdapter(
                      child: SizedBox(
                        height:
                            JamSpace.huge +
                            MediaQuery.paddingOf(context).bottom,
                      ),
                    ),
                  ],
                ),
        ),
      ],
    );
  }
}

/// Where a queue row dropped at [newIndex] of the NEXT UP list lands in the
/// *whole* playlist.
///
/// The sheet shows two groups (the pinned current track, then the rest) but
/// the engine moves items within one list, so the reorder has to be replayed
/// against the full order before it can be sent. Pure, and tested directly.
({String mediaId, int toIndex})? queueReorderTarget({
  required List<MediaItem> playlist,
  required String? currentId,
  required int oldIndex,
  required int newIndex,
}) {
  final rest = [
    for (final item in playlist)
      if (item.mediaId != currentId) item.mediaId,
  ];
  if (oldIndex < 0 || oldIndex >= rest.length) return null;
  // `onReorderItem` (unlike the deprecated `onReorder`) hands back an index
  // already adjusted for the removed row.
  final target = newIndex.clamp(0, rest.length - 1);
  if (target == oldIndex) return null;

  final movedId = rest[oldIndex];
  final reordered = List<String>.of(rest)..removeAt(oldIndex);
  reordered.insert(target, movedId);

  final currentIndex = currentId == null
      ? -1
      : playlist.indexWhere((item) => item.mediaId == currentId);
  if (currentIndex >= 0) {
    reordered.insert(math.min(currentIndex, reordered.length), currentId!);
  }
  var toIndex = reordered.indexOf(movedId);

  // NOW PLAYING is not a drop target. Dropping a row above the current track
  // used to land it at playlist index 0, which on a host silently changed
  // what was playing — a queue reorder should never touch the transport.
  // The floor is the slot immediately after the current track in the list
  // the engine will have once the moved item is lifted out of it.
  if (currentId != null) {
    final withoutMoved = [
      for (final item in playlist)
        if (item.mediaId != movedId) item.mediaId,
    ];
    final currentAfterLift = withoutMoved.indexOf(currentId);
    if (currentAfterLift >= 0) {
      toIndex = math.max(toIndex, currentAfterLift + 1);
    }
  }
  if (toIndex == playlist.indexWhere((item) => item.mediaId == movedId)) {
    return null;
  }
  return (mediaId: movedId, toIndex: toIndex);
}

/// The header's right-hand side: the track count and the Add action.
///
/// A widget of its own because the sheet builds its header above this panel's
/// state — the count has to stay live while people add tracks.
class QueueHeaderActions extends StatefulWidget {
  const QueueHeaderActions({super.key, required this.engine});

  final JamEngine engine;

  @override
  State<QueueHeaderActions> createState() => _QueueHeaderActionsState();
}

class _QueueHeaderActionsState extends State<QueueHeaderActions> {
  final List<StreamSubscription<Object?>> _subs = [];
  bool _adding = false;

  @override
  void initState() {
    super.initState();
    void refresh(Object? _) {
      if (mounted) setState(() {});
    }

    _subs
      ..add(widget.engine.playlistUpdates.listen(refresh))
      ..add(widget.engine.permissionUpdates.listen(refresh));
  }

  @override
  void dispose() {
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    super.dispose();
  }

  Future<void> _add() async {
    setState(() => _adding = true);
    try {
      await jamAddToQueue(context, widget.engine);
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final canAdd = widget.engine.can(JamCapability.addTracks);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          QueueSheetStrings.count(widget.engine.playlist.length),
          style: context.jamFootnote,
        ),
        const SizedBox(width: JamSpace.sm),
        // Never vanishes when the room says no: a control that disappears
        // reads as a bug, a disabled one reads as a rule.
        JamButton.tertiary(
          label: QueueSheetStrings.add,
          icon: Icons.add_rounded,
          loading: _adding,
          onPressed: canAdd ? () => unawaited(_add()) : null,
        ),
      ],
    );
  }
}

/// Why the Add button next to this is grey.
class _QueueGateNote extends StatelessWidget {
  const _QueueGateNote();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      JamSpace.page,
      JamSpace.sm,
      JamSpace.page,
      0,
    ),
    child: Text(QueueSheetStrings.hostRunsQueue, style: context.jamFootnote),
  );
}

/// The guest's upload, as a 3 dp accent line under the header.
class _UploadLine extends StatelessWidget {
  const _UploadLine({required this.engine});

  final JamEngine engine;

  @override
  Widget build(BuildContext context) {
    final guest = engine;
    if (guest is! JamGuestEngine) return const SizedBox.shrink();
    final colors = context.jamColors;
    return ValueListenableBuilder<double?>(
      valueListenable: guest.uploadProgress,
      builder: (context, progress, _) => progress == null
          ? const SizedBox.shrink()
          : Semantics(
              liveRegion: true,
              label: QueueSheetStrings.uploading,
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 3,
                color: colors.accent,
                backgroundColor: colors.surfaceMuted,
              ),
            ),
    );
  }
}

/// A "NOW PLAYING" / "NEXT UP" rule.
class _SectionRule extends StatelessWidget {
  const _SectionRule({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        JamSpace.page,
        JamSpace.lg,
        JamSpace.page,
        JamSpace.sm,
      ),
      child: Semantics(
        header: true,
        child: Text(
          label,
          style: context.jamCaption.copyWith(color: colors.textTertiary),
        ),
      ),
    );
  }
}

/// One queue row: the shared [JamTrackRow], plus the two things only a queue
/// needs — the equaliser badge on the playing cover and the drag grip.
class _QueueRow extends StatelessWidget {
  const _QueueRow({
    required this.engine,
    required this.item,
    required this.peers,
    required this.selfName,
    required this.isCurrent,
    required this.playing,
    required this.animateIn,
    required this.canRemove,
    required this.onTap,
    required this.onRemove,
    this.dragIndex,
    this.reserveHandle = false,
  });

  final JamEngine engine;
  final MediaItem item;
  final List<PeerInfo> peers;

  /// This device's display name, for the "you" face.
  final String selfName;

  final bool isCurrent;
  final bool playing;
  final bool animateIn;
  final bool canRemove;
  final VoidCallback? onTap;
  final VoidCallback onRemove;

  /// Position in the reorderable list, or null when the queue is read-only.
  final int? dragIndex;

  /// Holds the drag grip's width open without drawing one — the pinned row.
  final bool reserveHandle;

  /// Removes the track and says so — with a way back, since a swipe leaves
  /// nothing behind and a mis-swipe on someone else's phone is a track the
  /// room just lost.
  void _removeAndSay(BuildContext context) {
    final title = jamDisplayTitle(item);
    final mediaId = item.mediaId;
    // Where it was, so Undo puts it back where it was rather than at the end.
    final index = engine.playlist.indexWhere((i) => i.mediaId == mediaId);
    final session = JamSession.read(context);
    // Only the host can put a file back, and only while the bytes are still
    // on this device: offering an Undo that cannot run is worse than none.
    final undoable = index >= 0 && session.canReinsert(mediaId);
    onRemove();
    // Through the controller's single notice channel, not straight at the
    // overlay: a swipe raises this from the row that is being removed, and by
    // the time the dismissal settles that row's context is on its way out.
    // The router shell owns the one subscriber and knows where a notice may
    // land on this route.
    session.notify(
      QueueSheetStrings.removed(title),
      actionLabel: undoable ? QueueSheetStrings.undo : null,
      onAction: undoable
          ? () => unawaited(session.reinsertItem(mediaId, index))
          : null,
    );
  }

  /// The accessible route to the same action as the swipe.
  Future<void> _menu(BuildContext context) async {
    if (!canRemove) return;
    final box = context.findRenderObject() as RenderBox?;
    final overlay =
        Navigator.of(context).overlay?.context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null) return;
    final origin = box.localToGlobal(Offset.zero, ancestor: overlay);
    final chose = await showMenu<bool>(
      context: context,
      position: RelativeRect.fromLTRB(
        origin.dx,
        origin.dy + box.size.height,
        overlay.size.width - origin.dx - box.size.width,
        0,
      ),
      items: [
        PopupMenuItem<bool>(
          value: true,
          child: Text(
            QueueSheetStrings.remove,
            // Destructive, and the only item in the menu: it should look like
            // what it does rather than like a neutral list entry.
            style: TextStyle(color: context.jamColors.danger),
          ),
        ),
      ],
    );
    if (chose == true && context.mounted) _removeAndSay(context);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    // Everyone's contribution is credited, yours included: a solo-hosted room
    // with no faces at all was the review's "where are the people?".
    final addedBy = engine.addedByLabel(item, peers);
    final guest = engine is JamGuestEngine ? engine as JamGuestEngine : null;
    final prefetch = guest?.prefetchStates.value[item.mediaId];
    final fetching = prefetch?.phase == JamPrefetchPhase.fetching;
    final failed = prefetch?.phase == JamPrefetchPhase.failed;
    final index = dragIndex;

    Widget row = FutureBuilder<Uint8List?>(
      future: item.artworkId == null ? null : engine.artworkFor(item),
      builder: (context, snapshot) => JamTrackRow(
        title: jamDisplayTitle(item),
        byline: artworkByline(item),
        artworkBytes: snapshot.data,
        artworkId: item.artworkId,
        artworkLoading:
            item.artworkId != null &&
            snapshot.connectionState != ConnectionState.done,
        addedByName: addedBy,
        addedByYou: addedBy == 'You',
        // Your rows wear your face, not a "Y" disc (§8.2: are there people
        // on screen?).
        addedByAvatarName: addedBy == 'You' ? selfName : null,
        isCurrent: isCurrent,
        duration: item.durationUs == null
            ? null
            : Duration(microseconds: item.durationUs!),
        prefetchProgress: fetching ? (prefetch?.progress ?? 0) : null,
        hasError: failed,
        artworkOverlay: isCurrent
            ? Padding(
                padding: const EdgeInsets.all(_badgeInset),
                child: Align(
                  alignment: Alignment.bottomRight,
                  child: _EqualiserBadge(playing: playing),
                ),
              )
            : null,
        showDragHandle: index != null,
        reserveDragHandle: reserveHandle,
        onTap: onTap,
        onLongPress: canRemove ? () => unawaited(_menu(context)) : null,
        // The grey remove_circle on every row turned the queue into a list of
        // delete buttons. Removal is a swipe now, with the long-press menu as
        // the accessible equivalent; the trailing slot goes back to status.
        trailing: _StatusSlot(
          item: item,
          prefetch: prefetch,
          isGuest: guest != null,
        ),
        // The 3×20 accent bar is flush to the *row's* left edge, and the row
        // is inset from the sheet by the page margin — otherwise the bar ran
        // off the sheet and was shaved by its rounded corner.
        contentPadding: const EdgeInsets.only(left: JamSpace.md),
      ),
    );

    if (canRemove) {
      row = Dismissible(
        key: ValueKey<String>('queue-dismiss-${item.mediaId}'),
        direction: DismissDirection.endToStart,
        dismissThresholds: const {DismissDirection.endToStart: 0.45},
        background: _RemoveBackground(colors: colors),
        onDismissed: (_) => _removeAndSay(context),
        child: row,
      );
    }

    row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: JamSpace.page),
      child: row,
    );

    row = Stack(
      children: [
        row,
        if (index != null)
          Positioned(
            top: 0,
            bottom: 0,
            right: JamSpace.page,
            width: 40,
            // ColoredBox, not SizedBox: `ReorderableDragStartListener` wraps
            // its child in a `Listener` that defers hit testing, and an empty
            // SizedBox never claims the pointer — the drag fell through to the
            // sheet, which grew instead of picking the row up.
            child: ReorderableDragStartListener(
              index: index,
              child: const ColoredBox(color: Color(0x00000000)),
            ),
          ),
      ],
    );

    return animateIn ? _InsertReveal(child: row) : row;
  }
}

/// What a row slides off to reveal: the danger ground and one glyph.
class _RemoveBackground extends StatelessWidget {
  const _RemoveBackground({required this.colors});

  final JamColors colors;

  @override
  Widget build(BuildContext context) => Container(
    alignment: Alignment.centerRight,
    padding: const EdgeInsets.only(right: JamSpace.lg),
    margin: const EdgeInsets.symmetric(vertical: JamSpace.xs),
    decoration: BoxDecoration(
      color: colors.danger.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(JamRadius.md),
    ),
    child: Icon(Icons.delete_outline_rounded, size: 22, color: colors.danger),
  );
}

/// The trailing status a row keeps when it also carries a remove button.
class _StatusSlot extends StatelessWidget {
  const _StatusSlot({
    required this.item,
    required this.prefetch,
    required this.isGuest,
  });

  final MediaItem item;
  final JamPrefetchState? prefetch;
  final bool isGuest;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    if (isGuest) {
      switch (prefetch?.phase) {
        case JamPrefetchPhase.fetching:
          return SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              value: prefetch!.progress == 0 ? null : prefetch!.progress,
              backgroundColor: colors.surfaceMuted,
              valueColor: AlwaysStoppedAnimation<Color>(colors.accent),
            ),
          );
        case JamPrefetchPhase.failed:
          return Icon(
            Icons.error_outline_rounded,
            size: 18,
            color: colors.danger,
          );
        case _:
          break;
      }
    }
    final duration = item.durationUs;
    if (duration == null) return const SizedBox.shrink();
    return Text(
      formatPositionUs(duration),
      style: jamNumericStyle(colors.textTertiary),
    );
  }
}

/// The 12×12 three-bar badge on the playing row's cover. One controller —
/// only ever one row is current, and the bars are phases of it.
class _EqualiserBadge extends StatefulWidget {
  const _EqualiserBadge({required this.playing});

  final bool playing;

  @override
  State<_EqualiserBadge> createState() => _EqualiserBadgeState();
}

class _EqualiserBadgeState extends State<_EqualiserBadge>
    with SingleTickerProviderStateMixin {
  /// 2100 ms is the common multiple of the three bars' 700/900/1100 ms loops
  /// closely enough that the pattern never visibly repeats on a short glance.
  late final AnimationController _bars = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2100),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(_EqualiserBadge old) {
    super.didUpdateWidget(old);
    _sync();
  }

  /// Frozen when paused — the badge is a statement about sound, not a
  /// decoration.
  void _sync() {
    final wanted = widget.playing && !MediaQuery.disableAnimationsOf(context);
    if (wanted && !_bars.isAnimating) {
      _bars.repeat();
    } else if (!wanted && _bars.isAnimating) {
      _bars.stop();
    }
  }

  @override
  void dispose() {
    _bars.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    const periods = [700.0, 900.0, 1100.0];
    return ExcludeSemantics(
      child: Container(
        width: _badgeSize,
        height: _badgeSize,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: colors.accent,
          borderRadius: BorderRadius.circular(4),
        ),
        child: AnimatedBuilder(
          animation: _bars,
          builder: (context, _) => Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (var i = 0; i < 3; i++) ...[
                if (i > 0) const SizedBox(width: 1),
                Container(
                  width: 2,
                  height: _height(periods[i]),
                  decoration: BoxDecoration(
                    color: colors.onAccent,
                    borderRadius: BorderRadius.circular(1),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 2–9 dp inside a 12 dp badge — the spec's 4–12 dp bars scaled to the
  /// badge's own inset box.
  double _height(double periodMs) {
    final phase = (_bars.value * 2100) / periodMs;
    final wave = (math.sin(phase * 2 * math.pi) + 1) / 2;
    return 2 + wave * 7;
  }
}

/// A newly added row growing into place (§5 "Adding").
class _InsertReveal extends StatefulWidget {
  const _InsertReveal({required this.child});

  final Widget child;

  @override
  State<_InsertReveal> createState() => _InsertRevealState();
}

class _InsertRevealState extends State<_InsertReveal>
    with SingleTickerProviderStateMixin {
  late final AnimationController _reveal = AnimationController(
    vsync: this,
    duration: JamDuration.base,
    value: 0,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _reveal.value = 1;
    } else if (!_reveal.isAnimating && _reveal.value == 0) {
      unawaited(_reveal.forward());
    }
  }

  @override
  void dispose() {
    _reveal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curved = CurvedAnimation(parent: _reveal, curve: JamCurve.base);
    return SizeTransition(
      sizeFactor: curved,
      child: FadeTransition(opacity: curved, child: widget.child),
    );
  }
}

/// Picks a source, picks files, and hands them to the controller.
///
/// Shared by the header action and the empty state so both report failures
/// the same way — once, as a summary, rather than one snackbar per bad file.
Future<void> jamAddToQueue(BuildContext context, JamEngine engine) async {
  // Same choice host setup offers. On Android most music lives in
  // MediaStore, which DocumentsUI will not show you — the in-room button
  // opening straight into the file picker made half the device unreachable
  // once the jam was running.
  final source = await chooseAddSource(context);
  if (source == null || !context.mounted) return;
  final paths = source == JamAddSource.library
      ? await pickLibraryTracks(context)
      : await pickAudioFiles(context);
  if (paths.isEmpty || !context.mounted) return;
  await JamSession.read(context).addFiles(paths.map(File.new));
}
