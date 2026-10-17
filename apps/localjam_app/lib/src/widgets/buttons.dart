/// The one button. Three variants, one shape family, no engine underneath.
///
/// Every action in the app is a [JamButton]: a raspberry-gradient *primary*
/// (exactly one in view at a time), an outlined *secondary*, and a borderless
/// *tertiary* for the quiet third option. Stock `FilledButton`s still resolve
/// to the same tokens through `theme.dart`, but the gradient — the thing that
/// makes "Start a jam" look like the thing you want to touch — lives here.
///
/// Contrast note: `accent` on the cream `canvas` measures 4.41:1, just under
/// AA for body-sized text, and a 16 dp/700 label is not "large text" under
/// WCAG (that needs 18.66 dp bold). So a **tertiary label uses
/// [JamColors.accentPressed] on light** (6.09:1 on canvas) and `accent` on
/// dark, where `accent` already clears AA against the plum ground.
library;

import 'package:flutter/material.dart';

import '../design/tokens.dart';
import '../design/typography.dart';

/// Which of the three roles a [JamButton] is playing.
enum JamButtonVariant {
  /// The single raspberry-filled action on a screen.
  primary,

  /// Outlined; the alternative you might reasonably take instead.
  secondary,

  /// Borderless and pill-shaped; the quiet way out.
  tertiary,
}

/// A LocalJam action button.
///
/// ```dart
/// JamButton.primary(label: 'Start a jam', onPressed: _start)
/// JamButton.secondary(label: 'Scan code', icon: Icons.qr_code_scanner_rounded, onPressed: _scan)
/// JamButton.tertiary(label: 'Not now', onPressed: _dismiss)
/// ```
///
/// Disabled whenever [onPressed] is null or [loading] is true. While loading
/// the label is replaced by a spinner and the button keeps its width, so a
/// bottom bar does not resize mid-tap.
class JamButton extends StatefulWidget {
  const JamButton({
    super.key,
    required this.label,
    this.onPressed,
    this.variant = JamButtonVariant.primary,
    this.icon,
    this.loading = false,
    this.expand = false,
    this.destructive = false,
    this.semanticLabel,
  });

  /// The raspberry-filled action. One per screen.
  const JamButton.primary({
    Key? key,
    required String label,
    VoidCallback? onPressed,
    IconData? icon,
    bool loading = false,
    bool expand = false,
    bool destructive = false,
    String? semanticLabel,
  }) : this(
         key: key,
         label: label,
         onPressed: onPressed,
         variant: JamButtonVariant.primary,
         icon: icon,
         loading: loading,
         expand: expand,
         destructive: destructive,
         semanticLabel: semanticLabel,
       );

  /// The outlined alternative.
  const JamButton.secondary({
    Key? key,
    required String label,
    VoidCallback? onPressed,
    IconData? icon,
    bool loading = false,
    bool expand = false,
    String? semanticLabel,
  }) : this(
         key: key,
         label: label,
         onPressed: onPressed,
         variant: JamButtonVariant.secondary,
         icon: icon,
         loading: loading,
         expand: expand,
         semanticLabel: semanticLabel,
       );

  /// The borderless one. [destructive] turns the label `danger` — the way
  /// "Leave jam" and "End jam" read at the bottom of the People sheet.
  const JamButton.tertiary({
    Key? key,
    required String label,
    VoidCallback? onPressed,
    IconData? icon,
    bool loading = false,
    bool expand = false,
    bool destructive = false,
    String? semanticLabel,
  }) : this(
         key: key,
         label: label,
         onPressed: onPressed,
         variant: JamButtonVariant.tertiary,
         icon: icon,
         loading: loading,
         expand: expand,
         destructive: destructive,
         semanticLabel: semanticLabel,
       );

  /// The label. Sentence case — this app does not shout at people.
  final String label;

  /// Null disables the button.
  final VoidCallback? onPressed;

  final JamButtonVariant variant;

  /// An optional 20 dp leading glyph, 8 dp before the label.
  final IconData? icon;

  /// Swaps the label for a spinner without changing the button's width.
  final bool loading;

  /// Stretches to the incoming width — for a bottom action bar.
  final bool expand;

  /// A destructive action. A primary takes a `danger` fill instead of the
  /// raspberry gradient; a tertiary takes a `danger` label. Ignored by
  /// secondary, which has no room for a colour that loud.
  final bool destructive;

  /// Overrides the accessibility label when [label] alone is not enough.
  final String? semanticLabel;

  /// Height per variant: 52 for primary and secondary, 44 for tertiary.
  double get height => variant == JamButtonVariant.tertiary ? 44 : 52;

  bool get _enabled => onPressed != null && !loading;

  @override
  State<JamButton> createState() => _JamButtonState();
}

