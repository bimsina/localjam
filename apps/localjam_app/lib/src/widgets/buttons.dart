/// The button family (DESIGN_SPEC v3 §5): capsules, no shadows, no ripples.
///
/// ```dart
/// JamButton.filled(label: 'Start a Jam', expand: true, onPressed: _start)
/// JamButton.tinted(label: 'Join', size: JamButtonSize.small, onPressed: _join)
/// JamButton.gray(label: 'Host Again', icon: CupertinoIcons.play_fill, onPressed: _replay)
/// JamButton.plain(label: 'See All', onPressed: _history)
/// JamButton.filled(label: 'End Jam', destructive: true, onPressed: _end)
/// ```
///
/// Pressed: 0.7 opacity. Disabled (null [JamButton.onPressed]): 0.35. Loading:
/// a spinner replaces the label and the button keeps its width.
library;

import 'dart:async';

import 'package:flutter/cupertino.dart';

import '../design/tokens.dart';
import '../design/typography.dart';
import 'pressable.dart';

export 'list.dart' show JamSwitchRow;
export 'switch.dart' show JamSwitch;

/// The four looks.
enum JamButtonVariant {
  /// Tint fill, white label. The one primary action.
  filled,

  /// `tintFill` ground, tint label ("Join").
  tinted,

  /// `fill` ground, tint label (Apple Music's Play / Shuffle).
  gray,

  /// No ground, tint label.
  plain,
}

/// The horizontal padding inside a plain, non-expanded [JamButton] of
/// [size]: the distance from its hit edge to its text. A row or header that
/// wants a plain button's *text* on a margin insets the button by this much
/// less.
double jamPlainButtonPadding(JamButtonSize size) =>
    size == JamButtonSize.large ? JamSpace.sm : JamSpace.xs;

/// The two sizes.
enum JamButtonSize {
  /// 50 tall, 17 semibold, 20 h-padding.
  large,

  /// 30 tall (44 hit), 15 semibold, 12 h-padding — in-row actions.
  small,
}

/// A LocalJam button.
class JamButton extends StatelessWidget {
  const JamButton({
    super.key,
    required this.label,
    this.onPressed,
    this.variant = JamButtonVariant.filled,
    this.size = JamButtonSize.large,
    this.icon,
    this.loading = false,
    this.expand = false,
    this.destructive = false,
    this.color,
    this.semanticLabel,
  });

  /// Tint fill, white label.
  const JamButton.filled({
    Key? key,
    required String label,
    VoidCallback? onPressed,
    JamButtonSize size = JamButtonSize.large,
    IconData? icon,
    bool loading = false,
    bool expand = false,
    bool destructive = false,
    String? semanticLabel,
  }) : this(
         key: key,
         label: label,
         onPressed: onPressed,
         variant: JamButtonVariant.filled,
         size: size,
         icon: icon,
         loading: loading,
         expand: expand,
         destructive: destructive,
         semanticLabel: semanticLabel,
       );

  /// `tintFill` ground, tint label.
  const JamButton.tinted({
    Key? key,
    required String label,
    VoidCallback? onPressed,
    JamButtonSize size = JamButtonSize.large,
    IconData? icon,
    bool loading = false,
    bool expand = false,
    bool destructive = false,
    String? semanticLabel,
  }) : this(
         key: key,
         label: label,
         onPressed: onPressed,
         variant: JamButtonVariant.tinted,
         size: size,
         icon: icon,
         loading: loading,
         expand: expand,
         destructive: destructive,
         semanticLabel: semanticLabel,
       );

  /// `fill` ground, tint label.
  const JamButton.gray({
    Key? key,
    required String label,
    VoidCallback? onPressed,
    JamButtonSize size = JamButtonSize.large,
    IconData? icon,
    bool loading = false,
    bool expand = false,
    bool destructive = false,
    String? semanticLabel,
  }) : this(
         key: key,
         label: label,
         onPressed: onPressed,
         variant: JamButtonVariant.gray,
         size: size,
         icon: icon,
         loading: loading,
         expand: expand,
         destructive: destructive,
         semanticLabel: semanticLabel,
       );

  /// Tint label, no ground. [color] overrides the label (e.g. white on the
  /// camera).
  const JamButton.plain({
    Key? key,
    required String label,
    VoidCallback? onPressed,
    JamButtonSize size = JamButtonSize.large,
    IconData? icon,
    bool loading = false,
    bool expand = false,
    bool destructive = false,
    Color? color,
    String? semanticLabel,
  }) : this(
         key: key,
         label: label,
         onPressed: onPressed,
         variant: JamButtonVariant.plain,
         size: size,
         icon: icon,
         loading: loading,
         expand: expand,
         destructive: destructive,
         color: color,
         semanticLabel: semanticLabel,
       );

