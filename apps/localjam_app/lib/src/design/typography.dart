/// The LocalJam type scale (DESIGN_SPEC v4 "Identity"; v3 §3 for metrics).
///
/// **Which face.** Manrope is for things with a name and for headings:
/// largeTitle, title1–3, a song's title, a jam's name, the wordmark, a jam's
/// monogram and a person's initials. The system face is for everything that
/// labels chrome or runs as text: headline and below — nav and sheet titles,
/// rows, buttons, footnotes. Pick by role, not by size, and never animate
/// between the two families (a `TextStyle.lerp` across families snaps
/// halfway); scale one style instead.
///
/// Body copy uses SF Pro on iOS/macOS, Roboto on Android, Segoe UI on
/// Windows, and the platform default on Linux. SF's tracking table is
/// applied on Apple platforms only; other faces track at 0.
///
/// Screens never hand-roll a size: they read a named getter
/// (`context.jamBody`, `context.jamFootnote`, …) and `copyWith` a colour.
/// Every getter resolves in [JamColors.label]; secondary text says so at the
/// call site (`context.jamSubheadline.copyWith(color: colors.secondaryLabel)`).
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

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

  /// Manrope 34/41 bold. Large nav titles, onboarding.
  final TextStyle largeTitle;

  /// Manrope 28/36 bold. The Now Playing song title.
  final TextStyle title1;

  /// Manrope 22/29 bold. Empty-state and terminal-state titles, detail
  /// headers, a jam's name at its largest.
  final TextStyle title2;

  /// Manrope 20/27 semibold. Section titles ("Recent", "Up next"), alert
  /// titles, a jam's name in a row.
  final TextStyle title3;

  /// 17/22 semibold. Inline nav titles, sheet titles.
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
    largeTitle: style(
      34,
      41,
      FontWeight.w700,
      0,
    ).copyWith(fontFamily: 'Manrope', letterSpacing: -1.2),
    title1: style(
      28,
      36,
      FontWeight.w700,
      0,
    ).copyWith(fontFamily: 'Manrope', letterSpacing: -0.8),
    title2: style(
      22,
      29,
      FontWeight.w700,
      0,
    ).copyWith(fontFamily: 'Manrope', letterSpacing: -0.5),
    title3: style(
      20,
      27,
      FontWeight.w600,
      0,
    ).copyWith(fontFamily: 'Manrope', letterSpacing: -0.4),
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

  /// Manrope 34/41 bold.
  TextStyle get jamLargeTitle => jamType.largeTitle;

  /// Manrope 28/36 bold.
  TextStyle get jamTitle1 => jamType.title1;

  /// Manrope 22/29 bold.
  TextStyle get jamTitle2 => jamType.title2;

  /// Manrope 20/27 semibold.
  TextStyle get jamTitle3 => jamType.title3;

  /// Manrope 17/22 bold, −0.2 tracking: a jam's name in a list row
  /// (Nearby, Recent, Past Jams) — the face says "a jam's name", the size
  /// sits level with the row's 17 pt controls instead of reading as a
  /// heading (R6). Page and sheet titles keep [jamTitle3] and up.
  TextStyle get jamNameRow => jamType.headline.copyWith(
    fontFamily: 'Manrope',
    fontWeight: FontWeight.w700,
    letterSpacing: -0.2,
  );

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

/// Text that wraps into balanced lines — CSS's `text-wrap: balance` — so a
/// two-line message never ends on one orphaned word ("…for everyone in
/// the / jam.").
///
/// Lays the text out at the full width, then narrows its box to the
/// smallest width that keeps the same number of lines. A single line is
/// left alone. For alert messages, empty-state sentences and other short
/// copy; running text should not use it.
class JamBalancedText extends StatelessWidget {
  const JamBalancedText(
    this.data, {
    super.key,
    this.style,
    this.textAlign = TextAlign.center,
    this.maxLines,
  });

  final String data;
  final TextStyle? style;
  final TextAlign textAlign;
  final int? maxLines;

  @override
  Widget build(BuildContext context) => _JamBalanced(
    text: TextSpan(
      text: data,
      style: DefaultTextStyle.of(context).style.merge(style),
    ),
    textAlign: textAlign,
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: maxLines,
    child: Text(data, style: style, textAlign: textAlign, maxLines: maxLines),
  );
}

class _JamBalanced extends SingleChildRenderObjectWidget {
  const _JamBalanced({
    required this.text,
    required this.textAlign,
    required this.textDirection,
    required this.textScaler,
    required this.maxLines,
    required super.child,
  });

