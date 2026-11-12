/// The host's shared library (PROTOCOL.md §6.6) as a browse sheet: the
/// library picker's chrome over the catalog listing.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/design/theme.dart';
import 'package:localjam_app/src/widgets/buttons.dart';
import 'package:localjam_app/src/widgets/catalog_sheet.dart';
import 'package:localjam_app/src/widgets/empty_state.dart';
import 'package:localjam_app/src/widgets/library_sheet.dart';
import 'package:localjam_app/src/widgets/switch.dart';
import 'package:localjam_app/src/widgets/text_field.dart';
import 'package:localjam_app/src/widgets/track_row.dart';
import 'package:localjam_client/localjam_client.dart';
import 'package:material_ui/material_ui.dart';

const _entries = [
  CatalogEntry(
    catalogId: 'c_1',
    title: 'Low Tide',
    artist: 'Harbour Kids',
    album: 'Shoreline',
    durationUs: 200000000,
  ),
  CatalogEntry(
    catalogId: 'c_2',
    title: 'Night Drive',
    artist: 'Neon Arcade',
    hasArtwork: false,
  ),
  CatalogEntry(catalogId: 'c_3', title: 'Paper Boats', album: 'Harbour'),
];

Future<void> _pump(
  WidgetTester tester, {
  List<CatalogEntry> entries = _entries,
  Future<List<CatalogEntry>> Function()? load,
  ValueListenable<CatalogSummary?>? revision,
  Future<Uint8List?> Function(CatalogEntry entry)? coverFor,
  bool canAdd = true,
  Set<String> queued = const {},
  bool dark = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: dark ? jamDarkTheme() : jamLightTheme(),
      home: Scaffold(
        body: JamCatalogPicker(
          title: 'Silky Puffin’s library',
          emptyBody: CatalogSheetStrings.emptyBody('Silky Puffin'),
          load: load ?? () async => entries,
          revision: revision,
          coverFor: coverFor,
          canAdd: canAdd,
          queued: queued,
        ),
      ),
    ),
  );
  await tester.pump();
}

JamTextButton _add(WidgetTester tester) => tester.widget<JamTextButton>(
  find.widgetWithText(JamTextButton, LibrarySheetStrings.add),
);

