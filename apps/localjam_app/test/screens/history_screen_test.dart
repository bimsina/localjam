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
import 'package:localjam_app/src/screens/history_screen.dart';
import 'package:localjam_app/src/state/app_settings.dart';
import 'package:localjam_app/src/state/session_controller.dart';
import 'package:localjam_app/src/widgets/artwork.dart';
import 'package:localjam_app/src/widgets/buttons.dart';
import 'package:localjam_app/src/widgets/empty_state.dart';
import 'package:localjam_app/src/widgets/list.dart';
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

  testWidgets('a record is one plain row: cover, name, summary, chevron', (
    tester,
  ) async {
    final session = testSession();
    await pumpHistory(tester, session, records: [_barRoom()]);

    expect(find.text('Bar Room'), findsOneWidget);
    expect(
      find.text(
        '${HistoryStrings.youHosted} · ${HistoryStrings.songs(2)} · '
        '${HistoryStrings.justNow}',
      ),
      findsOneWidget,
    );
    final row = tester.widget<JamRow>(find.byType(JamRow));
    expect(row.chevron, isTrue);
    final mosaic = tester.widget<JamArtworkMosaic>(
      find.byType(JamArtworkMosaic),
    );
    expect(mosaic.size, 56);
    // The queue lives on the detail page, not in the list.
    expect(find.byType(JamTrackRow), findsNothing);
    expect(find.textContaining('.m4a'), findsNothing);
  });

  testWidgets('without four real covers the art is one tile, not a grid', (
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

    // No cover on this device: the plain placeholder, not four ghosts.
    expect(
      find.descendant(
        of: find.byType(JamArtworkMosaic),
        matching: find.byType(JamArtworkTile),
      ),
      findsOneWidget,
    );
  });

  testWidgets('tapping a record opens its detail page', (tester) async {
    final session = testSession();
    await pumpHistory(tester, session, records: [_barRoom()]);

    await tester.tap(find.text('Bar Room'));
    await tester.pumpAndSettle();

    expect(find.byType(HistoryDetailScreen), findsOneWidget);
    // Cover 200, name, summary, people, Host Again, the queue.
    final mosaic = tester.widget<JamArtworkMosaic>(
      find.byType(JamArtworkMosaic),
    );
    expect(mosaic.size, 200);
    expect(find.text('Bar Room'), findsOneWidget);
    expect(
      find.text('${HistoryStrings.youHosted} · ${HistoryStrings.justNow}'),
      findsOneWidget,
    );
    expect(find.text('With Neon Walrus and Amber Fox'), findsOneWidget);
    expect(
      find.widgetWithText(JamButton, HistoryStrings.hostAgain),
      findsOneWidget,
    );
    // No rule above the first song: the one hairline left is the separator
    // between the two rows.
    expect(find.byType(JamHairline), findsOneWidget);
    expect(find.byType(JamTrackRow), findsNWidgets(2));
    expect(find.text('Added by Neon Walrus · 3:42'), findsOneWidget);
    expect(find.text('Added by you · 3:00'), findsOneWidget);
    final footer = find.text(
      HistoryStrings.songsAndLength(2, const Duration(seconds: 402)),
    );
    await tester.scrollUntilVisible(footer, 100);
    expect(footer, findsOneWidget);
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

  testWidgets('a jam you joined offers "Host This Jam", not "Host Again"', (
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
