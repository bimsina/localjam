import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/design/artwork_tint.dart';
import 'package:localjam_app/src/design/tokens.dart';
import 'package:material_ui/material_ui.dart';

Future<Uint8List> _solidPng(Color color) => _stripesPng([(color, 1)]);

/// A 24×24 PNG of horizontal bands: each colour takes its share of the
/// height.
Future<Uint8List> _stripesPng(List<(Color, double)> bands) async {
  const edge = 24.0;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final total = bands.fold<double>(0, (sum, b) => sum + b.$2);
  var y = 0.0;
  for (final (color, share) in bands) {
    final h = edge * share / total;
    canvas.drawRect(Rect.fromLTWH(0, y, edge, h), Paint()..color = color);
    y += h;
  }
  final image = await recorder.endRecording().toImage(24, 24);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

double _hue(Color c) => HSLColor.fromColor(c).hue;

void main() {
  group('backdropColorFor', () {
    test('secondary text (white 70%) clears AA on every grey (§10.7)', () {
      for (var l = 0.0; l <= 1.0; l += 0.02) {
        final v = l <= 0.0031308
            ? 12.92 * l
            : 1.055 * math.pow(l, 1 / 2.4) - 0.055;
        final c = (v.clamp(0.0, 1.0) * 255).round();
        final ground = backdropColorFor(
          Color.fromARGB(255, c, c, c),
          grey: true,
        );
        expect(
          jamSecondaryContrastOn(ground),
          greaterThanOrEqualTo(4.5),
          reason: 'luminance $l',
        );
      }
    });

    test('and on saturated colours, solved per colour, hue kept', () {
      for (final cover in const [
        Color(0xFFFFE4EC), // pale pink
        Color(0xFFFFB347), // bright orange
        Color(0xFF00FFFF), // cyan
        Color(0xFFB4E628), // lime
        Color(0xFF4A2B7F), // deep purple
        Color(0xFF101830), // navy
      ]) {
        final ground = backdropColorFor(cover);
        expect(
          jamSecondaryContrastOn(ground),
          greaterThanOrEqualTo(4.5),
          reason: '$cover',
        );
        expect(_hue(ground), closeTo(_hue(cover), 1), reason: '$cover');
        final s = HSLColor.fromColor(ground).saturation;
        expect(s, inInclusiveRange(kJamBackdropMinSaturation - 0.01, 0.56));
        expect(
          HSLColor.fromColor(ground).lightness,
          lessThanOrEqualTo(kJamBackdropMaxLightness + 0.005),
        );
      }
    });

    test('pinks near raspberry are held dusty', () {
      for (final cover in const [
        Color(0xFFE0207A), // magenta
        Color(0xFFFF4F8B), // hot pink
        Color(0xFFB82F59), // raspberry itself
      ]) {
        expect(jamHueNearTint(_hue(cover)), isTrue, reason: '$cover');
        expect(
          HSLColor.fromColor(backdropColorFor(cover)).saturation,
          lessThanOrEqualTo(kJamBackdropMaxSaturationNearTint + 0.01),
          reason: '$cover',
        );
      }
      // An orange is nowhere near it, and keeps more colour.
      expect(jamHueNearTint(_hue(const Color(0xFFF08A3C))), isFalse);
    });

    test('greys stay grey — the charcoal\'s warm grey, never a cold one', () {
      for (final cover in const [
        Color(0xFF000000),
        Color(0xFF141414),
        Color(0xFF808080),
        Color(0xFFFFFFFF),
      ]) {
        final ground = backdropColorFor(cover, grey: true);
        final hsl = HSLColor.fromColor(ground);
        expect(hsl.saturation, closeTo(kJamBackdropGreySaturation, 0.02));
        expect(ground.r, greaterThan(ground.g), reason: '$cover');
        expect(ground.g, greaterThan(ground.b), reason: '$cover');
        expect(
          jamSecondaryContrastOn(ground),
          greaterThanOrEqualTo(4.5),
          reason: '$cover',
        );
      }
    });

    test(
      'a dark cover still has a wash, lighter than the charcoal (RB-11)',
      () {
        const charcoal = JamNowPlayingColors.backdropPlaceholder;
        for (final (cover, grey) in const [
          (Color(0xFF000000), true), // black
          (Color(0xFF0B0F1A), false), // near-black navy
          (Color(0xFF281912), false), // dark brown
          (Color(0xFF1A0A2E), false), // deep violet
        ]) {
          final ground = backdropColorFor(cover, grey: grey);
          expect(
            ground.computeLuminance(),
            greaterThan(charcoal.computeLuminance()),
            reason: '$cover',
          );
          expect(
            jamContrastRatio(ground, charcoal),
            greaterThanOrEqualTo(kJamBackdropMinLift - 0.005),
            reason: '$cover',
          );
        }
      },
    );

    test('reds go brick, not mauve; yellows go amber, not olive (RB-12)', () {
      for (final red in const [
        Color(0xFFE6141E), // pure red
        Color(0xFFFF2400), // scarlet
        Color(0xFFC0392B), // brick red
      ]) {
        final hsl = HSLColor.fromColor(backdropColorFor(red));
        expect(hsl.hue, inInclusiveRange(5, 12), reason: '$red');
        expect(hsl.saturation, greaterThan(0.5), reason: '$red');
      }
      for (final yellow in const [
        Color(0xFFFFDD00), // yellow
        Color(0xFFE1AD01), // mustard
        Color(0xFFFFFF00), // lemon
      ]) {
        final ground = backdropColorFor(yellow);
        expect(_hue(ground), inInclusiveRange(36, 47), reason: '$yellow');
        expect(jamSecondaryContrastOn(ground), greaterThanOrEqualTo(4.5));
      }
      // The bend fades out: limes and greens keep their hue.
      expect(jamBackdropHue(80), 80);
      expect(jamBackdropHue(140), 140);
      expect(jamBackdropHue(30), 30);
      // …and the pinks stay pinks, held dusty.
      expect(jamBackdropHue(342), 342);
      expect(jamHueNearTint(350), isTrue);
      expect(jamHueNearTint(357), isFalse);
      expect(jamHueNearTint(315), isFalse);
    });

    test('is monotonic in the cover\'s lightness', () {
      var last = 1.0;
      for (var l = 0.0; l <= 1.0; l += 0.05) {
        final c = (l * 255).round();
        final ground = backdropColorFor(
          Color.fromARGB(255, c, c, c),
          grey: true,
        );
        final now = ground.computeLuminance();
        if (l > 0.5) expect(now, lessThanOrEqualTo(last + 1e-6));
        last = now;
      }
    });
  });

  group('JamBackdrop', () {
    test('the placeholder is the warm charcoal every wash fades into', () {
      expect(JamBackdrop.placeholder.isPlaceholder, isTrue);
      expect(
        JamBackdrop.placeholder.base,
        JamNowPlayingColors.backdropPlaceholder,
      );
      expect(
        const JamBackdrop(id: 'a', base: Color(0xFF112233)).isPlaceholder,
        isFalse,
      );
    });
  });

  testWidgets('a white cover is darkened hard; navy keeps its own depth', (
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
      expect(white.base.computeLuminance(), lessThan(0.15));
      expect(
        HSLColor.fromColor(white.base).saturation,
        lessThanOrEqualTo(kJamBackdropGreySaturation + 0.01),
      );
      expect(white.base.r, greaterThan(white.base.b));
      expect(_hue(navy.base), closeTo(_hue(const Color(0xFF101830)), 4));
      expect(jamSecondaryContrastOn(white.base), greaterThanOrEqualTo(4.5));
      expect(jamSecondaryContrastOn(navy.base), greaterThanOrEqualTo(4.5));
    });
  });

  testWidgets('orange with a teal sky stays orange, never olive', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final cover = await backdropFor(
        'o',
        await _stripesPng([
          (const Color(0xFF2A9D9A), 0.4), // teal sky
          (const Color(0xFFF08A3C), 0.6), // orange ground
        ]),
      );
      final hue = _hue(cover.base);
      expect(hue, inInclusiveRange(15, 40), reason: '${cover.base}');
      expect(jamSecondaryContrastOn(cover.base), greaterThanOrEqualTo(4.5));
    });
  });

  testWidgets('the larger colour family wins, not the brighter one', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final cover = await backdropFor(
        't',
        await _stripesPng([
          (const Color(0xFF2A9D9A), 0.75), // mostly teal
          (const Color(0xFFF08A3C), 0.25),
        ]),
      );
      expect(_hue(cover.base), inInclusiveRange(165, 195));
    });
  });

  testWidgets('a pale cover keeps its hue: dusty rose, not grey', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final pale = await backdropFor(
        'p',
        await _solidPng(const Color(0xFFF5D5DC)),
      );
      final hsl = HSLColor.fromColor(pale.base);
      expect(hsl.saturation, greaterThanOrEqualTo(0.2));
      expect(hsl.saturation, lessThanOrEqualTo(0.31));
      expect(hsl.hue, anyOf(greaterThan(320), lessThan(20)));
      expect(jamSecondaryContrastOn(pale.base), greaterThanOrEqualTo(4.5));
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
    JamBackdrop fake(String id) =>
        JamBackdrop(id: id, base: const Color(0xFF112233));

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
