/// Why LocalJam is about to ask the OS for something (DESIGN_SPEC v3 §6.6).
///
/// Shown *before* the system prompt and never after a denial — once the OS has
/// said no for good, the only honest thing left is a route into Settings, and
/// that is a notice's job, not this sheet's. Contextual only, never chained
/// after onboarding.
///
/// The look is a privacy primer: a [JamIconSize.hero] outline glyph in
/// `secondaryLabel` (raspberry is for what can be tapped, and the glyph
/// cannot — the same rule as every empty state), a centred title2 title and
/// body in balanced lines, two short left-aligned rows wrapped at their full
/// measure — what LocalJam does with the permission and what it never does,
/// each with its own heading — then **Continue** (filled) and **Not Now**
/// (plain), as wide as every other sheet's buttons.
///
/// All of the sheet's words live here: each says one thing once.
library;

import 'dart:math' as math;

import 'package:flutter/cupertino.dart';

import '../design/tokens.dart';
import '../design/typography.dart';
import '../util/permissions.dart';
import 'buttons.dart';
import 'sheet.dart';
import 'wifi_glyph.dart';

/// One permission's case.
///
/// A value rather than a widget so a screen can decide *whether* to ask
/// without building anything, and so the copy stays testable.
@immutable
class JamPermissionRationale {
  const JamPermissionRationale({
    this.icon,
    required this.title,
    required this.body,
    required this.doesBullet,
    required this.neverBullet,
    this.continueLabel = JamPermissionSheetStrings.continueLabel,
    this.dismissLabel = JamPermissionSheetStrings.dismissLabel,
    this.doesHeading = JamPermissionSheetStrings.doesHeading,
    this.neverHeading = JamPermissionSheetStrings.neverHeading,
  });

  /// The hero glyph, in `secondaryLabel`. Null: the network's own glyph,
  /// [JamWifiGlyph] — CupertinoIcons draws Wi‑Fi only as a solid wedge,
  /// beside the outline glyphs every other primer and empty state shows.
  final IconData? icon;

  /// Sentence case, title2.
  final String title;

  /// The body sentence(s).
  final String body;

  /// What LocalJam does with it, in one sentence under [doesHeading].
  final String doesBullet;

  /// What LocalJam never does, under [neverHeading]. The half people
  /// actually want to read.
  final String neverBullet;

  /// The promise rows' headings, sentence case — specific to the permission,
  /// so no two primers read the same.
  final String doesHeading;
  final String neverHeading;

  final String continueLabel;

  /// Empty when there is nothing to decline (one button).
  final String dismissLabel;

  /// The two local-network promises, shared by the Android rationale and the
  /// Apple one: the same permission and the same promise.
  static const String _localNetworkDoesHeading = 'Finds phones nearby';
  static const String _localNetworkDoes =
      'Phones in the jam find each other and play every song in time.';
  static const String _localNetworkNeverHeading = 'Stays off the internet';
  static const String _localNetworkNever =
      'A jam never leaves the network you’re on.';

  /// Android 17's `ACCESS_LOCAL_NETWORK`, asked before hosting or joining.
  static const JamPermissionRationale localNetwork = JamPermissionRationale(
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
  /// either way the moment the first socket opens, and a "Not now" that
  /// cannot stop it would be a lie.
  static const JamPermissionRationale localNetworkApple =
      JamPermissionRationale(
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
    doesHeading: 'Playback on the lock screen',
    doesBullet: 'The song and its controls, while a jam plays.',
    neverHeading: 'Nothing else',
    neverBullet: 'No promotions, no reminders.',
  );

  /// Android's `READ_MEDIA_AUDIO`, asked before the first library browse.
  static const JamPermissionRationale audioLibrary = JamPermissionRationale(
    icon: CupertinoIcons.music_albums,
    title: JamPermissionSheetStrings.audioLibraryTitle,
    body: JamPermissionSheetStrings.audioLibraryBody,
    doesHeading: 'Only while you pick',
    doesBullet: 'LocalJam looks at your songs only to show you the list.',
    neverHeading: 'Nothing uploaded',
    neverBullet: 'Songs you don’t add never leave this phone.',
  );

  /// The same permission, asked by turning on "Share my music library".
  ///
  /// Not the picker's promise: sharing publishes the library's titles,
  /// artists and covers to the jam, so "nothing leaves this phone" would be
  /// false. It says what is shared, with whom, and for how long.
  static const JamPermissionRationale audioLibraryShare =
      JamPermissionRationale(
        icon: CupertinoIcons.music_house,
        title: JamPermissionSheetStrings.audioLibraryShareTitle,
        body: JamPermissionSheetStrings.audioLibraryShareBody,
        doesHeading: 'Only while the jam runs',
        doesBullet:
            'People in this jam see each song’s title, artist and cover. '
            'Sharing stops when the jam ends.',
        neverHeading: 'Only the songs that play',
        neverBullet:
            'A song is sent to their phones only once it’s added to the '
            'queue.',
      );

  /// The camera, asked before the first QR scan.
  static const JamPermissionRationale camera = JamPermissionRationale(
    icon: CupertinoIcons.qrcode_viewfinder,
    title: JamPermissionSheetStrings.cameraTitle,
    body: JamPermissionSheetStrings.cameraDetail,
    doesHeading: 'Only while scanning',
    doesBullet: 'The camera is on only while the scanner is open.',
    neverHeading: 'Nothing saved',
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
        JamPermissionKind.audioLibraryShare => audioLibraryShare,
        JamPermissionKind.camera => camera,
      };
}

/// Strings this sheet owns.
abstract final class JamPermissionSheetStrings {
  static const String continueLabel = 'Continue';
  static const String dismissLabel = 'Not now';

