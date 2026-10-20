/// The queue — the room's social object — as the list that opens **in place**
/// on Now Playing (DESIGN_SPEC v3 §6.3 D5, §6.6), and in the docked panel on
/// wide windows (D7).
///
/// One implementation for host and guest, capability-gated: "Add Songs"
/// only with `addTracks`, drag handles only with `editQueue`, swipe-to-remove
/// and the long-press menu (Play Next, Remove) per what the room allows.
/// Every row says who put it on — "Added by Mia · 3:42" — because that is
/// most of what makes a shared queue feel like a room rather than a
/// playlist.
///
/// It lives on the immersive backdrop, so it paints in the fixed
/// [JamNowPlayingColors] whatever the app theme.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:localjam_client/localjam_client.dart';

import '../design/tokens.dart';
import '../design/typography.dart';
import '../state/session_controller.dart';
import '../util/format.dart';
import '../util/media_picking.dart';
import 'list.dart' show JamAddSongsRow;
import 'menu.dart';
import 'pressable.dart';
import 'progress.dart';
import 'swipe_action.dart';
import 'track_row.dart';

/// Everything the queue says out loud.
abstract final class QueueSheetStrings {
  static const String title = 'Up Next';
  static const String addSongs = 'Add Songs';
  static const String empty = 'Nothing up next';
  static const String playNext = 'Play Next';
  static const String remove = 'Remove';
  static const String reorder = 'Reorder';

  /// Confirmation after a removal, so it is never silent.
  static String removed(String title) => 'Removed “$title”';
  static const String undo = 'Undo';
  static const String uploading = 'Sending your song to the jam';
  static const String importing = 'Adding your music to the jam';
  static const String hostRunsQueue = 'Only the host can add songs.';

  /// Why "Add Songs" is grey while the host cannot be reached — the same
  /// rule as the transport's: a control that stops working says why.
  static const String hostAsleep =
      'The host’s phone is asleep. You can add songs when it wakes.';
  static const String reconnecting =
      'Reconnecting to the host. You can add songs again in a moment.';

  static const String retry = 'Try getting this song again';
  static const String fetchFailed = 'Couldn’t get this song';

  /// "1 song" / "12 songs".
  static String count(int n) => '$n ${n == 1 ? 'song' : 'songs'}';
}

/// The queue's rows and header, as a column that fills what it is given.
///
/// Used in place on Now Playing (with its own "Up Next" header) and in the
/// wide docked panel (where the panel's switcher is the header).
class QueuePanel extends StatefulWidget {
  const QueuePanel({
    super.key,
    required this.engine,
    this.scrollController,
    this.showHeader = true,
    this.horizontalPadding = JamSpace.page,
    this.bottomPadding = JamSpace.lg,
  });

  final JamEngine engine;

  /// An external scroll controller, if the host layout needs one.
  final ScrollController? scrollController;

  /// Whether to draw the "Up Next" header with its count.
  final bool showHeader;

  /// The side margin rows and the header share — the artwork's margin on
  /// Now Playing, so the list lines up with the cover it replaced.
  final double horizontalPadding;

  /// Air under the last row.
  final double bottomPadding;

  @override
  State<QueuePanel> createState() => _QueuePanelState();
}

class _QueuePanelState extends State<QueuePanel> {
  final List<StreamSubscription<Object?>> _subs = [];
  final Map<String, Future<Uint8List?>> _covers = {};

  Future<Uint8List?>? _coverFor(MediaItem item) {
    final id = item.artworkId;
    if (id == null) return null;
    return _covers.putIfAbsent(id, () {
      late final Future<Uint8List?> request;
      request = _engine.artworkFor(item).then((bytes) {
        // A temporary miss must be retryable after a reconnect or queue update.
        if (bytes == null && identical(_covers[id], request)) {
          _covers.remove(id);
        }
        return bytes;
      });
      return request;
    });
  }

  /// mediaIds the list has already drawn, so only genuinely new rows play the
  /// insert animation.
  Set<String> _seen = const {};
  bool _drawnOnce = false;
  bool _adding = false;

  /// Rows swiped away whose removal the room has not confirmed yet.
  ///
  /// A swiped row has to leave the tree once it has collapsed,
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

