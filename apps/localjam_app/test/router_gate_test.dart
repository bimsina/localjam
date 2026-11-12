/// The first-launch gate.
///
/// One boolean decides whether the app opens on the intro or on Home, and the
/// gate is a router redirect rather than a branch inside a screen — so a deep
/// link that arrives before the flag has loaded is held, not dropped.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:localjam_app/src/design/theme.dart';
import 'package:localjam_app/src/router.dart';
import 'package:localjam_app/src/screens/home_screen.dart';
import 'package:localjam_app/src/screens/onboarding_screen.dart';
import 'package:localjam_app/src/state/app_settings.dart';
import 'package:localjam_app/src/state/onboarding_prefs.dart';
import 'package:localjam_app/src/state/session_controller.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'harness.dart';

/// Pumps the real shell with a gate in front of it.
Future<GoRouter> pumpGated(
  WidgetTester tester,
  JamSessionController session,
  JamOnboardingPrefs onboarding,
) async {
  final router = buildRouter(session, onboarding: onboarding);
  await tester.pumpWidget(
    JamSettings(
      settings: JamAppSettings(),
      child: JamOnboarding(
        prefs: onboarding,
        child: JamSession(
          controller: session,
          child: MaterialApp.router(
            theme: jamLightTheme(),
            routerConfig: router,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

void main() {
  testWidgets('a first launch opens on the intro, not on Home', (tester) async {
    final session = testSession();
    SharedPreferences.setMockInitialValues({});
    final onboarding = JamOnboardingPrefs();
    await onboarding.load();

    final router = await pumpGated(tester, session, onboarding);

    expect(find.byType(OnboardingScreen), findsOneWidget);
    expect(find.byType(HomeScreen), findsNothing);
    expect(
      router.routerDelegate.currentConfiguration.uri.path,
      kOnboardingPath,
    );
  });

  testWidgets('finishing the intro writes the flag and lands on Home', (
    tester,
  ) async {
    final session = testSession();
    SharedPreferences.setMockInitialValues({});
    final onboarding = JamOnboardingPrefs();
    await onboarding.load();
    await pumpGated(tester, session, onboarding);

    // Skip is the fast way out, and it counts as having seen the intro.
    await tester.tap(find.text(OnboardingStrings.skip));
    await tester.pumpAndSettle();

    expect(onboarding.seen, isTrue);
    expect(find.byType(OnboardingScreen), findsNothing);
    expect(find.byType(HomeScreen), findsOneWidget);
  });

  testWidgets('Continue lands on Home even when the flag is slow to save', (
    tester,
  ) async {
    // The redirect fires the instant the in-memory flag flips, so the intro
    // can be gone before the write finishes — and its own `context.go` then
    // ran on a dead context ("No GoRouter found in context"), which a deep
    // link arriving at the same moment made likely on a fresh install.
    final session = testSession();
    SharedPreferences.setMockInitialValues({});
    final onboarding = _SlowWrite();
    await onboarding.load();
    await pumpGated(tester, session, onboarding);

    await tester.tap(find.text(OnboardingStrings.continueLabel));
    await tester.pumpAndSettle();
    expect(find.byType(OnboardingScreen), findsNothing);

    onboarding.gate.complete();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(HomeScreen), findsOneWidget);
  });

  testWidgets('a second launch goes straight to Home', (tester) async {
    final session = testSession();
    SharedPreferences.setMockInitialValues({kOnboardingSeenKey: true});
    final onboarding = JamOnboardingPrefs();
    await onboarding.load();

    await pumpGated(tester, session, onboarding);

    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.byType(OnboardingScreen), findsNothing);
  });

  testWidgets('the intro cannot be reached again once it is done', (
    tester,
  ) async {
    final session = testSession();
    SharedPreferences.setMockInitialValues({kOnboardingSeenKey: true});
    final onboarding = JamOnboardingPrefs();
    await onboarding.load();

    final router = await pumpGated(tester, session, onboarding);
    router.go(kOnboardingPath);
    await tester.pumpAndSettle();

    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.byType(OnboardingScreen), findsNothing);
  });

  testWidgets(
    'a gate that has not loaded yet holds Home rather than guessing',
    (tester) async {
      final session = testSession();
      SharedPreferences.setMockInitialValues({});
      // Deliberately not loaded: `seen` is false but so is `loaded`, and
      // flashing the intro at somebody who has already seen it is worse than
      // one frame of Home.
      final onboarding = JamOnboardingPrefs();

      await pumpGated(tester, session, onboarding);

      expect(find.byType(OnboardingScreen), findsNothing);

      // Once it lands, the gate closes without anything having to push.
      await onboarding.load();
      await tester.pumpAndSettle();
      expect(find.byType(OnboardingScreen), findsOneWidget);
    },
  );

  testWidgets('a router built without a gate never shows the intro', (
    tester,
  ) async {
    // What every other screen test gets: no gate, no redirect, Home.
    final session = testSession();
    final router = await pumpApp(tester, session);
    router.go(kOnboardingPath);
    await tester.pumpAndSettle();

    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.byType(OnboardingScreen), findsNothing);
  });
}

/// Flips the flag at once, as the real one does, but holds the write until
/// the test lets it land.
class _SlowWrite extends JamOnboardingPrefs {
  final Completer<void> gate = Completer<void>();

  @override
  Future<void> markSeen() async {
    final write = super.markSeen();
    await gate.future;
    await write;
  }
}
