/// Past jams: every session leaves a record (queue + who added what + who was
/// there); tracks still on this device can seed a new room in one tap.
///
/// A record ages visibly. The mosaic tiles for tracks that have since left the
/// device fade to 35%, and the "Host it again" button says how much of the
/// queue is still there — so a six-month-old jam looks like one.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:localjam_client/localjam_client.dart';

import '../design/breakpoints.dart';
import '../design/tokens.dart';
import '../design/typography.dart';
import '../router.dart';
import '../util/format.dart';
import '../state/session_controller.dart';
import '../widgets/session_gate.dart';
import '../widgets/artwork.dart';
import '../widgets/avatar.dart';
import '../widgets/buttons.dart';
import '../widgets/dialogs.dart';
import '../widgets/empty_state.dart';
import '../widgets/track_row.dart';

/// Every user-facing string on this screen, in one place.
abstract final class HistoryStrings {
  static const String title = 'Past jams';
  static const String forget = 'Forget';
  static const String hostAgain = 'Host it again';
  static const String youHosted = 'You hosted';
  static const String youJoined = 'You joined';
  static const String noneLeft = 'No tracks left on this device';
  static String someLeft(int replayable, int total) =>
      '$replayable of $total still on this device';
  static String tracks(int n) => '$n ${n == 1 ? 'track' : 'tracks'}';
  static String more(int n) => '+ $n more';

  static const String forgetTitle = 'Forget this jam?';
  static String forgetBody(String name) =>
      'The record of $name goes away. The music on this device stays.';
  static const String forgetConfirm = 'Forget';

  static const String emptyTitle = 'No jams yet';
  static const String emptyBody =
      'Every room you host or join shows up here, queue and all.';

  static const String justNow = 'Just now';

  /// Announced for a mosaic, which is decorative on its own.
  static String cover(String name) => 'Cover art from $name';
}

/// How many track rows a card shows before it stops listing and counts.
const int _previewTracks = 3;

/// The loading shimmer's beat, and the fade inside it. The fade is shorter
/// than the beat on purpose: the still moment between them is what keeps the
/// frame scheduler from running forever while a page waits on disk.
const Duration _shimmerBeat = Duration(milliseconds: 800);
const Duration _shimmerFade = Duration(milliseconds: 600);

/// A relative "when", short enough for a footnote.
///
/// Lives here rather than in `util/format.dart` because it is presentation,
/// not formatting of engine data — and the recents rail on home is its only
/// other caller.
String jamRelativeTime(DateTime time) {
  final difference = DateTime.now().difference(time);
  if (difference.inMinutes < 1) return HistoryStrings.justNow;
  if (difference.inHours < 1) return '${difference.inMinutes} min ago';
  if (difference.inDays < 1) return '${difference.inHours} h ago';
  if (difference.inDays < 30) return '${difference.inDays} d ago';
  return '${time.year}-${time.month.toString().padLeft(2, '0')}-'
      '${time.day.toString().padLeft(2, '0')}';
}

/// A 2×2 grid of a past jam's covers.
///
/// History records carry no artwork bytes — a `JamHistoryTrack` is a
/// `MediaItem` and a path, and the cover lived in the engine that is long
/// gone — so every tile draws the brand placeholder. That is the point: the
/// grid is a *shape* that identifies a record, and tracks no longer on this
/// device drop to 35% so a record visibly ages.
class JamArtworkMosaic extends StatelessWidget {
  const JamArtworkMosaic({
    super.key,
    required this.tracks,
    required this.size,
    this.semanticLabel,
  });

  final List<JamHistoryTrack> tracks;

  /// Edge length of the whole grid.
  final double size;

  final String? semanticLabel;

  /// The gap between tiles.
  static const double _gap = 2;

