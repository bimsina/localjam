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
  static const String listen = 'Tap to Listen';
  static const String openApp = 'Open in App';
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
        TextField(
          controller: nameController,
          enabled: !joining,
          maxLength: 40,
          textInputAction: TextInputAction.go,
          onSubmitted: (_) => onListen(),
          style: PageType.body.copyWith(color: c.label),
          cursorColor: c.tint,
          decoration: InputDecoration(
            hintText: nameHint,
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
