/// The LocalJam design tokens.
///
/// Light-first: the light palette is the one the app is designed against and
/// dark is a full peer, not an inversion afterthought. Chrome stays cream and
/// plum so cover art supplies the colour in the content area; a single
/// raspberry accent carries interactive state, apricot carries warmth and
/// liveness, and only *problems* get a red of their own — "in sync" is
/// deliberately quiet.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Semantic colours, resolved per theme. Read them from the context rather
/// than importing the constants directly: `context.jamColors.accent`.
@immutable
class JamColors extends ThemeExtension<JamColors> {
  const JamColors({
    required this.canvas,
    required this.surface,
    required this.surfaceElevated,
    required this.surfaceMuted,
    required this.separator,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.accent,
    required this.accentPressed,
    required this.accentDeep,
    required this.accentSoft,
    required this.onAccent,
    required this.highlight,
    required this.highlightSoft,
    required this.warning,
    required this.danger,
    required this.scrim,
    required this.shadowTint,
  });

  /// The page behind everything. Cream on light, below-plum on dark.
  final Color canvas;

  /// Cards, list groups, the sidebar, the room bar. Separated from [canvas]
  /// by a hairline on light and by lightness on dark.
  final Color surface;

  /// Sheets, dialogs and popup menus — a step *above* [surface], so a sheet
  /// still reads as lifted on dark where there are no shadows.
  final Color surfaceElevated;

  /// Inset areas: artwork placeholders, chips, disabled fills, text fields.
  final Color surfaceMuted;

  /// Hairline rules between rows and sections, drawn at 0.5 dp.
  final Color separator;

  /// Titles and primary values.
  final Color textPrimary;

  /// Bylines, labels, and the quiet "in sync" state.
  final Color textSecondary;

  /// Placeholder text, disabled text, durations.
  final Color textTertiary;

  /// The one accent: primary actions, selection, the current track.
  final Color accent;

  /// [accent] while pressed.
  final Color accentPressed;

  /// The brand end of the raspberry gradient: app icon, primary-button fill,
  /// the jam-started moment. Identical in both themes — it is a brand mark,
  /// not a UI state.
  final Color accentDeep;

  /// A tinted fill for selected rows and accent chips.
  final Color accentSoft;

  /// Text and icons drawn on top of [accent].
  final Color onAccent;

  /// Apricot: the live dot, the "you" ring, the warm glow, the artwork
  /// placeholder gradient. Warmth, not alarm — it never carries text.
  final Color highlight;

  /// An apricot-tinted fill, for the catching-up banner and live chips.
  final Color highlightSoft;

  /// Recoverable trouble as **text or an icon**: catching up, reconnecting,
  /// a peer still fetching. Apricot itself fails AA as text on cream, so this
  /// is a darker sibling of [highlight] rather than [highlight] itself.
  final Color warning;

  /// Failure: fetch failed, kicked, session ended, unsupported format.
  final Color danger;

  /// Behind modal sheets and dialogs.
  final Color scrim;

  /// The base colour every [JamShadow] is mixed from. Fully transparent on
  /// dark, where separation comes from a lightness step instead.
  final Color shadowTint;

  /// The live dot on a room card and in the room bar.
  Color get liveDot => highlight;

  /// The ring around your own avatar.
  Color get youRing => highlight;

  /// The ring around the host's avatar.
  Color get hostRing => accent;

  /// The light palette — the primary design target.
  static const JamColors light = JamColors(
    canvas: Color(0xFFFFF7F2),
    surface: Color(0xFFFFFFFF),
    surfaceElevated: Color(0xFFFFFFFF),
    surfaceMuted: Color(0xFFF5E9E2),
    separator: Color(0xFFEBDDD4),
    textPrimary: Color(0xFF2B1332),
    textSecondary: Color(0xFF7A6478),
    textTertiary: Color(0xFFA99AA6),
    accent: Color(0xFFD92C64),
    accentPressed: Color(0xFFB31F51),
    accentDeep: Color(0xFFC71F5E),
    accentSoft: Color(0xFFFCE7EE),
    onAccent: Color(0xFFFFFFFF),
    highlight: Color(0xFFFFB25C),
    highlightSoft: Color(0xFFFFF0DC),
    warning: Color(0xFFA85B12),
    danger: Color(0xFFB3261E),
    scrim: Color(0x662B1332),
    shadowTint: Color(0x1A2B1332),
  );

