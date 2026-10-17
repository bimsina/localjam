/// Joining by pasted link — the way in when there is no camera and nothing
/// nearby.
///
/// mDNS does not cross a hotspot and a QR needs a working camera, which left
/// a real hole: someone sends you the room link in a chat and the app had
/// nowhere to put it. This is that field.
///
/// Styled as a [JamPromptDialog] with two additions the shared prompt has no
/// business carrying: the clipboard is read on open, so a link that is
/// already copied is simply *there* (with a footnote saying where it came
/// from, because a field that fills itself is otherwise unnerving), and a bad
/// link is answered with inline helper text rather than a snackbar — the
/// mistake is in the field, so the correction belongs beside it.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design/theme.dart';
import '../design/tokens.dart';
import '../design/typography.dart';
import '../util/network.dart';
import 'dialogs.dart';

/// Every user-facing string this dialog can show.
abstract final class JamJoinLinkStrings {
  static const String title = 'Join with a link';

  /// Not the URI scheme. `localjam://join?…` is machine text (§8.3) and it
  /// told the user nothing about what to put in the box.
  static const String hint = 'Paste the invite link';
  static const String pasted = 'Pasted from your clipboard';
  static const String invalid = 'That is not a jam link.';
  static const String cancel = 'Cancel';
  static const String join = 'Join';
  static const String fieldLabel = 'Jam link';

  /// The deep-link confirmation, for a link that arrived from outside the app.
  static const String confirmBody =
      'A link asked LocalJam to join a room on your network.';
  static const String confirmDecline = 'Not now';
  static const String confirmFallbackName = 'this jam';

  /// "Join Van Jam?" — the deep-link confirmation's title.
  static String confirmTitle(String name) => 'Join $name?';
}

/// Asks for a `localjam://join?...` link. Returns the parsed URI, or null if
/// the user backed out.
Future<Uri?> promptForJoinLink(BuildContext context) => showDialog<Uri>(
  context: context,
  builder: (context) => const JoinLinkDialog(),
);

class JoinLinkDialog extends StatefulWidget {
  const JoinLinkDialog({super.key, this.initialValue = ''});

  /// Seeds the field instead of the clipboard. Tests use it; nothing else
  /// needs to.
  final String initialValue;

  @override
  State<JoinLinkDialog> createState() => _JoinLinkDialogState();
}

class _JoinLinkDialogState extends State<JoinLinkDialog> {
  late final TextEditingController _text = TextEditingController(
    text: widget.initialValue,
  );

  /// Set once the clipboard filled the field, so the footnote is only shown
  /// when it is true — and cleared the moment the text is edited.
  bool _fromClipboard = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.initialValue.isEmpty) unawaitedPrefill();
  }

  /// Reads the clipboard once, on open, and only takes a jam link from it.
  /// Anything else stays out of the field: pasting someone's shopping list
  /// into a URL box is worse than an empty box.
  void unawaitedPrefill() {
    Clipboard.getData(Clipboard.kTextPlain)
        .then((data) {
          final text = data?.text?.trim();
          if (!mounted || text == null || text.isEmpty) return;
          if (parseJoinUri(text) == null) return;
          setState(() {
            _text.text = text;
            _fromClipboard = true;
          });
        })
        // A platform without a clipboard is not an error path; the field just
        // stays empty.
        .catchError((_) {});
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _submit() {
    final uri = parseJoinUri(_text.text);
    if (uri == null) {
      setState(() => _error = JamJoinLinkStrings.invalid);
      return;
    }
    Navigator.of(context).pop(uri);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final text = Theme.of(context).textTheme;

    return AlertDialog(
      title: const Text(JamJoinLinkStrings.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _text,
            builder: (context, _, _) => TextField(
              controller: _text,
              autofocus: true,
              minLines: 1,
              maxLines: 2,
              keyboardType: TextInputType.url,
              autocorrect: false,
              enableSuggestions: false,
              textInputAction: TextInputAction.go,
              style: context.jamBody.copyWith(color: colors.textPrimary),
              // The app's filled field, applied explicitly. The stock
              // outline-notch label ("Jam link" cut into a raspberry border)
              // is the one Material tell this dialog had left, and with a
              // floating label the accent focus ring also stayed accent
              // while the helper underneath was already saying `danger`.
              // The error and the border are one state now, not two.
              decoration: InputDecoration(
                hintText: JamJoinLinkStrings.hint,
                errorText: _error,
                helperText: _error == null && _fromClipboard
                    ? JamJoinLinkStrings.pasted
                    : null,
                helperStyle: context.jamFootnote.copyWith(
                  color: colors.textTertiary,
                ),
              ).applyDefaults(jamFilledInput(colors, text)),
              onChanged: (_) {
                if (_error == null && !_fromClipboard) return;
                setState(() {
                  _error = null;
                  _fromClipboard = false;
                });
              },
              onSubmitted: (_) => _submit(),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text(JamJoinLinkStrings.cancel),
        ),
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: _text,
          builder: (context, value, _) => _SubmitButton(
            enabled: value.text.trim().isNotEmpty,
            onPressed: _submit,
          ),
        ),
      ],
    );
  }
}

/// The dialog's Join button, disabled until the field holds something.
///
/// It uses the theme's own disabled fill — `surfaceMuted` behind
/// `textTertiary` — rather than the half-opacity raspberry it wore before.
/// That was `onAccent` white over 50% raspberry on the dialog's surface,
/// which lands under 4.5:1 and is unreadable on exactly the screen someone
/// is squinting at a pasted link on. The muted pair is the palette's
/// contrast-checked answer to "not yet", and it is what every other disabled
/// primary in the app already shows.
class _SubmitButton extends StatelessWidget {
  const _SubmitButton({required this.enabled, required this.onPressed});

  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => JamDialogPrimaryButton(
    label: JamJoinLinkStrings.join,
    onPressed: enabled ? onPressed : null,
  );
}

/// Confirms a join the user did not initiate from inside the app — a link
/// that arrived from somewhere else and opened LocalJam.
///
/// Returns true to go ahead.
Future<bool> confirmLinkJoin(BuildContext context, {String? roomName}) async {
  final name = (roomName == null || roomName.isEmpty)
      ? JamJoinLinkStrings.confirmFallbackName
      : roomName;
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => JamConfirmDialog(
      title: JamJoinLinkStrings.confirmTitle(name),
      message: JamJoinLinkStrings.confirmBody,
      confirmLabel: JamJoinLinkStrings.join,
      cancelLabel: JamJoinLinkStrings.confirmDecline,
    ),
  );
  return ok ?? false;
}
