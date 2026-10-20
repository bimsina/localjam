/// Past Jams: every session leaves a record (queue + who added what + who
/// was there); tracks still on this device can seed a new jam in one tap.
///
/// A jam is drawn the way it is everywhere else (D4): its mark — one cover,
/// or its monogram — its name in Manrope, and the people who were there.
/// The list is plain rows (mark 56, name, faces + "With Mia and Theo", "You
/// hosted · 12 songs · Yesterday, 9:10 PM", chevron), swipe to Forget, tap
/// for the jam's page: the mark beside its name, when and who, **Host
/// Again**, and the songs with who added what — as faces, as in the queue.
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
import '../widgets/avatar.dart';
import '../widgets/buttons.dart';
import '../widgets/dialogs.dart';
import '../widgets/empty_state.dart';
import '../widgets/jam_mark.dart';
import '../widgets/list.dart';
import '../widgets/menu.dart';
import '../widgets/peer_row.dart' show JamPeopleLine;
import '../widgets/pressable.dart';
import '../widgets/scaffold.dart';
import '../widgets/session_gate.dart';
import '../widgets/swipe_action.dart';
import '../widgets/track_row.dart';

/// Every user-facing string on these pages, in one place.
abstract final class HistoryStrings {
  static const String title = 'Past jams';
  static const String forget = 'Forget';
  static const String hostAgain = 'Host again';

  /// A jam you joined was never yours to host *again*.
  static const String hostThis = 'Host this jam';
  static String hostLabel({required bool wasHost}) =>
      wasHost ? hostAgain : hostThis;
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
  /// others" — people said as everywhere else ([jamPeopleSummary]); nothing
  /// for a jam nobody else was in.
  static String withPeople(List<String> names) =>
      names.isEmpty ? '' : jamPeopleSummary(names);

  /// The detail page's list of what played.
  static const String songsHeader = 'Songs';

  static const String forgetTitle = 'Forget this jam?';
  static String forgetBody(String name) =>
      '$name will be removed from Past jams. Songs on this device won’t be '
      'deleted.';
  static const String forgetConfirm = 'Forget';

  /// The notice after a swipe forgets a jam — the undo is the safety net,
  /// not a second question.
  static String forgotten(String name) => 'Forgot $name';
  static const String undo = 'Undo';

  static const String emptyTitle = 'No past jams';
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

  /// Announced for a past jam's cover, which is decorative on its own.
  static String cover(String name) => 'Cover art from $name';
  static String forgetHint(String name) => '$forget $name';
  static const String more = 'More';

  /// What the store writes against this device's own tracks.
  static const String storedYou = 'You';
}

/// A relative "when", Apple style: "Just now", "Today, 3:42 PM",
/// "Yesterday, 9:10 PM", a weekday within the week, then "Oct 12" (and the
/// year once it is not this one).
///
/// Today and yesterday carry the time: two jams in one evening otherwise
/// read as the same row twice.
///
/// Lives here rather than in `util/format.dart` because it is presentation,
/// not formatting of engine data; Home's Recent section reaches it through
/// [jamHistorySummary].
String jamRelativeTime(
  DateTime time, {
  DateTime? now,
  bool use24HourFormat = false,
}) {
  final at = time.toLocal();
  final current = (now ?? DateTime.now()).toLocal();
  if (current.difference(at).inMinutes.abs() < 1) return HistoryStrings.justNow;
  final today = DateTime(current.year, current.month, current.day);
  final day = DateTime(at.year, at.month, at.day);
  // Calendar days, not 24-hour spans; DST-safe via rounding.
  final days = (today.difference(day).inHours / 24).round();
  final clock = jamClockTime(at, use24HourFormat: use24HourFormat);
  if (days <= 0) return '${HistoryStrings.today}, $clock';
  if (days == 1) return '${HistoryStrings.yesterday}, $clock';
  if (days < 7) return HistoryStrings.weekdays[at.weekday - 1];
  final date = '${HistoryStrings.months[at.month - 1]} ${at.day}';
  return at.year == current.year ? date : '$date, ${at.year}';
}

/// "3:42 PM" (or "15:42" where the device uses a 24-hour clock).
String jamClockTime(DateTime time, {bool use24HourFormat = false}) {
  final minute = time.minute.toString().padLeft(2, '0');
  if (use24HourFormat) {
    return '${time.hour.toString().padLeft(2, '0')}:$minute';
  }
  final hour = time.hour % 12 == 0 ? 12 : time.hour % 12;
  return '$hour:$minute ${time.hour < 12 ? 'AM' : 'PM'}';
}

