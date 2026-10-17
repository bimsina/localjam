import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/design/artwork_tint.dart';
import 'package:localjam_app/src/design/tokens.dart';

void main() {
  group('clampTint', () {
    test('drags a neon cover back into the band', () {
      // Pure electric cyan: saturation 1.0, lightness 0.5.
      final tint = clampTint(const Color(0xFF00FFFF), Brightness.light);
      final hsl = HSLColor.fromColor(tint.base);
      expect(tint.isFallback, isFalse);
      expect(hsl.saturation, lessThanOrEqualTo(0.60 + 0.01));
      expect(hsl.saturation, greaterThanOrEqualTo(0.28 - 0.01));
      expect(hsl.lightness, closeTo(0.46, 0.01));
      // The hue survives — a cyan cover still washes the room cyan.
      expect(hsl.hue, closeTo(180, 1));
    });

    test('lifts a nearly-flat cover up to the floor saturation', () {
      // A dull olive: saturation ~0.17 — enough colour to keep, not to see.
      final tint = clampTint(const Color(0xFF706A50), Brightness.light);
      expect(tint.isFallback, isFalse);
      expect(
        HSLColor.fromColor(tint.base).saturation,
        greaterThanOrEqualTo(0.28 - 0.01),
      );
    });

    test('pins lightness per theme, so the wash sits where it is drawn', () {
      const source = Color(0xFF1B0F3A); // Very dark indigo.
      expect(
        HSLColor.fromColor(clampTint(source, Brightness.light).base).lightness,
        closeTo(0.46, 0.01),
      );
      expect(
        HSLColor.fromColor(clampTint(source, Brightness.dark).base).lightness,
        closeTo(0.58, 0.01),
      );
    });

    test('rejects covers with no colour in them', () {
      for (final grey in [
        const Color(0xFF000000),
        const Color(0xFFFFFFFF),
        const Color(0xFF808080),
        const Color(0xFF8A8288), // Saturation ~0.04.
      ]) {
        final tint = clampTint(grey, Brightness.light);
        expect(tint.isFallback, isTrue, reason: '$grey should fall back');
        expect(tint.base, JamColors.brandRaspberry);
      }
    });

    test('the deep end is darker than the base', () {
      final tint = clampTint(const Color(0xFFD9366B), Brightness.light);
      expect(
        HSLColor.fromColor(tint.deep).lightness,
        lessThan(HSLColor.fromColor(tint.base).lightness),
      );
    });

    test('lerps between two tints', () {
      final a = clampTint(const Color(0xFFFF0000), Brightness.light);
      final b = clampTint(const Color(0xFF0000FF), Brightness.light);
      expect(JamTint.lerp(a, b, 0), a);
      expect(JamTint.lerp(a, b, 1), b);
      expect(JamTint.lerp(a, b, 0.5).base, isNot(a.base));
    });
  });

  group('tintFor', () {
    test('undecodable bytes fall back rather than throwing', () async {
      expect(await tintFor(Uint8List(0), Brightness.light), JamTint.fallback);
      expect(
        await tintFor(Uint8List.fromList([1, 2, 3, 4]), Brightness.light),
        JamTint.fallback,
      );
    });
  });

  group('JamTintCache', () {
    test('a hit is answerable synchronously', () async {
      final cache = JamTintCache();
      expect(cache.peek('a', Brightness.light), isNull);
      await cache.resolve('a', Uint8List(0), Brightness.light);
      expect(cache.peek('a', Brightness.light), JamTint.fallback);
      // Keyed by brightness too: the same cover tints differently per theme.
      expect(cache.peek('a', Brightness.dark), isNull);
    });

    test('evicts the least recently used past capacity', () async {
      final cache = JamTintCache(capacity: 2);
      const tint = JamTint(base: Color(0xFF112233), deep: Color(0xFF001122));
      cache
        ..store('a', Brightness.light, tint)
        ..store('b', Brightness.light, tint);
      // A hit through resolve marks 'a' as most recently used, which leaves
      // 'b' as the one to drop.
      expect(await cache.resolve('a', Uint8List(0), Brightness.light), tint);
      cache.store('c', Brightness.light, tint);
      expect(cache.length, 2);
      expect(cache.peek('b', Brightness.light), isNull);
      expect(cache.peek('c', Brightness.light), tint);
    });

    test('clears', () async {
      final cache = JamTintCache();
      await cache.resolve('a', Uint8List(0), Brightness.light);
      cache.clear();
      expect(cache.length, 0);
    });
  });
}