  /// The dark palette: same structure on a plum ground, with an accent picked
  /// for that ground rather than inverted into it.
  static const JamColors dark = JamColors(
    canvas: Color(0xFF150A19),
    surface: Color(0xFF221029),
    surfaceElevated: Color(0xFF2B1332),
    surfaceMuted: Color(0xFF32183A),
    separator: Color(0xFF3D2145),
    textPrimary: Color(0xFFFBF2F6),
    textSecondary: Color(0xFFB9A5BD),
    textTertiary: Color(0xFF7E6C84),
    accent: Color(0xFFFF6E96),
    accentPressed: Color(0xFFE63B6F),
    accentDeep: Color(0xFFC71F5E),
    accentSoft: Color(0xFF3A1329),
    onAccent: Color(0xFF2B1332),
    highlight: Color(0xFFFFB25C),
    highlightSoft: Color(0xFF3A2415),
    warning: Color(0xFFFFC078),
    danger: Color(0xFFFF7A6E),
    scrim: Color(0xA6100616),
    shadowTint: Color(0x00000000),
  );

  /// The brand raspberry — the start of the primary-button and app-icon
  /// gradient. [accent] is a half-step deeper so white labels clear 4.5:1;
  /// this is the colour the brand is drawn in, not one the UI states use.
  static const Color brandRaspberry = Color(0xFFE63B6F);

  @override
  JamColors copyWith({
    Color? canvas,
    Color? surface,
    Color? surfaceElevated,
    Color? surfaceMuted,
    Color? separator,
    Color? textPrimary,
    Color? textSecondary,
    Color? textTertiary,
    Color? accent,
    Color? accentPressed,
    Color? accentDeep,
    Color? accentSoft,
    Color? onAccent,
    Color? highlight,
    Color? highlightSoft,
    Color? warning,
    Color? danger,
    Color? scrim,
    Color? shadowTint,
  }) => JamColors(
    canvas: canvas ?? this.canvas,
    surface: surface ?? this.surface,
    surfaceElevated: surfaceElevated ?? this.surfaceElevated,
    surfaceMuted: surfaceMuted ?? this.surfaceMuted,
    separator: separator ?? this.separator,
    textPrimary: textPrimary ?? this.textPrimary,
    textSecondary: textSecondary ?? this.textSecondary,
    textTertiary: textTertiary ?? this.textTertiary,
    accent: accent ?? this.accent,
    accentPressed: accentPressed ?? this.accentPressed,
    accentDeep: accentDeep ?? this.accentDeep,
    accentSoft: accentSoft ?? this.accentSoft,
    onAccent: onAccent ?? this.onAccent,
    highlight: highlight ?? this.highlight,
    highlightSoft: highlightSoft ?? this.highlightSoft,
    warning: warning ?? this.warning,
    danger: danger ?? this.danger,
    scrim: scrim ?? this.scrim,
    shadowTint: shadowTint ?? this.shadowTint,
  );

  @override
  bool operator ==(Object other) =>
      other is JamColors &&
      other.canvas == canvas &&
      other.surface == surface &&
      other.surfaceElevated == surfaceElevated &&
      other.surfaceMuted == surfaceMuted &&
      other.separator == separator &&
      other.textPrimary == textPrimary &&
      other.textSecondary == textSecondary &&
      other.textTertiary == textTertiary &&
      other.accent == accent &&
      other.accentPressed == accentPressed &&
      other.accentDeep == accentDeep &&
      other.accentSoft == accentSoft &&
      other.onAccent == onAccent &&
      other.highlight == highlight &&
      other.highlightSoft == highlightSoft &&
      other.warning == warning &&
      other.danger == danger &&
      other.scrim == scrim &&
      other.shadowTint == shadowTint;

