/// The intro is a courtesy: one "Welcome to LocalJam" page, one way on, and
/// it writes the flag exactly once.
library;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_client/localjam_client.dart' show JamIdentity;
import 'package:localjam_app/src/design/theme.dart';
import 'package:localjam_app/src/design/tokens.dart';
import 'package:localjam_app/src/screens/onboarding_screen.dart';
import 'package:localjam_app/src/state/onboarding_prefs.dart';
import 'package:localjam_app/src/widgets/avatar.dart';
import 'package:localjam_app/src/widgets/brand.dart';
import 'package:localjam_app/src/widgets/buttons.dart';
import 'package:localjam_app/src/widgets/rename_dialog.dart';
import 'package:localjam_app/src/widgets/scaffold.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<JamOnboardingPrefs> pumpOnboarding(
  WidgetTester tester, {
  VoidCallback? onDone,
  ThemeData? theme,
  Size? size,
  String identity = 'Sparkly Kiwi',
}) async {
  SharedPreferences.setMockInitialValues({'localjam.displayName': identity});
  JamIdentity.resetCacheForTesting();
  final prefs = JamOnboardingPrefs();
  if (size != null) {
    tester.view.physicalSize = size * tester.view.devicePixelRatio;
    addTearDown(tester.view.resetPhysicalSize);
  }
  await tester.pumpWidget(
    JamOnboarding(
      prefs: prefs,
      child: MaterialApp(
        theme: theme ?? jamLightTheme(),
        home: OnboardingScreen(onDone: onDone),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return prefs;
}

void main() {
  testWidgets('one page: a title, three features and Continue', (tester) async {
    await pumpOnboarding(tester);

    expect(find.text(OnboardingStrings.title), findsOneWidget);
    for (final text in [
      OnboardingStrings.oneTitle,
      OnboardingStrings.oneBody,
      OnboardingStrings.twoTitle,
      OnboardingStrings.twoBody,
      OnboardingStrings.threeTitle,
      OnboardingStrings.threeBody,
    ]) {
      expect(find.text(text), findsOneWidget);
    }
    // No carousel, no page dots, one filled button.
    expect(find.byType(PageView), findsNothing);
    final filled = tester
        .widgetList<JamButton>(find.byType(JamButton))
        .where((b) => b.variant == JamButtonVariant.filled);
    expect(filled.single.label, OnboardingStrings.continueLabel);
    // A typographic list: no glyph column, so nothing raspberry that cannot
    // be tapped (D8).
    expect(find.byType(Icon), findsNothing);
  });

  testWidgets('says the name you will appear as, and changes it', (
    tester,
  ) async {
    await pumpOnboarding(
      tester,
      identity: 'Sparkly Kiwi',
      size: const Size(402, 874),
    );

    expect(
      find.bySemanticsLabel(OnboardingStrings.appearAs('Sparkly Kiwi')),
      findsOneWidget,
    );
    expect(find.byType(JamAvatar), findsOneWidget);

    await tester.tap(find.text(OnboardingStrings.change));
    await tester.pumpAndSettle();
    expect(find.text(RenameStrings.title), findsOneWidget);
    await tester.enterText(find.byType(CupertinoTextField), 'Mia');
    await tester.tap(find.text(RenameStrings.save));
    await tester.pumpAndSettle();

    expect(
      find.bySemanticsLabel(OnboardingStrings.appearAs('Mia')),
      findsOneWidget,
    );
    expect(await JamIdentity.displayName(), 'Mia');
  });

  testWidgets('leaving the name alone keeps it, and Continue is still one '
      'tap', (tester) async {
    var done = 0;
    await pumpOnboarding(
      tester,
      identity: 'Sparkly Kiwi',
      onDone: () => done++,
    );

    await tester.tap(find.text(OnboardingStrings.continueLabel));
    await tester.pumpAndSettle();

    expect(done, 1);
    expect(await JamIdentity.displayName(), 'Sparkly Kiwi');
  });

  testWidgets('continuing marks the flag and hands back to the caller', (
    tester,
  ) async {
    var done = 0;
    final prefs = await pumpOnboarding(tester, onDone: () => done++);
    expect(prefs.seen, isFalse);

    await tester.tap(find.text(OnboardingStrings.continueLabel));
    await tester.pumpAndSettle();

    expect(prefs.seen, isTrue);
    expect(done, 1);
  });

  testWidgets('a double tap still writes and leaves once', (tester) async {
    var done = 0;
    await pumpOnboarding(tester, onDone: () => done++);

    await tester.tap(find.text(OnboardingStrings.continueLabel));
    await tester.tap(find.text(OnboardingStrings.continueLabel));
    await tester.pumpAndSettle();

    expect(done, 1);
  });

  testWidgets('the skip the router relies on is the same one tap', (
    tester,
  ) async {
    var done = 0;
    final prefs = await pumpOnboarding(tester, onDone: () => done++);

    await tester.tap(find.text(OnboardingStrings.skip));
    await tester.pumpAndSettle();

    expect(prefs.seen, isTrue);
    expect(done, 1);
  });

  testWidgets('the flag survives a reload', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = JamOnboardingPrefs();
    await prefs.load();
    expect(prefs.seen, isFalse);
    expect(prefs.loaded, isTrue);

    await prefs.markSeen();
    final reread = JamOnboardingPrefs();
    await reread.load();
    expect(reread.seen, isTrue);
  });

  testWidgets('it works on a desktop window, not just a phone', (tester) async {
    await pumpOnboarding(tester, size: const Size(1440, 900));

    expect(tester.takeException(), isNull);
    expect(find.text(OnboardingStrings.oneTitle), findsOneWidget);
    // Content is held to a column rather than stretched across the window.
    final headline = tester.getSize(find.text(OnboardingStrings.oneBody));
    expect(headline.width, lessThanOrEqualTo(480));
  });

  testWidgets('no permission sheet is chained behind it', (tester) async {
    final prefs = await pumpOnboarding(tester);

    await tester.tap(find.text(OnboardingStrings.continueLabel));
    await tester.pumpAndSettle();

    // Permissions are asked for at the moment they are needed, not here.
    expect(prefs.seen, isTrue);
    expect(find.textContaining('local network'), findsNothing);
    expect(find.text('Not Now'), findsNothing);
    expect(find.text('Not now'), findsNothing);
  });

  testWidgets('1.3× text scrolls rather than clips', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await pumpOnboarding(tester, size: const Size(320, 568));

    expect(tester.takeException(), isNull);
    expect(find.text(OnboardingStrings.continueLabel), findsOneWidget);
  });

  testWidgets('wordmark, words and Continue share Nearby’s page edge', (
    tester,
  ) async {
    // Four edges before (title 36, glyphs 43, text 92, button 20), then
    // two (words 32, button 16): now one, the page margin Nearby uses, so
    // nothing moves sideways when Continue hands over.
    await pumpOnboarding(tester, size: const Size(402, 874));
    final wordmark = tester.getRect(find.byType(JamWordmark));
    final title = tester.getRect(find.text(OnboardingStrings.title));
    final feature = tester.getRect(find.text(OnboardingStrings.oneTitle));
    final button = tester.getRect(
      find.widgetWithText(JamButton, OnboardingStrings.continueLabel),
    );
    for (final edge in [wordmark.left, title.left, feature.left]) {
      expect(edge, closeTo(button.left, 0.5));
    }
    expect(button.left, JamSpace.page);
    // Continue sits where Start a Jam does: on the bottom bar's inset.
    expect(874 - button.bottom, jamBottomBarInset(0));
    expect(
      tester.widget<Text>(find.text(OnboardingStrings.title)).style?.fontSize,
      34,
    );
    // The feature headlines are named things in Manrope, not system chrome.
    expect(
      tester
          .widget<Text>(find.text(OnboardingStrings.oneTitle))
          .style
          ?.fontFamily,
      'Manrope',
    );
  });

  testWidgets('the name sits at the foot of the page, above Continue', (
    tester,
  ) async {
    await pumpOnboarding(tester, size: const Size(402, 874));
    final name = tester.getRect(find.text(OnboardingStrings.change));
    final button = tester.getRect(
      find.widgetWithText(JamButton, OnboardingStrings.continueLabel),
    );
    final features = tester.getRect(find.text(OnboardingStrings.threeBody));
    expect(name.bottom, lessThan(button.top));
    expect(button.top - name.bottom, lessThan(JamSpace.giant));
    expect(name.top, greaterThan(features.bottom));
  });

  testWidgets('renders on the dark palette', (tester) async {
    await pumpOnboarding(tester, theme: jamDarkTheme());
    expect(tester.takeException(), isNull);
    expect(find.text(OnboardingStrings.title), findsOneWidget);
  });
}
