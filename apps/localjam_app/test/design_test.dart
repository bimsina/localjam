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
    // Not an inversion: the tint is re-picked for the dark ground.
    expect(JamColors.dark.tint, isNot(JamColors.light.tint));
    // Both themes style the same surfaces — the old app built a light theme
    // that was missing the card and input customisations dark had.
    for (final theme in [light, dark]) {
      expect(theme.cardTheme.elevation, 0);
      expect(theme.inputDecorationTheme.filled, isTrue);
      expect(theme.bottomSheetTheme.showDragHandle, isTrue);
      expect(theme.scaffoldBackgroundColor, isNotNull);
      // D2: no Material ink anywhere.
      expect(theme.splashFactory, NoSplash.splashFactory);
      expect(theme.cupertinoOverrideTheme?.primaryColor, isNotNull);
    }
  });

  test('tokens are the Apple system values from the spec', () {
    const l = JamColors.light;
    const d = JamColors.dark;
    expect(l.background, const Color(0xFFFFFFFF));
    expect(d.background, const Color(0xFF000000));
    expect(l.groupedBackground, const Color(0xFFF2F2F7));
    expect(d.groupedSurface, const Color(0xFF1C1C1E));
    expect(d.elevatedGroupedSurface, const Color(0xFF2C2C2E));
    expect(l.tint, const Color(0xFFD92C64));
    expect(d.tint, const Color(0xFFFF4F82));
    expect(l.success, const Color(0xFF34C759));
    expect(l.danger, const Color(0xFFFF3B30));
    expect(d.danger, const Color(0xFFFF453A));
    expect(l.separator.a, closeTo(0.29, 0.01));
    expect(l.secondaryLabel.a, closeTo(0.6, 0.01));
    expect(l.material.a, closeTo(0.72, 0.01));
    expect(JamShadow.artwork.single.blurRadius, 30);
    expect(JamShadow.artwork.single.offset, const Offset(0, 12));
    expect(JamRadius.alert, 14);
    expect(JamRadius.menu, 14);
    expect(JamCurve.standard, const Cubic(0.25, 0.1, 0.25, 1));
    expect(JamCurve.spring.transform(0), 0);
    expect(JamCurve.spring.transform(1), 1);
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
