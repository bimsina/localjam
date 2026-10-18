/// The Now Playing backdrop (D4): the current cover, scaled to fill and
/// blurred, under a black overlay strong enough for white text.
///
/// This file produces the *inputs* — which image, how strong the overlay,
/// what flat colour stands in — and caches them per cover. Painting is
/// `JamBackdropView` in `widgets/artwork.dart`.
///
/// Two things happen to a cover before it is painted (spec §10.7):
///
/// 1. **Saturation first.** The cover is decoded small (it is about to be
///    blurred by σ 70 anyway) and its saturation boosted by
///    [kJamBackdropSaturation], so a pale or bright sleeve keeps its hue
///    once darkened instead of turning to grey-brown mud. The boosted
///    pixels become the image the view blurs.
/// 2. **Then the overlay, solved for the secondary text.** The black
///    overlay is the weakest that puts *secondary* white
///    ([JamNowPlayingColors.secondary], white 70%) at
///    [kJamBackdropContrastTarget] (AA 4.5:1 plus a margin) over the
///    cover's brightest blurred patch — not its mean, since the blur leaves
///    local bright spots under the text. Floored at
///    [kJamBackdropMinOverlay], capped at [kJamBackdropMaxOverlay] (a white
///    cover still clears at the cap).
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import 'tokens.dart';

/// The weakest overlay any cover gets.
const double kJamBackdropMinOverlay = 0.25;

/// The strongest overlay any cover gets (a white cover). Enough that white
/// 70% on pure white darkened by it still clears [kJamBackdropContrastTarget].
const double kJamBackdropMaxOverlay = 0.7;

/// How much the cover's saturation is boosted before it is darkened.
const double kJamBackdropSaturation = 1.5;

/// The contrast secondary text must reach on the backdrop: AA's 4.5:1 with
/// a margin for what the sampling misses.
const double kJamBackdropContrastTarget = 4.6;

/// The edge the cover is decoded at for sampling and painting. The view
/// blurs it by σ 70, so detail beyond this is never seen.
const int _kSampleEdge = 24;

/// What the Now Playing backdrop should paint.
@immutable
class JamBackdrop {
  const JamBackdrop({
    required this.image,
    required this.overlayOpacity,
    required this.base,
    this.id,
  });

  /// The placeholder: a deep neutral, no image, no overlay. The room paints
  /// its faint lift over it (spec §10.7).
  static const JamBackdrop placeholder = JamBackdrop(
    image: null,
    overlayOpacity: 0,
    base: JamNowPlayingColors.backdropPlaceholder,
  );

  /// The cover to blur (already saturated), or null for [placeholder].
  final ImageProvider? image;

  /// Alpha of the black overlay over the blurred cover.
  final double overlayOpacity;

  /// A flat stand-in: the cover's (saturated) mean colour with the overlay
  /// applied, or the deep neutral for the placeholder. Paint it under the
  /// blur so the edges never show the page, and use it anywhere a solid
  /// backdrop colour is needed.
  final Color base;

  /// Identity of the cover, for cross-fades. Null for the placeholder.
  final String? id;

  /// Whether this is the placeholder.
  bool get isPlaceholder => image == null;

  @override
  bool operator ==(Object other) =>
      other is JamBackdrop &&
      other.id == id &&
      other.image == image &&
      other.overlayOpacity == overlayOpacity &&
      other.base == base;

  @override
  int get hashCode => Object.hash(id, image, overlayOpacity, base);

  @override
  String toString() =>
      'JamBackdrop(${id ?? 'placeholder'}, overlay: '
      '${overlayOpacity.toStringAsFixed(2)})';
}

