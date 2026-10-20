/// Past Jams: a record has to say what it was, who was there, and whether it
/// can still be played — the last one is what makes the screen useful rather
/// than nostalgic.
///
/// Records are handed to the screen rather than read off disk: a `testWidgets`
/// body runs in a fake-async zone where real file I/O never completes, which
/// is what [HistoryScreen.loadRecords] exists for.
library;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/design/theme.dart';
import 'package:localjam_app/src/design/tokens.dart';
import 'package:localjam_app/src/screens/history_screen.dart';
import 'package:localjam_app/src/state/app_settings.dart';
import 'package:localjam_app/src/state/session_controller.dart';
import 'package:localjam_app/src/widgets/artwork.dart';
import 'package:localjam_app/src/widgets/avatar.dart';
import 'package:localjam_app/src/widgets/buttons.dart';
import 'package:localjam_app/src/widgets/empty_state.dart';
import 'package:localjam_app/src/widgets/jam_mark.dart';
import 'package:localjam_app/src/widgets/list.dart';
import 'package:localjam_app/src/widgets/menu.dart';
import 'package:localjam_app/src/widgets/track_row.dart';
import 'package:localjam_client/localjam_client.dart';

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
  DateTime? at,
}) => JamHistoryRecord(
  sessionId: 's_$name',
  sessionName: name,
  wasHost: wasHost,
  startedAt: at ?? DateTime.now(),
  updatedAt: at ?? DateTime.now(),
  peerNames: peers,
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
    // Who was there: their faces, then their names.
    expect(find.text('With Neon Walrus and Amber Fox'), findsOneWidget);
    final pile = tester.widget<JamAvatarStack>(find.byType(JamAvatarStack));
    expect(pile.names, ['Neon Walrus', 'Amber Fox']);
    expect(find.byType(JamDisclosureChevron), findsOneWidget);
    // The jam's mark, at a Past Jams row's size — with no face on it.
    final mark = tester.widget<JamHistoryMark>(find.byType(JamHistoryMark));
    expect(mark.size, JamMarkSize.row);
    expect(mark.name, 'Bar Room');
    expect(tester.widget<JamMark>(find.byType(JamMark)).hostName, isNull);
    // One node that says it all, and opens the jam.
    expect(
      find.bySemanticsLabel(
        RegExp(r'^Bar Room\. With Neon Walrus and Amber Fox\. You hosted'),
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
    expect(pile.names, ['Mia', 'Theo', 'Ana']);
    // No "+1" beside "and 2 others".
    expect(find.text('+1'), findsNothing);
    expect(find.text('With Mia, Theo and 2 others'), findsOneWidget);
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

  test('faces wear the colours the jam gave them (D3)', () {
    // Hosted here: this device was the host, so it kept its colour and the
    // others moved around it in name order — what the room's faces did.
    final hosted = _record(name: 'Van Jam', peers: ['Theo', 'Mia']);
    final room = jamPeopleColors(['Bibek', 'Theo', 'Mia'], host: 'Bibek');
    expect(jamRecordFaceColors(hosted, self: 'Bibek'), [
      room['Theo'],
      room['Mia'],
    ]);
    // Joined: the record does not say who hosted, so name order alone —
    // with this device still counted.
    final joined = _record(
      name: 'Van Jam',
      peers: ['Theo', 'Mia'],
      wasHost: false,
    );
    final named = jamPeopleColors(['Mia', 'Theo', 'Bibek']);
    expect(jamRecordFaceColors(joined, self: 'Bibek'), [
      named['Theo'],
      named['Mia'],
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
    final people = tester.getRect(find.text('With Neon Walrus and Amber Fox'));
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
    expect(find.text('With Neon Walrus and Amber Fox'), findsOneWidget);
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
