/// Two-state and choice controls on every platform: the switch (the brand
/// fill, `tintFilled`, when on), the segmented control and the selection
/// check.
library;

import 'package:flutter/cupertino.dart';

import '../design/motion.dart';
import '../design/tokens.dart';
import '../design/typography.dart';

/// The switch: `tintFilled` track when on, `fill` when off, a white knob. A
/// selection haptic on change.
class JamSwitch extends StatelessWidget {
  const JamSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.semanticLabel,
  });

  final bool value;

  /// Null disables the switch.
  final ValueChanged<bool>? onChanged;

  /// Labels the switch when it is not inside a labelled row.
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final onChanged = this.onChanged;
    Widget control = CupertinoSwitch(
      value: value,
      activeTrackColor: colors.tintFilled,
      inactiveTrackColor: colors.fill,
      thumbColor: JamFixedColors.white,
      onChanged: onChanged == null
          ? null
          : (v) {
              JamHaptics.selection();
              onChanged(v);
            },
    );
    final label = semanticLabel;
    if (label != null) {
      control = Semantics(label: label, child: control);
    }
    return control;
  }
}

/// The segmented control: one choice among two to four, said in words.
/// [segments] maps each value to its label (sentence case). A selection
/// haptic on change.
///
/// LocalJam's own (CR-8), not the stock sliding control: a soft-rectangle
/// track ([JamRadius.md]) with the thumb inset [_kInset] on a concentric
/// corner, no shadow and no dividers. The thumb is the grouped row's paper
/// with a hairline edge on light, a quiet warm grey with the same edge on
/// dark ([JamFixedColors.segmentThumbDark]); the chosen label is `label`
/// semibold, the others `secondaryLabel` — the choice reads from the words,
/// not only from a soft shape (RB-22). On the Now Playing backdrop
/// ([onBackdrop]) the track is a quieter glass and the thumb the selected
/// footer plate's glass, the chosen label white semibold and the others the
/// backdrop's secondary white — never ivory, which is the play square's
/// alone.
///
/// 44 tall at the default text size — every segment is a full target — and
/// taller with the text. The thumb slides in [JamDuration.fast] (not under
/// reduced motion); a drag along the track moves the choice with it.
class JamSegmentedControl<T extends Object> extends StatefulWidget {
  const JamSegmentedControl({
    super.key,
    required this.segments,
    required this.groupValue,
    required this.onValueChanged,
    this.expand = true,
    this.onBackdrop = false,
  });

  /// Value → label, in display order.
  final Map<T, String> segments;

  final T? groupValue;

  /// Null disables the control.
  final ValueChanged<T>? onValueChanged;

  /// Stretches to the incoming width. Otherwise every segment is as wide as
  /// the widest label needs.
  final bool expand;

  /// Drawn on the Now Playing backdrop.
  final bool onBackdrop;

  @override
  State<JamSegmentedControl<T>> createState() => _JamSegmentedControlState<T>();
}

/// The gap between the track's edge and the thumb.
const double _kInset = 3;

/// The control's height at the default text size.
const double _kSegmentHeight = JamMetrics.hitTarget;

/// A segment's label inset, each side, when the control hugs its labels.
const double _kSegmentPadding = JamSpace.lg;

