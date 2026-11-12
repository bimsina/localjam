import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/design/theme.dart';
import 'package:localjam_app/src/design/tokens.dart';
import 'package:material_ui/material_ui.dart';

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
    expect(d.background, const Color(0xFF1A1715));
    expect(l.groupedBackground, const Color(0xFFF2EFEB));
    // Rows in a grouped sheet stand off its ground as they do on a screen.
    expect(l.elevatedGroupedBackground, l.groupedBackground);
    expect(d.groupedSurface, const Color(0xFF262220));
    expect(d.elevatedGroupedSurface, const Color(0xFF302B28));
    expect(l.tint, const Color(0xFFB82F59));
    expect(d.tint, const Color(0xFFF28AA7));
    expect(l.success, const Color(0xFF3E8068));
    expect(l.danger, const Color(0xFFB5343A));
    expect(d.danger, const Color(0xFFFF9190));
    // D2: dark neutrals are warm charcoal — red over green over blue.
    for (final c in [
      d.background,
      d.groupedSurface,
      d.elevated,
      d.elevatedGroupedSurface,
      d.fill,
      d.fillSecondary,
      d.secondaryLabel,
      d.tertiaryLabel,
      JamNowPlayingColors.backdropPlaceholder,
      JamFixedColors.segmentThumbDark,
    ]) {
      expect(c.r, greaterThan(c.g), reason: '$c');
      expect(c.g, greaterThan(c.b), reason: '$c');
    }
    expect(l.separator.a, closeTo(0.14, 0.01));
    expect(l.secondaryLabel.a, closeTo(1, 0.01));
    expect(l.material.a, closeTo(0.96, 0.01));
    expect(JamShadow.artwork.single.blurRadius, 30);
    expect(JamShadow.artwork.single.offset, const Offset(0, 12));
    // Soft rectangles (v4): no capsule radius exists to reach for.
    expect(JamRadius.button, 16);
    expect(JamRadius.buttonSmall, 10);
    expect(JamRadius.alertButton, 14);
    expect(JamRadius.notice, 16);
    expect(JamRadius.miniPlayer, 20);
    expect(JamRadius.largeCover, 18);
    expect(JamRadius.artwork(JamRadius.largeCoverFrom), JamRadius.largeCover);
    expect(JamRadius.alert, 34);
    expect(JamRadius.menu, 22);
    expect(JamRadius.sheetFloating, 38);
    expect(JamRadius.section, 20);
    // A lone 44 row is not a pill; a taller block keeps the full 26.
    expect(JamRadius.sectionFor(44), JamRadius.md);
    expect(JamRadius.menuFor(44), JamRadius.md);
    expect(JamRadius.sectionFor(120), JamRadius.section);
    // Filled tint holds white at AA in both themes.
    double contrast(Color a, Color b) {
      final la = a.computeLuminance(), lb = b.computeLuminance();
      return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
    }

    expect(contrast(l.tintFilled, l.onTint), greaterThanOrEqualTo(4.5));
    expect(contrast(d.tintFilled, d.onTint), greaterThanOrEqualTo(4.5));
    // …and so does filled danger (the alert's End Jam).
    for (final c in [
      l,
      d,
      JamColors.lightHighContrast,
      JamColors.darkHighContrast,
    ]) {
      expect(contrast(c.dangerFilled, c.onTint), greaterThanOrEqualTo(4.5));
    }
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

  group('contrast, in every palette', () {
    double blend(Color fg, Color bg) =>
        Color.alphaBlend(fg, bg).computeLuminance();
    double contrast(Color fg, Color bg) {
      final lb = bg.computeLuminance();
      final lf = blend(fg, bg);
      return (math.max(lf, lb) + 0.05) / (math.min(lf, lb) + 0.05);
    }

    final palettes = {
      'light': JamColors.light,
      'dark': JamColors.dark,
      'light HC': JamColors.lightHighContrast,
      'dark HC': JamColors.darkHighContrast,
    };
    List<(String, Color)> grounds(JamColors c) => [
      ('background', c.background),
      ('groupedBackground', c.groupedBackground),
      ('groupedSurface', c.groupedSurface),
      ('elevated', c.elevated),
      ('elevatedGroupedBackground', c.elevatedGroupedBackground),
      ('elevatedGroupedSurface', c.elevatedGroupedSurface),
      ('fillSecondary', c.fillSecondary),
    ];

    for (final MapEntry(key: name, value: c) in palettes.entries) {
      test('$name: text at 4.5:1 on every ground', () {
        for (final (g, ground) in grounds(c)) {
          for (final (f, fg) in [
            ('label', c.label),
            ('secondaryLabel', c.secondaryLabel),
            ('tint', c.tint),
            ('danger', c.danger),
            ('warning', c.warning),
          ]) {
            expect(
              contrast(fg, ground),
              greaterThanOrEqualTo(4.5),
              reason: '$f on $g',
            );
          }
        }
        // Grey and tinted buttons carry their label at AA too.
        expect(contrast(c.tint, c.fill), greaterThanOrEqualTo(4.5));
        expect(contrast(c.danger, c.fill), greaterThanOrEqualTo(4.5));
        expect(contrast(c.tint, c.tintFill), greaterThanOrEqualTo(4.5));
      });

      test('$name: indicators (tertiaryLabel) at 3:1 on every ground', () {
        for (final (g, ground) in [...grounds(c), ('fill', c.fill)]) {
          expect(
            contrast(c.tertiaryLabel, ground),
            greaterThanOrEqualTo(3),
            reason: 'tertiaryLabel on $g',
          );
        }
      });
    }

    test('Increase Contrast never lowers a ratio', () {
      for (final (base, hc) in [
        (JamColors.light, JamColors.lightHighContrast),
        (JamColors.dark, JamColors.darkHighContrast),
      ]) {
        for (final (g, ground) in grounds(base)) {
          for (final pick in <Color Function(JamColors)>[
            (c) => c.secondaryLabel,
            (c) => c.tertiaryLabel,
            (c) => c.tint,
            (c) => c.danger,
            (c) => c.warning,
          ]) {
            expect(
              contrast(pick(hc), ground),
              greaterThanOrEqualTo(contrast(pick(base), ground) - 0.01),
              reason: g,
            );
          }
        }
        expect(
          contrast(hc.onTint, hc.dangerFilled),
          greaterThanOrEqualTo(contrast(base.onTint, base.dangerFilled)),
        );
      }
    });

    test('R7: light inks are warm, and no ratio fell to get there', () {
      const l = JamColors.light;
      final hc = JamColors.lightHighContrast;
      // R ≥ G > B: the paper's (and the dark theme's) temperature, not plum.
      for (final c in [
        l.label,
        l.secondaryLabel,
        l.tertiaryLabel,
        l.separator,
        l.fillPressed,
        l.scrim,
        hc.secondaryLabel,
        hc.tertiaryLabel,
        hc.separator,
      ]) {
        expect(c.r, greaterThanOrEqualTo(c.g), reason: '$c');
        expect(c.g, greaterThan(c.b), reason: '$c');
      }
      // The plum inks they replaced, ratio for ratio on every ground.
      final before = <(String, Color, Color)>[
        ('label', const Color(0xFF292428), l.label),
        ('secondaryLabel', const Color(0xFF71686D), l.secondaryLabel),
        ('tertiaryLabel', const Color(0xFF857A80), l.tertiaryLabel),
        ('HC secondaryLabel', const Color(0xFF5E565B), hc.secondaryLabel),
        ('HC tertiaryLabel', const Color(0xFF72686E), hc.tertiaryLabel),
      ];
      for (final (name, was, now) in before) {
        for (final (g, ground) in [
          ...grounds(l),
          ('fill', l.fill),
          ('tintFill', l.tintFill),
        ]) {
          expect(
            contrast(now, ground),
            greaterThanOrEqualTo(contrast(was, ground)),
            reason: '$name on $g',
          );
        }
      }
    });

    test('the dark scrim dims the page under an alert', () {
      const d = JamColors.dark;
      final dimmed = Color.alphaBlend(d.scrim, d.background);
      expect(
        d.elevated.computeLuminance(),
        greaterThan(dimmed.computeLuminance() * 1.5),
      );
    });

    test('on the backdrop: handles at 3:1, red and amber at 4.5:1', () {
      // The brightest ground the backdrop allows: secondary white at 4.6.
      const worst = Color(0xFF555555);
      expect(
        contrast(JamNowPlayingColors.tertiary, worst),
        greaterThanOrEqualTo(3),
      );
      final colors = jamBackdropColors(JamColors.light);
      expect(contrast(colors.danger, worst), greaterThanOrEqualTo(4.5));
      expect(contrast(colors.warning, worst), greaterThanOrEqualTo(4.5));
      expect(
        contrast(
          JamNowPlayingColors.playGlyph,
          JamNowPlayingColors.playSurface,
        ),
        greaterThanOrEqualTo(7),
      );
    });
  });
}