  @override
  void initState() {
    super.initState();
    _bind();
  }

  @override
  void didUpdateWidget(QueuePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.engine, widget.engine)) {
      _covers.clear();
      _unbind(oldWidget.engine);
      _bind();
    }
  }

  void _bind() {
    void refresh(Object? _) {
      if (mounted) setState(() {});
    }

    _subs
      ..add(_engine.playlistUpdates.listen(refresh))
      ..add(_engine.states.listen(refresh))
      ..add(_engine.permissionUpdates.listen(refresh));
    final guest = _engine;
    if (guest is JamGuestEngine) guest.prefetchStates.addListener(_onPrefetch);
  }

  void _unbind(JamEngine engine) {
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    _subs.clear();
    if (engine is JamGuestEngine) {
      engine.prefetchStates.removeListener(_onPrefetch);
    }
  }

  void _onPrefetch() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _unbind(_engine);
    for (final timer in _removing.values) {
      timer.cancel();
    }
    super.dispose();
  }

  Future<void> _add() async {
    if (_adding) return;
    setState(() => _adding = true);
    try {
      await jamAddToQueue(context, _engine);
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = JamSession.of(context);
    _pruneRemoved(_engine.playlist);
    final artworkIds = {for (final item in _engine.playlist) item.artworkId};
    _covers.removeWhere((id, _) => !artworkIds.contains(id));
    final playlist = [
      for (final item in _engine.playlist)
        if (!_removing.containsKey(item.mediaId)) item,
    ];
    final canAdd = _engine.can(JamCapability.addTracks);
    final canEdit = _engine.can(JamCapability.editQueue);
    final canControl = _engine.can(JamCapability.controlPlayback);
    final canSend = session.canSendCommands;
    final currentId = _engine.snapshot.mediaId;
    final guest = _engine is JamGuestEngine ? _engine as JamGuestEngine : null;
    final pad = widget.horizontalPadding;

    // Up Next is the order the room will play, not the order the queue is
    // stored in: once the room has wrapped (skipping and the end policy
    // both go round, §5.5) the tracks above the current one come AFTER the
    // ones below it.
    final upNext = jamUpNext(playlist, currentId);

    final ids = {for (final item in upNext) item.mediaId};
    final fresh = _drawnOnce ? ids.difference(_seen) : const <String>{};
    _seen = ids;
    _drawnOnce = true;

    Widget row(MediaItem item, {int? dragIndex}) => KeyedSubtree(
      // The key rides on the outermost widget: `SliverReorderableList`
      // looks for it there, and the insert animation wraps the row.
      key: ValueKey(item.mediaId),
      child: _QueueRow(
        artwork: _coverFor(item),
        engine: _engine,
        item: item,
        horizontalPadding: pad,
        animateIn: fresh.contains(item.mediaId),
        dragIndex: dragIndex,
        canRemove: _engine.canRemove(item),
        // Play Next is a move, which needs `editQueue` — and a track that
        // is already next has nowhere to go.
        onPlayNext: canEdit && upNext.first.mediaId != item.mediaId
            ? () {
                final move = queueReorderTarget(
                  playlist: playlist,
                  currentId: currentId,
                  oldIndex: upNext.indexOf(item),
                  newIndex: 0,
                );
                if (move != null) {
                  unawaited(
                    session.act((e) => e.queueMove(move.mediaId, move.toIndex)),
                  );
                }
              }
            : null,
        onTap: canControl
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
                if (item.artworkId != null) _covers.remove(item.artworkId);
                if (!guest.retryFetch(item.mediaId)) {
                  session.notify(kJamIntentFailed, tone: JamNoticeTone.warning);
                }
              },
      ),
    );

    final String? gate = !canAdd
        ? QueueSheetStrings.hostRunsQueue
        : !canSend
        ? (session.hostAway
              ? QueueSheetStrings.hostAsleep
              : QueueSheetStrings.reconnecting)
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.showHeader)
          Padding(
            padding: EdgeInsets.fromLTRB(pad, 0, pad, JamSpace.xs),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text(
                      QueueSheetStrings.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.jamHeadline.copyWith(
                        color: JamNowPlayingColors.text,
                      ),
                    ),
                  ),
                ),
                if (upNext.isNotEmpty)
                  Text(
                    QueueSheetStrings.count(upNext.length),
                    style: jamTabular(
                      context.jamFootnote,
                    ).copyWith(color: JamNowPlayingColors.secondary),
                  ),
              ],
            ),
          ),
        // Pinned under the header rather than dropped into the flow, so a
        // running upload never shifts the list under a finger.
        Padding(
          padding: EdgeInsets.symmetric(horizontal: pad),
          child: _UploadLine(engine: _engine, import: session.hostImport),
        ),
        if (gate != null)
          Padding(
            padding: EdgeInsets.fromLTRB(pad, 0, pad, JamSpace.xs),
            child: Text(
              gate,
              style: context.jamFootnote.copyWith(
                color: JamNowPlayingColors.secondary,
              ),
            ),
          ),
        Expanded(
          child: ShaderMask(
            // The list fades out under its top and bottom edges rather than
            // being cut by them — the scrubber sits right below. An alpha
            // mask (only the opacity is used), not a painted gradient.
            shaderCallback: (rect) => const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                JamFixedColors.clear,
                JamFixedColors.white,
                JamFixedColors.white,
                JamFixedColors.clear,
              ],
              // Long enough at the bottom that a row cut by the edge
              // dissolves rather than looking sliced.
              stops: [0, 0.03, 0.85, 1],
            ).createShader(rect),
            blendMode: BlendMode.dstIn,
            child: CustomScrollView(
              controller: widget.scrollController,
              slivers: [
                const SliverToBoxAdapter(child: SizedBox(height: JamSpace.xs)),
                if (canAdd)
                  SliverToBoxAdapter(
                    child: JamAddSongsRow(
                      title: QueueSheetStrings.addSongs,
                      onBackdrop: true,
                      horizontalPadding: pad,
                      busy: _adding,
                      separator: false,
                      onTap: canSend ? () => unawaited(_add()) : null,
                    ),
                  ),
                // Empty: with Add Songs above, that row is the whole story —
                // no second sentence on another axis. Without it, one centred
                // line is all there is.
                if (upNext.isEmpty && !canAdd)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                        pad,
                        JamSpace.xxl,
                        pad,
                        JamSpace.xxl,
                      ),
                      child: Text(
                        QueueSheetStrings.empty,
                        textAlign: TextAlign.center,
                        style: context.jamSubheadline.copyWith(
                          color: JamNowPlayingColors.secondary,
                        ),
                      ),
                    ),
                  )
                else if (upNext.isEmpty)
                  const SliverToBoxAdapter(child: SizedBox.shrink())
                else if (canEdit)
                  SliverReorderableList(
                    itemCount: upNext.length,
                    onReorderStart: (_) => JamHaptics.reorder(),
                    onReorderEnd: (_) => JamHaptics.reorder(),
                    proxyDecorator: (child, index, animation) => DecoratedBox(
                      decoration: BoxDecoration(
                        color: JamNowPlayingColors.placeholderGround,
                        borderRadius: BorderRadius.circular(JamRadius.md),
                      ),
                      child: child,
                    ),
                    onReorderItem: (oldIndex, newIndex) {
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
                    itemBuilder: (context, index) =>
                        row(upNext[index], dragIndex: index),
                  )
                else
                  SliverList.builder(
                    itemCount: upNext.length,
                    itemBuilder: (context, index) => row(upNext[index]),
                  ),
                SliverToBoxAdapter(
                  child: SizedBox(height: widget.bottomPadding),
                ),
              ],
            ),
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