class _JamSegmentedControlState<T extends Object>
    extends State<JamSegmentedControl<T>> {
  /// The segment a drag is over, shown before it is committed.
  int? _dragging;

  List<T> get _values => widget.segments.keys.toList();

  int? get _selected {
    final i = _values.indexOf(widget.groupValue as T);
    return i < 0 ? null : i;
  }

  void _choose(int index) {
    final onChanged = widget.onValueChanged;
    if (onChanged == null) return;
    final value = _values[index];
    if (value == widget.groupValue) return;
    JamHaptics.selection();
    onChanged(value);
  }

  int _indexAt(double dx, double width) {
    final n = widget.segments.length;
    final segment = (width - _kInset * 2) / n;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final x = rtl ? width - dx : dx;
    return ((x - _kInset) / segment).floor().clamp(0, n - 1);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final enabled = widget.onValueChanged != null;
    final onBackdrop = widget.onBackdrop;
    final reduceMotion = jamReducedMotion(context);
    final dark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    final hairline = BorderSide(
      color: onBackdrop ? JamNowPlayingColors.clear : colors.separator,
      width: 1 / MediaQuery.devicePixelRatioOf(context),
    );
    final track = onBackdrop
        ? JamNowPlayingColors.segmentTrack
        : colors.fillSecondary;
    final thumb = onBackdrop
        ? JamNowPlayingColors.glass
        : dark
        ? JamFixedColors.segmentThumbDark
        : colors.groupedSurface;
    final base = context.jamSubheadline;
    final selected = _dragging ?? _selected;
    final n = widget.segments.length;

    Color labelColor(bool chosen) {
      if (!enabled) {
        return onBackdrop ? JamNowPlayingColors.tertiary : colors.tertiaryLabel;
      }
      if (onBackdrop) {
        return chosen
            ? JamNowPlayingColors.text
            : JamNowPlayingColors.secondary;
      }
      return chosen ? colors.label : colors.secondaryLabel;
    }

    final labels = widget.segments.values.toList();
    final line = (base.fontSize ?? 15) * (base.height ?? 1.33);
    final vertical = (_kSegmentHeight - _kInset * 2 - line) / 2;

    Widget segment(int index) {
      final chosen = index == selected;
      return _Segment(
        label: labels[index],
        selected: index == _selected,
        onTap: enabled ? () => _choose(index) : null,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: JamSpace.sm,
            vertical: vertical,
          ),
          child: Center(
            child: AnimatedDefaultTextStyle(
              duration: reduceMotion ? Duration.zero : JamDuration.fast,
              curve: JamCurve.standard,
              style: base.copyWith(
                color: labelColor(chosen),
                fontWeight: chosen ? FontWeight.w600 : FontWeight.w500,
              ),
              child: Text(
                labels[index],
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
      );
    }

    final row = Row(
      children: [for (var i = 0; i < n; i++) Expanded(child: segment(i))],
    );

    Widget control = LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final segmentWidth = (width - _kInset * 2) / n;
        final at = selected;
        final rtl = Directionality.of(context) == TextDirection.rtl;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: enabled
              ? (d) => setState(
                  () => _dragging = _indexAt(d.localPosition.dx, width),
                )
              : null,
          onHorizontalDragUpdate: enabled
              ? (d) {
                  final i = _indexAt(d.localPosition.dx, width);
                  if (i != _dragging) setState(() => _dragging = i);
                }
              : null,
          onHorizontalDragEnd: enabled
              ? (_) {
                  final i = _dragging;
                  setState(() => _dragging = null);
                  if (i != null) _choose(i);
                }
              : null,
          onHorizontalDragCancel: enabled
              ? () => setState(() => _dragging = null)
              : null,
          child: DecoratedBox(
            decoration: ShapeDecoration(
              color: track,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(JamRadius.md),
              ),
            ),
            child: Stack(
              children: [
                if (at != null)
                  AnimatedPositioned(
                    duration: reduceMotion ? Duration.zero : JamDuration.fast,
                    curve: JamCurve.standard,
                    top: _kInset,
                    bottom: _kInset,
                    left: _kInset + (rtl ? n - 1 - at : at) * segmentWidth,
                    width: segmentWidth,
                    child: DecoratedBox(
                      decoration: ShapeDecoration(
                        color: thumb,
                        shape: RoundedRectangleBorder(
                          side: hairline,
                          borderRadius: BorderRadius.circular(
                            JamRadius.md - _kInset,
                          ),
                        ),
                      ),
                    ),
                  ),
                Padding(padding: const EdgeInsets.all(_kInset), child: row),
              ],
            ),
          ),
        );
      },
    );

    if (!widget.expand) {
      // Hugging: every segment as wide as the widest label needs.
      final scaler = MediaQuery.textScalerOf(context);
      var widest = 0.0;
      for (final label in labels) {
        final painter = TextPainter(
          text: TextSpan(
            text: label,
            style: base.copyWith(fontWeight: FontWeight.w600),
          ),
          textDirection: Directionality.of(context),
          textScaler: scaler,
          maxLines: 1,
        )..layout();
        if (painter.width > widest) widest = painter.width;
        painter.dispose();
      }
      control = SizedBox(
        width: (widest + _kSegmentPadding * 2) * n + _kInset * 2,
        child: control,
      );
    } else {
      control = SizedBox(width: double.infinity, child: control);
    }
    return Semantics(container: true, explicitChildNodes: true, child: control);
  }
}

