/// Progress, drawn one way: a thin ring ([JamProgressRing]) — filling for
/// an amount (a song downloading), turning for a wait (a button at work) —
/// and a thin soft bar for progress across a width. No spokes, no Material
/// indicators.
library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../design/tokens.dart';

/// The ring's stroke.
const double kJamProgressRingStroke = 2;

/// The share of the circle a waiting ring's arc covers.
const double _kWaitingArc = 0.28;

/// How long a waiting ring takes to go round once.
const Duration _kWaitingTurn = Duration(milliseconds: 900);

/// One progress ring: a [color] arc on a faint track of the same colour,
/// round-capped, starting at twelve o'clock.
///
/// With a [value] (0–1) the arc *is* the amount — a song 35% downloaded
/// shows a third of a ring, so the words beside it need no percentage. With
/// none it is a short arc going round: something is being waited on.
///
/// ```dart
/// JamProgressRing(value: 0.35)                                   // queue row
/// JamProgressRing(value: p, color: JamNowPlayingColors.text)     // the room's status line
/// JamProgressRing(color: colors.onTint, size: 17)                // a button at work
/// ```
class JamProgressRing extends StatefulWidget {
  const JamProgressRing({
    super.key,
    this.value,
    this.size = JamProgressRing.inlineSize,
    this.strokeWidth = kJamProgressRingStroke,
    this.color,
    this.trackColor,
  });

  /// Inside a line of footnote or subheadline text, and a queue row's
  /// status slot.
  static const double inlineSize = 13;

  /// Inside a button, or standing alone on a page.
  static const double controlSize = 17;

  /// The amount, 0–1. Null: waiting (the arc goes round).
  final double? value;

  /// The ring's outer diameter.
  final double size;

  final double strokeWidth;

  /// The arc. Defaults to `secondaryLabel` — progress is information, not
  /// an action, so never the tint.
  final Color? color;

  /// The full circle under the arc. Defaults to [color] at a quarter of its
  /// strength, so the ring reads on paper, charcoal and the backdrop alike.
  final Color? trackColor;

  @override
  State<JamProgressRing> createState() => _JamProgressRingState();
}

class _JamProgressRingState extends State<JamProgressRing>
    with SingleTickerProviderStateMixin {
  AnimationController? _turn;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(JamProgressRing oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  /// A waiting ring turns; an amount holds still.
  void _sync() {
    if (widget.value == null) {
      final turn = _turn ??= AnimationController(
        vsync: this,
        duration: _kWaitingTurn,
      );
      if (!turn.isAnimating) turn.repeat();
    } else {
      _turn?.stop();
    }
  }

  @override
  void dispose() {
    _turn?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? context.jamColors.secondaryLabel;
    final track = widget.trackColor ?? color.withValues(alpha: color.a * 0.25);
    final value = widget.value;
    final turn = _turn;
    final Widget ring;
    if (value != null || turn == null) {
      ring = CustomPaint(
        painter: _RingPainter(
          color: color,
          track: track,
          stroke: widget.strokeWidth,
          start: 0,
          sweep: (value ?? 0).clamp(0.0, 1.0),
        ),
      );
    } else {
      ring = AnimatedBuilder(
        animation: turn,
        builder: (context, _) => CustomPaint(
          painter: _RingPainter(
            color: color,
            track: track,
            stroke: widget.strokeWidth,
            start: turn.value,
            sweep: _kWaitingArc,
          ),
        ),
      );
    }
    return SizedBox.square(dimension: widget.size, child: ring);
  }
}

class _RingPainter extends CustomPainter {
  const _RingPainter({
    required this.color,
    required this.track,
    required this.stroke,
    required this.start,
    required this.sweep,
  });

  final Color color;
  final Color track;
  final double stroke;

  /// Where the arc starts, in turns clockwise from twelve o'clock.
  final double start;

  /// How much of the circle the arc covers, 0–1.
  final double sweep;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(stroke / 2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;
    canvas.drawOval(rect, paint..color = track);
    if (sweep <= 0) return;
    canvas.drawArc(
      rect,
      -math.pi / 2 + start * 2 * math.pi,
      sweep * 2 * math.pi,
      false,
      paint
        ..color = color
        ..strokeCap = sweep >= 1 ? StrokeCap.butt : StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.color != color ||
      old.track != track ||
      old.stroke != stroke ||
      old.start != start ||
      old.sweep != sweep;
}

/// Something is being waited on — or, with [progress], how far along it is:
/// a [JamProgressRing] [radius] × 2 across. Kept for its call sites; new
/// code can use the ring directly.
class JamSpinner extends StatelessWidget {
  const JamSpinner({super.key, this.radius = 10, this.color, this.progress});

  /// Half the ring's diameter: 10 standing alone, 8 inside a small control.
  final double radius;

  /// Defaults to `secondaryLabel`.
  final Color? color;

  /// Determinate progress, 0–1.
  final double? progress;

  @override
  Widget build(BuildContext context) =>
      JamProgressRing(value: progress, size: radius * 2, color: color);
}

/// A determinate bar: [value] of [color] (default `secondaryLabel`) on a
/// `fill` track, [height] tall, with ends rounded to half its height.
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
              child: ColoredBox(color: color ?? colors.secondaryLabel),
            ),
          ],
        ),
      ),
    );
  }
}
