/// The queue — the room's social object.
///
/// One implementation for host and guest, capability-gated. Every row carries
/// attribution, because "who put this on" is most of what makes a shared queue
/// feel like a room rather than a playlist. Adding works while live on both
/// sides now; the old UI hid the host's add button once the session started,
/// which on a long drive meant the host could never extend their own queue.
library;

import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:localjam_client/localjam_client.dart';

import '../design/tokens.dart';
import '../design/typography.dart';
import '../state/queue_actions.dart';
import '../util/format.dart';
import 'artwork.dart';

/// Opens the queue as a modal sheet. Compact layouts only — wide ones keep
/// [QueuePanel] open beside the player instead.
Future<void> showQueueSheet(BuildContext context, JamEngine engine) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.8,
      maxChildSize: 0.95,
      builder: (context, scrollController) =>
          QueuePanel(engine: engine, scrollController: scrollController),
    ),
  );
}

/// The queue itself, laid out as a column so it works as both a sheet body
/// and a docked desktop panel.
class QueuePanel extends StatefulWidget {
  const QueuePanel({super.key, required this.engine, this.scrollController});

  final JamEngine engine;

  /// Supplied by a DraggableScrollableSheet; null when docked.
  final ScrollController? scrollController;

  @override
  State<QueuePanel> createState() => _QueuePanelState();
}

class _QueuePanelState extends State<QueuePanel> {
  final List<StreamSubscription<Object?>> _subs = [];
  bool _adding = false;

  JamEngine get _engine => widget.engine;

  @override
  void initState() {
    super.initState();
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

  Future<void> _add() async {
    final typeGroup = XTypeGroup(
      label: 'Audio',
      extensions: supportedAudioExtensions,
      uniformTypeIdentifiers: const ['public.audio'],
    );
    try {
      final files = await openFiles(acceptedTypeGroups: [typeGroup]);
      if (files.isEmpty || !mounted) return;
      setState(() => _adding = true);
      for (final file in files) {
        try {
          await jamAddFile(_engine, File(file.path));
        } catch (e) {
          _report('Could not add ${file.name}: $e');
        }
      }
    } catch (e) {
      _report('Could not open the file picker: $e');
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  void _report(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final playlist = _engine.playlist;
    final peers = _engine.peers;
    final canAdd = _engine.can(JamCapability.addTracks);
    final canEdit = _engine.can(JamCapability.editQueue);
    final canControl = _engine.can(JamCapability.controlPlayback);
    final currentId = _engine.snapshot.mediaId;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            JamSpace.page,
            JamSpace.sm,
            JamSpace.md,
            JamSpace.md,
          ),
          child: Row(
            children: [
              Expanded(child: Text('Queue', style: context.jamTitle)),
              if (canAdd)
                _adding
                    ? const Padding(
                        padding: EdgeInsets.symmetric(horizontal: JamSpace.lg),
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : TextButton.icon(
                        onPressed: () => unawaited(_add()),
                        icon: const Icon(Icons.add_rounded, size: 20),
                        label: const Text('Add'),
                      ),
            ],
          ),
        ),
        if (_engine case final JamGuestEngine guest)
          ValueListenableBuilder<double?>(
            valueListenable: guest.uploadProgress,
            builder: (context, progress, _) => progress == null
                ? const SizedBox.shrink()
                : LinearProgressIndicator(value: progress),
          ),
        Expanded(
          child: playlist.isEmpty
              ? _EmptyQueue(canAdd: canAdd, onAdd: () => unawaited(_add()))
              : ReorderableListView.builder(
                  scrollController: widget.scrollController,
                  padding: const EdgeInsets.only(bottom: JamSpace.huge),
                  buildDefaultDragHandles: canEdit,
                  itemCount: playlist.length,
                  // onReorderItem (unlike the deprecated onReorder) hands
                  // back an index already adjusted for the removed row.
                  onReorderItem: (oldIndex, newIndex) => unawaited(
                    jamMoveItem(_engine, playlist[oldIndex].mediaId, newIndex),
                  ),
                  itemBuilder: (context, index) {
                    final item = playlist[index];
                    return _QueueRow(
                      key: ValueKey(item.mediaId),
                      engine: _engine,
                      item: item,
                      peers: peers,
                      isCurrent: item.mediaId == currentId,
                      canRemove: jamCanRemove(_engine, item),
                      onTap: canControl
                          ? () => unawaited(jamSetMedia(_engine, item.mediaId))
                          : null,
                      onRemove: () =>
                          unawaited(jamRemoveItem(_engine, item.mediaId)),
                    );
                  },
                ),
        ),
        if (playlist.isNotEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(
              JamSpace.page,
              JamSpace.sm,
              JamSpace.page,
              JamSpace.md,
            ),
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(color: colors.separator, width: 0.5),
              ),
            ),
            child: SafeArea(
              top: false,
              child: Text(
                '${playlist.length} '
                '${playlist.length == 1 ? 'track' : 'tracks'}',
                style: context.jamFootnote,
              ),
            ),
          ),
      ],
    );
  }
}

