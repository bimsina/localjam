/// Why LocalJam is about to ask the OS for something (DESIGN_SPEC v3 §6.6).
///
/// Shown *before* the system prompt and never after a denial — once the OS has
/// said no for good, the only honest thing left is a route into Settings, and
/// that is a notice's job, not this sheet's. Contextual only, never chained
/// after onboarding.
///
/// The look is Apple's privacy primer: a 48 tint glyph, a title2 title, a
/// one-line body, two short rows — what LocalJam does with the permission and
/// what it never does, each with its own heading — then **Continue** (filled)
/// and **Not Now** (plain), as wide as every other sheet's buttons.
///
/// All of the sheet's words live here: each says one thing once.
library;

import 'package:flutter/cupertino.dart';

import '../design/tokens.dart';
import '../design/typography.dart';
import '../util/permissions.dart';
import 'buttons.dart';
import 'sheet.dart';

/// One permission's case.
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
    this.doesHeading = JamPermissionSheetStrings.doesHeading,
    this.neverHeading = JamPermissionSheetStrings.neverHeading,
  });

  /// The 48 tint glyph.
  final IconData icon;

  /// Title Case, title2.
  final String title;

  /// The body sentence(s).
  final String body;

  /// What LocalJam does with it, in one sentence under [doesHeading].
  final String doesBullet;

  /// What LocalJam never does, under [neverHeading]. The half people
  /// actually want to read.
  final String neverBullet;

  /// The promise rows' headings, Title Case — specific to the permission,
  /// so no two primers read the same.
  final String doesHeading;
  final String neverHeading;

  final String continueLabel;

  /// Empty when there is nothing to decline (one button).
  final String dismissLabel;

  /// The two local-network promises, shared by the Android rationale and the
  /// Apple one: the same permission and the same promise.
  static const String _localNetworkDoesHeading = 'Finds Phones Nearby';
  static const String _localNetworkDoes =
      'So everyone hears the same second of the same song.';
  static const String _localNetworkNeverHeading = 'Stays Off the Internet';
  static const String _localNetworkNever =
      'A jam never leaves the network you’re on.';

  /// Android 17's `ACCESS_LOCAL_NETWORK`, asked before hosting or joining.
  static const JamPermissionRationale localNetwork = JamPermissionRationale(
    icon: CupertinoIcons.wifi,
    title: JamPermissionSheetStrings.localNetworkTitle,
    body: JamPermissionSheetStrings.localNetworkBody,
    doesHeading: _localNetworkDoesHeading,
    doesBullet: _localNetworkDoes,
    neverHeading: _localNetworkNeverHeading,
    neverBullet: _localNetworkNever,
  );

  /// The same thing on iOS and macOS, where the system does the asking.
  ///
  /// One button, because there is nothing to decline: the OS alert is coming
  /// either way the moment the first socket opens, and a "Not Now" that
  /// cannot stop it would be a lie.
  static const JamPermissionRationale localNetworkApple =
      JamPermissionRationale(
        icon: CupertinoIcons.wifi,
        title: JamPermissionSheetStrings.localNetworkTitle,
        body: JamPermissionSheetStrings.localNetworkAppleBody,
        doesHeading: _localNetworkDoesHeading,
        doesBullet: _localNetworkDoes,
        neverHeading: _localNetworkNeverHeading,
        neverBullet: _localNetworkNever,
        continueLabel: JamPermissionSheetStrings.gotItLabel,
        dismissLabel: '',
      );

  /// Android 13+'s `POST_NOTIFICATIONS`, asked before the media card.
  static const JamPermissionRationale notifications = JamPermissionRationale(
    icon: CupertinoIcons.play_rectangle,
    title: JamPermissionSheetStrings.notificationsTitle,
    body: JamPermissionSheetStrings.notificationsBody,
    doesHeading: 'Playback on the Lock Screen',
    doesBullet: 'The song and its controls, while a jam plays.',
    neverHeading: 'Nothing Else',
    neverBullet: 'No promotions, no reminders.',
  );

  /// Android's `READ_MEDIA_AUDIO`, asked before the first library browse.
  static const JamPermissionRationale audioLibrary = JamPermissionRationale(
    icon: CupertinoIcons.music_albums,
    title: JamPermissionSheetStrings.audioLibraryTitle,
    body: JamPermissionSheetStrings.audioLibraryBody,
    doesHeading: 'Only While You Pick',
    doesBullet: 'LocalJam looks at your songs only to show you the list.',
    neverHeading: 'Nothing Uploaded',
    neverBullet: 'Songs you don’t add never leave this phone.',
  );

  /// The camera, asked before the first QR scan.
  static const JamPermissionRationale camera = JamPermissionRationale(
    icon: CupertinoIcons.qrcode_viewfinder,
    title: JamPermissionSheetStrings.cameraTitle,
    body: JamPermissionSheetStrings.cameraDetail,
    doesHeading: 'Only While Scanning',
    doesBullet: 'The camera is on only while the scanner is open.',
    neverHeading: 'Nothing Saved',
    neverBullet: 'Nothing it sees is kept or sent anywhere.',
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

/// Strings this sheet owns.
abstract final class JamPermissionSheetStrings {
  static const String continueLabel = 'Continue';
  static const String dismissLabel = 'Not Now';

  /// The single-button variant, for a sheet that only announces something.
  static const String gotItLabel = 'Continue';

  /// The promise rows' fallback headings, for a rationale that names none.
  static const String doesHeading = 'What LocalJam Does';
  static const String neverHeading = 'What LocalJam Never Does';

  static const String localNetworkTitle = 'Let LocalJam Use This Network';
  static const String localNetworkBody =
      'A jam plays between phones on the same Wi‑Fi or hotspot.';
  static const String localNetworkAppleBody =
      'A jam plays between phones on the same Wi‑Fi or hotspot. Next, the '
      'system will ask to let LocalJam find them.';

  static const String notificationsTitle = 'Show the Playback Card';
  static const String notificationsBody =
      'Pause and skip from the Lock Screen without unlocking. Music still '
      'plays if you say no.';

  static const String audioLibraryTitle = 'Reach Your Music';
  static const String audioLibraryBody =
      'Pick songs that are already on this phone and add them to a jam.';

  static const String cameraTitle = 'Scan to Join';
  static const String cameraDetail =
      'LocalJam uses the camera only to read a jam’s code.';
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
    await showJamModalSheet<bool>(
      context,
      builder: (context) => JamPermissionSheet(rationale: rationale),
    ) ??
    false;

/// The rationale sheet's body. Pops true for Continue, false for Not Now.
class JamPermissionSheet extends StatelessWidget {
  const JamPermissionSheet({super.key, required this.rationale});

  final JamPermissionRationale rationale;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    return JamSheetSurface(
      child: SafeArea(
        top: false,
        child: JamSheetScaffold(
          header: const SizedBox(height: JamSpace.sm),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(
              JamSpace.page,
              JamSpace.xxl,
              JamSpace.page,
              JamSpace.lg,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                // The words sit on a narrower measure than the buttons, as in
                // Apple's primers; the buttons match every other sheet's.
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: JamSpace.xxxl - JamSpace.page,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ExcludeSemantics(
                        child: Icon(
                          rationale.icon,
                          size: 48,
                          color: colors.tint,
                        ),
                      ),
                      const SizedBox(height: JamSpace.lg),
                      Semantics(
                        header: true,
                        child: Text(
                          rationale.title,
                          textAlign: TextAlign.center,
                          style: context.jamTitle2,
                        ),
                      ),
                      const SizedBox(height: JamSpace.sm),
                      Text(
                        rationale.body,
                        textAlign: TextAlign.center,
                        style: context.jamSubheadline.copyWith(
                          color: colors.secondaryLabel,
                        ),
                      ),
                      const SizedBox(height: JamSpace.xxl),
                      _Promise(
                        icon: CupertinoIcons.checkmark_circle,
                        heading: rationale.doesHeading,
                        detail: rationale.doesBullet,
                      ),
                      const SizedBox(height: JamSpace.lg),
                      _Promise(
                        icon: CupertinoIcons.lock,
                        heading: rationale.neverHeading,
                        detail: rationale.neverBullet,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: JamSpace.xxxl),
                JamButton.filled(
                  label: rationale.continueLabel,
                  expand: true,
                  onPressed: () => Navigator.of(context).pop(true),
                ),
                // An empty dismiss label means there is nothing to decline
                // (the Apple local-network primer): one button, not a choice
                // that does not exist.
                if (rationale.dismissLabel.isNotEmpty) ...[
                  const SizedBox(height: JamSpace.sm),
                  JamButton.plain(
                    label: rationale.dismissLabel,
                    expand: true,
                    onPressed: () => Navigator.of(context).pop(false),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The promise glyph: 28 in a 30 box, the onboarding feature rows' size.
const double _promiseIcon = 28;
const double _promiseIconBox = 30;

/// One promise: a glyph, a headline, a sentence. The glyph is
/// `secondaryLabel`, not tint — nothing here can be tapped.
class _Promise extends StatelessWidget {
  const _Promise({
    required this.icon,
    required this.heading,
    required this.detail,
  });

  final IconData icon;
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
          SizedBox(
            width: _promiseIconBox,
            child: Icon(icon, size: _promiseIcon, color: colors.secondaryLabel),
          ),
          const SizedBox(width: JamSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(heading, style: context.jamHeadline),
                const SizedBox(height: JamSpace.xxs),
                Text(
                  detail,
                  style: context.jamSubheadline.copyWith(
                    color: colors.secondaryLabel,
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
