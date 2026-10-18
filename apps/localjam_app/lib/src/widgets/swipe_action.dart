/// The iOS trailing swipe action (DESIGN_SPEC v3 §6.2, §6.3, §6.7): drag a
/// row left to uncover a red button, tap it — or keep swiping past the
/// middle — to run it. Past Jams' **Forget**, Start a Jam's and the queue's
/// **Remove** all use this one.
///
/// ```dart
/// JamSwipeAction(
///   key: ValueKey(record.sessionId),
///   label: 'Forget',
///   onAction: () => confirmAndDelete(record), // true: it went
///   onRemoved: () => setState(() => records.remove(record)),
///   child: JamRow(title: record.sessionName),
/// )
/// ```
///
/// The action decides; the row only leaves when it says so. A refused or
/// declined action (a "Cancel" in the alert, a removal the host said no to)
/// slides the row back.
library;

import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/semantics.dart';

import '../design/tokens.dart';
import '../design/typography.dart';
import 'list.dart';
import 'pressable.dart';

/// A row with one destructive trailing swipe action.
///
/// Implements [JamSelfSeparatingRow]: wrap a row that draws its own hairline
/// (a `JamRow`, a `JamTrackRow`), and a `JamSection` leaves it alone.
class JamSwipeAction extends StatefulWidget implements JamSelfSeparatingRow {
  const JamSwipeAction({
    super.key,
    required this.child,
    required this.label,
    required this.onAction,
    this.onRemoved,
    this.semanticLabel,
    this.enabled = true,
  });

  final Widget child;

  /// The button's word, Title Case ("Forget", "Remove").
  final String label;

  /// The screen-reader action's name; defaults to [label].
  final String? semanticLabel;

  /// Runs the action: true when the row should go (it was removed, the
  /// user confirmed), false to slide it back.
  final Future<bool> Function() onAction;

  /// Called once the row has collapsed after [onAction] said true — drop
  /// it from the list here. Null for an action that never removes.
  final VoidCallback? onRemoved;

  /// False: just the row, no gesture.
  final bool enabled;

  @override
  State<JamSwipeAction> createState() => _JamSwipeActionState();
}

class _JamSwipeActionState extends State<JamSwipeAction>
    with TickerProviderStateMixin {
  /// The uncovered button's width.
  static const double _actionWidth = 88;

  /// Past this share of the row, letting go runs the action.
  static const double _fullSwipe = 0.6;

  late final AnimationController _offset = AnimationController(
    vsync: this,
    lowerBound: 0,
    upperBound: double.infinity,
    value: 0,
  )..addListener(_changed);

  /// 1 while the row is here; runs to 0 as it collapses after removal.
  late final AnimationController _size = AnimationController(
    vsync: this,
    value: 1,
  );

  double _width = 1;
  bool _busy = false;

  void _changed() => setState(() {});

  @override
  void dispose() {
    _offset.dispose();
    _size.dispose();
    super.dispose();
  }

  bool get _still => MediaQuery.disableAnimationsOf(context);

  Future<void> _animateTo(double target) => _offset.animateTo(
    target,
    duration: _still ? Duration.zero : JamDuration.base,
    curve: JamCurve.standard,
  );

  void _onDragUpdate(DragUpdateDetails details) {
    if (_busy) return;
    final before = _offset.value;
    final next = (before - details.primaryDelta!).clamp(0.0, _width);
    _offset.value = next;
    // The full-swipe point is felt as well as seen.
    final edge = _width * _fullSwipe;
    if ((before < edge) != (next < edge)) JamHaptics.selection();
  }

  void _onDragEnd(DragEndDetails details) {
    if (_busy) return;
    final velocity = details.primaryVelocity ?? 0;
    final value = _offset.value;
    if (value > _width * _fullSwipe || (velocity < -2500 && value > 0)) {
      unawaited(_run(full: true));
    } else if (value > _actionWidth / 2 || velocity < -400) {
      unawaited(_animateTo(_actionWidth));
    } else {
      unawaited(_animateTo(0));
    }
  }

  Future<void> _run({bool full = false}) async {
    if (_busy) return;
    _busy = true;
    if (full) await _animateTo(_width);
    final gone = await widget.onAction();
    if (!mounted) return;
    final removed = widget.onRemoved;
    if (gone && removed != null) {
      if (!full) await _animateTo(_width);
      if (!mounted) return;
      await _size.animateTo(
        0,
        duration: _still ? Duration.zero : JamDuration.fast,
        curve: JamCurve.standard,
      );
      if (!mounted) return;
      removed();
      return;
    }
    _busy = false;
    await _animateTo(0);
  }

  void _close() => unawaited(_animateTo(0));

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    final colors = context.jamColors;
    final open = _offset.value;
    final label = widget.semanticLabel ?? widget.label;

    final row = Semantics(
      customSemanticsActions: {
        CustomSemanticsAction(label: label): () => unawaited(_run()),
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          _width = constraints.maxWidth;
          return GestureDetector(
            behavior: HitTestBehavior.translucent,
            onHorizontalDragUpdate: _onDragUpdate,
            onHorizontalDragEnd: _onDragEnd,
            child: Stack(
              clipBehavior: Clip.hardEdge,
              children: [
                // The row moves; the button is exactly the gap it leaves,
                // so nothing shows through a translucent row.
                if (open > 0)
                  Positioned(
                    top: 0,
                    bottom: 0,
                    right: 0,
                    width: open,
                    child: ExcludeSemantics(
                      child: JamPressable(
                        style: JamPressStyle.none,
                        onTap: () => unawaited(_run()),
                        child: ClipRect(
                          child: ColoredBox(
                            color: colors.danger,
                            child: OverflowBox(
                              minWidth: _actionWidth,
                              maxWidth: _actionWidth,
                              // Uncovered from under the row, then carried
                              // along by its edge on a long swipe.
                              alignment: open <= _actionWidth
                                  ? Alignment.centerRight
                                  : Alignment.centerLeft,
                              child: Center(
                                child: Text(
                                  widget.label,
                                  maxLines: 1,
                                  textAlign: TextAlign.center,
                                  style: context.jamBody.copyWith(
                                    color: colors.onTint,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                Transform.translate(
                  offset: Offset(-open, 0),
                  child: open > 0
                      ? JamPressable(
                          style: JamPressStyle.none,
                          onTap: _close,
                          child: AbsorbPointer(child: widget.child),
                        )
                      : widget.child,
                ),
              ],
            ),
          );
        },
      ),
    );

    return SizeTransition(
      sizeFactor: _size,
      alignment: Alignment.topCenter,
      child: row,
    );
  }
}
