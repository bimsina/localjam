/// Nothing here yet — said once, plainly, with at most one way forward
/// (DESIGN_SPEC v3 §5 Empty state).
///
/// Centred: a 48 glyph in `tertiaryLabel`, a title2 title, one subheadline
/// `secondaryLabel` sentence, and an optional `.filled` or `.plain` action.
/// No illustrations.
library;

import 'package:flutter/widgets.dart';

import '../design/tokens.dart';
import '../design/typography.dart';
import 'buttons.dart';

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

  /// A 48 CupertinoIcons glyph in `tertiaryLabel`.
  final IconData? icon;

  /// A ready-made mark used instead of [icon].
  final Widget? mark;

  /// Title Case ("No Jams Nearby").
  final String title;

  /// One sentence.
  final String body;

  /// The action. Both must be non-null for the button to appear.
  final String? actionLabel;
  final VoidCallback? onAction;

  /// [JamButtonVariant.filled] (default) or [JamButtonVariant.plain].
  final JamButtonVariant actionVariant;

  final bool actionLoading;

  /// A second, plain action under the first — only for terminal states
  /// ("Try Again" + "Back to Nearby").
  final String? secondaryActionLabel;
  final VoidCallback? onSecondaryAction;

  /// Overrides the title colour (e.g. white on the camera).
  final Color? foregroundColor;

  /// Overrides the glyph and body colour.
  final Color? secondaryColor;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final label = actionLabel;
    final secondary = secondaryActionLabel;
    final filled = actionVariant == JamButtonVariant.filled;

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
                  size: 48,
                  color: secondaryColor ?? colors.tertiaryLabel,
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
              Text(
                body,
                textAlign: TextAlign.center,
                style: context.jamSubheadline.copyWith(
                  color: secondaryColor ?? colors.secondaryLabel,
                ),
              ),
              if (label != null && onAction != null) ...[
                SizedBox(height: filled ? JamSpace.xxl : JamSpace.md),
                Center(
                  child: JamButton(
                    label: label,
                    variant: actionVariant,
                    expand: filled,
                    onPressed: onAction,
                    loading: actionLoading,
                  ),
                ),
              ],
              if (secondary != null && onSecondaryAction != null) ...[
                const SizedBox(height: JamSpace.xs),
                Center(
                  child: JamButton.plain(
                    label: secondary,
                    onPressed: onSecondaryAction,
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