/// One choice: a button in a mutually exclusive group, reachable by the
/// keyboard (Enter or Space chooses it).
class _Segment extends StatelessWidget {
  const _Segment({
    required this.label,
    required this.selected,
    required this.onTap,
    required this.child,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final onTap = this.onTap;
    // One node: the button, its state, its label and its focus together.
    return MergeSemantics(
      child: Semantics(
        button: true,
        selected: selected,
        inMutuallyExclusiveGroup: true,
        onTap: onTap,
        child: FocusableActionDetector(
          enabled: onTap != null,
          actions: <Type, Action<Intent>>{
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) {
                onTap?.call();
                return null;
              },
            ),
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTap,
            child: child,
          ),
        ),
      ),
    );
  }
}

/// The selection check's diameter.
const double kJamSelectionCheckSize = 22;

/// "Picked": a [kJamSelectionCheckSize] circle in the brand fill
/// (`tintFilled`) with LocalJam's own check drawn in `onTint` — the same
/// raspberry and the same mark in both themes, as a switch that is on
/// (CR-5). Not picked: an empty 1.5 pt `tertiaryLabel` ring.
///
/// For a list you pick several things from (the library). Decorative
/// unless given a [semanticLabel], which is announced while [selected].
///
/// ```dart
/// JamSelectionCheck(selected: picked.contains(track), semanticLabel: 'Selected')
/// ```
class JamSelectionCheck extends StatelessWidget {
  const JamSelectionCheck({
    super.key,
    required this.selected,
    this.size = kJamSelectionCheckSize,
    this.semanticLabel,
  });

  final bool selected;

  /// The circle's diameter.
  final double size;

  /// Said while [selected] ("Selected"); nothing is said otherwise.
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final reduceMotion = jamReducedMotion(context);
    final label = selected ? semanticLabel : null;
    final check = ExcludeSemantics(
      child: SizedBox.square(
        dimension: size,
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(end: selected ? 1 : 0),
          duration: reduceMotion ? Duration.zero : JamDuration.fast,
          curve: JamCurve.standard,
          builder: (context, t, _) => CustomPaint(
            painter: _CheckPainter(
              t: t,
              ring: colors.tertiaryLabel,
              fill: colors.tintFilled,
              mark: colors.onTint,
            ),
          ),
        ),
      ),
    );
    return label == null ? check : Semantics(label: label, child: check);
  }
}

class _CheckPainter extends CustomPainter {
  const _CheckPainter({
    required this.t,
    required this.ring,
    required this.fill,
    required this.mark,
  });

  /// 0: not picked, 1: picked.
  final double t;
  final Color ring;
  final Color fill;
  final Color mark;

  static const double _ringWidth = 1.5;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = size.center(Offset.zero);
    final radius = size.shortestSide / 2;
    if (t < 1) {
      canvas.drawCircle(
        centre,
        radius - _ringWidth / 2,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = _ringWidth
          ..color = ring.withValues(alpha: ring.a * (1 - t)),
      );
    }
    if (t <= 0) return;
    canvas.drawCircle(
      centre,
      radius,
      Paint()..color = fill.withValues(alpha: fill.a * t),
    );
    // The check: a short stroke down to the low point, a long one up and
    // out — 13 across on a 22 circle, drawn on as it fills.
    final unit = size.shortestSide / kJamSelectionCheckSize;
    final a = centre + Offset(-5.5, 0.5) * unit;
    final b = centre + Offset(-1.75, 4.25) * unit;
    final c = centre + Offset(6, -4) * unit;
    final first = (b - a).distance;
    final second = (c - b).distance;
    final drawn = (first + second) * t;
    final path = Path()..moveTo(a.dx, a.dy);
    if (drawn <= first) {
      final p = Offset.lerp(a, b, drawn / first)!;
      path.lineTo(p.dx, p.dy);
    } else {
      final p = Offset.lerp(b, c, (drawn - first) / second)!;
      path
        ..lineTo(b.dx, b.dy)
        ..lineTo(p.dx, p.dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2 * unit
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = mark,
    );
  }

  @override
  bool shouldRepaint(_CheckPainter old) =>
      old.t != t || old.ring != ring || old.fill != fill || old.mark != mark;
}
