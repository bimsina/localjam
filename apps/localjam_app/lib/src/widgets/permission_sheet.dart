/// Why LocalJam is about to ask the OS for something.
///
/// Shown *before* the system prompt and never after a denial — once the OS has
/// said no for good, the only honest thing left is a route into Settings, and
/// that is a notice's job, not this sheet's.
///
/// The wording lives in [JamPermissionCopy] (`util/permissions.dart`), which
/// is where the functional pass put it so the redesign could lift it without
/// hunting through call sites. This file adds only the two bullets — what we
/// do with the permission, and what we never do — because the promise is part
/// of the ask.
library;

import 'package:flutter/material.dart';

import '../design/tokens.dart';
import '../design/typography.dart';
import '../util/permissions.dart';
import 'sheet.dart';

/// One permission's case, assembled from [JamPermissionCopy].
///
/// A value rather than a widget so a screen can decide *whether* to ask
/// without building anything, and so the copy stays testable.
@immutable
class JamPermissionRationale {
  const JamPermissionRationale({
    required this.icon,
    required this.title,
    required this.body,
    required this.doesBullet,
    required this.neverBullet,
    this.continueLabel = JamPermissionSheetStrings.continueLabel,
    this.dismissLabel = JamPermissionSheetStrings.dismissLabel,
  });

  /// The 64 dp glyph in the accent-soft square.
  final IconData icon;

  /// `jamSheetTitle`.
  final String title;

  /// `jamBody`.
  final String body;

  /// "What we do with it."
  final String doesBullet;

  /// "What we never do." The half people actually want to read.
  final String neverBullet;

  final String continueLabel;
  final String dismissLabel;

  /// The two local-network bullets, shared by the Android rationale and the
  /// Apple one: it is the same permission and the same promise, and two
  /// copies of a sentence about privacy are two chances for them to drift
  /// apart.
  static const String _localNetworkDoes =
      'Talk to the other phones on this Wi-Fi or hotspot, so everyone '
      'hears the same second of the same song.';
  static const String _localNetworkNever =
      'Reach the internet. A jam never leaves the network you are '
      'standing on.';

  /// Android 17's `ACCESS_LOCAL_NETWORK`, asked before hosting or joining.
  static const JamPermissionRationale localNetwork = JamPermissionRationale(
    icon: Icons.wifi_rounded,
    title: JamPermissionCopy.localNetworkTitle,
    body: JamPermissionCopy.localNetworkDetail,
    doesBullet: _localNetworkDoes,
    neverBullet: _localNetworkNever,
  );

  /// The same thing on iOS and macOS, where the system does the asking.
  ///
  /// One button, because there is nothing to decline: the OS alert is coming
  /// either way the moment the first socket opens, and a "Not now" that
  /// cannot stop it would be a lie.
  static const JamPermissionRationale localNetworkApple =
      JamPermissionRationale(
        icon: Icons.wifi_rounded,
        title: JamPermissionCopy.localNetworkTitle,
        body: JamPermissionCopy.localNetworkAppleDetail,
        doesBullet: _localNetworkDoes,
        neverBullet: _localNetworkNever,
        continueLabel: JamPermissionSheetStrings.gotItLabel,
        dismissLabel: '',
      );

  /// Android 13+'s `POST_NOTIFICATIONS`, asked before the media card.
  static const JamPermissionRationale notifications = JamPermissionRationale(
    icon: Icons.play_circle_outline_rounded,
    title: JamPermissionCopy.notificationsTitle,
    body: JamPermissionCopy.notificationsDetail,
    doesBullet:
        'Put a playback card on your lock screen so you can pause and skip '
        'without unlocking.',
    neverBullet: 'Send you anything else. No promotions, no reminders, ever.',
  );

  /// Android's `READ_MEDIA_AUDIO`, asked before the first library browse.
  static const JamPermissionRationale audioLibrary = JamPermissionRationale(
    icon: Icons.library_music_rounded,
    title: JamPermissionCopy.audioLibraryTitle,
    body: JamPermissionCopy.audioLibraryDetail,
    doesBullet: 'List the songs already on this phone so you can queue them.',
    neverBullet:
        'Upload your library, or look at it while you are not picking a '
        'track.',
  );

  /// The camera, asked before the first QR scan.
  static const JamPermissionRationale camera = JamPermissionRationale(
    icon: Icons.qr_code_scanner_rounded,
    title: JamPermissionSheetStrings.cameraTitle,
    body: JamPermissionSheetStrings.cameraDetail,
    doesBullet: "Read a room's QR code, which is how you join without typing.",
    neverBullet: 'Record, keep or send anything the camera sees.',
  );

