/// Faces (D3): a flat colour per person, white Manrope initials, no ring.
///
/// **One person, one colour, everywhere.** A face's colour is a pure
/// function of the person's *display name* ([identityColor]) — the same in
/// the room, the People sheet, every "Added by" credit, Past Jams, Settings,
/// the sidebar and the web guest's page (apps/localjam_web `Avatar`, which
/// hashes the same way into the same palette). Nothing about who *else* is
/// in the jam moves it: a guest's face no longer changes colour when
/// somebody joins, and a past jam draws everyone as the room did.
///
/// The name, not an id, because it is the one key every surface has: the
/// protocol's `clientId` never leaves the host (§3.3), peer ids are minted
/// per jam, and a history record keeps names only. The price is that two
/// people can share a colour — eight colours, any number of people — which
/// is why a face always carries initials, and two people with the same name
/// are told apart by "Sam 2" in words rather than by colour.
///
/// The derivation must be stable *across devices*, which is why it hashes
/// with FNV-1a rather than [Object.hashCode] (not stable between runs or
/// platforms). A rename repaints a person — a rename *is* how they appear.
library;

import 'package:flutter/widgets.dart';

import '../design/tokens.dart';
import '../design/typography.dart';

/// The face colours (see [JamAvatarPalette]).
const List<Color> kJamAvatarPalette = JamAvatarPalette.colors;

/// FNV-1a over UTF-16 code units: stable across runs, platforms, devices.
int _stableHash(String value) {
  var hash = 0x811c9dc5;
  for (final unit in value.codeUnits) {
    hash ^= unit;
    // × the FNV prime (2^24 + 0x193) in two halves, each well inside 2^53:
    // compiled to JavaScript the one-step product (up to 2^56) lost its low
    // bits to double rounding, and the web guest's page put nearly
    // everybody in slot 0.
    hash = (((hash << 24) & 0xFFFFFFFF) + hash * 0x193) & 0xFFFFFFFF;
  }
  return hash;
}

/// The identity colour for [name]: FNV-1a over its UTF-16 code units, into
/// [kJamAvatarPalette]. The same in both themes — [brightness] is accepted
/// for older call sites and ignored.
///
/// The web guest's page computes exactly this (apps/localjam_web
/// `avatarColorIndex`); a test on each side pins the same names to the same
/// slots, so the two cannot drift apart unnoticed.
Color identityColor(String name, [Brightness? brightness]) =>
    kJamAvatarPalette[identityColorIndex(name)];

/// [identityColor]'s slot in [kJamAvatarPalette], for [name].
int identityColorIndex(String name) =>
    _stableHash(name) % kJamAvatarPalette.length;

/// Each person's face colour, by display name (D3): [identityColor] for
/// each of [people] — nothing more. The one map every face of a jam is
/// painted from (the room's footer, the People sheet, an "Added by" face,
/// Past Jams, a jam mark's host), so a person is the same colour on every
/// screen of every phone, and on the web guest's page.
Map<String, Color> jamPeopleColors(Iterable<String> people) => {
  for (final name in people) name: identityColor(name),
};

/// The first letter or digit in [text], upper-cased — skipping emoji,
/// punctuation and symbols — or null when it has none. Faces and jam marks
/// both take their letters this way.
String? jamFirstLetterOf(String text) {
  for (final c in text.characters) {
    if (_letterOrDigit.hasMatch(c)) return c.toUpperCase();
  }
  return null;
}

final RegExp _letterOrDigit = RegExp(r'[\p{L}\p{N}]', unicode: true);

/// One or two initials for [name]: "Silky Puffin" becomes "SP". Only
/// letters and digits count (RB-21): "🎸 Mia" is "M", "(Mia)" is "M",
/// "- DJ K" is "DK"; a name with none is "?".
String identityInitials(String name) {
  final letters = [
    for (final word in name.trim().split(RegExp(r'\s+')))
      ?jamFirstLetterOf(word),
  ];
  if (letters.isEmpty) return '?';
  if (letters.length == 1) return letters.first;
  return letters.first + letters.last;
}

/// At or below this diameter a face shows one initial (spec §10.10): two
/// letters at 0.4 × 24 are under 10 pt, and a pile's overlap cuts them.
const double kJamAvatarSingleInitialMax = 24;

