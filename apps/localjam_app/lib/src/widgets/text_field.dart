/// One text field (CR-16): a filled soft rectangle — `fillSecondary`,
/// [JamRadius.field] — with a `secondaryLabel` placeholder, a tint cursor,
/// the app's keyboard appearance, and one clear button
/// ([JamFieldClearButton]) while there is text to clear. A search field is
/// the same field with a magnifier in front.
///
/// The alert's field (`JamAlertTextField`) and the library's search are
/// this field. Start a Jam's name — a section's cell, not a filled field —
/// clears text the same way: [JamFieldClearButton] is the `suffix` of any
/// `CupertinoTextField` that is not a [JamTextField].
///
/// ```dart
/// JamTextField(controller: _query, placeholder: 'Search', search: true)
/// CupertinoTextField.borderless(..., suffix: JamFieldClearButton(controller: c), suffixMode: OverlayVisibilityMode.editing)
/// ```
library;

import 'package:cupertino_ui/cupertino_ui.dart';

import '../design/theme.dart';
import '../design/tokens.dart';
import '../design/typography.dart';

/// Strings the field says.
abstract final class JamTextFieldStrings {
  static const String clear = 'Clear text';
}

/// The clear button's painted circle.
const double kJamFieldClearSize = 18;

/// The finger-sized box the circle is centred in.
const double kJamFieldClearHit = 36;

/// "Clear": an [kJamFieldClearSize] circle in `tertiaryLabel` with a small
/// xmark knocked out in the field's own paper — the one way a field is
/// cleared, in every field. Empties [controller] and reports the empty text
/// through [onCleared].
class JamFieldClearButton extends StatelessWidget {
  const JamFieldClearButton({
    super.key,
    required this.controller,
    this.focusNode,
    this.onCleared,
    this.semanticLabel = JamTextFieldStrings.clear,
  });

  final TextEditingController controller;

  /// The field's focus, taken when it clears (N9): you clear a field to
  /// type a new value, so the caret and the keyboard come with it. An
  /// unfocused field used to empty and then swallow what was typed until
  /// it was tapped a second time.
  final FocusNode? focusNode;

  /// Told the text is now empty (a field's `onChanged` is not called for a
  /// programmatic change).
  final ValueChanged<String>? onCleared;

  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    return Semantics(
      button: true,
      label: semanticLabel,
      excludeSemantics: true,
      onTap: () => _clear(),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _clear,
        // A finger-sized target around a small mark, inside the field.
        child: SizedBox(
          width: kJamFieldClearHit,
          height: kJamFieldClearHit,
          child: Center(
            child: Container(
              width: kJamFieldClearSize,
              height: kJamFieldClearSize,
              decoration: BoxDecoration(
                color: colors.tertiaryLabel,
                shape: BoxShape.circle,
              ),
              child: Icon(
                CupertinoIcons.xmark,
                size: 10,
                color: colors.groupedSurface,
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _clear() {
    controller.clear();
    onCleared?.call('');
    final focus = focusNode;
    if (focus != null && !focus.hasFocus) focus.requestFocus();
  }
}

/// The app's text field. [search] puts a magnifier in front.
class JamTextField extends StatefulWidget {
  const JamTextField({
    super.key,
    required this.controller,
    this.focusNode,
    this.placeholder,
    this.search = false,
    this.autofocus = false,
    this.keyboardType,
    this.textCapitalization = TextCapitalization.sentences,
    this.textInputAction,
    this.maxLength,
    this.minLines,
    this.maxLines = 1,
    this.autocorrect = true,
    this.onChanged,
    this.onSubmitted,
    this.error = false,
    this.style,
    this.semanticLabel,
  });

  final TextEditingController controller;
  final FocusNode? focusNode;
  final String? placeholder;

  /// A search field: a magnifier before the text, and the search key.
  final bool search;

  final bool autofocus;
  final TextInputType? keyboardType;
  final TextCapitalization textCapitalization;
  final TextInputAction? textInputAction;
  final int? maxLength;
  final int? minLines;
  final int? maxLines;
  final bool autocorrect;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  /// A `danger` hairline round the field: what was typed is the problem.
  final bool error;

  /// The text's style; defaults to body. The placeholder takes it in
  /// `secondaryLabel`.
  final TextStyle? style;

  /// Labels the field for screen readers (defaults to [placeholder]).
  final String? semanticLabel;

  @override
  State<JamTextField> createState() => _JamTextFieldState();
}

class _JamTextFieldState extends State<JamTextField> {
  /// The field's focus when the caller keeps none, so the clear button can
  /// hand it the caret.
  FocusNode? _ownFocus;
  FocusNode get _focus => widget.focusNode ?? (_ownFocus ??= FocusNode());

  @override
  void dispose() {
    _ownFocus?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final JamTextField(
      :controller,
      :placeholder,
      :search,
      :autofocus,
      :keyboardType,
      :textCapitalization,
      :textInputAction,
      :maxLength,
      :minLines,
      :maxLines,
      :autocorrect,
      :onChanged,
      :onSubmitted,
      :error,
      :style,
      :semanticLabel,
    ) = widget;
    final focusNode = _focus;
    final colors = context.jamColors;
    final text = (style ?? context.jamBody).copyWith(color: colors.label);
    return Semantics(
      label: semanticLabel ?? placeholder,
      textField: true,
      child: CupertinoTextField(
        controller: controller,
        focusNode: focusNode,
        autofocus: autofocus,
        placeholder: placeholder,
        keyboardType: keyboardType ?? (search ? TextInputType.text : null),
        keyboardAppearance: jamKeyboardAppearance(context),
        textCapitalization: textCapitalization,
        textInputAction:
            textInputAction ?? (search ? TextInputAction.search : null),
        maxLength: maxLength,
        minLines: minLines,
        maxLines: maxLines,
        autocorrect: autocorrect,
        enableSuggestions: autocorrect,
        style: text,
        placeholderStyle: text.copyWith(color: colors.secondaryLabel),
        cursorColor: colors.tint,
        prefix: search
            ? Padding(
                padding: const EdgeInsetsDirectional.only(start: JamSpace.sm),
                child: Icon(
                  CupertinoIcons.search,
                  size: JamIconSize.inline + 2,
                  color: colors.secondaryLabel,
                ),
              )
            : null,
        suffix: JamFieldClearButton(
          controller: controller,
          focusNode: focusNode,
          onCleared: onChanged,
        ),
        suffixMode: OverlayVisibilityMode.editing,
        clearButtonMode: OverlayVisibilityMode.never,
        padding: EdgeInsetsDirectional.fromSTEB(
          search ? JamSpace.xs + JamSpace.xxs : JamSpace.md,
          JamSpace.sm,
          JamSpace.md,
          JamSpace.sm,
        ),
        decoration: BoxDecoration(
          color: colors.fillSecondary,
          border: error ? Border.all(color: colors.danger, width: 0.5) : null,
          borderRadius: BorderRadius.circular(JamRadius.field),
        ),
        onChanged: onChanged,
        onSubmitted: onSubmitted,
      ),
    );
  }
}