void main() {
  testWidgets('lists the host’s songs under its name, with title, byline and '
      'length', (tester) async {
    await _pump(tester);
    expect(find.text('Silky Puffin’s library'), findsOneWidget);
    expect(find.byType(JamTrackRow), findsNWidgets(3));
    expect(find.text('Low Tide'), findsOneWidget);
    expect(find.textContaining('Harbour Kids'), findsOneWidget);
    expect(find.text(LibrarySheetStrings.available(3)), findsOneWidget);
    // The commit is the verb, grey until something is chosen.
    expect(find.text('Done'), findsNothing);
    expect(_add(tester).onPressed, isNull);
  });

  testWidgets('search filters by title, artist and album, on this phone', (
    tester,
  ) async {
    await _pump(tester);
    await tester.enterText(find.byType(JamTextField), 'harbour');
    await tester.pump();
    // "Harbour Kids" (artist) and "Harbour" (album); not Night Drive.
    expect(find.byType(JamTrackRow), findsNWidgets(2));
    expect(find.text('Night Drive'), findsNothing);
    expect(find.text(LibrarySheetStrings.available(2)), findsOneWidget);

    await tester.enterText(find.byType(JamTextField), 'night');
    await tester.pump();
    expect(find.byType(JamTrackRow), findsOneWidget);
    expect(find.text('Night Drive'), findsOneWidget);

    await tester.enterText(find.byType(JamTextField), 'zzz');
    await tester.pump();
    expect(find.text(LibrarySheetStrings.noResults), findsOneWidget);
    expect(find.text(LibrarySheetStrings.noResultsFor('zzz')), findsOneWidget);
    expect(find.text(LibrarySheetStrings.selectAll), findsNothing);
  });

  testWidgets('Select all chooses what the search left, and only that', (
    tester,
  ) async {
    await _pump(tester);
    await tester.enterText(find.byType(JamTextField), 'harbour');
    await tester.pump();
    await tester.tap(find.text(LibrarySheetStrings.selectAll));
    await tester.pump();
    expect(find.text(LibrarySheetStrings.selectedCount(2)), findsOneWidget);
    expect(find.text(LibrarySheetStrings.deselectAll), findsOneWidget);
    expect(_add(tester).onPressed, isNotNull);

    // Cleared, the third song is there and not chosen.
    await tester.enterText(find.byType(JamTextField), '');
    await tester.pump();
    final checks = tester
        .widgetList<JamSelectionCheck>(find.byType(JamSelectionCheck))
        .map((c) => c.selected)
        .toList();
    expect(checks, [true, false, true]);
    expect(find.text(LibrarySheetStrings.selectAll), findsOneWidget);
  });

  testWidgets('Add pops exactly what was chosen, in library order', (
    tester,
  ) async {
    List<CatalogEntry>? popped;
    await tester.pumpWidget(
      MaterialApp(
        theme: jamLightTheme(),
        home: Builder(
          builder: (context) => Center(
            child: GestureDetector(
              onTap: () async {
                popped = await Navigator.of(context).push(
                  MaterialPageRoute<List<CatalogEntry>>(
                    builder: (_) => Scaffold(
                      body: JamCatalogPicker(
                        title: 'Silky Puffin’s library',
                        load: () async => _entries,
                      ),
                    ),
                  ),
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Paper Boats'));
    await tester.tap(find.text('Low Tide'));
    await tester.pump();
    await tester.tap(
      find.widgetWithText(JamTextButton, LibrarySheetStrings.add),
    );
    await tester.pumpAndSettle();
    expect(popped?.map((e) => e.catalogId), ['c_1', 'c_3']);
  });

  testWidgets('without add_tracks the library can be browsed, nothing '
      'chosen, and the sheet only closes, with the reason', (tester) async {
    await _pump(tester, canAdd: false);
    // A sheet that only shows: Done, no Cancel and no grey verb (§10.2).
    expect(find.widgetWithText(JamTextButton, 'Done'), findsOneWidget);
    expect(find.text('Cancel'), findsNothing);
    expect(
      find.widgetWithText(JamTextButton, LibrarySheetStrings.add),
      findsNothing,
    );
    expect(find.byType(JamTrackRow), findsNWidgets(3));
    expect(find.text(CatalogSheetStrings.cantAdd), findsOneWidget);
    expect(find.byType(JamSelectionCheck), findsNothing);
    expect(find.text(LibrarySheetStrings.selectAll), findsNothing);
    await tester.tap(find.text('Low Tide'));
    await tester.pump();
    expect(find.text(LibrarySheetStrings.selectedCount(1)), findsNothing);
  });

  testWidgets('the host stopping sharing while the sheet is open is said, '
      'not shown as an empty library', (tester) async {
    final revision = ValueNotifier<CatalogSummary?>(
      const CatalogSummary(rev: 1, count: 3),
    );
    addTearDown(revision.dispose);
    var withdrawn = 0;
    var loads = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: jamLightTheme(),
        home: Scaffold(
          body: JamCatalogPicker(
            title: 'Silky Puffin’s library',
            revision: revision,
            onWithdrawn: () => withdrawn++,
            load: () async {
              loads++;
              return _entries;
            },
          ),
        ),
      ),
    );
    await tester.pump();
    revision.value = null;
    await tester.pump();
    expect(withdrawn, 1);
    expect(loads, 1, reason: 'not listed again');
    expect(find.text(CatalogSheetStrings.emptyTitle), findsNothing);
    expect(
      CatalogSheetStrings.stoppedSharing('Silky Puffin'),
      'Silky Puffin stopped sharing their library.',
    );
  });

  testWidgets('songs already in the queue say so, cannot be chosen, and '
      'Select all leaves them out', (tester) async {
    await _pump(tester, queued: {'c_2'});
    expect(find.text(CatalogSheetStrings.inQueue), findsOneWidget);
    expect(find.byType(JamSelectionCheck), findsNWidgets(2));
    await tester.tap(find.text('Night Drive'));
    await tester.pump();
    expect(find.text(LibrarySheetStrings.selectedCount(1)), findsNothing);
    await tester.tap(find.text(LibrarySheetStrings.selectAll));
    await tester.pump();
    expect(find.text(LibrarySheetStrings.selectedCount(2)), findsOneWidget);
    expect(find.text(LibrarySheetStrings.deselectAll), findsOneWidget);

    // Everything the search left is queued: no Select all to press.
    await tester.enterText(find.byType(JamTextField), 'night');
    await tester.pump();
    expect(find.text(LibrarySheetStrings.selectAll), findsNothing);
    expect(find.text(LibrarySheetStrings.deselectAll), findsNothing);
  });

  testWidgets('an empty library is the app’s one empty state', (tester) async {
    await _pump(tester, entries: const []);
    expect(find.byType(JamEmptyState), findsOneWidget);
    expect(find.text(CatalogSheetStrings.emptyTitle), findsOneWidget);
    expect(
      find.text(CatalogSheetStrings.emptyBody('Silky Puffin')),
      findsOneWidget,
    );
    expect(find.text(LibrarySheetStrings.available(0)), findsNothing);
  });

  testWidgets('a listing that fails offers Try again, which lists again', (
    tester,
  ) async {
    var calls = 0;
    await _pump(
      tester,
      load: () async {
        calls++;
        if (calls == 1) throw StateError('offline');
        return _entries;
      },
    );
    expect(find.text(CatalogSheetStrings.failedTitle), findsOneWidget);
    await tester.tap(find.text(CatalogSheetStrings.retry));
    await tester.pump();
    expect(calls, 2);
    expect(find.byType(JamTrackRow), findsNWidgets(3));
  });

  testWidgets('a new rev lists again, keeping what is still there chosen', (
    tester,
  ) async {
    final revision = ValueNotifier<CatalogSummary?>(
      const CatalogSummary(rev: 1, count: 3),
    );
    addTearDown(revision.dispose);
    var listing = _entries;
    var calls = 0;
    await _pump(
      tester,
      revision: revision,
      load: () async {
        calls++;
        return listing;
      },
    );
    await tester.tap(find.text('Low Tide'));
    await tester.tap(find.text('Night Drive'));
    await tester.pump();
    expect(find.text(LibrarySheetStrings.selectedCount(2)), findsOneWidget);

    // Night Drive left the library; a new song arrived.
    listing = [
      _entries[0],
      _entries[2],
      const CatalogEntry(catalogId: 'c_4', title: 'Glass Coast'),
    ];
    revision.value = const CatalogSummary(rev: 2, count: 3);
    await tester.pump();
    await tester.pump();
    expect(calls, 2);
    expect(find.text('Glass Coast'), findsOneWidget);
    expect(find.text('Night Drive'), findsNothing);
    expect(find.text(LibrarySheetStrings.selectedCount(1)), findsOneWidget);

    // The same rev again is not a change.
    revision.value = const CatalogSummary(rev: 2, count: 3);
    await tester.pump();
    expect(calls, 2);
  });

  testWidgets('covers are asked for per row built, never for a song known '
      'to have none', (tester) async {
    final asked = <String>[];
    await _pump(
      tester,
      coverFor: (entry) async {
        asked.add(entry.catalogId);
        return null;
      },
    );
    await tester.pump();
    expect(asked, unorderedEquals(['c_1', 'c_3']));
  });

  testWidgets('only the rows on screen ask for their covers', (tester) async {
    final asked = <String>{};
    final many = [
      for (var i = 0; i < 400; i++)
        CatalogEntry(catalogId: 'c_$i', title: 'Song $i'),
    ];
    await _pump(
      tester,
      entries: many,
      coverFor: (entry) async {
        asked.add(entry.catalogId);
        return null;
      },
    );
    await tester.pump();
    expect(asked, isNotEmpty);
    expect(asked.length, lessThan(60));
  });

  testWidgets('renders on the dark palette', (tester) async {
    await _pump(tester, dark: true);
    expect(tester.takeException(), isNull);
  });
}
