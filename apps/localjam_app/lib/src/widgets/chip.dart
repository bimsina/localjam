/// A small labelled pill: a filter, a selected preset, a "LIVE" badge.
///
/// Three states, no third-party chip: Material's `Chip` family drags in
/// avatars, delete themes and a 48 dp density model that fights a 32 dp pill.
/// This is the whole component.
library;

import 'package:flutter/material.dart';

import '../design/tokens.dart';

/// Everything this chip says out loud.
abstract final class JamChipStrings {
  /// Prefixes the chip's own label on its close glyph: "Remove LIVE".
  static const String remove = 'Remove';
}

/// What a [JamChip] is saying.
enum JamChipState {
  /// Inert or unselected.
  idle,

  /// Chosen.
  selected,

  /// Something is happening right now — carries an apricot dot.
  live,
}

/// A 32 dp pill. Tappable chips are wrapped in a 44 dp-high hit area so the
/// target rule holds without inflating the painted chip.
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

  /// The chip text. Pass it already cased — this widget does not shout.
  final String label;

  final JamChipState state;

  /// An optional 14 dp leading glyph. Ignored on [JamChipState.live], whose
  /// leading slot belongs to the highlight dot.
  final IconData? icon;

  /// Makes the whole chip tappable.
  final VoidCallback? onTap;

  /// Adds a trailing 16 dp close glyph.
  final VoidCallback? onClose;

  /// Overrides the accessibility label.
  final String? semanticLabel;

  bool get _interactive => onTap != null;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final (Color fill, Color foreground) = switch (state) {
      JamChipState.idle => (colors.surfaceMuted, colors.textSecondary),
      JamChipState.selected => (colors.accentSoft, colors.accent),
      JamChipState.live => (colors.highlightSoft, colors.warning),
    };

    final chip = AnimatedContainer(
      duration: _reducedMotion(context) ? Duration.zero : JamDuration.fast,
      curve: JamCurve.fast,
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: JamSpace.md),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(JamRadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (state == JamChipState.live) ...[
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: colors.liveDot,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: JamSpace.sm),
          ] else if (icon != null) ...[
            Icon(icon, size: 14, color: foreground),
            const SizedBox(width: JamSpace.xs),
          ],
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.labelMedium!.copyWith(color: foreground),
          ),
          if (onClose != null) ...[
            const SizedBox(width: JamSpace.sm),
            // The close glyph takes the chip's full height as its target and
            // sits inside the 44 dp wrapper, so it is comfortably tappable
            // without the pill growing.
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onClose,
              child: Semantics(
                button: true,
                label: '${JamChipStrings.remove} $label',
                child: SizedBox(
                  width: 20,
                  height: 32,
                  child: Icon(Icons.close_rounded, size: 16, color: foreground),
                ),
              ),
            ),
          ],
        ],
      ),
    );

    if (!_interactive) {
      // No `selected`: a decorative chip is a label, and announcing a
      // selection state nobody can change is noise in a screen reader.
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
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        // 6 dp of transparent padding above and below: painted 32, tapped 44.
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: chip,
        ),
      ),
    );
  }
}

bool _reducedMotion(BuildContext context) =>
    MediaQuery.maybeDisableAnimationsOf(context) ?? false;
