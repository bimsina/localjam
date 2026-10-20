/// One line of text that scrolls when it does not fit (R1): the Now Playing
/// title, which must never wrap — a second line would move the transport
/// under a thumb — and must never hide the end of a song's name either.
///
/// When the text fits it is plain text. When it does not, it rests at its
/// start for [JamMarquee.pause], scrolls left at [JamMarquee.speed] until a
/// second copy, [JamMarquee.gap] behind it, has taken its place, and rests
/// again — so it always returns to where it began. It makes
/// [JamMarquee.passes] passes and then stays at rest: restrained motion, not
/// a ticker running for as long as the song does; a new text starts it
/// again. The cut edge fades rather than slicing a letter. Under reduced
/// motion it never moves: it ends in an ellipsis instead.
///
/// A screen reader always hears the whole text, once.
///
/// The scroll is paint-only: a widget rebuilt on every tick inside the
/// player's layout would lay the whole player out again sixty times a
/// second, so the moving line is a render object that listens to the cycle
/// and repaints itself, and the widget tree changes only when the line
/// starts or stops moving.
library;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../design/motion.dart';
import '../design/tokens.dart';

/// A single line that scrolls when it overflows.
class JamMarquee extends StatefulWidget {
  const JamMarquee(
    this.text, {
    super.key,
    required this.style,
    this.pause = const Duration(seconds: 2),
    this.speed = 30,
    this.gap = 48,
    this.passes = 2,
  });

  final String text;
  final TextStyle style;

  /// How long it rests at its start before each pass.
  final Duration pause;

  /// Scroll speed, in logical pixels per second.
  final double speed;

  /// The space between the text and the copy that follows it round.
  final double gap;

  /// How many times it goes round before it rests for good.
  final int passes;

  /// How far the cut edges fade.
  static const double fade = 16;

  @override
  State<JamMarquee> createState() => _JamMarqueeState();
}

