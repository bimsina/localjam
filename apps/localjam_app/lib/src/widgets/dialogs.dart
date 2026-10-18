/// iOS alerts on every platform — iOS 26's (DESIGN_SPEC v3 §5 Alerts, as
/// amended by §10.3).
///
/// Centred, 300 wide, radius 34, blurred: title headline and message
/// subheadline, leading-aligned in balanced lines (no orphaned last word);
/// capsule buttons side by side for two, stacked otherwise — the preferred
/// action filled tint, a destructive one filled red, Cancel a grey capsule;
/// optionally one text field whose keyboard follows the app's appearance.
///
/// **The lifetime rule.** A `TextEditingController` disposed the moment the
/// dialog's future completes is still wired to a field the exit transition
/// keeps building — red screen. Every alert here that owns a field owns its
/// controller in a `State` and disposes it in `State.dispose`.
library;

import 'dart:ui' show ImageFilter;

import 'package:flutter/cupertino.dart';

import '../design/theme.dart';
import '../design/tokens.dart';
import '../design/typography.dart';
import 'buttons.dart';
import 'pressable.dart';

/// Default labels.
abstract final class JamDialogStrings {
  static const String cancel = 'Cancel';
  static const String confirm = 'OK';
  static const String save = 'Save';
}

/// One alert button.
@immutable
class JamAlertAction {
  const JamAlertAction({
    required this.label,
    this.onPressed,
    this.isDefault = false,
    this.destructive = false,
  });

  /// Title Case ("Leave Jam").
  final String label;

  /// Null disables the button.
  final VoidCallback? onPressed;

  /// The preferred action: a filled tint capsule.
  final bool isDefault;

  /// A filled red capsule.
  final bool destructive;
}

/// An iOS 26 alert (spec §10.3): a rounded (34) card of blurred `elevated`,
/// title and message leading-aligned in balanced lines, an optional field,
/// and capsule buttons — side by side for two when both labels fit, stacked
/// otherwise (the cancelling action last, as iOS stacks it).
///
/// Buttons are told apart by shape and fill, not by two near-identical
/// reds (rev-holistic): the preferred action is a filled tint capsule, a
/// destructive one a filled red capsule, and everything else — Cancel — a
/// grey `fill` capsule with `label` text.
class JamAlert extends StatelessWidget {
  const JamAlert({
    super.key,
    required this.title,
    this.message,
    this.content,
    required this.actions,
  });

  /// Title Case question or statement ("End Jam?").
  final String title;

  /// One or two sentences.
  final String? message;

  /// Extra content under the message — a [JamAlertTextField].
  final Widget? content;

  /// Cancel first, the action last (iOS order).
  final List<JamAlertAction> actions;

  static const double _padding = JamSpace.xl;
  static const double _gap = JamSpace.sm;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final message = this.message;
    final content = this.content;
    final media = MediaQuery.of(context);
    final width = (media.size.width - JamSpace.huge * 2).clamp(
      0.0,
      JamMetrics.alertWidth,
    );

    final text = <Widget>[
      Semantics(
        header: true,
        child: JamBalancedText(
          title,
          textAlign: TextAlign.start,
          style: context.jamHeadline.copyWith(color: colors.label),
        ),
      ),
      if (message != null) ...[
        const SizedBox(height: JamSpace.xs),
        JamBalancedText(
          message,
          textAlign: TextAlign.start,
          style: context.jamSubheadline.copyWith(color: colors.label),
        ),
      ],
    ];

