/// Joining by pasted link — the way in when there is no camera and nothing
/// nearby (DESIGN_SPEC v3 §6.10, §6.11).
///
/// mDNS does not cross a hotspot and a QR needs a working camera, which left
/// a real hole: someone sends you the jam link in a chat and the app had
/// nowhere to put it. This is that field, as an iOS alert with a text field.
///
/// Two things the shared prompt has no business carrying: the clipboard is
/// read on open, so a link that is already copied is simply *there* (with a
/// note saying where it came from, because a field that fills itself is
/// otherwise unnerving), and a bad link is answered under the field rather
/// than in a toast — the mistake is in the field, so the correction belongs
/// beside it.
library;

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

import '../util/network.dart';
import 'dialogs.dart';

/// Every user-facing string these alerts can show.
abstract final class JamJoinLinkStrings {
  static const String title = 'Join with Link';
  static const String message = 'Paste the link someone shared with you.';

  /// Not the URI scheme: `localjam://join?…` is machine text and tells the
  /// user nothing about what to put in the box.
  static const String hint = 'Jam Link';
  static const String pasted = 'Pasted from your clipboard.';
  static const String invalid = 'That isn’t a LocalJam link.';
  static const String cancel = 'Cancel';
  static const String join = 'Join';

  /// The deep-link confirmation, for a link that arrived from outside the
  /// app.
  static const String confirmBody =
      'A link opened LocalJam to join a jam on your network.';
  static const String confirmDecline = cancel;
  static const String confirmFallbackName = 'This Jam';

  /// "Join Van Jam?" — the deep-link confirmation's title.
  static String confirmTitle(String name) => 'Join $name?';
}

/// Asks for a `localjam://join?...` link. Returns the parsed URI, or null if
/// the user backed out.
Future<Uri?> promptForJoinLink(BuildContext context) {
  // The keyboard belongs to the alert now.
  FocusManager.instance.primaryFocus?.unfocus();
  return showJamAlert<Uri>(context, builder: (_) => const JoinLinkDialog());
}

/// The Join with Link alert. Owns its controller (the dialogs.dart lifetime
/// rule).
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

  /// Set once the clipboard filled the field, so the note is only shown
  /// when it is true — and cleared the moment the text is edited.
  bool _fromClipboard = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.initialValue.isEmpty) _prefill();
  }

  /// Reads the clipboard once, on open, and only takes a jam link from it.
  /// Anything else stays out of the field: pasting someone's shopping list
  /// into a link box is worse than an empty box.
  void _prefill() {
    Clipboard.getData(Clipboard.kTextPlain)
        .then((data) {
          final text = data?.text?.trim();
          if (!mounted || text == null || text.isEmpty) return;
          if (parseJoinUri(text) == null) return;
          // Typed into already: the person's text wins.
          if (_text.text.isNotEmpty) return;
          setState(() {
            _text.text = text;
            _fromClipboard = true;
          });
        })
        // A platform without a clipboard is not an error path; the field
        // just stays empty.
        .catchError((_) {});
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _submit() {
    if (_text.text.trim().isEmpty) return;
    final uri = parseJoinUri(_text.text);
    if (uri == null) {
      setState(() => _error = JamJoinLinkStrings.invalid);
      return;
    }
    Navigator.of(context).pop(uri);
  }

  void _onChanged(String _) {
    if (_error == null && !_fromClipboard) return;
    setState(() {
      _error = null;
      _fromClipboard = false;
    });
  }

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<TextEditingValue>(
        valueListenable: _text,
        builder: (context, value, _) => JamAlert(
          title: JamJoinLinkStrings.title,
          message: JamJoinLinkStrings.message,
          content: JamAlertTextField(
            controller: _text,
            placeholder: JamJoinLinkStrings.hint,
            keyboardType: TextInputType.url,
            textCapitalization: TextCapitalization.none,
            textInputAction: TextInputAction.go,
            autocorrect: false,
            errorText: _error,
            helperText: _fromClipboard ? JamJoinLinkStrings.pasted : null,
            onChanged: _onChanged,
            onSubmitted: (_) => _submit(),
          ),
          actions: [
            JamAlertAction(
              label: JamJoinLinkStrings.cancel,
              onPressed: () => Navigator.of(context).pop(),
            ),
            JamAlertAction(
              label: JamJoinLinkStrings.join,
              isDefault: true,
              onPressed: value.text.trim().isEmpty ? null : _submit,
            ),
          ],
        ),
      );
}

/// Confirms a join the user did not start from inside the app — a link
/// that arrived from somewhere else and opened LocalJam.
///
/// Returns true to go ahead.
Future<bool> confirmLinkJoin(BuildContext context, {String? roomName}) {
  final name = (roomName == null || roomName.trim().isEmpty)
      ? JamJoinLinkStrings.confirmFallbackName
      : roomName.trim();
  return JamDialogs.confirm(
    context,
    title: JamJoinLinkStrings.confirmTitle(name),
    message: JamJoinLinkStrings.confirmBody,
    confirmLabel: JamJoinLinkStrings.join,
    cancelLabel: JamJoinLinkStrings.confirmDecline,
  );
}
