/// Past Jams: every session leaves a record (queue + who added what + who
/// was there); tracks still on this device can seed a new jam in one tap.
///
/// An Apple Music list: plain rows (cover 56, name, "You hosted · 12 songs ·
/// Yesterday", chevron), swipe to Forget, tap for the detail page — a centred
/// 200 cover, the name, **Host Again** and the queue with who added what
/// (DESIGN_SPEC v3 §6.7).
///
/// History records carry no artwork bytes — a `JamHistoryTrack` is a
/// `MediaItem` and a path — so covers are read back out of the files that are
/// still on this device (a host's sources, a guest's cache), off the UI
/// isolate, and cached by `artworkId`.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:go_router/go_router.dart';
import 'package:localjam_client/localjam_client.dart';

import '../design/breakpoints.dart';
import '../design/tokens.dart';
import '../design/typography.dart';
import '../router.dart';
import '../state/session_controller.dart';
import '../util/format.dart';
import '../widgets/artwork.dart';
import '../widgets/buttons.dart';
import '../widgets/dialogs.dart';
import '../widgets/empty_state.dart';
import '../widgets/list.dart';
import '../widgets/menu.dart';
import '../widgets/scaffold.dart';
import '../widgets/session_gate.dart';
import '../widgets/swipe_action.dart';
import '../widgets/track_row.dart';

/// Every user-facing string on these pages, in one place.
abstract final class HistoryStrings {
  static const String title = 'Past Jams';
  static const String forget = 'Forget';
  static const String hostAgain = 'Host Again';
  static const String youHosted = 'You hosted';
  static const String youJoined = 'You joined';
  static const String noneLeft = 'None of these songs are on this device now.';
  static String someLeft(int replayable, int total) =>
      '$replayable of $total songs are still on this device.';
  static String songs(int n) => '$n ${n == 1 ? 'song' : 'songs'}';

  /// "12 songs, 48 minutes" — the footer under the detail page's queue.
  static String songsAndLength(int n, Duration length) {
    final minutes = length.inMinutes;
    if (minutes < 1) return songs(n);
    if (minutes < 60) {
      return '${songs(n)}, $minutes ${minutes == 1 ? 'minute' : 'minutes'}';
    }
    final hours = length.inHours;
    final rest = minutes - hours * 60;
    final h = '$hours ${hours == 1 ? 'hour' : 'hours'}';
    return rest == 0
        ? '${songs(n)}, $h'
        : '${songs(n)}, $h $rest ${rest == 1 ? 'minute' : 'minutes'}';
  }

  /// "With Mia", "With Mia and Neon Walrus", "With Mia, Neon Walrus and 2
  /// others".
  static String withPeople(List<String> names) {
    if (names.isEmpty) return '';
    if (names.length == 1) return 'With ${names[0]}';
    if (names.length == 2) return 'With ${names[0]} and ${names[1]}';
    final others = names.length - 2;
    return 'With ${names[0]}, ${names[1]} and $others '
        '${others == 1 ? 'other' : 'others'}';
  }

  static const String forgetTitle = 'Forget This Jam?';
  static String forgetBody(String name) =>
      'The record of $name goes away. The music on this device stays.';
  static const String forgetConfirm = 'Forget';

  static const String emptyTitle = 'No Past Jams';
  static const String emptyBody = 'Jams you host or join show up here.';

  static const String justNow = 'Just now';
  static const String today = 'Today';
  static const String yesterday = 'Yesterday';
  static const List<String> weekdays = [
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ];
  static const List<String> months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];

  /// Announced for a cover or mosaic, which is decorative on its own.
  static String cover(String name) => 'Cover art from $name';
  static String forgetHint(String name) => '$forget $name';
  static const String more = 'More';

  /// What the store writes against this device's own tracks.
  static const String storedYou = 'You';
}

