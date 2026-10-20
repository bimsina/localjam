/// The LocalJam design tokens (DESIGN_SPEC v4; v3 §2 for anything v4 does
/// not override).
///
/// Warm paper and charcoal carry the chrome — paper and grouped paper on
/// light, warm charcoal (R > G > B) on dark — and raspberry is the **tint**:
/// it lands only on things you can tap, plus selection. Cover art carries
/// every other colour; people carry theirs on their faces
/// ([JamAvatarPalette]).
///
/// Every text pair here is checked in `test/design_test.dart`: body text at
/// 4.5:1 or better, icons and control edges at 3:1, in all four palettes.
library;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';

/// Semantic colours, resolved per theme. Read them from the context rather
/// than importing the constants: `context.jamColors.tint`.
@immutable
class JamColors extends ThemeExtension<JamColors> {
  const JamColors({
    required this.background,
    required this.groupedBackground,
    required this.groupedSurface,
    required this.elevated,
    required this.elevatedGroupedBackground,
    required this.elevatedGroupedSurface,
    required this.fill,
    required this.fillSecondary,
    required this.fillPressed,
    required this.separator,
    required this.label,
    required this.secondaryLabel,
    required this.tertiaryLabel,
    required this.tint,
    required this.tintPressed,
    required this.tintFill,
    required this.onTint,
    required this.success,
    required this.warning,
    required this.danger,
    required this.scrim,
    required this.material,
    required this.glass,
    this._tintFilled,
    required this.dangerFilled,
  });

  /// Plain screens: Home, History, the scan fallbacks.
  final Color background;

  /// Grouped screens: Settings, Start a Jam, the People sheet.
  final Color groupedBackground;

  /// Rows and cells inside a grouped section.
  final Color groupedSurface;

  /// Sheets, alerts and menus.
  final Color elevated;

  /// The ground of a sheet that hosts grouped rows. On light it is the
  /// screens' grouped paper, so rows stand off it the way they do on a
  /// grouped screen.
  final Color elevatedGroupedBackground;

  /// Rows inside a grouped sheet; also the ground of a pull-down or context
  /// menu (`JamMenuPanel`), which has to stand off whatever it opens over.
  final Color elevatedGroupedSurface;

  /// Tinted-grey buttons (`JamButton.gray`), search fields, slider tracks.
  final Color fill;

  /// Placeholder art ground, text fields.
  final Color fillSecondary;

  /// A row's press highlight.
  final Color fillPressed;

  /// 0.5 px hairlines, inset to the text start.
  final Color separator;

  /// Primary text.
  final Color label;

  /// Subtitles, values, footers.
  final Color secondaryLabel;

  /// Placeholder artwork glyphs, disabled text, grabbers, chevrons and other
  /// small indicators. At least 3:1 on every ground it marks a control on;
  /// text-field placeholders use [secondaryLabel] instead.
  final Color tertiaryLabel;

  /// Tappable text and icons, filled buttons, selection, checkmarks.
  final Color tint;

  /// [tint] while pressed.
  final Color tintPressed;

  /// "Tinted" buttons (Join) and the selected sidebar item.
  final Color tintFill;

  /// Text and icons on a [tint] fill.
  final Color onTint;

  /// Positive confirmation glyphs ("Done" notices). Never a switch track:
  /// switches use the brand fill ([tintFilled]).
  final Color success;

  /// Recoverable trouble as text or an icon: "Catching up…".
  final Color warning;

  /// Destructive *text* and glyphs: rows, plain and grey buttons, menu
  /// items, failures. For a filled ground under white use [dangerFilled].
  final Color danger;

  /// The ground of a filled destructive button (an alert's End Jam,
  /// `JamButton.filled(destructive: true)`): white on it clears 4.5:1 in
  /// every palette. The bright dark-mode [danger] is for red text on
  /// charcoal, never a fill.
  final Color dangerFilled;

  /// Behind sheets and alerts. Dark mode dims with black, so an `elevated`
  /// card always sits *above* the page it covers.
  final Color scrim;