  @override
  int get hashCode => Object.hashAll([
    canvas,
    surface,
    surfaceElevated,
    surfaceMuted,
    separator,
    textPrimary,
    textSecondary,
    textTertiary,
    accent,
    accentPressed,
    accentDeep,
    accentSoft,
    onAccent,
    highlight,
    highlightSoft,
    warning,
    danger,
    scrim,
    shadowTint,
  ]);

  @override
  JamColors lerp(covariant JamColors? other, double t) {
    if (other == null) return this;
    Color mix(Color a, Color b) => Color.lerp(a, b, t)!;
    return JamColors(
      canvas: mix(canvas, other.canvas),
      surface: mix(surface, other.surface),
      surfaceElevated: mix(surfaceElevated, other.surfaceElevated),
      surfaceMuted: mix(surfaceMuted, other.surfaceMuted),
      separator: mix(separator, other.separator),
      textPrimary: mix(textPrimary, other.textPrimary),
      textSecondary: mix(textSecondary, other.textSecondary),
      textTertiary: mix(textTertiary, other.textTertiary),
      accent: mix(accent, other.accent),
      accentPressed: mix(accentPressed, other.accentPressed),
      accentDeep: mix(accentDeep, other.accentDeep),
      accentSoft: mix(accentSoft, other.accentSoft),
      onAccent: mix(onAccent, other.onAccent),
      highlight: mix(highlight, other.highlight),
      highlightSoft: mix(highlightSoft, other.highlightSoft),
      warning: mix(warning, other.warning),
      danger: mix(danger, other.danger),
      scrim: mix(scrim, other.scrim),
      shadowTint: mix(shadowTint, other.shadowTint),
    );
  }
}

/// The spacing scale. Codifies the values the pre-overhaul screens repeated
/// inline (page padding 20/24, card padding 16, section gap 28).
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

  /// Horizontal page margin.
  static const double page = 20;

  /// Padding inside a card or grouped section.
  static const double card = 16;

  /// Gap between top-level sections.
  static const double section = 28;
}

/// Corner radii. Softer than Material's default so the chrome reads warm
/// rather than engineered.
abstract final class JamRadius {
  static const double xs = 8;
  static const double sm = 10;
  static const double md = 14;
  static const double lg = 18;
  static const double xl = 24;
  static const double xxl = 32;
  static const double pill = 999;

  /// Artwork corner radius for a given edge length, so thumbnails and heroes
  /// stay a family: a 48 dp thumb gets 10, a 340 dp hero gets 28.
  static double artwork(double size) => (size / 9).clamp(10, 28);
}

/// Standard artwork sizes.
abstract final class JamArtworkSize {
  /// List-row thumbnail.
  static const double thumb = 48;

  /// Docked room bar.
  static const double bar = 44;

  /// Now-playing hero. A ceiling for tablets and desktop only — on a phone
  /// the page width bounds first, so the cover lines up with the title's
  /// margin the way it does in Spotify and Apple Music.
  static const double hero = 420;

  /// The hero's cap once the layout is wide enough to sit it beside a panel.
  static const double heroExpanded = 340;
}

/// Drop shadows. Light theme only — on dark, [JamColors.shadowTint] is
/// transparent and every level resolves to an empty list, because separation
/// there comes from the [JamColors.surface] lightness step instead.
abstract final class JamShadow {
  /// List groups and rows: no shadow at all, just a hairline.
  static List<BoxShadow> flat(JamColors c) => const <BoxShadow>[];

  /// Cards, artwork thumbnails, chips that carry an action.
  static List<BoxShadow> raised(JamColors c) => _mix(c, const [
    (0.06, Offset(0, 1), 2.0, 0.0),
    (0.08, Offset(0, 4), 12.0, -2.0),
  ]);