  final TextSpan text;
  final TextAlign textAlign;
  final TextDirection textDirection;
  final TextScaler textScaler;
  final int? maxLines;

  @override
  _RenderJamBalanced createRenderObject(BuildContext context) =>
      _RenderJamBalanced(
        text: text,
        textAlign: textAlign,
        textDirection: textDirection,
        textScaler: textScaler,
        maxLines: maxLines,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderJamBalanced renderObject,
  ) {
    renderObject
      ..text = text
      ..textAlign = textAlign
      ..textDirection = textDirection
      ..textScaler = textScaler
      ..maxLines = maxLines;
  }
}

/// Lays its text child out at the narrowest width that keeps the line count
/// it would have at full width, then places it by the alignment. Intrinsic
/// sizes are the child's own, so it works inside `SliverFillRemaining`,
/// `IntrinsicWidth` and friends.
class _RenderJamBalanced extends RenderShiftedBox {
  _RenderJamBalanced({
    required TextSpan text,
    required TextAlign textAlign,
    required TextDirection textDirection,
    required TextScaler textScaler,
    required int? maxLines,
  }) : _painter = TextPainter(
         text: text,
         textAlign: textAlign,
         textDirection: textDirection,
         textScaler: textScaler,
         maxLines: maxLines,
       ),
       super(null);

  final TextPainter _painter;

  set text(TextSpan value) {
    if (_painter.text == value) return;
    _painter.text = value;
    markNeedsLayout();
  }

  set textAlign(TextAlign value) {
    if (_painter.textAlign == value) return;
    _painter.textAlign = value;
    markNeedsLayout();
  }

  set textDirection(TextDirection value) {
    if (_painter.textDirection == value) return;
    _painter.textDirection = value;
    markNeedsLayout();
  }

  set textScaler(TextScaler value) {
    if (_painter.textScaler == value) return;
    _painter.textScaler = value;
    markNeedsLayout();
  }

  set maxLines(int? value) {
    if (_painter.maxLines == value) return;
    _painter.maxLines = value;
    markNeedsLayout();
  }

  @override
  void dispose() {
    _painter.dispose();
    super.dispose();
  }

  int _linesAt(double width) {
    _painter.layout(maxWidth: width);
    return _painter.computeLineMetrics().length;
  }

  /// The balanced width for a box at most [max] wide.
  double _balancedWidth(double max) {
    if (!max.isFinite || max <= 0) return max;
    final lines = _linesAt(max);
    if (lines <= 1 || _painter.didExceedMaxLines) return max;
    // Never narrower than an even split needs.
    var lo = max / lines;
    var hi = max;
    for (var i = 0; i < 10 && hi - lo > 1; i++) {
      final mid = (lo + hi) / 2;
      if (_linesAt(mid) <= lines) {
        hi = mid;
      } else {
        lo = mid;
      }
    }
    return math.min(max, hi.ceilToDouble() + 1);
  }

  BoxConstraints _childConstraints(BoxConstraints constraints) =>
      BoxConstraints(
        maxWidth: _balancedWidth(constraints.maxWidth),
        maxHeight: constraints.maxHeight,
      );

  @override
  Size computeDryLayout(covariant BoxConstraints constraints) {
    final child = this.child;
    if (child == null) return constraints.smallest;
    return constraints.constrain(
      child.getDryLayout(_childConstraints(constraints)),
    );
  }

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    child.layout(_childConstraints(constraints), parentUsesSize: true);
    size = constraints.constrain(child.size);
    final free = size.width - child.size.width;
    final ltr = _painter.textDirection == TextDirection.ltr;
    final factor = switch (_painter.textAlign) {
      TextAlign.center => 0.5,
      TextAlign.right => 1.0,
      TextAlign.left => 0.0,
      TextAlign.end => ltr ? 1.0 : 0.0,
      _ => ltr ? 0.0 : 1.0,
    };
    (child.parentData! as BoxParentData).offset = Offset(free * factor, 0);
  }
}

/// A heading or title that never breaks inside a word (N3).
///
/// At the largest accessibility sizes a Manrope title can be wider per word
/// than its column — "Golden" at AX5 on a phone — and Flutter then breaks
/// the word itself: "Golde / n Hour / Drive", "Recen / t". Wrapped in this,
/// the [Text] steps its text scale down, never below its design size, until
/// its widest word fits the width it is given. Words still wrap between
/// themselves as usual; only the scale is capped.
///
/// The child stays an ordinary [Text] (found by `find.text`, heard by screen
/// readers as before), built at the scale that fits once the width is known.
/// Unlike a bare `LayoutBuilder`, it answers intrinsic and dry sizes, so it
/// is safe inside rows and other layouts that measure first.
class JamWholeWords extends StatelessWidget {
  const JamWholeWords({super.key, required this.child});

