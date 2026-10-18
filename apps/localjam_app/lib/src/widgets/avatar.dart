/// Faces for the room (D6): a flat colour per person, white initials, no ring.
///
/// The protocol carries only a `clientName` — no avatar, no colour — so a
/// face derives from that name. The derivation must be stable *across
/// devices*, which is why it hashes with FNV-1a rather than
/// [Object.hashCode] (not stable between runs or platforms).
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

/// One or two initials for [name]: "Silky Puffin" becomes "SP".
String identityInitials(String name) {
  final words = name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
  if (words.isEmpty) return '?';
  if (words.length == 1) return words.first.characters.first.toUpperCase();
  return (words.first.characters.first + words.last.characters.first)
      .toUpperCase();
}

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
  });

  /// The display name the colour and the initials both derive from.
  final String name;

  /// A stable id (the peer's client id) to pick the colour from instead of
  /// [name]. Reserved for the per-jam colour assignment (spec §10.10).
  final String? colorKey;

  /// Diameter — see [JamAvatarSize].
  final double size;

  /// Faded, for a peer who is reconnecting or has left.
  final bool dimmed;

  /// Overrides the announced label. Defaults to [name].
  final String? semanticLabel;

  /// Overrides the letters, keeping [name]'s colour.
  final String? initials;

  /// The face colour for [name].
  static Color colorFor(String name) => identityColor(name);

  @override
  Widget build(BuildContext context) {
    Widget face = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: colorFor(name), shape: BoxShape.circle),
      child: Text(
        initials ?? identityInitials(name),
        maxLines: 1,
        textScaler: TextScaler.noScaling,
        style: context.jamBody.copyWith(
          fontSize: size * 0.4,
          fontWeight: FontWeight.w600,
          color: JamAvatarPalette.initials,
          height: 1,
          letterSpacing: 0,
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

/// The face pile: up to [maxVisible] overlapping faces (30% overlap), each
/// cut out of its neighbour by a 2 pt ring in [cutoutColor], then "+N" in
/// `secondaryLabel`.
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
  });

  /// Display names, in room order.
  final List<String> names;

  /// Stable ids parallel to [names] (see [JamAvatar.colorKey]).
  final List<String>? colorKeys;

  /// Diameter of each face.
  final double size;

  /// Faces before the "+N".
  final int maxVisible;

  /// The ground the pile sits on (default `background`). On the Now Playing
  /// backdrop pass the backdrop's `base`.
  final Color? cutoutColor;

  /// The "+N" colour (default `secondaryLabel`).
  final Color? overflowColor;

  /// Overrides the announced label. Defaults to a spoken list of names.
  final String? semanticLabel;

  static const double _overlap = 0.3;
  static const double _cutout = 2;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    if (names.isEmpty) return const SizedBox.shrink();

    final visible = names.take(maxVisible).toList();
    final overflow = names.length - visible.length;
    final outer = size + _cutout * 2;
    final step = size * (1 - _overlap);
    final cutout = cutoutColor ?? colors.background;

    final pile = SizedBox(
      width: (visible.length - 1) * step + outer,
      height: outer,
      child: Stack(
        children: [
          for (var i = 0; i < visible.length; i++)
            Positioned(
              left: i * step,
              child: Container(
                width: outer,
                height: outer,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: i == 0 ? null : cutout,
                  shape: BoxShape.circle,
                ),
                child: JamAvatar(name: visible[i], size: size),
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
                ).copyWith(color: overflowColor ?? colors.secondaryLabel),
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
