/// Faces for the room.
///
/// The protocol carries only a `clientName` (PROTOCOL.md) — no avatar, no
/// colour, no emoji — so a face is derived from that name rather than stored.
/// The derivation has to be stable *across devices*, which is why it hashes
/// the string with FNV-1a rather than using [Object.hashCode], which Dart
/// does not guarantee between runs or platforms.
///
/// [JamAvatarStack] is the room-first form: overlapping faces read as a
/// group of people, where a spaced row reads as a data grid.
library;

import 'package:flutter/material.dart';

import '../design/tokens.dart';
import '../design/typography.dart';

/// Hue wheel positions for identity colours. Twelve well-separated hues, so
/// two people in a four-person van are very unlikely to collide.
const List<int> _hues = [8, 32, 48, 92, 140, 168, 190, 212, 248, 280, 312, 340];

/// FNV-1a over UTF-16 code units: stable across runs, platforms, and devices.
int _stableHash(String value) {
  var hash = 0x811c9dc5;
  for (final unit in value.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash;
}

/// The identity colour for [name], readable on [brightness]'s ground.
///
/// Saturation and lightness are fixed per theme so every identity lands at
/// roughly the same contrast — the hue is the only thing that varies.
/// [JamAvatar.colorFor] restates that band against the v2 palette; this is
/// the shared hue wheel underneath it.
Color identityColor(String name, Brightness brightness) {
  final hue = _hues[_stableHash(name) % _hues.length].toDouble();
  return brightness == Brightness.dark
      ? HSLColor.fromAHSL(1, hue, 0.55, 0.62).toColor()
      : HSLColor.fromAHSL(1, hue, 0.58, 0.42).toColor();
}

/// One or two initials for [name]: "Silky Puffin" becomes "SP".
String identityInitials(String name) {
  final words = name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
  if (words.isEmpty) return '?';
  if (words.length == 1) return words.first.characters.first.toUpperCase();
  return (words.first.characters.first + words.last.characters.first)
      .toUpperCase();
}

/// The avatar diameters the design uses. Anything else is a one-off and
/// should be argued for rather than typed.
abstract final class JamAvatarSize {
  /// The "added by" credit on a track row.
  static const double attribution = 20;

  /// The people strip under the player, and the room bar's stack.
  static const double strip = 24;

  /// The identity button on home and in the sidebar.
  static const double identity = 28;

  /// A list row.
  static const double list = 36;

  /// A row in the People sheet.
  static const double sheet = 44;

  /// The profile block in Settings.
  static const double profile = 56;
}

/// The ring drawn around an avatar, if any.
enum JamAvatarRing {
  /// No ring: an ordinary person in the room.
  none,

  /// The host: a raspberry ring.
  host,

  /// This device: an apricot ring.
  you,
}

/// A person, drawn as their initials on their identity colour.
class JamAvatar extends StatelessWidget {
  const JamAvatar({
    super.key,
    required this.name,
    this.size = JamAvatarSize.list,
    this.ring = JamAvatarRing.none,
    this.dimmed = false,
    this.semanticLabel,
    this.initials,
  });

  /// The display name the colour and the initials both derive from.
  final String name;

  /// Diameter, including [ring] — see [JamAvatarSize].
  final double size;

  /// Whether this face is ringed as the host's or as your own.
  final JamAvatarRing ring;

  /// Renders faded, for a peer who is reconnecting or has left.
  final bool dimmed;

  /// Overrides the announced label. Defaults to [name].
  final String? semanticLabel;

  /// Overrides the letters on the face, keeping [name]'s colour.
  ///
  /// For clusters where two letters is one letter too many — a tight
  /// overlapping group, where the face in front crops the second initial of
  /// the one behind it and both read as gibberish.
  final String? initials;

  /// The identity colour restated against the v2 palette: the hue wheel is
  /// the shared one, the saturation and lightness are this design's.
  static Color colorFor(String name, Brightness brightness) {
    final hue = HSLColor.fromColor(identityColor(name, brightness)).hue;
    return brightness == Brightness.dark
        ? HSLColor.fromAHSL(1, hue, 0.50, 0.66).toColor()
        : HSLColor.fromAHSL(1, hue, 0.52, 0.44).toColor();
  }

  /// The initials colour that sits on [colorFor].
  static Color initialsColorFor(Brightness brightness) =>
      brightness == Brightness.dark ? const Color(0xFF150A19) : Colors.white;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final brightness = Theme.of(context).brightness;
    final ringColor = switch (ring) {
      JamAvatarRing.none => null,
      JamAvatarRing.host => colors.hostRing,
      JamAvatarRing.you => colors.youRing,
    };

    Widget face = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: colorFor(name, brightness),
        shape: BoxShape.circle,
        border: ringColor == null
            ? null
            : Border.all(color: ringColor, width: 2),
      ),
      child: Text(
        initials ?? identityInitials(name),
        style: TextStyle(
          fontFamily: jamFontFamily,
          fontSize: size * 0.36,
          fontWeight: FontWeight.w700,
          color: initialsColorFor(brightness),
          height: 1,
        ),
      ),
    );
    if (dimmed) face = Opacity(opacity: 0.4, child: face);

    return Semantics(
      label: semanticLabel ?? name,
      image: true,
      child: ExcludeSemantics(child: face),
    );
  }
}

