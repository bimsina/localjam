/// iOS alerts on every platform (DESIGN_SPEC v3 §5 Alerts).
///
/// Centred, 270 wide, blurred: title headline, message footnote, buttons 17
/// (the preferred action semibold, destructive in `danger`), side by side for
/// two and stacked for more; optionally one text field. Built on
/// `CupertinoAlertDialog`, tinted from the theme.
///
/// **The lifetime rule.** A `TextEditingController` disposed the moment the
/// dialog's future completes is still wired to a field the exit transition
/// keeps building — red screen. Every alert here that owns a field owns its
/// controller in a `State` and disposes it in `State.dispose`.
library;

import 'package:flutter/cupertino.dart';

import '../design/tokens.dart';
import '../design/typography.dart';
import 'buttons.dart';

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

  /// The preferred action: semibold.
  final bool isDefault;

  /// `danger` label.
  final bool destructive;
}

/// An iOS alert.
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

  @override
  Widget build(BuildContext context) {
    final message = this.message;
    final content = this.content;
    return CupertinoAlertDialog(
      title: Text(title),
      content: message == null && content == null
          ? null
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (message != null) Text(message),
                if (content != null) ...[
                  const SizedBox(height: JamSpace.md),
                  content,
                ],
              ],
            ),
      actions: [
        for (final action in actions)
          CupertinoDialogAction(
            onPressed: action.onPressed,
            isDefaultAction: action.isDefault,
            isDestructiveAction: action.destructive,
            child: Text(action.label),
          ),
      ],
    );
  }
}

/// The text field inside an alert: iOS's bordered rounded field, with an
/// optional footnote under it — [errorText] in `danger`, else [helperText]
/// in `secondaryLabel`.
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
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
            decoration: BoxDecoration(
              color: colors.elevated,
              border: Border.all(
                color: errorText != null ? colors.danger : colors.separator,
                width: 0.5,
              ),
              borderRadius: BorderRadius.circular(7),
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

  /// The confirming action in `danger` (and Cancel becomes the bold one, as
  /// iOS does).
  final bool destructive;

  @override
  Widget build(BuildContext context) => JamAlert(
    title: title,
    message: message,
    actions: [
      JamAlertAction(
        label: cancelLabel,
        isDefault: destructive,
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