class _QueueRow extends StatelessWidget {
  const _QueueRow({
    super.key,
    required this.engine,
    required this.item,
    required this.peers,
    required this.isCurrent,
    required this.canRemove,
    required this.onTap,
    required this.onRemove,
  });

  final JamEngine engine;
  final MediaItem item;
  final List<PeerInfo> peers;
  final bool isCurrent;
  final bool canRemove;
  final VoidCallback? onTap;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    // Credit only somebody else's contribution — "added by You" on every one
    // of your own rows is noise, and in a solo-hosted room it is every row.
    final addedBy = engine.addedByLabel(item, peers);
    final byline = [
      ?artworkByline(item),
      if (addedBy != null && addedBy != 'You') 'added by $addedBy',
    ].join(' · ');

    return ListTile(
      onTap: onTap,
      leading: JamArtwork(engine: engine, item: item),
      title: Text(
        item.displayTitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: context.jamRowTitle.copyWith(
          color: isCurrent ? colors.accent : colors.textPrimary,
        ),
      ),
      subtitle: byline.isEmpty
          ? null
          : Text(byline, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ItemStatus(engine: engine, item: item),
          if (canRemove)
            IconButton(
              icon: const Icon(Icons.remove_circle_outline_rounded, size: 20),
              color: colors.textTertiary,
              onPressed: onRemove,
              tooltip: 'Remove',
            ),
        ],
      ),
    );
  }
}

/// Per-item state: a duration on the host, prefetch progress on a guest.
class _ItemStatus extends StatelessWidget {
  const _ItemStatus({required this.engine, required this.item});

  final JamEngine engine;
  final MediaItem item;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final guest = engine;
    if (guest is! JamGuestEngine) {
      final duration = item.durationUs;
      if (duration == null) return const SizedBox.shrink();
      return Text(
        formatPositionUs(duration),
        style: context.jamNumeric.copyWith(color: colors.textTertiary),
      );
    }

    final state = guest.prefetchStates.value[item.mediaId];
    return switch (state?.phase) {
      JamPrefetchPhase.ready || null => Text(
        item.durationUs == null ? '' : formatPositionUs(item.durationUs!),
        style: context.jamNumeric.copyWith(color: colors.textTertiary),
      ),
      JamPrefetchPhase.fetching => SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          value: state!.progress == 0 ? null : state.progress,
        ),
      ),
      JamPrefetchPhase.failed => Icon(
        Icons.error_outline_rounded,
        size: 18,
        color: colors.danger,
      ),
      JamPrefetchPhase.queued || JamPrefetchPhase.notQueued => Icon(
        Icons.schedule_rounded,
        size: 18,
        color: colors.textTertiary,
      ),
    };
  }
}

/// A drive drains the queue. Say so, and offer the fix.
class _EmptyQueue extends StatelessWidget {
  const _EmptyQueue({required this.canAdd, required this.onAdd});

  final bool canAdd;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(JamSpace.xxxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.queue_music_rounded,
              size: 40,
              color: colors.textTertiary,
            ),
            const SizedBox(height: JamSpace.lg),
            Text('Nothing queued', style: context.jamTitle),
            const SizedBox(height: JamSpace.sm),
            Text(
              canAdd
                  ? 'Add tracks from this device and everyone in the room '
                        'hears them.'
                  : 'The host has not queued anything yet.',
              textAlign: TextAlign.center,
              style: context.jamByline,
            ),
            if (canAdd) ...[
              const SizedBox(height: JamSpace.xl),
              FilledButton.icon(
                onPressed: onAdd,
                icon: const Icon(Icons.add_rounded, size: 20),
                label: const Text('Add music'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