/// A relative "when", Apple style: "Just now", "Today", "Yesterday", a
/// weekday within the week, then "Oct 12" (and the year once it is not this
/// one).
///
/// Lives here rather than in `util/format.dart` because it is presentation,
/// not formatting of engine data; Home's Recent section reaches it through
/// [jamHistorySummary].
String jamRelativeTime(DateTime time, {DateTime? now}) {
  final at = time.toLocal();
  final current = (now ?? DateTime.now()).toLocal();
  if (current.difference(at).inMinutes.abs() < 1) return HistoryStrings.justNow;
  final today = DateTime(current.year, current.month, current.day);
  final day = DateTime(at.year, at.month, at.day);
  // Calendar days, not 24-hour spans; DST-safe via rounding.
  final days = (today.difference(day).inHours / 24).round();
  if (days <= 0) return HistoryStrings.today;
  if (days == 1) return HistoryStrings.yesterday;
  if (days < 7) return HistoryStrings.weekdays[at.weekday - 1];
  final date = '${HistoryStrings.months[at.month - 1]} ${at.day}';
  return at.year == current.year ? date : '$date, ${at.year}';
}

/// "You hosted · 12 songs · Yesterday" — a record's one-line summary, on
/// Past Jams, the detail page and Home's Recent section alike. A jam that
/// never had a song says nothing about songs rather than "0 songs".
String jamHistorySummary(
  JamHistoryRecord record, {
  bool withCount = true,
  DateTime? now,
}) => [
  record.wasHost ? HistoryStrings.youHosted : HistoryStrings.youJoined,
  if (withCount && record.tracks.isNotEmpty)
    HistoryStrings.songs(record.tracks.length),
  jamRelativeTime(record.updatedAt, now: now),
].join(' · ');

// ---------------------------------------------------------------------------
// Covers
// ---------------------------------------------------------------------------

/// Covers read back out of files still on this device, by `artworkId`.
///
/// Reads run in `readAudioTags`' short-lived isolate, two at a time, and the
/// newest [_capacity] results (including "no cover") are kept, so scrolling
/// back up a long list never reads a file twice.
abstract final class _HistoryCovers {
  static final LinkedHashMap<String, Future<Uint8List?>> _cache =
      LinkedHashMap<String, Future<Uint8List?>>();
  static const int _capacity = 96;

  /// A cover is a picture, not a payload: anything bigger is not read.
  static const int _maxBytes = 8 * 1024 * 1024;

  static int _running = 0;
  static const int _parallel = 2;
  static final Queue<Completer<void>> _waiting = Queue<Completer<void>>();

  /// One track per distinct cover, in queue order, among tracks whose file
  /// is still here.
  static List<JamHistoryTrack> distinct(
    Iterable<JamHistoryTrack> tracks, {
    int limit = 4,
  }) {
    final seen = <String>{};
    final out = <JamHistoryTrack>[];
    for (final track in tracks) {
      final id = track.item.artworkId;
      if (id == null || seen.contains(id)) continue;
      if (!track.existsLocally) continue;
      seen.add(id);
      out.add(track);
      if (out.length >= limit) break;
    }
    return out;
  }

  /// The cached result for [track], if a read already finished or started.
  static Future<Uint8List?>? peek(JamHistoryTrack track) {
    final id = track.item.artworkId;
    return id == null ? null : _cache[id];
  }

  /// The cover of [track], or null when it has none or its file is gone.
  static Future<Uint8List?> load(JamHistoryTrack track) {
    final id = track.item.artworkId;
    final path = track.localPath;
    if (id == null || path == null) return Future<Uint8List?>.value();
    final hit = _cache.remove(id);
    if (hit != null) {
      _cache[id] = hit; // Most recently used goes last.
      return hit;
    }
    final read = _limited(() => _read(path));
    _cache[id] = read;
    while (_cache.length > _capacity) {
      _cache.remove(_cache.keys.first);
    }
    return read;
  }

  static Future<Uint8List?> _read(String path) async {
    final file = File(path);
    if (!file.existsSync()) return null;
    final tags = await readAudioTags(file, maxMetadataBytes: _maxBytes);
    return tags.hasArtwork ? tags.artworkBytes : null;
  }

