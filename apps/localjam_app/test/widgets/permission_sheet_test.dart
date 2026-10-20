/// The rationale sheet, and the rule that a dismissal is not consent.
library;

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/design/theme.dart';
import 'package:localjam_app/src/design/tokens.dart';
import 'package:localjam_app/src/widgets/buttons.dart';
import 'package:localjam_app/src/widgets/permission_sheet.dart';
import 'package:localjam_app/src/widgets/sheet.dart';

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
  test('each primer says its own thing once, in Title Case headings', () {
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
    // Nor is the hero glyph: one rule with every empty state's (D8).
    final hero = tester.widget<Icon>(find.byIcon(rationale.icon));
    expect(hero.color, JamColors.light.secondaryLabel);
    expect(hero.size, JamIconSize.hero);
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
}
