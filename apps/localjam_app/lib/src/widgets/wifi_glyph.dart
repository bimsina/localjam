/// The Wi‑Fi glyph, drawn in outline.
///
/// CupertinoIcons' `wifi` and `wifi_slash` are solid wedges, while every
/// other glyph an empty state, a terminal page or a primer shows (the
/// antenna, the clock, the viewfinder, the camera) is a stroke. Beside
/// them a solid wedge reads as a different, heavier family, so the network
/// glyph is drawn here at the outline icons' weight instead.
library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../design/tokens.dart';

/// Three arcs and a dot — with a slash through them for "no network".
class JamWifiGlyph extends StatelessWidget {
  const JamWifiGlyph({
    super.key,
    this.slashed = false,
    this.size = JamIconSize.hero,
    this.color,
  });

  /// Struck through: not on a network.
  final bool slashed;

  /// The glyph's em box, as an `Icon`'s size.
  final double size;

  /// Null: `secondaryLabel`, as an empty state's glyph.
  final Color? color;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: CustomPaint(
      size: Size.square(size),
      painter: _WifiPainter(
        color: color ?? context.jamColors.secondaryLabel,
        slashed: slashed,
      ),
    ),
  );
}

class _WifiPainter extends CustomPainter {
  const _WifiPainter({required this.color, required this.slashed});

  final Color color;
  final bool slashed;

  /// The outline icons' stroke, as a share of the em box (3.5 at 48).
  static const double _stroke = 0.073;

  @override
  void paint(Canvas canvas, Size size) {
    // Drawn in an em box centred in whatever it is given.
    final s = size.shortestSide;
    canvas.translate((size.width - s) / 2, (size.height - s) / 2);
    final stroke = s * _stroke;
    final centre = Offset(s / 2, s * 0.79);
    // 100° either side of straight up, as SF's wifi opens.
    const sweep = 100 * math.pi / 180;
    const start = -math.pi / 2 - sweep / 2;
    final line = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;

    canvas.saveLayer(Offset.zero & Size.square(s), Paint());
    for (final r in [0.2, 0.385, 0.57]) {
      canvas.drawArc(
        Rect.fromCircle(center: centre, radius: s * r),
        start,
        sweep,
        false,
        line,
      );
    }
    canvas.drawCircle(centre, s * 0.066, Paint()..color = color);
    if (slashed) {
      final from = Offset(s * 0.16, s * 0.14);
      final to = Offset(s * 0.84, s * 0.88);
      // A real gap either side of the slash, knocked out of the arcs.
      canvas.drawLine(
        from,
        to,
        Paint()
          ..blendMode = BlendMode.clear
          ..strokeWidth = stroke * 2.4
          ..strokeCap = StrokeCap.round,
      );
      canvas.drawLine(from, to, line);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_WifiPainter old) =>
      old.color != color || old.slashed != slashed;
}
