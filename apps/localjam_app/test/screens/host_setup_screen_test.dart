/// Start a Jam: the defaults that make "one tap to sound" true, as an iOS
/// grouped sheet (DESIGN_SPEC v3 §6.2).
library;

import 'dart:io';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/design/theme.dart';
import 'package:localjam_app/src/design/tokens.dart';
import 'package:localjam_app/src/router.dart';
import 'package:localjam_app/src/screens/home_screen.dart';
import 'package:localjam_app/src/screens/host_setup_screen.dart';
import 'package:localjam_app/src/state/session_controller.dart';
import 'package:localjam_app/src/util/media_picking.dart';
import 'package:localjam_app/src/util/permissions.dart';
import 'package:localjam_app/src/widgets/buttons.dart';
import 'package:localjam_app/src/widgets/guests_can.dart';
import 'package:localjam_app/src/widgets/list.dart';
import 'package:localjam_app/src/widgets/menu.dart';
import 'package:localjam_app/src/widgets/text_field.dart';
import 'package:localjam_app/src/widgets/track_row.dart';
import 'package:localjam_client/localjam_client.dart';

import '../harness.dart';

/// A music library of one song, for the share switch.
class _Library extends JamCatalogSource {
  @override
  Future<List<CatalogEntry>> list() async => const [
    CatalogEntry(catalogId: 'c_1', title: 'Low Tide'),
  ];

  @override
  Future<File?> open(String catalogId) async => null;
}

/// The `sharing` flag of every library ask, in order.
final List<bool> _askedSharing = [];

/// Whether this platform has a library, and what the permission ask says.
void _library({
  bool available = true,
  JamPermissionOutcome outcome = JamPermissionOutcome.granted,
}) {
  debugJamLibraryAvailable = available;
  jamAudioPermissionRequest = ({bool sharing = false}) async {
    _askedSharing.add(sharing);
    return outcome;
  };
  _askedSharing.clear();
  addTearDown(() {
    debugJamLibraryAvailable = null;
    jamAudioPermissionRequest = requestAudioLibraryPermission;
  });
}

JamRow _shareRow(WidgetTester tester) => tester.widget<JamRow>(
  find.widgetWithText(JamRow, HostSetupStrings.shareLibrary),
);

/// Tall enough that every section is on screen without scrolling — the
/// default 800×600 test surface stops a lazy `ListView` from building it.
Future<void> _tall(WidgetTester tester) async {
  tester.view.physicalSize =
      const Size(420, 1400) * tester.view.devicePixelRatio;
  addTearDown(tester.view.resetPhysicalSize);
}

/// [text] inside the sheet — home under it says "Start a jam" too.
Finder _inSheet(String text) => find.descendant(
  of: find.byType(HostSetupScreen),
  matching: find.text(text),
);

