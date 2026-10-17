/// Cover-art rendering (PROTOCOL.md §6.5).
///
/// Artwork is the only thing on screen with real colour, so it gets a
/// hairline on light grounds — without one, a pale cover dissolves into a
/// white page. On dark the lightness step is separation enough.
///
/// A track with no cover is not a hole: it gets the brand gradient with the
/// logo knocked into it, so a queue of untagged files still looks composed.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:localjam_client/localjam_client.dart';

import '../design/artwork_tint.dart';
import '../design/tokens.dart';

/// The brand mark drawn into the artwork placeholder.
const String _logoAsset = 'assets/brand/logo.svg';

/// The same placeholder, pre-rendered at 512×512.
///
/// The OS media card is drawn by the platform from raw bytes — it cannot run
/// [JamArtworkTile], so an untagged track showed up on the lock screen as a
/// blank square. Rendering it at runtime would mean rasterising an SVG and a
/// gradient on the first track of every session; baking it once at build time
/// costs 26 KB and no frames. Kept in step with [_placeholderAlpha],
/// [_logoScale] and [_logoOpacity] by hand — see README.md, "Brand assets".
const String kJamPlaceholderArtworkAsset =
    'assets/brand/artwork_placeholder.png';

/// The placeholder gradient's alpha — a shade under solid, so a wall of
/// untagged tracks does not read as a wall of buttons.
const double _placeholderAlpha = 0.85;

/// The logo's share of the tile, and how faintly it sits in the gradient.
const double _logoScale = 0.42;
const double _logoOpacity = 0.22;

/// One turn of the loading shimmer.
const Duration _shimmerPeriod = Duration(milliseconds: 1200);

/// A square of cover art, or the brand placeholder standing in for one.
///
/// Engine-free by design: hand it bytes (what `JamEngine.artworkFor`
/// returns) or any [ImageProvider], plus flags for the loading and error
/// states. [JamArtwork] is the engine-aware wrapper around it.
class JamArtworkTile extends StatefulWidget {
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
  });

  /// Encoded cover bytes, if they have arrived.
  final Uint8List? bytes;

  /// An already-resolved provider, for callers that hold one. Ignored when
  /// [bytes] is set.
  final ImageProvider? image;

  /// Edge length. Drives the corner radius through [JamRadius.artwork].
  final double size;

  /// Whether the cover is still being fetched — draws the shimmer.
  final bool isLoading;

  /// Whether the cover failed to load or decode.
  final bool hasError;

  /// Identity of the current artwork, so a *different* cover cross-fades
  /// while a rebuild with the same one does not. Defaults to the identity of
  /// [bytes] / [image].
  final Object? imageKey;

  /// Announced description. Omit for decorative thumbnails beside a title
  /// that already says what the track is.
  final String? semanticLabel;

  /// Drawn over the artwork, inside the clip — the queue's equaliser badge,
  /// for instance.
  final Widget? overlay;

  @override
  State<JamArtworkTile> createState() => _JamArtworkTileState();
}

class _JamArtworkTileState extends State<JamArtworkTile>
    with SingleTickerProviderStateMixin {
  late final AnimationController _shimmer = AnimationController(
    vsync: this,
    duration: _shimmerPeriod,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncShimmer();
  }

  @override
  void didUpdateWidget(JamArtworkTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncShimmer();
  }

  void _syncShimmer() {
    final wanted =
        widget.isLoading &&
        widget.bytes == null &&
        widget.image == null &&
        !widget.hasError &&
        !MediaQuery.disableAnimationsOf(context);
    if (wanted && !_shimmer.isAnimating) {
      _shimmer.repeat();
    } else if (!wanted && _shimmer.isAnimating) {
      _shimmer
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _shimmer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final isLight = Theme.of(context).brightness == Brightness.light;
    final size = widget.size;
    final radius = BorderRadius.circular(JamRadius.artwork(size));
    final reduceMotion = MediaQuery.disableAnimationsOf(context);

    final bytes = widget.bytes;
    final provider = bytes != null
        ? MemoryImage(bytes) as ImageProvider
        : widget.image;

    Widget content;
    Object contentKey;
    if (widget.hasError) {
      content = _placeholder(colors, size, errorGlyph: true);
      contentKey = 'error';
    } else if (provider != null) {
      content = Image(
        image: provider,
        width: size,
        height: size,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => _placeholder(colors, size, errorGlyph: true),
      );
      contentKey =
          widget.imageKey ?? identityHashCode(bytes ?? widget.image ?? this);
    } else if (widget.isLoading) {
      content = _shimmerPlaceholder(colors, size, reduceMotion: reduceMotion);
      contentKey = 'loading';
    } else {
      content = _placeholder(colors, size);
      contentKey = 'placeholder';
    }

    final overlay = widget.overlay;
    final tile = Container(
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
      child: Stack(
        fit: StackFit.expand,
        children: [
          AnimatedSwitcher(
            duration: reduceMotion ? JamDuration.instant : JamDuration.base,
            switchInCurve: JamCurve.base,
            child: KeyedSubtree(
              key: ValueKey<Object>(contentKey),
              child: content,
            ),
          ),
          ?overlay,
        ],
      ),
    );

    final label = widget.semanticLabel;
    if (label == null) return ExcludeSemantics(child: tile);
    return Semantics(
      label: label,
      image: true,
      child: ExcludeSemantics(child: tile),
    );
  }

  /// The brand gradient with the logo knocked into it — what stands in for a
  /// cover that does not exist.
  Widget _placeholder(
    JamColors colors,
    double size, {
    bool errorGlyph = false,
  }) => DecoratedBox(
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          colors.highlight.withValues(alpha: _placeholderAlpha),
          colors.accent.withValues(alpha: _placeholderAlpha),
        ],
      ),
    ),
    child: Center(
      child: errorGlyph
          ? Icon(
              Icons.music_note_rounded,
              size: size * _logoScale,
              color: Colors.white.withValues(alpha: 0.3),
            )
          : Opacity(
              opacity: _logoOpacity,
              child: SvgPicture.asset(
                _logoAsset,
                width: size * _logoScale,
                height: size * _logoScale,
                fit: BoxFit.contain,
                colorFilter: const ColorFilter.mode(
                  Colors.white,
                  BlendMode.srcIn,
                ),
              ),
            ),
    ),
  );

  /// The same placeholder with a light sweeping across it while the real
  /// cover is on its way.
  Widget _shimmerPlaceholder(
    JamColors colors,
    double size, {
    required bool reduceMotion,
  }) {
    final base = _placeholder(colors, size);
    if (reduceMotion) return base;
    return AnimatedBuilder(
      animation: _shimmer,
      builder: (context, child) {
        final t = _shimmer.value * 2 - 0.5;
        return ShaderMask(
          blendMode: BlendMode.srcATop,
          shaderCallback: (rect) => LinearGradient(
            begin: Alignment(t - 1, -1),
            end: Alignment(t + 1, 1),
            colors: [
              Colors.white.withValues(alpha: 0),
              Colors.white.withValues(alpha: 0.28),
              Colors.white.withValues(alpha: 0),
            ],
            stops: const [0.35, 0.5, 0.65],
          ).createShader(rect),
          child: child,
        );
      },
      child: base,
    );
  }
}