/// The avatar diameters the design uses.
abstract final class JamAvatarSize {
  /// The face beside "Added by Mia" on Now Playing (D6): 18, so its letter
  /// still reads (RB-17).
  static const double credit = 18;

  /// A song row's credit (the queue, a past jam's songs) and the small
  /// piles inside rows (Past Jams).
  static const double attribution = 20;

  /// The face pile on Now Playing's footer and the mini player.
  static const double strip = 24;

  /// Your avatar in the nav bar and the sidebar.
  static const double identity = 30;

  /// A row in the People sheet.
  static const double sheet = 40;

  /// The default: a face standing alone at row height.
  static const double list = 44;

  /// The profile row in Settings.
  static const double profile = 56;

  /// [size] for a face that sits in a line of text (a credit, a row's
  /// adder): it grows with the text beside it, up to 1.5× (RB-17), so a
  /// large text size never puts a dot beside a word.
  static double scaled(BuildContext context, double size) {
    final scale = MediaQuery.textScalerOf(context).scale(17) / 17;
    return size * scale.clamp(1.0, 1.5);
  }
}

/// A person: initials on their identity colour.
class JamAvatar extends StatelessWidget {
  const JamAvatar({
    super.key,
    required this.name,
    this.size = JamAvatarSize.list,
    this.dimmed = false,
    this.semanticLabel,
    this.initials,
    this.color,
    this.tokenSize,
  }) : initialsShift = 0;

  /// A face in a pile, its letters moved [initialsShift] into the part the
  /// next face leaves uncovered ([JamAvatarKnockout]). Decorative: the pile
  /// says who is in it.
  const JamAvatar.inPile({
    super.key,
    required this.name,
    required this.size,
    this.color,
    this.initialsShift = 0,
  }) : dimmed = false,
       semanticLabel = null,
       initials = null,
       tokenSize = null;

  /// The display name the initials and (without [color]) the colour derive
  /// from.
  final String name;

  /// A colour picked elsewhere — from [jamPeopleColors], which is [name]'s
  /// own. Without it, [name]'s own.
  final Color? color;

  /// Diameter — see [JamAvatarSize].
  final double size;

  /// Faded, for a peer who is reconnecting or has left.
  final bool dimmed;

  /// Overrides the announced label. Defaults to [name].
  final String? semanticLabel;

  /// Overrides the letters, keeping [name]'s colour.
  final String? initials;

  /// How far the letters sit off-centre: in a pile, into the part of the
  /// face still showing.
  final double initialsShift;

  /// For a face drawn at [JamAvatarSize.scaled] of a design size: that
  /// size. It, not the grown [size], decides one initial or two, so a
  /// person reads the same way in every face on a screen ("E" in the
  /// credit and in the pile, not "ES" in one) whatever the text size.
  final double? tokenSize;

  /// The face colour for [name].
  static Color colorFor(String name) => identityColor(name);

  /// The colour this avatar paints.
  Color get resolvedColor => color ?? colorFor(name);

  String get _letters {
    final letters = initials ?? identityInitials(name);
    if ((tokenSize ?? size) > kJamAvatarSingleInitialMax ||
        letters.characters.length < 2) {
      return letters;
    }
    return letters.characters.first;
  }

  @override
  Widget build(BuildContext context) {
    final letters = _letters;
    final single = letters.characters.length <= 1;
    Widget text = Text(
      letters,
      maxLines: 1,
      textScaler: TextScaler.noScaling,
      // The brand face (D3): Manrope, like every named thing.
      style: context.jamBody.copyWith(
        fontFamily: 'Manrope',
        fontSize: size * (single ? 0.45 : 0.4),
        fontWeight: FontWeight.w700,
        color: JamAvatarPalette.initials,
        height: 1,
        letterSpacing: 0,
      ),
    );
    if (initialsShift != 0) {
      text = Transform.translate(offset: Offset(initialsShift, 0), child: text);
    }
    Widget face = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: resolvedColor, shape: BoxShape.circle),
      child: text,
    );
    if (dimmed) face = Opacity(opacity: 0.4, child: face);

    return Semantics(
      label: semanticLabel ?? name,
      image: true,
      child: ExcludeSemantics(child: face),
    );
  }
}

