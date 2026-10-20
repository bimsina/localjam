import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/design/theme.dart';
import 'package:localjam_app/src/design/tokens.dart';
import 'package:localjam_app/src/widgets/avatar.dart';
import 'package:localjam_app/src/widgets/jam_mark.dart';

/// A 1×1 PNG.
final _pixel = MemoryImage(
  base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
  ),
);

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  bool dark = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: dark ? jamDarkTheme() : jamLightTheme(),
      home: Scaffold(body: Center(child: child)),
    ),
  );
  // The theme animates between palettes, and a mark cross-fades its art.
  await tester.pumpAndSettle();
}

ShapeDecoration _ground(WidgetTester tester) => tester
    .widgetList<DecoratedBox>(
      find.descendant(
        of: find.byType(JamMark),
        matching: find.byType(DecoratedBox),
      ),
    )
    .map((b) => b.decoration)
    .whereType<ShapeDecoration>()
    .firstWhere((d) => d.color != null);

void main() {
  group('JamMark', () {
    testWidgets('without covers: a neutral Manrope monogram, a square', (
      tester,
    ) async {
      for (final dark in [false, true]) {
        await _pump(tester, const JamMark(name: 'sunday at home'), dark: dark);
        final colors = dark ? JamColors.dark : JamColors.light;
        final letter = tester.widget<Text>(find.text('S'));
        expect(letter.style!.fontFamily, 'Manrope');
        expect(letter.style!.fontWeight, FontWeight.w700);
        expect(letter.style!.color, colors.secondaryLabel);
        final ground = _ground(tester);
        // Never a person's colour, never raspberry.
        expect(ground.color, colors.fillSecondary);
        expect(ground.color, isNot(colors.tint));
        expect(kJamAvatarPalette, isNot(contains(ground.color)));
        // A rounded square with continuous corners: music, not a person.
        expect(ground.shape, isA<RoundedSuperellipseBorder>());
        expect(
          (ground.shape as RoundedSuperellipseBorder).borderRadius,
          BorderRadius.circular(JamRadius.artwork(JamMarkSize.nearby)),
        );
        expect(
          tester.getSize(find.byType(JamMark)),
          const Size.square(JamMarkSize.nearby),
        );
      }
    });

    test('the monogram is the first letter or digit, upper-cased', () {
      expect(JamMark.monogramOf('sunday at home'), 'S');
      expect(JamMark.monogramOf('“Mia’s” Jam'), 'M');
      expect(JamMark.monogramOf('  9 to 5'), '9');
      expect(JamMark.monogramOf('élan'), 'É');
      expect(JamMark.monogramOf('!!!'), isNull);
    });

    testWidgets('a name with no letter shows the LocalJam symbol', (
      tester,
    ) async {
      await _pump(tester, const JamMark(name: '♪♪'));
      expect(find.byType(Text), findsNothing);
    });

    testWidgets('one cover fills the tile; four make a mosaic', (tester) async {
      await _pump(tester, JamMark(name: 'Van Jam', covers: [_pixel]));
      expect(find.byType(Image), findsOneWidget);
      expect(find.text('V'), findsNothing);

      await _pump(
        tester,
        JamMark(
          name: 'Van Jam',
          size: JamMarkSize.row,
          covers: [_pixel, _pixel, _pixel, _pixel],
        ),
      );
      expect(find.byType(Image), findsNWidgets(4));
    });

    testWidgets('a known host wears a face on the corner, knocked out', (
      tester,
    ) async {
      await _pump(tester, const JamMark(name: 'Mia’s Jam', hostName: 'Mia'));
      final face = tester.widget<JamAvatar>(find.byType(JamAvatar));
      expect(face.name, 'Mia');
      expect(face.size, JamMark.badgeSizeFor(JamMarkSize.nearby));
      expect(face.resolvedColor, identityColor('Mia'));
      // The badge's centre sits on the tile's corner, inset by 8%.
      final mark = tester.getRect(find.byType(JamMark));
      final badge = tester.getRect(find.byType(JamAvatar));
      const inset = JamMarkSize.nearby * 0.08;
      expect(badge.center.dx, closeTo(mark.right - inset, 0.5));
      expect(badge.center.dy, closeTo(mark.bottom - inset, 0.5));
      // A real hole in the tile, not a painted ring.
      expect(find.byType(ClipPath), findsOneWidget);
      // The row's layout is the tile's: the badge overhangs.
      expect(mark.size, const Size.square(JamMarkSize.nearby));
    });

    testWidgets('no host, no badge — never a guess', (tester) async {
      await _pump(tester, const JamMark(name: 'The late shift'));
      expect(find.byType(JamAvatar), findsNothing);
      await _pump(tester, const JamMark(name: 'The late shift', hostName: ''));
      expect(find.byType(JamAvatar), findsNothing);
    });

    test('badge sizes follow the mark, clamped 16–36', () {
      expect(JamMark.badgeSizeFor(JamMarkSize.nearby), 18);
      expect(JamMark.badgeSizeFor(48), 20);
      expect(JamMark.badgeSizeFor(JamMarkSize.row), 24);
      expect(JamMark.badgeSizeFor(JamMarkSize.ended), 36);
      expect(JamMark.badgeSizeFor(24), 16);
    });

    testWidgets('decorative unless labelled', (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(tester, const JamMark(name: 'Van Jam'));
      expect(find.bySemanticsLabel('Van Jam'), findsNothing);
      await _pump(
        tester,
        const JamMark(name: 'Van Jam', semanticLabel: 'Van Jam'),
      );
      expect(find.bySemanticsLabel('Van Jam'), findsOneWidget);
      handle.dispose();
    });
  });
}