  /// Title Case: "Start a Jam".
  final String label;

  /// Null disables the button.
  final VoidCallback? onPressed;

  final JamButtonVariant variant;
  final JamButtonSize size;

  /// An optional leading glyph (CupertinoIcons), 6 before the label.
  final IconData? icon;

  /// Swaps the label for a spinner without changing the button's width.
  final bool loading;

  /// Stretches to the incoming width.
  final bool expand;

  /// `danger` instead of tint (fill for [JamButtonVariant.filled], label for
  /// the rest).
  final bool destructive;

  /// Overrides the label colour of a plain/gray/tinted button.
  final Color? color;

  /// Overrides the accessibility label.
  final String? semanticLabel;

  /// The painted height.
  double get height => size == JamButtonSize.large
      ? JamMetrics.buttonHeight
      : JamMetrics.buttonHeightSmall;

  bool get _enabled => onPressed != null && !loading;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final accent = destructive ? colors.danger : colors.tint;
    final (Color? ground, Color fg) = switch (variant) {
      JamButtonVariant.filled => (
        destructive ? colors.danger : colors.tintFilled,
        colors.onTint,
      ),
      JamButtonVariant.tinted => (
        destructive ? colors.danger.withValues(alpha: 0.15) : colors.tintFill,
        color ?? accent,
      ),
      JamButtonVariant.gray => (colors.fill, color ?? accent),
      JamButtonVariant.plain => (null, color ?? accent),
    };

    final large = size == JamButtonSize.large;
    final base = large
        ? (variant == JamButtonVariant.plain
              ? context.jamBody
              : context.jamHeadline)
        : context.jamSubheadline.copyWith(fontWeight: FontWeight.w600);
    final textStyle = base.copyWith(color: fg);

    final content = Row(
      mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (icon != null) ...[
          Icon(icon, size: large ? 20 : 16, color: fg),
          const SizedBox(width: 6),
        ],
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: textStyle,
          ),
        ),
      ],
    );

    final body = loading
        ? Stack(
            alignment: Alignment.center,
            children: [
              Opacity(opacity: 0, child: content),
              CupertinoActivityIndicator(radius: large ? 10 : 8, color: fg),
            ],
          )
        : content;

    final padding = EdgeInsets.symmetric(
      horizontal: variant == JamButtonVariant.plain && !expand
          ? jamPlainButtonPadding(size)
          : (large ? JamSpace.xl : JamSpace.md),
    );

    Widget painted = Container(
      height: height,
      width: expand ? double.infinity : null,
      padding: padding,
      alignment: Alignment.center,
      decoration: ground == null
          ? null
          : ShapeDecoration(color: ground, shape: const StadiumBorder()),
      child: body,
    );

    // A small button keeps a 44 pt hit area without growing its paint.
    if (!large) {
      painted = Padding(
        padding: const EdgeInsets.symmetric(
          vertical: (JamMetrics.hitTarget - JamMetrics.buttonHeightSmall) / 2,
        ),
        child: painted,
      );
    } else if (variant == JamButtonVariant.plain) {
      painted = ConstrainedBox(
        constraints: const BoxConstraints(minWidth: JamMetrics.hitTarget),
        child: painted,
      );
    }

    return Semantics(
      container: true,
      button: true,
      enabled: _enabled,
      label: semanticLabel ?? label,
      onTap: _enabled ? onPressed : null,
      excludeSemantics: true,
      child: Opacity(
        opacity: onPressed == null ? 0.35 : 1,
        child: JamPressable(
          onTap: _enabled ? onPressed : null,
          pressedOpacity: 0.7,
          child: painted,
        ),
      ),
    );
  }
}

/// A text action for a nav bar or sheet header ("Cancel", "Done", "Start").
/// 17 regular in tint; [bold] for the confirming action.
class JamTextButton extends StatelessWidget {
  const JamTextButton({
    super.key,
    required this.label,
    this.onPressed,
    this.bold = false,
    this.destructive = false,
    this.color,
  });

  final String label;
  final VoidCallback? onPressed;