class _JamButtonState extends State<JamButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final light = Theme.of(context).brightness == Brightness.light;
    final enabled = widget._enabled;
    final pressed = _pressed && enabled;
    final radius = BorderRadius.circular(
      widget.variant == JamButtonVariant.tertiary
          ? JamRadius.pill
          : JamRadius.md,
    );

    final (
      Color? fill,
      Gradient? gradient,
      Color label,
      BoxBorder? border,
    ) = switch (widget.variant) {
      JamButtonVariant.primary when !enabled => (
        colors.surfaceMuted,
        null,
        colors.textTertiary,
        null,
      ),
      JamButtonVariant.primary when widget.destructive => (
        pressed ? colors.danger.withValues(alpha: 0.86) : colors.danger,
        null,
        Colors.white,
        null,
      ),
      JamButtonVariant.primary when pressed => (
        colors.accentPressed,
        null,
        colors.onAccent,
        null,
      ),
      // The gradient is the brand mark; on dark the flat accent already
      // carries enough light against plum, and a gradient there muddies.
      JamButtonVariant.primary => (
        light ? null : colors.accent,
        light ? _primaryGradient(colors) : null,
        colors.onAccent,
        null,
      ),
      JamButtonVariant.secondary => (
        pressed ? colors.surfaceMuted : Colors.transparent,
        null,
        enabled ? colors.textPrimary : colors.textTertiary,
        Border.all(color: colors.separator),
      ),
      JamButtonVariant.tertiary when widget.destructive => (
        pressed ? colors.danger.withValues(alpha: 0.10) : Colors.transparent,
        null,
        enabled ? colors.danger : colors.textTertiary,
        null,
      ),
      JamButtonVariant.tertiary => (
        pressed ? colors.accentSoft : Colors.transparent,
        null,
        enabled
            ? (light ? colors.accentPressed : colors.accent)
            : colors.textTertiary,
        null,
      ),
    };

    final content = Row(
      mainAxisSize: widget.expand ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (widget.icon != null) ...[
          Icon(widget.icon, size: 20, color: label),
          const SizedBox(width: JamSpace.sm),
        ],
        Flexible(
          child: Text(
            widget.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.labelLarge!.copyWith(color: label),
          ),
        ),
      ],
    );

    final body = widget.loading
        // The label stays in the tree at zero opacity so the button keeps
        // exactly the width it had before the tap.
        ? Stack(
            alignment: Alignment.center,
            children: [
              Opacity(opacity: 0, child: content),
              SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: widget.variant == JamButtonVariant.primary
                      ? colors.onAccent
                      : colors.accent,
                ),
              ),
            ],
          )
        : content;

    final surface = DecoratedBox(
      decoration: BoxDecoration(
        color: fill,
        gradient: gradient,
        border: border,
        borderRadius: radius,
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: radius,
          onTap: enabled ? widget.onPressed : null,
          onHighlightChanged: (v) {
            if (v != _pressed) setState(() => _pressed = v);
          },
          child: SizedBox(
            height: widget.height,
            width: widget.expand ? double.infinity : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: JamSpace.xl),
              child: Center(widthFactor: widget.expand ? null : 1, child: body),
            ),
          ),
        ),
      ),
    );

    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.semanticLabel ?? widget.label,
      onTap: enabled ? widget.onPressed : null,
      excludeSemantics: true,
      child: AnimatedScale(
        scale: pressed && !_reducedMotion(context) ? 0.97 : 1,
        duration: _reducedMotion(context) ? Duration.zero : JamDuration.instant,
        curve: JamCurve.instant,
        child: surface,
      ),
    );
  }
}

/// The 135° brand gradient: raspberry into [JamColors.accentDeep].
LinearGradient _primaryGradient(JamColors colors) => LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: [JamColors.brandRaspberry, colors.accentDeep],
);

bool _reducedMotion(BuildContext context) =>
    MediaQuery.maybeDisableAnimationsOf(context) ?? false;

/// A switch row that states a rule instead of shouting one.
///
/// Material's stock switch fills its track with the accent when on. Three of
/// those stacked in the People sheet out-shouted the sheet's only primary
/// action — the review's words were "two raspberry switches shout louder than
/// the primary". Here the accent lands on the *thumb*, the track carries the
/// soft tint, and an off switch is `surfaceMuted` with a hairline outline. The
/// row is still unmistakably a toggle; it just stops competing.
class JamSwitchRow extends StatelessWidget {
  const JamSwitchRow({
    super.key,
    required this.label,
    this.detail,
    required this.value,
    required this.onChanged,
    this.padding = const EdgeInsets.symmetric(
      horizontal: JamSpace.page,
      vertical: JamSpace.md,
    ),
  });

  final String label;

  /// A second line under the label. Omitted when null.
  final String? detail;

  final bool value;
  final ValueChanged<bool>? onChanged;

  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final enabled = onChanged != null;
    final detail = this.detail;

    return Semantics(
      toggled: value,
      enabled: enabled,
      label: detail == null ? label : '$label. $detail',
      excludeSemantics: true,
      child: InkWell(
        onTap: enabled ? () => onChanged!(!value) : null,
        child: Padding(
          padding: padding,
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      label,
                      style: context.jamBody.copyWith(
                        color: enabled
                            ? colors.textPrimary
                            : colors.textTertiary,
                      ),
                    ),
                    if (detail != null) ...[
                      const SizedBox(height: JamSpace.xxs),
                      Text(
                        detail,
                        style: context.jamFootnote.copyWith(
                          color: colors.textSecondary,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: JamSpace.md),
              ExcludeSemantics(
                child: JamSwitch(value: value, onChanged: onChanged),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The bare toggle from [JamSwitchRow], for callers that lay out their own row.
class JamSwitch extends StatelessWidget {
  const JamSwitch({super.key, required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    return Switch(
      value: value,
      onChanged: onChanged,
      // Accent on the thumb only; the track stays a tint, never a fill.
      thumbColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) return colors.textTertiary;
        return states.contains(WidgetState.selected)
            ? colors.accent
            : colors.textTertiary;
      }),
      trackColor: WidgetStateProperty.resolveWith((states) {
        return states.contains(WidgetState.selected)
            ? colors.accentSoft
            : colors.surfaceMuted;
      }),
      trackOutlineColor: WidgetStateProperty.resolveWith((states) {
        return states.contains(WidgetState.selected)
            ? colors.accent.withValues(alpha: 0.45)
            : colors.separator;
      }),
      trackOutlineWidth: const WidgetStatePropertyAll<double>(1),
      thumbIcon: const WidgetStatePropertyAll<Icon?>(null),
    );
  }
}
