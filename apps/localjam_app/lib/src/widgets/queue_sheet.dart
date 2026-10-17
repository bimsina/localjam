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
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:localjam_client/localjam_client.dart';

import '../design/tokens.dart';
import '../design/typography.dart';
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
  static const String importing = 'Adding your music to the room';
  static const String hostRunsQueue = 'The host is running this queue';

  /// Why Add is grey while the host cannot be reached — the same rule as
  /// the transport's: a control that stops working says why.
  static const String hostAsleep =
      'The host’s phone is asleep. You can add music when it wakes.';
  static const String reconnecting =
      'Reconnecting to the host. You can add music again in a moment.';
  static const String retry = 'Try getting this track again';
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

  /// Rows swiped away whose removal the room has not confirmed yet.
  ///
  /// A swiped [Dismissible] has to leave the tree when its animation ends,
  /// but a guest's removal is only a request: the playlist broadcast that
  /// actually drops the row comes later — or never, if the host says no. So
  /// the row is held out of the list here until the broadcast lands, and
  /// put back if it has not after [_removalGrace].
  final Map<String, Timer> _removing = {};
  static const Duration _removalGrace = Duration(seconds: 5);

  JamEngine get _engine => widget.engine;

  void _hideRemoved(String mediaId) {
    _removing[mediaId]?.cancel();
    _removing[mediaId] = Timer(_removalGrace, () {
      // Still in the queue: the host refused (its `not_allowed` already
      // said so through the notice channel). The row comes back.
      _removing.remove(mediaId);
      if (mounted) setState(() {});
    });
    if (mounted) setState(() {});
  }

  /// Forgets hidden rows the playlist no longer carries — their removal
  /// landed.
  void _pruneRemoved(List<MediaItem> playlist) {
    if (_removing.isEmpty) return;
    final ids = {for (final item in playlist) item.mediaId};
    _removing.removeWhere((id, timer) {
      if (ids.contains(id)) return false;
      timer.cancel();
      return true;
    });
  }

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
    for (final timer in _removing.values) {
      timer.cancel();
    }
    final guest = _engine;
    if (guest is JamGuestEngine) {
      guest.prefetchStates.removeListener(_onPrefetch);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = JamSession.of(context);
    _pruneRemoved(_engine.playlist);
    final playlist = [
      for (final item in _engine.playlist)
        if (!_removing.containsKey(item.mediaId)) item,
    ];
    final peers = _engine.peers;
    final canAdd = _engine.can(JamCapability.addTracks);
    final canEdit = _engine.can(JamCapability.editQueue);
    final canControl = _engine.can(JamCapability.controlPlayback);
    final canSend = session.canSendCommands;
    final currentId = _engine.snapshot.mediaId;
    final playing = _engine.snapshot.status == PlaybackStatus.playing;
    final guest = _engine is JamGuestEngine ? _engine as JamGuestEngine : null;

    final ids = {for (final item in playlist) item.mediaId};
    final fresh = _drawnOnce ? ids.difference(_seen) : const <String>{};
    _seen = ids;
    _drawnOnce = true;

    final current = playlist
        .where((item) => item.mediaId == currentId)
        .firstOrNull;
    // NEXT UP is the order the room will play, not the order the queue is
    // stored in: once the room has wrapped (skipping and the end policy
    // both go round, §5.5) the tracks above the current one come AFTER the
    // ones below it — the 2026-10-17 run listed songs already heard first.
    final rest = jamUpNext(playlist, currentId);

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
            canRemove: _engine.canRemove(item),
            // Picking the track that is already on changes nothing (§5.2
            // `set_media`): the pinned row is not a button.
            onTap: canControl && !isCurrent
                ? () => unawaited(
                    session.act((e) => e.transportSetMedia(item.mediaId)),
                  )
                : null,
            onRemoved: () => _hideRemoved(item.mediaId),
            onRetry: guest == null
                ? null
                : () {
                    // False when there is nothing to retry any more — it
                    // landed, or is already on its way. Say so rather than
                    // leaving a tap that did nothing.
                    if (!guest.retryFetch(item.mediaId)) {
                      session.notify(kJamIntentFailed);
                    }
                  },
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
        _UploadLine(engine: _engine, import: session.hostImport),
        if (!canAdd)
          const _QueueGateNote(QueueSheetStrings.hostRunsQueue)
        else if (!canSend)
          _QueueGateNote(
            session.hostAway
                ? QueueSheetStrings.hostAsleep
                : QueueSheetStrings.reconnecting,
          ),
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
                  onAction: canAdd && canSend
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
                              session.act(
                                (e) => e.queueMove(move.mediaId, move.toIndex),
                              ),
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

/// What plays after [currentId], in the order the room will play it: the
/// rest of the queue below the current track, then from the top round to it
/// — `next` and the advance end policy both wrap (§5.5). With nothing
/// current (or a current track no longer queued), the queue as it stands.
List<MediaItem> jamUpNext(List<MediaItem> playlist, String? currentId) {
  final at = currentId == null
      ? -1
      : playlist.indexWhere((item) => item.mediaId == currentId);
  if (at < 0) return List.of(playlist);
  return [...playlist.sublist(at + 1), ...playlist.sublist(0, at)];
}

/// Where a queue row dropped at [newIndex] of the NEXT UP list lands in the
/// *whole* playlist.
///
/// The sheet shows the current track pinned, then the rest in play order
/// ([jamUpNext]), but the engine moves items within one stored list, so the
/// drop has to be replayed against it before it can be sent. The moved
/// track goes straight after whatever now plays before it — the row above
/// it, or the current track when it was dropped at the top — which keeps
/// the play order the person sees, wrap included. (NOW PLAYING is never a
/// drop target: nothing can be put in front of the track that is on.)
/// Pure, and tested directly.
({String mediaId, int toIndex})? queueReorderTarget({
  required List<MediaItem> playlist,
  required String? currentId,
  required int oldIndex,
  required int newIndex,
}) {
  final upNext = [
    for (final item in jamUpNext(playlist, currentId)) item.mediaId,
  ];
  if (oldIndex < 0 || oldIndex >= upNext.length) return null;
  // `onReorderItem` (unlike the deprecated `onReorder`) hands back an index
  // already adjusted for the removed row.
  final target = newIndex.clamp(0, upNext.length - 1);
  if (target == oldIndex) return null;

  final movedId = upNext[oldIndex];
  final reordered = List<String>.of(upNext)
    ..removeAt(oldIndex)
    ..insert(target, movedId);
  final playsAfter = target == 0 ? currentId : reordered[target - 1];
  final withoutMoved = [
    for (final item in playlist)
      if (item.mediaId != movedId) item.mediaId,
  ];
  // -1 + 1: nothing before it (no current track) is the top of the queue.
  final toIndex = withoutMoved.indexOf(playsAfter ?? '') + 1;
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
    // Grey, with the panel's gate note saying why, while a guest cannot reach
    // the host — every file would fail with the same "not connected".
    final canAdd =
        widget.engine.can(JamCapability.addTracks) &&
        JamSession.of(context).canSendCommands;
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
  const _QueueGateNote(this.message);

  final String message;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      JamSpace.page,
      JamSpace.sm,
      JamSpace.page,
      0,
    ),
    child: Text(message, style: context.jamFootnote),
  );
}