/// Where a row dropped at [newIndex] of the Up Next list lands in the
/// *whole* playlist.
///
/// The list shows the rest in play order ([jamUpNext]), but the engine moves
/// items within one stored list, so the drop has to be replayed against it
/// before it can be sent. The moved track goes straight after whatever now
/// plays before it — the row above it, or the current track when it was
/// dropped at the top (which is also what Play Next does) — keeping the play
/// order the person sees, wrap included. Pure, and tested directly.
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

/// Music on its way into the room, as a thin line under the header: a
/// guest's upload, or the host's background import of the files the room
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
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    label: label,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: JamSpace.sm),
      child: JamProgressBar(
        value: value,
        height: 3,
        color: JamNowPlayingColors.fill,
        trackColor: JamNowPlayingColors.track,
      ),
    ),
  );
}

/// One queue row: the shared [JamTrackRow] in white, plus what only a queue
/// needs — the drag grip, the swipe, the long-press menu, the retry.
class _QueueRow extends StatelessWidget {
  const _QueueRow({
    required this.engine,
    required this.item,
    required this.artwork,
    required this.horizontalPadding,
    required this.animateIn,
    required this.canRemove,
    required this.onTap,
    required this.onRemoved,
    this.onPlayNext,
    this.onRetry,
    this.dragIndex,
  });

