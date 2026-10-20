/// The jam mark (D4): one object for "a jam", everywhere a jam appears —
/// Nearby, Recent and Past Jams, a past jam's page, the Invite sheet and the
/// page a jam ends on.
///
/// **Circles are people, squares are music.** A jam is music, so it is a
/// rounded square with continuous corners, the same family (and the same
/// radius steps, [JamRadius.artwork]) as a cover: a jam with art and a jam
/// without are the same object. It can wear one face — its host's — as a
/// small badge on its bottom-right corner, knocked out of the tile by a real
/// gap rather than a painted ring.
///
/// What it shows, in order:
///
/// 1. **Covers**, when known: four or more make a 2×2 mosaic, otherwise the
///    first fills the tile.
/// 2. Otherwise a **monogram**: the first letter of the jam's name in
///    Manrope, `secondaryLabel` on `fillSecondary`. Never a person's colour,
///    never raspberry, never a music note (that is a *song* without art).
///
/// ```dart
/// JamMark(name: room.name, size: JamMarkSize.nearby)                       // Nearby: monogram only
/// JamMark(name: record.sessionName, size: JamMarkSize.row, covers: covers) // Past Jams
/// JamMark(name: jam, size: JamMarkSize.row, covers: [cover], hostName: host) // Invite
/// ```
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../design/tokens.dart';
import 'avatar.dart';

/// The sizes a jam mark is drawn at.
abstract final class JamMarkSize {
  /// A Nearby row.
  static const double nearby = 44;

  /// A Recent row on Home.
  static const double recent = 48;

  /// A Past Jams row; the Invite sheet's identity row.
  static const double row = 56;

  /// The page a jam ends on.
  static const double ended = 88;

  /// A past jam's own page (no host badge at this size).
  static const double detail = 200;
}

/// The gap a host badge keeps from the tile it is knocked out of.
const double kJamMarkBadgeGap = 2;

/// A jam: its covers, or its monogram, with an optional host face.
class JamMark extends StatelessWidget {
  const JamMark({
    super.key,
    required this.name,
    this.size = JamMarkSize.nearby,
    this.covers = const [],
    this.hostName,
    this.hostColor,
    this.semanticLabel,
    this.shadow = false,
  });

  /// The jam's name: where the monogram comes from.
  final String name;

  /// The tile's edge — see [JamMarkSize].
  final double size;

  /// The jam's covers, in queue order. Empty: the monogram.
  final List<ImageProvider> covers;

  /// The host's display name, when it is really known (a live jam, a past
  /// jam you hosted, a Nearby jam whose name says whose it is). Null: no
  /// badge — never a guess.
  final String? hostName;

  /// The host face's colour when the jam has assigned one
  /// (`jamAvatarColors`); otherwise their name's own.
  final Color? hostColor;

  /// Announced as an image when given; otherwise the mark is decorative
  /// (it sits beside the jam's name, which says it already).
  final String? semanticLabel;

  /// `JamShadow.artwork` under the tile — large marks only.
  final bool shadow;

  /// The host badge's diameter for a mark [size] across.
  static double badgeSizeFor(double size) =>
      (size * 0.42).roundToDouble().clamp(16.0, 36.0);

  /// The letter a jam called [name] is marked with: its first letter or
  /// digit, upper-cased; null when it has none.
  static String? monogramOf(String name) {
    final letter = RegExp(r'[\p{L}\p{N}]', unicode: true);
    for (final c in name.characters) {
      if (letter.hasMatch(c)) return c.toUpperCase();
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final shape = RoundedSuperellipseBorder(
      borderRadius: BorderRadius.circular(JamRadius.artwork(size)),
    );
    final host = hostName?.trim();
    final badge = host == null || host.isEmpty ? null : badgeSizeFor(size);
    final inset = size * 0.08;

    final Widget content;
    final Object contentKey;
    if (covers.isEmpty) {
      content = _Monogram(name: name, size: size);
      contentKey = 'monogram';
    } else if (covers.length < 4) {
      content = Image(
        image: covers.first,
        width: size,
        height: size,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => _Monogram(name: name, size: size),
      );
      contentKey = covers.first;
    } else {
      final half = size / 2;
      Widget quad(ImageProvider image) => Image(
        image: image,
        width: half,
        height: half,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) =>
            SizedBox.square(dimension: half, child: const SizedBox.shrink()),
      );
      content = Column(
        children: [
          Row(children: [quad(covers[0]), quad(covers[1])]),
          Row(children: [quad(covers[2]), quad(covers[3])]),
        ],
      );
      contentKey = Object.hashAll(covers.take(4));
    }

    Widget tile = DecoratedBox(
      decoration: ShapeDecoration(color: colors.fillSecondary, shape: shape),
      child: SizedBox.square(
        dimension: size,
        child: AnimatedSwitcher(
          duration: reduceMotion ? Duration.zero : JamDuration.base,
          switchInCurve: JamCurve.standard,
          child: KeyedSubtree(
            key: ValueKey<Object>(contentKey),
            child: content,
          ),
        ),
      ),
    );
    tile = ClipPath(
      clipper: _MarkClipper(
        shape: shape,
        badge: badge == null
            ? null
            : Rect.fromCircle(
                center: Offset(size - inset, size - inset),
                radius: badge / 2 + kJamMarkBadgeGap,
              ),
      ),
      child: tile,
    );
    if (shadow) {
      tile = DecoratedBox(
        decoration: ShapeDecoration(shape: shape, shadows: JamShadow.artwork),
        child: tile,
      );
    }

    Widget mark = tile;
    if (badge != null) {
      mark = SizedBox.square(
        dimension: size,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            tile,
            Positioned(
              left: size - inset - badge / 2,
              top: size - inset - badge / 2,
              child: JamAvatar(name: host!, size: badge, color: hostColor),
            ),
          ],
        ),
      );
    }

    final label = semanticLabel;
    if (label == null) return ExcludeSemantics(child: mark);
    return Semantics(
      label: label,
      image: true,
      child: ExcludeSemantics(child: mark),
    );
  }
}

/// The letter on `fillSecondary`, or the LocalJam symbol for a name with no
/// letter in it.
class _Monogram extends StatelessWidget {
  const _Monogram({required this.name, required this.size});

  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final ink = context.jamColors.secondaryLabel;
    final letter = JamMark.monogramOf(name);
    return Center(
      child: letter == null
          ? SvgPicture.asset(
              'assets/brand/logo.svg',
              width: size * 0.46,
              height: size * 0.46,
              colorFilter: ColorFilter.mode(ink, BlendMode.srcIn),
            )
          : Text(
              letter,
              maxLines: 1,
              textScaler: TextScaler.noScaling,
              style: TextStyle(
                fontFamily: 'Manrope',
                fontSize: size * 0.46,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.02 * size,
                height: 1,
                color: ink,
                decoration: TextDecoration.none,
              ),
            ),
    );
  }
}

/// Clips the tile to its shape, less a circle around the host badge.
class _MarkClipper extends CustomClipper<Path> {
  const _MarkClipper({required this.shape, this.badge});

  final ShapeBorder shape;

  /// The badge's knock-out, gap included.
  final Rect? badge;

  @override
  Path getClip(Size size) {
    final own = shape.getOuterPath(Offset.zero & size);
    final hole = badge;
    if (hole == null) return own;
    return Path.combine(PathOperation.difference, own, Path()..addOval(hole));
  }

  @override
  bool shouldReclip(_MarkClipper oldClipper) =>
      oldClipper.shape != shape || oldClipper.badge != badge;
}