  /// Nearly opaque chrome (nav bars on scroll, mini player, toasts). Paired
  /// with a [JamBlur.material] backdrop blur.
  final Color material;

  /// Round icon buttons over artwork (white 8%). Paired with [JamBlur.glass].
  final Color glass;

  /// The ground of a filled tint button (`JamButton.filled`, an alert's
  /// preferred action). Darker than [tint] in dark mode so the white label
  /// clears 4.5:1 — the bright dark-mode tint is for tint *text* on black.
  /// Falls back to [tint].
  Color get tintFilled => _tintFilled ?? tint;
  final Color? _tintFilled;

  /// Warm paper and warm ink (R ≥ G > B, hue 24–28° — the dark theme's
  /// temperature, R7), with raspberry reserved for interaction.
  ///
  /// | Ink | On `background` | On `groupedBackground` | On `fill` |
  /// |---|---|---|---|
  /// | label `2A2420` | 14.44 (was 14.38) | 13.36 (13.30) | 12.01 (11.96) |
  /// | secondaryLabel `6F6761` | 5.23 (5.08) | 4.84 (4.69) | 4.35 (4.22) |
  /// | tertiaryLabel `82786F` | 4.07 (3.89) | 3.77 (3.60) | 3.39 (3.23) |
  static const JamColors light = JamColors(
    background: Color(0xFFFAF8F5),
    groupedBackground: Color(0xFFF2EFEB),
    groupedSurface: Color(0xFFFFFEFC),
    elevated: Color(0xFFFAF8F5),
    elevatedGroupedBackground: Color(0xFFF2EFEB),
    elevatedGroupedSurface: Color(0xFFFFFEFC),
    fill: Color(0xFFE8E3DE),
    fillSecondary: Color(0xFFF0EBE6),
    fillPressed: Color(0x102A2420),
    separator: Color(0x242A2420),
    label: Color(0xFF2A2420),
    secondaryLabel: Color(0xFF6F6761),
    tertiaryLabel: Color(0xFF82786F),
    tint: Color(0xFFB82F59),
    tintPressed: Color(0xFF922343),
    tintFill: Color(0xFFF6E3E8),
    onTint: Color(0xFFFFFFFF),
    success: Color(0xFF3E8068),
    warning: Color(0xFFA54C20),
    danger: Color(0xFFB5343A),
    scrim: Color(0x66201C19),
    material: Color(0xF5FAF8F5),
    glass: Color(0x14FFFFFF),
    tintFilled: Color(0xFFB82F59),
    dangerFilled: Color(0xFFB5343A),
  );

  /// Warm charcoal (R > G > B, hue 20–30°) keeps dark mode intimate without
  /// a purple cast. Each ground sits at or under the luminance of the v4
  /// baseline and each text colour at or over it, so no ratio dropped.
  static const JamColors dark = JamColors(
    background: Color(0xFF1A1715),
    groupedBackground: Color(0xFF1A1715),
    groupedSurface: Color(0xFF262220),
    elevated: Color(0xFF221E1B),
    elevatedGroupedBackground: Color(0xFF221E1B),
    elevatedGroupedSurface: Color(0xFF302B28),
    fill: Color(0xFF3A3532),
    fillSecondary: Color(0xFF2E2926),
    fillPressed: Color(0x14FFFFFF),
    separator: Color(0x29F0E6DF),
    label: Color(0xFFF7F2EE),
    secondaryLabel: Color(0xFFBEB5AE),
    tertiaryLabel: Color(0xFF8E847D),
    tint: Color(0xFFF28AA7),
    tintPressed: Color(0xFFD96F8F),
    tintFill: Color(0xFF432A34),
    onTint: Color(0xFFFFFFFF),
    success: Color(0xFF79B79C),
    warning: Color(0xFFEAAF79),
    danger: Color(0xFFFF9190),
    scrim: Color(0x99000000),
    material: Color(0xF5262220),
    glass: Color(0x14FFFFFF),
    tintFilled: Color(0xFFB82F59),
    dangerFilled: Color(0xFFB3343A),
  );

