/// The rationale sheet, and the rule that a dismissal is not consent.
library;

import 'package:cupertino_ui/cupertino_ui.dart' show CupertinoIcons;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/design/theme.dart';
import 'package:localjam_app/src/design/tokens.dart';
import 'package:localjam_app/src/design/typography.dart';
import 'package:localjam_app/src/util/permissions.dart';
import 'package:localjam_app/src/widgets/buttons.dart';
import 'package:localjam_app/src/widgets/permission_sheet.dart';
import 'package:localjam_app/src/widgets/sheet.dart';
import 'package:localjam_app/src/widgets/wifi_glyph.dart';
import 'package:material_ui/material_ui.dart';

Widget _host(Future<void> Function(BuildContext) onTap, {ThemeData? theme}) =>
    MaterialApp(
      theme: theme ?? jamLightTheme(),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => onTap(context),
            child: const Text('Go'),
          ),
        ),
      ),
    );

void main() {
  test('sharing the library says what the jam sees, not that nothing leaves '
      'this phone', () {
    // Turning on "Share my music library" once showed the picker's primer:
    // "Songs you don't add never leave this phone", while the jam was about
    // to see every title.
    expect(
      JamPermissionRationale.forKind(JamPermissionKind.audioLibraryShare),
      JamPermissionRationale.audioLibraryShare,
    );
    final share = JamPermissionRationale.audioLibraryShare;
    final words = [share.body, share.doesBullet, share.neverBullet].join(' ');
    expect(words, isNot(contains('never leave')));
    expect(words, contains('title, artist and cover'));
    expect(words, contains('jam ends'));
  });

  test('each primer says its own thing once, in sentence-case headings', () {
    expect(
      JamPermissionRationale.localNetwork.title,
      JamPermissionSheetStrings.localNetworkTitle,
    );
    expect(
      JamPermissionRationale.localNetwork.body,
      JamPermissionSheetStrings.localNetworkBody,
    );
    expect(
      JamPermissionRationale.notifications.title,
      JamPermissionSheetStrings.notificationsTitle,
    );
    expect(
      JamPermissionRationale.audioLibrary.body,
      JamPermissionSheetStrings.audioLibraryBody,
    );
    const all = [
      JamPermissionRationale.localNetwork,
      JamPermissionRationale.notifications,
      JamPermissionRationale.audioLibrary,
      JamPermissionRationale.audioLibraryShare,
      JamPermissionRationale.camera,
    ];
    // No two primers share their promise headings.
    expect(all.map((r) => r.doesHeading).toSet(), hasLength(all.length));
    expect(all.map((r) => r.neverHeading).toSet(), hasLength(all.length));
    for (final r in [...all, JamPermissionRationale.localNetworkApple]) {
      // No "cannot", and the Wi-Fi is named once, not in every line.
      for (final text in [r.body, r.doesBullet, r.neverBullet]) {
        expect(text, isNot(contains('cannot')));
      }
      expect(
        '${r.body} ${r.doesBullet} ${r.neverBullet}'.split('Wi‑Fi').length,
        lessThanOrEqualTo(2),
      );
    }
  });

  testWidgets('shows the ask, the promise, and both actions', (tester) async {
    await tester.pumpWidget(
      _host(
        (context) => showJamPermissionSheet(
          context,
          JamPermissionRationale.localNetwork,
        ),
      ),
    );
    await tester.tap(find.text('Go'));
    await tester.pumpAndSettle();

    expect(
      find.text(JamPermissionSheetStrings.localNetworkTitle),
      findsOneWidget,
    );
    expect(
      find.text(JamPermissionSheetStrings.localNetworkBody),
      findsOneWidget,
    );
    // The promise, headed in plain words — never an uppercase label.
    const rationale = JamPermissionRationale.localNetwork;
    expect(find.text(rationale.doesHeading), findsOneWidget);
    expect(find.text(rationale.neverHeading), findsOneWidget);
    expect(find.text(rationale.neverHeading.toUpperCase()), findsNothing);
    expect(find.byType(JamButton), findsNWidgets(2));
    // The buttons sit on the page margin like every other sheet's; only the
    // words take the narrower measure.
    // Measured from the painted surface: a floating medium sheet stands
    // [JamRadius.sheetFloatingInset] off the screen edges.
    final sheet = tester.getRect(
      find
          .descendant(
            of: find.byType(JamSheetSurface),
            matching: find.byType(ClipRRect),
          )
          .first,
    );
    final button = tester.getRect(find.byType(JamButton).first);
    expect(button.left - sheet.left, 16);
    expect(sheet.right - button.right, 16);
    final body = tester.getRect(
      find.text(JamPermissionSheetStrings.localNetworkBody),
    );
    expect(body.left - sheet.left, greaterThanOrEqualTo(32));
    // The promise glyphs are not tint: nothing there can be tapped. Row
    // icons, so they mark the rows rather than out-sizing the headings.
    final glyph = tester.widget<Icon>(find.byIcon(CupertinoIcons.lock));
    expect(glyph.color, isNot(JamColors.light.tint));
    expect(glyph.size, JamIconSize.row);
    // Nor is the hero glyph: one rule with every empty state's (D8). The
    // network's own glyph is drawn in outline, at an icon's hero size.
    expect(rationale.icon, isNull);
    final hero = tester.widget<JamWifiGlyph>(find.byType(JamWifiGlyph));
    expect(hero.color, isNull); // secondaryLabel
    expect(hero.slashed, isFalse);
    expect(tester.getSize(find.byType(JamWifiGlyph)), const Size.square(48));
    // The promises wrap at the full column, not balanced to half of it.
    expect(
      find.descendant(
        of: find.byType(Row),
        matching: find.byType(JamBalancedText),
      ),
      findsNothing,
    );
    expect(find.text(JamPermissionSheetStrings.continueLabel), findsOneWidget);
    expect(find.text(JamPermissionSheetStrings.dismissLabel), findsOneWidget);
  });

  testWidgets('Continue resolves true', (tester) async {
    bool? answer;
    await tester.pumpWidget(
      _host(
        (context) async => answer = await showJamPermissionSheet(
          context,
          JamPermissionRationale.audioLibrary,
        ),
      ),
    );
    await tester.tap(find.text('Go'));
    await tester.pumpAndSettle();

    await tester.tap(find.text(JamPermissionSheetStrings.continueLabel));
    await tester.pumpAndSettle();
    expect(answer, isTrue);
  });

  testWidgets('Not now resolves false', (tester) async {
    bool? answer;
    await tester.pumpWidget(
      _host(
        (context) async => answer = await showJamPermissionSheet(
          context,
          JamPermissionRationale.camera,
        ),
      ),
    );
    await tester.tap(find.text('Go'));
    await tester.pumpAndSettle();

    await tester.tap(find.text(JamPermissionSheetStrings.dismissLabel));
    await tester.pumpAndSettle();
    expect(answer, isFalse);
  });

  testWidgets('a swiped-away sheet is not consent', (tester) async {
    bool? answer;
    await tester.pumpWidget(
      _host(
        (context) async => answer = await showJamPermissionSheet(
          context,
          JamPermissionRationale.notifications,
        ),
      ),
    );
    await tester.tap(find.text('Go'));
    await tester.pumpAndSettle();

    await tester.tapAt(const Offset(10, 10)); // the barrier
    await tester.pumpAndSettle();
    expect(answer, isFalse);
  });

  testWidgets('reads the bullets out as heading plus promise', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        theme: jamLightTheme(),
        home: const Scaffold(
          body: JamPermissionSheet(
            rationale: JamPermissionRationale.localNetwork,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.bySemanticsLabel(
        '${JamPermissionRationale.localNetwork.neverHeading}: '
        '${JamPermissionRationale.localNetwork.neverBullet}',
      ),
      findsOneWidget,
    );
    handle.dispose();
  });

  testWidgets('renders on the dark palette', (tester) async {
    await tester.pumpWidget(
      _host(
        (context) =>
            showJamPermissionSheet(context, JamPermissionRationale.camera),
        theme: jamDarkTheme(),
      ),
    );
    await tester.tap(find.text('Go'));
    await tester.pumpAndSettle();

    expect(find.text(JamPermissionSheetStrings.cameraTitle), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // Last in the file: it swaps the body face for a proportional one.
  testWidgets('no promise ends on one word alone', (tester) async {
    // The test font sets every glyph a full em wide, so its lines wrap like
    // no real face's. Measure with a proportional one (Manrope, bundled)
    // standing in for the system face.
    final manrope = rootBundle.load('assets/fonts/Manrope.ttf');
    for (final family in ['Roboto', 'CupertinoSystemText']) {
      await tester.runAsync(
        () => (FontLoader(family)..addFont(manrope)).load(),
      );
    }
    for (final width in [320.0, 360.0, 402.0, 430.0]) {
      tester.view.physicalSize = Size(width, 874);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      for (final rationale in [
        JamPermissionRationale.localNetwork,
        JamPermissionRationale.notifications,
        JamPermissionRationale.audioLibrary,
        JamPermissionRationale.camera,
      ]) {
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(
          _host((context) => showJamPermissionSheet(context, rationale)),
        );
        await tester.tap(find.text('Go'));
        await tester.pumpAndSettle();
        for (final detail in [rationale.doesBullet, rationale.neverBullet]) {
          final paragraph = tester.renderObject<RenderParagraph>(
            find.text(detail, skipOffstage: false),
          );
          // The first character of the last line; 0 when there is one.
          final start = paragraph
              .getPositionForOffset(Offset(1, paragraph.size.height - 1))
              .offset;
          if (start == 0) continue;
          expect(
            detail.substring(start).trim(),
            contains(' '),
            reason: '$width: $detail',
          );
        }
      }
    }
  });
}
