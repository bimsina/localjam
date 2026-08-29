/// The LocalJam design tokens.
///
/// Light-first: the light palette is the one the app is designed against and
/// dark is a full peer, not an inversion afterthought. Chrome stays neutral so
/// cover art supplies the colour (the Apple Music stance); a single ember
/// accent carries interactive state, and only *problems* get a hue of their
/// own — "in sync" is deliberately quiet.
library;

import 'package:flutter/material.dart';

/// Semantic colours, resolved per theme. Read them from the context rather
/// than importing the constants directly: `context.jamColors.accent`.
@immutable
class JamColors extends ThemeExtension<JamColors> {
  const JamColors({
    required this.canvas,
    required this.surface,
    required this.surfaceMuted,
    required this.separator,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.accent,
    required this.accentPressed,
    required this.accentSoft,
    required this.onAccent,
    required this.warning,
    required this.danger,
    required this.scrim,
  });

  /// The page behind everything.
  final Color canvas;

  /// Cards, sheets, list backgrounds. Separated from [canvas] by a hairline
  /// on light and by lightness on dark.
  final Color surface;

  /// Inset areas: artwork placeholders, chips, disabled fills, track slots.
  final Color surfaceMuted;

  /// Hairline rules between rows and sections.
  final Color separator;

  /// Titles and primary values.
  final Color textPrimary;

  /// Bylines, labels, and the quiet "in sync" state.
  final Color textSecondary;

  /// Placeholder and disabled text.
  final Color textTertiary;

  /// The one accent: primary actions, selection, live indicators.
  final Color accent;

  /// [accent] while pressed.
  final Color accentPressed;

  /// A tinted fill for selected rows and accent chips.
  final Color accentSoft;

  /// Text and icons drawn on top of [accent].
  final Color onAccent;

  /// Recoverable trouble: catching up, low battery, degraded route.
  final Color warning;

  /// Failure: fetch failed, kicked, session ended, unsupported format.
  final Color danger;

  /// Behind modal sheets.
  final Color scrim;

  /// The light palette — the primary design target.
  static const JamColors light = JamColors(
    canvas: Color(0xFFFFFFFF),
    surface: Color(0xFFFFFFFF),
    surfaceMuted: Color(0xFFF4F4F6),
    separator: Color(0xFFE3E3E7),
    textPrimary: Color(0xFF16161A),
    textSecondary: Color(0xFF6E6E78),
    textTertiary: Color(0xFFA0A0AA),
    accent: Color(0xFFC2410C),
    accentPressed: Color(0xFF9A340A),
    accentSoft: Color(0xFFFDF0E8),
    onAccent: Color(0xFFFFFFFF),
    warning: Color(0xFFB45309),
    danger: Color(0xFFC42B1C),
    scrim: Color(0x33000000),
  );

  /// The dark palette: same structure, inverted ramp, brighter accent (the
  /// light theme's burnt orange does not read on a dark ground).
  static const JamColors dark = JamColors(
    canvas: Color(0xFF0E0E11),
    surface: Color(0xFF17171C),
    surfaceMuted: Color(0xFF1F1F26),
    separator: Color(0xFF2A2A32),
    textPrimary: Color(0xFFF2F2F5),
    textSecondary: Color(0xFF9A9AA5),
    textTertiary: Color(0xFF6A6A75),
    accent: Color(0xFFFF7A45),
    accentPressed: Color(0xFFE5632F),
    accentSoft: Color(0xFF2A1810),
    onAccent: Color(0xFF16161A),
    warning: Color(0xFFE8A33D),
    danger: Color(0xFFFF6B5E),
    scrim: Color(0x66000000),
  );