/// "You hosted · 12 songs · Yesterday, 9:10 PM" — a record's one-line
/// summary, on Past Jams, the detail page and Home's Recent section alike. A
/// jam that never had a song says nothing about songs rather than "0 songs".
///
/// [keepTimeTogether] joins the "when" with no-break spaces, so a summary
/// that wraps moves "Yesterday, 9:10 PM" to the next line whole instead of
/// leaving "PM" there alone. For drawing; the plain string is for matching.
String jamHistorySummary(
  JamHistoryRecord record, {
  bool withCount = true,
  DateTime? now,
  bool use24HourFormat = false,
  bool keepTimeTogether = false,
}) {
  final when = jamRelativeTime(
    record.updatedAt,
    now: now,
    use24HourFormat: use24HourFormat,
  );
  return [
    record.wasHost ? HistoryStrings.youHosted : HistoryStrings.youJoined,
    if (withCount && record.tracks.isNotEmpty)
      HistoryStrings.songs(record.tracks.length),
    keepTimeTogether ? when.replaceAll(' ', kJamNoBreakSpace) : when,
  ].join(' · ');
}

/// U+00A0: a space a line never breaks at.
const String kJamNoBreakSpace = '\u00A0';

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

  /// Forgets every read. A cached read belongs to the zone it started in,
  /// so a test run that follows another must not inherit it.
  static void reset() {
    _cache.clear();
    _running = 0;
    _waiting.clear();
  }

  /// One track per distinct cover, in queue order, among tracks whose file
  /// is still here.
  static List<JamHistoryTrack> distinct(
    Iterable<JamHistoryTrack> tracks, {
    int limit = 3,
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

/// Forgets the covers Past Jams has read, for a test that runs after another
/// in the same process (the capture tool's light and dark passes).
@visibleForTesting
void debugResetJamHistoryCovers() => _HistoryCovers.reset();

/// Decodes [bytes] at the size it is drawn, not at the file's 1400 px.
ImageProvider _coverImage(BuildContext context, Uint8List bytes, double size) {
  final px = (size * MediaQuery.devicePixelRatioOf(context)).round();
  return ResizeImage(MemoryImage(bytes), width: px, height: px);
}

/// A past jam's mark (`JamMark`, D4): the cover of its first song whose
/// cover is still on this device — one cover, as the jam is drawn on the
/// Invite sheet and the page it ended on — and with none here, the jam's
/// monogram rather than a music note (a note is a *song* without art; this
/// is a jam).
///
/// Used by every past-jam row (Past Jams, Home's Recent) and the detail
/// page.
class JamHistoryMark extends StatefulWidget {
  const JamHistoryMark({
    super.key,
    required this.tracks,
    required this.size,
    required this.name,
    this.semanticLabel,
    this.shadow = false,
  });

  final List<JamHistoryTrack> tracks;

  /// Edge length of the tile.
  final double size;

  /// The jam's name: where its monogram comes from.
  final String name;

  final String? semanticLabel;

  /// `JamShadow.artwork` under it — only for large art, and only once there
  /// is a cover to cast it.
  final bool shadow;

  @override
  State<JamHistoryMark> createState() => _JamHistoryMarkState();
}

class _JamHistoryMarkState extends State<JamHistoryMark> {
  /// The cover, once read. Null until then, and when there is none.
  Uint8List? _cover;
  Object? _token;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(JamHistoryMark old) {
    super.didUpdateWidget(old);
    if (!identical(old.tracks, widget.tracks)) unawaited(_load());
  }

  Future<void> _load() async {
    final token = _token = Object();
    // The first song with a cover, in queue order; a file whose tag turns
    // out to hold none hands over to the next.
    for (final track in _HistoryCovers.distinct(widget.tracks)) {
      final bytes = await _HistoryCovers.load(track);
      if (!mounted || token != _token) return;
      if (bytes != null && bytes.isNotEmpty) {
        setState(() => _cover = bytes);
        return;
      }
    }
    if (_cover != null && mounted) setState(() => _cover = null);
  }

  @override
  Widget build(BuildContext context) {
    final cover = _cover;
    return JamMark(
      name: widget.name,
      size: widget.size,
      cover: cover == null ? null : _coverImage(context, cover, widget.size),
      semanticLabel: widget.semanticLabel,
      shadow: widget.shadow && cover != null,
    );
  }
}

/// The faces of [record]'s people, coloured as the jam coloured them (D3):
/// this device ([self]) and everyone the record names, through
/// [jamPeopleColors] — with this device as the host when it hosted. A
/// joined jam's record does not say who hosted, so there everyone is in
/// name order. Parallel to [JamHistoryRecord.peerNames].
List<Color> jamRecordFaceColors(
  JamHistoryRecord record, {
  required String self,
}) {
  final byName = jamRecordColorsByName(record, self: self);
  return [for (final name in record.peerNames) byName[name]!];
}

/// Every face of [record] by name, this device's under [self] — the same
/// assignment as [jamRecordFaceColors], for the songs' credits.
Map<String, Color> jamRecordColorsByName(
  JamHistoryRecord record, {
  required String self,
}) {
  final me = self.trim();
  return jamPeopleColors([
    if (me.isNotEmpty) me,
    ...record.peerNames,
  ], host: record.wasHost && me.isNotEmpty ? me : null);
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

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({
    super.key,
    this.loadRecords,
    this.forgetRecord,
    this.restoreRecord,
  });

  /// Where the records come from. Defaults to the on-disk store.
  ///
  /// The seam exists because a `testWidgets` body runs in a fake-async zone
  /// where real file I/O never completes — the store can only be read for
  /// real from the app or an integration test, so a widget test hands the
  /// screen its records instead.
  final Future<List<JamHistoryRecord>> Function()? loadRecords;

  /// How a record is forgotten. Defaults to deleting it from that store.
  final Future<void> Function(JamHistoryRecord record)? forgetRecord;

  /// How a forgotten record comes back (Undo). Defaults to saving it to the
  /// store again.
  final Future<void> Function(JamHistoryRecord record)? restoreRecord;

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  JamHistoryStore? _store;
  List<JamHistoryRecord>? _records;

  /// This device's name: the jam counted it when it gave out the faces'
  /// colours, so the rows do too ([jamRecordFaceColors]).
  String _self = '';

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    unawaited(_loadSelf());
  }

  Future<void> _loadSelf() async {
    final name = await JamIdentity.displayName();
    if (mounted && name != _self) setState(() => _self = name);
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

  /// The swipe action: forgets at once, like a trailing swipe in Mail or
  /// Notes — the swipe *was* the decision — and offers Undo, which is the
  /// safety net a second question used to be.
  Future<bool> _forget(JamHistoryRecord record) async {
    final session = JamSession.read(context);
    JamHaptics.destructive();
    await _delete(record);
    session.notify(
      HistoryStrings.forgotten(record.sessionName),
      actionLabel: HistoryStrings.undo,
      onAction: () => unawaited(_restore(record)),
      tone: JamNoticeTone.neutral,
    );
    return true;
  }

  /// Undo: the record goes back to the store and the list.
  Future<void> _restore(JamHistoryRecord record) async {
    final restore = widget.restoreRecord;
    if (restore != null) {
      await restore(record);
    } else {
      final store = _store ??= await JamHistoryStore.open();
      await store?.save(record);
    }
    if (mounted) await _load();
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
      // The reading column, centred in the pane (not the window), with the
      // large title on its edge.
      maxContentWidth: JamContentWidth.reading,
      slivers: [
        switch (records) {
          // Read off disk in a moment; a spinner would only flash.
          null => const SliverToBoxAdapter(child: SizedBox.shrink()),
          // Placed as Nearby places its own.
          [] => jamAnchoredEmptyState(
            const JamEmptyState(
              icon: CupertinoIcons.clock,
              title: HistoryStrings.emptyTitle,
              body: HistoryStrings.emptyBody,
            ),
          ),
          _ => SliverList.builder(
            itemCount: records.length,
            itemBuilder: (context, index) {
              final record = records[index];
              return JamSwipeAction(
                key: ValueKey<String>(record.sessionId),
                label: HistoryStrings.forget,
                semanticLabel: HistoryStrings.forgetHint(record.sessionName),
                onAction: () => _forget(record),
                onRemoved: () => _drop(record),
                child: JamHistoryRow(
                  record: record,
                  self: _self,
                  separator: index < records.length - 1,
                  onTap: () => unawaited(_open(record)),
                ),
              );
            },
          ),
        },
      ],
    );
  }
}

/// One past jam, drawn the way a jam is drawn everywhere: its mark, its
/// name in Manrope, the faces of who was there, then what it was and when.
/// Past Jams lists these, and Home's Recent section lists its last few.
///
/// It draws its own hairline ([separator]), inset to the text.
class JamHistoryRow extends StatelessWidget implements JamSelfSeparatingRow {
  const JamHistoryRow({
    super.key,
    required this.record,
    required this.onTap,
    this.self = '',
    this.separator = false,
  });

  final JamHistoryRecord record;
  final VoidCallback onTap;

  /// This device's display name, for the faces' colours
  /// ([jamRecordFaceColors]).
  final String self;

  /// A hairline under the row — every row but the last.
  final bool separator;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final peers = record.peerNames;
    final summary = jamHistorySummary(
      record,
      use24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
      keepTimeTogether: true,
    );
    const mark = JamMarkSize.row;

    Widget content = Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(
        kJamRowInset,
        JamSpace.md,
        kJamRowInset,
        JamSpace.md,
      ),
      child: Row(
        children: [
          JamHistoryMark(
            tracks: record.tracks,
            size: mark,
            name: record.sessionName,
          ),
          const SizedBox(width: kJamRowLeadingGap),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  record.sessionName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: context.jamNameRow,
                ),
                if (peers.isNotEmpty) ...[
                  const SizedBox(height: JamSpace.xs),
                  _People(
                    names: peers,
                    colors: jamRecordFaceColors(record, self: self),
                    size: JamAvatarSize.attribution,
                  ),
                ],
                const SizedBox(height: JamSpace.xxs),
                // Two lines before an ellipsis: the time at the end is what
                // tells two jams from one evening apart, and it moves to the
                // second line whole.
                Text(
                  summary,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: context.jamFootnote.copyWith(
                    color: colors.secondaryLabel,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: JamSpace.sm),
          const JamDisclosureChevron(),
        ],
      ),
    );

    if (separator) {
      content = Stack(
        children: [
          content,
          PositionedDirectional(
            start: kJamRowInset + mark + kJamRowLeadingGap,
            end: jamHairlineEndInset(context, kJamRowInset),
            bottom: 0,
            child: const JamHairline(),
          ),
        ],
      );
    }

    // One node, read in the order it is drawn.
    return MergeSemantics(
      child: Semantics(
        button: true,
        label: [
          record.sessionName,
          if (peers.isNotEmpty) HistoryStrings.withPeople(peers),
          jamHistorySummary(
            record,
            use24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
          ),
        ].join('. '),
        onTap: onTap,
        excludeSemantics: true,
        child: JamPressable(
          onTap: onTap,
          style: JamPressStyle.highlight,
          child: content,
        ),
      ),
    );
  }
}

