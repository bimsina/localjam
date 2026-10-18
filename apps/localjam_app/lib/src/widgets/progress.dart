/// Progress, the iOS way: the activity indicator everywhere (no Material
/// circular indicators), and a thin capsule bar for determinate progress.
library;

import 'package:flutter/cupertino.dart';

import '../design/tokens.dart';

/// The spinning activity indicator. [progress] (0–1) draws the partially
/// revealed, non-spinning form instead.
class JamSpinner extends StatelessWidget {
  const JamSpinner({super.key, this.radius = 10, this.color, this.progress});

  /// 10 is iOS's default (20 across); 8 inside small buttons.
  final double radius;

  /// Defaults to `secondaryLabel`.
  final Color? color;

  /// Determinate progress, 0–1.
  final double? progress;

  @override
  Widget build(BuildContext context) {
    final c = color ?? context.jamColors.secondaryLabel;
    final p = progress;
    if (p != null) {
      return CupertinoActivityIndicator.partiallyRevealed(
        radius: radius,
        color: c,
        progress: p.clamp(0.0, 1.0),
      );
    }
    return CupertinoActivityIndicator(radius: radius, color: c);
  }
}

/// A determinate capsule bar: [value] of `tint` (or [color]) on a `fill`
/// track, [height] tall.
class JamProgressBar extends StatelessWidget {
  const JamProgressBar({
    super.key,
    required this.value,
    this.height = 4,
    this.color,
    this.trackColor,
  });

  final double value;
  final double height;
  final Color? color;
  final Color? trackColor;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final v = value.clamp(0.0, 1.0);
    return ClipRRect(
      borderRadius: BorderRadius.circular(height / 2),
      child: SizedBox(
        height: height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: trackColor ?? colors.fill),
            FractionallySizedBox(
              alignment: AlignmentDirectional.centerStart,
              widthFactor: v,
              child: ColoredBox(color: color ?? colors.tint),
            ),
          ],
        ),
      ),
    );
  }
}