    final card = ConstrainedBox(
      constraints: BoxConstraints.tightFor(width: width),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(JamRadius.alert),
        child: BackdropFilter(
          filter: ImageFilter.blur(
            sigmaX: JamBlur.material,
            sigmaY: JamBlur.material,
          ),
          child: ColoredBox(
            // Nearly opaque: an alert over the black camera page (or any
            // dark ground) must never turn into a muddy, half-legible grey.
            color: colors.elevated.withValues(alpha: 0.96),
            child: Padding(
              padding: const EdgeInsets.all(_padding),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Flexible(
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: text,
                      ),
                    ),
                  ),
                  if (content != null) ...[
                    const SizedBox(height: JamSpace.lg),
                    content,
                  ],
                  if (actions.isNotEmpty) ...[
                    const SizedBox(height: _padding),
                    _JamAlertButtons(actions: actions, gap: _gap),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );

    // Rises with the keyboard when the alert holds a field.
    return AnimatedPadding(
      padding:
          media.viewInsets + const EdgeInsets.symmetric(vertical: JamSpace.xxl),
      duration: JamDuration.fast,
      curve: JamCurve.standard,
      child: MediaQuery.removeViewInsets(
        context: context,
        removeLeft: true,
        removeTop: true,
        removeRight: true,
        removeBottom: true,
        child: Center(
          child: Semantics(
            scopesRoute: true,
            explicitChildNodes: true,
            namesRoute: true,
            label: title,
            child: card,
          ),
        ),
      ),
    );
  }
}

/// The alert's capsules: a row of two when both labels fit, else a stack.
class _JamAlertButtons extends StatelessWidget {
  const _JamAlertButtons({required this.actions, required this.gap});

  final List<JamAlertAction> actions;
  final double gap;

  /// Text inset inside a capsule.
  static const double _inset = JamSpace.md;

  bool _fitsSideBySide(BuildContext context, double width) {
    if (actions.length != 2) return false;
    final each = (width - gap) / 2 - _inset * 2;
    final scaler = MediaQuery.textScalerOf(context);
    for (final action in actions) {
      final painter = TextPainter(
        text: TextSpan(text: action.label, style: context.jamHeadline),
        textDirection: Directionality.of(context),
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      final fits = painter.width <= each;
      painter.dispose();
      if (!fits) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      if (_fitsSideBySide(context, constraints.maxWidth)) {
        return Row(
          children: [
            Expanded(child: JamAlertButton(action: actions[0])),
            SizedBox(width: gap),
            Expanded(child: JamAlertButton(action: actions[1])),
          ],
        );
      }
      // Stacked, iOS puts the action on top and Cancel at the bottom.
      final ordered = actions.length == 2 ? actions.reversed.toList() : actions;
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < ordered.length; i++) ...[
            if (i > 0) SizedBox(height: gap),
            JamAlertButton(action: ordered[i]),
          ],
        ],
      );
    },
  );
}

/// One of an alert's capsules: filled tint for the preferred action, filled
/// red for a destructive one, grey `fill` with `label` text otherwise.
class JamAlertButton extends StatelessWidget {
  const JamAlertButton({super.key, required this.action});

