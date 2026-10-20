/// The jam mark (D4): one object for "a jam", everywhere a jam appears —
/// Nearby, Recent and Past Jams, a past jam's page, the Invite sheet, the
/// page a jam ends on and the empty room.
///
/// **Circles are people, squares are music.** A jam is music, so it is a
/// rounded square with continuous corners, the same family (and the same
/// radius steps, [JamRadius.artwork]) as a cover: a jam with art and a jam
/// without are the same object. It can wear one face — its host's — as a
/// small badge on its bottom-right corner, knocked out of the tile (and out
/// of its shadow) by a real gap rather than a painted ring.
///
/// What it shows, in order:
///
/// 1. **One cover**, when one is known: the jam's first song with art (R4 —
///    one cover per jam, never a mosaic).
/// 2. Otherwise a **monogram**: the first letter or digit of the jam's name
///    in Manrope, `secondaryLabel` on `fill`. Never a person's colour, never
///    raspberry, never a music note (that is a *song* without art).
///
/// **The host's face (R5)** only where it tells you something: a jam hosted
/// by someone other than you, on the Invite identity row and the page a jam
/// ends on. Never on a list row (Nearby, Recent, Past Jams), never your own
/// face, never guessed from the jam's name. Pass [JamMark.hostName] only
/// then.
///
/// ```dart
/// JamMark(name: room.name, size: JamMarkSize.nearby)                         // Nearby: monogram only
/// JamMark(name: record.sessionName, size: JamMarkSize.row, covers: [cover])  // Past Jams
/// JamMark(name: jam, size: JamMarkSize.row, covers: [cover], hostName: host) // Invite, as a guest
/// JamMark(name: jam, size: 332, onBackdrop: true)                            // the empty room
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

  /// A past jam's row (Past Jams, Home's Recent); the Invite sheet's
  /// identity row.
  static const double row = 56;

  /// The page a jam ends on.
  static const double ended = 88;

  /// A past jam's own page (no host badge at this size).
  static const double detail = 200;
}

/// The gap a host badge keeps from the tile it is knocked out of.
const double kJamMarkBadgeGap = 2;

/// A jam: its cover, or its monogram, with an optional host face.
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
    this.onBackdrop = false,
  });

  /// The jam's name: where the monogram comes from.
  final String name;

  /// The tile's edge — see [JamMarkSize].
  final double size;

  /// The jam's covers, in queue order: the first is the one shown (R4).
  /// Empty: the monogram.
  final List<ImageProvider> covers;

  /// The host's display name — only for a jam hosted by someone other than
  /// you, on the Invite identity row or the page a jam ends on (R5). Null:
  /// no badge — never a guess.
  final String? hostName;

  /// The host face's colour when the jam has assigned one
  /// (`jamPeopleColors`); otherwise their name's own.
  final Color? hostColor;

  /// Announced as an image when given; otherwise the mark is decorative
  /// (it sits beside the jam's name, which says it already).
  final String? semanticLabel;

  /// `JamShadow.artwork` under the tile — large marks only. The host
  /// badge's gap is cut out of the shadow too, so the page shows through
  /// it.
  final bool shadow;

  /// Drawn on the Now Playing backdrop (the empty room): the monogram on
  /// the backdrop's own see-through ground in its placeholder white — the
  /// material a song without art sits on there — not an opaque theme tile.
  final bool onBackdrop;

  /// The host badge's diameter for a mark [size] across.
  static double badgeSizeFor(double size) =>
      (size * 0.42).roundToDouble().clamp(16.0, 36.0);

  /// The monogram's size on a mark [size] across: nearly half the tile on
  /// a list or page mark, but quiet on a cover-sized one, where half the
  /// tile would be a shout (IR-1).
  static double monogramSizeFor(double size) =>
      size <= 96 ? size * 0.46 : (size * 0.2).clamp(44.0, 72.0);

  /// The letter a jam called [name] is marked with: its first letter or
  /// digit, upper-cased; null when it has none.
  static String? monogramOf(String name) => jamFirstLetterOf(name);

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
    final ink = onBackdrop
        ? JamNowPlayingColors.placeholderGlyph
        : colors.secondaryLabel;
    final ground = onBackdrop
        ? JamNowPlayingColors.placeholderGround
        : colors.fill;

    final Widget content;
    final Object contentKey;
    if (covers.isEmpty) {
      content = _Monogram(name: name, size: size, ink: ink);
      contentKey = 'monogram';
    } else {
      content = Image(
        image: covers.first,
        width: size,
        height: size,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => _Monogram(name: name, size: size, ink: ink),
      );
      contentKey = covers.first;
    }

    // The badge's knock-out, gap included: cut from the tile and from the
    // shadow under it.
    final hole = badge == null
        ? null
        : Rect.fromCircle(
            center: Offset(size - inset, size - inset),
            radius: badge / 2 + kJamMarkBadgeGap,
          );

    Widget tile = DecoratedBox(
      decoration: ShapeDecoration(color: ground, shape: shape),
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
      clipper: _MarkClipper(shape: shape, badge: hole),
      child: tile,
    );
    if (shadow) {
      Widget cast = DecoratedBox(
        decoration: ShapeDecoration(shape: shape, shadows: JamShadow.artwork),
        child: SizedBox.square(dimension: size),
      );
      if (hole != null) {
        // Without this the blurred shadow fills the badge's gap: a grey
        // halo on paper, a black ring on charcoal (CR-2).
        cast = ClipPath(clipper: _OutsideClipper(hole), child: cast);
      }
      tile = Stack(clipBehavior: Clip.none, children: [cast, tile]);
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

/// The letter in [ink], or the LocalJam symbol for a name with no letter
/// in it.
class _Monogram extends StatelessWidget {
  const _Monogram({required this.name, required this.size, required this.ink});

  final String name;
  final double size;
  final Color ink;

  @override
  Widget build(BuildContext context) {
    final letter = JamMark.monogramOf(name);
    final glyph = JamMark.monogramSizeFor(size);
    return Center(
      child: letter == null
          ? SvgPicture.asset(
              'assets/brand/logo.svg',
              width: glyph,
              height: glyph,
              colorFilter: ColorFilter.mode(ink, BlendMode.srcIn),
            )
          : Text(
              letter,
              maxLines: 1,
              textScaler: TextScaler.noScaling,
              style: TextStyle(
                fontFamily: 'Manrope',
                fontSize: glyph,
                fontWeight: FontWeight.w700,
                letterSpacing: size <= 96 ? -0.02 * size : 0,
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

/// Everything but [hole] — wide enough for the shadow's blur and offset.
class _OutsideClipper extends CustomClipper<Path> {
  const _OutsideClipper(this.hole);

  final Rect hole;

  @override
  Path getClip(Size size) {
    final reach = (Offset.zero & size).inflate(size.shortestSide + 64);
    return Path.combine(
      PathOperation.difference,
      Path()..addRect(reach),
      Path()..addOval(hole),
    );
  }

  @override
  bool shouldReclip(_OutsideClipper oldClipper) => oldClipper.hole != hole;
}
