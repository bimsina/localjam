import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/design/artwork_tint.dart';

Future<Uint8List> _solidPng(Color color) async {
  final recorder = ui.PictureRecorder();
  Canvas(
    recorder,
  ).drawRect(const Rect.fromLTWH(0, 0, 8, 8), Paint()..color = color);
  final image = await recorder.endRecording().toImage(8, 8);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

void main() {
  group('backdropOverlayFor', () {
    test('dark covers get the spec floor', () {
      expect(backdropOverlayFor(0.0), kJamBackdropMinOverlay);
      expect(backdropOverlayFor(0.05), kJamBackdropMinOverlay);
    });

    test('pale covers get more black, capped', () {
      final pale = backdropOverlayFor(0.6);
      expect(pale, greaterThan(kJamBackdropMinOverlay));
      expect(pale, lessThanOrEqualTo(kJamBackdropMaxOverlay));
      expect(
        backdropOverlayFor(1.0),
        lessThanOrEqualTo(kJamBackdropMaxOverlay),
      );
      expect(backdropOverlayFor(1.0), greaterThan(0.6));
    });

    test('secondary text (white 70%) clears AA on every grey (§10.7)', () {
      for (var l = 0.0; l <= 1.0; l += 0.02) {
        final v = l <= 0.0031308
            ? 12.92 * l
            : 1.055 * math.pow(l, 1 / 2.4) - 0.055;
        final c = (v.clamp(0.0, 1.0) * 255).round();
        final grey = Color.fromARGB(255, c, c, c);
        final ground = jamDarken(grey, backdropOverlayFor(l));
        expect(
          jamSecondaryContrastOn(ground),
          greaterThanOrEqualTo(4.5),
          reason: 'luminance $l',
        );
      }
    });

    test('and on saturated colours, solved per colour', () {
      for (final cover in const [
        Color(0xFFFFE4EC), // pale pink
        Color(0xFFFFB347), // bright orange
        Color(0xFF00FFFF), // cyan
        Color(0xFFFFFF00), // yellow
        Color(0xFF4A2B7F), // deep purple
      ]) {
        final ground = jamDarken(cover, backdropOverlayForColor(cover));
        expect(
          jamSecondaryContrastOn(ground),
          greaterThanOrEqualTo(4.5),
          reason: '$cover',
        );
      }
    });
  });

  group('saturation', () {
    test('is boosted before darkening, keeping the hue', () {
      const pale = Color(0xFFD8B4C0);
      final boosted = jamSaturate(pale, kJamBackdropSaturation);
      final hsvBefore = HSVColor.fromColor(pale);
      final hsvAfter = HSVColor.fromColor(boosted);
      expect(hsvAfter.saturation, greaterThan(hsvBefore.saturation));
      expect(hsvAfter.hue, closeTo(hsvBefore.hue, 6));
    });

    test('leaves greys grey', () {
      const grey = Color(0xFF808080);
      expect(jamSaturate(grey, kJamBackdropSaturation), grey);
    });

    test('is monotonic in luminance', () {
      var last = 0.0;
      for (var l = 0.0; l <= 1.0; l += 0.05) {
        final a = backdropOverlayFor(l);
        expect(a, greaterThanOrEqualTo(last));
        last = a;
      }
    });
  });

  group('backdropFromMean', () {
    test('darkens the flat base by the overlay', () {
      final b = backdropFromMean(
        id: 'a',
        image: MemoryImage(Uint8List(1)),
        mean: const Color(0xFF808080),
      );
      expect(b.isPlaceholder, isFalse);
      expect(b.id, 'a');
      expect(
        b.base.computeLuminance(),
        lessThan(const Color(0xFF808080).computeLuminance()),
      );
    });

    test('the placeholder is flat #1C1C1E with no overlay', () {
      expect(JamBackdrop.placeholder.isPlaceholder, isTrue);
      expect(JamBackdrop.placeholder.base, const Color(0xFF1C1C1E));
      expect(JamBackdrop.placeholder.overlayOpacity, 0);
    });
  });

  testWidgets('derives a stronger overlay for a white cover than a dark one', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final white = await backdropFor('w', await _solidPng(Colors.white));
      final navy = await backdropFor(
        'n',
        await _solidPng(const Color(0xFF101830)),
      );
      expect(white.isPlaceholder, isFalse);
      expect(navy.isPlaceholder, isFalse);
      expect(white.overlayOpacity, greaterThan(navy.overlayOpacity));
      expect(white.overlayOpacity, greaterThan(0.6));
      expect(navy.overlayOpacity, kJamBackdropMinOverlay);
      // The flat stand-in still holds secondary text.
      expect(jamSecondaryContrastOn(white.base), greaterThanOrEqualTo(4.5));
    });
  });

  testWidgets('bytes that do not decode fall back to the placeholder', (
    tester,
  ) async {
    await tester.runAsync(() async {
      expect(await backdropFor('x', Uint8List(0)), JamBackdrop.placeholder);
      expect(
        await backdropFor('y', Uint8List.fromList([1, 2, 3, 4])),
        JamBackdrop.placeholder,
      );
    });
  });

  group('JamBackdropCache', () {
    final image = MemoryImage(Uint8List(1));
    JamBackdrop fake(String id) => JamBackdrop(
      id: id,
      image: image,
      overlayOpacity: 0.3,
      base: const Color(0xFF112233),
    );

    test('peek misses until stored', () {
      final cache = JamBackdropCache();
      expect(cache.peek('a'), isNull);
      cache.store('a', fake('a'));
      expect(cache.peek('a'), fake('a'));
    });

    test('evicts least recently used past capacity', () async {
      final cache = JamBackdropCache(capacity: 2)
        ..store('a', fake('a'))
        ..store('b', fake('b'));
      await cache.resolve('a', Uint8List(0)); // a is now most recent
      cache.store('c', fake('c'));
      expect(cache.peek('b'), isNull);
      expect(cache.peek('a'), isNotNull);
      expect(cache.peek('c'), isNotNull);
      expect(cache.length, 2);
      cache.clear();
      expect(cache.length, 0);
    });
  });
}
