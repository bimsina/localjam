/// iOS controls on every platform: the switch (green when on — never
/// raspberry) and the sliding segmented control.
library;

import 'package:flutter/cupertino.dart';

import '../design/tokens.dart';
import '../design/typography.dart';

/// The iOS switch, `success` track when on. A selection haptic on change.
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
      activeTrackColor: colors.success,
      inactiveTrackColor: colors.fill,
      thumbColor: const Color(0xFFFFFFFF),
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

/// iOS's sliding segmented control. [segments] maps each value to its label
/// (Title Case). A selection haptic on change.
class JamSegmentedControl<T extends Object> extends StatelessWidget {
  const JamSegmentedControl({
    super.key,
    required this.segments,
    required this.groupValue,
    required this.onValueChanged,
    this.expand = true,
  });

  /// Value → label, in display order.
  final Map<T, String> segments;

  final T? groupValue;

  /// Null disables the control.
  final ValueChanged<T>? onValueChanged;

  /// Stretches to the incoming width.
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final style = context.jamSubheadline.copyWith(fontWeight: FontWeight.w500);
    final onChanged = onValueChanged;
    final control = CupertinoSlidingSegmentedControl<T>(
      groupValue: groupValue,
      backgroundColor: colors.fillSecondary,
      thumbColor: CupertinoDynamicColor.withBrightness(
        color: const Color(0xFFFFFFFF),
        darkColor: const Color(0xFF636366),
      ),
      padding: const EdgeInsets.all(2),
      onValueChanged: (v) {
        if (v == null || onChanged == null) return;
        JamHaptics.selection();
        onChanged(v);
      },
      children: {
        for (final entry in segments.entries)
          entry.key: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(
              entry.value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          ),
      },
    );
    return expand ? SizedBox(width: double.infinity, child: control) : control;
  }
}
