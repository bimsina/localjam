/// A person in the room (DESIGN_SPEC v3 §6.5).
///
/// An ordinary list row: a 40 avatar, the name, and a subtitle only when it
/// says something — "Host", "You", "Host · You", "Co-host", what the host
/// changed for this person ("Can’t add songs"), or, in `warning`, that they
/// are still loading the song. No pills, no rings, no "Listening": a person
/// who is simply fine gets a name and nothing else (§1.2).
///
/// The host gets a trailing "•••" pull-down per guest ([JamPeerRow.menu]).
///
/// Engine-free: map `JamPermissions.roleOf` and `MediaReadiness` to the plain
/// enums below at the call site.
library;

import 'package:flutter/cupertino.dart';

import '../design/tokens.dart';
import 'avatar.dart';
import 'list.dart';
import 'menu.dart';

/// Strings this row can put in front of a person.
abstract final class JamPeerRowStrings {
  static const String host = 'Host';
  static const String cohost = 'Co-host';
  static const String you = 'You';

  /// The one warning a person row carries: they cannot hear this song yet.
  static const String loading = 'Still loading songs…';
  static String loadingProgress(int percent) =>
      'Still loading songs… $percent%';

  /// Joins the parts of a subtitle: "Host · You".
  static const String joiner = ' · ';

  /// The "•••" button's spoken name.
  static String more(String name) => 'More for $name';
}

/// What a person may do in the room — the presentational half of
/// `JamPermissions.roleOf`.
enum JamPeerRole { guest, cohost, host }

/// Whether a person has the current track yet — the presentational half of
/// `MediaReadiness`.
enum JamPeerReadiness { ready, fetching, missing }

/// One person: face, name, and at most one quiet line about them.
class JamPeerRow extends StatelessWidget implements JamSelfSeparatingRow {
  const JamPeerRow({
    super.key,
    required this.name,
    this.role = JamPeerRole.guest,
    this.isYou = false,
    this.detail,
    this.readiness,
    this.fetchProgress,
    this.menu,
    this.trailing,
    this.dimmed = false,
    this.onTap,
    this.colorKey,
  });

  /// Display name — the face's initials come from it (and its colour, when
  /// there is no [colorKey]).
  final String name;

  /// A stable id for the face's colour (`JamAvatar.colorKey`): the peer id,
  /// which every device in the jam sees the same.
  final String? colorKey;

  /// Host, co-host or guest. Host and co-host are said in the subtitle.
  final JamPeerRole role;

  /// Whether this row is this device ("You").
  final bool isYou;

  /// Extra words after the role ("Can’t add songs"), sentence case.
  final String? detail;

  /// Whether this person has the current track. Anything but ready replaces
  /// the subtitle with the loading line in `warning`.
  final JamPeerReadiness? readiness;

  /// Their fetch progress, 0–1, while [readiness] is fetching.
  final double? fetchProgress;

  /// The host's per-guest pull-down. Null: no "•••".
  final List<List<JamMenuItem>>? menu;

  /// Any other trailing control (used when [menu] is null).
  final Widget? trailing;

  /// Fades the face — someone who is not in the room right now.
  final bool dimmed;

  final VoidCallback? onTap;

  /// Whether the subtitle is the loading warning.
  bool get isLoading =>
      readiness == JamPeerReadiness.fetching ||
      readiness == JamPeerReadiness.missing;

  /// The subtitle, or null when there is nothing worth saying.
  String? get subtitle {
    if (isLoading) {
      final progress = fetchProgress;
      if (readiness == JamPeerReadiness.fetching && progress != null) {
        final percent = (progress.clamp(0.0, 1.0) * 100).round();
        return JamPeerRowStrings.loadingProgress(percent);
      }
      return JamPeerRowStrings.loading;
    }
    final parts =
        <String>[
            if (role == JamPeerRole.host) JamPeerRowStrings.host,
            if (role == JamPeerRole.cohost) JamPeerRowStrings.cohost,
            if (isYou) JamPeerRowStrings.you,
            if (detail != null && detail!.isNotEmpty) detail!,
          ]
          // A host who shared no name is titled "Host" already.
          ..remove(name);
    return parts.isEmpty ? null : parts.join(JamPeerRowStrings.joiner);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final menu = this.menu;
    return JamRow(
      title: name,
      subtitle: subtitle,
      subtitleColor: isLoading ? colors.warning : null,
      subtitleMaxLines: 1,
      // The name is the row's title; the face must not say it twice.
      leading: ExcludeSemantics(
        child: JamAvatar(
          name: name,
          colorKey: colorKey,
          size: JamAvatarSize.sheet,
          dimmed: dimmed,
        ),
      ),
      leadingWidth: JamAvatarSize.sheet,
      trailing: menu != null
          // A quiet "•••": tint is for the one primary action, and a column
          // of raspberry circles would outshout the names.
          ? JamMenuButton(
              groups: menu,
              semanticLabel: JamPeerRowStrings.more(name),
              icon: CupertinoIcons.ellipsis,
              iconColor: colors.secondaryLabel,
            )
          : trailing,
      onTap: onTap,
    );
  }
}
