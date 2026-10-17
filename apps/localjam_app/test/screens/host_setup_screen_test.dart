/// Host setup: the defaults that make "one tap to sound" true, and the shapes
/// §5 and §6.5 replaced the old form controls with.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/design/theme.dart';
import 'package:localjam_app/src/router.dart';
import 'package:localjam_app/src/screens/host_setup_screen.dart';
import 'package:localjam_app/src/widgets/buttons.dart';
import 'package:localjam_app/src/widgets/track_row.dart';
import 'package:localjam_client/localjam_client.dart';

import '../harness.dart';

/// Tall enough that the Music section is on screen without scrolling — the
/// default 800×600 test surface stops a lazy `ListView` from building it.
Future<void> _tall(WidgetTester tester) async {
  tester.view.physicalSize =
      const Size(420, 1400) * tester.view.devicePixelRatio;
  addTearDown(tester.view.resetPhysicalSize);
}

void main() {
  testWidgets('the screen opens on a named room and one primary action', (
    tester,
  ) async {
    final session = testSession();
    final router = await pumpApp(tester, session);
    router.push('/host');
    await tester.pumpAndSettle();

    expect(find.text(HostSetupStrings.title), findsOneWidget);
    // An editable heading, not a form field: the name is already filled in.
    final field = tester.widget<TextField>(find.byType(TextField));
    // A typographic apostrophe: the name is 26 dp type, not a code literal.
    expect(field.controller!.text, 'Silky Puffin\u2019s Jam');
    expect(field.style!.fontSize, 26);
    final fieldTheme = tester.widget<Theme>(
      find
          .ancestor(of: find.byType(TextField), matching: find.byType(Theme))
          .first,
    );
    expect(fieldTheme.data.inputDecorationTheme.border, InputBorder.none);
    expect(fieldTheme.data.inputDecorationTheme.filled, isFalse);

    // §8 check 5: exactly one raspberry-filled control in view.
    final primaries = tester
        .widgetList<JamButton>(find.byType(JamButton))
        .where((b) => b.variant == JamButtonVariant.primary);
    expect(primaries.length, 1);
    expect(primaries.single.label, HostSetupStrings.start);
  });

  testWidgets('the policy presets are cards, and "Add music" is the default', (
    tester,
  ) async {
    final session = testSession();
    final router = await pumpApp(tester, session);
    router.push('/host');
    await tester.pumpAndSettle();

    // §6.5: the SegmentedButton is gone.
    expect(find.byType(SegmentedButton<JamPolicy>), findsNothing);
    for (final label in [
      HostSetupStrings.presetEverything,
      HostSetupStrings.presetAddMusic,
      HostSetupStrings.presetListen,
    ]) {
      expect(find.text(label), findsOneWidget);
    }

    // The engine's own default, not the old screen's `open`.
    expect(find.text(HostSetupStrings.presetAddMusicDetail), findsOneWidget);
    expect(
      tester
          .widget<Semantics>(
            find
                .ancestor(
                  of: find.text(HostSetupStrings.presetAddMusic),
                  matching: find.byType(Semantics),
                )
                .first,
          )
          .properties
          .selected,
      isTrue,
    );

    await tester.tap(find.text(HostSetupStrings.presetListen));
    await tester.pumpAndSettle();
    expect(find.text(HostSetupStrings.presetListenDetail), findsOneWidget);
  });

  testWidgets('"Host it again" tracks arrive as track rows, removable', (
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

    expect(find.byType(JamTrackRow), findsNWidgets(2));
    // §6.5: real titles, not `_basename(path)` with its extension showing.
    expect(find.text('Night Drive'), findsOneWidget);
    expect(find.text('Second Wind'), findsOneWidget);
    expect(find.textContaining('.mp3'), findsNothing);

    await tester.tap(find.byIcon(Icons.close_rounded).first);
    await tester.pumpAndSettle();
    expect(find.byType(JamTrackRow), findsOneWidget);
  });

  testWidgets('renders on the dark palette', (tester) async {
    final session = testSession();
    final router = await pumpApp(tester, session, theme: jamDarkTheme());
    router.push('/host');
    await tester.pumpAndSettle();

    expect(find.text(HostSetupStrings.title), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
