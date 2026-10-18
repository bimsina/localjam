/// Translucent chrome (D1): the `material` blur behind bars, the mini player,
/// toasts and menus, and the round glass icon buttons over artwork.
library;

import 'dart:ui' show ImageFilter;

import 'package:flutter/widgets.dart';

import '../design/tokens.dart';
import 'pressable.dart';

/// Which translucent material to paint.
enum JamMaterialKind {
  /// `material` colour + [JamBlur.material]: chrome on ordinary screens.
  chrome,

  /// `glass` colour + [JamBlur.glass]: controls over artwork / the backdrop.
  glass,
}

/// A blurred translucent surface clipped to [shape].
class JamBlurSurface extends StatelessWidget {
  const JamBlurSurface({
    super.key,
    required this.child,
    this.kind = JamMaterialKind.chrome,
    this.shape = const RoundedRectangleBorder(),
    this.color,
    this.border,
  });

  final Widget child;
  final JamMaterialKind kind;

  /// The clip and paint shape — `StadiumBorder()` for capsules,
  /// `CircleBorder()` for icon buttons.
  final ShapeBorder shape;

  /// Overrides the material's colour.
  final Color? color;

  /// An optional hairline stroke (the mini player's 0.5 pt edge).
  final BorderSide? border;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final (Color fill, double sigma) = switch (kind) {
      JamMaterialKind.chrome => (colors.material, JamBlur.material),
      JamMaterialKind.glass => (colors.glass, JamBlur.glass),
    };
    final border = this.border;
    final painted = border == null
        ? shape
        : (shape is OutlinedBorder
              ? (shape as OutlinedBorder).copyWith(side: border)
              : shape);
    return ClipPath(
      clipper: ShapeBorderClipper(shape: shape),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
        child: DecoratedBox(
          decoration: ShapeDecoration(color: color ?? fill, shape: painted),
          child: child,
        ),
      ),
    );
  }
}

/// A round translucent icon button: 44 hit area, a [visualSize] circle of
/// chrome material (or glass over artwork when [onArtwork]), glyph
/// [iconSize]. [semanticLabel] is required.
class JamGlassButton extends StatelessWidget {
  const JamGlassButton({
    super.key,
    required this.icon,
    required this.semanticLabel,
    this.onPressed,
    this.onArtwork = false,
    this.visualSize = JamMetrics.glassButton,
    this.iconSize = 18,
    this.selected = false,
    this.iconColor,
    this.fillColor,
  });

  final IconData icon;
  final String semanticLabel;
  final VoidCallback? onPressed;

  /// Glass (white 18%, white glyph) for the Now Playing backdrop and artwork.
  final bool onArtwork;

  /// The painted circle (34–36; 30 for the Now Playing •••).
  final double visualSize;

  /// The glyph (17–20).
  final double iconSize;

  /// The selected state: an opaque white circle behind a dark glyph (Now
  /// Playing's queue toggle).
  final bool selected;

  /// Overrides the glyph colour.
  final Color? iconColor;

  /// A flat circle in this colour instead of the blurred material — for
  /// a button on a surface the material would vanish into (a sheet's
  /// xmark on the dark `elevated` ground).
  final Color? fillColor;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final enabled = onPressed != null;
    final glyph =
        iconColor ??
        (selected
            ? JamNowPlayingColors.selectedGlyph
            : onArtwork
            ? JamNowPlayingColors.text
            : colors.label);

    final fill = fillColor;
    final circle = fill != null && !selected
        ? DecoratedBox(
            decoration: ShapeDecoration(
              color: fill,
              shape: const CircleBorder(),
            ),
            child: SizedBox.square(
              dimension: visualSize,
              child: Icon(icon, size: iconSize, color: glyph),
            ),
          )
        : selected
        ? DecoratedBox(
            decoration: const ShapeDecoration(
              color: JamNowPlayingColors.fill,
              shape: CircleBorder(),
            ),
            child: SizedBox.square(
              dimension: visualSize,
              child: Icon(icon, size: iconSize, color: glyph),
            ),
          )
        : JamBlurSurface(
            kind: onArtwork ? JamMaterialKind.glass : JamMaterialKind.chrome,
            shape: const CircleBorder(),
            child: SizedBox.square(
              dimension: visualSize,
              child: Icon(icon, size: iconSize, color: glyph),
            ),
          );

    return Semantics(
      container: true,
      button: true,
      enabled: enabled,
      selected: selected,
      label: semanticLabel,
      onTap: onPressed,
      excludeSemantics: true,
      child: Opacity(
        opacity: enabled ? 1 : 0.35,
        child: JamPressable(
          onTap: onPressed,
          child: SizedBox.square(
            dimension: visualSize > JamMetrics.hitTarget
                ? visualSize
                : JamMetrics.hitTarget,
            child: Center(child: circle),
          ),
        ),
      ),
    );
  }
}