  @override
  JamColors copyWith({
    Color? canvas,
    Color? surface,
    Color? surfaceMuted,
    Color? separator,
    Color? textPrimary,
    Color? textSecondary,
    Color? textTertiary,
    Color? accent,
    Color? accentPressed,
    Color? accentSoft,
    Color? onAccent,
    Color? warning,
    Color? danger,
    Color? scrim,
  }) => JamColors(
    canvas: canvas ?? this.canvas,
    surface: surface ?? this.surface,
    surfaceMuted: surfaceMuted ?? this.surfaceMuted,
    separator: separator ?? this.separator,
    textPrimary: textPrimary ?? this.textPrimary,
    textSecondary: textSecondary ?? this.textSecondary,
    textTertiary: textTertiary ?? this.textTertiary,
    accent: accent ?? this.accent,
    accentPressed: accentPressed ?? this.accentPressed,
    accentSoft: accentSoft ?? this.accentSoft,
    onAccent: onAccent ?? this.onAccent,
    warning: warning ?? this.warning,
    danger: danger ?? this.danger,
    scrim: scrim ?? this.scrim,
  );

  @override
  bool operator ==(Object other) =>
      other is JamColors &&
      other.canvas == canvas &&
      other.surface == surface &&
      other.surfaceMuted == surfaceMuted &&
      other.separator == separator &&
      other.textPrimary == textPrimary &&
      other.textSecondary == textSecondary &&
      other.textTertiary == textTertiary &&
      other.accent == accent &&
      other.accentPressed == accentPressed &&
      other.accentSoft == accentSoft &&
      other.onAccent == onAccent &&
      other.warning == warning &&
      other.danger == danger &&
      other.scrim == scrim;

  @override
  int get hashCode => Object.hash(
    canvas,
    surface,
    surfaceMuted,
    separator,
    textPrimary,
    textSecondary,
    textTertiary,
    accent,
    accentPressed,
    accentSoft,
    onAccent,
    warning,
    danger,
    scrim,
  );

  @override
  JamColors lerp(covariant JamColors? other, double t) {
    if (other == null) return this;
    Color mix(Color a, Color b) => Color.lerp(a, b, t)!;
    return JamColors(
      canvas: mix(canvas, other.canvas),
      surface: mix(surface, other.surface),
      surfaceMuted: mix(surfaceMuted, other.surfaceMuted),
      separator: mix(separator, other.separator),
      textPrimary: mix(textPrimary, other.textPrimary),
      textSecondary: mix(textSecondary, other.textSecondary),
      textTertiary: mix(textTertiary, other.textTertiary),
      accent: mix(accent, other.accent),
      accentPressed: mix(accentPressed, other.accentPressed),
      accentSoft: mix(accentSoft, other.accentSoft),
      onAccent: mix(onAccent, other.onAccent),
      warning: mix(warning, other.warning),
      danger: mix(danger, other.danger),
      scrim: mix(scrim, other.scrim),
    );
  }
}

/// The spacing scale. Codifies the values the pre-overhaul screens repeated
/// inline (page padding 20/24, card padding 16, section gap 16).
abstract final class JamSpace {
  static const double xxs = 2;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;
  static const double xxxl = 32;
  static const double huge = 40;

  /// Horizontal page margin.
  static const double page = 20;

  /// Padding inside a card or grouped section.
  static const double card = 16;

  /// Gap between top-level sections.
  static const double section = 24;
}

/// Corner radii.
abstract final class JamRadius {
  static const double xs = 6;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double pill = 999;

  /// Artwork corner radius for a given edge length — the ratio the old
  /// [JamArtwork] used, kept so thumbnails and heroes stay a family.
  static double artwork(double size) => (size / 8).clamp(xs, xl);
}

/// Standard artwork sizes.
abstract final class JamArtworkSize {
  /// List-row thumbnail.
  static const double thumb = 44;

  /// Docked room bar.
  static const double bar = 40;

  /// Now-playing hero. A ceiling for tablets and desktop only — on a phone
  /// the page width bounds first, so the cover lines up with the title's
  /// margin the way it does in Spotify and Apple Music.
  static const double hero = 420;
}

/// Motion. Short and unfussy — this app is looked at in a moving vehicle.
abstract final class JamDuration {
  static const Duration fast = Duration(milliseconds: 120);
  static const Duration base = Duration(milliseconds: 200);
  static const Duration slow = Duration(milliseconds: 320);
}

/// Reads the [JamColors] for the current theme.
extension JamColorsOf on BuildContext {
  JamColors get jamColors =>
      Theme.of(this).extension<JamColors>() ?? JamColors.light;
}