  @override
  Widget build(BuildContext context) {
    final tile = (size - _gap) / 2;
    final cells = [
      for (var i = 0; i < 4; i++) i < tracks.length ? tracks[i] : null,
    ];

    final colors = context.jamColors;

    Widget cell(JamHistoryTrack? track) {
      // An empty cell is *absence*, not a faded track: a ghosted brand mark
      // in the fourth slot made a three-track jam look like a four-track one
      // whose cover failed to load.
      if (track == null) {
        return Container(
          width: tile,
          height: tile,
          decoration: BoxDecoration(
            color: colors.surfaceMuted,
            borderRadius: BorderRadius.circular(JamRadius.artwork(tile)),
          ),
        );
      }
      final art = JamArtworkTile(size: tile);
      return track.existsLocally ? art : Opacity(opacity: 0.35, child: art);
    }

    return Semantics(
      image: true,
      label: semanticLabel,
      child: ExcludeSemantics(
        child: SizedBox(
          width: size,
          height: size,
          child: Column(
            children: [
              Row(
                children: [
                  cell(cells[0]),
                  const SizedBox(width: _gap),
                  cell(cells[1]),
                ],
              ),
              const SizedBox(height: _gap),
              Row(
                children: [
                  cell(cells[2]),
                  const SizedBox(width: _gap),
                  cell(cells[3]),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key, this.loadRecords, this.forgetRecord});

  /// Where the records come from. Defaults to the on-disk store.
  ///
  /// The seam exists because a `testWidgets` body runs in a fake-async zone
  /// where real file I/O never completes — the store can only be read for
  /// real from the app or an integration test, so a widget test hands the
  /// screen its records instead.
  final Future<List<JamHistoryRecord>> Function()? loadRecords;

  /// How a record is forgotten. Defaults to deleting it from that store.
  final Future<void> Function(JamHistoryRecord record)? forgetRecord;

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  JamHistoryStore? _store;
  List<JamHistoryRecord>? _records;

  /// This device's display name. The store writes the literal 'You' against
  /// your own tracks, and a face lettered from the word "You" is not a face —
  /// so the credit stays "You" and the avatar comes from here.
  String _selfName = '';

  /// One beat for the whole screen's shimmer, not one per placeholder.
  Timer? _shimmer;
  bool _shimmerLit = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    unawaited(_loadIdentity());
  }

  Future<void> _loadIdentity() async {
    final name = await JamIdentity.displayName();
    if (mounted && name != _selfName) setState(() => _selfName = name);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (_records != null || still) {
      _stopShimmer();
      return;
    }
    _shimmer ??= Timer.periodic(_shimmerBeat, (_) {
      if (mounted) setState(() => _shimmerLit = !_shimmerLit);
    });
  }

  void _stopShimmer() {
    _shimmer?.cancel();
    _shimmer = null;
  }

  @override
  void dispose() {
    _stopShimmer();
    super.dispose();
  }

  Future<void> _load() async {
    final override = widget.loadRecords;
    final List<JamHistoryRecord> records;
    if (override != null) {
      records = await override();
    } else {
      final store = _store ??= await JamHistoryStore.open();
      records = store == null ? const <JamHistoryRecord>[] : await store.list();
    }
    if (!mounted) return;
    _stopShimmer();
    setState(() => _records = records);
  }

  Future<void> _forget(JamHistoryRecord record) async {
    final confirmed = await JamDialogs.confirmDestructive(
      context,
      title: HistoryStrings.forgetTitle,
      message: HistoryStrings.forgetBody(record.sessionName),
      confirmLabel: HistoryStrings.forgetConfirm,
    );
    if (!confirmed) return;
    JamHaptics.destructive();
    final forget = widget.forgetRecord;
    if (forget != null) {
      await forget(record);
    } else {
      await _store?.delete(record.sessionId);
    }
    await _load();
  }

  Future<void> _hostAgain(JamHistoryRecord record) async {
    // A jam still running is ended first, on the user's say-so; "Host it
    // again" used to open setup on a start that could only be refused.
    final session = JamSession.read(context);
    if (!await jamReadyForNewSession(context, session) || !mounted) return;
    final args = HostSetupArgs(
      paths: [for (final track in record.replayableTracks) track.localPath!],
      name: record.sessionName,
    );
    // Also held by the controller: route `extra` alone can be lost.
    session.hostSetupDraft = (name: args.name, paths: args.paths);
    context.push('/host', extra: args);
  }

  @override
  Widget build(BuildContext context) {
    final records = _records;

    return Scaffold(
      // The title is a large one in the page itself (§3), not a 19 dp app-bar
      // label — the bar carries only the way back.
      appBar: AppBar(toolbarHeight: 56),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: JamContentWidth.reading,
            ),
            child: switch (records) {
              // A spinner in the middle of a page says "wait"; the shape of
              // what is coming says "nearly there".
              null => ListView(
                padding: _pagePadding,
                children: [
                  const _LargeTitle(),
                  for (var i = 0; i < 2; i++) ...[
                    const SizedBox(height: JamSpace.section),
                    _ShimmerCard(lit: _shimmerLit),
                  ],
                ],
              ),
              [] => const Column(
                children: [
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      JamSpace.page,
                      JamSpace.sm,
                      JamSpace.page,
                      0,
                    ),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: _LargeTitle(),
                    ),
                  ),
                  Expanded(
                    child: JamEmptyState(
                      icon: Icons.history_rounded,
                      title: HistoryStrings.emptyTitle,
                      body: HistoryStrings.emptyBody,
                    ),
                  ),
                ],
              ),
              _ => ListView.separated(
                padding: _pagePadding,
                itemCount: records.length + 1,
                separatorBuilder: (_, _) =>
                    const SizedBox(height: JamSpace.section),
                itemBuilder: (context, index) => index == 0
                    ? const _LargeTitle()
                    : _RecordCard(
                        record: records[index - 1],
                        selfName: _selfName,
                        onForget: () => unawaited(_forget(records[index - 1])),
                        onHostAgain: () =>
                            unawaited(_hostAgain(records[index - 1])),
                      ),
              ),
            },
          ),
        ),
      ),
    );
  }

  static const EdgeInsets _pagePadding = EdgeInsets.fromLTRB(
    JamSpace.page,
    JamSpace.sm,
    JamSpace.page,
    JamSpace.huge,
  );
}