  final JamEngine engine;
  final MediaItem item;
  final Future<Uint8List?>? artwork;
  final double horizontalPadding;
  final bool animateIn;
  final bool canRemove;
  final VoidCallback? onTap;
  final VoidCallback? onPlayNext;

  /// The swipe finished and the row has to leave the list now.
  final VoidCallback onRemoved;

  /// Fetches a track this guest gave up on again (failed, no retry
  /// scheduled). Null on a host, which has every file already.
  final VoidCallback? onRetry;

  /// Position in the reorderable list, or null when the queue is read-only.
  final int? dragIndex;

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
    // Through the controller's single notice channel: by the time a swipe
    // settles, this row's context is on its way out.
    session.notify(
      QueueSheetStrings.removed(title),
      actionLabel: undoable ? QueueSheetStrings.undo : null,
      onAction: undoable
          ? () => unawaited(session.reinsertItem(mediaId, index))
          : null,
    );
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final addedBy = jamAddedByLabel(engine, item);
    final guest = engine is JamGuestEngine ? engine as JamGuestEngine : null;
    final prefetch = guest?.prefetchStates.value[item.mediaId];
    final fetching = prefetch?.phase == JamPrefetchPhase.fetching;
    final failed = prefetch?.phase == JamPrefetchPhase.failed;
    final index = dragIndex;
    final retry = onRetry;
    final showRetry = failed && !(prefetch?.willRetry ?? true) && retry != null;

    final menu = <JamMenuItem>[
      if (onPlayNext != null)
        JamMenuItem(
          title: QueueSheetStrings.playNext,
          icon: CupertinoIcons.text_insert,
          onPressed: onPlayNext,
        ),
      if (canRemove)
        JamMenuItem(
          title: QueueSheetStrings.remove,
          icon: CupertinoIcons.trash,
          destructive: true,
          onPressed: () => unawaited(_removeAndSay(context)),
        ),
    ];

    // The row's artwork, fetched once and shared by the row and its lifted
    // copy (the long-press preview).

    /// The row. [preview] is the copy that lifts out of the list under the
    /// long-press menu: the same content at the same place, with nothing to
    /// tap and no grip, inside a platter [previewPadding] in from its edges.
    Widget track({
      VoidCallback? onLongPress,
      bool preview = false,
      bool grip = true,
      EdgeInsets? previewPadding,
    }) => FutureBuilder<Uint8List?>(
      future: artwork,
      builder: (context, snapshot) => JamTrackRow(
        onBackdrop: true,
        title: jamDisplayTitle(item),
        // The artist is the song's identity; the album is catalogue
        // detail nobody acts on here (it stands in only when there is no
        // artist).
        byline: _queueByline(item),
        artworkBytes: snapshot.data,
        artworkId: item.artworkId,
        artworkLoading:
            item.artworkId != null &&
            snapshot.connectionState != ConnectionState.done,
        addedByName: addedBy,
        addedByYou: addedBy == 'You',
        duration: item.durationUs == null
            ? null
            : Duration(microseconds: item.durationUs!),
        prefetchProgress: fetching ? (prefetch?.progress ?? 0) : null,
        hasError: failed,
        errorText: QueueSheetStrings.fetchFailed,
        showDragHandle: index != null && !preview && grip,
        onTap: preview ? null : onTap,
        onLongPress: onLongPress,
        trailing: showRetry && !preview ? _RetryButton(onPressed: retry) : null,
        contentPadding:
            previewPadding ??
            EdgeInsets.only(
              left: horizontalPadding,
              // The grip sits in its own 44 box at the edge; without one the
              // row keeps the side margin.
              right: index != null
                  ? math.max(0, horizontalPadding - 12)
                  : horizontalPadding,
            ),
      ),
    );

