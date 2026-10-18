/// A small capsule: a filter token or a selected choice.
///
/// The spec has no badges or pills for things that are just text ("Host" is
/// secondary text, not a pill), so this is only for genuinely selectable
/// tokens. Screens should prefer a `JamRow` value or plain text.
library;

import 'package:flutter/cupertino.dart';

import '../design/tokens.dart';
import '../design/typography.dart';
import 'pressable.dart';

/// Everything this chip says out loud.
abstract final class JamChipStrings {
  /// Prefixes the chip's label on its close glyph: "Remove Rock".
  static const String remove = 'Remove';
}

/// A chip's state.
enum JamChipState {
  /// Unselected / inert: `fillSecondary` ground, `label` text.
  idle,

  /// Chosen: `tintFill` ground, tint text.
  selected,
}

/// A 30-tall capsule (44 hit when tappable).
class JamChip extends StatelessWidget {
  const JamChip({
    super.key,
    required this.label,
    this.state = JamChipState.idle,
    this.icon,
    this.onTap,
    this.onClose,
    this.semanticLabel,
  });

  final String label;
  final JamChipState state;

  /// An optional 14 leading glyph.
  final IconData? icon;

  /// Makes the chip tappable.
  final VoidCallback? onTap;

  /// Adds a trailing xmark.
  final VoidCallback? onClose;

  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final (Color fill, Color foreground) = switch (state) {
      JamChipState.idle => (colors.fillSecondary, colors.label),
      JamChipState.selected => (colors.tintFill, colors.tint),
    };

    final chip = Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: JamSpace.md),
      decoration: ShapeDecoration(color: fill, shape: const StadiumBorder()),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: foreground),
            const SizedBox(width: JamSpace.xs),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.jamFootnote.copyWith(
                color: foreground,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          if (onClose != null) ...[
            const SizedBox(width: JamSpace.xs),
            Semantics(
              button: true,
              label: '${JamChipStrings.remove} $label',
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onClose,
                child: SizedBox(
                  width: 20,
                  height: 30,
                  child: Icon(
                    CupertinoIcons.xmark,
                    size: 12,
                    color: foreground,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );

    if (onTap == null) {
      return Semantics(
        label: semanticLabel ?? label,
        excludeSemantics: onClose == null,
        child: chip,
      );
    }

    return Semantics(
      button: true,
      selected: state == JamChipState.selected,
      label: semanticLabel ?? label,
      onTap: onTap,
      excludeSemantics: onClose == null,
      child: JamPressable(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: chip,
        ),
      ),
    );
  }
}
