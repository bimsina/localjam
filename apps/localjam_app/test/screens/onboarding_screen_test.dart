/// The intro is a courtesy: three panels, skippable from the first, and it
/// writes the flag exactly once however you leave it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/design/theme.dart';
import 'package:localjam_app/src/screens/onboarding_screen.dart';
import 'package:localjam_app/src/state/onboarding_prefs.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<JamOnboardingPrefs> pumpOnboarding(
  WidgetTester tester, {
  VoidCallback? onDone,
  ThemeData? theme,
  Size? size,
}) async {
  SharedPreferences.setMockInitialValues({});
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
  testWidgets('three panels, in order, with one way on', (tester) async {
    await pumpOnboarding(tester);

    expect(find.text(OnboardingStrings.oneTitle), findsOneWidget);
    expect(find.text(OnboardingStrings.next), findsOneWidget);
    expect(find.text(OnboardingStrings.skip), findsOneWidget);

    await tester.tap(find.text(OnboardingStrings.next));
    await tester.pumpAndSettle();
    expect(find.text(OnboardingStrings.twoTitle), findsOneWidget);

    await tester.tap(find.text(OnboardingStrings.next));
    await tester.pumpAndSettle();
    expect(find.text(OnboardingStrings.threeTitle), findsOneWidget);
    // The last panel names the end of the road.
    expect(find.text(OnboardingStrings.getStarted), findsOneWidget);
    expect(find.text(OnboardingStrings.next), findsNothing);
  });

  testWidgets('finishing marks the flag and hands back to the caller', (
    tester,
  ) async {
    var done = 0;
    final prefs = await pumpOnboarding(tester, onDone: () => done++);
    expect(prefs.seen, isFalse);

    await tester.tap(find.text(OnboardingStrings.next));
    await tester.pumpAndSettle();
    await tester.tap(find.text(OnboardingStrings.next));
    await tester.pumpAndSettle();
    await tester.tap(find.text(OnboardingStrings.getStarted));
    await tester.pumpAndSettle();

    expect(prefs.seen, isTrue);
    expect(done, 1);
  });

  testWidgets('skipping counts as seen — this is not a gate', (tester) async {
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
    final headline = tester.getSize(find.text(OnboardingStrings.oneTitle));
    expect(headline.width, lessThanOrEqualTo(480));
  });

  testWidgets('no permission sheet is chained behind it', (tester) async {
    await pumpOnboarding(tester);

    await tester.tap(find.text(OnboardingStrings.skip));
    await tester.pumpAndSettle();

    // Permissions are asked for at the moment they are needed, not here.
    expect(find.textContaining('local network'), findsNothing);
    expect(find.text('Continue'), findsNothing);
    expect(find.text('Not now'), findsNothing);
  });
}
