/// The listener page's slice of the LocalJam design tokens
/// (docs/design/DESIGN_SPEC_V3.md §2–§3, with the app's current identity
/// values from `apps/localjam_app/lib/src/design/tokens.dart`, which this
/// page cannot depend on). That file is the source of truth: a deliberate
/// copy, so a token changed there is changed here by hand. Warm paper and charcoal for chrome, raspberry
/// only on what you can tap, cover art for every other colour.
///
/// One face: Manrope, bundled with the page. The app draws body text in the
/// system face, but a browser page offline has no system face Flutter can
/// name, and an unnamed one is fetched from the internet (WEB_GUEST.md D8).
library;

import 'package:flutter/material.dart';

/// Semantic colours for one brightness.
@immutable
class PageColors {
  const PageColors({
    required this.background,
    required this.groupedSurface,
    required this.fill,
    required this.fillSecondary,
    required this.separator,
    required this.label,
    required this.secondaryLabel,
    required this.tertiaryLabel,
    required this.tint,
    required this.tintFill,
    required this.tintFilled,
    required this.onTint,
    required this.warning,
    required this.danger,
  });

  final Color background;
  final Color groupedSurface;
  final Color fill;
  final Color fillSecondary;
  final Color separator;
  final Color label;
  final Color secondaryLabel;
  final Color tertiaryLabel;
  final Color tint;
  final Color tintFill;
  final Color tintFilled;
  final Color onTint;
  final Color warning;
  final Color danger;

  static const PageColors light = PageColors(
    background: Color(0xFFFAF8F5),
    groupedSurface: Color(0xFFFFFEFC),
    fill: Color(0xFFE8E3DE),
    fillSecondary: Color(0xFFF0EBE6),
    separator: Color(0x242A2420),
    label: Color(0xFF2A2420),
    secondaryLabel: Color(0xFF6F6761),
    tertiaryLabel: Color(0xFF82786F),
    tint: Color(0xFFB82F59),
    tintFill: Color(0xFFF6E3E8),
    tintFilled: Color(0xFFB82F59),
    onTint: Color(0xFFFFFFFF),
    warning: Color(0xFFA54C20),
    danger: Color(0xFFB5343A),
  );

  static const PageColors dark = PageColors(
    background: Color(0xFF1A1715),
    groupedSurface: Color(0xFF262220),
    fill: Color(0xFF3A3532),
    fillSecondary: Color(0xFF2E2926),
    separator: Color(0x29F0E6DF),
    label: Color(0xFFF7F2EE),
    secondaryLabel: Color(0xFFBEB5AE),
    tertiaryLabel: Color(0xFF8E847D),
    tint: Color(0xFFF28AA7),
    tintFill: Color(0xFF432A34),
    tintFilled: Color(0xFFB82F59),
    onTint: Color(0xFFFFFFFF),
    warning: Color(0xFFEAAF79),
    danger: Color(0xFFFF9190),
  );

  /// The palette for [brightness].
  static PageColors of(Brightness brightness) =>
      brightness == Brightness.dark ? dark : light;
}

/// The type scale (DESIGN_SPEC_V3 §3 sizes), all Manrope, falling back to
/// the bundled Noto Sans Devanagari for what Manrope lacks (Nepali titles
/// and names): a glyph no bundled face has would otherwise send the engine
/// to its font-fallback URL, which this LAN page cannot serve.
abstract final class PageType {
  static const String family = 'Manrope';

  /// Bundled faces tried, in order, for glyphs [family] lacks.
  static const List<String> fallback = ['NotoSansDevanagari'];

  static TextStyle _style(
    double size,
    double line,
    FontWeight weight, [
    double tracking = 0,
  ]) => TextStyle(
    fontFamily: family,
    fontFamilyFallback: fallback,
    fontSize: size,
    height: line / size,
    fontWeight: weight,
    letterSpacing: tracking,
    leadingDistribution: TextLeadingDistribution.even,
  );

  static final TextStyle largeTitle = _style(34, 41, FontWeight.w700, -1.2);
  static final TextStyle title1 = _style(28, 36, FontWeight.w700, -0.8);
  static final TextStyle title2 = _style(22, 29, FontWeight.w700, -0.5);
  static final TextStyle title3 = _style(20, 27, FontWeight.w600, -0.4);
  static final TextStyle headline = _style(17, 22, FontWeight.w600);
  static final TextStyle body = _style(17, 22, FontWeight.w400);
  static final TextStyle subheadline = _style(15, 20, FontWeight.w400);
  static final TextStyle footnote = _style(13, 18, FontWeight.w400);
  static final TextStyle caption = _style(12, 16, FontWeight.w400);

  /// Fixed-width digits for times and offsets.
  static TextStyle tabular(TextStyle style) =>
      style.copyWith(fontFeatures: const [FontFeature.tabularFigures()]);
}

/// Radii and spacing (DESIGN_SPEC_V3 §2, the app's current radius table).
abstract final class Metrics {
  static const double gutter = 16;
  static const double column = 480;
  static const double button = 16;
  static const double section = 12;
  static const double cover = 18;
  static const double artworkSmall = 8;
  static const double rowMinHeight = 44;
}

/// Flat avatar colours, white initials on each (D3). A copy of
/// `JamAvatarPalette.colors` in `apps/localjam_app/lib/src/design/tokens.dart`,
/// the source of truth, in the same order: a person's face is the colour
/// their display name hashes to there ([Avatar]), so it must be the same
/// list here or a browser guest sees everyone in different colours.
const List<Color> avatarPalette = [
  Color(0xFFA86048), // terracotta
  Color(0xFF157E8E), // sea
  Color(0xFF966B27), // ochre
  Color(0xFF4A75AD), // slate
  Color(0xFF6D792F), // olive
  Color(0xFF756AAC), // indigo
  Color(0xFF2F815B), // pine
  Color(0xFF956197), // plum
];

/// The page's theme for [brightness].
ThemeData pageTheme(Brightness brightness) {
  final c = PageColors.of(brightness);
  return ThemeData(
    brightness: brightness,
    fontFamily: PageType.family,
    fontFamilyFallback: PageType.fallback,
    scaffoldBackgroundColor: c.background,
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    colorScheme: ColorScheme.fromSeed(
      seedColor: c.tint,
      brightness: brightness,
      primary: c.tint,
      surface: c.background,
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: c.tint,
      selectionColor: c.tint.withValues(alpha: 0.3),
      selectionHandleColor: c.tint,
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: c.tint,
      inactiveTrackColor: c.fill,
      thumbColor: c.tint,
      overlayShape: SliderComponentShape.noOverlay,
      trackHeight: 4,
    ),
  );
}
