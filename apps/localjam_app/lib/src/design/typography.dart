/// The LocalJam type scale.
///
/// One bundled family — Plus Jakarta Sans (Tokotype, OFL 1.1) — instead of the
/// platform UI face, because the app has a voice of its own and a shared
/// screen should look the same whoever is holding the phone. Its open
/// apertures stay warm at a 15 dp byline while ExtraBold holds an
/// Apple-Music-scale title without reading as a tech logotype, and it ships
/// real tabular figures, which is what keeps the room timer from jittering.
///
/// The scale is set tight and confident: hard negative tracking on the big
/// titles, a comfortable 16 dp body, and generous row text, because this UI
/// gets read at arm's length in a moving vehicle.
library;

import 'package:flutter/material.dart';

/// The bundled family. Declared once here and applied once in `theme.dart`.
const String jamFontFamily = 'Plus Jakarta Sans';

/// Builds the [TextTheme] for a palette's primary/secondary text colours.
TextTheme buildJamTextTheme({
  required Color primary,
  required Color secondary,
}) {
  TextStyle style(
    double size,
    FontWeight weight, {
    Color? color,
    double tracking = 0,
    double? height,
    List<FontFeature>? features,
  }) => TextStyle(
    // Named here rather than left to `ThemeData(fontFamily:)`. That applies
    // the family to the *theme's* text theme, but every component theme in
    // `theme.dart` (app bar titles, dialogs, snackbars, tooltips) is built
    // from this TextTheme value directly, before the apply runs — so an
    // unnamed family there fell back to the system face and app-bar titles
    // shipped in San Francisco / Roboto.
    fontFamily: jamFontFamily,
    fontSize: size,
    fontWeight: weight,
    color: color ?? primary,
    letterSpacing: tracking,
    height: height,
    fontFeatures: features,
  );

  return TextTheme(
    // The ceremonial sizes: onboarding, the jam-started moment, an empty home.
    displayLarge: style(40, FontWeight.w800, tracking: -1.2, height: 1.05),
    // Screen titles.
    headlineLarge: style(32, FontWeight.w800, tracking: -0.8, height: 1.12),
    // The now-playing track title.
    headlineMedium: style(26, FontWeight.w700, tracking: -0.6, height: 1.15),
    // Sheet titles and terminal-state titles.
    headlineSmall: style(22, FontWeight.w700, tracking: -0.4, height: 1.20),
    // Section headings and panel headers.
    titleLarge: style(19, FontWeight.w700, tracking: -0.3, height: 1.25),
    // Track and peer row titles, the room bar's title.
    titleMedium: style(17, FontWeight.w600, tracking: -0.2, height: 1.30),
    // Segmented buttons and inline labels.
    titleSmall: style(15, FontWeight.w600, tracking: -0.1, height: 1.30),
    // Running text and dialog bodies.
    bodyLarge: style(16, FontWeight.w400, height: 1.45),
    // Row bylines.
    bodyMedium: style(15, FontWeight.w400, color: secondary, height: 1.40),
    // Footnotes, counts, the sync label.
    bodySmall: style(13, FontWeight.w400, color: secondary, height: 1.35),
    // Button labels.
    labelLarge: style(16, FontWeight.w700, tracking: 0.1, height: 1.20),
    // Chip labels.
    labelMedium: style(
      13,
      FontWeight.w600,
      color: secondary,
      tracking: 0.1,
      height: 1.20,
    ),
    // Micro labels — always rendered uppercase at the call site.
    labelSmall: style(
      11,
      FontWeight.w700,
      color: secondary,
      tracking: 0.6,
      height: 1.20,
    ),
  );
}

/// Timers, drift and byte counts: fixed-width digits so a value does not
/// shuffle its own layout as it ticks. Built off the palette rather than the
/// context so non-widget code (painters, tests) can reach it too.
TextStyle jamNumericStyle(Color color) => TextStyle(
  fontFamily: jamFontFamily,
  fontSize: 13,
  fontWeight: FontWeight.w500,
  color: color,
  height: 1.20,
  fontFeatures: const [FontFeature.tabularFigures()],
);

/// Semantic type aliases, so call sites read as design rather than as
/// Material slot names.
extension JamTypography on BuildContext {
  TextTheme get _text => Theme.of(this).textTheme;

  /// The ceremonial headline: onboarding, the jam-started overlay, the hero
  /// on an empty home.
  TextStyle get jamDisplay => _text.displayLarge!;

  /// The big screen title ("Nearby", "Past jams", "Start a jam").
  TextStyle get jamLargeTitle => _text.headlineLarge!;

  /// The now-playing track title.
  TextStyle get jamTrackTitle => _text.headlineMedium!;

  /// A sheet's title, and the title of a terminal state.
  TextStyle get jamSheetTitle => _text.headlineSmall!;

  /// A section heading inside a screen.
  TextStyle get jamTitle => _text.titleLarge!;

  /// A list row's primary line (a track title, a person's name).
  TextStyle get jamRowTitle => _text.titleMedium!;

  /// Running text.
  TextStyle get jamBody => _text.bodyLarge!;

  /// The secondary line under a row title ("added by Silky Puffin").
  TextStyle get jamByline => _text.bodyMedium!;

  /// Small supporting text.
  TextStyle get jamFootnote => _text.bodySmall!;

  /// A micro label. Render the string uppercase — the style only sets the
  /// tracking that makes uppercase readable.
  TextStyle get jamCaption => _text.labelSmall!;

  /// Durations, drift, counts — anything that must not jitter as it ticks.
  TextStyle get jamNumeric =>
      jamNumericStyle(_text.bodySmall?.color ?? _text.bodyMedium!.color!);
}
