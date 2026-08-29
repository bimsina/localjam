/// The LocalJam type scale.
///
/// No bundled font: the platform's own UI face (SF, Roboto, Segoe, Cantarell)
/// keeps the app feeling local to each OS and keeps the bundle small. The
/// scale is Apple-Music-flavoured — a heavy large title, a comfortable
/// 16pt body, and generous row text, because this UI gets read at arm's
/// length in a moving vehicle.
library;

import 'package:flutter/material.dart';

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
  }) => TextStyle(
    fontSize: size,
    fontWeight: weight,
    color: color ?? primary,
    letterSpacing: tracking,
    height: height,
  );

  return TextTheme(
    // Screen titles.
    headlineLarge: style(32, FontWeight.w700, tracking: -0.6, height: 1.15),
    headlineMedium: style(28, FontWeight.w700, tracking: -0.4, height: 1.18),
    headlineSmall: style(24, FontWeight.w600, tracking: -0.3),
    // Section and row titles.
    titleLarge: style(20, FontWeight.w600, tracking: -0.2),
    titleMedium: style(17, FontWeight.w600, tracking: -0.1),
    titleSmall: style(15, FontWeight.w600),
    // Running text.
    bodyLarge: style(16, FontWeight.w400, height: 1.35),
    bodyMedium: style(15, FontWeight.w400, color: secondary, height: 1.35),
    bodySmall: style(13, FontWeight.w400, color: secondary, height: 1.3),
    // Controls and labels.
    labelLarge: style(16, FontWeight.w600),
    labelMedium: style(13, FontWeight.w500, color: secondary),
    labelSmall: style(11, FontWeight.w600, color: secondary, tracking: 0.5),
  );
}

/// Semantic type aliases, so call sites read as design rather than as
/// Material slot names.
extension JamTypography on BuildContext {
  TextTheme get _text => Theme.of(this).textTheme;

  /// The big screen title ("Nearby", a room name).
  TextStyle get jamLargeTitle => _text.headlineLarge!;

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

  /// An all-caps-ish micro label.
  TextStyle get jamCaption => _text.labelSmall!;

  /// Durations, drift, counts — anything that must not jitter as it ticks.
  TextStyle get jamNumeric => _text.bodyMedium!.copyWith(
    fontFeatures: const [FontFeature.tabularFigures()],
  );
}