  /// The rationale for a [JamPermissionKind], so `util/permissions.dart` can
  /// name a permission without importing any widget.
  static JamPermissionRationale forKind(JamPermissionKind kind) =>
      switch (kind) {
        JamPermissionKind.localNetwork => localNetwork,
        JamPermissionKind.localNetworkApple => localNetworkApple,
        JamPermissionKind.notifications => notifications,
        JamPermissionKind.audioLibrary => audioLibrary,
        JamPermissionKind.camera => camera,
      };
}

/// Strings this sheet owns, because they have no home in `permissions.dart`.
abstract final class JamPermissionSheetStrings {
  static const String continueLabel = 'Continue';
  static const String dismissLabel = 'Not now';

  /// The single-button variant, for a sheet that only announces something.
  static const String gotItLabel = 'Got it';
  static const String doesHeading = 'What we do';
  static const String neverHeading = 'What we never do';

  static const String cameraTitle = 'Point the camera at a code';
  static const String cameraDetail =
      'Joining a jam means reading the room’s QR code. The camera opens '
      'only while the scanner is on screen.';
}

/// Shows the rationale and resolves to whether the user wants to go on.
///
/// True means "ask the OS now"; false means they said not now, or swiped the
/// sheet away — the same answer, deliberately, because a dismissed rationale
/// is not consent.
Future<bool> showJamPermissionSheet(
  BuildContext context,
  JamPermissionRationale rationale,
) async =>
    await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      elevation: 0,
      showDragHandle: false,
      constraints: const BoxConstraints(maxWidth: 640),
      builder: (context) => JamPermissionSheet(rationale: rationale),
    ) ??
    false;

/// The rationale sheet's body. Pops true for Continue, false for Not now.
class JamPermissionSheet extends StatelessWidget {
  const JamPermissionSheet({super.key, required this.rationale});

  final JamPermissionRationale rationale;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    const radius = BorderRadius.vertical(top: Radius.circular(JamRadius.xl));

    return DecoratedBox(
      decoration: BoxDecoration(color: colors.elevated, borderRadius: radius),
      child: Material(
        color: Colors.transparent,
        clipBehavior: Clip.antiAlias,
        shape: const RoundedRectangleBorder(borderRadius: radius),
        child: SafeArea(
          top: false,
          child: JamSheetScaffold(
            header: const SizedBox.shrink(),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(
                JamSpace.xl,
                JamSpace.xxl,
                JamSpace.xl,
                JamSpace.xl,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      color: colors.tintFill,
                      borderRadius: BorderRadius.circular(JamRadius.lg),
                    ),
                    child: Icon(
                      rationale.icon,
                      size: 32,
                      color: colors.tint,
                      semanticLabel: '',
                    ),
                  ),
                  const SizedBox(height: JamSpace.xl),
                  Semantics(
                    header: true,
                    child: Text(rationale.title, style: context.jamTitle2),
                  ),
                  const SizedBox(height: JamSpace.md),
                  Text(
                    rationale.body,
                    style: context.jamBody.copyWith(
                      color: colors.secondaryLabel,
                    ),
                  ),
                  const SizedBox(height: JamSpace.xl),
                  _Bullet(
                    icon: Icons.check_rounded,
                    tint: colors.tint,
                    heading: JamPermissionSheetStrings.doesHeading,
                    detail: rationale.doesBullet,
                  ),
                  const SizedBox(height: JamSpace.md),
                  _Bullet(
                    icon: Icons.block_rounded,
                    tint: colors.tertiaryLabel,
                    heading: JamPermissionSheetStrings.neverHeading,
                    detail: rationale.neverBullet,
                  ),
                  const SizedBox(height: JamSpace.xxl),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () => Navigator.of(context).pop(true),
                      child: Text(rationale.continueLabel),
                    ),
                  ),
                  // An empty dismiss label means there is nothing to decline
                  // (the iOS local-network sheet): one button, not a choice
                  // that does not exist.
                  if (rationale.dismissLabel.isNotEmpty) ...[
                    const SizedBox(height: JamSpace.sm),
                    Center(
                      child: TextButton(
                        onPressed: () => Navigator.of(context).pop(false),
                        child: Text(rationale.dismissLabel),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Bullet extends StatelessWidget {
  const _Bullet({
    required this.icon,
    required this.tint,
    required this.heading,
    required this.detail,
  });

  final IconData icon;
  final Color tint;
  final String heading;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    return Semantics(
      label: '$heading: $detail',
      excludeSemantics: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: JamSpace.xxs),
            child: Icon(icon, size: 20, color: tint),
          ),
          const SizedBox(width: JamSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  heading.toUpperCase(),
                  style: context.jamCaption2.copyWith(
                    color: colors.tertiaryLabel,
                  ),
                ),
                const SizedBox(height: JamSpace.xxs),
                Text(
                  detail,
                  style: context.jamSubheadline.copyWith(
                    color: context.jamColors.secondaryLabel,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
