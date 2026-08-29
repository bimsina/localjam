/// Renaming yourself, in one place.
///
/// `JamIdentity.setDisplayName` shipped in v1 with no caller at all; it is
/// now reachable from home, settings and the desktop sidebar, so the dialog
/// itself lives here rather than being copied into each.
library;

import 'package:flutter/material.dart';

/// Asks for a new display name. Returns null when cancelled or left blank.
Future<String?> promptForName(
  BuildContext context, {
  required String current,
}) async {
  final controller = TextEditingController(text: current);
  final name = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Your name in the room'),
      content: TextField(
        controller: controller,
        autofocus: true,
        textCapitalization: TextCapitalization.words,
        onSubmitted: (value) => Navigator.of(context).pop(value.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(controller.text.trim()),
          child: const Text('Save'),
        ),
      ],
    ),
  );
  controller.dispose();
  return (name == null || name.isEmpty) ? null : name;
}
