/// Cover art (PROTOCOL.md §6.5) and the Now Playing backdrop (D4).
///
/// A track with no cover gets the iOS placeholder: `fillSecondary` ground and
/// a music note in `tertiaryLabel` at 40% of the tile. On the Now Playing
/// backdrop ([JamArtworkTile.onBackdrop]) it is white @ 12% with a white @ 50%
/// note. No gradients, no logo.
library;

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' show ImageFilter;

import 'package:flutter/cupertino.dart';
import 'package:localjam_client/localjam_client.dart';

import '../design/artwork_tint.dart';
import '../design/tokens.dart';

/// A pre-rendered 512×512 placeholder for the OS media card, which is drawn
/// by the platform from bytes and cannot run [JamArtworkTile].
const String kJamPlaceholderArtworkAsset =
    'assets/brand/artwork_placeholder.png';

/// The placeholder note's share of the tile.
const double _noteScale = 0.4;

/// A square of cover art, or the placeholder standing in for one.
///
/// Engine-free: hand it bytes or an [ImageProvider]. [JamArtwork] is the
/// engine-aware wrapper.
class JamArtworkTile extends StatelessWidget {
  const JamArtworkTile({
    super.key,
    this.bytes,
    this.image,
    this.size = JamArtworkSize.thumb,
    this.isLoading = false,
    this.hasError = false,
    this.imageKey,
    this.semanticLabel,
    this.overlay,
    this.onBackdrop = false,
    this.radius,
    this.shadow = false,
  });

  /// Encoded cover bytes, if they have arrived.
  final Uint8List? bytes;

  /// An already-resolved provider. Ignored when [bytes] is set.
  final ImageProvider? image;

  /// Edge length. Drives the radius through [JamRadius.artwork].
  final double size;

  /// Still fetching: shows the placeholder (no shimmer — no idle motion).
  final bool isLoading;

  /// The cover failed to load or decode: shows the placeholder.
  final bool hasError;

  /// Identity of the current artwork, so a *different* cover cross-fades.
  final Object? imageKey;

  /// Announced description. Omit for thumbnails beside a title.
  final String? semanticLabel;

  /// Drawn over the artwork, inside the clip.
  final Widget? overlay;

  /// Uses the Now Playing placeholder (white on the backdrop).
  final bool onBackdrop;

  /// Overrides the corner radius.
  final double? radius;

  /// Adds [JamShadow.artwork] (large covers only).
  final bool shadow;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final r = BorderRadius.circular(radius ?? JamRadius.artwork(size));

    final bytes = this.bytes;
    final provider = bytes != null ? MemoryImage(bytes) : image;

    final ground = onBackdrop
        ? JamNowPlayingColors.placeholderGround
        : colors.fillSecondary;
    final glyph = onBackdrop
        ? JamNowPlayingColors.placeholderGlyph
        : colors.tertiaryLabel;
    final placeholder = ColoredBox(
      color: ground,
      child: Center(
        child: Icon(
          CupertinoIcons.music_note,
          size: size * _noteScale,
          color: glyph,
        ),
      ),
    );

    Widget content;
    Object contentKey;
    if (hasError || provider == null) {
      content = placeholder;
      contentKey = 'placeholder';
    } else {
      content = Image(
        image: provider,
        width: size,
        height: size,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => placeholder,
      );
      contentKey = imageKey ?? identityHashCode(bytes ?? image);
    }

    final overlay = this.overlay;
    final tile = Container(
      width: size,
      height: size,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(color: ground, borderRadius: r),
      child: Stack(
        fit: StackFit.expand,
        children: [
          AnimatedSwitcher(
            duration: reduceMotion ? Duration.zero : JamDuration.base,
            switchInCurve: JamCurve.standard,
            child: KeyedSubtree(
              key: ValueKey<Object>(contentKey),
              child: content,
            ),
          ),
          ?overlay,
        ],
      ),
    );

    final painted = shadow
        ? DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: r,
              boxShadow: JamShadow.artwork,
            ),
            child: tile,
          )
        : tile;

    final label = semanticLabel;
    if (label == null) return ExcludeSemantics(child: painted);
    return Semantics(
      label: label,
      image: true,
      child: ExcludeSemantics(child: painted),
    );
  }
}

/// The artwork for [item], loaded through [JamEngine.artworkFor].
class JamArtwork extends StatelessWidget {
  const JamArtwork({
    super.key,
    required this.engine,
    required this.item,
    this.size = JamArtworkSize.thumb,
    this.semanticLabel,
    this.overlay,
    this.onBackdrop = false,
    this.shadow = false,
  });

  final JamEngine engine;
  final MediaItem? item;
  final double size;

  /// Announced description, if this artwork is worth announcing.
  final String? semanticLabel;

  /// Drawn over the artwork, inside the clip.
  final Widget? overlay;

  /// Uses the Now Playing placeholder.
  final bool onBackdrop;

  /// Adds [JamShadow.artwork].
  final bool shadow;