  /// The light palette under the system's Increase Contrast: the same warm
  /// ink a step firmer — secondary and tertiary text, hairlines in ink at
  /// 50%, the tint and the reds deeper. Every pair is at or above the
  /// normal palette's.
  static final JamColors lightHighContrast = light.copyWith(
    secondaryLabel: const Color(0xFF5C544F),
    tertiaryLabel: const Color(0xFF6F665F),
    separator: const Color(0x802A2420),
    tint: const Color(0xFFA82450),
    tintPressed: const Color(0xFF8A1D41),
    tintFilled: const Color(0xFFA82450),
    warning: const Color(0xFF8F3C14),
    danger: const Color(0xFFA8262B),
    dangerFilled: const Color(0xFFA8262B),
  );

  /// The dark palette under Increase Contrast: lighter warm text, a
  /// stronger hairline, and lighter tint and danger *text* — with deeper
  /// fills under white.
  static final JamColors darkHighContrast = dark.copyWith(
    secondaryLabel: const Color(0xFFD6CEC8),
    tertiaryLabel: const Color(0xFFADA39B),
    separator: const Color(0x66F0E6DF),
    tint: const Color(0xFFFFA3BC),
    tintPressed: const Color(0xFFFF8FAE),
    tintFilled: const Color(0xFFA82450),
    warning: const Color(0xFFFFC98A),
    danger: const Color(0xFFFFAAA8),
    dangerFilled: const Color(0xFFA8262B),
  );

  List<Color> get _all => [
    background,
    groupedBackground,
    groupedSurface,
    elevated,
    elevatedGroupedBackground,
    elevatedGroupedSurface,
    fill,
    fillSecondary,
    fillPressed,
    separator,
    label,
    secondaryLabel,
    tertiaryLabel,
    tint,
    tintPressed,
    tintFill,
    onTint,
    success,
    warning,
    danger,
    scrim,
    material,
    glass,
    tintFilled,
    dangerFilled,
  ];

  static JamColors _fromList(List<Color> v) => JamColors(
    background: v[0],
    groupedBackground: v[1],
    groupedSurface: v[2],
    elevated: v[3],
    elevatedGroupedBackground: v[4],
    elevatedGroupedSurface: v[5],
    fill: v[6],
    fillSecondary: v[7],
    fillPressed: v[8],
    separator: v[9],
    label: v[10],
    secondaryLabel: v[11],
    tertiaryLabel: v[12],
    tint: v[13],
    tintPressed: v[14],
    tintFill: v[15],
    onTint: v[16],
    success: v[17],
    warning: v[18],
    danger: v[19],
    scrim: v[20],
    material: v[21],
    glass: v[22],
    tintFilled: v[23],
    dangerFilled: v[24],
  );

  @override
  JamColors copyWith({
    Color? background,
    Color? groupedBackground,
    Color? groupedSurface,
    Color? elevated,
    Color? elevatedGroupedBackground,
    Color? elevatedGroupedSurface,
    Color? fill,
    Color? fillSecondary,
    Color? fillPressed,
    Color? separator,
    Color? label,
    Color? secondaryLabel,
    Color? tertiaryLabel,
    Color? tint,
    Color? tintPressed,
    Color? tintFill,
    Color? onTint,
    Color? success,
    Color? warning,
    Color? danger,
    Color? scrim,
    Color? material,
    Color? glass,
    Color? tintFilled,
    Color? dangerFilled,
  }) => JamColors(
    background: background ?? this.background,
    groupedBackground: groupedBackground ?? this.groupedBackground,
    groupedSurface: groupedSurface ?? this.groupedSurface,
    elevated: elevated ?? this.elevated,
    elevatedGroupedBackground:
        elevatedGroupedBackground ?? this.elevatedGroupedBackground,
    elevatedGroupedSurface:
        elevatedGroupedSurface ?? this.elevatedGroupedSurface,
    fill: fill ?? this.fill,
    fillSecondary: fillSecondary ?? this.fillSecondary,
    fillPressed: fillPressed ?? this.fillPressed,
    separator: separator ?? this.separator,
    label: label ?? this.label,
    secondaryLabel: secondaryLabel ?? this.secondaryLabel,
    tertiaryLabel: tertiaryLabel ?? this.tertiaryLabel,
    tint: tint ?? this.tint,
    tintPressed: tintPressed ?? this.tintPressed,
    tintFill: tintFill ?? this.tintFill,
    onTint: onTint ?? this.onTint,
    success: success ?? this.success,
    warning: warning ?? this.warning,
    danger: danger ?? this.danger,
    scrim: scrim ?? this.scrim,
    material: material ?? this.material,
    glass: glass ?? this.glass,
    tintFilled: tintFilled ?? this.tintFilled,
    dangerFilled: dangerFilled ?? this.dangerFilled,
  );

