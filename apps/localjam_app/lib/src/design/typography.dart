/// The LocalJam type scale (DESIGN_SPEC v3 §3).
///
/// The platform's own face — SF Pro on iOS/macOS, Roboto on Android, Segoe UI
/// on Windows, the platform default on Linux — at iOS's text-style sizes. SF's
/// tracking table is applied on Apple platforms only; other faces track at 0.
///
/// Screens never hand-roll a size: they read a named getter
/// (`context.jamBody`, `context.jamFootnote`, …) and `copyWith` a colour.
/// Every getter resolves in [JamColors.label]; secondary text says so at the
/// call site (`context.jamSubheadline.copyWith(color: colors.secondaryLabel)`).
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'tokens.dart';

/// Whether [platform] renders in SF and so takes SF's tracking table.
bool jamIsApple(TargetPlatform platform) =>
    platform == TargetPlatform.iOS || platform == TargetPlatform.macOS;

/// The resolved type scale, carried on the theme as an extension.
@immutable
class JamTypeScale extends ThemeExtension<JamTypeScale> {
  const JamTypeScale({
    required this.largeTitle,
    required this.title1,
    required this.title2,
    required this.title3,
    required this.headline,
    required this.body,
    required this.callout,
    required this.subheadline,
    required this.footnote,
    required this.caption1,
    required this.caption2,
  });

  /// 34/41 bold. Large nav titles, onboarding.
  final TextStyle largeTitle;

  /// 28/34 bold.
  final TextStyle title1;

  /// 22/28 bold. Empty-state and terminal-state titles, detail headers.
  final TextStyle title2;

  /// 20/25 semibold. Section titles ("Recent"), the Now Playing title.
  final TextStyle title3;

  /// 17/22 semibold. Inline nav titles, sheet titles, alert titles.
  final TextStyle headline;

  /// 17/22 regular. Row titles, running text.
  final TextStyle body;

  /// 16/21 regular.
  final TextStyle callout;

  /// 15/20 regular. Row subtitles.
  final TextStyle subheadline;

  /// 13/18 regular. Section headers and footers, alert messages.
  final TextStyle footnote;

  /// 12/16 regular. Times under the scrubber.
  final TextStyle caption1;

  /// 11/13 regular.
  final TextStyle caption2;

  List<TextStyle> get _all => [
    largeTitle,
    title1,
    title2,
    title3,
    headline,
    body,
    callout,
    subheadline,
    footnote,
    caption1,
    caption2,
  ];

  @override
  JamTypeScale copyWith({
    TextStyle? largeTitle,
    TextStyle? title1,
    TextStyle? title2,
    TextStyle? title3,
    TextStyle? headline,
    TextStyle? body,
    TextStyle? callout,
    TextStyle? subheadline,
    TextStyle? footnote,
    TextStyle? caption1,
    TextStyle? caption2,
  }) => JamTypeScale(
    largeTitle: largeTitle ?? this.largeTitle,
    title1: title1 ?? this.title1,
    title2: title2 ?? this.title2,
    title3: title3 ?? this.title3,
    headline: headline ?? this.headline,
    body: body ?? this.body,
    callout: callout ?? this.callout,
    subheadline: subheadline ?? this.subheadline,
    footnote: footnote ?? this.footnote,
    caption1: caption1 ?? this.caption1,
    caption2: caption2 ?? this.caption2,
  );

