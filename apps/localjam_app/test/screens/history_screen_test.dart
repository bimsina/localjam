/// Past Jams: a record has to say what it was, who was there, and whether it
/// can still be played — the last one is what makes the screen useful rather
/// than nostalgic.
///
/// Records are handed to the screen rather than read off disk: a `testWidgets`
/// body runs in a fake-async zone where real file I/O never completes, which
/// is what [HistoryScreen.loadRecords] exists for.
library;

import 'dart:convert' show ascii;
import 'dart:io';
import 'dart:typed_data';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/design/theme.dart';
import 'package:localjam_app/src/design/tokens.dart';
import 'package:localjam_app/src/screens/history_screen.dart';
import 'package:localjam_app/src/screens/home_screen.dart';
import 'package:localjam_app/src/state/app_settings.dart';
import 'package:localjam_app/src/state/session_controller.dart';
import 'package:localjam_app/src/util/network.dart';
import 'package:localjam_app/src/widgets/artwork.dart';
import 'package:localjam_app/src/widgets/avatar.dart';
import 'package:localjam_app/src/widgets/buttons.dart';
import 'package:localjam_app/src/widgets/empty_state.dart';
import 'package:localjam_app/src/widgets/jam_mark.dart';
import 'package:localjam_app/src/widgets/list.dart';
import 'package:localjam_app/src/widgets/menu.dart';
import 'package:localjam_app/src/widgets/track_row.dart';
import 'package:localjam_client/localjam_client.dart';
import 'package:material_ui/material_ui.dart';

import '../harness.dart';

MediaItem _item(String name, {String? artist, int? seconds}) => MediaItem(
  mediaId: 'm_$name',
  kind: MediaKind.audio,
  name: '$name.m4a',
  mime: 'audio/mp4',
  sizeBytes: 1024,
  sha256: 'abc',
  title: name,
  artist: artist,
  durationUs: seconds == null ? null : seconds * 1000000,
);

JamHistoryRecord _record({
  required String name,
  List<JamHistoryTrack> tracks = const [],
  List<String> peers = const [],
  bool wasHost = true,
  String? host,
  DateTime? at,
}) => JamHistoryRecord(
  sessionId: 's_$name',
  sessionName: name,
  wasHost: wasHost,
  startedAt: at ?? DateTime.now(),
  updatedAt: at ?? DateTime.now(),
  peerNames: peers,
  hostName: host,
  tracks: tracks,
);

