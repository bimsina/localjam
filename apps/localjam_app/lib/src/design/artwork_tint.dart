/// The Now Playing backdrop (D4): the current cover, scaled to fill and
/// blurred, under a black overlay strong enough for white text.
///
/// This file produces the *inputs* — which image, how strong the overlay,
/// what flat colour stands in — and caches them per cover. Painting is
/// `JamBackdropView` in `widgets/artwork.dart`.
///
/// The overlay is not a constant. The spec's 25–35% band holds white text on
/// a mid-tone cover, but a pale cover (a white sleeve, a beach) needs more, so
/// the strength is solved from the cover's mean luminance: enough black that
/// the blurred average lands where white clears AA (4.5:1), floored at 25%
/// and capped at [kJamBackdropMaxOverlay].
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import 'tokens.dart';

/// The weakest overlay any cover gets.
const double kJamBackdropMinOverlay = 0.25;

/// The strongest overlay any cover gets (a white cover).
const double kJamBackdropMaxOverlay = 0.6;

/// The blurred cover's luminance white text must sit on to clear AA, with a
/// margin for the blur's local bright spots.
const double _targetLuminance = 0.16;

/// What the Now Playing backdrop should paint.
@immutable
class JamBackdrop {
  const JamBackdrop({
    required this.image,
    required this.overlayOpacity,
    required this.base,
    this.id,
  });

  /// The placeholder: flat `#1C1C1E`, no image, no overlay.
  static const JamBackdrop placeholder = JamBackdrop(
    image: null,
    overlayOpacity: 0,
    base: JamNowPlayingColors.backdropPlaceholder,
  );

  /// The cover to blur, or null for [placeholder].
  final ImageProvider? image;

  /// Alpha of the black overlay over the blurred cover.
  final double overlayOpacity;

  /// A flat stand-in: the cover's mean colour with the overlay applied (or
  /// `#1C1C1E` for the placeholder). Paint it under the blur so the edges
  /// never show the page, and use it anywhere a solid backdrop colour is
  /// needed.
  final Color base;

  /// Identity of the cover, for cross-fades. Null for the placeholder.
  final String? id;

  /// Whether this is the flat placeholder.
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

/// The overlay strength for a cover whose mean relative luminance is
/// [luminance] (0–1).
double backdropOverlayFor(double luminance) {
  if (luminance <= 0) return kJamBackdropMinOverlay;
  // Black over a colour scales its luminance by (1 - a), near enough.
  final needed = 1 - _targetLuminance / luminance;
  return needed
      .clamp(kJamBackdropMinOverlay, kJamBackdropMaxOverlay)
      .toDouble();
}

/// Builds the backdrop for a cover whose mean colour is [mean].
JamBackdrop backdropFromMean({
  required String id,
  required ImageProvider image,
  required Color mean,
}) {
  final overlay = backdropOverlayFor(mean.computeLuminance());
  final base = Color.alphaBlend(
    const Color(0xFF000000).withValues(alpha: overlay),
    mean.withValues(alpha: 1),
  );
  return JamBackdrop(id: id, image: image, overlayOpacity: overlay, base: base);
}

/// Decodes [bytes] at a thumbnail size and returns its mean colour, or null
/// when the bytes do not decode.
Future<Color?> meanColorOf(Uint8List bytes) async {
  if (bytes.isEmpty) return null;
  try {
    final codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: 16,
      targetHeight: 16,
    );
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    image.dispose();
    codec.dispose();
    if (data == null) return null;
    var r = 0.0, g = 0.0, b = 0.0, n = 0;
    for (var i = 0; i + 3 < data.lengthInBytes; i += 4) {
      final a = data.getUint8(i + 3) / 255;
      if (a == 0) continue;
      r += data.getUint8(i) * a;
      g += data.getUint8(i + 1) * a;
      b += data.getUint8(i + 2) * a;
      n++;
    }
    if (n == 0) return null;
    int c(double v) => math.min(255, (v / n).round());
    return Color.fromARGB(255, c(r), c(g), c(b));
  } on Object {
    return null;
  }
}

/// Derives the backdrop for a cover. Prefer [JamBackdropCache.resolve].
Future<JamBackdrop> backdropFor(String id, Uint8List bytes) async {
  final mean = await meanColorOf(bytes);
  if (mean == null) return JamBackdrop.placeholder;
  return backdropFromMean(id: id, image: MemoryImage(bytes), mean: mean);
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