    // The long-press menu is a context menu, not a pull-down: the pressed
    // row lifts out of the list onto a platter, everything else dims, and
    // the menu attaches to the lifted row — so it can only ever be read as
    // acting on that row, and never covers another row's title.
    final platterInset = math.max(0.0, horizontalPadding - _kPlatterPadding);
    // [grip]: false while the row is swiped open — a reorder grip does not
    // belong beside an open Remove (as in Music).
    Widget assemble({required bool grip}) {
      Widget row = menu.isEmpty
          ? track(grip: grip)
          : Builder(
              builder: (rowContext) => track(
                grip: grip,
                onLongPress: () => unawaited(
                  _showRowMenu(
                    rowContext,
                    items: menu,
                    inset: platterInset,
                    preview: track(
                      preview: true,
                      previewPadding: const EdgeInsets.symmetric(
                        horizontal: _kPlatterPadding,
                      ),
                    ),
                  ),
                ),
              ),
            );

      if (index == null) return row;
      // The Stack stays either way, so the row's state survives the grip
      // coming and going.
      return Stack(
        children: [
          row,
          if (grip)
            Positioned(
              top: 0,
              bottom: 0,
              right: math.max(0, horizontalPadding - 12),
              width: JamMetrics.hitTarget,
              // ColoredBox, not SizedBox: `ReorderableDragStartListener` wraps
              // its child in a `Listener` that defers hit testing, and an empty
              // SizedBox never claims the pointer.
              child: Semantics(
                label: QueueSheetStrings.reorder,
                child: ReorderableDragStartListener(
                  index: index,
                  child: const ColoredBox(color: JamFixedColors.clear),
                ),
              ),
            ),
        ],
      );
    }

    // Outside the grip, so the uncovered button is what a tap at the edge
    // reaches.
    final row = canRemove
        ? _SwipeToRemove(
            key: ValueKey<String>('queue-dismiss-${item.mediaId}'),
            // Decided before the row goes: a removal the jam refused springs
            // back instead of vanishing from this phone only.
            onAction: () => _removeAndSay(context),
            onRemoved: onRemoved,
            builder: (open) => assemble(grip: !open),
          )
        : assemble(grip: true);

    return animateIn ? _InsertReveal(child: row) : row;
  }
}

/// A queue row's second line: the artist, or the album when the file
/// names no artist.
String? _queueByline(MediaItem item) {
  final artist = item.artist?.trim();
  if (artist != null && artist.isNotEmpty) return artist;
  final album = item.album?.trim();
  return album == null || album.isEmpty ? null : album;
}

/// Swipe-to-remove that rebuilds its row with whether it is open, so the
/// row can drop what does not belong beside an open action.
class _SwipeToRemove extends StatefulWidget {
  const _SwipeToRemove({
    super.key,
    required this.onAction,
    required this.onRemoved,
    required this.builder,
  });

  final Future<bool> Function() onAction;
  final VoidCallback onRemoved;
  final Widget Function(bool open) builder;

  @override
  State<_SwipeToRemove> createState() => _SwipeToRemoveState();
}

class _SwipeToRemoveState extends State<_SwipeToRemove> {
  bool _open = false;

  @override
  Widget build(BuildContext context) => JamSwipeAction(
    label: QueueSheetStrings.remove,
    onAction: widget.onAction,
    onRemoved: widget.onRemoved,
    onOpenChanged: (open) {
      if (mounted && open != _open) setState(() => _open = open);
    },
    child: widget.builder(_open),
  );
}

/// "Try again" on a row whose fetch the engine gave up on.
class _RetryButton extends StatelessWidget {
  const _RetryButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    button: true,
    label: QueueSheetStrings.retry,
    onTap: onPressed,
    excludeSemantics: true,
    child: JamPressable(
      onTap: onPressed,
      child: const SizedBox.square(
        dimension: JamMetrics.hitTarget,
        child: Icon(
          CupertinoIcons.arrow_clockwise,
          size: 20,
          color: JamNowPlayingColors.text,
        ),
      ),
    ),
  );
}

