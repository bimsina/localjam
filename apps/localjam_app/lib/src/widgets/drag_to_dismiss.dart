/// Drag the player down to put it away.
///
/// The companion to the room's vertical page transition: the chevron and the
/// gesture do the same thing, so the way it leaves matches the way it
/// arrived. Only downward drags count — this dismisses, it never pulls up.
///
/// Implemented by translating the page and popping on release rather than by
/// driving the route's own animation, which `ModalRoute` does not expose.
library;

import 'package:flutter/widgets.dart';

import '../design/tokens.dart';

class DragToDismiss extends StatefulWidget {
  const DragToDismiss({
    super.key,
    required this.child,
    required this.onDismiss,
    this.enabled = true,
  });

  final Widget child;

  /// Called once the drag passes the threshold or is flung downward.
  final VoidCallback onDismiss;

  /// False when there is nothing to dismiss to.
  final bool enabled;

  @override
  State<DragToDismiss> createState() => _DragToDismissState();
}

class _DragToDismissState extends State<DragToDismiss>
    with SingleTickerProviderStateMixin {
  /// How far down the page has been dragged, in logical pixels.
  double _offset = 0;

  /// Where a spring-back started, so the controller can interpolate from it.
  double _settleFrom = 0;

  // Built eagerly in initState, not lazily: a `late final` initialiser would
  // construct the controller on first touch — including from dispose() when
  // the player was closed without ever being dragged, where createTicker's
  // ancestor lookup hits a deactivated element.
  late final AnimationController _settle;

  /// Past this fraction of the screen, release dismisses.
  static const double _distanceThreshold = 0.22;

  /// A downward fling dismisses regardless of distance (px/s).
  static const double _velocityThreshold = 700;

  @override
  void initState() {
    super.initState();
    _settle = AnimationController(vsync: this, duration: JamDuration.base)
      ..addListener(_onSettle);
  }

  void _onSettle() {
    setState(() {
      _offset = _settleFrom * (1 - Curves.easeOut.transform(_settle.value));
    });
  }

  /// Springs the page back from wherever the finger left it — or, under
  /// reduced motion, puts it straight back.
  void _springBack() {
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      _settle.stop();
      setState(() => _offset = 0);
      return;
    }
    _settleFrom = _offset;
    _settle
      ..reset()
      ..forward();
  }

  @override
  void dispose() {
    _settle
      ..removeListener(_onSettle)
      ..dispose();
    super.dispose();
  }

  void _onUpdate(DragUpdateDetails details) {
    if (_settle.isAnimating) _settle.stop();
    setState(() {
      // Clamped at zero: dragging up does nothing rather than lifting the
      // page off the top of the screen.
      _offset = (_offset + details.delta.dy).clamp(0.0, double.infinity);
    });
  }

  void _onEnd(DragEndDetails details) {
    final velocity = details.velocity.pixelsPerSecond.dy;
    final height = MediaQuery.sizeOf(context).height;
    final dismissed =
        velocity > _velocityThreshold || _offset > height * _distanceThreshold;
    if (dismissed) {
      widget.onDismiss();
      return;
    }
    _springBack();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    // Corners round as the page peels away, so it reads as a sheet being put
    // down rather than a screen sliding off. Only clip while dragging — a
    // zero-radius ClipRRect still costs a layer every frame.
    final height = MediaQuery.sizeOf(context).height;
    final progress = height == 0
        ? 0.0
        : (_offset / (height * _distanceThreshold)).clamp(0.0, 1.0);
    final page = _offset <= 0
        ? widget.child
        : ClipRRect(
            borderRadius: BorderRadius.vertical(
              top: Radius.circular(JamRadius.sheetFloating * progress),
            ),
            child: widget.child,
          );
    return GestureDetector(
      // Vertical only, so the scrubber's horizontal drag still wins the arena.
      onVerticalDragUpdate: _onUpdate,
      onVerticalDragEnd: _onEnd,
      onVerticalDragCancel: _springBack,
      child: Transform.translate(offset: Offset(0, _offset), child: page),
    );
  }
}
