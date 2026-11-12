import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/design/theme.dart';
import 'package:localjam_app/src/design/tokens.dart';
import 'package:localjam_app/src/design/typography.dart';
import 'package:material_ui/material_ui.dart';

/// Relative luminance per WCAG 2.1, with a translucent foreground composited
/// over its ground first.
double _luminance(Color c) {
  double channel(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
}

double contrast(Color fg, Color bg) {
  final a = _luminance(Color.alphaBlend(fg, bg));
  final b = _luminance(bg);
  final hi = a > b ? a : b;
  final lo = a > b ? b : a;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  test('Manrope headings and platform-native body text', () {
    final ios = buildJamTypeScale(
      platform: TargetPlatform.iOS,
      color: JamColors.light.label,
    );
    expect(ios.body.fontFamily, 'CupertinoSystemText');
    expect(ios.footnote.fontFamily, 'CupertinoSystemText');
    // SF switches to its Display cut at 20 pt and up.
    expect(ios.title3.fontFamily, 'Manrope');
    expect(ios.largeTitle.fontFamily, 'Manrope');

    final android = buildJamTypeScale(
      platform: TargetPlatform.android,
      color: JamColors.light.label,
    );
    expect(android.body.fontFamily, 'Roboto');
    final windows = buildJamTypeScale(
      platform: TargetPlatform.windows,
      color: JamColors.light.label,
    );
    expect(windows.body.fontFamily, 'Segoe UI');
    for (final s in [ios.body, android.body]) {
      expect(s.fontFamily, isNot('Plus Jakarta Sans'));
    }
  });

  test('Manrope never rewrites a straight apostrophe into a curly one', () {
    // Its `calt` did, in the Now Playing title only: "Pappu Can't Dance"
    // read "Can’t" there and "Can't" everywhere else. Titles are set as
    // written.
    for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
      final s = buildJamTypeScale(
        platform: platform,
        color: JamColors.light.label,
      );
      for (final style in [s.largeTitle, s.title1, s.title2, s.title3]) {
        expect(style.fontFamily, 'Manrope');
        expect(style.fontFeatures, contains(const FontFeature.disable('calt')));
      }
    }
  });

  test('the scale matches the spec table', () {
    final s = buildJamTypeScale(
      platform: TargetPlatform.iOS,
      color: JamColors.light.label,
    );
    void check(
      TextStyle style,
      double size,
      double line,
      FontWeight w,
      double t,
    ) {
      expect(style.fontSize, size);
      expect(style.height! * size, closeTo(line, 0.001));
      expect(style.fontWeight, w);
      expect(style.letterSpacing, t);
    }

    check(s.largeTitle, 34, 41, FontWeight.w700, -1.2);
    check(s.title1, 28, 36, FontWeight.w700, -0.8);
    check(s.title2, 22, 29, FontWeight.w700, -0.5);
    check(s.title3, 20, 27, FontWeight.w600, -0.4);
    check(s.headline, 17, 22, FontWeight.w600, -0.43);
    check(s.body, 17, 22, FontWeight.w400, -0.43);
    check(s.callout, 16, 21, FontWeight.w400, -0.31);
    check(s.subheadline, 15, 20, FontWeight.w400, -0.23);
    check(s.footnote, 13, 18, FontWeight.w400, -0.08);
    check(s.caption1, 12, 16, FontWeight.w400, 0);
    check(s.caption2, 11, 13, FontWeight.w400, 0.06);
  });

  test('SF tracking applies on Apple platforms only', () {
    for (final p in [TargetPlatform.iOS, TargetPlatform.macOS]) {
      final s = buildJamTypeScale(platform: p, color: JamColors.light.label);
      expect(s.body.letterSpacing, -0.43);
    }
    for (final p in [
      TargetPlatform.android,
      TargetPlatform.windows,
      TargetPlatform.linux,
    ]) {
      final s = buildJamTypeScale(platform: p, color: JamColors.light.label);
      expect(s.body.letterSpacing, 0);
      expect(s.largeTitle.letterSpacing, -1.2);
    }
  });

  test('numeric styles ask for tabular figures', () {
    final style = jamNumericStyle(JamColors.light.secondaryLabel);
    expect(style.fontFeatures, contains(const FontFeature.tabularFigures()));
    expect(
      jamTabular(const TextStyle()).fontFeatures,
      contains(const FontFeature.tabularFigures()),
    );
  });

  testWidgets('the named getters resolve from the theme', (tester) async {
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
    expect(ctx.jamLargeTitle.fontSize, 34);
    expect(ctx.jamTitle1.fontSize, 28);
    expect(ctx.jamTitle2.fontSize, 22);
    expect(ctx.jamTitle3.fontSize, 20);
    expect(ctx.jamHeadline.fontSize, 17);
    expect(ctx.jamHeadline.fontWeight, FontWeight.w600);
    expect(ctx.jamBody.fontSize, 17);
    expect(ctx.jamCallout.fontSize, 16);
    expect(ctx.jamSubheadline.fontSize, 15);
    expect(ctx.jamFootnote.fontSize, 13);
    expect(ctx.jamCaption1.fontSize, 12);
    expect(ctx.jamCaption2.fontSize, 11);
    expect(ctx.jamBody.color, JamColors.light.label);
    expect(ctx.jamNumeric.color, JamColors.light.secondaryLabel);
    expect(
      ctx.jamNumeric.fontFeatures,
      contains(const FontFeature.tabularFigures()),
    );
  });

  test('the text theme carries the same scale', () {
    final theme = jamLightTheme(platform: TargetPlatform.iOS);
    expect(theme.textTheme.bodyLarge!.fontSize, 17);
    expect(theme.textTheme.bodySmall!.fontSize, 13);
    expect(theme.textTheme.displayLarge!.fontSize, 34);
    expect(theme.extension<JamTypeScale>(), isNotNull);
  });

  test('text colours hold their contrast on the grounds they sit on', () {
    for (final c in [JamColors.light, JamColors.dark]) {
      for (final ground in [
        c.background,
        c.groupedBackground,
        c.groupedSurface,
        c.elevated,
      ]) {
        expect(contrast(c.label, ground), greaterThanOrEqualTo(4.5));
        // Apple's secondaryLabel: 3:1 is its design floor on light grounds.
        expect(contrast(c.secondaryLabel, ground), greaterThanOrEqualTo(4.5));
      }
      expect(contrast(c.tint, c.background), greaterThanOrEqualTo(4.5));
      expect(contrast(c.warning, c.background), greaterThanOrEqualTo(4.5));
      // Filled-button labels (17 semibold): at least the large-text floor.
      expect(contrast(c.onTint, c.tintFilled), greaterThanOrEqualTo(4.5));
    }
  });
}
