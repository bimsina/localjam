import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/design/theme.dart';
import 'package:localjam_app/src/design/tokens.dart';

void main() {
  test('both themes carry the JamColors extension', () {
    expect(jamLightTheme().extension<JamColors>(), JamColors.light);
    expect(jamDarkTheme().extension<JamColors>(), JamColors.dark);
  });

  test('light is the designed-against theme and dark is a real peer', () {
    final light = jamLightTheme();
    final dark = jamDarkTheme();
    expect(light.brightness, Brightness.light);
    expect(dark.brightness, Brightness.dark);
    // Not an inversion: the accent is re-picked for the dark ground, because
    // the light theme's burnt orange does not read on near-black.
    expect(JamColors.dark.accent, isNot(JamColors.light.accent));
    // Both themes style the same surfaces — the old app built a light theme
    // that was missing the card and input customisations dark had.
    for (final theme in [light, dark]) {
      expect(theme.cardTheme.elevation, 0);
      expect(theme.inputDecorationTheme.filled, isTrue);
      expect(theme.bottomSheetTheme.showDragHandle, isTrue);
      expect(theme.scaffoldBackgroundColor, isNotNull);
    }
  });

  testWidgets('jamColors resolves from context in both themes', (tester) async {
    for (final (theme, expected) in [
      (jamLightTheme(), JamColors.light),
      (jamDarkTheme(), JamColors.dark),
    ]) {
      late JamColors seen;
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Builder(
            builder: (context) {
              seen = context.jamColors;
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(seen, expected);
    }
  });
}