  final Text child;

  @override
  Widget build(BuildContext context) {
    final text = child;
    final defaults = DefaultTextStyle.of(context);
    var style = defaults.style.merge(text.style);
    if (MediaQuery.boldTextOf(context)) {
      style = style.merge(const TextStyle(fontWeight: FontWeight.bold));
    }
    final measure = _WordFitSpec(
      text: text.data ?? text.textSpan?.toPlainText() ?? '',
      style: style,
      base: text.textScaler ?? MediaQuery.textScalerOf(context),
      textAlign: text.textAlign ?? defaults.textAlign ?? TextAlign.start,
      textDirection: text.textDirection ?? Directionality.of(context),
      maxLines: text.maxLines ?? defaults.maxLines,
      ellipsis:
          (text.overflow ?? style.overflow ?? defaults.overflow) ==
          TextOverflow.ellipsis,
      locale: text.locale,
      strutStyle: text.strutStyle,
      textWidthBasis: text.textWidthBasis ?? defaults.textWidthBasis,
      textHeightBehavior:
          text.textHeightBehavior ??
          defaults.textHeightBehavior ??
          DefaultTextHeightBehavior.maybeOf(context),
    );
    return _WholeWordsBuilder(
      spec: measure,
      builder: (context, constraints) {
        final fitted = measure.scalerFor(constraints.maxWidth);
        if (text.textScaler != null || fitted == measure.base) return text;
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: fitted),
          child: text,
        );
      },
    );
  }
}

/// The scale at which [text]'s widest word fits [maxWidth]: [base] when it
/// already does, else a linear scale stepped down from [base] — but never
/// below 1, so a word too long even at its design size wraps as before
/// rather than shrinking past the type scale.
@visibleForTesting
TextScaler jamWholeWordScaler({
  required String text,
  required TextStyle style,
  required TextScaler base,
  required double maxWidth,
  TextDirection textDirection = TextDirection.ltr,
  Locale? locale,
  StrutStyle? strutStyle,
  TextHeightBehavior? textHeightBehavior,
}) {
  if (!maxWidth.isFinite || maxWidth <= 0) return base;
  final words = text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
  if (words.isEmpty) return base;
  // One word per line: the painter's width is then the widest word.
  final painter = TextPainter(
    text: TextSpan(text: words.join('\n'), style: style),
    textDirection: textDirection,
    locale: locale,
    strutStyle: strutStyle,
    textHeightBehavior: textHeightBehavior,
  );
  double widestAt(TextScaler scaler) {
    painter
      ..textScaler = scaler
      ..layout();
    return painter.width;
  }

  try {
    var widest = widestAt(base);
    if (widest <= maxWidth) return base;
    final fontSize = style.fontSize ?? kDefaultFontSize;
    var factor = base.scale(fontSize) / fontSize;
    if (factor <= 1) return base;
    // Letter spacing does not scale with the text, so the first estimate
    // can be a hair off; a couple of refinements settle it.
    for (var i = 0; i < 4; i++) {
      factor = math.max(
        1.0,
        ((factor * maxWidth / widest) * 100).floorToDouble() / 100,
      );
      final scaler = TextScaler.linear(factor);
      widest = widestAt(scaler);
      if (widest <= maxWidth || factor == 1) return scaler;
    }
    return TextScaler.linear(factor);
  } finally {
    painter.dispose();
  }
}

/// Everything [JamWholeWords] needs to size its text without building it.
@immutable
class _WordFitSpec {
  const _WordFitSpec({
    required this.text,
    required this.style,
    required this.base,
    required this.textAlign,
    required this.textDirection,
    required this.maxLines,
    required this.ellipsis,
    required this.locale,
    required this.strutStyle,
    required this.textWidthBasis,
    required this.textHeightBehavior,
  });

  final String text;
  final TextStyle style;
  final TextScaler base;
  final TextAlign textAlign;
  final TextDirection textDirection;
  final int? maxLines;
  final bool ellipsis;
  final Locale? locale;
  final StrutStyle? strutStyle;
  final TextWidthBasis textWidthBasis;
  final TextHeightBehavior? textHeightBehavior;

