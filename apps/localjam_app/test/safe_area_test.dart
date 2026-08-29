/// Every screen must inset for the home indicator and the notch.
///
/// A guard rather than a formality: the room's utility row, the scanner's
/// hint, and the room sheet's last row all sat directly on the home indicator
/// before this pass, and nothing in the type system stops that returning.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/screens/history_screen.dart';
import 'package:localjam_app/src/screens/home_screen.dart';
import 'package:localjam_app/src/screens/host_setup_screen.dart';
import 'package:localjam_app/src/screens/settings_screen.dart';
import 'package:localjam_app/src/state/app_settings.dart';
import 'package:localjam_app/src/state/session_controller.dart';
import 'package:localjam_app/src/design/theme.dart';

import 'harness.dart';

/// A viewport with the insets of a notched phone, so an unpadded page
/// actually collides with something.
const _insets = EdgeInsets.only(top: 59, bottom: 34);

Future<void> pumpInset(
  WidgetTester tester,
  JamSessionController session,
  Widget screen,
) async {
  await tester.pumpWidget(
    JamSettings(
      settings: JamAppSettings(),
      child: JamSession(
        controller: session,
        child: MaterialApp(
          theme: jamLightTheme(),
          home: MediaQuery(
            data: const MediaQueryData(padding: _insets, viewPadding: _insets),
            child: screen,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  for (final (name, build) in <(String, Widget Function())>[
    ('Home', HomeScreen.new),
    ('History', HistoryScreen.new),
    ('Settings', SettingsScreen.new),
    ('Host setup', HostSetupScreen.new),
  ]) {
    testWidgets('$name insets for the home indicator', (tester) async {
      final session = testSession();
      await pumpInset(tester, session, build());
      await tester.pump();

      expect(
        find.byType(SafeArea),
        findsWidgets,
        reason: '$name must inset its content',
      );

      // Nothing may be painted underneath the home indicator.
      final viewport = tester.getSize(find.byType(MaterialApp));
      final floor = viewport.height - _insets.bottom;
      for (final element in find.byType(Text).evaluate()) {
        final box = element.renderObject as RenderBox?;
        if (box == null || !box.hasSize || box.size.isEmpty) continue;
        final bottom = tester.getBottomLeft(find.byWidget(element.widget)).dy;
        expect(
          bottom,
          lessThanOrEqualTo(floor),
          reason:
              '"${(element.widget as Text).data}" runs under the '
              'home indicator on $name',
        );
      }
    });
  }
}