  @override
  JamTypeScale lerp(covariant JamTypeScale? other, double t) {
    if (other == null) return this;
    final a = _all;
    final b = other._all;
    TextStyle at(int i) => TextStyle.lerp(a[i], b[i], t)!;
    return JamTypeScale(
      largeTitle: at(0),
      title1: at(1),
      title2: at(2),
      title3: at(3),
      headline: at(4),
      body: at(5),
      callout: at(6),
      subheadline: at(7),
      footnote: at(8),
      caption1: at(9),
      caption2: at(10),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is JamTypeScale && listEquals(other._all, _all);

  @override
  int get hashCode => Object.hashAll(_all);
}

/// Builds the scale for [platform], in [color].
JamTypeScale buildJamTypeScale({
  required TargetPlatform platform,
  required Color color,
}) {
  final apple = jamIsApple(platform);
  // The face itself comes from the platform typography so it is *named* (a
  // style with no family resolves through DefaultTextStyle, which outside a
  // Material ancestor is the engine fallback). On iOS SF switches to its
  // Display cut at 20 pt and up, exactly as UIKit does.
  final platformBase = Typography.material2021(
    platform: platform,
  ).black.bodyMedium!;

  TextStyle style(
    double size,
    double lineHeight,
    FontWeight weight,
    double tracking,
  ) {
    final String? family;
    if (platform == TargetPlatform.iOS) {
      family = size >= 20 ? 'CupertinoSystemDisplay' : 'CupertinoSystemText';
    } else {
      family = platformBase.fontFamily;
    }
    return TextStyle(
      inherit: true,
      fontFamily: family,
      fontFamilyFallback: platformBase.fontFamilyFallback,
      fontSize: size,
      height: lineHeight / size,
      fontWeight: weight,
      letterSpacing: apple ? tracking : 0,
      color: color,
      decoration: TextDecoration.none,
      leadingDistribution: TextLeadingDistribution.even,
    );
  }

  return JamTypeScale(
    largeTitle: style(34, 41, FontWeight.w700, 0.4),
    title1: style(28, 34, FontWeight.w700, 0.38),
    title2: style(22, 28, FontWeight.w700, -0.26),
    title3: style(20, 25, FontWeight.w600, -0.45),
    headline: style(17, 22, FontWeight.w600, -0.43),
    body: style(17, 22, FontWeight.w400, -0.43),
    callout: style(16, 21, FontWeight.w400, -0.31),
    subheadline: style(15, 20, FontWeight.w400, -0.23),
    footnote: style(13, 18, FontWeight.w400, -0.08),
    caption1: style(12, 16, FontWeight.w400, 0),
    caption2: style(11, 13, FontWeight.w400, 0.06),
  );
}

/// Maps the scale onto Material's [TextTheme] slots, so stock widgets that
/// still read the text theme pick up the same sizes.
TextTheme jamTextThemeFrom(JamTypeScale s) => TextTheme(
  displayLarge: s.largeTitle,
  displayMedium: s.title1,
  displaySmall: s.title2,
  headlineLarge: s.largeTitle,
  headlineMedium: s.title1,
  headlineSmall: s.title2,
  titleLarge: s.title3,
  titleMedium: s.headline,
  titleSmall: s.subheadline.copyWith(fontWeight: FontWeight.w600),
  bodyLarge: s.body,
  bodyMedium: s.subheadline,
  bodySmall: s.footnote,
  labelLarge: s.headline,
  labelMedium: s.footnote,
  labelSmall: s.caption2,
);

/// Fixed-width digits for timers, durations, counts.
TextStyle jamTabular(TextStyle style) =>
    style.copyWith(fontFeatures: const [FontFeature.tabularFigures()]);

/// Footnote-sized tabular figures in [color], for code that has a palette but
/// no context (painters, tests).
TextStyle jamNumericStyle(Color color, {TargetPlatform? platform}) =>
    jamTabular(
      buildJamTypeScale(
        platform: platform ?? defaultTargetPlatform,
        color: color,
      ).footnote,
    );

/// Named type styles. All resolve in `label`; pass a colour with `copyWith`.
extension JamTypography on BuildContext {
  JamTypeScale get jamType =>
      Theme.of(this).extension<JamTypeScale>() ??
      buildJamTypeScale(
        platform: Theme.of(this).platform,
        color: JamColors.light.label,
      );

  /// 34/41 bold.
  TextStyle get jamLargeTitle => jamType.largeTitle;

  /// 28/34 bold.
  TextStyle get jamTitle1 => jamType.title1;

  /// 22/28 bold.
  TextStyle get jamTitle2 => jamType.title2;

  /// 20/25 semibold.
  TextStyle get jamTitle3 => jamType.title3;

  /// 17/22 semibold.
  TextStyle get jamHeadline => jamType.headline;

  /// 17/22 regular.
  TextStyle get jamBody => jamType.body;

  /// 16/21 regular.
  TextStyle get jamCallout => jamType.callout;

  /// 15/20 regular.
  TextStyle get jamSubheadline => jamType.subheadline;

  /// 13/18 regular.
  TextStyle get jamFootnote => jamType.footnote;

  /// 12/16 regular.
  TextStyle get jamCaption1 => jamType.caption1;

  /// 11/13 regular.
  TextStyle get jamCaption2 => jamType.caption2;

  /// Footnote in tabular figures, `secondaryLabel` — durations, drift, counts.
  TextStyle get jamNumeric =>
      jamTabular(jamType.footnote).copyWith(color: jamColors.secondaryLabel);
}