  @override
  Widget build(BuildContext context) {
    final current = item;
    if (current?.artworkId == null) {
      return JamArtworkTile(
        size: size,
        semanticLabel: semanticLabel,
        overlay: overlay,
        onBackdrop: onBackdrop,
        shadow: shadow,
      );
    }
    return FutureBuilder<Uint8List?>(
      // The engines dedup and cache loads, so re-requesting is cheap.
      future: engine.artworkFor(current!),
      builder: (context, snapshot) => JamArtworkTile(
        bytes: snapshot.data,
        imageKey: current.artworkId,
        size: size,
        isLoading: snapshot.connectionState != ConnectionState.done,
        hasError: snapshot.hasError,
        semanticLabel: semanticLabel,
        overlay: overlay,
        onBackdrop: onBackdrop,
        shadow: shadow,
      ),
    );
  }
}

/// Resolves the Now Playing [JamBackdrop] for whatever [engine] is playing
/// and hands it to [builder].
///
/// The [cache] is shared (the session controller's `backdrops`) so the room
/// screen and the mini player never decode the same cover twice. On a hit the
/// right backdrop is on the first frame; on a miss [builder] sees
/// [JamBackdrop.placeholder] until it lands.
class JamBackdropBuilder extends StatefulWidget {
  const JamBackdropBuilder({
    super.key,
    required this.engine,
    required this.cache,
    required this.builder,
  });

  final JamEngine engine;
  final JamBackdropCache cache;
  final Widget Function(BuildContext context, JamBackdrop backdrop) builder;

  @override
  State<JamBackdropBuilder> createState() => _JamBackdropBuilderState();
}

class _JamBackdropBuilderState extends State<JamBackdropBuilder> {
  JamBackdrop _backdrop = JamBackdrop.placeholder;
  String? _key;

  @override
  Widget build(BuildContext context) {
    _sync();
    return widget.builder(context, _backdrop);
  }

  void _sync() {
    final item = widget.engine.currentItem;
    final id = item?.artworkId;
    if (id == _key) return;
    _key = id;
    if (id == null || item == null) {
      _backdrop = JamBackdrop.placeholder;
      return;
    }
    final hit = widget.cache.peek(id);
    if (hit != null) {
      _backdrop = hit;
      return;
    }
    // Keep showing the previous cover until the new one resolves: the
    // cross-fade goes cover → cover, not cover → grey → cover.
    unawaited(_resolve(item, id));
  }

  Future<void> _resolve(MediaItem item, String id) async {
    final bytes = await widget.engine.artworkFor(item);
    if (!mounted || _key != id) return;
    final backdrop = bytes == null || bytes.isEmpty
        ? JamBackdrop.placeholder
        : await widget.cache.resolve(id, bytes);
    if (!mounted || _key != id) return;
    setState(() => _backdrop = backdrop);
  }
}

/// Paints a [JamBackdrop]: the base colour, the cover scaled to fill and
/// blurred (σ [JamBlur.backdrop]), and the black overlay — cross-fading over
/// [JamDuration.crossfade] when the cover changes. With no cover: the base
/// with a faint radial lift (spec §10.7).
///
/// Paints only. Every colour decision — the saturation boost, the darkening
/// solved for secondary text, the vibrance — is made once, in
/// `design/artwork_tint.dart`, and is already in [JamBackdrop.image].
class JamBackdropView extends StatelessWidget {
  const JamBackdropView({super.key, required this.backdrop, this.child});

  final JamBackdrop backdrop;

  /// Content drawn above the backdrop.
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final image = backdrop.image;
    final layer = KeyedSubtree(
      key: ValueKey<Object>(backdrop.id ?? 'placeholder'),
      child: ColoredBox(
        color: backdrop.base,
        child: image == null
            // The one gradient the spec allows lives on this surface.
            // A deep neutral with a faint lift behind where the cover sits,
            // so a song without art still reads as Now Playing.
            ? const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: Alignment(0, -0.3),
                    radius: 0.85,
                    colors: [
                      JamNowPlayingColors.backdropPlaceholderLift,
                      JamNowPlayingColors.clear,
                    ],
                  ),
                ),
                child: SizedBox.expand(),
              )
            : Stack(
                fit: StackFit.expand,
                children: [
                  ClipRect(
                    child: ImageFiltered(
                      imageFilter: ImageFilter.blur(
                        sigmaX: JamBlur.backdrop,
                        sigmaY: JamBlur.backdrop,
                        tileMode: TileMode.mirror,
                      ),
                      child: Image(
                        image: image,
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                        // Downsampled: a blurred cover needs no detail.
                        filterQuality: FilterQuality.low,
                      ),
                    ),
                  ),
                  ColoredBox(
                    color: const Color(
                      0xFF000000,
                    ).withValues(alpha: backdrop.overlayOpacity),
                  ),
                ],
              ),
      ),
    );

    return Stack(
      fit: StackFit.expand,
      children: [
        AnimatedSwitcher(
          duration: reduceMotion ? Duration.zero : JamDuration.crossfade,
          switchInCurve: JamCurve.standard,
          switchOutCurve: JamCurve.standard,
          layoutBuilder: (current, previous) =>
              Stack(fit: StackFit.expand, children: [...previous, ?current]),
          child: layer,
        ),
        ?child,
      ],
    );
  }
}

/// The one-line artist/album byline for [item], or null when untagged.
String? artworkByline(MediaItem item) {
  final artist = item.artist;
  final album = item.album;
  if (artist != null && album != null) return '$artist · $album';
  return artist ?? album;
}