/// "Past jams", set as a page title rather than an app-bar label.
class _LargeTitle extends StatelessWidget {
  const _LargeTitle();

  @override
  Widget build(BuildContext context) => Semantics(
    header: true,
    child: Text(HistoryStrings.title, style: context.jamLargeTitle),
  );
}

/// The card shell every record and every placeholder shares.
class _Card extends StatelessWidget {
  const _Card({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(JamRadius.lg),
        border: Border.all(color: colors.separator, width: 0.5),
        boxShadow: JamShadow.raised(colors),
      ),
      child: child,
    );
  }
}

class _RecordCard extends StatelessWidget {
  const _RecordCard({
    required this.record,
    required this.selfName,
    required this.onForget,
    required this.onHostAgain,
  });

  final JamHistoryRecord record;

  /// This device's display name, for the "you" face on your own rows.
  final String selfName;

  final VoidCallback onForget;
  final VoidCallback onHostAgain;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final replayable = record.replayableTracks.length;
    final total = record.tracks.length;
    final preview = record.tracks.take(_previewTracks).toList();

    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Header(record: record),
          Divider(height: 0.5, thickness: 0.5, color: colors.separator),
          for (final track in preview)
            JamTrackRow(
              title: jamDisplayTitle(track.item),
              byline: track.item.artist,
              addedByName: track.addedByName,
              // Every row is credited, yours included — a past jam with no
              // faces on it is a playlist. The store writes the literal 'You'
              // for this device, so the label stays "You" and the face is
              // drawn from this device's own name with the apricot ring.
              addedByYou: track.addedByName == 'You',
              addedByAvatarName: track.addedByName == 'You' ? selfName : null,
              // Faded is the whole signal that a track has left the device;
              // saying it again on every row turns a card into a warning.
              dimmed: !track.existsLocally,
              trailing: const SizedBox.shrink(),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: JamSpace.card,
              ),
            ),
          if (total > preview.length)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                JamSpace.card,
                0,
                JamSpace.card,
                JamSpace.md,
              ),
              child: Text(
                HistoryStrings.more(total - preview.length),
                style: context.jamFootnote.copyWith(color: colors.textTertiary),
              ),
            ),
          Divider(height: 0.5, thickness: 0.5, color: colors.separator),
          Padding(
            padding: const EdgeInsets.all(JamSpace.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    JamButton.tertiary(
                      label: HistoryStrings.forget,
                      onPressed: onForget,
                      semanticLabel:
                          '${HistoryStrings.forget} ${record.sessionName}',
                    ),
                    const Spacer(),
                    // Always the same label: interpolating the count read as
                    // "Host 0 again" on a record whose files are all gone,
                    // which is a sentence, not a button. What is missing goes
                    // in the footnote under it.
                    JamButton.primary(
                      label: HistoryStrings.hostAgain,
                      onPressed: replayable == 0 ? null : onHostAgain,
                      semanticLabel:
                          '${HistoryStrings.hostAgain}: '
                          '${record.sessionName}',
                    ),
                  ],
                ),
                if (replayable < total) ...[
                  const SizedBox(height: JamSpace.sm),
                  Text(
                    replayable == 0
                        ? HistoryStrings.noneLeft
                        : HistoryStrings.someLeft(replayable, total),
                    textAlign: TextAlign.end,
                    style: context.jamFootnote.copyWith(
                      color: colors.textTertiary,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The 96 dp strip: what the jam looked like, what it was called, and who
/// was in it.
class _Header extends StatelessWidget {
  const _Header({required this.record});

  final JamHistoryRecord record;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final total = record.tracks.length;

    return SizedBox(
      height: 96,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: JamSpace.card),
        child: Row(
          children: [
            JamArtworkMosaic(
              tracks: record.tracks,
              size: 64,
              semanticLabel: HistoryStrings.cover(record.sessionName),
            ),
            const SizedBox(width: JamSpace.md),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          record.sessionName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.jamRowTitle,
                        ),
                      ),
                      const SizedBox(width: JamSpace.sm),
                      Text(
                        jamRelativeTime(record.updatedAt),
                        style: context.jamFootnote.copyWith(
                          color: colors.textTertiary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: JamSpace.xxs),
                  Text(
                    '${record.wasHost ? HistoryStrings.youHosted : HistoryStrings.youJoined}'
                    ' · ${HistoryStrings.tracks(total)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.jamByline,
                  ),
                  if (record.peerNames.isNotEmpty) ...[
                    const SizedBox(height: JamSpace.sm),
                    JamAvatarStack(
                      names: record.peerNames,
                      size: JamAvatarSize.strip,
                      maxVisible: 4,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The shape of a record, sweeping, while the store is read off disk.
class _ShimmerCard extends StatelessWidget {
  const _ShimmerCard({required this.lit});

  /// Which half of the beat this is.
  final bool lit;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;

    Widget block(double width, double height) => Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: colors.surfaceMuted,
        borderRadius: BorderRadius.circular(JamRadius.xs),
      ),
    );

    return ExcludeSemantics(
      child: AnimatedOpacity(
        opacity: lit ? 1 : 0.55,
        duration: _shimmerFade,
        curve: JamCurve.ambient,
        child: _Card(
          child: Padding(
            padding: const EdgeInsets.all(JamSpace.card),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        color: colors.surfaceMuted,
                        borderRadius: BorderRadius.circular(
                          JamRadius.artwork(64),
                        ),
                      ),
                    ),
                    const SizedBox(width: JamSpace.md),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        block(140, 17),
                        const SizedBox(height: JamSpace.sm),
                        block(96, 13),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: JamSpace.xl),
                for (var i = 0; i < 3; i++) ...[
                  if (i > 0) const SizedBox(height: JamSpace.md),
                  block(double.infinity, 20),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