/// The face pile: up to [maxVisible] overlapping faces ([overlap] 25%), each
/// knocked out of the face it covers by a [cutout] gap — a real hole, so the
/// surface behind the pile shows through (the Now Playing backdrop, a sheet)
/// rather than a painted ring guessing at its colour — then "+N" in
/// `secondaryLabel` on overflow only.
class JamAvatarStack extends StatelessWidget {
  const JamAvatarStack({
    super.key,
    required this.names,
    this.size = JamAvatarSize.strip,
    this.maxVisible = 3,
    this.overflowColor,
    this.semanticLabel,
    this.colors,
  });

  /// Display names, in room order. Without [colors] each face is its
  /// name's own colour ([identityColor]).
  final List<String> names;

  /// Colours parallel to [names], already assigned for the whole jam
  /// ([jamPeopleColors]) — for a pile whose labels are not the names the
  /// colours come from ("Sam 2").
  final List<Color>? colors;

  /// Diameter of each face.
  final double size;

  /// Faces before the "+N".
  final int maxVisible;

  /// The "+N" colour (default `secondaryLabel`).
  final Color? overflowColor;

  /// Overrides the announced label. Defaults to a spoken list of names.
  final String? semanticLabel;

  /// The share of each face the next one covers.
  static const double overlap = 0.25;

  /// The knocked-out gap around each face that covers another.
  static const double cutout = 2;

  @override
  Widget build(BuildContext context) {
    final theme = context.jamColors;
    if (names.isEmpty) return const SizedBox.shrink();

    final visible = names.take(maxVisible).toList();
    final overflow = names.length - visible.length;
    final step = size * (1 - overlap);
    final assigned = colors;
    final List<Color> palette;
    if (assigned != null && assigned.length >= visible.length) {
      palette = assigned;
    } else {
      final byName = jamPeopleColors(names);
      palette = [for (final name in visible) byName[name]!];
    }
    // A covered face's letters move to the middle of the part still showing.
    final shift = (step - cutout) / 2 - size / 2;

    final pile = SizedBox(
      width: (visible.length - 1) * step + size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (var i = 0; i < visible.length; i++)
            Positioned(
              left: i * step,
              top: 0,
              child: i == visible.length - 1
                  ? JamAvatar.inPile(
                      name: visible[i],
                      size: size,
                      color: palette[i],
                    )
                  : ClipPath(
                      clipper: JamAvatarKnockout(offset: step),
                      child: JamAvatar.inPile(
                        name: visible[i],
                        size: size,
                        color: palette[i],
                        initialsShift: shift,
                      ),
                    ),
            ),
        ],
      ),
    );

    return Semantics(
      label: semanticLabel ?? _spoken(visible, overflow),
      image: true,
      child: ExcludeSemantics(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            pile,
            if (overflow > 0) ...[
              const SizedBox(width: JamSpace.xs),
              Text(
                '+$overflow',
                style: jamTabular(
                  context.jamFootnote,
                ).copyWith(color: overflowColor ?? theme.secondaryLabel),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _spoken(List<String> visible, int overflow) {
    final tail = overflow > 0 ? ' and $overflow more' : '';
    return '${visible.join(', ')}$tail';
  }
}

/// Clips a face to itself minus the next face in a pile — [offset] to the
/// right — grown by [gap]: a real hole, so whatever is behind the pile shows
/// through. Every face pile (this one, the room's animated footer) cuts its
/// faces with it.
class JamAvatarKnockout extends CustomClipper<Path> {
  const JamAvatarKnockout({
    required this.offset,
    this.gap = JamAvatarStack.cutout,
  });

  final double offset;
  final double gap;

  @override
  Path getClip(Size size) {
    final own = Path()..addOval(Offset.zero & size);
    final r = size.width / 2;
    final next = Path()
      ..addOval(
        Rect.fromCircle(center: Offset(offset + r, r), radius: r + gap),
      );
    return Path.combine(PathOperation.difference, own, next);
  }

  @override
  bool shouldReclip(JamAvatarKnockout oldClipper) =>
      oldClipper.offset != offset || oldClipper.gap != gap;
}
