/// Nothing here yet — said once, kindly, with one way forward.
///
/// Every empty screen in the app uses this: a mark, a title, a sentence, and
/// **one** action. Two competing buttons in an empty state is a screen that
/// does not know what it wants you to do.
library;

import 'package:flutter/material.dart';

import '../design/tokens.dart';
import '../design/typography.dart';
import 'buttons.dart';

/// The centred empty-state block, capped at 320 dp wide.
class JamEmptyState extends StatelessWidget {
  const JamEmptyState({
    super.key,
    this.icon,
    this.mark,
    this.gradientMark = false,
    required this.title,
    required this.body,
    this.actionLabel,
    this.onAction,
    this.actionVariant = JamButtonVariant.primary,
    this.actionLoading = false,
  });

  /// A 56 dp glyph in `textTertiary`, or — with [gradientMark] — the glyph
  /// knocked white into the 72 dp apricot→raspberry placeholder square.
  final IconData? icon;

  /// A ready-made mark (the logo, an artwork mosaic) used instead of [icon].
  final Widget? mark;

  /// Music-shaped empties get the placeholder gradient rather than a grey
  /// glyph, so an empty queue still looks like it belongs to a player.
  final bool gradientMark;

  final String title;

  final String body;

  /// The single action. Both must be non-null for the button to appear.
  final String? actionLabel;
  final VoidCallback? onAction;

  /// Usually primary; secondary where the empty state sits under a screen
  /// that already owns the primary action.
  final JamButtonVariant actionVariant;

  final bool actionLoading;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final label = actionLabel;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: JamSpace.page),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (mark != null)
                mark!
              else if (icon != null && gradientMark)
                _GradientMark(icon: icon!, colors: colors)
              else if (icon != null)
                Icon(icon, size: 56, color: colors.textTertiary),
              if (mark != null || icon != null)
                const SizedBox(height: JamSpace.xl),
              Text(title, textAlign: TextAlign.center, style: context.jamTitle),
              const SizedBox(height: JamSpace.sm),
              Text(
                body,
                textAlign: TextAlign.center,
                style: context.jamByline.copyWith(color: colors.textSecondary),
              ),
              if (label != null && onAction != null) ...[
                const SizedBox(height: JamSpace.xxl),
                JamButton(
                  label: label,
                  variant: actionVariant,
                  onPressed: onAction,
                  loading: actionLoading,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The 72 dp placeholder square: the same apricot→raspberry gradient the
/// artwork placeholder uses, with the glyph knocked into it.
class _GradientMark extends StatelessWidget {
  const _GradientMark({required this.icon, required this.colors});

  final IconData icon;
  final JamColors colors;

  @override
  Widget build(BuildContext context) => Container(
    width: 72,
    height: 72,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(JamRadius.artwork(72)),
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          colors.highlight.withValues(alpha: 0.85),
          colors.accent.withValues(alpha: 0.85),
        ],
      ),
    ),
    child: Icon(icon, size: 30, color: Colors.white.withValues(alpha: 0.85)),
  );
}
