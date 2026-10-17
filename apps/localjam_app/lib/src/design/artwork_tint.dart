/// Artwork-derived ambient colour.
///
/// The one place the app lets something other than the palette pick a colour:
/// the cover of the track that is playing washes the room's background. It is
/// deliberately narrow. The tint may ground the room screen, the glow behind
/// the hero artwork and the left edge of the docked room bar — and nothing
/// else. Never text, icons, transport, dividers or the sync indicator, so no
/// cover, however lurid, can break a contrast ratio.
///
/// Derivation is the stock [ColorScheme.fromImageProvider] (no new
/// dependency), then clamped hard in HSL so a neon sleeve and a muddy one both
/// land in the same band of saturation and lightness. Covers with almost no
/// colour in them — black-and-white photography, plain type on grey — are
/// rejected outright and fall back to the brand raspberry, which looks
/// deliberate where a desaturated "tint" would just look broken.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'tokens.dart';

/// A resolved ambient tint: the colour itself, plus the deeper end used when
/// it is painted as a gradient.
@immutable
class JamTint {
  const JamTint({
    required this.base,
    required this.deep,
    this.isFallback = false,
  });

  /// The clamped tint. Everything in §2.2 is drawn from this at low alpha.
  final Color base;

  /// The far end of a gradient from [base] — a step deeper and slightly less
  /// bright, so the wash has direction rather than being a flat panel.
  final Color deep;

  /// Whether this is the brand fallback rather than a colour taken from the
  /// artwork. Call sites do not usually care; the flag exists so the room can
  /// skip the cross-fade when one grey cover follows another.
  final bool isFallback;

  /// The brand gradient, used when a cover has no usable colour and when
  /// there is no artwork at all.
  static const JamTint fallback = JamTint(
    base: JamColors.brandRaspberry,
    deep: Color(0xFFC71F5E),
    isFallback: true,
  );

  @override
  bool operator ==(Object other) =>
      other is JamTint &&
      other.base == base &&
      other.deep == deep &&
      other.isFallback == isFallback;

  @override
  int get hashCode => Object.hash(base, deep, isFallback);

  /// Cross-fade between two tints. Pair with [JamDuration.ambient] and
  /// [JamCurve.ambient] when the track changes.
  static JamTint lerp(JamTint a, JamTint b, double t) => JamTint(
    base: Color.lerp(a.base, b.base, t)!,
    deep: Color.lerp(a.deep, b.deep, t)!,
    isFallback: t < 0.5 ? a.isFallback : b.isFallback,
  );

  @override
  String toString() =>
      'JamTint(${base.toARGB32().toRadixString(16)}, fallback: $isFallback)';
}

/// Saturation below which a cover counts as having no colour worth using.
const double _minSourceSaturation = 0.12;

/// The band every accepted tint is squeezed into.
const double _minSaturation = 0.28;
const double _maxSaturation = 0.60;

/// The lightness each theme pins the tint to, so the wash sits at a known
/// distance from the ground whatever the cover does.
const double _lightnessOnLight = 0.46;
const double _lightnessOnDark = 0.58;

/// Clamps a raw colour taken from artwork into the usable band, or returns
/// [JamTint.fallback] when there is not enough colour in it to be worth using.
///
/// Split out from [tintFor] so it can be reasoned about — and tested — without
/// decoding an image.
JamTint clampTint(Color source, Brightness brightness) {
  final hsl = HSLColor.fromColor(source);
  if (hsl.saturation < _minSourceSaturation) return JamTint.fallback;

  final saturation = hsl.saturation.clamp(_minSaturation, _maxSaturation);
  final lightness = brightness == Brightness.dark
      ? _lightnessOnDark
      : _lightnessOnLight;

  final base = HSLColor.fromAHSL(1, hsl.hue, saturation, lightness);
  // The gradient's far end: a touch more saturated and meaningfully darker,
  // which reads as depth rather than as a second colour.
  final deep = HSLColor.fromAHSL(
    1,
    hsl.hue,
    (saturation + 0.06).clamp(_minSaturation, _maxSaturation),
    (lightness - 0.14).clamp(0.0, 1.0),
  );
  return JamTint(base: base.toColor(), deep: deep.toColor());
}

/// Derives the ambient tint for a piece of artwork.
///
/// Decoding and quantising an image is not free — always go through a
/// [JamTintCache] rather than calling this per frame or per rebuild.
Future<JamTint> tintFor(Uint8List bytes, Brightness brightness) async {
  if (bytes.isEmpty) return JamTint.fallback;
  try {
    final scheme = await ColorScheme.fromImageProvider(
      provider: MemoryImage(bytes),
      brightness: brightness,
    );
    return clampTint(scheme.primary, brightness);
  } on Object {
    // A cover we cannot decode is not worth an error path: the brand gradient
    // is a perfectly good answer.
    return JamTint.fallback;
  }
}

/// A small bounded cache of tints, keyed by artwork identity and brightness.
///
/// Hold one next to whatever owns the artwork — the room screen, the engine
/// adapter — so a queue of twelve tracks costs twelve derivations for the life
/// of the jam rather than one per rebuild. Least-recently-used entries are
/// dropped past [capacity], which keeps a long jam from holding every cover's
/// colour forever.
class JamTintCache {
  JamTintCache({this.capacity = 32}) : assert(capacity > 0);

  /// How many resolved tints to keep. A jam's queue is rarely longer.
  final int capacity;

  /// Insertion-ordered, which is what makes the eviction below LRU: a hit
  /// re-inserts the key at the end.
  final Map<String, JamTint> _entries = <String, JamTint>{};
  final Map<String, Future<JamTint>> _inFlight = <String, Future<JamTint>>{};

  /// The tint for [artworkId] if it has already been derived. Synchronous, so
  /// `build` can paint the right colour on the first frame after a hit. A peek
  /// does not count as a use — reading during a build should not reshuffle
  /// what gets evicted.
  JamTint? peek(String artworkId, Brightness brightness) =>
      _entries[_key(artworkId, brightness)];

  /// The tint for [artworkId], deriving it from [bytes] on a miss.
  ///
  /// Concurrent calls for the same key share one derivation.
  Future<JamTint> resolve(
    String artworkId,
    Uint8List bytes,
    Brightness brightness,
  ) {
    final key = _key(artworkId, brightness);
    final hit = _entries.remove(key);
    if (hit != null) {
      _entries[key] = hit; // Re-insert: most recently used.
      return Future<JamTint>.value(hit);
    }
    return _inFlight[key] ??= tintFor(bytes, brightness).then((tint) {
      _inFlight.remove(key);
      _put(key, tint);
      return tint;
    });
  }

  /// Records an already-derived tint — for a cover whose colour arrived from
  /// somewhere other than its bytes.
  void store(String artworkId, Brightness brightness, JamTint tint) =>
      _put(_key(artworkId, brightness), tint);

  /// Forgets everything. Worth calling when a jam ends.
  void clear() {
    _entries.clear();
    _inFlight.clear();
  }

  /// How many tints are currently held.
  int get length => _entries.length;

  void _put(String key, JamTint tint) {
    _entries
      ..remove(key)
      ..[key] = tint;
    while (_entries.length > capacity) {
      _entries.remove(_entries.keys.first);
    }
  }

  static String _key(String artworkId, Brightness brightness) =>
      '${brightness.name}:$artworkId';
}
