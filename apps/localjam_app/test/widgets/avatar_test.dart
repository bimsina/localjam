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
  // An inner Theme, not just MaterialApp's: MaterialApp animates a theme
  // change, so a single pump would still be halfway through the old palette.
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
    testWidgets('draws initials in both themes', (tester) async {
      for (final dark in [false, true]) {
        await pumpAvatar(
          tester,
          const JamAvatar(name: 'Silky Puffin'),
          dark: dark,
        );
        expect(find.text('SP'), findsOneWidget);
      }
    });

    testWidgets('uses the restated identity colour, per theme', (tester) async {
      await pumpAvatar(tester, const JamAvatar(name: 'Silky Puffin'));
      final light = decorationOf(
        tester,
        find.descendant(
          of: find.byType(JamAvatar),
          matching: find.byType(Container),
        ),
      );
      expect(light.color, JamAvatar.colorFor('Silky Puffin', Brightness.light));
      expect(HSLColor.fromColor(light.color!).lightness, closeTo(0.44, 0.01));

      await pumpAvatar(
        tester,
        const JamAvatar(name: 'Silky Puffin'),
        dark: true,
      );
      final dark = decorationOf(
        tester,
        find.descendant(
          of: find.byType(JamAvatar),
          matching: find.byType(Container),
        ),
      );
      expect(HSLColor.fromColor(dark.color!).lightness, closeTo(0.66, 0.01));
    });

    testWidgets('rings the host in accent and you in highlight', (
      tester,
    ) async {
      final finder = find.descendant(
        of: find.byType(JamAvatar),
        matching: find.byType(Container),
      );

      await pumpAvatar(
        tester,
        const JamAvatar(name: 'Silky Puffin', ring: JamAvatarRing.host),
      );
      expect(
        (decorationOf(tester, finder).border! as Border).top.color,
        JamColors.light.accent,
      );

      await pumpAvatar(
        tester,
        const JamAvatar(name: 'Silky Puffin', ring: JamAvatarRing.you),
      );
      expect(
        (decorationOf(tester, finder).border! as Border).top.color,
        JamColors.light.highlight,
      );

      await pumpAvatar(tester, const JamAvatar(name: 'Silky Puffin'));
      expect(decorationOf(tester, finder).border, isNull);
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
    testWidgets('collapses the overflow into a +N chip', (tester) async {
      await pumpAvatar(
        tester,
        const JamAvatarStack(
          names: ['One Fox', 'Two Owl', 'Three Bat', 'Four Elk', 'Five Ram'],
        ),
      );
      expect(find.byType(JamAvatar), findsNWidgets(4));
      expect(find.text('+1'), findsOneWidget);
    });

    testWidgets('overlaps by -0.32 of the diameter', (tester) async {
      const size = 24.0;
      await pumpAvatar(
        tester,
        const JamAvatarStack(names: ['One Fox', 'Two Owl'], size: size),
      );
      // Two faces, each with a 2 dp ring, pulled back 0.32 × size.
      const outer = size + 4;
      const expected = outer + (outer - size * 0.32);
      expect(
        tester.getSize(find.byType(JamAvatarStack)).width,
        closeTo(expected, 0.01),
      );
    });

    testWidgets('rings you over the host, and announces everyone', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpAvatar(
        tester,
        const JamAvatarStack(
          names: ['One Fox', 'Two Owl', 'Three Bat'],
          hostName: 'One Fox',
          youName: 'Two Owl',
          maxVisible: 2,
        ),
      );
      final avatars = tester
          .widgetList<JamAvatar>(find.byType(JamAvatar))
          .toList();
      expect(avatars[0].ring, JamAvatarRing.host);
      expect(avatars[1].ring, JamAvatarRing.you);
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
