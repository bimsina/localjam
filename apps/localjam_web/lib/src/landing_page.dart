/// The first screen (docs/design/WEB_GUEST.md "Web page behaviour" 1): the
/// brand, the jam's name from the link, a name to join with (a generated
/// default like the app's, kept in this browser's storage), and one button.
/// Its tap is the user gesture that lets the page make sound.
library;

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';

import 'design.dart';
import 'widgets.dart';

class LandingPage extends StatelessWidget {
  const LandingPage({
    super.key,
    required this.jamName,
    required this.nameController,
    required this.joining,
    required this.onListen,
    required this.onOpenApp,
  });

  static const String brand = 'LocalJam';
  static const String invited = "You're invited to listen along";
  static const String fallbackJamName = 'A LocalJam';
  static const String nameLabel = 'Your name';
  static const String nameHint = 'How others see you';
  static const String listen = 'Tap to listen';
  static const String openApp = 'Open in app';
  static const String sameWifi =
      'Listening works on the same Wi-Fi as the host, with no app and no '
      'internet.';

  final String? jamName;
  final TextEditingController nameController;
  final bool joining;
  final VoidCallback onListen;
  final VoidCallback? onOpenApp;

  @override
  Widget build(BuildContext context) {
    final c = colorsOf(context);
    return PageColumn(
      center: true,
      children: [
        Row(
          children: [
            Icon(CupertinoIcons.music_note_2, color: c.tint, size: 22),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                brand,
                style: PageType.headline.copyWith(
                  color: c.tint,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 40),
        Text(
          invited,
          style: PageType.subheadline.copyWith(color: c.secondaryLabel),
        ),
        const SizedBox(height: 4),
        Semantics(
          header: true,
          child: Text(
            jamName ?? fallbackJamName,
            style: PageType.largeTitle.copyWith(color: c.label),
          ),
        ),
        const SizedBox(height: 32),
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 6),
          child: Text(
            nameLabel,
            style: PageType.footnote.copyWith(color: c.secondaryLabel),
          ),
        ),
        _NameField(
          controller: nameController,
          enabled: !joining,
          onSubmitted: onListen,
        ),
        const SizedBox(height: 16),
        PageButton(
          label: listen,
          icon: CupertinoIcons.headphones,
          busy: joining,
          onPressed: onListen,
        ),
        if (onOpenApp != null) ...[
          const SizedBox(height: 4),
          PageButton(
            label: openApp,
            style: PageButtonStyle.plain,
            onPressed: joining ? null : onOpenApp,
          ),
        ],
        const SizedBox(height: 16),
        Text(
          sameWifi,
          textAlign: TextAlign.center,
          style: PageType.footnote.copyWith(color: c.secondaryLabel),
        ),
      ],
    );
  }
}

/// The name to join with: prefilled with a generated name, which the first
/// focus selects whole — so typing replaces it ("Polka Yak" then "Web Tester"
/// read "Polka YakWeb Tester") rather than appending to it.
class _NameField extends StatefulWidget {
  const _NameField({
    required this.controller,
    required this.enabled,
    required this.onSubmitted,
  });

  final TextEditingController controller;
  final bool enabled;
  final VoidCallback onSubmitted;

  @override
  State<_NameField> createState() => _NameFieldState();
}

class _NameFieldState extends State<_NameField> {
  final FocusNode _focus = FocusNode();

  /// Whether the first focus has selected the name yet. Only the first: a
  /// later tap places the caret as usual.
  bool _selectedOnce = false;

  /// A pointer went down while the field was unfocused: the focus that
  /// follows is a tap's, whose caret lands after it, so the select waits
  /// for the tap ([_onTap]).
  bool _tapFocusing = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocus);
  }

  @override
  void dispose() {
    _focus
      ..removeListener(_onFocus)
      ..dispose();
    super.dispose();
  }

  /// Focus by keyboard (Tab) selects at once.
  void _onFocus() {
    if (_focus.hasFocus && !_tapFocusing) _selectAllOnce();
  }

  void _onTap() {
    if (!_tapFocusing) return;
    _tapFocusing = false;
    _selectAllOnce();
  }

  void _selectAllOnce() {
    if (_selectedOnce) return;
    _selectedOnce = true;
    widget.controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: widget.controller.text.length,
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = colorsOf(context);
    return Listener(
      onPointerDown: (_) {
        if (!_focus.hasFocus && !_selectedOnce) _tapFocusing = true;
      },
      child: TextField(
        controller: widget.controller,
        focusNode: _focus,
        enabled: widget.enabled,
        onTap: _onTap,
        maxLength: 40,
        textInputAction: TextInputAction.go,
        onSubmitted: (_) => widget.onSubmitted(),
        style: PageType.body.copyWith(color: c.label),
        cursorColor: c.tint,
        decoration: InputDecoration(
          hintText: LandingPage.nameHint,
          hintStyle: PageType.body.copyWith(color: c.secondaryLabel),
          counterText: '',
          filled: true,
          fillColor: c.fillSecondary,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: 14,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(Metrics.section),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }
}