/// Who was there: their faces, then their names ("With Mia and Theo").
class _People extends StatelessWidget {
  const _People({
    required this.names,
    required this.colors,
    required this.size,
  });

  final List<String> names;

  /// The faces' colours, parallel to [names] ([jamRecordFaceColors]).
  final List<Color> colors;
  final double size;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      // The names beside it say who, and how many more; the faces — the
      // first three, with no "+N" to repeat that count — are how they look.
      ExcludeSemantics(
        child: JamAvatarStack(
          names: names.take(3).toList(),
          colors: colors.take(3).toList(),
          size: size,
        ),
      ),
      const SizedBox(width: JamSpace.sm),
      // Names cut before the count is, as in the room (R9, RB-7).
      Flexible(
        child: JamPeopleLine(
          JamPeoplePhrase.summary(names),
          style: context.jamSubheadline.copyWith(
            color: context.jamColors.secondaryLabel,
          ),
        ),
      ),
    ],
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

/// One past jam's page: the jam — its mark beside its name, what it was and
/// when, who was there — then Host Again, then the songs with who added
/// each. Laid out on the reading column's leading edge like the rest of the
/// app's pages, not as a centred album.
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

  /// This device's name, for the faces' colours ([jamRecordFaceColors]).
  String _self = '';

  /// The inline nav title appears once the name has scrolled under the bar.
  bool _titleShown = false;

  /// Where the name has scrolled under the bar: past the top of the header
  /// and most of the mark beside it.
  static const double _titleScrollThreshold =
      JamSpace.sm + JamMarkSize.ended * 0.6;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    unawaited(_loadSelf());
  }

  Future<void> _loadSelf() async {
    final name = await JamIdentity.displayName();
    if (mounted && name != _self) setState(() => _self = name);
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
    final peers = record.peerNames;
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
    // The songs credit people by face, coloured as the jam coloured them.
    final faces = jamRecordColorsByName(record, self: _self);

    // The app's one "•••": a fill circle on paper, its dots in the tint of
    // the bar's other actions.
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

    final use24 = MediaQuery.alwaysUse24HourFormatOf(context);
    final hostLabel = HistoryStrings.hostLabel(wasHost: record.wasHost);
    final header = Padding(
      padding: const EdgeInsets.symmetric(horizontal: JamSpace.page),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: JamSpace.sm),
          // One block: the mark, and beside it the jam — its name, when,
          // and who was there.
          Row(
            children: [
              JamHistoryMark(
                tracks: tracks,
                size: JamMarkSize.ended,
                name: record.sessionName,
                shadow: true,
                semanticLabel: HistoryStrings.cover(record.sessionName),
              ),
              const SizedBox(width: JamSpace.lg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Semantics(
                      header: true,
                      child: Text(
                        record.sessionName,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: context.jamTitle2,
                      ),
                    ),
                    const SizedBox(height: JamSpace.xxs),
                    Text(
                      jamHistorySummary(
                        record,
                        withCount: false,
                        use24HourFormat: use24,
                        keepTimeTogether: true,
                      ),
                      style: secondary,
                    ),
                    if (peers.isNotEmpty) ...[
                      const SizedBox(height: JamSpace.sm),
                      _People(
                        names: peers,
                        colors: jamRecordFaceColors(record, self: _self),
                        size: JamAvatarSize.attribution,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: JamSpace.xl),
          // The page's one action, filled like every other primary.
          JamButton.filled(
            label: hostLabel,
            icon: CupertinoIcons.play_fill,
            expand: true,
            // Always the same label; what is missing is said in the
            // footnote under it.
            onPressed: replayable == 0 ? null : () => unawaited(_hostAgain()),
            semanticLabel: '$hostLabel: ${record.sessionName}',
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
          const SizedBox(height: JamSpace.section),
        ],
      ),
    );

    final content = SliverList.list(
      children: [
        header,
        if (tracks.isNotEmpty) ...[
          // What played, under its own heading — the count and length
          // beside it rather than as an album's footer.
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(
              kJamRowInset,
              0,
              kJamRowInset,
              JamSpace.xs,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text(
                      HistoryStrings.songsHeader,
                      style: context.jamTitle3,
                    ),
                  ),
                ),
                const SizedBox(width: JamSpace.sm),
                Text(
                  HistoryStrings.songsAndLength(total, length),
                  style: footnote,
                ),
              ],
            ),
          ),
          for (var i = 0; i < tracks.length; i++)
            _HistoryTrackRow(
              track: tracks[i],
              separator: i < tracks.length - 1,
              faces: faces,
            ),
        ],
      ],
    );

    return JamScaffold(
      title: _titleShown ? record.sessionName : '',
      largeTitle: false,
      controller: _scroll,
      // A reading column, sized from the pane this page sits in.
      maxContentWidth: JamContentWidth.reading,
      trailing: [menu],
      slivers: [content],
    );
  }
}

/// A queue row on the detail page, with its cover read back off disk, and
/// who added it credited as the queue credits them: by face.
class _HistoryTrackRow extends StatefulWidget {
  const _HistoryTrackRow({
    required this.track,
    required this.separator,
    required this.faces,
  });

  final JamHistoryTrack track;
  final bool separator;

  /// Everyone's face colour, by name ([jamRecordColorsByName]).
  final Map<String, Color> faces;

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
    // The store writes the literal 'You' against this device's tracks.
    final you = adder == HistoryStrings.storedYou;
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
      addedByYou: you,
      // Someone else's song wears their face where the jam gave one out,
      // and says their name where it did not; your own carries no credit
      // (R3).
      addedByColor: you || adder == null ? null : widget.faces[adder],
      duration: durationUs == null ? null : Duration(microseconds: durationUs),
      // Faded is the whole signal that a track has left the device.
      dimmed: !_local,
      separator: widget.separator,
    );
  }
}
