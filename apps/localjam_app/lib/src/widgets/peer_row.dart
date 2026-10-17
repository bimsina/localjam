/// A person in the room.
///
/// The People sheet is the one place faces get names, roles and a state of
/// their own, so this row carries all three: the ring says whose device this
/// is and who owns the room, the badge says what they may do, and the detail
/// line says whether they can actually hear the current track.
///
/// Engine-free: map `JamPermissions.roleOf` and `MediaReadiness` to the plain
/// enums below at the call site.
library;

import 'package:flutter/material.dart';

import '../design/tokens.dart';
import '../design/typography.dart';
import 'avatar.dart';

/// Strings this row can put in front of a person.
abstract final class JamPeerRowStrings {
  static const String host = 'HOST';
  static const String cohost = 'CO-HOST';
  static const String listening = 'Listening';
  static const String fetching = 'Getting the track';
  static const String missing = 'Missing the track';
  static const String more = 'More options for';
}

/// The fixed row height.
const double kJamPeerRowHeight = 64;

const double _avatarSize = JamAvatarSize.sheet;
const double _menuSize = 44;
const double _readinessRing = 16;

/// What a person may do in the room — the presentational half of
/// `JamPermissions.roleOf`.
enum JamPeerRole { guest, cohost, host }

/// Whether a person has the current track yet — the presentational half of
/// `MediaReadiness`.
enum JamPeerReadiness { ready, fetching, missing }

/// One person: their face, their name, their standing, their readiness.
class JamPeerRow extends StatelessWidget {
  const JamPeerRow({
    super.key,
    required this.name,
    this.detail,
    this.role = JamPeerRole.guest,
    this.isYou = false,
    this.readiness,
    this.fetchProgress,
    this.showMenu = false,
    this.onMenuTap,
    this.onTap,
    this.dimmed = false,
    this.contentPadding = const EdgeInsets.symmetric(horizontal: JamSpace.page),
  });

  /// Display name — the face's colour and initials come from it.
  final String name;

  /// The line under the name when there is no [readiness] to report.
  final String? detail;

  /// Host, co-host or guest. Drives the badge and the host ring.
  final JamPeerRole role;

  /// Whether this row is this device. Rings apricot, and wins over [role]'s
  /// ring: you are you first.
  final bool isYou;

  /// Whether this person has the current track. Replaces [detail].
  final JamPeerReadiness? readiness;

  /// Their fetch progress, 0–1, while [readiness] is
  /// [JamPeerReadiness.fetching]. Null draws an indeterminate ring.
  final double? fetchProgress;

  /// Whether to offer the overflow menu. Hosts only — gate it on
  /// `manageMembers` at the call site.
  final bool showMenu;

  final VoidCallback? onMenuTap;
  final VoidCallback? onTap;

  /// Renders faded, for someone who is reconnecting or has left.
  final bool dimmed;

  /// Horizontal insets.
  final EdgeInsets contentPadding;

  /// The badge text for [role], or null for a plain guest.
  static String? badgeFor(JamPeerRole role) => switch (role) {
    JamPeerRole.host => JamPeerRowStrings.host,
    JamPeerRole.cohost => JamPeerRowStrings.cohost,
    JamPeerRole.guest => null,
  };

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final badge = badgeFor(role);

    Widget person = Semantics(
      button: onTap != null,
      label: _semanticLabel(),
      child: ExcludeSemantics(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Row(
            children: [
              JamAvatar(
                name: name,
                size: _avatarSize,
                ring: isYou
                    ? JamAvatarRing.you
                    : role == JamPeerRole.host
                    ? JamAvatarRing.host
                    : JamAvatarRing.none,
              ),
              const SizedBox(width: JamSpace.md),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.jamRowTitle,
                    ),
                    ..._detailLine(context, colors),
                  ],
                ),
              ),
              if (badge != null) ...[
                const SizedBox(width: JamSpace.sm),
                _RoleBadge(text: badge),
              ],
            ],
          ),
        ),
      ),
    );
    if (dimmed) person = Opacity(opacity: 0.5, child: person);

    return SizedBox(
      height: kJamPeerRowHeight,
      child: Padding(
        padding: contentPadding,
        child: Row(
          children: [
            Expanded(child: person),
            if (showMenu)
              SizedBox(
                width: _menuSize,
                height: _menuSize,
                child: IconButton(
                  onPressed: onMenuTap,
                  iconSize: 20,
                  padding: EdgeInsets.zero,
                  tooltip: '${JamPeerRowStrings.more} $name',
                  icon: Icon(
                    Icons.more_horiz_rounded,
                    color: colors.textSecondary,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Readiness outranks [detail]: whether someone can hear this track is the
  /// only thing about them worth a line of its own.
  List<Widget> _detailLine(BuildContext context, JamColors colors) {
    final text = _detailText();
    if (text == null) return const [];
    final color = switch (readiness) {
      JamPeerReadiness.fetching => colors.warning,
      JamPeerReadiness.missing => colors.danger,
      _ => colors.textSecondary,
    };
    return [
      const SizedBox(height: JamSpace.xxs),
      Row(
        children: [
          if (readiness == JamPeerReadiness.fetching) ...[
            SizedBox(
              width: _readinessRing,
              height: _readinessRing,
              child: CircularProgressIndicator(
                value: fetchProgress?.clamp(0.0, 1.0),
                strokeWidth: 2,
                backgroundColor: colors.surfaceMuted,
                valueColor: AlwaysStoppedAnimation<Color>(colors.warning),
              ),
            ),
            const SizedBox(width: JamSpace.sm),
          ],
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.jamFootnote.copyWith(color: color),
            ),
          ),
        ],
      ),
    ];
  }

  String? _detailText() => switch (readiness) {
    JamPeerReadiness.ready => JamPeerRowStrings.listening,
    JamPeerReadiness.fetching => JamPeerRowStrings.fetching,
    JamPeerReadiness.missing => JamPeerRowStrings.missing,
    null => detail,
  };

  String _semanticLabel() {
    final parts = <String>[name];
    final badge = badgeFor(role);
    if (badge != null) parts.add(badge);
    final detailText = _detailText();
    if (detailText != null && detailText.isNotEmpty) parts.add(detailText);
    return parts.join(', ');
  }
}

/// The HOST / CO-HOST chip.
class _RoleBadge extends StatelessWidget {
  const _RoleBadge({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: JamSpace.sm,
        vertical: JamSpace.xs,
      ),
      decoration: BoxDecoration(
        color: colors.accentSoft,
        borderRadius: BorderRadius.circular(JamRadius.pill),
      ),
      child: Text(
        text,
        style: context.jamCaption.copyWith(color: colors.accent),
      ),
    );
  }
}
