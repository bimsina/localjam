/// Cover-art rendering (PROTOCOL.md §6.5).
///
/// Artwork is the only thing on screen with real colour, so it gets a hairline
/// on light grounds — without one, a pale cover dissolves into a white page.
/// On dark the lightness step is separation enough.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:localjam_client/localjam_client.dart';

import '../design/tokens.dart';

/// The artwork for [item], loaded through [JamEngine.artworkFor] (hosts read
/// their own registry, guests fetch-and-cache), with a placeholder while
/// loading, on failure, or when the item has no artwork at all.
class JamArtwork extends StatelessWidget {
  const JamArtwork({
    super.key,
    required this.engine,
    required this.item,
    this.size = JamArtworkSize.thumb,
    this.icon = Icons.music_note_rounded,
  });

  final JamEngine engine;
  final MediaItem? item;
  final double size;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final isLight = Theme.of(context).brightness == Brightness.light;
    final radius = BorderRadius.circular(JamRadius.artwork(size));
    final current = item;

    Widget frame(Widget child) => Container(
      width: size,
      height: size,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: colors.surfaceMuted,
        borderRadius: radius,
        border: isLight
            ? Border.all(color: colors.separator, width: 0.5)
            : null,
      ),
      child: child,
    );

    Widget placeholder() =>
        frame(Icon(icon, size: size * 0.4, color: colors.textTertiary));

    if (current?.artworkId == null) return placeholder();
    return FutureBuilder<Uint8List?>(
      // The engines dedup/cache loads internally, so a rebuilt FutureBuilder
      // re-requesting the same artworkId is cheap.
      future: engine.artworkFor(current!),
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (bytes == null) return placeholder();
        return frame(
          Image.memory(
            bytes,
            width: size,
            height: size,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) =>
                Icon(icon, size: size * 0.4, color: colors.textTertiary),
          ),
        );
      },
    );
  }
}

/// The one-line artist/album byline for [item], or null when untagged —
/// callers show their own fallback.
String? artworkByline(MediaItem item) {
  final artist = item.artist;
  final album = item.album;
  if (artist != null && album != null) return '$artist · $album';
  return artist ?? album;
}
