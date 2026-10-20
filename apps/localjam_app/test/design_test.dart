import 'dart:math' as math;

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

  test('tokens express the warm LocalJam palette', () {
    const l = JamColors.light;
    const d = JamColors.dark;
    expect(l.background, const Color(0xFFFAF8F5));
    expect(d.background, const Color(0xFF191719));
    expect(l.groupedBackground, const Color(0xFFF2EFEB));
    expect(d.groupedSurface, const Color(0xFF252225));
    expect(d.elevatedGroupedSurface, const Color(0xFF302B2F));
    expect(l.tint, const Color(0xFFB82F59));
    expect(d.tint, const Color(0xFFF28AA7));
    expect(l.success, const Color(0xFF3E8068));
    expect(l.danger, const Color(0xFFC0393E));
    expect(d.danger, const Color(0xFFFF9190));
    expect(l.separator.a, closeTo(0.14, 0.01));
    expect(l.secondaryLabel.a, closeTo(1, 0.01));
    expect(l.material.a, closeTo(0.96, 0.01));
    expect(JamShadow.artwork.single.blurRadius, 30);
    expect(JamShadow.artwork.single.offset, const Offset(0, 12));
    // One iOS era (spec §10.3): iOS 26's rounder alerts, menus and sheets.
    expect(JamRadius.alert, 34);
    expect(JamRadius.menu, 22);
    expect(JamRadius.sheetFloating, 38);
    expect(JamRadius.section, 20);
    // A lone 44 row is not a pill; a taller block keeps the full 26.
    expect(JamRadius.sectionFor(44), lessThan(22));
    expect(JamRadius.sectionFor(120), JamRadius.section);
    // Filled tint holds white at AA in both themes.
    double contrast(Color a, Color b) {
      final la = a.computeLuminance(), lb = b.computeLuminance();
      return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
    }

    expect(contrast(l.tintFilled, l.onTint), greaterThanOrEqualTo(4.5));
    expect(contrast(d.tintFilled, d.onTint), greaterThanOrEqualTo(4.5));
    // A 402 pt Pro keeps UIKit's 16 margin; Plus / Pro Max widths get 20.
    expect(JamSpace.pageFor(402), 16);
    expect(JamSpace.pageFor(440), 20);
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