Future<void> pumpHistory(
  WidgetTester tester,
  JamSessionController session, {
  required List<JamHistoryRecord> records,
  Future<void> Function(JamHistoryRecord)? onForget,
  Future<void> Function(JamHistoryRecord)? onRestore,
  List<JamHistoryRecord> Function()? reload,
  ThemeData? theme,
}) async {
  await tester.pumpWidget(
    JamSettings(
      settings: JamAppSettings(),
      child: JamSession(
        controller: session,
        child: MaterialApp(
          theme: theme ?? jamLightTheme(),
          home: HistoryScreen(
            loadRecords: () async => reload?.call() ?? records,
            forgetRecord: onForget ?? (_) async {},
            restoreRecord: onRestore ?? (_) async {},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

JamHistoryRecord _barRoom() => _record(
  name: 'Bar Room',
  peers: ['Neon Walrus', 'Amber Fox'],
  tracks: [
    JamHistoryTrack(
      item: _item('Night Bus', artist: 'Perla', seconds: 222),
      addedByName: 'Neon Walrus',
    ),
    JamHistoryTrack(
      item: _item('Slow Coast', seconds: 180),
      addedByName: 'You',
    ),
  ],
);

void main() {
  testWidgets('an empty history says so, once, with no action', (tester) async {
    final session = testSession();
    await pumpHistory(tester, session, records: const []);

    expect(find.text(HistoryStrings.title), findsWidgets);
    expect(find.byType(JamEmptyState), findsOneWidget);
    expect(find.text(HistoryStrings.emptyTitle), findsOneWidget);
    expect(find.text(HistoryStrings.emptyBody), findsOneWidget);
    // Nothing to do on this screen but leave it.
    expect(find.byType(JamButton), findsNothing);
  });

  testWidgets('a record is one row drawn as a jam: mark, name, people, '
      'summary, chevron', (tester) async {
    final session = testSession();
    await pumpHistory(tester, session, records: [_barRoom()]);

    expect(find.text('Bar Room'), findsOneWidget);
    // The jam's name in Manrope, like every other place a jam is named —
    // at row scale, as Nearby's rows: 17 bold, not a heading.
    final name = tester.widget<Text>(find.text('Bar Room'));
    expect(name.style?.fontFamily, 'Manrope');
    expect(name.style?.fontSize, 17);
    expect(name.style?.fontWeight, FontWeight.w700);
    expect(name.maxLines, 2);
    // The "when" is held together, so "PM" never wraps onto a line alone.
    expect(
      find.text(
        '${HistoryStrings.youHosted} · ${HistoryStrings.songs(2)} · '
        '${HistoryStrings.justNow.replaceAll(' ', kJamNoBreakSpace)}',
      ),
      findsOneWidget,
    );
    // Who was there: their faces, then their names — by name, the one
    // people order (N7), whatever order the record kept them in.
    expect(find.text('With Amber Fox and Neon Walrus'), findsOneWidget);
    final pile = tester.widget<JamAvatarStack>(find.byType(JamAvatarStack));
    expect(pile.names, ['Amber Fox', 'Neon Walrus']);
    expect(find.byType(JamDisclosureChevron), findsOneWidget);
    // The jam's mark, at a Past Jams row's size — with no face on it.
    final mark = tester.widget<JamHistoryMark>(find.byType(JamHistoryMark));
    expect(mark.size, JamMarkSize.row);
    expect(mark.name, 'Bar Room');
    expect(tester.widget<JamMark>(find.byType(JamMark)).hostName, isNull);
    // One node that says it all, and opens the jam.
    expect(
      find.bySemanticsLabel(
        RegExp(r'^Bar Room\. With Amber Fox and Neon Walrus\. You hosted'),
      ),
      findsOneWidget,
    );
    // The queue lives on the detail page, not in the list.
    expect(find.byType(JamTrackRow), findsNothing);
    expect(find.textContaining('.m4a'), findsNothing);
  });

  testWidgets('a past jam with no cover here is its monogram, not a note', (
    tester,
  ) async {
    final session = testSession();
    await pumpHistory(
      tester,
      session,
      records: [
        _record(
          name: 'Long Jam',
          tracks: [
            for (var i = 0; i < 6; i++) JamHistoryTrack(item: _item('T$i')),
          ],
        ),
      ],
    );

    // No cover on this device: the jam's own letter, not four ghosts and
    // not the placeholder a song without art gets.
    final mark = tester.widget<JamMark>(find.byType(JamMark));
    expect(mark.cover, isNull);
    expect(find.text('L'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(JamHistoryMark),
        matching: find.byType(JamArtworkTile),
      ),
      findsNothing,
    );
  });

  testWidgets('more than three people: three faces, and the names count the '
      'rest', (tester) async {
    final session = testSession();
    await pumpHistory(
      tester,
      session,
      records: [
        _record(name: 'Van Jam', peers: ['Mia', 'Theo', 'Ana', 'Jo']),
      ],
    );
    final pile = tester.widget<JamAvatarStack>(find.byType(JamAvatarStack));
    expect(pile.names, ['Ana', 'Jo', 'Mia']);
    // No "+1" beside "and 2 others".
    expect(find.text('+1'), findsNothing);
    expect(find.text('With Ana, Jo and 2 others'), findsOneWidget);
  });

  testWidgets('a long name is cut before the count is (RB-7)', (tester) async {
    final session = testSession();
    await pumpHistory(
      tester,
      session,
      records: [
        _record(
          name: 'Van Jam',
          peers: [
            'Electric Mongoose Supreme',
            'Theo',
            'Ana',
            'Jo',
            'Okon',
            'Priya',
          ],
        ),
      ],
    );
    // The line is too narrow for the whole phrase: the long name gives way
    // and the count stays whole.
    expect(
      find.text('With Electric Mongoose Supreme, Theo and 4 others'),
      findsNothing,
    );
    expect(find.text(' and 4 others'), findsOneWidget);
    // The long name, cut, ends in its own ellipsis with nothing before it.
    final cut = find.byWidgetPredicate((w) {
      final text = w is Text ? w.data ?? '' : '';
      return text.length > 1 &&
          text.endsWith('…') &&
          !text.endsWith(' …') &&
          'Electric Mongoose Supreme'.startsWith(
            text.substring(0, text.length - 1),
          );
    });
    expect(cut, findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('faces wear the colours the jam gave them (D3): each their name\'s '
      'own', () {
    final hosted = _record(name: 'Van Jam', peers: ['Theo', 'Mia']);
    expect(jamRecordFaceColors(hosted, self: 'Bibek'), [
      identityColor('Mia'),
      identityColor('Theo'),
    ]);
    // Joined: the host first in the row, as in the room — in their own
    // colour, as in the room.
    final joined = _record(
      name: 'Van Jam',
      peers: ['Theo', 'Mia', 'Zoe'],
      wasHost: false,
      host: 'Zoe',
    );
    expect(jamRecordPeople(joined), ['Zoe', 'Mia', 'Theo']);
    expect(jamRecordFaceColors(joined, self: 'Bibek'), [
      identityColor('Zoe'),
      identityColor('Mia'),
      identityColor('Theo'),
    ]);
    expect(
      jamRecordColorsByName(joined, self: 'Bibek'),
      jamPeopleColors(['Bibek', 'Zoe', 'Theo', 'Mia']),
    );
  });

  testWidgets('a jam you joined lists its host first, in the colour the '
      'room gave them — in Past jams and on its page', (tester) async {
    final session = testSession();
    final joined = _record(
      name: 'Late Shift',
      peers: ['Mia', 'Amber Fox', 'Zed'],
      wasHost: false,
      host: 'Zed',
    );
    await pumpHistory(tester, session, records: [joined]);

    final room = jamRecordColorsByName(joined, self: 'Silky Puffin');
    expect(room, jamPeopleColors(['Silky Puffin', 'Zed', 'Amber Fox', 'Mia']));
    void expectHostFirst() {
      expect(find.text('With Zed, Amber Fox and Mia'), findsOneWidget);
      final pile = tester.widget<JamAvatarStack>(find.byType(JamAvatarStack));
      expect(pile.names, ['Zed', 'Amber Fox', 'Mia']);
      expect(pile.colors, [room['Zed'], room['Amber Fox'], room['Mia']]);
    }

    expectHostFirst();
    await tester.tap(find.text('Late Shift'));
    await tester.pumpAndSettle();
    expect(find.byType(HistoryDetailScreen), findsOneWidget);
    expectHostFirst();
  });

  testWidgets('a jam you hosted lists the others by name: the host was you', (
    tester,
  ) async {
    final session = testSession();
    await pumpHistory(
      tester,
      session,
      records: [
        _record(
          name: 'Our Jam',
          peers: ['Mia', 'Amber Fox', 'Zed'],
          // Even a stray host name on a hosted record puts nobody first.
          host: 'Zed',
        ),
      ],
    );
    expect(find.text('With Amber Fox, Mia and Zed'), findsOneWidget);
  });

  testWidgets('Home\'s Recent puts the host first too', (tester) async {
    final session = testSession();
    await tester.pumpWidget(
      JamSession(
        controller: session,
        child: MaterialApp(
          theme: jamLightTheme(),
          home: HomeScreen(
            networkReader: () async => const JamNetworkStatus(
              addresses: ['192.168.1.20'],
              interface: 'en0',
            ),
            loadRecords: () async => [
              _record(
                name: 'Late Shift',
                peers: ['Mia', 'Amber Fox', 'Zed'],
                wasHost: false,
                host: 'Zed',
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(JamHistoryRow), findsOneWidget);
    expect(find.text('With Zed, Amber Fox and Mia'), findsOneWidget);
    expect(tester.widget<JamAvatarStack>(find.byType(JamAvatarStack)).names, [
      'Zed',
      'Amber Fox',
      'Mia',
    ]);
  });

  testWidgets('tapping a record opens its detail page', (tester) async {
    final session = testSession();
    await pumpHistory(tester, session, records: [_barRoom()]);

    await tester.tap(find.text('Bar Room'));
    await tester.pumpAndSettle();

    expect(find.byType(HistoryDetailScreen), findsOneWidget);
    // The jam's mark, and beside it — one block — its name, when and who
    // was there; then Host Again, then the songs under their own heading.
    final mark = tester.widget<JamHistoryMark>(find.byType(JamHistoryMark));
    expect(mark.size, JamMarkSize.ended);
    expect(mark.name, 'Bar Room');
    expect(find.text('Bar Room'), findsOneWidget);
    final markRect = tester.getRect(find.byType(JamHistoryMark));
    final people = tester.getRect(find.text('With Amber Fox and Neon Walrus'));
    expect(people.left, greaterThan(markRect.right));
    expect(
      people.left,
      tester.getRect(find.byType(JamAvatarStack)).right + JamSpace.sm,
    );
    expect(
      tester.widget<JamAvatarStack>(find.byType(JamAvatarStack)).size,
      JamAvatarSize.attribution,
    );
    expect(
      find.text(
        '${HistoryStrings.youHosted} · '
        '${HistoryStrings.justNow.replaceAll(' ', kJamNoBreakSpace)}',
      ),
      findsOneWidget,
    );
    expect(find.text('With Amber Fox and Neon Walrus'), findsOneWidget);
    expect(find.byType(JamAvatarStack), findsOneWidget);
    // The page's one action is a filled primary, like every other.
    final hostAgain = tester.widget<JamButton>(
      find.widgetWithText(JamButton, HistoryStrings.hostAgain),
    );
    expect(hostAgain.variant, JamButtonVariant.filled);
    expect(find.text(HistoryStrings.songsHeader), findsOneWidget);
    // The count and length beside the heading, not as an album's footer.
    expect(
      find.text(HistoryStrings.songsAndLength(2, const Duration(seconds: 402))),
      findsOneWidget,
    );
    // No rule above the first song: the one hairline left is the separator
    // between the two rows.
    expect(find.byType(JamHairline), findsOneWidget);
    // Who added each song, credited as the queue credits them: by face, in
    // the colour the jam gave them.
    final rows = tester
        .widgetList<JamTrackRow>(find.byType(JamTrackRow, skipOffstage: false))
        .toList();
    final faces = jamRecordColorsByName(_barRoom(), self: 'Silky Puffin');
    expect(rows[0].addedByName, 'Neon Walrus');
    expect(rows[0].addedByColor, faces['Neon Walrus']);
    expect(rows[1].addedByYou, isTrue);
    // Your own song carries no credit, so no face to colour (R3).
    expect(rows[1].addedByColor, isNull);
    // Song rows are two lines (R3): the artist and the length; a credit is
    // a face, and only for someone else's song.
    expect(find.text('Perla · 3:42'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('3:00'), 80);
    expect(find.text('3:00'), findsOneWidget);
  });

  testWidgets('on a phone the "more" circle ends on the page margin, where '
      'Host again does', (tester) async {
    tester.view.physicalSize = const Size(402, 874);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final session = testSession();
    await pumpHistory(tester, session, records: [_barRoom()]);
    await tester.tap(find.text('Bar Room'));
    await tester.pumpAndSettle();
    final circle = find.descendant(
      of: find.byType(JamMenuButton),
      matching: find.byWidgetPredicate(
        (w) =>
            w is DecoratedBox &&
            w.decoration is ShapeDecoration &&
            (w.decoration as ShapeDecoration).shape is CircleBorder,
      ),
    );
    expect(
      tester.getRect(circle).right,
      closeTo(
        tester
            .getRect(find.widgetWithText(JamButton, HistoryStrings.hostAgain))
            .right,
        0.5,
      ),
    );
  });

  testWidgets('a record whose files are gone cannot be re-hosted', (
    tester,
  ) async {
    final session = testSession();
    await pumpHistory(
      tester,
      session,
      records: [
        _record(
          name: 'Gone Jam',
          tracks: [
            JamHistoryTrack(
              item: _item('Night Bus'),
              localPath: '/nowhere/not-here.m4a',
            ),
          ],
        ),
      ],
    );
    await tester.tap(find.text('Gone Jam'));
    await tester.pumpAndSettle();

    final hostAgain = tester.widget<JamButton>(
      find.widgetWithText(JamButton, HistoryStrings.hostAgain),
    );
    expect(hostAgain.onPressed, isNull);
    // Disabled, and the footnote says why rather than leaving a dead button.
    expect(find.text(HistoryStrings.noneLeft), findsOneWidget);
  });

  testWidgets('a swipe forgets at once, with no second question, and '
      'offers Undo', (tester) async {
    final session = testSession();
    final store = [_record(name: 'Bar Room'), _record(name: 'Van Jam')];
    final notices = <JamNotice>[];
    final sub = session.notices.listen(notices.add);
    addTearDown(sub.cancel);
    await pumpHistory(
      tester,
      session,
      records: store,
      reload: () => [...store],
      onForget: (r) async =>
          store.removeWhere((x) => x.sessionId == r.sessionId),
      onRestore: (r) async => store.insert(0, r),
    );

    await tester.drag(find.text('Bar Room'), const Offset(-120, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.text(HistoryStrings.forget));
    await tester.pumpAndSettle();

    // Mail / Notes: the swipe was the decision.
    expect(find.text(HistoryStrings.forgetTitle), findsNothing);
    expect(find.text('Bar Room'), findsNothing);
    expect(find.text('Van Jam'), findsOneWidget);
    expect(store.map((r) => r.sessionName), ['Van Jam']);

    final notice = notices.single;
    expect(notice.message, HistoryStrings.forgotten('Bar Room'));
    expect(notice.actionLabel, HistoryStrings.undo);
    expect(notice.tone, JamNoticeTone.neutral);

    notice.onAction!();
    await tester.pumpAndSettle();
    expect(find.text('Bar Room'), findsOneWidget);
    expect(store.map((r) => r.sessionName), ['Bar Room', 'Van Jam']);
  });

  testWidgets('Forget from the detail page menu pops back to the list', (
    tester,
  ) async {
    final session = testSession();
    final forgotten = <String>[];
    final records = [_barRoom()];
    await tester.pumpWidget(
      JamSettings(
        settings: JamAppSettings(),
        child: JamSession(
          controller: session,
          child: MaterialApp(
            theme: jamLightTheme(),
            home: HistoryScreen(
              loadRecords: () async => [...records],
              forgetRecord: (r) async {
                forgotten.add(r.sessionName);
                records.removeWhere((x) => x.sessionId == r.sessionId);
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Bar Room'));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel(HistoryStrings.more));
    await tester.pumpAndSettle();
    await tester.tap(find.text(HistoryStrings.forget).last);
    await tester.pumpAndSettle();
    expect(find.text(HistoryStrings.forgetTitle), findsOneWidget);
    await tester.tap(find.text(HistoryStrings.forgetConfirm).last);
    await tester.pumpAndSettle();

    expect(forgotten, ['Bar Room']);
    expect(find.byType(HistoryDetailScreen), findsNothing);
    expect(find.text(HistoryStrings.emptyTitle), findsOneWidget);
  });

  testWidgets('renders on the dark palette', (tester) async {
    final session = testSession();
    await pumpHistory(
      tester,
      session,
      records: [_record(name: 'Night Jam')],
      theme: jamDarkTheme(),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Night Jam'), findsOneWidget);
  });

  testWidgets('nothing clips at 1.3× text', (tester) async {
    final session = testSession();
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await pumpHistory(tester, session, records: [_barRoom()]);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Bar Room'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('a jam you joined offers "Host this jam", not "Host again"', (
    tester,
  ) async {
    final session = testSession();
    await pumpHistory(
      tester,
      session,
      records: [
        _record(
          name: 'Van Jam',
          wasHost: false,
          tracks: [JamHistoryTrack(item: _item('Night Bus'))],
        ),
      ],
    );
    await tester.tap(find.text('Van Jam'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(JamButton, HistoryStrings.hostThis), findsOne);
    expect(find.text(HistoryStrings.hostAgain), findsNothing);
  });

  group('jamRelativeTime', () {
    final now = DateTime(2026, 10, 18, 15);
    test('reads like Apple does', () {
      expect(jamRelativeTime(now, now: now), HistoryStrings.justNow);
      // Two jams in one evening must not read as the same row twice.
      expect(
        jamRelativeTime(DateTime(2026, 10, 18, 9, 5), now: now),
        'Today, 9:05 AM',
      );
      expect(
        jamRelativeTime(DateTime(2026, 10, 18, 13, 52), now: now),
        'Today, 1:52 PM',
      );
      expect(
        jamRelativeTime(DateTime(2026, 10, 17, 23), now: now),
        'Yesterday, 11:00 PM',
      );
      expect(
        jamRelativeTime(
          DateTime(2026, 10, 17, 0, 30),
          now: now,
          use24HourFormat: true,
        ),
        'Yesterday, 00:30',
      );
      expect(jamRelativeTime(DateTime(2026, 10, 14), now: now), 'Wednesday');
      expect(jamRelativeTime(DateTime(2026, 9, 2), now: now), 'Sep 2');
      expect(jamRelativeTime(DateTime(2025, 12, 31), now: now), 'Dec 31, 2025');
    });
  });

  test('a drawn summary keeps its "when" on one line', () {
    final now = DateTime(2026, 10, 18, 15);
    final record = _record(
      name: 'Bar Room',
      at: DateTime(2026, 10, 17, 17),
      tracks: [JamHistoryTrack(item: _item('Night Bus'))],
    );
    // For matching, plain spaces; for drawing, "Yesterday, 5:00 PM" moves
    // to the next line whole rather than leaving "PM" there alone.
    expect(
      jamHistorySummary(record, now: now),
      'You hosted · 1 song · Yesterday, 5:00 PM',
    );
    expect(
      jamHistorySummary(record, now: now, keepTimeTogether: true),
      'You hosted · 1 song · Yesterday,\u00A05:00\u00A0PM',
    );
  });

  test('summaries count songs, not tracks', () {
    expect(HistoryStrings.songs(1), '1 song');
    expect(
      HistoryStrings.songsAndLength(12, const Duration(minutes: 48)),
      '12 songs, 48 minutes',
    );
    expect(
      HistoryStrings.withPeople(['Mia', 'Neon Walrus', 'Amber Fox', 'Jo']),
      'With Mia, Neon Walrus and 2 others',
    );
    // One person left over is named, not counted — as on the Invite sheet.
    expect(
      HistoryStrings.withPeople(['Mia', 'Theo', 'Ana']),
      'With Mia, Theo and Ana',
    );
  });

  group('a past jam\'s cover', () {
    late Directory dir;
    setUp(() {
      debugResetJamHistoryCovers();
      dir = Directory.systemTemp.createTempSync('history_cover');
    });
    tearDown(() => dir.deleteSync(recursive: true));

    /// A song file with [cover] as its embedded art.
    String song(String name, Uint8List cover) {
      final file = File('${dir.path}/$name.mp3')
        ..writeAsBytesSync(_mp3WithCover(cover));
      return file.path;
    }

    /// The picture a record keeps.
    String kept(Uint8List cover) {
      final file = File('${dir.path}/s_jam.cover.png')..writeAsBytesSync(cover);
      return file.path;
    }

    JamHistoryRecord jam(List<JamHistoryTrack> tracks, {String? coverPath}) =>
        JamHistoryRecord(
          sessionId: 's_jam',
          sessionName: 'Cover Jam',
          wasHost: true,
          startedAt: DateTime.now(),
          updatedAt: DateTime.now(),
          tracks: tracks,
          coverFile: coverPath == null ? null : 's_jam.cover.png',
          coverMediaId: coverPath == null ? null : 'm_first',
          coverPath: coverPath,
        );

    JamHistoryTrack track(String id, {String? art, String? path}) =>
        JamHistoryTrack(
          item: MediaItem(
            mediaId: 'm_$id',
            kind: MediaKind.audio,
            name: '$id.mp3',
            mime: 'audio/mpeg',
            sizeBytes: 1024,
            sha256: 'abc',
            title: id,
            artworkId: art,
          ),
          localPath: path,
        );

    /// The bytes the row's mark shows once the reads (real file I/O) are
    /// done, or null for the monogram.
    Future<Uint8List?> shown(WidgetTester tester) async {
      for (var i = 0; i < 40; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
        if (tester.widget<JamMark>(find.byType(JamMark)).cover != null) break;
      }
      final cover = tester.widget<JamMark>(find.byType(JamMark)).cover;
      if (cover == null) return null;
      return ((cover as ResizeImage).imageProvider as MemoryImage).bytes;
    }

    testWidgets('its first song\'s own file comes first', (tester) async {
      final record = jam([
        track('first', art: 'a_1', path: song('first', _png(1))),
      ], coverPath: kept(_png(2)));
      await pumpHistory(tester, testSession(), records: [record]);
      expect(await shown(tester), _png(1));
    });

    testWidgets('with that song gone, the picture its record kept — not a '
        'later song\'s', (tester) async {
      final record = jam([
        track('first', art: 'a_1', path: '${dir.path}/gone.mp3'),
        track('later', art: 'a_3', path: song('later', _png(3))),
      ], coverPath: kept(_png(2)));
      await pumpHistory(tester, testSession(), records: [record]);
      expect(await shown(tester), _png(2));
    });

    testWidgets('with no picture kept, the first song still here with a '
        'cover, as before', (tester) async {
      final record = jam([
        track('first', art: 'a_1', path: '${dir.path}/gone.mp3'),
        track('later', art: 'a_3', path: song('later', _png(3))),
      ], coverPath: '${dir.path}/s_jam.cover.png');
      await pumpHistory(tester, testSession(), records: [record]);
      expect(await shown(tester), _png(3));
    });

    testWidgets('with nothing left at all, its monogram', (tester) async {
      final record = jam([
        track('first', art: 'a_1', path: '${dir.path}/gone.mp3'),
      ], coverPath: '${dir.path}/s_jam.cover.png');
      await pumpHistory(tester, testSession(), records: [record]);
      expect(await shown(tester), isNull);
      expect(find.text('C'), findsOneWidget);
    });

    testWidgets('the jam\'s page draws the kept picture '
        'too', (tester) async {
      final record = jam([
        track('first', art: 'a_1', path: '${dir.path}/gone.mp3'),
      ], coverPath: kept(_png(2)));
      await pumpHistory(tester, testSession(), records: [record]);
      expect(await shown(tester), _png(2));
      await tester.tap(find.text('Cover Jam'));
      await tester.pumpAndSettle();
      final page = find.descendant(
        of: find.byType(HistoryDetailScreen),
        matching: find.byType(JamMark),
      );
      final cover = tester.widget<JamMark>(page).cover! as ResizeImage;
      expect((cover.imageProvider as MemoryImage).bytes, _png(2));
    });
  });

  // Keeps the Cupertino import honest: the detail page is pushed with a
  // Cupertino route (edge swipe back on every platform).
  testWidgets('the detail page is a Cupertino route', (tester) async {
    final session = testSession();
    await pumpHistory(tester, session, records: [_barRoom()]);
    await tester.tap(find.text('Bar Room'));
    await tester.pumpAndSettle();
    final route = ModalRoute.of(
      tester.element(find.byType(HistoryDetailScreen)),
    );
    expect(route, isA<CupertinoPageRoute<bool>>());
    await tester.pumpAndSettle();
  });
}

/// A 1×1 PNG, told apart by [n] bytes after its end (decoders ignore them).
Uint8List _png(int n) => Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, //
  0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53, 0xDE, 0x00, 0x00, 0x00, //
  0x0C, 0x49, 0x44, 0x41, 0x54, 0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00, //
  0x00, 0x00, 0x03, 0x00, 0x01, 0x9E, 0xDE, 0x81, 0x4A, 0x00, 0x00, 0x00, //
  0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82, //
  ...List<int>.filled(n, n),
]);

/// A minimal MP3 (ID3v2.3 with [cover] as its front cover, then two silent
/// frames) — what a song file with art looks like to `readAudioTags`.
Uint8List _mp3WithCover(Uint8List cover) {
  List<int> be32(int v) => [
    v >> 24 & 0xFF,
    v >> 16 & 0xFF,
    v >> 8 & 0xFF,
    v & 0xFF,
  ];
  List<int> syncsafe(int v) => [
    v >> 21 & 0x7F,
    v >> 14 & 0x7F,
    v >> 7 & 0x7F,
    v & 0x7F,
  ];
  final picture = [0, ...ascii.encode('image/png'), 0, 3, 0, ...cover];
  final frame = [0xFF, 0xFB, 0x90, 0x64, ...List.filled(413, 0)];
  return Uint8List.fromList([
    ...ascii.encode('ID3'), 3, 0, 0, //
    ...syncsafe(10 + picture.length),
    ...ascii.encode('APIC'), ...be32(picture.length), 0, 0,
    ...picture,
    ...frame,
    ...frame,
  ]);
}