/// The artwork for [item], loaded through [JamEngine.artworkFor] (hosts read
/// their own registry, guests fetch-and-cache).
///
/// A thin engine-aware shell over [JamArtworkTile] — the tile is the one
/// that knows what artwork looks like.
class JamArtwork extends StatelessWidget {
  const JamArtwork({
    super.key,
    required this.engine,
    required this.item,
    this.size = JamArtworkSize.thumb,
    this.semanticLabel,
    this.overlay,
  });

  final JamEngine engine;
  final MediaItem? item;
  final double size;

  /// Announced description, if this artwork is worth announcing.
  final String? semanticLabel;

  /// Drawn over the artwork, inside the clip.
  final Widget? overlay;

  @override
  Widget build(BuildContext context) {
    final current = item;
    if (current?.artworkId == null) {
      return JamArtworkTile(
        size: size,
        semanticLabel: semanticLabel,
        overlay: overlay,
      );
    }
    return FutureBuilder<Uint8List?>(
      // The engines dedup/cache loads internally, so a rebuilt FutureBuilder
      // re-requesting the same artworkId is cheap.
      future: engine.artworkFor(current!),
      builder: (context, snapshot) => JamArtworkTile(
        bytes: snapshot.data,
        imageKey: current.artworkId,
        size: size,
        isLoading: snapshot.connectionState != ConnectionState.done,
        hasError: snapshot.hasError,
        semanticLabel: semanticLabel,
        overlay: overlay,
      ),
    );
  }
}

/// Resolves the ambient tint (§2.2) for whatever [engine] is playing and
/// hands it to [builder].
///
/// The derivation is not free — it decodes and quantises the cover — so the
/// [cache] is passed in rather than owned: the room screen and the docked
/// room bar are looking at the same track and must not each pay for it. The
/// session controller holds the shared one.
///
/// On a cache hit the right colour is on the very first frame; on a miss the
/// builder sees [JamTint.fallback] until the derivation lands.
class JamTintBuilder extends StatefulWidget {
  const JamTintBuilder({
    super.key,
    required this.engine,
    required this.cache,
    required this.builder,
  });

  final JamEngine engine;

  /// The shared cache — see [JamSessionController.tints].
  final JamTintCache cache;

  final Widget Function(BuildContext context, JamTint tint) builder;

  @override
  State<JamTintBuilder> createState() => _JamTintBuilderState();
}

class _JamTintBuilderState extends State<JamTintBuilder> {
  JamTint _tint = JamTint.fallback;
  String? _key;
  Brightness? _brightness;

  @override
  Widget build(BuildContext context) {
    _sync();
    return widget.builder(context, _tint);
  }

  void _sync() {
    final item = widget.engine.currentItem;
    final id = item?.artworkId;
    final brightness = Theme.of(context).brightness;
    if (id == _key && brightness == _brightness) return;
    _key = id;
    _brightness = brightness;
    if (id == null || item == null) {
      _tint = JamTint.fallback;
      return;
    }
    final hit = widget.cache.peek(id, brightness);
    if (hit != null) {
      _tint = hit;
      return;
    }
    _tint = JamTint.fallback;
    unawaited(_resolve(item, id, brightness));
  }

  Future<void> _resolve(
    MediaItem item,
    String id,
    Brightness brightness,
  ) async {
    final bytes = await widget.engine.artworkFor(item);
    if (!mounted || _key != id) return;
    final tint = bytes == null || bytes.isEmpty
        ? JamTint.fallback
        : await widget.cache.resolve(id, bytes, brightness);
    if (!mounted || _key != id) return;
    setState(() => _tint = tint);
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
