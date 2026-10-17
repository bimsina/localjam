/// Past jams: a record has to say what it was, who was there, and whether it
/// can still be played — the last one is what makes the screen useful rather
/// than nostalgic.
///
/// Records are handed to the screen rather than read off disk: a `testWidgets`
/// body runs in a fake-async zone where real file I/O never completes, which
/// is what [HistoryScreen.loadRecords] exists for.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/design/theme.dart';
import 'package:localjam_app/src/screens/history_screen.dart';
import 'package:localjam_app/src/state/app_settings.dart';
import 'package:localjam_app/src/state/session_controller.dart';
import 'package:localjam_app/src/widgets/avatar.dart';
import 'package:localjam_app/src/widgets/buttons.dart';
import 'package:localjam_app/src/widgets/empty_state.dart';
import 'package:localjam_app/src/widgets/track_row.dart';
import 'package:localjam_client/localjam_client.dart';

import '../harness.dart';

MediaItem _item(String name, {String? artist}) => MediaItem(
  mediaId: 'm_$name',
  kind: MediaKind.audio,
  name: '$name.m4a',
  mime: 'audio/mp4',
  sizeBytes: 1024,
  sha256: 'abc',
  title: name,
  artist: artist,
);

JamHistoryRecord _record({
  required String name,
  List<JamHistoryTrack> tracks = const [],
  List<String> peers = const [],
  bool wasHost = true,
}) => JamHistoryRecord(
  sessionId: 's_$name',
  sessionName: name,
  wasHost: wasHost,
  startedAt: DateTime.now(),
  updatedAt: DateTime.now(),
  peerNames: peers,
  tracks: tracks,
);

Future<void> pumpHistory(
  WidgetTester tester,
  JamSessionController session, {
  required List<JamHistoryRecord> records,
  Future<void> Function(JamHistoryRecord)? onForget,
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
            loadRecords: () async => records,
            forgetRecord: onForget ?? (_) async {},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('an empty history says so, once, with no action', (tester) async {
    final session = testSession();
    await pumpHistory(tester, session, records: const []);

    expect(find.byType(JamEmptyState), findsOneWidget);
    expect(find.text(HistoryStrings.emptyTitle), findsOneWidget);
    // Not two competing actions — here, none at all: there is nothing to do
    // on this screen but leave it.
    expect(find.byType(JamButton), findsNothing);
  });

  testWidgets('a record says what it was and who was in it', (tester) async {
    final session = testSession();
    await pumpHistory(
      tester,
      session,
      records: [
        _record(
          name: 'Bar Room',
          peers: ['Neon Walrus', 'Amber Fox'],
          tracks: [
            JamHistoryTrack(
              item: _item('Night Bus', artist: 'Perla'),
              addedByName: 'Neon Walrus',
            ),
            JamHistoryTrack(item: _item('Slow Coast')),
          ],
        ),
      ],
    );

    expect(find.text('Bar Room'), findsOneWidget);
    expect(
      find.text('${HistoryStrings.youHosted} · ${HistoryStrings.tracks(2)}'),
      findsOneWidget,
    );
    // Faces, overlapping, not a spaced data grid.
    expect(find.byType(JamAvatarStack), findsOneWidget);
    // Tracks are the shared row, with attribution.
    expect(find.byType(JamTrackRow), findsNWidgets(2));
    expect(find.text('Night Bus'), findsOneWidget);
    // No raw filenames or paths anywhere.
    expect(find.textContaining('.m4a'), findsNothing);
  });

  testWidgets('only the first three tracks are listed, the rest counted', (
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

    expect(find.byType(JamTrackRow), findsNWidgets(3));
    expect(find.text(HistoryStrings.more(3)), findsOneWidget);
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

    final hostAgain = tester.widget<JamButton>(
      find.widgetWithText(JamButton, HistoryStrings.hostAgain),
    );
    expect(hostAgain.onPressed, isNull);
    // Disabled, and the footnote says why rather than leaving a dead button.
    expect(find.text(HistoryStrings.noneLeft), findsOneWidget);
  });

  testWidgets('forgetting a jam asks first, and takes no for an answer', (
    tester,
  ) async {
    final session = testSession();
    var forgotten = 0;
    await pumpHistory(
      tester,
      session,
      records: [_record(name: 'Bar Room')],
      onForget: (_) async => forgotten++,
    );

    await tester.tap(find.text(HistoryStrings.forget));
    await tester.pumpAndSettle();
    expect(find.text(HistoryStrings.forgetTitle), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(forgotten, 0);
    expect(find.text('Bar Room'), findsOneWidget);
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
}
