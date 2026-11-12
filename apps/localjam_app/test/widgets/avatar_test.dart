import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/design/theme.dart';
import 'package:localjam_app/src/design/tokens.dart';
import 'package:localjam_app/src/widgets/avatar.dart';
import 'package:material_ui/material_ui.dart';

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

    test('one person, one colour: a pure function of the name', () {
      // Pinned slots, shared with the web guest's page (apps/localjam_web
      // test/page_test.dart pins the same names to the same slots): FNV-1a
      // over the UTF-16 code units, modulo the palette.
      const slots = {
        'Priya': 0,
        'Theo': 1,
        'Bibek': 2,
        'Sam': 4,
        'Maya': 5,
        'Mia': 6,
        'Zoë': 7,
      };
      for (final MapEntry(key: name, value: slot) in slots.entries) {
        expect(identityColorIndex(name), slot, reason: name);
        expect(identityColor(name), kJamAvatarPalette[slot], reason: name);
      }
    });

    test('a jam\'s faces: nobody moves when somebody else joins', () {
      // The report: a guest's colour changed when someone else joined, and
      // Past Jams drew the same people in other colours again.
      final before = jamPeopleColors(['Bibek', 'Mia']);
      final after = jamPeopleColors(['Theo', 'Mia', 'Bibek', 'Priya']);
      expect(after['Bibek'], before['Bibek']);
      expect(after['Mia'], before['Mia']);
      for (final MapEntry(key: name, value: color) in after.entries) {
        expect(color, identityColor(name), reason: name);
      }
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

    testWidgets('by name, each face in the pile is its name\'s own colour', (
      tester,
    ) async {
      const names = ['Bibek', 'Mia', 'Theo'];
      await pumpAvatar(tester, const JamAvatarStack(names: names));
      final colors = tester
          .widgetList<JamAvatar>(find.byType(JamAvatar))
          .map((a) => a.resolvedColor)
          .toList();
      expect(colors, [for (final n in names) identityColor(n)]);
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

  testWidgets('a face beside text grows with it, up to 1.5× (RB-17)', (
    tester,
  ) async {
    late double plain, large, huge;
    Widget probe(double scale, void Function(double) out) => MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(scale)),
      child: Builder(
        builder: (context) {
          out(JamAvatarSize.scaled(context, JamAvatarSize.credit));
          return const SizedBox.shrink();
        },
      ),
    );
    await tester.pumpWidget(probe(1, (v) => plain = v));
    await tester.pumpWidget(probe(1.3, (v) => large = v));
    await tester.pumpWidget(probe(3, (v) => huge = v));
    expect(plain, JamAvatarSize.credit);
    expect(large, closeTo(JamAvatarSize.credit * 1.3, 0.01));
    expect(huge, JamAvatarSize.credit * 1.5);
    expect(JamAvatarSize.credit, greaterThanOrEqualTo(18));
  });

  testWidgets('a face grown with its text keeps its design size\'s letters: '
      'one person reads the same way across a screen', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: jamLightTheme(),
        home: const Row(
          children: [
            // The credit at 1.5×: 27 across, but an 18 face.
            JamAvatar(
              name: 'Electric Mongoose Supreme',
              size: JamAvatarSize.credit * 1.5,
              tokenSize: JamAvatarSize.credit,
            ),
            JamAvatar(
              name: 'Electric Mongoose Supreme',
              size: JamAvatarSize.strip,
            ),
          ],
        ),
      ),
    );
    expect(find.text('E'), findsNWidgets(2));
    expect(find.text('ES'), findsNothing);
  });
}