void main() {
  testWidgets('the sheet opens with Cancel, Start and a default name', (
    tester,
  ) async {
    final session = testSession();
    await _tall(tester);
    final router = await pumpApp(tester, session);
    router.push('/host');
    await tester.pumpAndSettle();

    expect(_inSheet(HostSetupStrings.title), findsOneWidget);
    expect(find.text(HostSetupStrings.cancel), findsOneWidget);
    expect(find.text(HostSetupStrings.start), findsOneWidget);
    // Presented as an iOS page sheet over home.
    expect(find.byType(HomeScreen), findsOneWidget);

    // The name is a big inline field that starts filled with the default,
    // in ink — a grey placeholder read as empty or disabled — with a
    // typographic apostrophe. Cleared, the placeholder says the same name
    // in a readable grey.
    final field = tester.widget<CupertinoTextField>(
      find.byType(CupertinoTextField),
    );
    expect(field.controller!.text, 'Silky Puffin’s jam');
    expect(field.placeholder, 'Silky Puffin’s jam');
    expect(field.placeholderStyle!.color, JamColors.light.secondaryLabel);
    expect(field.style!.fontSize, 22);
    // The app's one clear button, not Cupertino's.
    expect(field.clearButtonMode, OverlayVisibilityMode.never);
    expect(field.suffixMode, OverlayVisibilityMode.editing);
    expect(
      find.descendant(
        of: find.byType(CupertinoTextField),
        matching: find.byType(JamFieldClearButton),
      ),
      findsOneWidget,
    );

    // Start lives in the nav bar: no big filled button on this sheet.
    final primaries = tester
        .widgetList<JamButton>(
          find.descendant(
            of: find.byType(HostSetupScreen),
            matching: find.byType(JamButton),
          ),
        )
        .where((b) => b.variant == JamButtonVariant.filled);
    expect(primaries, isEmpty);
    final start = tester.widget<JamTextButton>(
      find.widgetWithText(JamTextButton, HostSetupStrings.start),
    );
    expect(start.bold, isTrue);
    expect(start.onPressed, isNotNull);
  });

  testWidgets('the first tap on the default name selects it all', (
    tester,
  ) async {
    final session = testSession();
    await _tall(tester);
    final router = await pumpApp(tester, session);
    router.push('/host');
    await tester.pumpAndSettle();

    await tester.tap(find.byType(CupertinoTextField));
    await tester.pumpAndSettle();
    final controller = tester
        .widget<CupertinoTextField>(find.byType(CupertinoTextField))
        .controller!;
    expect(
      controller.selection,
      TextSelection(baseOffset: 0, extentOffset: controller.text.length),
    );
    // Typing replaces it; Start then uses what was typed.
    await tester.enterText(find.byType(CupertinoTextField), 'Van Jam');
    expect(controller.text, 'Van Jam');
  });

  testWidgets('Add Songs is the app’s one row, and stays put when the first '
      'song lands', (tester) async {
    await _tall(tester);
    Future<Rect> addRow(List<String> paths) async {
      final session = testSession();
      final router = await pumpApp(tester, session);
      router.push(
        '/host',
        extra: HostSetupArgs(paths: paths, name: 'Jam'),
      );
      await tester.pumpAndSettle();
      expect(find.byType(JamAddSongsRow), findsOneWidget);
      expect(find.byIcon(CupertinoIcons.plus_circle_fill), findsNothing);
      return tester.getRect(find.byIcon(CupertinoIcons.plus));
    }

    final empty = await addRow(const []);
    final full = await addRow(const ['/music/Night Drive.mp3']);
    expect(full.left, empty.left);
    expect(full.width, empty.width);
  });

  testWidgets('Cancel dismisses the sheet back to home', (tester) async {
    final session = testSession();
    final router = await pumpApp(tester, session);
    router.push('/host');
    await tester.pumpAndSettle();

    await tester.tap(find.text(HostSetupStrings.cancel));
    await tester.pumpAndSettle();
    expect(_inSheet(HostSetupStrings.title), findsNothing);
    expect(find.byType(HomeScreen), findsOneWidget);
  });

  testWidgets('Guests Can is a menu of presets, "Add Music" by default', (
    tester,
  ) async {
    final session = testSession();
    await _tall(tester);
    final router = await pumpApp(tester, session);
    router.push('/host');
    await tester.pumpAndSettle();

    // The engine's own default, not the old screen's `open`, in the same
    // words the People sheet uses.
    expect(find.text(JamPresetStrings.guestsCan), findsOneWidget);
    expect(find.text(JamPresetStrings.addMusic), findsOneWidget);
    expect(find.text(JamPresetStrings.summary(JamPolicy.jam)), findsOneWidget);

    await tester.tap(find.text(JamPresetStrings.guestsCan));
    await tester.pumpAndSettle();
    final items = find.byType(JamMenuRow);
    expect(items, findsNWidgets(kJamPresets.length));
    for (final preset in kJamPresets) {
      expect(
        find.descendant(
          of: items,
          matching: find.text(JamPresetStrings.name(preset)),
        ),
        findsOneWidget,
      );
      expect(find.text(JamPresetStrings.detail(preset)!), findsOneWidget);
    }

    await tester.tap(
      find.descendant(
        of: items,
        matching: find.text(JamPresetStrings.listenOnly),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text(JamPresetStrings.summary(JamPolicy.listenOnly)),
      findsOneWidget,
    );
    expect(find.text(JamPresetStrings.listenOnly), findsOneWidget);
    expect(find.text(JamPresetStrings.addMusic), findsNothing);
  });

  testWidgets('Show to People Nearby is a switch, on by default', (
    tester,
  ) async {
    final session = testSession();
    await _tall(tester);
    final router = await pumpApp(tester, session);
    router.push('/host');
    await tester.pumpAndSettle();

    final toggle = tester.widget<JamRow>(
      find.widgetWithText(JamRow, HostSetupStrings.discoverable),
    );
    expect(toggle.toggled, isTrue);
    await tester.tap(find.text(HostSetupStrings.discoverable));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<JamRow>(
            find.widgetWithText(JamRow, HostSetupStrings.discoverable),
          )
          .toggled,
      isFalse,
    );
  });

  testWidgets('"Host again" songs arrive as song rows, swipe to remove', (
    tester,
  ) async {
    final session = testSession();
    await _tall(tester);
    final router = await pumpApp(tester, session);
    router.push(
      '/host',
      extra: const HostSetupArgs(
        paths: ['/music/Night Drive.mp3', '/music/Second Wind.m4a'],
        name: 'Van Jam',
      ),
    );
    await tester.pumpAndSettle();

    // A past jam's name is real text, not a placeholder.
    expect(
      tester
          .widget<CupertinoTextField>(find.byType(CupertinoTextField))
          .controller!
          .text,
      'Van Jam',
    );
    expect(find.text(HostSetupStrings.addSongs), findsOneWidget);
    expect(find.text(HostSetupStrings.songCount(2)), findsOneWidget);
    expect(find.byType(JamTrackRow), findsNWidgets(2));
    // Real titles, not `_basename(path)` with its extension showing.
    expect(find.text('Night Drive'), findsOneWidget);
    expect(find.text('Second Wind'), findsOneWidget);
    expect(find.textContaining('.mp3'), findsNothing);

    await tester.drag(find.text('Night Drive'), const Offset(-500, 0));
    await tester.pumpAndSettle();
    expect(find.byType(JamTrackRow), findsOneWidget);
    expect(find.text('Night Drive'), findsNothing);
    expect(find.text(HostSetupStrings.songCount(1)), findsOneWidget);
  });

  test('the Songs footer follows the preset — Listen Only is not '
      '"everyone can add songs"', () {
    expect(
      HostSetupStrings.songsFooter(JamPolicy.jam),
      HostSetupStrings.songsFooterGuests,
    );
    expect(
      HostSetupStrings.songsFooter(JamPolicy.open),
      HostSetupStrings.songsFooterGuests,
    );
    expect(
      HostSetupStrings.songsFooter(JamPolicy.listenOnly),
      HostSetupStrings.songsFooterHost,
    );
    // Sentence-case count headers (§10.9).
    expect(HostSetupStrings.songCount(12), '12 songs');
    expect(HostSetupStrings.songCount(1), '1 song');
  });

  testWidgets('the empty Songs section says who can add songs', (tester) async {
    final session = testSession();
    await _tall(tester);
    final router = await pumpApp(tester, session);
    router.push(
      '/host',
      extra: const HostSetupArgs(paths: [], name: 'Jam'),
    );
    await tester.pumpAndSettle();
    expect(find.text(HostSetupStrings.songsFooterGuests), findsOneWidget);
  });

  testWidgets('renders on the dark palette', (tester) async {
    final session = testSession();
    final router = await pumpApp(tester, session, theme: jamDarkTheme());
    router.push('/host');
    await tester.pumpAndSettle();

    expect(_inSheet(HostSetupStrings.title), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  group('Share my music library', () {
    testWidgets('is not offered where the phone has no library', (
      tester,
    ) async {
      _library(available: false);
      final session = testSession();
      await _tall(tester);
      final router = await pumpApp(tester, session);
      router.push('/host');
      await tester.pumpAndSettle();
      expect(find.text(HostSetupStrings.shareLibrary), findsNothing);
    });

    testWidgets('sits under the songs, off by default, and says who will '
        'see it', (tester) async {
      _library();
      final session = testSession();
      await _tall(tester);
      final router = await pumpApp(tester, session);
      router.push('/host');
      await tester.pumpAndSettle();
      expect(_shareRow(tester).toggled, isFalse);
      // Who sees the titles, true to the preset and the nearby switch.
      expect(
        find.text(
          'Anyone on this Wi‑Fi who joins can see your song titles '
          'and add them',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text(HostSetupStrings.discoverable));
      await tester.pumpAndSettle();
      expect(
        find.text(HostSetupStrings.shareLibraryDetail(JamPolicy.jam, false)),
        findsOneWidget,
      );
      expect(
        HostSetupStrings.shareLibraryDetail(JamPolicy.listenOnly, false),
        'People in the jam can see your song titles',
      );
      final songs = tester.getRect(_inSheet(HostSetupStrings.addSongs));
      final share = tester.getRect(find.text(HostSetupStrings.shareLibrary));
      final nearby = tester.getRect(find.text(HostSetupStrings.discoverable));
      expect(share.top, greaterThan(songs.bottom));
      expect(share.bottom, lessThan(nearby.top));
    });

    testWidgets('a denied permission keeps it off, with the permission '
        'notice', (tester) async {
      _library(outcome: JamPermissionOutcome.denied);
      final session = testSession();
      final heard = <JamNotice>[];
      final sub = session.notices.listen(heard.add);
      addTearDown(sub.cancel);
      await _tall(tester);
      final router = await pumpApp(tester, session);
      router.push('/host');
      await tester.pumpAndSettle();

      await tester.tap(find.text(HostSetupStrings.shareLibrary));
      await tester.pumpAndSettle();
      expect(_shareRow(tester).toggled, isFalse);
      expect(
        heard.map((n) => n.message),
        contains(JamPermissionCopy.audioLibraryDenied),
      );
    });

    testWidgets('granted, it turns on, and Start shares the library with '
        'the jam', (tester) async {
      _library();
      final session = testSession(librarySource: _Library.new);
      await _tall(tester);
      final router = await pumpApp(tester, session);
      router.push('/host');
      await tester.pumpAndSettle();

      await tester.tap(find.text(HostSetupStrings.shareLibrary));
      await tester.pumpAndSettle();
      expect(_shareRow(tester).toggled, isTrue);
      // Asked as sharing: its rationale says what the jam will see, not the
      // picker's "nothing leaves this phone".
      expect(_askedSharing, [true]);

      await tester.tap(
        find.widgetWithText(JamTextButton, HostSetupStrings.start),
      );
      for (
        var i = 0;
        i < 200 && session.hostEngine?.catalog.value == null;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(session.isLive, isTrue);
      expect(session.hostEngine!.catalog.value?.count, 1);
      await leaveTestSession(tester, session);
    });
  });
}
