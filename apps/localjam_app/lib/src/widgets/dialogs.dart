/// The three dialogs the app actually needs: confirm, confirm-something-you-
/// cannot-undo, and ask-for-one-line-of-text.
///
/// Shape and palette come from `dialogTheme` (§4: `surfaceElevated`, radius
/// `lg`, 24 padding, `jamSheetTitle` title, `jamBody` `textSecondary` body,
/// actions right-aligned, dismiss first and primary last). What lives here is
/// the wording contract and the one lifetime rule below.
///
/// **The lifetime rule.** A `TextEditingController` created by the *caller*
/// and disposed the moment `showDialog` completes is still wired to a
/// `TextField` that the exit transition keeps building for another 150 ms —
/// `'_dependents.isEmpty': is not true`, red screen. Every dialog here that
/// owns a field owns its controller in a `State` and disposes it in
/// `State.dispose`, which ties the controller's life to the route's.
library;

import 'package:flutter/material.dart';

import '../design/tokens.dart';
import '../design/typography.dart';

/// Default labels, in one place rather than scattered through call sites.
abstract final class JamDialogStrings {
  static const String cancel = 'Cancel';
  static const String confirm = 'Confirm';
  static const String save = 'Save';
}

/// Ask, then act. Every method returns only after the exit transition has
/// been started, and never throws.
abstract final class JamDialogs {
  /// A yes/no question. Returns true only when the primary action was taken.
  static Future<bool> confirm(
    BuildContext context, {
    required String title,
    String? message,
    String confirmLabel = JamDialogStrings.confirm,
    String cancelLabel = JamDialogStrings.cancel,
  }) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => JamConfirmDialog(
          title: title,
          message: message,
          confirmLabel: confirmLabel,
          cancelLabel: cancelLabel,
        ),
      ) ??
      false;

  /// A yes/no question about something that cannot be undone — ending the jam,
  /// removing a person, forgetting a past jam. The primary action is filled in
  /// `danger` so the consequence is visible before the tap, not after.
  static Future<bool> confirmDestructive(
    BuildContext context, {
    required String title,
    String? message,
    required String confirmLabel,
    String cancelLabel = JamDialogStrings.cancel,
  }) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => JamConfirmDialog(
          title: title,
          message: message,
          confirmLabel: confirmLabel,
          cancelLabel: cancelLabel,
          destructive: true,
        ),
      ) ??
      false;

  /// Ask for one line of text. Returns the trimmed value, or null when the
  /// dialog was cancelled or (unless [allowEmpty]) left blank.
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
    // The keyboard belongs to the dialog now; leaving a field focused behind
    // it means the caller's own field pops the keyboard back up on the way
    // out.
    FocusManager.instance.primaryFocus?.unfocus();
    final value = await showDialog<String>(
      context: context,
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

/// The confirm dialog. Public so a caller can push it onto a navigator of its
/// own; [JamDialogs.confirm] is the way in for everything else.
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

  /// Fills the primary action in `danger` rather than the accent.
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final body = message;
    return AlertDialog(
      title: Text(title),
      content: body == null ? null : Text(body),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(cancelLabel),
        ),
        JamDialogPrimaryButton(
          label: confirmLabel,
          destructive: destructive,
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ],
    );
  }
}

/// A dialog's primary action: the themed `FilledButton`, re-tinted to `danger`
/// when the thing behind it cannot be undone.
///
/// The label is [JamColors.onAccent] rather than a literal white: on the dark
/// palette `danger` is a light coral, and white on it misses AA by a mile,
/// where the plum `onAccent` clears it.
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
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    return FilledButton(
      onPressed: onPressed,
      style: destructive
          ? FilledButton.styleFrom(
              backgroundColor: colors.danger,
              foregroundColor: colors.onAccent,
              disabledBackgroundColor: colors.surfaceMuted,
              disabledForegroundColor: colors.textTertiary,
            )
          : null,
      child: Text(label),
    );
  }
}

/// The one-field dialog. Owns its [TextEditingController] — see the lifetime
/// rule at the top of this file.
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

  /// Whether the primary action stays live with an empty field.
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
    // Not after `await showDialog` — here, where the route's own lifetime
    // decides when the field is finally gone.
    _text.dispose();
    super.dispose();
  }

  bool get _canSubmit => widget.allowEmpty || _text.text.trim().isNotEmpty;

  void _submit() {
    if (!_canSubmit) return;
    Navigator.of(context).pop(_text.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final message = widget.message;

    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (message != null) ...[
            Text(message),
            const SizedBox(height: JamSpace.lg),
          ],
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _text,
            builder: (context, _, _) => TextField(
              controller: _text,
              autofocus: true,
              textCapitalization: widget.textCapitalization,
              keyboardType: widget.keyboardType,
              maxLength: widget.maxLength,
              textInputAction: TextInputAction.done,
              style: context.jamBody.copyWith(color: colors.textPrimary),
              decoration: InputDecoration(
                hintText: widget.hintText,
                counterText: '',
              ),
              onSubmitted: (_) => _submit(),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(widget.cancelLabel),
        ),
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: _text,
          builder: (context, _, _) => JamDialogPrimaryButton(
            label: widget.confirmLabel,
            onPressed: _canSubmit ? _submit : null,
          ),
        ),
      ],
    );
  }
}
