/// Joining by pasted link — the way in when there is no camera and nothing
/// nearby (DESIGN_SPEC v3 §6.10, §6.11).
///
/// mDNS does not cross a hotspot and a QR needs a working camera, which left
/// a real hole: someone sends you the jam link in a chat and the app had
/// nowhere to put it. This is that field, as an iOS alert with a text field.
///
/// It behaves like iOS's own text-field alerts:
///
/// * **Join** stays disabled until the text parses as a jam link — no
///   validating after the fact, no red field.
/// * The clipboard is never read on open: on iOS that raises the system's
///   "Allow Paste" prompt every time, even for a clipboard that holds no
///   link. A **Paste** button reads it when asked to (shown only while the
///   clipboard has text, which iOS can tell without prompting).
/// * Only a real attempt that fails — Return on a bad link, or pasting
///   something that isn't one — says so, by swapping the alert's message
///   line for the reason.
library;

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

import '../design/theme.dart';
import '../design/tokens.dart';
import '../util/network.dart';
import 'buttons.dart';
import 'dialogs.dart';

/// Every user-facing string these alerts can show.
abstract final class JamJoinLinkStrings {
  static const String title = 'Join with Link';
  static const String message = 'Paste a link someone shared.';

  /// Not the URI scheme: `localjam://join?…` is machine text and tells the
  /// user nothing about what to put in the box. Sentence case: it's a
  /// placeholder, not a title.
  static const String hint = 'Jam link';
  static const String paste = 'Paste';
  static const String invalid = 'That isn’t a LocalJam link.';
  static const String cancel = 'Cancel';
  static const String join = 'Join';

  /// The deep-link confirmation, for a link that arrived from outside the
  /// app.
  static const String confirmBody = 'Someone shared a link to this jam.';
  static const String confirmDecline = cancel;
  static const String confirmFallbackName = 'This Jam';

  /// "Join Van Jam?" — the deep-link confirmation's title.
  static String confirmTitle(String name) => 'Join $name?';
}

/// Asks for a `localjam://join?...` link. Returns the parsed URI, or null if
/// the user backed out.
///
/// [brightness] draws the alert in that appearance whatever the app's — the
/// scanner passes [Brightness.dark] so the alert matches its black camera
/// page instead of turning a muddy grey over it. Null follows [context]'s
/// theme (the alert route captures it).
Future<Uri?> promptForJoinLink(BuildContext context, {Brightness? brightness}) {
  // The keyboard belongs to the alert now.
  FocusManager.instance.primaryFocus?.unfocus();
  return showJamAlert<Uri>(
    context,
    builder: (_) => brightness == null
        ? const JoinLinkDialog()
        : JamForcedAppearance(
            brightness: brightness,
            child: const JoinLinkDialog(),
          ),
  );
}

/// The Join with Link alert. Owns its controller (the dialogs.dart lifetime
/// rule).
class JoinLinkDialog extends StatefulWidget {
  const JoinLinkDialog({super.key, this.initialValue = ''});

  /// Seeds the field. Tests use it; nothing else needs to.
  final String initialValue;

  @override
  State<JoinLinkDialog> createState() => _JoinLinkDialogState();
}

class _JoinLinkDialogState extends State<JoinLinkDialog> {
  late final TextEditingController _text = TextEditingController(
    text: widget.initialValue,
  );

  /// Whether the clipboard holds text — asked without reading it, so no
  /// prompt. Decides whether Paste is offered.
  bool _canPaste = false;

  /// Set by a real attempt that failed; cleared by the next edit.
  String? _error;

  @override
  void initState() {
    super.initState();
    Clipboard.hasStrings()
        .then((has) {
          if (mounted && has != _canPaste) setState(() => _canPaste = has);
        })
        // A platform without a clipboard simply offers no Paste.
        .catchError((_) {});
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  /// Reads the clipboard because the person asked to. A jam link goes into
  /// the field; anything else stays out of it (pasting someone's shopping
  /// list into a link box helps nobody) and the message says why.
  Future<void> _paste() async {
    ClipboardData? data;
    try {
      data = await Clipboard.getData(Clipboard.kTextPlain);
    } catch (_) {
      data = null;
    }
    if (!mounted) return;
    final text = data?.text?.trim() ?? '';
    if (parseJoinUri(text) == null) {
      setState(() => _error = JamJoinLinkStrings.invalid);
      return;
    }
    _text.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    setState(() => _error = null);
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
    if (_error == null) return;
    setState(() => _error = null);
  }

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<TextEditingValue>(
        valueListenable: _text,
        builder: (context, value, _) {
          final valid = parseJoinUri(value.text) != null;
          return JamAlert(
            title: JamJoinLinkStrings.title,
            // A failed attempt answers where the alert explains itself:
            // centred, in the message's place — not a red line under the
            // field.
            message: _error ?? JamJoinLinkStrings.message,
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                JamAlertTextField(
                  controller: _text,
                  placeholder: JamJoinLinkStrings.hint,
                  keyboardType: TextInputType.url,
                  textCapitalization: TextCapitalization.none,
                  textInputAction: TextInputAction.go,
                  autocorrect: false,
                  onChanged: _onChanged,
                  onSubmitted: (_) => _submit(),
                ),
                if (_canPaste && !valid) ...[
                  const SizedBox(height: JamSpace.xs),
                  Center(
                    child: JamButton.plain(
                      label: JamJoinLinkStrings.paste,
                      icon: CupertinoIcons.doc_on_clipboard,
                      size: JamButtonSize.small,
                      onPressed: _paste,
                    ),
                  ),
                ],
              ],
            ),
            actions: [
              JamAlertAction(
                label: JamJoinLinkStrings.cancel,
                onPressed: () => Navigator.of(context).pop(),
              ),
              JamAlertAction(
                label: JamJoinLinkStrings.join,
                isDefault: true,
                onPressed: valid ? _submit : null,
              ),
            ],
          );
        },
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