/// A newly added row growing into place.
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
    final curved = CurvedAnimation(parent: _reveal, curve: JamCurve.standard);
    return SizeTransition(
      sizeFactor: curved,
      child: FadeTransition(opacity: curved, child: widget.child),
    );
  }
}

/// How far the lifted row's platter reaches past its content.
const double _kPlatterPadding = 12;

/// How much the lifted row grows.
const double _kLiftScale = 1.03;

/// The context menu's width (iOS's).
const double _kRowMenuWidth = 250;

/// Between the lifted row and its menu, and from the window's edges.
const double _kRowMenuGap = 8;

/// Strings the row menu says to a screen reader.
abstract final class QueueRowMenuStrings {
  static const String dismiss = 'Dismiss';
  static const String actions = 'Song actions';
}

/// Opens [items] as a context menu on the queue row at [rowContext]: the
/// row lifts onto a platter in place, the rest of the screen blurs and dims,
/// and the menu attaches under it (or over it, near the bottom). The chosen
/// action runs after the menu has closed.
Future<void> _showRowMenu(
  BuildContext rowContext, {
  required List<JamMenuItem> items,
  required Widget preview,
  required double inset,
}) async {
  final navigator = Navigator.of(rowContext, rootNavigator: true);
  final box = rowContext.findRenderObject();
  final overlay = navigator.overlay?.context.findRenderObject();
  if (box is! RenderBox || overlay is! RenderBox || !box.hasSize) return;
  final rect = MatrixUtils.transformRect(
    box.getTransformTo(overlay),
    Offset.zero & box.size,
  );
  unawaited(HapticFeedback.mediumImpact());
  final action = await navigator.push<VoidCallback?>(
    _RowMenuRoute(
      rect: rect,
      inset: inset,
      preview: preview,
      items: items,
      // The queue sits on Now Playing's dark subtree; the menu, drawn in the
      // root overlay, keeps its themes.
      themes: InheritedTheme.capture(from: rowContext, to: navigator.context),
    ),
  );
  action?.call();
}

class _RowMenuRoute extends PopupRoute<VoidCallback?> {
  _RowMenuRoute({
    required this.rect,
    required this.inset,
    required this.preview,
    required this.items,
    required this.themes,
  });

  /// The pressed row, in the overlay's coordinates.
  final Rect rect;
  final double inset;
  final Widget preview;
  final List<JamMenuItem> items;
  final CapturedThemes themes;

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => QueueRowMenuStrings.dismiss;

  @override
  Duration get transitionDuration => JamDuration.fast;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => themes.wrap(_RowMenuPage(route: this, animation: animation));
}

class _RowMenuPage extends StatelessWidget {
  const _RowMenuPage({required this.route, required this.animation});

  final _RowMenuRoute route;
  final Animation<double> animation;

  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final padding = MediaQuery.paddingOf(context);
    void dismiss() => Navigator.of(context).pop();

