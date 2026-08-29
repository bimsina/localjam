/// Cover-art rendering for playlist items (PROTOCOL.md §6.5).
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:localjam_client/localjam_client.dart';

/// The artwork for [item], loaded through [JamEngine.artworkFor] (hosts read
/// their own registry, guests fetch-and-cache), with a placeholder [icon]
/// while loading, on failure, or when the item has no artwork at all.
class JamArtwork extends StatelessWidget {
  const JamArtwork({
    super.key,
    required this.engine,
    required this.item,
    this.size = 40,
    this.icon = Icons.audio_file_outlined,
  });

  final JamEngine engine;
  final MediaItem? item;
  final double size;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final current = item;
    Widget placeholder() => Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(size / 8),
      ),
      child: Icon(
        icon,
        size: size * 0.55,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );

    if (current?.artworkId == null) return placeholder();
    return FutureBuilder<Uint8List?>(
      // The engines dedup/cache loads internally, so a rebuilt FutureBuilder
      // re-requesting the same artworkId is cheap.
      future: engine.artworkFor(current!),
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (bytes == null) return placeholder();
        return ClipRRect(
          borderRadius: BorderRadius.circular(size / 8),
          child: Image.memory(
            bytes,
            width: size,
            height: size,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => placeholder(),
          ),
        );
      },
    );
  }
}

/// The one-line artist/album byline for [item], or null when untagged —
/// callers show their own fallback (mime, fetch state, nothing).
String? artworkByline(MediaItem item) {
  final artist = item.artist;
  final album = item.album;
  if (artist != null && album != null) return '$artist · $album';
  return artist ?? album;
}