  /// The single-button variant, for a sheet that only announces something.
  static const String gotItLabel = 'Continue';

  /// The promise rows' fallback headings, for a rationale that names none.
  static const String doesHeading = 'What LocalJam does';
  static const String neverHeading = 'What LocalJam never does';

  static const String localNetworkTitle = 'Let LocalJam use this network';
  static const String localNetworkBody =
      'A jam plays between phones on the same Wi‑Fi or hotspot.';
  static const String localNetworkAppleBody =
      'A jam plays between phones on the same Wi‑Fi or hotspot. Next, the '
      'system will ask to let LocalJam find them.';

  static const String notificationsTitle = 'Show the playback card';
  static const String notificationsBody =
      'Pause and skip from the lock screen without unlocking. Music still '
      'plays if you say no.';

  static const String audioLibraryTitle = 'Reach your music';
  static const String audioLibraryBody =
      'Pick songs that are already on this phone and add them to a jam.';

  static const String audioLibraryShareTitle = 'Share your music library';
  static const String audioLibraryShareBody =
      'Let people in this jam browse the songs on this phone.';

  static const String cameraTitle = 'Scan to join';
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
                        child: Center(
                          child: rationale.icon == null
                              ? const JamWifiGlyph()
                              : Icon(
                                  rationale.icon,
                                  size: JamIconSize.hero,
                                  color: colors.secondaryLabel,
                                ),
                        ),
                      ),
                      const SizedBox(height: JamSpace.lg),
                      Semantics(
                        header: true,
                        child: JamWholeWords(
                          child: Text(
                            rationale.title,
                            textAlign: TextAlign.center,
                            style: context.jamTitle2,
                          ),
                        ),
                      ),
                      const SizedBox(height: JamSpace.sm),
                      // Balanced: no line ends on one word ("code.").
                      JamBalancedText(
                        rationale.body,
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

/// The promise glyph: a row icon (22) in its 30 box, so it marks the row
/// rather than competing with the 17 pt heading beside it.
const double _promiseIcon = JamMetrics.rowIcon;
const double _promiseIconBox = JamMetrics.rowIconBox;

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
                // Wrapped at the full column, not balanced: balancing a
                // left-aligned line under a heading only leaves a ragged
                // half-width edge, and siblings at different measures.
                _UnorphanedText(
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

/// Left-aligned text wrapped at its full measure, except that a last line
/// holding one word alone ("…the network you’re / on.") takes the word
/// before it along: the line above ends one word early, and nothing else
/// moves. CSS calls it `text-wrap: pretty`.
class _UnorphanedText extends StatelessWidget {
  const _UnorphanedText(this.data, {required this.style});

  final String data;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final direction = Directionality.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    return LayoutBuilder(
      builder: (context, constraints) => Align(
        alignment: AlignmentDirectional.topStart,
        child: SizedBox(
          width: _widthFor(constraints.maxWidth, direction, scaler),
          child: Text(data, style: style),
        ),
      ),
    );
  }

  double _widthFor(double max, TextDirection direction, TextScaler scaler) {
    if (!max.isFinite) return max;
    TextPainter laidOut(double width) => TextPainter(
      text: TextSpan(text: data, style: style),
      textDirection: direction,
      textScaler: scaler,
    )..layout(maxWidth: width);
    // Whether the last line holds more than one word; null when there is
    // only one line.
    (int, bool) shape(TextPainter painter) {
      final lines = painter.computeLineMetrics().length;
      final last = painter.getLineBoundary(TextPosition(offset: data.length));
      return (lines, data.substring(last.start, last.end).trim().contains(' '));
    }

    final full = laidOut(max);
    final (lines, company) = shape(full);
    full.dispose();
    if (lines < 2 || company) return max;
    // Narrow a step at a time until the last word has company, as long as
    // the text keeps its number of lines and most of its measure.
    final step = math.max(4.0, max / 48);
    for (var width = max - step; width >= max * 0.6; width -= step) {
      final painter = laidOut(width);
      final (narrowLines, narrowCompany) = shape(painter);
      painter.dispose();
      if (narrowLines != lines) return max;
      if (narrowCompany) return width;
    }
    return max;
  }
}