    // The app's one menu surface; the choice closes the menu first and runs
    // after (see [_showRowMenu]).
    final menu = JamMenuPanel(
      groups: [route.items],
      semanticLabel: QueueRowMenuStrings.actions,
      onSelected: (item) => Navigator.of(context).pop(item.onPressed),
    );

    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        final t = reduced
            ? (animation.value > 0 ? 1.0 : 0.0)
            : JamCurve.standard.transform(animation.value);
        return Stack(
          fit: StackFit.expand,
          children: [
            // Everything but the row, blurred and dimmed; a tap anywhere on
            // it closes the menu.
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: dismiss,
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 12 * t, sigmaY: 12 * t),
                child: ColoredBox(
                  color: JamNowPlayingColors.contextScrim.withValues(
                    alpha: JamNowPlayingColors.contextScrim.a * t,
                  ),
                ),
              ),
            ),
            CustomMultiChildLayout(
              delegate: _RowMenuLayout(
                rect: route.rect,
                inset: route.inset,
                padding: padding,
                t: t,
              ),
              children: [
                LayoutId(
                  id: _RowMenuSlot.preview,
                  child: IgnorePointer(
                    child: Transform.scale(
                      scale: 1 + (_kLiftScale - 1) * t,
                      // The menu's ground and corner, so the two read as one
                      // object.
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: JamNowPlayingColors.liftedRow,
                          borderRadius: BorderRadius.circular(JamRadius.menu),
                        ),
                        child: route.preview,
                      ),
                    ),
                  ),
                ),
                LayoutId(
                  id: _RowMenuSlot.menu,
                  child: Opacity(
                    opacity: t,
                    child: Transform.scale(scale: 0.9 + 0.1 * t, child: menu),
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

enum _RowMenuSlot { preview, menu }

/// Puts the lifted row where it was and the menu against it: below when it
/// fits, else above, else the row slides up just enough for the menu to fit
/// under it.
class _RowMenuLayout extends MultiChildLayoutDelegate {
  _RowMenuLayout({
    required this.rect,
    required this.inset,
    required this.padding,
    required this.t,
  });

  final Rect rect;
  final double inset;
  final EdgeInsets padding;
  final double t;

  @override
  void performLayout(Size size) {
    final row = Rect.fromLTRB(
      rect.left + inset,
      rect.top,
      math.max(rect.left + inset, rect.right - inset),
      rect.bottom,
    );
    final width = math.min(_kRowMenuWidth, size.width - JamSpace.page * 2);
    final menu = layoutChild(
      _RowMenuSlot.menu,
      BoxConstraints(
        minWidth: math.max(0, width),
        maxWidth: math.max(0, width),
        maxHeight: math.max(0, size.height - padding.vertical),
      ),
    );
    final top = padding.top + _kRowMenuGap;
    final bottom = size.height - padding.bottom - _kRowMenuGap;

    var rowTop = row.top;
    double menuTop;
    if (row.bottom + _kRowMenuGap + menu.height <= bottom) {
      menuTop = row.bottom + _kRowMenuGap;
    } else if (row.top - _kRowMenuGap - menu.height >= top) {
      menuTop = row.top - _kRowMenuGap - menu.height;
    } else {
      rowTop = math.max(top, bottom - menu.height - _kRowMenuGap - row.height);
      menuTop = rowTop + row.height + _kRowMenuGap;
    }
    // The row eases to where it has to be, from where it was pressed.
    final shownRowTop = row.top + (rowTop - row.top) * t;
    final shift = shownRowTop - rowTop;

    layoutChild(_RowMenuSlot.preview, BoxConstraints.tight(row.size));
    positionChild(_RowMenuSlot.preview, Offset(row.left, shownRowTop));
    // The menu shares the lifted platter's leading edge — where the platter
    // is once it has grown about its centre.
    final platterLeft = row.left - row.width * (_kLiftScale - 1) / 2 * t;
    final left = platterLeft
        .clamp(
          padding.left + JamSpace.sm,
          math.max(
            padding.left + JamSpace.sm,
            size.width - padding.right - width - JamSpace.sm,
          ),
        )
        .toDouble();
    positionChild(_RowMenuSlot.menu, Offset(left, menuTop + shift));
  }

  @override
  bool shouldRelayout(_RowMenuLayout old) =>
      old.rect != rect ||
      old.inset != inset ||
      old.padding != padding ||
      old.t != t;
}

/// Picks a source, picks files, and hands them to the controller.
///
/// Shared by the queue's "Add Songs" row and the empty Now Playing, so both
/// report failures the same way — once, as a summary, rather than one notice
/// per bad file.
Future<void> jamAddToQueue(BuildContext context, JamEngine engine) async {
  // Same choice host setup offers. On Android most music lives in
  // MediaStore, which DocumentsUI will not show you.
  final source = await chooseAddSource(context);
  if (source == null || !context.mounted) return;
  final paths = source == JamAddSource.library
      ? await pickLibraryTracks(context)
      : await pickAudioFiles(context);
  if (paths.isEmpty || !context.mounted) return;
  await JamSession.read(context).addFiles(paths.map(File.new));
}
