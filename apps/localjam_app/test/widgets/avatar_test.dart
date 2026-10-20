import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/design/theme.dart';
import 'package:localjam_app/src/design/tokens.dart';
import 'package:localjam_app/src/widgets/avatar.dart';

Future<void> pumpAvatar(
  WidgetTester tester,
  Widget child, {
  bool dark = false,
}) {
  final theme = dark ? jamDarkTheme() : jamLightTheme();
  return tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: Theme(
        data: theme,
        child: Scaffold(body: Center(child: child)),
      ),
    ),
  );
}

BoxDecoration decorationOf(WidgetTester tester, Finder finder) =>
    tester.widget<Container>(finder).decoration! as BoxDecoration;

void main() {
  group('JamAvatar', () {
    testWidgets('draws white Manrope initials in both themes', (tester) async {
      for (final dark in [false, true]) {
        await pumpAvatar(
          tester,
          const JamAvatar(name: 'Silky Puffin'),
          dark: dark,
        );
        expect(find.text('SP'), findsOneWidget);
        final text = tester.widget<Text>(find.text('SP'));
        expect(text.style!.color, Colors.white);
        expect(text.style!.fontWeight, FontWeight.w700);
        expect(text.style!.fontFamily, 'Manrope');
      }
    });

    testWidgets('a flat palette colour, no ring, the same in both themes', (
      tester,
    ) async {
      final finder = find.descendant(
        of: find.byType(JamAvatar),
        matching: find.byType(Container),
      );
      await pumpAvatar(tester, const JamAvatar(name: 'Silky Puffin'));
      final light = decorationOf(tester, finder);
      expect(kJamAvatarPalette, contains(light.color));
      expect(light.border, isNull);
      expect(light.gradient, isNull);

      await pumpAvatar(
        tester,
        const JamAvatar(name: 'Silky Puffin'),
        dark: true,
      );
      expect(decorationOf(tester, finder).color, light.color);
    });

    test('every palette colour holds white initials at 4.5:1', () {
      for (final c in kJamAvatarPalette) {
        final ratio = 1.05 / (c.computeLuminance() + 0.05);
        expect(ratio, greaterThanOrEqualTo(4.5), reason: '$c');
      }
    });

    test('eight warm hues at one lightness, none near raspberry', () {
      expect(kJamAvatarPalette.toSet(), hasLength(8));
      final lums = [for (final c in kJamAvatarPalette) c.computeLuminance()];
      final spread =
          lums.reduce((a, b) => a > b ? a : b) -
          lums.reduce((a, b) => a < b ? a : b);
      expect(spread, lessThan(0.01));
      final tint = HSLColor.fromColor(JamColors.light.tint).hue;
      for (final c in kJamAvatarPalette) {
        final d = (HSLColor.fromColor(c).hue - tint).abs() % 360;
        expect(d < 180 ? d : 360 - d, greaterThan(25), reason: '$c');
      }
    });

    test('one person, one colour: the jam starts from the name\'s own', () {
      const roster = ['Bibek', 'Mia', 'Theo'];
      final colors = jamAvatarColors(roster);
      expect(colors.first, identityColor('Bibek'));
      expect(colors.toSet(), hasLength(3));
      for (var i = 0; i < roster.length; i++) {
        // Nobody earlier took their slot, so everyone keeps their own.
        if (!roster
            .take(i)
            .any((n) => identityColor(n) == identityColor(roster[i]))) {
          expect(colors[i], identityColor(roster[i]));
        }
      }
    });

    test('jam colours: stable per id, distinct while the palette lasts', () {
      final ids = [for (var i = 0; i < 8; i++) 'client-$i'];
      final colors = jamAvatarColors(ids);
      expect(colors.toSet().length, 8);
      // The first person keeps their own colour; order decides the rest.
      expect(colors.first, jamAvatarColorForKey(ids.first));
      expect(jamAvatarColors(ids), colors);
      // The same id twice is the same person.
      expect(jamAvatarColors(['x', 'x']).toSet().length, 1);
      // A ninth person starts the palette over rather than failing.
      expect(jamAvatarColors([...ids, 'client-8']).length, 9);
    });

    testWidgets('colorKey picks the colour from the id, not the name', (
      tester,
    ) async {
      await pumpAvatar(
        tester,
        const JamAvatar(name: 'Silky Puffin', colorKey: 'device-42'),
      );
      expect(
        tester.widget<JamAvatar>(find.byType(JamAvatar)).resolvedColor,
        jamAvatarColorForKey('device-42'),
      );
    });

    testWidgets('announces the person, not their initials', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpAvatar(tester, const JamAvatar(name: 'Silky Puffin'));
      expect(find.bySemanticsLabel('Silky Puffin'), findsOneWidget);
      expect(find.bySemanticsLabel('SP'), findsNothing);
      handle.dispose();
    });
  });

  group('JamAvatarStack', () {
    testWidgets('shows three faces then +N in secondaryLabel', (tester) async {
      await pumpAvatar(
        tester,
        const JamAvatarStack(
          names: ['One Fox', 'Two Owl', 'Three Bat', 'Four Elk', 'Five Ram'],
        ),
      );
      expect(find.byType(JamAvatar), findsNWidgets(3));
      expect(find.text('+2'), findsOneWidget);
      expect(
        tester.widget<Text>(find.text('+2')).style!.color,
        JamColors.light.secondaryLabel,
      );
    });

    testWidgets('overlaps by 25%, the covered face knocked out, not ringed', (
      tester,
    ) async {
      const size = 24.0;
      await pumpAvatar(
        tester,
        const JamAvatarStack(names: ['One Fox', 'Two Owl'], size: size),
      );
      const expected = size * 0.75 + size;
      expect(
        tester.getSize(find.byType(JamAvatarStack)).width,
        closeTo(expected, 0.01),
      );
      // A real hole in the covered face — no painted ring guessing at the
      // colour behind the pile.
      expect(find.byType(ClipPath), findsOneWidget);
      final rings = tester
          .widgetList<Container>(
            find.descendant(
              of: find.byType(JamAvatarStack),
              matching: find.byType(Container),
            ),
          )
          .where((c) => (c.decoration as BoxDecoration?)?.color == null);
      expect(rings, isEmpty);
    });

    testWidgets('at 24 and under a face shows one initial', (tester) async {
      await pumpAvatar(
        tester,
        const JamAvatarStack(names: ['Sparkly Kiwi', 'Electric Mongoose']),
      );
      expect(find.text('S'), findsOneWidget);
      expect(find.text('E'), findsOneWidget);
      expect(find.text('SK'), findsNothing);
      await pumpAvatar(
        tester,
        const JamAvatar(name: 'Sparkly Kiwi', size: JamAvatarSize.identity),
      );
      expect(find.text('SK'), findsOneWidget);
    });

    testWidgets('with ids, nobody in the pile shares a colour', (tester) async {
      const names = ['A', 'B', 'C'];
      const ids = ['id-1', 'id-2', 'id-3'];
      await pumpAvatar(
        tester,
        const JamAvatarStack(names: names, colorKeys: ids),
      );
      final colors = tester
          .widgetList<JamAvatar>(find.byType(JamAvatar))
          .map((a) => a.resolvedColor)
          .toList();
      expect(colors, jamAvatarColors(ids));
      expect(colors.toSet().length, 3);
    });

    testWidgets('by name, nobody in the pile shares a colour either', (
      tester,
    ) async {
      const names = ['Bibek', 'Mia', 'Theo'];
      await pumpAvatar(tester, const JamAvatarStack(names: names));
      final colors = tester
          .widgetList<JamAvatar>(find.byType(JamAvatar))
          .map((a) => a.resolvedColor)
          .toList();
      expect(colors, jamAvatarColors(names));
      expect(colors.toSet(), hasLength(3));
    });

    testWidgets('announces everyone', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpAvatar(
        tester,
        const JamAvatarStack(
          names: ['One Fox', 'Two Owl', 'Three Bat'],
          maxVisible: 2,
        ),
      );
      expect(
        find.bySemanticsLabel('One Fox, Two Owl and 1 more'),
        findsOneWidget,
      );
      handle.dispose();
    });

    testWidgets('draws nothing when the room is empty', (tester) async {
      await pumpAvatar(tester, const JamAvatarStack(names: []));
      expect(find.byType(JamAvatar), findsNothing);
    });
  });
}