class _JamMarqueeState extends State<JamMarquee>
    with SingleTickerProviderStateMixin {
  late final AnimationController _cycle = AnimationController(vsync: this)
    ..addListener(_onTick);

  /// How far one pass travels (text + gap) as the last layout asked; null
  /// for still text. A parent may lay this out more than once in a frame
  /// (the player's stage measures at two widths), so only the last one,
  /// after the frame, decides.
  double? _target;

  /// What the cycle is running for, and for which text.
  double? _running;
  String? _runningFor;

  /// Whether a post-frame check is already scheduled.
  bool _pending = false;

  /// Whether the line is away from its rest: the copy that follows it round
  /// is built only then.
  bool _moving = false;

  @override
  void dispose() {
    _cycle.dispose();
    super.dispose();
  }

  void _onTick() {
    final d = _running;
    final moving = d != null && _offset(d) > 0;
    if (moving != _moving) setState(() => _moving = moving);
  }

  /// Asks for [distance] (null: still) — settled after this frame: the
  /// decision is made during layout, where an animation must not start.
  void _configure(double? distance) {
    _target = distance;
    if (_pending) return;
    _pending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pending = false;
      if (!mounted) return;
      final d = _target;
      if (d == _running && widget.text == _runningFor) return;
      _running = d;
      _runningFor = widget.text;
      if (d == null) {
        _cycle
          ..stop()
          ..value = 0;
        return;
      }
      final scrollMs = (d / widget.speed * 1000).round();
      _cycle.duration = widget.pause + Duration(milliseconds: scrollMs);
      _cycle.repeat(count: widget.passes).whenCompleteOrCancel(() {
        // Back at the start, at rest.
        if (mounted && !_cycle.isAnimating) _cycle.value = 0;
      });
    });
  }

  /// How far along a pass the text is, from the cycle's value.
  double _offset(double distance) {
    final total = _cycle.duration?.inMicroseconds ?? 0;
    if (total <= 0) return 0;
    final elapsed = _cycle.value * total;
    final rest = widget.pause.inMicroseconds;
    if (elapsed <= rest) return 0;
    return ((elapsed - rest) / 1e6 * widget.speed).clamp(0.0, distance);
  }

  @override
  Widget build(BuildContext context) {
    final style = widget.style;
    final text = widget.text;
    final reduced = jamReducedMotion(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: TextSpan(text: text, style: style),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
          maxLines: 1,
        )..layout();
        final width = painter.width;
        final height = painter.height;
        painter.dispose();
        final max = constraints.maxWidth;
        final overflows = max.isFinite && width > max + 0.5;

        if (!overflows || reduced) {
          _configure(null);
          return Text(
            text,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
            style: style,
          );
        }

        final distance = width + widget.gap;
        _configure(distance);
        final line = Text(text, maxLines: 1, softWrap: false, style: style);
        return Semantics(
          label: text,
          child: ExcludeSemantics(
            child: SizedBox(
              width: max,
              height: height,
              child: _MarqueeViewport(
                repaint: _cycle,
                offset: () => _offset(distance),
                fade: JamMarquee.fade,
                child: _moving
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          line,
                          SizedBox(width: widget.gap),
                          line,
                        ],
                      )
                    : line,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The window the line moves in: lays its child out at its own width, and
/// paints it [offset] along — clipped, with the cut edges faded — each time
/// [repaint] ticks, without a rebuild or a layout.
class _MarqueeViewport extends SingleChildRenderObjectWidget {
  const _MarqueeViewport({
    required this.repaint,
    required this.offset,
    required this.fade,
    required super.child,
  });

  final Listenable repaint;
  final double Function() offset;
  final double fade;

  @override
  _RenderMarqueeViewport createRenderObject(BuildContext context) =>
      _RenderMarqueeViewport(
        repaint: repaint,
        offset: offset,
        fade: fade,
        textDirection: Directionality.of(context),
      );

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderMarqueeViewport renderObject,
  ) {
    renderObject
      ..repaint = repaint
      ..offset = offset
      ..fade = fade
      ..textDirection = Directionality.of(context);
  }
}

class _RenderMarqueeViewport extends RenderProxyBox {
  _RenderMarqueeViewport({
    required this._repaint,
    required this.offset,
    required this._fade,
    required this._textDirection,
  });

  Listenable get repaint => _repaint;
  Listenable _repaint;
  set repaint(Listenable value) {
    if (identical(value, _repaint)) return;
    if (attached) {
      _repaint.removeListener(markNeedsPaint);
      value.addListener(markNeedsPaint);
    }
    _repaint = value;
    markNeedsPaint();
  }

  /// Read at paint time: how far along the line is.
  double Function() offset;

  double get fade => _fade;
  double _fade;
  set fade(double value) {
    if (value == _fade) return;
    _fade = value;
    markNeedsPaint();
  }

  TextDirection get textDirection => _textDirection;
  TextDirection _textDirection;
  set textDirection(TextDirection value) {
    if (value == _textDirection) return;
    _textDirection = value;
    markNeedsPaint();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _repaint.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _repaint.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  bool get alwaysNeedsCompositing => child != null;

  @override
  void performLayout() {
    size = constraints.biggest;
    // The line at its own width, however much wider than the window.
    child?.layout(
      BoxConstraints(maxHeight: constraints.maxHeight),
      parentUsesSize: true,
    );
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      false;

  final LayerHandle<ShaderMaskLayer> _mask = LayerHandle<ShaderMaskLayer>();
  final LayerHandle<ClipRectLayer> _clip = LayerHandle<ClipRectLayer>();

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null) return;
    final dx = this.offset();
    final moving = dx > 0;
    final rtl = textDirection == TextDirection.rtl;
    final rect = offset & size;
    final f = size.width <= 0 ? 0.0 : (fade / size.width).clamp(0.0, 0.5);
    // At rest only the cut end fades; moving, both edges.
    final shader = LinearGradient(
      begin: rtl ? Alignment.centerRight : Alignment.centerLeft,
      end: rtl ? Alignment.centerLeft : Alignment.centerRight,
      colors: [
        moving ? JamFixedColors.clear : JamFixedColors.white,
        JamFixedColors.white,
        JamFixedColors.white,
        JamFixedColors.clear,
      ],
      stops: [0, moving ? f : 0, 1 - f, 1],
    ).createShader(Offset.zero & size);
    final start = rtl ? size.width - child.size.width + dx : -dx;
    _mask.layer = (_mask.layer ?? ShaderMaskLayer())
      ..shader = shader
      ..maskRect = rect
      ..blendMode = BlendMode.dstIn;
    context.pushLayer(_mask.layer!, (context, offset) {
      _clip.layer = context.pushClipRect(
        needsCompositing,
        offset,
        Offset.zero & size,
        (context, offset) =>
            context.paintChild(child, offset + Offset(start, 0)),
        oldLayer: _clip.layer,
      );
    }, offset);
  }

  @override
  void dispose() {
    _mask.layer = null;
    _clip.layer = null;
    super.dispose();
  }
}