  /// Semibold — the confirming action ("Done", "Start").
  final bool bold;
  final bool destructive;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final enabled = onPressed != null;
    final fg = !enabled
        ? colors.tertiaryLabel
        : color ?? (destructive ? colors.danger : colors.tint);
    return Semantics(
      container: true,
      button: true,
      enabled: enabled,
      label: label,
      onTap: onPressed,
      excludeSemantics: true,
      child: JamPressable(
        onTap: onPressed,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minWidth: JamMetrics.hitTarget,
            minHeight: JamMetrics.hitTarget,
          ),
          child: Center(
            widthFactor: 1,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: JamSpace.xs),
              child: Text(
                label,
                maxLines: 1,
                style: (bold ? context.jamHeadline : context.jamBody).copyWith(
                  color: fg,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A bare icon action (nav bar items, row accessories): 44 hit, glyph 22 in
/// tint, dims on press. [semanticLabel] is required — the icon says nothing
/// to a screen reader.
class JamIconButton extends StatelessWidget {
  const JamIconButton({
    super.key,
    required this.icon,
    required this.semanticLabel,
    this.onPressed,
    this.color,
    this.size = JamMetrics.navIcon,
  });

  final IconData icon;
  final String semanticLabel;
  final VoidCallback? onPressed;
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final enabled = onPressed != null;
    return Semantics(
      container: true,
      button: true,
      enabled: enabled,
      label: semanticLabel,
      onTap: onPressed,
      excludeSemantics: true,
      child: JamPressable(
        onTap: onPressed,
        child: SizedBox(
          width: JamMetrics.hitTarget,
          height: JamMetrics.hitTarget,
          child: Icon(
            icon,
            size: size,
            color: enabled ? (color ?? colors.tint) : colors.tertiaryLabel,
          ),
        ),
      ),
    );
  }
}

/// Strings the in-place confirmations say.
abstract final class JamConfirmationStrings {
  static const String copied = 'Copied';
}

/// How long an in-place confirmation shows before the control goes back.
const Duration kJamInPlaceConfirmation = Duration(milliseconds: 1500);

/// Confirms an action *in place* (spec §10.5): the control that was used
/// changes for [duration] — "Copy Link" becomes "Copied" with a checkmark —
/// instead of a toast landing on top of it.
///
/// [builder] gets whether the confirmation is showing and a `confirm`
/// callback to run the action through: `confirm(action)` awaits [action]
/// (when it returns `false` nothing is confirmed) and then flips the state.
///
/// ```dart
/// JamInPlaceConfirmation(
///   builder: (context, confirmed, confirm) => JamRow(
///     title: confirmed ? 'Copied' : 'Copy Diagnostics',
///     icon: confirmed ? CupertinoIcons.checkmark : CupertinoIcons.doc_on_doc,
///     tinted: true,
///     onTap: () => confirm(_copy),
///   ),
/// )
/// ```
class JamInPlaceConfirmation extends StatefulWidget {
  const JamInPlaceConfirmation({
    super.key,
    required this.builder,
    this.duration = kJamInPlaceConfirmation,
  });

  final Widget Function(
    BuildContext context,
    bool confirmed,
    void Function(FutureOr<Object?> Function() action) confirm,
  )
  builder;

  final Duration duration;

  @override
  State<JamInPlaceConfirmation> createState() => _JamInPlaceConfirmationState();
}

class _JamInPlaceConfirmationState extends State<JamInPlaceConfirmation> {
  bool _confirmed = false;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _confirm(FutureOr<Object?> Function() action) => unawaited(_run(action));

  Future<void> _run(FutureOr<Object?> Function() action) async {
    final result = await action();
    if (!mounted || result == false) return;
    _timer?.cancel();
    setState(() => _confirmed = true);
    _timer = Timer(widget.duration, () {
      if (mounted) setState(() => _confirmed = false);
    });
  }

  @override
  Widget build(BuildContext context) =>
      widget.builder(context, _confirmed, _confirm);
}

/// A [JamButton] that copies and then says so in its own label: "Copied"
/// with a checkmark for 1.5 s (spec §10.5). [onCopy] returning `false`
/// (nothing was copied) skips the confirmation.
class JamCopyButton extends StatelessWidget {
  const JamCopyButton({
    super.key,
    required this.label,
    required this.onCopy,
    this.copiedLabel = JamConfirmationStrings.copied,
    this.variant = JamButtonVariant.plain,
    this.size = JamButtonSize.large,
    this.icon,
    this.expand = false,
  });

  /// "Copy Link".
  final String label;

  /// "Copied".
  final String copiedLabel;

  final FutureOr<Object?> Function() onCopy;
  final JamButtonVariant variant;
  final JamButtonSize size;

  /// The glyph before [label]; the confirmation always shows a checkmark.
  final IconData? icon;

  final bool expand;

  @override
  Widget build(BuildContext context) => JamInPlaceConfirmation(
    builder: (context, copied, confirm) => Semantics(
      liveRegion: copied,
      child: JamButton(
        label: copied ? copiedLabel : label,
        icon: copied ? CupertinoIcons.checkmark_alt : icon,
        variant: variant,
        size: size,
        expand: expand,
        onPressed: () => confirm(onCopy),
      ),
    ),
  );
}