/// The WCAG contrast ratio between two opaque colours.
double jamContrastRatio(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = math.max(la, lb);
  final lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

/// [cover] under a black overlay of [opacity].
Color jamDarken(Color cover, double opacity) => Color.alphaBlend(
  const Color(0xFF000000).withValues(alpha: opacity),
  cover.withValues(alpha: 1),
);

/// The contrast of secondary text (white 70%) on [ground].
double jamSecondaryContrastOn(Color ground) => jamContrastRatio(
  Color.alphaBlend(JamNowPlayingColors.secondary, ground),
  ground,
);

/// The weakest overlay that puts secondary text at
/// [kJamBackdropContrastTarget] on [cover] — floored and capped.
double backdropOverlayForColor(Color cover) {
  // A fixed-step scan rather than a bisection, so the answer is monotonic in
  // the cover's brightness by construction.
  for (var a = kJamBackdropMinOverlay; a < kJamBackdropMaxOverlay; a += 0.005) {
    if (jamSecondaryContrastOn(jamDarken(cover, a)) >=
        kJamBackdropContrastTarget) {
      return a;
    }
  }
  return kJamBackdropMaxOverlay;
}

/// The overlay for a grey cover of relative [luminance] (0–1).
double backdropOverlayFor(double luminance) {
  final l = luminance.clamp(0.0, 1.0);
  final v = l <= 0.0031308 ? 12.92 * l : 1.055 * math.pow(l, 1 / 2.4) - 0.055;
  final c = (v.clamp(0.0, 1.0) * 255).round();
  return backdropOverlayForColor(Color.fromARGB(255, c, c, c));
}

/// [color] with its saturation scaled by [amount] around its own luminance
/// (Rec. 709 weights), clamped to gamut.
Color jamSaturate(Color color, double amount) {
  final (r, g, b) = _saturate(color.r, color.g, color.b, amount);
  return Color.from(alpha: color.a, red: r, green: g, blue: b);
}

(double, double, double) _saturate(double r, double g, double b, double s) {
  const lr = 0.2126, lg = 0.7152, lb = 0.0722;
  final l = lr * r + lg * g + lb * b;
  double c(double v) => (l + (v - l) * s).clamp(0.0, 1.0);
  return (c(r), c(g), c(b));
}

/// Builds the backdrop for a cover whose (already saturated) mean colour is
/// [mean]. The overlay is solved against [bright] — the brightest patch the
/// blur leaves — when known, else against [mean].
JamBackdrop backdropFromMean({
  required String id,
  required ImageProvider image,
  required Color mean,
  Color? bright,
}) {
  final overlay = backdropOverlayForColor(bright ?? mean);
  return JamBackdrop(
    id: id,
    image: image,
    overlayOpacity: overlay,
    base: jamDarken(mean, overlay),
  );
}

/// Decodes [bytes] at a thumbnail size and returns its mean colour, or null
/// when the bytes do not decode.
Future<Color?> meanColorOf(Uint8List bytes) async =>
    (await _sample(bytes, 16))?.mean;

/// A cover decoded small: its pixels, mean colour and brightest patch.
class _Sample {
  _Sample(this.pixels, this.edge);

  /// RGBA, [edge] × [edge].
  final Uint8List pixels;
  final int edge;

  Color get mean {
    var r = 0.0, g = 0.0, b = 0.0, n = 0.0;
    for (var i = 0; i + 3 < pixels.length; i += 4) {
      final a = pixels[i + 3] / 255;
      if (a == 0) continue;
      r += pixels[i] * a;
      g += pixels[i + 1] * a;
      b += pixels[i + 2] * a;
      n += a;
    }
    if (n == 0) return const Color(0xFF000000);
    int c(double v) => math.min(255, (v / n).round());
    return Color.fromARGB(255, c(r), c(g), c(b));
  }

  /// The brightest mean of a box about a fifth of the cover wide — roughly
  /// what σ 70 leaves of a bright spot on a phone-sized backdrop — within
  /// the cover's middle columns, which is what a portrait window shows of
  /// it, and away from the top and bottom rows (status bar, home bar).
  Color get bright {
    final box = math.max(2, (edge / 5).round());
    final fromX = (edge * 0.2).floor();
    final toX = math.max(fromX, (edge * 0.8).ceil() - box);
    final fromY = (edge * 0.05).ceil();
    final toY = math.max(fromY, edge - box - fromY);
    var best = mean;
    var bestL = best.computeLuminance();
    for (var y = fromY; y <= toY; y++) {
      for (var x = fromX; x <= toX; x++) {
        var r = 0, g = 0, b = 0, n = 0;
        for (var dy = 0; dy < box; dy++) {
          for (var dx = 0; dx < box; dx++) {
            final i = ((y + dy) * edge + (x + dx)) * 4;
            if (i + 3 >= pixels.length || pixels[i + 3] == 0) continue;
            r += pixels[i];
            g += pixels[i + 1];
            b += pixels[i + 2];
            n++;
          }
        }
        if (n == 0) continue;
        final c = Color.fromARGB(255, r ~/ n, g ~/ n, b ~/ n);
        final l = c.computeLuminance();
        if (l > bestL) {
          best = c;
          bestL = l;
        }
      }
    }
    return best;
  }

  /// Boosts every pixel's saturation in place.
  void saturate(double amount) {
    for (var i = 0; i + 3 < pixels.length; i += 4) {
      final (r, g, b) = _saturate(
        pixels[i] / 255,
        pixels[i + 1] / 255,
        pixels[i + 2] / 255,
        amount,
      );
      pixels[i] = (r * 255).round();
      pixels[i + 1] = (g * 255).round();
      pixels[i + 2] = (b * 255).round();
    }
  }

  /// The pixels as a PNG, for an [ImageProvider]; null if encoding fails.
  Future<Uint8List?> encode() async {
    try {
      final buffer = await ui.ImmutableBuffer.fromUint8List(pixels);
      final descriptor = ui.ImageDescriptor.raw(
        buffer,
        width: edge,
        height: edge,
        pixelFormat: ui.PixelFormat.rgba8888,
      );
      final codec = await descriptor.instantiateCodec();
      final frame = await codec.getNextFrame();
      final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
      frame.image.dispose();
      codec.dispose();
      descriptor.dispose();
      buffer.dispose();
      return data?.buffer.asUint8List();
    } on Object {
      return null;
    }
  }
}

Future<_Sample?> _sample(Uint8List bytes, int edge) async {
  if (bytes.isEmpty) return null;
  try {
    final codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: edge,
      targetHeight: edge,
    );
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    image.dispose();
    codec.dispose();
    if (data == null) return null;
    final pixels = Uint8List.fromList(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
    for (var i = 3; i < pixels.length; i += 4) {
      if (pixels[i] != 0) return _Sample(pixels, edge);
    }
    return null;
  } on Object {
    return null;
  }
}

/// Derives the backdrop for a cover. Prefer [JamBackdropCache.resolve].
Future<JamBackdrop> backdropFor(String id, Uint8List bytes) async {
  final sample = await _sample(bytes, _kSampleEdge);
  if (sample == null) return JamBackdrop.placeholder;
  sample.saturate(kJamBackdropSaturation);
  final png = await sample.encode();
  return backdropFromMean(
    id: id,
    image: MemoryImage(png ?? bytes),
    mean: sample.mean,
    bright: sample.bright,
  );
}

/// A small LRU cache of resolved backdrops, keyed by artwork id.
///
/// The session controller holds one so the room screen and the mini player
/// never decode the same cover twice.
class JamBackdropCache {
  JamBackdropCache({this.capacity = 24}) : assert(capacity > 0);

  /// How many backdrops to keep.
  final int capacity;

  final Map<String, JamBackdrop> _entries = <String, JamBackdrop>{};
  final Map<String, Future<JamBackdrop>> _inFlight =
      <String, Future<JamBackdrop>>{};

  /// The backdrop for [artworkId] if already derived. Does not count as a use.
  JamBackdrop? peek(String artworkId) => _entries[artworkId];

  /// The backdrop for [artworkId], deriving it from [bytes] on a miss.
  /// Concurrent calls for the same id share one derivation.
  Future<JamBackdrop> resolve(String artworkId, Uint8List bytes) {
    final hit = _entries.remove(artworkId);
    if (hit != null) {
      _entries[artworkId] = hit;
      return Future<JamBackdrop>.value(hit);
    }
    return _inFlight[artworkId] ??= backdropFor(artworkId, bytes).then((b) {
      _inFlight.remove(artworkId);
      _put(artworkId, b);
      return b;
    });
  }

  /// Records an already-derived backdrop.
  void store(String artworkId, JamBackdrop backdrop) =>
      _put(artworkId, backdrop);

  /// Forgets everything. Worth calling when a jam ends.
  void clear() {
    _entries.clear();
    _inFlight.clear();
  }

  /// How many backdrops are held.
  int get length => _entries.length;

  void _put(String key, JamBackdrop backdrop) {
    _entries
      ..remove(key)
      ..[key] = backdrop;
    while (_entries.length > capacity) {
      _entries.remove(_entries.keys.first);
    }
  }
}