  @override
  bool operator ==(Object other) {
    if (other is! JamColors) return false;
    final a = _all;
    final b = other._all;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(_all);

  @override
  JamColors lerp(covariant JamColors? other, double t) {
    if (other == null) return this;
    final a = _all;
    final b = other._all;
    return _fromList([
      for (var i = 0; i < a.length; i++) Color.lerp(a[i], b[i], t)!,
    ]);
  }
}

/// [base] re-pointed at the Now Playing backdrop: white text at the
/// backdrop's three strengths, white (not raspberry) for what can be tapped,
/// see-through grounds (a control's `fill` — a switch's off track, a
/// disabled button — is the backdrop's glass), white hairlines and press
/// highlights, and the
/// backdrop's own red and amber — the one "danger on artwork" and "warning on
/// artwork" in the app (each ≥ 4.5:1 on the brightest ground the backdrop
/// allows).
///
/// Shared components dropped onto the backdrop (the docked People panel, the
/// status line) read their colours from this, never from their own copy.
/// Wrap a subtree in `JamOnBackdrop` (design/theme.dart) to apply it.
JamColors jamBackdropColors(JamColors base) => base.copyWith(
  background: JamNowPlayingColors.clear,
  groupedBackground: JamNowPlayingColors.clear,
  elevatedGroupedBackground: JamNowPlayingColors.clear,
  groupedSurface: JamNowPlayingColors.clear,
  elevatedGroupedSurface: JamNowPlayingColors.clear,
  separator: JamNowPlayingColors.separator,
  label: JamNowPlayingColors.text,
  secondaryLabel: JamNowPlayingColors.secondary,
  tertiaryLabel: JamNowPlayingColors.tertiary,
  fill: JamNowPlayingColors.glass,
  fillPressed: JamNowPlayingColors.pressed,
  tint: JamNowPlayingColors.text,
  tintPressed: JamNowPlayingColors.secondary,
  danger: JamNowPlayingColors.destructive,
  warning: JamNowPlayingColors.warning,
);

/// The fixed palette of the immersive Now Playing surface (D4). Identical in
/// both themes: the backdrop is always dark enough for white text.
abstract final class JamNowPlayingColors {
  /// Titles, transport glyphs.
  static const Color text = Color(0xFFFFFFFF);

  /// "Added by Mia", times. 70%, not iOS's 60%: the backdrop is solved so
  /// this clears 4.5:1 on any cover (spec §10.7, `artwork_tint.dart`).
  static const Color secondary = Color(0xB3FFFFFF);

  /// The grabber, drag handles, disabled transport. White 50%: 3.2:1 on the
  /// brightest ground the backdrop allows, enough for a control's glyph.
  static const Color tertiary = Color(0x80FFFFFF);

  /// The scrubber's unplayed track.
  static const Color track = Color(0x40FFFFFF);

  /// The scrubber's played part; the selected footer-icon circle; the
  /// segmented control's thumb on the backdrop.
  static const Color fill = Color(0xD9FFFFFF);

  /// The artwork placeholder's ground on the backdrop.
  static const Color placeholderGround = Color(0x1FFFFFFF);

  /// The artwork placeholder's note on the backdrop.
  static const Color placeholderGlyph = Color(0x80FFFFFF);

  /// The backdrop when the cover is a placeholder, and the charcoal every
  /// backdrop fades into: the dark `elevated`.
  static const Color backdropPlaceholder = Color(0xFF221E1B);

