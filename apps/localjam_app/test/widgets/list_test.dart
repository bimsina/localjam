import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart' show kPressTimeout;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/design/theme.dart';
import 'package:localjam_app/src/design/tokens.dart';
import 'package:localjam_app/src/widgets/avatar.dart';
import 'package:localjam_app/src/widgets/buttons.dart';
import 'package:localjam_app/src/widgets/list.dart';
import 'package:localjam_app/src/widgets/section.dart';

Widget _host(Widget child, {bool dark = false}) {
  final theme = dark ? jamDarkTheme() : jamLightTheme();
  return MaterialApp(
    theme: theme,
    home: Theme(
      data: theme,
      child: Scaffold(
        backgroundColor: theme.extension<JamColors>()!.groupedBackground,
        body: ListView(children: [child]),
      ),
    ),
  );
}

void main() {
  group('JamRow', () {
    testWidgets('44 tall with a title, 60 with a subtitle', (tester) async {
      await tester.pumpWidget(_host(const JamRow(title: 'Appearance')));
      expect(tester.getSize(find.byType(JamRow)).height, 44);
      final title = tester.widget<Text>(find.text('Appearance')).style!;
      expect(title.fontSize, 17);
      expect(title.fontWeight, FontWeight.w400);

      await tester.pumpWidget(
        _host(const JamRow(title: 'Mia', subtitle: 'Host')),
      );
      expect(tester.getSize(find.byType(JamRow)).height, 60);
      final sub = tester.widget<Text>(find.text('Host')).style!;
      expect(sub.fontSize, 15);
      expect(sub.color, JamColors.light.secondaryLabel);
    });

    testWidgets('value + chevron trail; checkmark in tint', (tester) async {
      await tester.pumpWidget(
        _host(const JamRow(title: 'Name', value: 'Mia', chevron: true)),
      );
      expect(find.byIcon(CupertinoIcons.chevron_forward), findsOneWidget);
      expect(
        tester.widget<Text>(find.text('Mia')).style!.color,
        JamColors.light.secondaryLabel,
      );
      await tester.pumpWidget(
        _host(const JamRow(title: 'Dark', checked: true)),
      );
      expect(
        tester.widget<Icon>(find.byIcon(CupertinoIcons.checkmark)).color,
        JamColors.light.tint,
      );
    });

    testWidgets('an icon sits in a 30 box in tint; tinted rows are actions', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          JamRow(
            title: 'Add Songs',
            icon: CupertinoIcons.plus,
            tinted: true,
            onTap: () {},
          ),
        ),
      );
      final icon = tester.widget<Icon>(find.byIcon(CupertinoIcons.plus));
      expect(icon.size, 22);
      expect(icon.color, JamColors.light.tint);
      expect(
        tester.widget<Text>(find.text('Add Songs')).style!.color,
        JamColors.light.tint,
      );
    });

    testWidgets('destructive + centred', (tester) async {
      await tester.pumpWidget(
        _host(
          JamRow(
            title: 'End Jam',
            destructive: true,
            centered: true,
            onTap: () {},
          ),
        ),
      );
      final text = tester.widget<Text>(find.text('End Jam'));
      expect(text.style!.color, JamColors.light.danger);
      expect(text.textAlign, TextAlign.center);
      expect(
        tester.getCenter(find.text('End Jam')).dx,
        closeTo(tester.getCenter(find.byType(JamRow)).dx, 1),
      );
    });

    testWidgets('press highlight is fillPressed; no ink; taps fire', (
      tester,
    ) async {
      var taps = 0;
      await tester.pumpWidget(
        _host(JamRow(title: 'Diagnostics', onTap: () => taps++)),
      );
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(JamRow)),
      );
      // Inside a scroll view the highlight waits out the tap slop, as on iOS.
      await tester.pump(kPressTimeout);
      final fills = tester
          .widgetList<DecoratedBox>(
            find.descendant(
              of: find.byType(JamRow),
              matching: find.byType(DecoratedBox),
            ),
          )
          .map((b) => (b.decoration as BoxDecoration).color);
      expect(fills, contains(JamColors.light.fillPressed));
      expect(find.byType(InkWell), findsNothing);
      await gesture.up();
      await tester.pump();
      expect(taps, 1);
    });

    testWidgets('a toggle row flips from the switch and from the row', (
      tester,
    ) async {
      var value = false;
      await tester.pumpWidget(
        _host(
          StatefulBuilder(
            builder: (context, setState) => JamRow.toggle(
              title: 'Show to People Nearby',
              value: value,
              onChanged: (v) => setState(() => value = v),
            ),
          ),
        ),
      );
      expect(find.byType(CupertinoSwitch), findsOneWidget);
      await tester.tap(find.byType(CupertinoSwitch));
      await tester.pumpAndSettle();
      expect(value, isTrue);
      await tester.tap(find.text('Show to People Nearby'));
      await tester.pumpAndSettle();
      expect(value, isFalse);
    });

    testWidgets('one semantics node: the button flag, its tap and the '
        'title together', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(JamRow(title: 'Appearance', subtitle: 'System', onTap: () {})),
      );
      expect(
        tester.getSemantics(find.text('Appearance')),
        matchesSemantics(
          label: 'Appearance\nSystem',
          isButton: true,
          hasTapAction: true,
          hasEnabledState: true,
          isEnabled: true,
        ),
      );
      handle.dispose();
    });

    testWidgets('the separator is inset to the title past the leading', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const JamSection(
            children: [
              JamRow(title: 'One', icon: CupertinoIcons.person),
              JamRow(title: 'Two', icon: CupertinoIcons.person),
            ],
          ),
        ),
      );
      final hairline = find.byType(JamHairline);
      expect(hairline, findsOneWidget);
      final left = tester.getTopLeft(hairline).dx;
      final titleLeft = tester.getTopLeft(find.text('One')).dx;
      expect(left, closeTo(titleLeft, 0.5));
    });

    testWidgets('a small trailing button stays tappable', (tester) async {
      var joins = 0;
      await tester.pumpWidget(
        _host(
          JamRow(
            title: 'Van Jam',
            leading: const JamAvatar(name: 'Mia', size: 44),
            trailing: JamButton.tinted(
              label: 'Join',
              size: JamButtonSize.small,
              onPressed: () => joins++,
            ),
          ),
        ),
      );
      await tester.tap(find.text('Join'));
      expect(joins, 1);
    });
  });

  group('JamSection', () {
    testWidgets('inset grouped: radius, surface, page margin, header/footer', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const JamSection(
            header: 'Appearance',
            footer: 'Follows your device.',
            children: [JamRow(title: 'System', checked: true)],
          ),
        ),
      );
      final clip = tester.widget<ClipRRect>(
        find.descendant(
          of: find.byType(JamSection),
          matching: find.byType(ClipRRect),
        ),
      );
      expect(clip.borderRadius, BorderRadius.circular(JamRadius.section));
      expect(
        tester
            .widgetList<ColoredBox>(
              find.descendant(
                of: find.byType(JamSection),
                matching: find.byType(ColoredBox),
              ),
            )
            .map((b) => b.color),
        contains(JamColors.light.groupedSurface),
      );
      expect(
        tester.getTopLeft(find.byType(ClipRRect)).dx,
        JamSpace.pageFor(800),
      );
      final header = tester.widget<Text>(find.text('Appearance')).style!;
      expect(header.fontSize, 13);
      expect(header.color, JamColors.light.secondaryLabel);
      expect(
        tester.widget<Text>(find.text('Follows your device.')).style!.fontSize,
        13,
      );
    });

    testWidgets('plain sections run edge to edge with no block', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const JamSection.plain(
            header: 'Recent',
            children: [JamRow(title: 'Van Jam')],
          ),
        ),
      );
      expect(
        find.descendant(
          of: find.byType(JamSection),
          matching: find.byType(ClipRRect),
        ),
        findsNothing,
      );
      expect(tester.widget<Text>(find.text('Recent')).style!.fontSize, 20);
    });

    testWidgets('non-row children get a hairline between them', (tester) async {
      await tester.pumpWidget(
        _host(
          const JamSection(
            children: [SizedBox(height: 20), SizedBox(height: 20)],
          ),
        ),
      );
      expect(find.byType(JamHairline), findsOneWidget);
    });

    testWidgets('dark uses the dark grouped surface', (tester) async {
      await tester.pumpWidget(
        _host(
          const JamSection(children: [JamRow(title: 'System')]),
          dark: true,
        ),
      );
      expect(
        tester
            .widgetList<ColoredBox>(find.byType(ColoredBox))
            .map((b) => b.color),
        contains(JamColors.dark.groupedSurface),
      );
    });
  });
}
