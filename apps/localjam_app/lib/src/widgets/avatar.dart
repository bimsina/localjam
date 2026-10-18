/// Faces for the room (D6): a flat colour per person, white initials, no ring.
///
/// The protocol carries only a `clientName` — no avatar, no colour — so a
/// face derives from that name, or better from a stable id
/// ([JamAvatar.colorKey]), or best from the jam's own assignment
/// ([jamAvatarColors]) so nobody in one jam shares a colour (spec §10.10).
/// The derivation must be stable *across devices*, which is why it hashes
/// with FNV-1a rather than [Object.hashCode] (not stable between runs or
/// platforms).
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
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash;
}

/// The identity colour for [name]. The same in both themes — [brightness]
/// is accepted for older call sites and ignored.
Color identityColor(String name, [Brightness? brightness]) =>
    kJamAvatarPalette[_stableHash(name) % kJamAvatarPalette.length];

/// The colour for a stable id (a peer's client id): what [JamAvatar.colorKey]
/// paints when nothing has assigned the jam's colours.
Color jamAvatarColorForKey(String key) =>
    kJamAvatarPalette[_stableHash(key) % kJamAvatarPalette.length];

/// Colours for everyone in one jam, in room order (spec §10.10).
///
/// Each id starts at its own stable slot ([jamAvatarColorForKey]) and moves
/// on to the next free palette colour when someone earlier in [keys] already
/// has it, so no two people share a colour while the palette lasts. Past
/// eight people the palette starts over. The same id always gets the same
/// colour within one call.
///
/// Pass the same ordered list everywhere the jam's faces appear (the People
/// sheet, the face pile) so a person keeps one colour across them.
List<Color> jamAvatarColors(List<String> keys) {
  const palette = kJamAvatarPalette;
  final n = palette.length;
  final byKey = <String, int>{};
  final used = <int>{};
  final out = <Color>[];
  for (final key in keys) {
    final known = byKey[key];
    if (known != null) {
      out.add(palette[known]);
      continue;
    }
    if (used.length >= n) used.clear();
    var slot = _stableHash(key) % n;
    while (used.contains(slot)) {
      slot = (slot + 1) % n;
    }
    used.add(slot);
    byKey[key] = slot;
    out.add(palette[slot]);
  }
  return out;
}

/// One or two initials for [name]: "Silky Puffin" becomes "SP".
String identityInitials(String name) {
  final words = name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
  if (words.isEmpty) return '?';
  if (words.length == 1) return words.first.characters.first.toUpperCase();
  return (words.first.characters.first + words.last.characters.first)
      .toUpperCase();
}

/// At or below this diameter a face shows one initial (spec §10.10): two
/// letters at 0.4 × 24 are under 10 pt, and a pile's overlap cuts them.
const double kJamAvatarSingleInitialMax = 24;

/// The avatar diameters the design uses.
abstract final class JamAvatarSize {
  /// Inline credits.
  static const double attribution = 20;

  /// The face pile on Now Playing's footer and the mini player.
  static const double strip = 24;

  /// Your avatar in the nav bar and the sidebar.
  static const double identity = 30;

  /// A row in the People sheet.
  static const double sheet = 40;

  /// A nearby room's host on Home.
  static const double list = 44;

  /// The profile row in Settings.
  static const double profile = 56;
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
    this.colorKey,
    this.color,
  }) : _initialsShift = 0;

  /// A face in a pile, its letters moved into the part left uncovered.
  const JamAvatar._inPile({
    required this.name,
    required this.size,
    this.color,
    this._initialsShift = 0,
  }) : dimmed = false,
       semanticLabel = null,
       initials = null,
       colorKey = null;

  /// The display name the initials (and, without [colorKey] or [color], the
  /// colour) derive from.
  final String name;

  /// A stable id (the peer's client id) to pick the colour from instead of
  /// [name], so a rename does not repaint someone.
  final String? colorKey;

  /// An assigned colour — from [jamAvatarColors], so nobody in the jam
  /// shares one. Wins over [colorKey] and [name].
  final Color? color;

  /// Diameter — see [JamAvatarSize].
  final double size;

  /// Faded, for a peer who is reconnecting or has left.
  final bool dimmed;

  /// Overrides the announced label. Defaults to [name].
  final String? semanticLabel;

  /// Overrides the letters, keeping [name]'s colour.
  final String? initials;

  final double _initialsShift;

  /// The face colour for [name].
  static Color colorFor(String name) => identityColor(name);

  /// The colour this avatar paints.
  Color get resolvedColor {
    final key = colorKey;
    return color ?? (key == null ? colorFor(name) : jamAvatarColorForKey(key));
  }

  String get _letters {
    final letters = initials ?? identityInitials(name);
    if (size > kJamAvatarSingleInitialMax || letters.characters.length < 2) {
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
      style: context.jamBody.copyWith(
        fontSize: size * (single ? 0.45 : 0.4),
        fontWeight: FontWeight.w600,
        color: JamAvatarPalette.initials,
        height: 1,
        letterSpacing: 0,
      ),
    );
    if (_initialsShift != 0) {
      text = Transform.translate(
        offset: Offset(_initialsShift, 0),
        child: text,
      );
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
    this.cutoutColor,
    this.overflowColor,
    this.semanticLabel,
    this.colorKeys,
    this.colors,
  });

  /// Display names, in room order.
  final List<String> names;

  /// Stable ids parallel to [names]. When given, the pile's colours come
  /// from [jamAvatarColors] over the whole list — distinct within the jam,
  /// and the same as anywhere else that assigns over the same list.
  final List<String>? colorKeys;

  /// Colours parallel to [names], already assigned (wins over [colorKeys]).
  final List<Color>? colors;

  /// Diameter of each face.
  final double size;

  /// Faces before the "+N".
  final int maxVisible;

  /// Ignored: the gap between faces is a true knockout, so it always shows
  /// the real surface behind the pile. Kept for older call sites.
  final Color? cutoutColor;

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
    final keys = colorKeys;
    final assigned = colors;
    final palette = assigned != null && assigned.length >= visible.length
        ? assigned
        : (keys != null && keys.length == names.length
              ? jamAvatarColors(keys)
              : null);
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
                  ? JamAvatar._inPile(
                      name: visible[i],
                      size: size,
                      color: palette?[i],
                    )
                  : ClipPath(
                      clipper: _KnockoutClipper(offset: step, gap: cutout),
                      child: JamAvatar._inPile(
                        name: visible[i],
                        size: size,
                        color: palette?[i],
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

/// Clips a face to itself minus the next face — [offset] to the right —
/// grown by [gap].
class _KnockoutClipper extends CustomClipper<Path> {
  const _KnockoutClipper({required this.offset, required this.gap});

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
  bool shouldReclip(_KnockoutClipper oldClipper) =>
      oldClipper.offset != offset || oldClipper.gap != gap;
}
