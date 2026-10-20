/// The Now Playing backdrop (D1): a matte wash of the cover's colour that
/// fades into charcoal behind the controls. No image is painted — the cover
/// itself is right there in the middle of the page.
///
/// This file picks the wash's colour and caches it per cover. Painting is
/// `JamBackdropView` in `widgets/artwork.dart` (a gradient from
/// [JamBackdrop.base] to [JamNowPlayingColors.backdropPlaceholder]).
///
/// Three steps turn a cover into its colour (spec §10.7):
///
/// 1. **A representative hue, not the mean.** The cover is decoded small
///    and every pixel votes for its hue family, weighted by its chroma, so
///    greys do not vote and the strongest colour family wins. An orange
///    sleeve with a teal sky stays orange — averaging the two would give
///    olive. A cover with almost no colour falls back to its mean, so a
///    grey cover stays grey.
/// 2. **Saturation held to a band.** Quiet colours are lifted to
///    [kJamBackdropMinSaturation] so a pastel keeps its hue (a pale pink
///    sleeve lands on dusty rose, not grey); loud ones are capped at
///    [kJamBackdropMaxSaturation], and hues near raspberry at
///    [kJamBackdropMaxSaturationNearTint], so a pink cover never turns the
///    room into a wall of the action colour.
/// 3. **Lightness solved for the secondary text.** The wash starts no
///    lighter than [kJamBackdropMaxLightness] and darkens until *secondary*
///    white ([JamNowPlayingColors.secondary], white 70%) reaches
///    [kJamBackdropContrastTarget] (AA 4.5:1 plus a margin) on it. The
///    gradient only gets darker below, so that is the worst case.
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import 'tokens.dart';

/// The contrast secondary text must reach on the backdrop: AA's 4.5:1 with
/// a margin.
const double kJamBackdropContrastTarget = 4.6;

/// The lightest a wash starts from (HSL), before the contrast solve: the
/// room stays dim even where a darker colour would be "allowed".
const double kJamBackdropMaxLightness = 0.38;

/// The least saturation (HSL) a coloured cover's wash keeps, so a pastel
/// still names its hue once darkened.
const double kJamBackdropMinSaturation = 0.24;

/// The most saturation (HSL) a wash may have: colour, not neon.
const double kJamBackdropMaxSaturation = 0.55;

/// The most saturation (HSL) for a wash whose hue is within
/// [kJamBackdropTintClearance] of raspberry: pinks and magentas come out
/// dusty, never as a raspberry wall competing with the action colour.
const double kJamBackdropMaxSaturationNearTint = 0.3;

/// Degrees of hue either side of raspberry that count as "near" it.
const double kJamBackdropTintClearance = 28;

/// Raspberry's hue (HSL degrees) — the light theme's tint, #B82F59.
const double _kTintHue = 342;

/// The most saturation a grey cover's wash may pick up.
const double _kGreySaturation = 0.12;

/// Mean chroma (max − min channel, 0–1) under which a cover counts as grey
/// and the mean stands in for the dominant hue.
const double kJamBackdropMinChroma = 0.08;

/// A pixel with less chroma than this does not vote for a hue.
const double _kVoteChroma = 0.04;

/// Hue families the votes are counted in (30° each).
const int _kHueBins = 12;

/// The edge the cover is decoded at for sampling.
const int _kSampleEdge = 24;

/// What the Now Playing backdrop should paint.
@immutable
class JamBackdrop {
  const JamBackdrop({required this.base, this.id});

  /// The placeholder: the deep warm neutral every backdrop fades into.
  static const JamBackdrop placeholder = JamBackdrop(
    base: JamNowPlayingColors.backdropPlaceholder,
  );

  /// The wash's colour at the top of the page: the cover's representative
  /// colour, contrast-solved ([backdropColorFor]), or the deep neutral for
  /// the placeholder. Use it anywhere a solid backdrop colour is needed.
  final Color base;

  /// Identity of the cover, for cross-fades. Null for the placeholder.
  final String? id;

  /// Whether this is the placeholder.
  bool get isPlaceholder => id == null;

  @override
  bool operator ==(Object other) =>
      other is JamBackdrop && other.id == id && other.base == base;

  @override
  int get hashCode => Object.hash(id, base);

  @override
  String toString() => 'JamBackdrop(${id ?? 'placeholder'}, $base)';
}

