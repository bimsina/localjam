/// The iOS press: no ink. Rows fill with `fillPressed`; buttons and icons dim.
///
/// Every tappable surface in the shared components goes through
/// [JamPressable], so a press reads the same everywhere and nothing ripples.
library;

import 'package:flutter/widgets.dart';

import '../design/tokens.dart';

/// How a [JamPressable] shows that it is held down.
enum JamPressStyle {
  /// Dims the child to [JamPressable.pressedOpacity] (buttons, icons).
  opacity,

  /// Paints [JamPressable.highlightColor] (default `fillPressed`) behind the
  /// child (rows).
  highlight,

  /// Shows nothing (the caller draws its own pressed state).
  none,
}

/// A tap target with an iOS press state and a 44 pt minimum.
class JamPressable extends StatefulWidget {
  const JamPressable({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.style = JamPressStyle.opacity,
    this.pressedOpacity = 0.6,
    this.highlightColor,
    this.borderRadius,
    this.onPressedChanged,
    this.behavior = HitTestBehavior.opaque,
  });

  final Widget child;

  /// Null (with [onLongPress] null) disables the press state.
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  final JamPressStyle style;

  /// The child's opacity while pressed, for [JamPressStyle.opacity].
  final double pressedOpacity;

  /// The highlight colour for [JamPressStyle.highlight]. Defaults to
  /// [JamColors.fillPressed].
  final Color? highlightColor;

  /// Clips the highlight.
  final BorderRadius? borderRadius;

  /// Reports press-state changes, for callers that restyle themselves.
  final ValueChanged<bool>? onPressedChanged;

  final HitTestBehavior behavior;

  @override
  State<JamPressable> createState() => _JamPressableState();
}

class _JamPressableState extends State<JamPressable> {
  bool _pressed = false;

  bool get _enabled => widget.onTap != null || widget.onLongPress != null;

  void _set(bool value) {
    if (_pressed == value) return;
    setState(() => _pressed = value);
    widget.onPressedChanged?.call(value);
  }

  @override
  void didUpdateWidget(JamPressable oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_enabled && _pressed) _pressed = false;
  }

  @override
  Widget build(BuildContext context) {
    final pressed = _pressed && _enabled;
    Widget child = widget.child;
    switch (widget.style) {
      case JamPressStyle.opacity:
        child = AnimatedOpacity(
          opacity: pressed ? widget.pressedOpacity : 1,
          duration: pressed ? Duration.zero : JamDuration.fast,
          curve: JamCurve.standard,
          child: child,
        );
      case JamPressStyle.highlight:
        final color = widget.highlightColor ?? context.jamColors.fillPressed;
        child = DecoratedBox(
          decoration: BoxDecoration(
            color: pressed ? color : JamFixedColors.clear,
            borderRadius: widget.borderRadius,
          ),
          child: child,
        );
      case JamPressStyle.none:
        break;
    }
    return GestureDetector(
      behavior: widget.behavior,
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      onTapDown: _enabled ? (_) => _set(true) : null,
      onTapUp: _enabled ? (_) => _set(false) : null,
      onTapCancel: _enabled ? () => _set(false) : null,
      onLongPressEnd: widget.onLongPress == null ? null : (_) => _set(false),
      child: child,
    );
  }
}
