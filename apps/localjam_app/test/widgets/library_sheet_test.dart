/// The Android library picker: Apple Music's "Add Songs" sheet.
library;

import 'package:flutter/cupertino.dart' show CupertinoSearchTextField;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/design/theme.dart';
import 'package:localjam_app/src/widgets/buttons.dart';
import 'package:localjam_app/src/widgets/library_sheet.dart';
import 'package:localjam_app/src/widgets/track_row.dart';
import 'package:localjam_client/localjam_client.dart';

const _tracks = [
  JamLibraryTrack(
    id: 1,
    title: 'Low Tide',
    artist: 'Harbour Kids',
    durationMs: 200000,
    sizeBytes: 1,
    contentUri: 'content://media/1',
  ),
  JamLibraryTrack(
    id: 2,
    title: 'Neon Afterglow.m4a',
    sizeBytes: 1,
    contentUri: 'content://media/2',
  ),
];

Future<void> _pump(WidgetTester tester, {bool dark = false}) {
  final theme = dark ? jamDarkTheme() : jamLightTheme();
  return tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: const Scaffold(body: JamLibraryPicker(tracks: _tracks)),
    ),
  );
}

void main() {
  testWidgets('rows carry title, artist and length; the count is sentence '
      'case; selecting retitles the sheet', (tester) async {
    await _pump(tester);
    expect(find.byType(JamTrackRow), findsNWidgets(2));
    expect(find.text('Low Tide'), findsOneWidget);
    expect(find.text('Neon Afterglow'), findsOneWidget);
    expect(find.textContaining('Harbour Kids'), findsOneWidget);
    expect(find.text(LibrarySheetStrings.available(2)), findsOneWidget);
    expect(LibrarySheetStrings.available(2), '2 songs');

    await tester.tap(find.text('Low Tide'));
    await tester.pump();
    expect(find.text(LibrarySheetStrings.selectedCount(1)), findsOneWidget);
  });

  testWidgets('"Select All" ends on the page margin', (tester) async {
    await _pump(tester);
    final sheet = tester.getRect(find.byType(JamLibraryPicker));
    final label = tester.getRect(find.text(LibrarySheetStrings.selectAll));
    expect(sheet.right - label.right, closeTo(16, 0.5));
  });

  testWidgets('the commit says what it does: Add, live once something is '
      'chosen', (tester) async {
    await _pump(tester);
    JamTextButton add() => tester.widget<JamTextButton>(
      find.widgetWithText(JamTextButton, LibrarySheetStrings.add),
    );
    expect(find.text('Done'), findsNothing);
    expect(add().onPressed, isNull);
    await tester.tap(find.text('Low Tide'));
    await tester.pump();
    expect(add().onPressed, isNotNull);
  });

  testWidgets('no results: no "0 songs", no dead Select All, and the '
      'query said back', (tester) async {
    await _pump(tester);
    await tester.enterText(find.byType(CupertinoSearchTextField), 'zzz');
    await tester.pump();

    expect(find.text(LibrarySheetStrings.noResults), findsOneWidget);
    expect(find.text(LibrarySheetStrings.noResultsFor('zzz')), findsOneWidget);
    expect(find.text(LibrarySheetStrings.available(0)), findsNothing);
    expect(find.text(LibrarySheetStrings.selectAll), findsNothing);
  });

  testWidgets('renders on the dark palette', (tester) async {
    await _pump(tester, dark: true);
    expect(tester.takeException(), isNull);
  });
}
