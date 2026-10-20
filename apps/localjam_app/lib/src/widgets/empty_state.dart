/// Nothing here yet — said once, plainly, with at most one way forward
/// (DESIGN_SPEC v3 §5 Empty state).
///
/// Centred: a [JamIconSize.hero] glyph in `secondaryLabel` — never the tint,
/// which is for what can be tapped (D8) — or a ready-made [JamEmptyState.mark]
/// (a `JamMark` on the session-ended page), a Manrope title2 title, one
/// subheadline `secondaryLabel` sentence in balanced lines, and an optional
/// action that *hugs its label* (min width [kJamEmptyStateActionMinWidth])
/// with an optional plain secondary action under it — never a full-width
/// bar floating mid-page (spec §10.6). No illustrations.
///
/// Every empty, ended, error and denied state uses this one.
library;

import 'package:flutter/widgets.dart';

import '../design/tokens.dart';
import '../design/typography.dart';
import 'buttons.dart';

/// The narrowest an empty state's primary action gets (spec §10.6).
const double kJamEmptyStateActionMinWidth = 140;

/// The centred empty-state block, capped at 320 wide.
class JamEmptyState extends StatelessWidget {
  const JamEmptyState({
    super.key,
    this.icon,
    this.mark,
    required this.title,
    required this.body,
    this.actionLabel,
    this.onAction,
    this.actionVariant = JamButtonVariant.filled,
    this.actionLoading = false,
    this.secondaryActionLabel,
    this.onSecondaryAction,
    this.foregroundColor,
    this.secondaryColor,
  });

  /// A [JamIconSize.hero] CupertinoIcons glyph in `secondaryLabel`.
  final IconData? icon;

  /// A ready-made mark used instead of [icon] (a `JamMark`).
  final Widget? mark;

  /// Title Case ("No Jams Nearby").
  final String title;

  /// One sentence.
  final String body;

  /// The action. Both must be non-null for the button to appear.
  final String? actionLabel;
  final VoidCallback? onAction;

  /// [JamButtonVariant.filled] (default), [JamButtonVariant.gray],
  /// [JamButtonVariant.tinted] or [JamButtonVariant.plain]. Whatever the
  /// look, it hugs its label.
  final JamButtonVariant actionVariant;

  final bool actionLoading;

  /// A second, plain action under the first — only for terminal states
  /// ("Try Again" + "Back to Nearby").
  final String? secondaryActionLabel;
  final VoidCallback? onSecondaryAction;

  /// Overrides the title colour (e.g. white on the camera), and the label
  /// of an unfilled action.
  final Color? foregroundColor;

  /// Overrides the glyph and body colour.
  final Color? secondaryColor;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final label = actionLabel;
    final secondary = secondaryActionLabel;
    final grounded = actionVariant != JamButtonVariant.plain;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: JamSpace.page),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (mark != null)
                Center(child: mark!)
              else if (icon != null)
                Icon(
                  icon,
                  size: JamIconSize.hero,
                  color: secondaryColor ?? colors.secondaryLabel,
                ),
              if (mark != null || icon != null)
                const SizedBox(height: JamSpace.lg),
              Semantics(
                header: true,
                child: Text(
                  title,
                  textAlign: TextAlign.center,
                  style: context.jamTitle2.copyWith(color: foregroundColor),
                ),
              ),
              const SizedBox(height: JamSpace.sm),
              JamBalancedText(
                body,
                style: context.jamSubheadline.copyWith(
                  color: secondaryColor ?? colors.secondaryLabel,
                ),
              ),
              if (label != null && onAction != null) ...[
                SizedBox(height: grounded ? JamSpace.xl : JamSpace.md),
                // JamButton hugs its label; the floor keeps a short one
                // from looking like a chip.
                Center(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minWidth: grounded ? kJamEmptyStateActionMinWidth : 0,
                    ),
                    child: JamButton(
                      label: label,
                      variant: actionVariant,
                      onPressed: onAction,
                      loading: actionLoading,
                      // On a page that sets its own foreground (white on
                      // the camera), an unfilled action's label follows.
                      color: actionVariant == JamButtonVariant.filled
                          ? null
                          : foregroundColor,
                    ),
                  ),
                ),
              ],
              if (secondary != null && onSecondaryAction != null) ...[
                const SizedBox(height: JamSpace.xs),
                Center(
                  child: JamButton.plain(
                    label: secondary,
                    onPressed: onSecondaryAction,
                    color: foregroundColor,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
