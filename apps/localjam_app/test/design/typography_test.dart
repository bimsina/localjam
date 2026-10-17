import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/design/theme.dart';
import 'package:localjam_app/src/design/tokens.dart';
import 'package:localjam_app/src/design/typography.dart';

/// Relative luminance per WCAG 2.1, then the 4.5:1 contrast ratio the palette
/// claims. Both themes are checked, because a dark palette that quietly fails
/// AA is exactly the kind of thing nobody notices until a review.
double _luminance(Color c) {
  double channel(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
}

double contrast(Color a, Color b) {
  final la = _luminance(a);
  final lb = _luminance(b);
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  test('the bundled family is applied once, at the theme', () {
    for (final theme in [jamLightTheme(), jamDarkTheme()]) {
      expect(theme.textTheme.bodyLarge!.fontFamily, jamFontFamily);
      expect(theme.textTheme.headlineLarge!.fontFamily, jamFontFamily);
    }
  });

  test('the scale matches the spec at every step', () {
    final text = buildJamTextTheme(
      primary: JamColors.light.textPrimary,
      secondary: JamColors.light.textSecondary,
    );
    expect(text.displayLarge!.fontSize, 40);
    expect(text.displayLarge!.fontWeight, FontWeight.w800);
    expect(text.headlineLarge!.fontSize, 32);
    expect(text.headlineMedium!.fontSize, 26);
    expect(text.headlineSmall!.fontSize, 22);
    expect(text.titleLarge!.fontSize, 19);
    expect(text.titleMedium!.fontSize, 17);
    expect(text.titleSmall!.fontSize, 15);
    expect(text.bodyLarge!.fontSize, 16);
    expect(text.bodyMedium!.fontSize, 15);
    expect(text.bodySmall!.fontSize, 13);
    expect(text.labelLarge!.fontSize, 16);
    expect(text.labelSmall!.fontSize, 11);
    // The big titles are set tight; the body is not.
    expect(text.headlineLarge!.letterSpacing, lessThan(0));
    expect(text.bodyLarge!.letterSpacing, 0);
  });

  test('numeric styles ask for tabular figures', () {
    final style = jamNumericStyle(JamColors.light.textSecondary);
    expect(style.fontFeatures, contains(const FontFeature.tabularFigures()));
    expect(style.fontFamily, jamFontFamily);
  });

  testWidgets('jamNumeric resolves from context with tnum', (tester) async {
    late TextStyle seen;
    await tester.pumpWidget(
      MaterialApp(
        theme: jamLightTheme(),
        home: Builder(
          builder: (context) {
            seen = context.jamNumeric;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    expect(seen.fontFeatures, contains(const FontFeature.tabularFigures()));
  });

  testWidgets('the semantic aliases map onto the scale', (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
        theme: jamLightTheme(),
        home: Builder(
          builder: (context) {
            ctx = context;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    expect(ctx.jamDisplay.fontSize, 40);
    expect(ctx.jamLargeTitle.fontSize, 32);
    expect(ctx.jamTrackTitle.fontSize, 26);
    expect(ctx.jamSheetTitle.fontSize, 22);
    expect(ctx.jamTitle.fontSize, 19);
    expect(ctx.jamRowTitle.fontSize, 17);
    expect(ctx.jamBody.fontSize, 16);
    expect(ctx.jamByline.fontSize, 15);
    expect(ctx.jamFootnote.fontSize, 13);
    expect(ctx.jamCaption.fontSize, 11);
  });

  test('label colours clear AA against the ground they sit on', () {
    for (final c in [JamColors.light, JamColors.dark]) {
      expect(contrast(c.onAccent, c.accent), greaterThanOrEqualTo(4.5));
      expect(contrast(c.textPrimary, c.canvas), greaterThanOrEqualTo(4.5));
      expect(contrast(c.textPrimary, c.surface), greaterThanOrEqualTo(4.5));
      expect(contrast(c.textSecondary, c.canvas), greaterThanOrEqualTo(4.5));
      // Apricot is a fill, never text — `warning` is the readable sibling.
      expect(contrast(c.warning, c.canvas), greaterThanOrEqualTo(4.5));
      expect(contrast(c.danger, c.canvas), greaterThanOrEqualTo(4.5));
      // A snackbar draws canvas-coloured text on the primary text colour.
      expect(contrast(c.canvas, c.textPrimary), greaterThanOrEqualTo(4.5));
    }
  });
}