  /// The platter a long-pressed queue row lifts onto, above its menu: the
  /// dark `elevatedGroupedSurface`, the same ground as the menu under it.
  static const Color liftedRow = Color(0xFF302B28);

  /// What a queue row's long-press menu dims the rest of the screen with.
  static const Color contextScrim = Color(0x59000000);

  /// Destructive *text* on the backdrop ("End jam" in the docked panel, the
  /// status line's failures). Holds 4.5:1 over the backdrop's brightest
  /// allowed ground and still reads as red.
  static const Color destructive = Color(0xFFFFBAB5);

  /// Warning *text* on the backdrop ("Still loading songs…"), for the same
  /// reason.
  static const Color warning = Color(0xFFFFD27A);

  /// Hairlines between grouped rows on the backdrop.
  static const Color separator = Color(0x29FFFFFF);

  /// Glass over the backdrop (white 18%): the play square while playback is
  /// the host's alone.
  static const Color glass = Color(0x2EFFFFFF);

  /// The glyph on a selected (white-filled) footer or glass button: warm
  /// ink, never pure black.
  static const Color selectedGlyph = Color(0xFF1A1715);

  /// The play square's fill: ivory, the dark theme's `label`.
  static const Color playSurface = Color(0xFFF7F2EE);

  /// The play and pause glyph on [playSurface] (16:1): warm ink.
  static const Color playGlyph = Color(0xFF1A1715);

  /// A row's press highlight on the backdrop.
  static const Color pressed = Color(0x1AFFFFFF);

  /// The docked panel's shade over the backdrop (wide windows): just enough
  /// to set it apart from the player, not a card.
  static const Color panelShade = Color(0x2E000000);

  /// A see-through white, for animating a fill in from nothing.
  static const Color clear = Color(0x00FFFFFF);
}

/// Colours that never follow the theme: the camera's black ground and white
/// viewfinder, the QR code's white plate, a switch's white knob, see-through
/// grounds under sheets that paint their own.
abstract final class JamFixedColors {
  static const Color white = Color(0xFFFFFFFF);
  static const Color black = Color(0xFF000000);
  static const Color clear = Color(0x00000000);

  /// The segmented control's thumb in dark mode: a quiet warm grey a step
  /// above the dark fills (1.5:1 on its track, with a hairline edge; `label`
  /// on it 8.7:1) — the chosen word, set semibold, carries the choice.
  static const Color segmentThumbDark = Color(0xFF4A433E);
}

/// Faces (D3): eight earthy hues at one luminance (OKLCH chroma ≈ 0.10), so
/// no face is louder than another and none sits near raspberry (the nearest,
/// terracotta and plum, are 33° and 44° of hue away). White initials clear
/// 4.7:1 on every one. Ordered so that neighbouring slots — where a colour
/// collision in a jam moves someone — are far apart on the wheel.
abstract final class JamAvatarPalette {
  static const List<Color> colors = [
    Color(0xFFA86048), // terracotta
    Color(0xFF157E8E), // sea
    Color(0xFF966B27), // ochre
    Color(0xFF4A75AD), // slate
    Color(0xFF6D792F), // olive
    Color(0xFF756AAC), // indigo
    Color(0xFF2F815B), // pine
    Color(0xFF956197), // plum
  ];

  /// The initials on every face.
  static const Color initials = Color(0xFFFFFFFF);
}

/// Backdrop-blur strengths that pair with [JamColors.material] and
/// [JamColors.glass].
abstract final class JamBlur {
  /// Chrome: nav bars, mini player, toasts.
  static const double material = 12;

  /// Glass buttons over artwork: matte, no blur.
  static const double glass = 0;
}

/// The 4-pt spacing grid.
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
  static const double giant = 56;

  /// Screen side margin on phones. See [pageFor] for wider windows.
  static const double page = 16;

  /// Screen side margin from [pageWideFrom] up (Plus / Pro Max phones,
  /// tablets) — UIKit's layout margins.
  static const double pageWide = 20;

