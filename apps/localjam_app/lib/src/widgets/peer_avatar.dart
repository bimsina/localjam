/// Faces for the room.
///
/// Identities are quirky two-word names ("Silky Puffin") with no avatar,
/// colour, or emoji behind them (PROTOCOL.md carries only `clientName`). A
/// colour derived from the name gives everyone a stable face for free, with no
/// protocol change — but only if the derivation is stable *across devices*,
/// so this hashes the string itself rather than using [Object.hashCode],
/// which Dart does not guarantee between runs or platforms.
library;

import 'package:flutter/material.dart';

import '../design/tokens.dart';

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

/// A person in the room: initials on their identity colour.
class PeerAvatar extends StatelessWidget {
  const PeerAvatar({
    super.key,
    required this.name,
    this.size = 36,
    this.isHost = false,
    this.dimmed = false,
  });

  /// The display name the colour and initials derive from.
  final String name;

  /// Diameter.
  final double size;

  /// Marks the room's owner with a ring.
  final bool isHost;

  /// Renders faded — used for a peer who is reconnecting or has left.
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final brightness = Theme.of(context).brightness;
    final color = identityColor(name, brightness);
    final avatar = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: isHost ? Border.all(color: colors.accent, width: 2) : null,
      ),
      child: Text(
        identityInitials(name),
        style: TextStyle(
          fontSize: size * 0.38,
          fontWeight: FontWeight.w600,
          color: Colors.white,
          letterSpacing: 0.2,
        ),
      ),
    );
    if (!dimmed) return avatar;
    return Opacity(opacity: 0.4, child: avatar);
  }
}

/// A horizontal run of faces with a trailing "+N" when they overflow.
///
/// Deliberately not overlapped: in a four-person room every face should be
/// legible at a glance, not stacked into a decoration.
class PeerAvatarRow extends StatelessWidget {
  const PeerAvatarRow({
    super.key,
    required this.names,
    this.hostName,
    this.size = 36,
    this.maxVisible = 6,
  });

  /// Display names, in room order.
  final List<String> names;

  /// The name to ring as the host, if present in [names].
  final String? hostName;

  final double size;

  /// How many faces to show before collapsing the rest into a count.
  final int maxVisible;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final visible = names.take(maxVisible).toList();
    final overflow = names.length - visible.length;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final name in visible)
          Padding(
            padding: const EdgeInsets.only(right: JamSpace.sm),
            child: PeerAvatar(
              name: name,
              size: size,
              isHost: hostName != null && name == hostName,
            ),
          ),
        if (overflow > 0)
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
                fontSize: size * 0.32,
                fontWeight: FontWeight.w600,
                color: colors.textSecondary,
              ),
            ),
          ),
      ],
    );
  }
}