/// Overlapping faces: who is in the room, at a glance.
///
/// Past [maxVisible] the rest collapse into a `+N` chip, so a twelve-person
/// jam still reads as a group rather than as a scrolling ribbon.
class JamAvatarStack extends StatelessWidget {
  const JamAvatarStack({
    super.key,
    required this.names,
    this.size = JamAvatarSize.strip,
    this.maxVisible = 4,
    this.hostName,
    this.youName,
    this.semanticLabel,
  });

  /// Display names, in room order.
  final List<String> names;

  /// Diameter of each face.
  final double size;

  /// How many faces to draw before the overflow chip.
  final int maxVisible;

  /// The name to ring as the host, if it appears in [names].
  final String? hostName;

  /// The name to ring as you, if it appears in [names]. Takes precedence
  /// over [hostName] — you are you first, host second.
  final String? youName;

  /// Overrides the announced label. Defaults to a spoken list of names.
  final String? semanticLabel;

  /// The gap each face is pulled back over its neighbour.
  static const double _overlap = 0.32;

  /// The canvas-coloured ring that separates overlapping faces.
  static const double _ringWidth = 2;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    if (names.isEmpty) return const SizedBox.shrink();

    final visible = names.take(maxVisible).toList();
    final overflow = names.length - visible.length;
    final itemCount = visible.length + (overflow > 0 ? 1 : 0);
    final outer = size + _ringWidth * 2;
    final step = outer - size * _overlap;

    Widget ringed(Widget child) => Container(
      width: outer,
      height: outer,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: colors.canvas, shape: BoxShape.circle),
      child: child,
    );

    final children = <Widget>[
      for (var i = 0; i < visible.length; i++)
        Positioned(
          left: i * step,
          child: ringed(
            JamAvatar(
              name: visible[i],
              size: size,
              ring: switch (visible[i]) {
                final n when n == youName => JamAvatarRing.you,
                final n when n == hostName => JamAvatarRing.host,
                _ => JamAvatarRing.none,
              },
            ),
          ),
        ),
      if (overflow > 0)
        Positioned(
          left: visible.length * step,
          child: ringed(
            Container(
              width: size,
              height: size,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: colors.surfaceMuted,
                shape: BoxShape.circle,
              ),
              child: Text(
                '+$overflow',
                style: TextStyle(
                  fontFamily: jamFontFamily,
                  fontSize: size * 0.32,
                  fontWeight: FontWeight.w700,
                  color: colors.textSecondary,
                  height: 1,
                ),
              ),
            ),
          ),
        ),
    ];

    return Semantics(
      label: semanticLabel ?? _spoken(visible, overflow),
      image: true,
      child: ExcludeSemantics(
        child: SizedBox(
          width: (itemCount - 1) * step + outer,
          height: outer,
          child: Stack(children: children),
        ),
      ),
    );
  }

  static String _spoken(List<String> visible, int overflow) {
    final tail = overflow > 0 ? ' and $overflow more' : '';
    return '${visible.join(', ')}$tail';
  }
}