/// The WCAG contrast ratio between two opaque colours.
double jamContrastRatio(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = math.max(la, lb);
  final lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

/// The contrast of secondary text (white 70%) on [ground].
double jamSecondaryContrastOn(Color ground) => jamContrastRatio(
  Color.alphaBlend(JamNowPlayingColors.secondary, ground),
  ground,
);

/// Whether [hue] (degrees) is within [kJamBackdropTintClearance] of
/// raspberry.
bool jamHueNearTint(double hue) {
  final d = (hue - _kTintHue).abs() % 360;
  return math.min(d, 360 - d) <= kJamBackdropTintClearance;
}

/// The wash for a cover whose representative colour is [representative]
/// (step 1 already done). [grey] keeps a colourless cover colourless.
///
/// Steps 2 and 3: saturation into its band, then the lightest lightness at
/// or under [kJamBackdropMaxLightness] that holds secondary text at
/// [kJamBackdropContrastTarget].
Color backdropColorFor(Color representative, {bool grey = false}) {
  final hsl = HSLColor.fromColor(representative.withValues(alpha: 1));
  final hue = hsl.hue;
  final double saturation;
  if (grey) {
    saturation = math.min(hsl.saturation, _kGreySaturation);
  } else {
    final cap = jamHueNearTint(hue)
        ? kJamBackdropMaxSaturationNearTint
        : kJamBackdropMaxSaturation;
    saturation = hsl.saturation.clamp(kJamBackdropMinSaturation, cap);
  }
  var lightness = math.min(hsl.lightness, kJamBackdropMaxLightness);
  Color at(double l) => HSLColor.fromAHSL(1, hue, saturation, l).toColor();
  // A fixed-step scan rather than a bisection, so the answer is monotonic in
  // the cover's lightness by construction.
  while (lightness > 0 &&
      jamSecondaryContrastOn(at(lightness)) < kJamBackdropContrastTarget) {
    lightness = math.max(0, lightness - 0.005);
  }
  return at(lightness);
}

/// A cover decoded small: its pixels, its mean, and its dominant colour.
class _Sample {
  _Sample(this.pixels);

  /// RGBA.
  final Uint8List pixels;

  /// The alpha-weighted mean colour.
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

  /// The colour of the heaviest hue family, by chroma-weighted votes —
  /// or null when the cover has too little colour to have one.
  ///
  /// A family's score counts half of each neighbour's votes too, so a hue
  /// sitting on a 30° boundary is not split in two; the colour is the
  /// chroma-weighted average of the winning family and its neighbours.
  Color? get dominant {
    final weight = List<double>.filled(_kHueBins, 0);
    final rs = List<double>.filled(_kHueBins, 0);
    final gs = List<double>.filled(_kHueBins, 0);
    final bs = List<double>.filled(_kHueBins, 0);
    var chroma = 0.0, n = 0.0;
    for (var i = 0; i + 3 < pixels.length; i += 4) {
      final a = pixels[i + 3] / 255;
      if (a == 0) continue;
      final r = pixels[i] / 255, g = pixels[i + 1] / 255;
      final b = pixels[i + 2] / 255;
      final hi = math.max(r, math.max(g, b));
      final lo = math.min(r, math.min(g, b));
      final c = hi - lo;
      n += a;
      chroma += c * a;
      if (c < _kVoteChroma) continue;
      final double hue;
      if (hi == r) {
        hue = 60 * (((g - b) / c) % 6);
      } else if (hi == g) {
        hue = 60 * ((b - r) / c + 2);
      } else {
        hue = 60 * ((r - g) / c + 4);
      }
      final bin = ((hue % 360) / (360 / _kHueBins)).floor() % _kHueBins;
      final w = c * a;
      weight[bin] += w;
      rs[bin] += r * w;
      gs[bin] += g * w;
      bs[bin] += b * w;
    }
    if (n == 0 || chroma / n < kJamBackdropMinChroma) return null;
    int wrap(int i) => (i + _kHueBins) % _kHueBins;
    var best = 0;
    var bestScore = -1.0;
    for (var i = 0; i < _kHueBins; i++) {
      final score =
          weight[i] + 0.5 * (weight[wrap(i - 1)] + weight[wrap(i + 1)]);
      if (score > bestScore) {
        bestScore = score;
        best = i;
      }
    }
    var r = 0.0, g = 0.0, b = 0.0, w = 0.0;
    for (final i in [wrap(best - 1), best, wrap(best + 1)]) {
      r += rs[i];
      g += gs[i];
      b += bs[i];
      w += weight[i];
    }
    if (w == 0) return null;
    int c(double v) => (v / w * 255).round().clamp(0, 255);
    return Color.fromARGB(255, c(r), c(g), c(b));
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
      if (pixels[i] != 0) return _Sample(pixels);
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
  final dominant = sample.dominant;
  return JamBackdrop(
    id: id,
    base: dominant == null
        ? backdropColorFor(sample.mean, grey: true)
        : backdropColorFor(dominant),
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
