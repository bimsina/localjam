/// Settings is three groups and nothing else: who you are, how it looks,
/// and where it came from — on the same paper as Nearby.
library;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/design/theme.dart';
import 'package:localjam_app/src/screens/licenses_screen.dart';
import 'package:localjam_app/src/screens/settings_screen.dart';
import 'package:localjam_app/src/state/app_settings.dart';
import 'package:localjam_app/src/state/session_controller.dart';
import 'package:localjam_app/src/widgets/avatar.dart';
import 'package:localjam_app/src/widgets/list.dart';
import 'package:localjam_app/src/widgets/rename_dialog.dart';
import 'package:localjam_app/src/widgets/scaffold.dart';
import 'package:localjam_app/src/widgets/section.dart';
import 'package:localjam_app/src/widgets/switch.dart';
import 'package:material_ui/material_ui.dart';

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
      'centres in it', (tester) async {
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
        of: find.text(SettingsStrings.version),
        matching: find.byType(JamRow),
      ),
    );
    // The reading column centres in the pane — not the window — and is
    // the reading width, not a 380 strip.
    expect(row.left - pane.left, closeTo(pane.right - row.right, 1));
    expect(row.width, greaterThan(580));
    expect(row.width, lessThanOrEqualTo(640));
    // (The large title on the column's edge is JamScaffold's own test.)
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

  testWidgets('appearance is one segmented control, not a section of '
      'checkmark rows', (tester) async {
    final session = testSession();
    final settings = await pumpSettings(tester, session);

    expect(find.byType(JamSegmentedControl<ThemeMode>), findsOneWidget);
    for (final label in [
      SettingsStrings.system,
      SettingsStrings.light,
      SettingsStrings.dark,
    ]) {
      expect(find.text(label), findsOneWidget);
    }
    // No checkmark rows left over.
    expect(find.byIcon(CupertinoIcons.checkmark_alt), findsNothing);
    ThemeMode? selected() => tester
        .widget<JamSegmentedControl<ThemeMode>>(
          find.byType(JamSegmentedControl<ThemeMode>),
        )
        .groupValue;
    expect(settings.themeMode, ThemeMode.system);
    expect(selected(), ThemeMode.system);
    // Each choice is announced as a selectable button inside "Appearance".
    expect(
      tester.getSemantics(find.text(SettingsStrings.system)),
      matchesSemantics(
        label: SettingsStrings.system,
        isButton: true,
        hasSelectedState: true,
        isSelected: true,
        isInMutuallyExclusiveGroup: true,
        hasTapAction: true,
        hasFocusAction: true,
        isFocusable: true,
      ),
    );

    await tester.tap(find.text(SettingsStrings.dark));
    await tester.pumpAndSettle();
    expect(settings.themeMode, ThemeMode.dark);
    expect(selected(), ThemeMode.dark);
  });

  testWidgets('Source Code has one line under it, not two', (tester) async {
    // SU-4: the row sits inside an in-place confirmation, so the section
    // draws the line under it — and the row used to draw a second.
    final session = testSession();
    await pumpSettings(tester, session);
    final row = find.ancestor(
      of: find.text(SettingsStrings.openSource),
      matching: find.byType(JamRow),
    );
    expect(tester.widget<JamRow>(row).separator, isFalse);
    expect(
      find.descendant(of: row, matching: find.byType(JamHairline)),
      findsNothing,
    );
  });

  testWidgets('the blocks sit on the page’s paper, edged like Nearby’s '
      'cards', (tester) async {
    final session = testSession();
    await pumpSettings(tester, session);
    final scaffold = tester.widget<JamScaffold>(find.byType(JamScaffold));
    expect(scaffold.grouped, isFalse);
    final sections = tester.widgetList<JamSection>(find.byType(JamSection));
    expect(sections.where((s) => s.bordered), hasLength(2));
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