  static Future<T> _limited<T>(Future<T> Function() task) async {
    while (_running >= _parallel) {
      final turn = Completer<void>();
      _waiting.add(turn);
      await turn.future;
    }
    _running++;
    try {
      return await task();
    } finally {
      _running--;
      if (_waiting.isNotEmpty) _waiting.removeFirst().complete();
    }
  }
}

/// Decodes [bytes] at the size it is drawn, not at the file's 1400 px.
ImageProvider _coverImage(BuildContext context, Uint8List bytes, double size) {
  final px = (size * MediaQuery.devicePixelRatioOf(context)).round();
  return ResizeImage(MemoryImage(bytes), width: px, height: px);
}

/// A past jam's cover: a 2×2 mosaic when the queue has at least four
/// distinct real covers still on this device, otherwise the first cover, and
/// otherwise the plain placeholder.
///
/// Used by Past Jams, the detail page and Home's Recent section.
class JamArtworkMosaic extends StatefulWidget {
  const JamArtworkMosaic({
    super.key,
    required this.tracks,
    required this.size,
    this.semanticLabel,
    this.shadow = false,
  });

  final List<JamHistoryTrack> tracks;

  /// Edge length of the whole tile.
  final double size;

  final String? semanticLabel;

  /// `JamShadow.artwork` under it — only for the large detail cover.
  final bool shadow;

  @override
  State<JamArtworkMosaic> createState() => _JamArtworkMosaicState();
}

class _JamArtworkMosaicState extends State<JamArtworkMosaic> {
  /// Loaded covers, in queue order. Null until the reads finish.
  List<Uint8List>? _covers;
  Object? _token;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(JamArtworkMosaic old) {
    super.didUpdateWidget(old);
    if (!identical(old.tracks, widget.tracks)) unawaited(_load());
  }

  Future<void> _load() async {
    final token = _token = Object();
    final candidates = _HistoryCovers.distinct(widget.tracks);
    if (candidates.isEmpty) {
      if (_covers != null && mounted) setState(() => _covers = null);
      return;
    }
    // Fewer than four distinct covers can only ever show the first one, so
    // only that one is read.
    final wanted = candidates.length >= 4 ? candidates : [candidates.first];
    final results = await Future.wait([
      for (final track in wanted) _HistoryCovers.load(track),
    ]);
    if (!mounted || token != _token) return;
    setState(() => _covers = [...results.nonNulls]);
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.size;
    final covers = _covers ?? const <Uint8List>[];
    final radius = BorderRadius.circular(JamRadius.artwork(size));

    if (covers.length < 4) {
      return JamArtworkTile(
        size: size,
        image: covers.isEmpty ? null : _coverImage(context, covers.first, size),
        imageKey: covers.isEmpty ? null : identityHashCode(covers.first),
        semanticLabel: widget.semanticLabel,
        shadow: widget.shadow && covers.isNotEmpty,
      );
    }

    final half = size / 2;
    Widget quad(Uint8List bytes) => Image(
      image: _coverImage(context, bytes, half),
      width: half,
      height: half,
      fit: BoxFit.cover,
      gaplessPlayback: true,
    );
    Widget grid = ClipRRect(
      borderRadius: radius,
      child: SizedBox.square(
        dimension: size,
        child: Column(
          children: [
            Row(children: [quad(covers[0]), quad(covers[1])]),
            Row(children: [quad(covers[2]), quad(covers[3])]),
          ],
        ),
      ),
    );
    if (widget.shadow) {
      grid = DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          boxShadow: JamShadow.artwork,
        ),
        child: grid,
      );
    }
    return Semantics(
      image: true,
      label: widget.semanticLabel,
      child: ExcludeSemantics(child: grid),
    );
  }
}

// ---------------------------------------------------------------------------
// Past Jams
// ---------------------------------------------------------------------------

/// Deletes [record] from the on-disk store.
Future<void> _forgetFromStore(JamHistoryRecord record) async {
  final store = await JamHistoryStore.open();
  await store?.delete(record.sessionId);
}