  /// The window width at which the side margin grows from [page] to
  /// [pageWide]. A 402 pt Pro keeps 16, as UIKit does.
  static const double pageWideFrom = 414;

  /// Now Playing's side margin on phones: the cover, title, scrubber and
  /// transport all sit on it.
  static const double player = 28;

  /// Gap between grouped sections.
  static const double section = 32;

  /// Section header (or footer) to its rows.
  static const double sectionHeader = 6;

  /// The side margin for a window [width] wide.
  static double pageFor(double width) =>
      width >= pageWideFrom ? pageWide : page;
}

/// The icon size scale. Every glyph takes one of these; a glyph that marks
/// a state (selected, failed) is filled, an informational one is outlined.
abstract final class JamIconSize {
  /// A disclosure chevron (`chevron_forward`), pop-up chevrons, the
  /// external ↗ — anything trailing a row or a label that says "this goes
  /// somewhere".
  static const double disclosure = 14;

  /// A glyph inside a line of footnote or subheadline text: the player's
  /// status line and banner, a small button's icon, a menu checkmark.
  static const double inline = 15;

  /// A glyph inside a control or a toast: a large button's icon, a menu
  /// row's icon, a notice's tone glyph.
  static const double control = 20;

  /// A row's leading glyph (in a [JamMetrics.rowIconBox] box).
  static const double row = 22;

  /// A nav bar or toolbar glyph.
  static const double nav = 22;

  /// The play and pause glyph in the play square.
  static const double play = 30;

  /// An empty state's (or a permission primer's) glyph.
  static const double hero = 48;
}

/// Fixed component metrics (§2 Spacing, §4, §5).
abstract final class JamMetrics {
  /// Minimum hit target, and the minimum row height.
  static const double hitTarget = 44;

  /// A row with only a title.
  static const double rowHeight = 44;

  /// A row with a subtitle.
  static const double rowHeightSubtitle = 60;

  /// The leading icon box in a row (icon 22 inside 30).
  static const double rowIconBox = 30;

  /// Row leading icon glyph size ([JamIconSize.row]).
  static const double rowIcon = JamIconSize.row;

  /// Nav bar icon glyph size ([JamIconSize.nav]).
  static const double navIcon = JamIconSize.nav;

  /// The inline nav bar height (without the status bar).
  static const double navBarHeight = 44;

  /// `JamButton` large height.
  static const double buttonHeight = 50;

  /// `JamButton` small height (in-row actions).
  static const double buttonHeightSmall = 30;

  /// The floating mini player's height.
  static const double miniPlayerHeight = 64;

  /// A glass icon button's painted circle.
  static const double glassButton = 36;

  /// The sheet grabber.
  static const Size grabber = Size(36, 5);

  /// The width of an alert (narrower windows inset it by 40 a side).
  static const double alertWidth = 300;

  /// An alert's buttons: soft rectangles ([JamRadius.alertButton]).
  static const double alertButtonHeight = 44;

  /// A pull-down menu row.
  static const double menuRow = 44;

  /// The play square on Now Playing.
  static const double playSquare = 76;
}

/// Corner radii — the one radius table (DESIGN_SPEC v4 "Soft rectangles").
/// Buttons, alerts' buttons, toasts and banners are soft rectangles; the
/// only round things are faces, glass icon buttons and the scrubber.
///
/// | Shape | Radius |
/// |---|---|
/// | Artwork ≤ 44 / ≤ 64 / ≤ 159 / larger | 6 / 8 / 12 / 18 ([largeCover]) |
/// | Now Playing cover | 18 ([largeCover]) |
/// | Large button / small button | 16 ([button]) / 10 ([buttonSmall]) |
/// | Alert button | 14 ([alertButton]) |
/// | Toast, player banner | 16 ([notice]) |
/// | Mini player | 20 ([miniPlayer]) |
/// | Play square (continuous corners) | 28 ([playSquare]) |
/// | Inset-grouped section | 20 (a lone row: 12 — see [sectionFor]) |
/// | Sheet, edge-attached / floating | 38 |
/// | Alert | 34 |
/// | Pull-down menu | 22 |
/// | Text field | 10 |
abstract final class JamRadius {
  /// A generic step for one-off shapes (a tooltip, a highlight).
  static const double sm = 8;