  TextScaler scalerFor(double maxWidth) => jamWholeWordScaler(
    text: text,
    style: style,
    base: base,
    maxWidth: maxWidth,
    textDirection: textDirection,
    locale: locale,
    strutStyle: strutStyle,
    textHeightBehavior: textHeightBehavior,
  );

  /// A painter laid out as the [Text] will be at [maxWidth]; dispose it.
  TextPainter paint(double maxWidth, {TextScaler? scaler}) => TextPainter(
    text: TextSpan(text: text, style: style),
    textAlign: textAlign,
    textDirection: textDirection,
    textScaler: scaler ?? scalerFor(maxWidth),
    maxLines: maxLines,
    ellipsis: ellipsis ? '\u2026' : null,
    locale: locale,
    strutStyle: strutStyle,
    textWidthBasis: textWidthBasis,
    textHeightBehavior: textHeightBehavior,
  )..layout(maxWidth: maxWidth);

  @override
  bool operator ==(Object other) =>
      other is _WordFitSpec &&
      other.text == text &&
      other.style == style &&
      other.base == base &&
      other.textAlign == textAlign &&
      other.textDirection == textDirection &&
      other.maxLines == maxLines &&
      other.ellipsis == ellipsis &&
      other.locale == locale &&
      other.strutStyle == strutStyle &&
      other.textWidthBasis == textWidthBasis &&
      other.textHeightBehavior == textHeightBehavior;

  @override
  int get hashCode => Object.hash(
    text,
    style,
    base,
    textAlign,
    textDirection,
    maxLines,
    ellipsis,
    locale,
    strutStyle,
    textWidthBasis,
    textHeightBehavior,
  );
}

class _WholeWordsBuilder extends ConstrainedLayoutBuilder<BoxConstraints> {
  const _WholeWordsBuilder({required this.spec, required super.builder});

  final _WordFitSpec spec;

  @override
  _RenderWholeWords createRenderObject(BuildContext context) =>
      _RenderWholeWords(spec);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderWholeWords renderObject,
  ) => renderObject.spec = spec;
}

/// A layout builder that can answer intrinsic and dry sizes: it measures
/// the text itself rather than building it speculatively.
class _RenderWholeWords extends RenderBox
    with
        RenderObjectWithChildMixin<RenderBox>,
        RenderObjectWithLayoutCallbackMixin,
        RenderAbstractLayoutBuilderMixin<BoxConstraints, RenderBox> {
  _RenderWholeWords(this._spec);

  _WordFitSpec _spec;
  set spec(_WordFitSpec value) {
    if (value == _spec) return;
    _spec = value;
    markNeedsLayout();
  }

  T _measured<T>(
    double maxWidth,
    T Function(TextPainter) read, {
    TextScaler? scaler,
  }) {
    final painter = _spec.paint(maxWidth, scaler: scaler);
    try {
      return read(painter);
    } finally {
      painter.dispose();
    }
  }

  @override
  double computeMinIntrinsicWidth(double height) {
    // The text can step down to its design size, so its narrowest is its
    // widest word there (or at the person's scale, if that is smaller).
    final base = _spec.base;
    final size = _spec.style.fontSize ?? kDefaultFontSize;
    final floor = base.scale(size) / size > 1 ? TextScaler.noScaling : base;
    return _measured(
      double.infinity,
      (p) => p.minIntrinsicWidth,
      scaler: floor,
    ).ceilToDouble();
  }

  @override
  double computeMaxIntrinsicWidth(double height) => _measured(
    double.infinity,
    (p) => p.maxIntrinsicWidth,
    scaler: _spec.base,
  ).ceilToDouble();

  @override
  double computeMinIntrinsicHeight(double width) =>
      _measured(width, (p) => p.height);

  @override
  double computeMaxIntrinsicHeight(double width) =>
      computeMinIntrinsicHeight(width);

  @override
  Size computeDryLayout(covariant BoxConstraints constraints) {
    final size = _measured(constraints.maxWidth, (p) => p.size);
    return constraints.constrain(
      Size(size.width.ceilToDouble(), size.height.ceilToDouble()),
    );
  }

  @override
  void performLayout() {
    final constraints = this.constraints;
    runLayoutCallback();
    final child = this.child;
    if (child != null) {
      child.layout(constraints, parentUsesSize: true);
      size = constraints.constrain(child.size);
    } else {
      size = constraints.smallest;
    }
  }

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) =>
      child?.getDistanceToActualBaseline(baseline);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      child?.hitTest(result, position: position) ?? false;

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child != null) context.paintChild(child, offset);
  }
}