  /// The hero artwork, the room bar, the play button.
  static List<BoxShadow> floating(JamColors c) => _mix(c, const [
    (0.14, Offset(0, 8), 24.0, -4.0),
    (0.06, Offset(0, 2), 6.0, 0.0),
  ]);

  /// Sheets, dialogs and menus — cast upward, since they rise from the edge.
  static List<BoxShadow> overlay(JamColors c) =>
      _mix(c, const [(0.16, Offset(0, -8), 40.0, 0.0)]);

  static List<BoxShadow> _mix(
    JamColors c,
    List<(double, Offset, double, double)> layers,
  ) {
    if (c.shadowTint.a == 0) return const <BoxShadow>[];
    final base = c.shadowTint.withValues(alpha: 1);
    return [
      for (final (alpha, offset, blur, spread) in layers)
        BoxShadow(
          color: base.withValues(alpha: alpha),
          offset: offset,
          blurRadius: blur,
          spreadRadius: spread,
        ),
    ];
  }
}

/// Motion. Short and unfussy — this app is looked at in a moving vehicle.
/// Pair each duration with the [JamCurve] of the same name.
abstract final class JamDuration {
  /// Press and hover states, icon swaps.
  static const Duration instant = Duration(milliseconds: 90);

  /// Chips, switches, ripple settle.
  static const Duration fast = Duration(milliseconds: 140);

  /// Sheet open, row insert, colour lerp.
  static const Duration base = Duration(milliseconds: 220);

  /// The room sliding up, a panel docking.
  static const Duration slow = Duration(milliseconds: 360);

  /// Artwork tint cross-fade, glow shift.
  static const Duration ambient = Duration(milliseconds: 480);

  /// The jam-started moment.
  static const Duration celebration = Duration(milliseconds: 900);
}

/// The curve that belongs with each [JamDuration].
abstract final class JamCurve {
  static const Curve instant = Curves.easeOut;
  static const Curve fast = Curves.easeOutCubic;
  static const Curve base = Curves.easeOutCubic;
  static const Curve slow = Curves.easeOutQuint;
  static const Curve ambient = Curves.easeInOutCubic;

  /// The scale half of the jam-started moment; its fade uses [exit]'s sibling
  /// [Curves.easeOut].
  static const Curve celebration = Curves.easeOutBack;

  /// Reverse transitions: things leave faster than they arrive.
  static const Curve exit = Curves.easeInCubic;
}

/// Haptics, named for the moment rather than the waveform, so call sites read
/// as intent. Every method is a no-op where the platform has no haptic engine
/// (desktop and web), which the framework handles for us.
abstract final class JamHaptics {
  /// Play or pause.
  static void transport() => HapticFeedback.lightImpact();

  /// Next or previous track.
  static void skip() => HapticFeedback.selectionClick();

  /// The scrubber thumb picked up.
  static void scrubStart() => HapticFeedback.selectionClick();

  /// The scrubber thumb released at a new position.
  static void scrubEnd() => HapticFeedback.lightImpact();

  /// A track landed in the local queue.
  static void queued() => HapticFeedback.lightImpact();

  /// The jam started (host) or was joined (guest).
  static void jamStarted() => HapticFeedback.mediumImpact();

  /// Somebody walked into the room.
  static void peerJoined() => HapticFeedback.selectionClick();

  /// A consequential confirmation: kick, end the jam, remove a track.
  static void destructive() => HapticFeedback.mediumImpact();

  /// Playback fell out of sync. Rate-limited by the caller — see
  /// [offSyncThrottle].
  static void offSync() => HapticFeedback.heavyImpact();

  /// The minimum gap between two [offSync] buzzes; going out of sync
  /// repeatedly should not turn the phone into a pager.
  static const Duration offSyncThrottle = Duration(seconds: 30);

  /// A reorder drag picked up or dropped.
  static void reorder() => HapticFeedback.selectionClick();
}

/// Reads the [JamColors] for the current theme.
extension JamColorsOf on BuildContext {
  JamColors get jamColors =>
      Theme.of(this).extension<JamColors>() ?? JamColors.light;
}