  /// A generic step for one-off shapes (the lifted queue row).
  static const double md = 12;

  /// Artwork up to 44 on a side.
  static const double artworkXs = 6;

  /// Artwork up to 64 on a side.
  static const double artworkS = 8;

  /// Artwork up to [largeCoverFrom].
  static const double artworkM = 12;

  /// A large cover: Now Playing's.
  static const double largeCover = 18;

  /// The edge from which artwork takes [largeCover].
  static const double largeCoverFrom = 160;

  /// A large `JamButton` (50 tall).
  static const double button = 16;

  /// A small `JamButton` (30 tall).
  static const double buttonSmall = 10;

  /// An alert's buttons (44 tall): between [buttonSmall] and [button], and
  /// concentric with the alert's corner and padding.
  static const double alertButton = 14;

  /// A toast or the player's banner: one soft rectangle for "something
  /// happened" wherever it is said.
  static const double notice = 16;

  /// The floating mini player.
  static const double miniPlayer = 20;

  /// The play square — use with `RoundedSuperellipseBorder` (continuous
  /// corners); never echoed on any other control.
  static const double playSquare = 28;

  /// An inset-grouped section. One value app-wide.
  static const double section = 20;

  /// The section radius for a block [height] tall: [section], but never
  /// so round that a single row reads as a pill (CR-17) — held 10 under
  /// half its height, so a lone 44 row is a soft rectangle at [md].
  static double sectionFor(double height) => _softFor(height, section);

  /// [max], held [_kSoftMargin] under half of [height] and never under [md]:
  /// the one rule that keeps a short block from turning into a capsule
  /// (D9).
  static double _softFor(double height, double max) {
    final cap = height / 2 - _kSoftMargin;
    return cap < max ? (cap < md ? md : cap) : max;
  }

  /// How far under half its height a short block's corner stays.
  static const double _kSoftMargin = 10;

  /// A sheet's top corners when attached to the bottom edge (the large
  /// detent): follows the device's own corner, approximated here.
  static const double sheet = 38;

  /// A sheet that floats inset from the edges (the medium detent, a form
  /// sheet on a wide window): all four corners.
  static const double sheetFloating = 38;

  /// The gap a floating sheet keeps from the window's sides and bottom.
  static const double sheetFloatingInset = 8;

  /// Alerts.
  static const double alert = 34;

  /// Pull-down and context menus.
  static const double menu = 22;

  /// The menu radius for a panel [height] tall: [menu], but never so round
  /// that a one-row menu turns into a pill (D9) — the rule [sectionFor]
  /// follows, capped at [menu].
  static double menuFor(double height) => _softFor(height, menu);

  /// Text and search fields.
  static const double field = 10;

  /// The artwork corner radius for an edge of [size]. A jam's mark
  /// (`JamMark`) uses the same steps: a jam with art and one without are
  /// the same object.
  static double artwork(double size) {
    if (size <= 44) return artworkXs;
    if (size <= 64) return artworkS;
    if (size < largeCoverFrom) return artworkM;
    return largeCover;
  }
}

/// Standard artwork sizes.
abstract final class JamArtworkSize {
  /// The mini player.
  static const double mini = 40;

  /// A list row (queue, songs, people's covers).
  static const double row = 44;

  /// A tile with no size of its own (the artwork widgets' default).
  static const double thumb = 48;

  /// The queue-in-place thumbnail beside Now Playing's title.
  static const double list = 56;
}

/// Shadows. There is exactly one: under large artwork.
abstract final class JamShadow {
  /// Under the Now Playing cover and a large jam mark (a past jam's page,
  /// the page a jam ends on). Black 25%, blur 30, y 12.
  static const List<BoxShadow> artwork = [
    BoxShadow(color: Color(0x40000000), blurRadius: 30, offset: Offset(0, 12)),
  ];
}

