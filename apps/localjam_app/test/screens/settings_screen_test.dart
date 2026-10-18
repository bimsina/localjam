/// Settings is three inset groups and nothing else: who you are, how it
/// looks, and where it came from.
library;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/widgets/rename_dialog.dart';
import 'package:localjam_app/src/design/theme.dart';
import 'package:localjam_app/src/screens/licenses_screen.dart';
import 'package:localjam_app/src/screens/settings_screen.dart';
import 'package:localjam_app/src/state/app_settings.dart';
import 'package:localjam_app/src/state/session_controller.dart';
import 'package:localjam_app/src/widgets/avatar.dart';
import 'package:localjam_app/src/widgets/list.dart';

import '../harness.dart';

Future<JamAppSettings> pumpSettings(
  WidgetTester tester,
  JamSessionController session, {
  ThemeData? theme,
}) async {
  final settings = JamAppSettings();
  await tester.pumpWidget(
    JamSettings(
      settings: settings,
      child: JamSession(
        controller: session,
        child: MaterialApp(
          theme: theme ?? jamLightTheme(),
          home: const SettingsScreen(),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return settings;
}

void main() {
  testWidgets('beside a sidebar, the column is sized from the pane and '
      'starts on the large title’s edge', (tester) async {
    // The iPad P1: (window − 640) / 2 of padding inside a pane that was
    // already 260 narrower left a 380 strip drifting right of its title.
    tester.view.physicalSize = const Size(1032, 1000) * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final session = testSession();
    await tester.pumpWidget(
      JamSettings(
        settings: JamAppSettings(),
        child: JamSession(
          controller: session,
          child: MaterialApp(
            theme: jamLightTheme(),
            home: const Row(
              children: [
                SizedBox(width: 260),
                Expanded(child: SettingsScreen()),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final pane = tester.getRect(find.byType(SettingsScreen));
    final row = tester.getRect(
      find.ancestor(
        of: find.text(SettingsStrings.system),
        matching: find.byType(JamRow),
      ),
    );
    // The grouped block starts at the page margin, where the large title
    // does, and the column is the reading width, not a 380 strip.
    expect(row.left - pane.left, inInclusiveRange(16, 20));
    expect(row.width, greaterThan(600));
    expect(row.right - pane.left, lessThanOrEqualTo(672));
  });

  testWidgets('you, appearance, about — and nothing else', (tester) async {
    final session = testSession();
    await pumpSettings(tester, session);

    expect(find.text(SettingsStrings.title), findsWidgets);
    expect(find.text(SettingsStrings.appearance), findsOneWidget);
    expect(find.text(SettingsStrings.about), findsOneWidget);

    expect(find.text('Silky Puffin'), findsOneWidget);
    expect(find.text(SettingsStrings.howYouAppear), findsOneWidget);
    // The 56 dp profile face, not a list-sized one.
    final avatar = tester.widget<JamAvatar>(find.byType(JamAvatar).first);
    expect(avatar.size, JamAvatarSize.profile);

    expect(find.text(SettingsStrings.version), findsOneWidget);
    expect(find.text(kAppVersion), findsOneWidget);
    expect(find.text(SettingsStrings.openSource), findsOneWidget);
    expect(find.text(SettingsStrings.licences), findsOneWidget);

    // Room behaviour stays in the room.
    expect(find.textContaining('sync'), findsNothing);
    expect(find.textContaining('Everyone can'), findsNothing);
  });

  testWidgets('renaming goes through the one shared prompt', (tester) async {
    final session = testSession();
    await pumpSettings(tester, session);

    await tester.tap(find.text('Silky Puffin'));
    await tester.pumpAndSettle();
    expect(find.text(RenameStrings.title), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('appearance is three plain checkmark rows', (tester) async {
    final session = testSession();
    final settings = await pumpSettings(tester, session);

    for (final label in [
      SettingsStrings.system,
      SettingsStrings.light,
      SettingsStrings.dark,
    ]) {
      expect(find.text(label), findsOneWidget);
    }
    // No preview thumbnails, no radio circles: one checkmark on the choice.
    bool checked(String label) =>
        tester.widget<JamRow>(find.widgetWithText(JamRow, label)).checked;
    expect(settings.themeMode, ThemeMode.system);
    expect(checked(SettingsStrings.system), isTrue);
    expect(find.byIcon(CupertinoIcons.checkmark), findsOneWidget);

    await tester.tap(find.text(SettingsStrings.dark));
    await tester.pumpAndSettle();
    expect(settings.themeMode, ThemeMode.dark);
    expect(checked(SettingsStrings.dark), isTrue);
    expect(checked(SettingsStrings.system), isFalse);
    expect(find.byIcon(CupertinoIcons.checkmark), findsOneWidget);
  });

  testWidgets('the licences page opens', (tester) async {
    final session = testSession();
    await pumpSettings(tester, session);

    await tester.ensureVisible(find.text(SettingsStrings.licences));
    await tester.pumpAndSettle();
    await tester.tap(find.text(SettingsStrings.licences));
    await tester.pumpAndSettle();
    expect(find.byType(JamLicensesScreen), findsOneWidget);
    // Cupertino all the way: no Material licence page or app bar.
    expect(find.byType(LicensePage), findsNothing);
    expect(find.byType(AppBar), findsNothing);
    expect(find.text(SettingsStrings.appName), findsOneWidget);
  });

  testWidgets('renders on the dark palette', (tester) async {
    final session = testSession();
    await pumpSettings(tester, session, theme: jamDarkTheme());

    expect(tester.takeException(), isNull);
    expect(find.text(SettingsStrings.appearance), findsOneWidget);
  });
}
