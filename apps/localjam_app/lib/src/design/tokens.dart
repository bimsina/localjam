/// The LocalJam design tokens (DESIGN_SPEC v3 §2).
///
/// Apple system neutrals carry the chrome — white and grouped grey on light,
/// true black on dark — and raspberry is the **tint**: it lands only on things
/// you can tap, plus selection. Cover art carries every other colour.
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
  });

  /// Plain screens: Home, History, the scan fallbacks.
  final Color background;

  /// Grouped screens: Settings, Start a Jam, the People sheet.
  final Color groupedBackground;

  /// Rows and cells inside a grouped section.
  final Color groupedSurface;

  /// Sheets, alerts and menus.
  final Color elevated;

  /// The ground of a sheet that hosts grouped rows (light `#F2F2F7`, dark
  /// `#1C1C1E`).
  final Color elevatedGroupedBackground;

  /// Rows inside a grouped sheet (light `#FFFFFF`, dark `#2C2C2E`).
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

  /// Placeholders, disabled text, grabbers, chevrons.
  final Color tertiaryLabel;

  /// Tappable text and icons, filled buttons, selection, checkmarks.
  final Color tint;

  /// [tint] while pressed.
  final Color tintPressed;

  /// "Tinted" buttons (Join) and the selected sidebar item.
  final Color tintFill;

  /// Text and icons on a [tint] fill.
  final Color onTint;

  /// Switch "on" track. Apple's green — switches are never raspberry.
  final Color success;

  /// Recoverable trouble as text or an icon: "Catching up…".
  final Color warning;

  /// Destructive buttons and rows, failures.
  final Color danger;

  /// Behind sheets and alerts.
  final Color scrim;

  /// Translucent chrome (nav bars on scroll, mini player, menus, toasts).
  /// Always paired with a [JamBlur.material] backdrop blur.
  final Color material;

  /// Round icon buttons over artwork. Paired with [JamBlur.glass].
  final Color glass;

  /// The ground of a filled tint button (`JamButton.filled`, an alert's
  /// preferred action). Darker than [tint] in dark mode so the white label
  /// clears 4.5:1 — the bright dark-mode tint is for tint *text* on black.
  /// Falls back to [tint].
  Color get tintFilled => _tintFilled ?? tint;
  final Color? _tintFilled;

  /// Warm paper and ink, with raspberry reserved for interaction.
  static const JamColors light = JamColors(
    background: Color(0xFFFAF8F5),
    groupedBackground: Color(0xFFF2EFEB),
    groupedSurface: Color(0xFFFFFEFC),
    elevated: Color(0xFFFAF8F5),
    elevatedGroupedBackground: Color(0xFFFAF8F5),
    elevatedGroupedSurface: Color(0xFFFFFEFC),
    fill: Color(0xFFE8E3DE),
    fillSecondary: Color(0xFFF0EBE6),
    fillPressed: Color(0x102C2529),
    separator: Color(0x242C2529),
    label: Color(0xFF292428),
    secondaryLabel: Color(0xFF71686D),
    tertiaryLabel: Color(0xFF9B9196),
    tint: Color(0xFFB82F59),
    tintPressed: Color(0xFF922343),
    tintFill: Color(0xFFF6E3E8),
    onTint: Color(0xFFFFFFFF),
    success: Color(0xFF3E8068),
    warning: Color(0xFFA54C20),
    danger: Color(0xFFC0393E),
    scrim: Color(0x66211C20),
    material: Color(0xF5FAF8F5),
    glass: Color(0x14FFFFFF),
    tintFilled: Color(0xFFB82F59),
  );

  /// Warm charcoal keeps dark mode intimate without a purple cast.
  static const JamColors dark = JamColors(
    background: Color(0xFF191719),
    groupedBackground: Color(0xFF191719),
    groupedSurface: Color(0xFF252225),
    elevated: Color(0xFF211E21),
    elevatedGroupedBackground: Color(0xFF211E21),
    elevatedGroupedSurface: Color(0xFF302B2F),
    fill: Color(0xFF3B3439),
    fillSecondary: Color(0xFF2E292D),
    fillPressed: Color(0x14FFFFFF),
    separator: Color(0x29EFE4E8),
    label: Color(0xFFF7F2EE),
    secondaryLabel: Color(0xFFBEB3B8),
    tertiaryLabel: Color(0xFF8F828A),
    tint: Color(0xFFF28AA7),
    tintPressed: Color(0xFFD96F8F),
    tintFill: Color(0xFF432A34),
    onTint: Color(0xFFFFFFFF),
    success: Color(0xFF79B79C),
    warning: Color(0xFFEAAF79),
    danger: Color(0xFFFF9190),
    scrim: Color(0x99211C20),
    material: Color(0xF5252225),
    glass: Color(0x14FFFFFF),
    tintFilled: Color(0xFFB82F59),
  );

  /// The light palette under the system's Increase Contrast: secondary text
  /// and hairlines firmer, the tint a step deeper (spec §8: AA everywhere).
  static final JamColors lightHighContrast = light.copyWith(
    secondaryLabel: const Color(0xCC3C3C43),
    tertiaryLabel: const Color(0x993C3C43),
    separator: const Color(0x803C3C43),
    tint: const Color(0xFFB31F51),
    tintPressed: const Color(0xFF8F1640),
    tintFilled: const Color(0xFFB31F51),
    warning: const Color(0xFFA62B00),
    danger: const Color(0xFFD70015),
  );

  /// The dark palette under Increase Contrast.
  static final JamColors darkHighContrast = dark.copyWith(
    secondaryLabel: const Color(0xCCEBEBF5),
    tertiaryLabel: const Color(0x99EBEBF5),
    separator: const Color(0xCC6C6C70),
    tint: const Color(0xFFFF6A95),
    tintPressed: const Color(0xFFFF4F82),
    tintFilled: const Color(0xFFB31F51),
    warning: const Color(0xFFFFB340),
    danger: const Color(0xFFFF6961),
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

/// The fixed palette of the immersive Now Playing surface (D4). Identical in
/// both themes: the backdrop is always dark enough for white text.
abstract final class JamNowPlayingColors {
  /// Titles, transport glyphs.
  static const Color text = Color(0xFFFFFFFF);

  /// "Added by Mia", times. 70%, not iOS's 60%: the backdrop's overlay is
  /// solved so this clears 4.5:1 on any cover (spec §10.7,
  /// `artwork_tint.dart`).
  static const Color secondary = Color(0xB3FFFFFF);

  /// The grabber, drag handles, disabled transport.
  static const Color tertiary = Color(0x59FFFFFF);

  /// The scrubber's unplayed track.
  static const Color track = Color(0x40FFFFFF);

  /// The scrubber's played part; the selected footer-icon circle.
  static const Color fill = Color(0xD9FFFFFF);

  /// The artwork placeholder's ground on the backdrop.
  static const Color placeholderGround = Color(0x1FFFFFFF);

  /// The artwork placeholder's note on the backdrop.
  static const Color placeholderGlyph = Color(0x80FFFFFF);

  /// The backdrop when the cover is a placeholder: a deep neutral…
  static const Color backdropPlaceholder = Color(0xFF211E21);

  /// …with a faint radial lift behind the cover, so a song without art
  /// still reads as Now Playing rather than a loading screen (§10.7).
  static const Color backdropPlaceholderLift = Color(0x1FFFFFFF);

  /// The platter a long-pressed queue row lifts onto, above its menu.
  static const Color liftedRow = Color(0xFF2C2C2E);

  /// What a queue row's long-press menu dims the rest of the screen with.
  static const Color contextScrim = Color(0x59000000);

  /// Grouped rows on the backdrop (the docked People panel): translucent
  /// white, never an opaque card.
  static const Color groupedRow = Color(0x17FFFFFF);

  /// Destructive *text* on the backdrop ("End Jam" in the docked panel).
  /// System red is 2–3:1 on a darkened cover; this light red holds 4.5:1
  /// over the backdrop's brightest allowed ground and still reads as red.
  static const Color destructive = Color(0xFFFFBAB5);

  /// Warning *text* on the backdrop ("Still loading songs…"), for the same
  /// reason.
  static const Color warning = Color(0xFFFFD27A);

  /// Hairlines between grouped rows on the backdrop.
  static const Color separator = Color(0x29FFFFFF);

  /// Glass buttons over the backdrop.
  static const Color glass = Color(0x2EFFFFFF);

  /// The glyph on a selected (white-filled) footer or glass button.
  static const Color selectedGlyph = Color(0xFF000000);

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

  /// The segmented control's thumb in dark mode (iOS's).
  static const Color segmentThumbDark = Color(0xFF636366);
}

/// Faces (D6): Apple's blue, indigo, purple, pink, red, orange, green and
/// teal at ~85% saturation, darkened until white initials clear 3:1.
abstract final class JamAvatarPalette {
  static const List<Color> colors = [
    Color(0xFF137BEC),
    Color(0xFF6160CC),
    Color(0xFFAC5CD4),
    Color(0xFFEF3D5F),
    Color(0xFFEF4940),
    Color(0xFFCB7D10),
    Color(0xFF37A352),
    Color(0xFF379CAE),
  ];

  /// The initials on every face.
  static const Color initials = Color(0xFFFFFFFF);
}

/// Backdrop-blur strengths that pair with [JamColors.material] and
/// [JamColors.glass].
abstract final class JamBlur {
  /// Chrome: nav bars, mini player, menus, toasts.
  static const double material = 12;

  /// Glass buttons over artwork.
  static const double glass = 0;

  /// The Now Playing backdrop's cover blur (σ).
  static const double backdrop = 70;
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

  /// Padding inside a custom content block in a grouped section.
  static const double card = 16;

  /// Gap between grouped sections.
  static const double section = 32;

  /// Section header (or footer) to its rows.
  static const double sectionHeader = 6;

  /// The side margin for a window [width] wide.
  static double pageFor(double width) =>
      width >= pageWideFrom ? pageWide : page;
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

  /// Row leading icon glyph size.
  static const double rowIcon = 22;

  /// Nav bar icon glyph size.
  static const double navIcon = 22;

  /// A row's small trailing glyphs: the pop-up chevrons, a disclosure.
  static const double disclosureIcon = 14;

  /// The inline nav bar height (without the status bar).
  static const double navBarHeight = 44;

  /// The large title's area under the inline bar.
  static const double largeTitleHeight = 52;

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

  /// The width of an iOS 26 alert (narrower windows inset it by 40 a side).
  static const double alertWidth = 300;

  /// An iOS 26 alert's capsule buttons.
  static const double alertButtonHeight = 44;

  /// A pull-down menu row.
  static const double menuRow = 44;
}

/// Corner radii — the one radius table (spec §2 Radii as amended by §10.3:
/// one iOS era, iOS 26).
///
/// | Shape | Radius |
/// |---|---|
/// | Artwork ≤ 44 / ≤ 64 / larger | 6 / 8 / 12 |
/// | Inset-grouped section | 26 (never more than half a lone row: see [sectionFor]) |
/// | Sheet, edge-attached (large detent: follows the device corner) | 38 (top) |
/// | Sheet, floating (medium detent, iPad form sheet) | 38 (all four) |
/// | Alert | 34 |
/// | Pull-down menu | 22 |
/// | Text field | 10 |
/// | Buttons, toasts, mini player | capsule |
abstract final class JamRadius {
  /// A generic scale for one-off shapes.
  static const double xs = 6;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;

  /// Artwork up to 44 on a side.
  static const double artworkXs = 6;

  /// Artwork up to 64 on a side.
  static const double artworkS = 8;

  /// Artwork above 64.
  static const double artworkM = 12;

  /// The Now Playing hero cover.
  static const double nowPlaying = 18;

  /// An inset-grouped section (iOS 26's rounder grouped look). One value
  /// app-wide.
  static const double section = 20;

  /// The section radius for a block [height] tall: [section], but never
  /// so round that a single 44 row turns into a pill.
  static double sectionFor(double height) {
    final cap = height / 2 - 6;
    return cap < section ? (cap < md ? md : cap) : section;
  }

  /// A sheet's top corners when attached to the bottom edge (the large
  /// detent): iOS 26 follows the device's own corner, approximated here.
  static const double sheet = 38;

  /// A sheet that floats inset from the edges (the medium detent, a form
  /// sheet on a wide window): all four corners.
  static const double sheetFloating = 38;

  /// The gap a floating sheet keeps from the window's sides and bottom.
  static const double sheetFloatingInset = 8;

  /// Alerts (iOS 26).
  static const double alert = 34;

  /// Pull-down menus (iOS 26).
  static const double menu = 22;

  /// Text and search fields.
  static const double field = 10;

  /// Buttons, toasts, the mini player: a stadium.
  static const double capsule = 999;

  /// The artwork corner radius for an edge of [size].
  static double artwork(double size) {
    if (size <= 44) return artworkXs;
    if (size <= 64) return artworkS;
    return artworkM;
  }
}

/// Standard artwork sizes.
abstract final class JamArtworkSize {
  /// The mini player.
  static const double mini = 40;

  /// A list row (queue, songs, people's covers).
  static const double row = 44;

  /// Recent jams on Home.
  static const double thumb = 48;

  /// The docked room bar (wide layouts).
  static const double bar = 44;

  /// History rows; the queue-in-place thumbnail.
  static const double list = 56;

  /// The History detail header.
  static const double detail = 200;

  /// Now-playing hero ceiling on tablets and desktop.
  static const double hero = 420;

  /// The hero's cap beside a docked panel.
  static const double heroExpanded = 340;
}

/// Shadows. There is exactly one: under large artwork.
abstract final class JamShadow {
  /// Under the Now Playing cover and the History detail cover. Black 25%,
  /// blur 30, y 12.
  static const List<BoxShadow> artwork = [
    BoxShadow(color: Color(0x40000000), blurRadius: 30, offset: Offset(0, 12)),
  ];
}

/// Motion durations (250–350 ms band). Pair with [JamCurve.standard]; respect
/// `MediaQuery.disableAnimations` at the call site.
abstract final class JamDuration {
  /// Press highlights and icon swaps.
  static const Duration instant = Duration(milliseconds: 100);

  /// Small state changes: switches, selection.
  static const Duration fast = Duration(milliseconds: 200);

  /// Most transitions: sheet content, row insert, colour.
  static const Duration base = Duration(milliseconds: 300);

  /// Larger moves: a panel docking, the artwork shrinking into the queue.
  static const Duration slow = Duration(milliseconds: 350);

  /// The Now Playing backdrop cross-fade on track change.
  static const Duration crossfade = Duration(milliseconds: 600);
}

/// Motion curves.
abstract final class JamCurve {
  /// The iOS ease: `Cubic(0.25, 0.1, 0.25, 1)`.
  static const Curve standard = Cubic(0.25, 0.1, 0.25, 1);

  /// Things leaving: faster out than in.
  static const Curve exit = Curves.easeIn;

  /// A critically-damped-ish spring for size changes (artwork scale, queue
  /// thumbnail).
  static const Curve spring = JamSpringCurve();
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
