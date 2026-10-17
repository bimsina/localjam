/// Renaming yourself, in one place.
///
/// `JamIdentity.setDisplayName` shipped in v1 with no caller at all; it is
/// now reachable from home, settings and the desktop sidebar, so the prompt
/// lives here rather than being copied into each.
///
/// The dialog itself is [JamDialogs.promptText] — one styled dialog for the
/// whole app, and one place where the controller-lifetime bug that used to
/// red-screen every rename is fixed.
library;

import 'package:flutter/material.dart';

import 'dialogs.dart';

/// The strings this prompt puts on screen.
abstract final class RenameStrings {
  static const String title = 'Your name in the room';
  static const String hint = 'Silky Puffin';
  static const String save = 'Save';
}

/// The longest name the protocol should have to carry. Two words and a
/// nickname fit; a pasted paragraph does not.
const int kDisplayNameMaxLength = 32;

/// Asks for a new display name. Returns null when cancelled or left blank.
Future<String?> promptForName(
  BuildContext context, {
  required String current,
}) => JamDialogs.promptText(
  context,
  title: RenameStrings.title,
  initialValue: current,
  hintText: RenameStrings.hint,
  confirmLabel: RenameStrings.save,
  textCapitalization: TextCapitalization.words,
  maxLength: kDisplayNameMaxLength,
);