/// Asks before a record goes; true when the user said Forget.
Future<bool> _confirmForget(BuildContext context, JamHistoryRecord record) =>
    JamDialogs.confirmDestructive(
      context,
      title: HistoryStrings.forgetTitle,
      message: HistoryStrings.forgetBody(record.sessionName),
      confirmLabel: HistoryStrings.forgetConfirm,
    );

/// Side padding that holds a list to a reading column on wide windows.
EdgeInsets _readingPadding(BuildContext context) {
  final width = MediaQuery.sizeOf(context).width;
  final side = width > JamContentWidth.reading
      ? (width - JamContentWidth.reading) / 2
      : 0.0;
  return EdgeInsets.symmetric(horizontal: side);
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

  @override
  void initState() {
    super.initState();
    unawaited(_load());
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
    setState(() => _records = records);
  }

  Future<void> _delete(JamHistoryRecord record) async {
    final forget = widget.forgetRecord;
    if (forget != null) {
      await forget(record);
    } else {
      final store = _store ??= await JamHistoryStore.open();
      await store?.delete(record.sessionId);
    }
  }

  /// The swipe action: asks, then forgets. False keeps the row.
  Future<bool> _forget(JamHistoryRecord record) async {
    if (!await _confirmForget(context, record)) return false;
    JamHaptics.destructive();
    await _delete(record);
    return true;
  }

  /// Takes a forgotten record's row out of the list once it has collapsed.
  void _drop(JamHistoryRecord record) {
    if (!mounted) return;
    setState(
      () => _records = [
        for (final r in _records ?? const <JamHistoryRecord>[])
          if (r.sessionId != record.sessionId) r,
      ],
    );
  }

  Future<void> _open(JamHistoryRecord record) async {
    final forgotten = await _pushDetail(context, record, forget: _delete);
    if (forgotten && mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final records = _records;
    return JamScaffold(
      title: HistoryStrings.title,
      slivers: [
        switch (records) {
          // Read off disk in a moment; a spinner would only flash.
          null => const SliverToBoxAdapter(child: SizedBox.shrink()),
          [] => SliverLayoutBuilder(
            builder: (context, constraints) {
              // Fill what is left of the screen (minus the scaffold's own
              // bottom spacer), so the empty state sits in the middle
              // without making an empty page scroll.
              final bottom =
                  JamSpace.xxxl + MediaQuery.paddingOf(context).bottom;
              final height =
                  constraints.viewportMainAxisExtent -
                  constraints.precedingScrollExtent -
                  bottom;
              final fill = height < 280 ? 280.0 : height;
              return SliverToBoxAdapter(
                child: SizedBox(
                  height: fill,
                  // Optically centred: a touch above the true middle.
                  child: Padding(
                    padding: EdgeInsets.only(bottom: fill * 0.15),
                    child: const JamEmptyState(
                      icon: CupertinoIcons.clock,
                      title: HistoryStrings.emptyTitle,
                      body: HistoryStrings.emptyBody,
                    ),
                  ),
                ),
              );
            },
          ),
          _ => SliverPadding(
            padding: _readingPadding(context),
            sliver: SliverList.builder(
              itemCount: records.length,
              itemBuilder: (context, index) {
                final record = records[index];
                return JamSwipeAction(
                  key: ValueKey<String>(record.sessionId),
                  label: HistoryStrings.forget,
                  semanticLabel: HistoryStrings.forgetHint(record.sessionName),
                  onAction: () => _forget(record),
                  onRemoved: () => _drop(record),
                  child: _RecordRow(
                    record: record,
                    separator: index < records.length - 1,
                    onTap: () => unawaited(_open(record)),
                  ),
                );
              },
            ),
          ),
        },
      ],
    );
  }
}

/// One past jam in the list.
class _RecordRow extends StatelessWidget {
  const _RecordRow({
    required this.record,
    required this.separator,
    required this.onTap,
  });

  final JamHistoryRecord record;
  final bool separator;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => JamRow(
    leading: JamArtworkMosaic(
      tracks: record.tracks,
      size: JamArtworkSize.list,
      semanticLabel: HistoryStrings.cover(record.sessionName),
    ),
    leadingWidth: JamArtworkSize.list,
    title: record.sessionName,
    subtitle: jamHistorySummary(record),
    subtitleMaxLines: 1,
    chevron: true,
    separator: separator,
    onTap: onTap,
  );
}

// ---------------------------------------------------------------------------
// Detail
// ---------------------------------------------------------------------------

/// Opens one past jam's detail page.
///
/// Home's Recent section and the Past Jams list both land here. Forgetting
/// from the page deletes the record from the on-disk store and pops.
Future<void> showJamHistoryDetail(
  BuildContext context,
  JamHistoryRecord record,
) async {
  await _pushDetail(context, record);
}

/// Pushes the detail page; true when the record was forgotten from it.
Future<bool> _pushDetail(
  BuildContext context,
  JamHistoryRecord record, {
  Future<void> Function(JamHistoryRecord record)? forget,
}) async {
  final forgotten = await Navigator.of(context).push<bool>(
    CupertinoPageRoute<bool>(
      builder: (context) =>
          HistoryDetailScreen(record: record, forgetRecord: forget),
    ),
  );
  return forgotten ?? false;
}

/// One past jam: its cover, what it was, Host Again, and the queue.
class HistoryDetailScreen extends StatefulWidget {
  const HistoryDetailScreen({
    super.key,
    required this.record,
    this.forgetRecord,
  });

  final JamHistoryRecord record;

  /// How the record is forgotten. Defaults to deleting it from the store.
  final Future<void> Function(JamHistoryRecord record)? forgetRecord;

  @override
  State<HistoryDetailScreen> createState() => _HistoryDetailScreenState();
}

class _HistoryDetailScreenState extends State<HistoryDetailScreen> {
  final ScrollController _scroll = ScrollController();

  /// The inline nav title appears once the name has scrolled under the bar.
  bool _titleShown = false;

  /// Where the name's baseline sits in the scroll view (cover + gaps).
  static const double _titleScrollThreshold =
      JamSpace.xxl + JamArtworkSize.detail + JamSpace.xl + 28;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll
      ..removeListener(_onScroll)
      ..dispose();
    super.dispose();
  }

  void _onScroll() {
    final shown = _scroll.offset > _titleScrollThreshold;
    if (shown != _titleShown) setState(() => _titleShown = shown);
  }

  JamHistoryRecord get _record => widget.record;

  Future<void> _forget() async {
    if (!await _confirmForget(context, _record)) return;
    JamHaptics.destructive();
    await (widget.forgetRecord ?? _forgetFromStore)(_record);
    if (mounted) Navigator.of(context).pop(true);
  }

  Future<void> _hostAgain() async {
    // A jam still running is ended first, on the user's say-so.
    final session = JamSession.read(context);
    if (!await jamReadyForNewSession(context, session) || !mounted) return;
    final args = HostSetupArgs(
      paths: [for (final track in _record.replayableTracks) track.localPath!],
      name: _record.sessionName,
    );
    // Also held by the controller: route `extra` alone can be lost.
    session.hostSetupDraft = (name: args.name, paths: args.paths);
    unawaited(context.push('/host', extra: args));
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final record = _record;
    final tracks = record.tracks;
    final replayable = record.replayableTracks.length;
    final total = tracks.length;
    final length = Duration(
      microseconds: tracks.fold<int>(
        0,
        (sum, t) => sum + (t.item.durationUs ?? 0),
      ),
    );
    final secondary = context.jamSubheadline.copyWith(
      color: colors.secondaryLabel,
    );
    final footnote = context.jamFootnote.copyWith(color: colors.secondaryLabel);

    final menu = JamMenuButton(
      semanticLabel: HistoryStrings.more,
      groups: [
        [
          JamMenuItem(
            title: HistoryStrings.forget,
            icon: CupertinoIcons.trash,
            destructive: true,
            onPressed: () => unawaited(_forget()),
          ),
        ],
      ],
    );

    final content = SliverMainAxisGroup(
      slivers: [
        SliverPadding(
          padding: _readingPadding(context),
          sliver: SliverList.list(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: JamSpace.page),
                child: Column(
                  children: [
                    const SizedBox(height: JamSpace.xxl),
                    JamArtworkMosaic(
                      tracks: tracks,
                      size: JamArtworkSize.detail,
                      shadow: true,
                      semanticLabel: HistoryStrings.cover(record.sessionName),
                    ),
                    const SizedBox(height: JamSpace.xl),
                    Semantics(
                      header: true,
                      child: Text(
                        record.sessionName,
                        textAlign: TextAlign.center,
                        style: context.jamTitle2,
                      ),
                    ),
                    const SizedBox(height: JamSpace.xs),
                    Text(
                      jamHistorySummary(record, withCount: false),
                      textAlign: TextAlign.center,
                      style: secondary,
                    ),
                    if (record.peerNames.isNotEmpty) ...[
                      const SizedBox(height: JamSpace.xxs),
                      Text(
                        HistoryStrings.withPeople(record.peerNames),
                        textAlign: TextAlign.center,
                        style: secondary,
                      ),
                    ],
                    const SizedBox(height: JamSpace.xl),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 360),
                      child: JamButton.gray(
                        label: HistoryStrings.hostAgain,
                        icon: CupertinoIcons.play_fill,
                        expand: true,
                        // Always the same label; what is missing is said in
                        // the footnote under it.
                        onPressed: replayable == 0
                            ? null
                            : () => unawaited(_hostAgain()),
                        semanticLabel:
                            '${HistoryStrings.hostAgain}: '
                            '${record.sessionName}',
                      ),
                    ),
                    if (replayable < total) ...[
                      const SizedBox(height: JamSpace.sm),
                      Text(
                        replayable == 0
                            ? HistoryStrings.noneLeft
                            : HistoryStrings.someLeft(replayable, total),
                        textAlign: TextAlign.center,
                        style: footnote,
                      ),
                    ],
                    const SizedBox(height: JamSpace.xxl),
                  ],
                ),
              ),
              if (tracks.isNotEmpty) ...[
                const JamHairline(indent: kJamRowInset),
                for (var i = 0; i < tracks.length; i++)
                  _HistoryTrackRow(
                    track: tracks[i],
                    separator: i < tracks.length - 1,
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    kJamRowInset,
                    JamSpace.md,
                    kJamRowInset,
                    0,
                  ),
                  child: Text(
                    HistoryStrings.songsAndLength(total, length),
                    style: footnote,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );

    return JamScaffold(
      title: _titleShown ? record.sessionName : '',
      largeTitle: false,
      controller: _scroll,
      trailing: [menu],
      slivers: [content],
    );
  }
}

/// A queue row on the detail page, with its cover read back off disk.
class _HistoryTrackRow extends StatefulWidget {
  const _HistoryTrackRow({required this.track, required this.separator});

  final JamHistoryTrack track;
  final bool separator;

  @override
  State<_HistoryTrackRow> createState() => _HistoryTrackRowState();
}

class _HistoryTrackRowState extends State<_HistoryTrackRow> {
  Uint8List? _cover;
  late final bool _local = widget.track.existsLocally;

  @override
  void initState() {
    super.initState();
    if (_local && widget.track.item.artworkId != null) {
      final pending =
          _HistoryCovers.peek(widget.track) ??
          _HistoryCovers.load(widget.track);
      unawaited(
        pending.then((bytes) {
          if (mounted && bytes != null) setState(() => _cover = bytes);
        }),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final track = widget.track;
    final adder = track.addedByName;
    final cover = _cover;
    final durationUs = track.item.durationUs;
    return JamTrackRow(
      title: jamDisplayTitle(track.item),
      byline: track.item.artist,
      artworkImage: cover == null
          ? null
          : _coverImage(context, cover, JamArtworkSize.row),
      artworkId: track.item.artworkId,
      addedByName: adder,
      // The store writes the literal 'You' against this device's tracks.
      addedByYou: adder == HistoryStrings.storedYou,
      duration: durationUs == null ? null : Duration(microseconds: durationUs),
      // Faded is the whole signal that a track has left the device.
      dimmed: !_local,
      separator: widget.separator,
    );
  }
}
