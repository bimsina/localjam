/// Two-state and choice controls on every platform: the switch (the brand
/// fill, `tintFilled`, when on) and the sliding segmented control.
library;

import 'package:flutter/cupertino.dart';

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

/// The sliding segmented control. [segments] maps each value to its label
/// (Title Case). A selection haptic on change.
///
/// 40 tall at the default text size (iOS's is 32): it also serves touch
/// tablets in landscape.
/// The thumb is white on light and a warm grey
/// ([JamFixedColors.segmentThumbDark]) on dark; on the Now Playing backdrop
/// ([onBackdrop]) it is the backdrop's white fill with a warm-ink label, on
/// a glass track with white labels — the selected footer circle's look.
class JamSegmentedControl<T extends Object> extends StatelessWidget {
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

  /// Stretches to the incoming width.
  final bool expand;

  /// Drawn on the Now Playing backdrop.
  final bool onBackdrop;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final style = context.jamSubheadline.copyWith(fontWeight: FontWeight.w500);
    final onChanged = onValueChanged;
    Color? labelColor(T value) => !onBackdrop
        ? null
        : value == groupValue
        ? JamNowPlayingColors.selectedGlyph
        : JamNowPlayingColors.text;
    final Widget control = CupertinoSlidingSegmentedControl<T>(
      groupValue: groupValue,
      backgroundColor: onBackdrop
          ? JamNowPlayingColors.glass
          : colors.fillSecondary,
      thumbColor: onBackdrop
          ? JamNowPlayingColors.fill
          : const CupertinoDynamicColor.withBrightness(
              color: JamFixedColors.white,
              darkColor: JamFixedColors.segmentThumbDark,
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
            padding: const EdgeInsets.symmetric(vertical: JamSpace.sm),
            child: Text(
              entry.value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style.copyWith(color: labelColor(entry.key)),
            ),
          ),
      },
    );
    return expand ? SizedBox(width: double.infinity, child: control) : control;
  }
}