  final JamAlertAction action;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final enabled = action.onPressed != null;
    final (Color ground, Color fg, bool strong) = action.destructive
        ? (colors.danger, colors.onTint, true)
        : action.isDefault
        ? (colors.tintFilled, colors.onTint, true)
        : (colors.fill, colors.label, false);
    return Semantics(
      container: true,
      button: true,
      enabled: enabled,
      label: action.label,
      onTap: action.onPressed,
      excludeSemantics: true,
      child: Opacity(
        opacity: enabled ? 1 : 0.35,
        child: JamPressable(
          onTap: action.onPressed,
          pressedOpacity: 0.7,
          child: Container(
            height: JamMetrics.alertButtonHeight,
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(
              horizontal: _JamAlertButtons._inset,
            ),
            decoration: ShapeDecoration(
              color: ground,
              shape: const StadiumBorder(),
            ),
            child: Text(
              action.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: (strong ? context.jamHeadline : context.jamBody).copyWith(
                color: fg,
                fontWeight: strong ? null : FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The text field inside an alert: a filled rounded field (iOS 26), with an
/// optional footnote under it — [errorText] in `danger` (with a hairline
/// round the field), else [helperText] in `secondaryLabel`. The keyboard
/// follows the app's appearance, not the device's.
class JamAlertTextField extends StatelessWidget {
  const JamAlertTextField({
    super.key,
    required this.controller,
    this.placeholder,
    this.autofocus = true,
    this.keyboardType,
    this.textCapitalization = TextCapitalization.sentences,
    this.textInputAction = TextInputAction.done,
    this.maxLength,
    this.minLines,
    this.maxLines = 1,
    this.autocorrect = true,
    this.onChanged,
    this.onSubmitted,
    this.errorText,
    this.helperText,
    this.semanticLabel,
  });

  final TextEditingController controller;
  final String? placeholder;
  final bool autofocus;
  final TextInputType? keyboardType;
  final TextCapitalization textCapitalization;
  final TextInputAction textInputAction;
  final int? maxLength;
  final int? minLines;
  final int? maxLines;
  final bool autocorrect;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  /// Shown under the field in `danger`.
  final String? errorText;

  /// Shown under the field in `secondaryLabel` when there is no error.
  final String? helperText;

  /// Labels the field for screen readers (defaults to [placeholder]).
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final note = errorText ?? helperText;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          label: semanticLabel ?? placeholder,
          textField: true,
          child: CupertinoTextField(
            controller: controller,
            autofocus: autofocus,
            placeholder: placeholder,
            keyboardType: keyboardType,
            keyboardAppearance: jamKeyboardAppearance(context),
            textCapitalization: textCapitalization,
            textInputAction: textInputAction,
            maxLength: maxLength,
            minLines: minLines,
            maxLines: maxLines,
            autocorrect: autocorrect,
            enableSuggestions: autocorrect,
            clearButtonMode: OverlayVisibilityMode.editing,
            style: context.jamSubheadline.copyWith(color: colors.label),
            placeholderStyle: context.jamSubheadline.copyWith(
              color: colors.tertiaryLabel,
            ),
            cursorColor: colors.tint,
            padding: const EdgeInsets.symmetric(
              horizontal: JamSpace.md,
              vertical: JamSpace.sm,
            ),
            decoration: BoxDecoration(
              color: colors.fillSecondary,
              border: errorText == null
                  ? null
                  : Border.all(color: colors.danger, width: 0.5),
              borderRadius: BorderRadius.circular(JamRadius.field),
            ),
            onChanged: onChanged,
            onSubmitted: onSubmitted,
          ),
        ),
        if (note != null) ...[
          const SizedBox(height: JamSpace.xs),
          Text(
            note,
            textAlign: TextAlign.start,
            style: context.jamFootnote.copyWith(
              color: errorText != null ? colors.danger : colors.secondaryLabel,
            ),
          ),
        ],
      ],
    );
  }
}

/// Presents an alert on the root navigator over the `scrim`.
Future<T?> showJamAlert<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool barrierDismissible = false,
}) {
  final colors = context.jamColors;
  return Navigator.of(context, rootNavigator: true).push<T>(
    CupertinoDialogRoute<T>(
      context: context,
      builder: builder,
      barrierColor: colors.scrim,
      barrierDismissible: barrierDismissible,
    ),
  );
}

/// Ask, then act. Every method resolves once the alert is dismissed and never
/// throws.
abstract final class JamDialogs {
  /// A yes/no question. True only when the confirming action was taken.
  static Future<bool> confirm(
    BuildContext context, {
    required String title,
    String? message,
    String confirmLabel = JamDialogStrings.confirm,
    String cancelLabel = JamDialogStrings.cancel,
  }) async =>
      await showJamAlert<bool>(
        context,
        builder: (context) => JamConfirmDialog(
          title: title,
          message: message,
          confirmLabel: confirmLabel,
          cancelLabel: cancelLabel,
        ),
      ) ??
      false;

  /// A question about something that cannot be undone. The confirming action
  /// is red.
  static Future<bool> confirmDestructive(
    BuildContext context, {
    required String title,
    String? message,
    required String confirmLabel,
    String cancelLabel = JamDialogStrings.cancel,
  }) async =>
      await showJamAlert<bool>(
        context,
        builder: (context) => JamConfirmDialog(
          title: title,
          message: message,
          confirmLabel: confirmLabel,
          cancelLabel: cancelLabel,
          destructive: true,
        ),
      ) ??
      false;