/// Music on its way into the room, as a 3 dp accent line under the header:
/// a guest's upload, or the host's background import of the files the room
/// started with.
class _UploadLine extends StatelessWidget {
  const _UploadLine({required this.engine, this.import});

  final JamEngine engine;

  /// The host's import, while there is one.
  final JamImport? import;

  @override
  Widget build(BuildContext context) {
    final guest = engine;
    final job = import;
    if (guest is JamGuestEngine) {
      return ValueListenableBuilder<double?>(
        valueListenable: guest.uploadProgress,
        builder: (context, progress, _) => progress == null
            ? const SizedBox.shrink()
            : _ProgressLine(
                value: progress,
                label: QueueSheetStrings.uploading,
              ),
      );
    }
    if (job == null) return const SizedBox.shrink();
    return ValueListenableBuilder<JamImportProgress>(
      valueListenable: job.progress,
      builder: (context, progress, _) => progress.isDone || progress.total == 0
          ? const SizedBox.shrink()
          : _ProgressLine(
              value: progress.completed / progress.total,
              label: QueueSheetStrings.importing,
            ),
    );
  }
}

class _ProgressLine extends StatelessWidget {
  const _ProgressLine({required this.value, required this.label});

  final double value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    return Semantics(
      liveRegion: true,
      label: label,
      child: LinearProgressIndicator(
        value: value,
        minHeight: 3,
        color: colors.accent,
        backgroundColor: colors.surfaceMuted,
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
    required this.onRemoved,
    this.onRetry,
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

  /// The swipe finished and the row has to leave the list now.
  final VoidCallback onRemoved;

  /// Fetches a track this guest gave up on again (failed, no retry
  /// scheduled). Null on a host, which has every file already.
  final VoidCallback? onRetry;

  /// Position in the reorderable list, or null when the queue is read-only.
  final int? dragIndex;

  /// Holds the drag grip's width open without drawing one — the pinned row.
  final bool reserveHandle;

  /// Removes the track and says so — with a way back, since a swipe leaves
  /// nothing behind and a mis-swipe on someone else's phone is a track the
  /// room just lost. Answers whether the removal went through; a refusal
  /// (a guest whose host is asleep, a track that already left) is said out
  /// loud by [JamSessionController.act] and the row stays.
  Future<bool> _removeAndSay(BuildContext context) async {
    final title = jamDisplayTitle(item);
    final mediaId = item.mediaId;
    // Where it was, so Undo puts it back where it was rather than at the end.
    final index = engine.playlist.indexWhere((i) => i.mediaId == mediaId);
    final session = JamSession.read(context);
    // Only the host can put a file back, and only while the bytes are still
    // on this device: offering an Undo that cannot run is worse than none.
    final undoable = index >= 0 && session.canReinsert(mediaId);
    final removed = await session.act((e) => e.queueRemove(mediaId));
    if (!removed) return false;
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
    return true;
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
    if (chose == true && context.mounted) unawaited(_removeAndSay(context));
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    // Everyone's contribution is credited, yours included: a solo-hosted room
    // with no faces at all was the review's "where are the people?".
    final addedBy = jamAddedByLabel(engine, item);
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
          onRetry: onRetry,
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
        // Decided before the row goes: a removal the room refused springs
        // back instead of vanishing from this phone only.
        confirmDismiss: (_) => _removeAndSay(context),
        onDismissed: (_) => onRemoved(),
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
    this.onRetry,
  });

  final MediaItem item;
  final JamPrefetchState? prefetch;
  final bool isGuest;

  /// Offered on a fetch that gave up (failed, no retry scheduled).
  final VoidCallback? onRetry;

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
          final retry = onRetry;
          // While a retry is scheduled the glyph is only a status; once the
          // engine has given up it becomes the way to ask again — a red mark
          // with nothing to do about it was a dead end.
          if (prefetch!.willRetry || retry == null) {
            return Icon(
              Icons.error_outline_rounded,
              size: 18,
              color: colors.danger,
            );
          }
          return IconButton(
            icon: const Icon(Icons.refresh_rounded, size: 20),
            color: colors.danger,
            tooltip: QueueSheetStrings.retry,
            visualDensity: VisualDensity.compact,
            onPressed: retry,
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