/// Motion durations. Controls move in 100–350 ms; a sheet takes 400, the
/// pause spring 550 and the backdrop's cross-fade 600. Pair with a
/// [JamCurve]; respect `MediaQuery.disableAnimations` at the call site.
abstract final class JamDuration {
  /// Press feedback (the play square's squeeze) and icon swaps.
  static const Duration instant = Duration(milliseconds: 100);

  /// Small state changes: switches, selection, a menu closing.
  static const Duration fast = Duration(milliseconds: 200);

  /// Most transitions: a menu opening, sheet content, row insert, colour.
  static const Duration base = Duration(milliseconds: 300);

  /// Larger moves: a panel docking, the artwork shrinking into the queue.
  static const Duration slow = Duration(milliseconds: 350);

  /// A sheet rising (with [JamCurve.emphasized]).
  static const Duration sheet = Duration(milliseconds: 400);

  /// The cover settling to (or from) its paused size (with
  /// [JamCurve.spring]).
  static const Duration spring = Duration(milliseconds: 550);

  /// The Now Playing backdrop cross-fade on track change.
  static const Duration crossfade = Duration(milliseconds: 600);
}

/// Motion curves.
abstract final class JamCurve {
  /// The iOS ease: `Cubic(0.25, 0.1, 0.25, 1)`. Things arriving.
  static const Curve standard = Cubic(0.25, 0.1, 0.25, 1);

  /// Things leaving: faster out than in.
  static const Curve exit = Curves.easeIn;

  /// A critically-damped-ish spring for size changes (artwork scale, queue
  /// thumbnail, a press released).
  static const Curve spring = JamSpringCurve();

  /// Something large arriving from off screen (a sheet): quick to start,
  /// long to settle.
  static const Curve emphasized = Curves.fastEaseInToSlowEaseOut;
}

/// A curve that follows an under-damped spring from 0 to 1 — a small settle,
/// not a bounce.
class JamSpringCurve extends Curve {
  const JamSpringCurve({this.dampingRatio = 0.82, this.stiffness = 180});

  final double dampingRatio;
  final double stiffness;

  @override
  double transformInternal(double t) {
    final spring = SpringDescription.withDampingRatio(
      mass: 1,
      stiffness: stiffness,
      ratio: dampingRatio,
    );
    final sim = SpringSimulation(spring, 0, 1, 0);
    // Map t∈[0,1] onto the time the spring needs to settle.
    const settle = 0.6;
    final x = sim.x(t * settle);
    return t == 1 ? 1 : x;
  }
}

/// Haptics, named for the moment.
abstract final class JamHaptics {
  /// Play or pause: light impact.
  static void transport() => HapticFeedback.lightImpact();

  /// Next or previous track.
  static void skip() => HapticFeedback.selectionClick();

  /// The scrubber picked up.
  static void scrubStart() => HapticFeedback.selectionClick();

  /// The scrubber released at a new position.
  static void scrubEnd() => HapticFeedback.lightImpact();

  /// A track landed in the local queue.
  static void queued() => HapticFeedback.lightImpact();

  /// The jam started (host) or was joined (guest): success notification.
  static void jamStarted() => HapticFeedback.successNotification();

  /// Somebody walked into the room.
  static void peerJoined() => HapticFeedback.selectionClick();

  /// A consequential confirmation: kick, end the jam, remove a track.
  static void destructive() => HapticFeedback.mediumImpact();

  /// Playback fell out of sync. Rate-limited by the caller — see
  /// [offSyncThrottle].
  static void offSync() => HapticFeedback.heavyImpact();

  /// The minimum gap between two [offSync] buzzes.
  static const Duration offSyncThrottle = Duration(seconds: 30);

  /// A reorder drag picked up or dropped.
  static void reorder() => HapticFeedback.selectionClick();

  /// A toggle, a segmented control, a checkmark choice.
  static void selection() => HapticFeedback.selectionClick();
}

/// Reads the [JamColors] for the current theme.
extension JamColorsOf on BuildContext {
  JamColors get jamColors =>
      Theme.of(this).extension<JamColors>() ?? JamColors.light;
}