  /// Ask for one line of text. The trimmed value, or null when cancelled or
  /// (unless [allowEmpty]) left blank.
  static Future<String?> promptText(
    BuildContext context, {
    required String title,
    String? message,
    String initialValue = '',
    String? hintText,
    String confirmLabel = JamDialogStrings.save,
    String cancelLabel = JamDialogStrings.cancel,
    TextCapitalization textCapitalization = TextCapitalization.sentences,
    TextInputType? keyboardType,
    int? maxLength,
    bool allowEmpty = false,
  }) async {
    // The keyboard belongs to the alert now.
    FocusManager.instance.primaryFocus?.unfocus();
    final value = await showJamAlert<String>(
      context,
      builder: (context) => JamPromptDialog(
        title: title,
        message: message,
        initialValue: initialValue,
        hintText: hintText,
        confirmLabel: confirmLabel,
        cancelLabel: cancelLabel,
        textCapitalization: textCapitalization,
        keyboardType: keyboardType,
        maxLength: maxLength,
        allowEmpty: allowEmpty,
      ),
    );
    if (value == null) return null;
    if (!allowEmpty && value.isEmpty) return null;
    return value;
  }
}

/// The confirm alert: Cancel, then the (semibold or red) confirming action.
/// Pops `true` on confirm, `false` on cancel.
class JamConfirmDialog extends StatelessWidget {
  const JamConfirmDialog({
    super.key,
    required this.title,
    this.message,
    this.confirmLabel = JamDialogStrings.confirm,
    this.cancelLabel = JamDialogStrings.cancel,
    this.destructive = false,
  });

  final String title;
  final String? message;
  final String confirmLabel;
  final String cancelLabel;

  /// The confirming action as a red capsule. Cancel stays the grey one —
  /// iOS 26 tells them apart by fill, not by two shades of red.
  final bool destructive;

  @override
  Widget build(BuildContext context) => JamAlert(
    title: title,
    message: message,
    actions: [
      JamAlertAction(
        label: cancelLabel,
        onPressed: () => Navigator.of(context).pop(false),
      ),
      JamAlertAction(
        label: confirmLabel,
        isDefault: !destructive,
        destructive: destructive,
        onPressed: () => Navigator.of(context).pop(true),
      ),
    ],
  );
}

/// A confirming text action for alerts and dialogs not yet on [JamAlert]:
/// 17 semibold tint (or `danger`).
class JamDialogPrimaryButton extends StatelessWidget {
  const JamDialogPrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.destructive = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool destructive;

  @override
  Widget build(BuildContext context) => JamTextButton(
    label: label,
    bold: true,
    destructive: destructive,
    onPressed: onPressed,
  );
}

/// The one-field alert. Owns its controller — see the lifetime rule above.
class JamPromptDialog extends StatefulWidget {
  const JamPromptDialog({
    super.key,
    required this.title,
    this.message,
    this.initialValue = '',
    this.hintText,
    this.confirmLabel = JamDialogStrings.save,
    this.cancelLabel = JamDialogStrings.cancel,
    this.textCapitalization = TextCapitalization.sentences,
    this.keyboardType,
    this.maxLength,
    this.allowEmpty = false,
  });

  final String title;
  final String? message;
  final String initialValue;
  final String? hintText;
  final String confirmLabel;
  final String cancelLabel;
  final TextCapitalization textCapitalization;
  final TextInputType? keyboardType;
  final int? maxLength;

  /// Whether the confirming action stays live with an empty field.
  final bool allowEmpty;

  @override
  State<JamPromptDialog> createState() => _JamPromptDialogState();
}

class _JamPromptDialogState extends State<JamPromptDialog> {
  late final TextEditingController _text = TextEditingController(
    text: widget.initialValue,
  );

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  bool get _canSubmit => widget.allowEmpty || _text.text.trim().isNotEmpty;

  void _submit() {
    if (!_canSubmit) return;
    Navigator.of(context).pop(_text.text.trim());
  }

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<TextEditingValue>(
        valueListenable: _text,
        builder: (context, _, _) => JamAlert(
          title: widget.title,
          message: widget.message,
          content: JamAlertTextField(
            controller: _text,
            placeholder: widget.hintText,
            keyboardType: widget.keyboardType,
            textCapitalization: widget.textCapitalization,
            maxLength: widget.maxLength,
            onSubmitted: (_) => _submit(),
          ),
          actions: [
            JamAlertAction(
              label: widget.cancelLabel,
              onPressed: () => Navigator.of(context).pop(),
            ),
            JamAlertAction(
              label: widget.confirmLabel,
              isDefault: true,
              onPressed: _canSubmit ? _submit : null,
            ),
          ],
        ),
      );
}
