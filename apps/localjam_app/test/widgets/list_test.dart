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
import 'package:localjam_app/src/widgets/track_row.dart';

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
        tester.widget<Icon>(find.byIcon(CupertinoIcons.checkmark_alt)).color,
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
      // Rounded by its height: 26, held under half a lone row.
      final block = tester.getSize(
        find.descendant(
          of: find.byType(JamSection),
          matching: find.byType(ClipRRect),
        ),
      );
      expect(
        clip.clipper!.getClip(block),
        RRect.fromRectAndRadius(
          Offset.zero & block,
          Radius.circular(JamRadius.sectionFor(block.height)),
        ),
      );
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

  group('one disclosure, one Add Songs', () {
    testWidgets('a chevron row draws the one chevron', (tester) async {
      await tester.pumpWidget(
        _host(const JamRow(title: 'Licenses', chevron: true)),
      );
      final icon = tester.widget<Icon>(
        find.descendant(
          of: find.byType(JamDisclosureChevron),
          matching: find.byType(Icon),
        ),
      );
      expect(icon.icon, CupertinoIcons.chevron_forward);
      expect(icon.size, JamIconSize.disclosure);
      expect(icon.color, JamColors.light.tertiaryLabel);
    });

    testWidgets('a row icon is raspberry only when the row acts (D8)', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(const JamRow(title: 'Version', icon: CupertinoIcons.info)),
      );
      expect(
        tester.widget<Icon>(find.byIcon(CupertinoIcons.info)).color,
        JamColors.light.secondaryLabel,
      );
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
      expect(
        tester.widget<Icon>(find.byIcon(CupertinoIcons.plus)).color,
        JamColors.light.tint,
      );
    });

    testWidgets('a chevron\'s stroke ends where a value does (CR-13)', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(const JamRow(title: 'Appearance', value: 'System')),
      );
      final row = tester.getRect(find.byType(JamRow));
      final valueEnd = tester.getRect(find.text('System')).right;
      expect(valueEnd, closeTo(row.right - kJamRowInset, 0.5));

      await tester.pumpWidget(
        _host(const JamRow(title: 'Licenses', chevron: true)),
      );
      final chevron = tester.getRect(find.byType(Icon));
      // The glyph's box overhangs by its bearing, so its stroke lands on
      // the inset.
      expect(
        chevron.right,
        closeTo(row.right - kJamRowInset + kJamChevronBearing, 0.5),
      );
    });

    testWidgets('a plain list\'s hairline stops at the content (CR-18)', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(const JamRow(title: 'Sunday', separator: true)),
      );
      final row = tester.getRect(find.byType(JamRow));
      final line = tester.getRect(find.byType(JamHairline));
      expect(line.right, closeTo(row.right - kJamRowInset, 0.5));

      // Inside a section it still meets the block's edge.
      await tester.pumpWidget(
        _host(
          const JamSection(
            children: [
              JamRow(title: 'One'),
              JamRow(title: 'Two'),
            ],
          ),
        ),
      );
      final first = tester.getRect(find.byType(JamRow).first);
      expect(
        tester.getRect(find.byType(JamHairline).first).right,
        closeTo(first.right, 0.5),
      );

      // A plain section is a plain list: its rows' hairlines — a song's
      // too — stop at the content, as a lone row's does.
      await tester.pumpWidget(
        _host(
          const JamSection.plain(
            children: [
              JamRow(title: 'One'),
              JamTrackRow(title: 'Two'),
              JamTrackRow(title: 'Three'),
            ],
          ),
        ),
      );
      final lines = find.byType(JamHairline);
      expect(lines, findsNWidgets(2));
      final edge = tester.getRect(find.byType(JamSection)).right;
      for (final line in [lines.first, lines.last]) {
        expect(tester.getRect(line).right, closeTo(edge - kJamRowInset, 0.5));
      }
    });

    testWidgets('JamAddSongsRow: a plus tile and a tint title, one button', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      var taps = 0;
      await tester.pumpWidget(_host(JamAddSongsRow(onTap: () => taps++)));
      expect(
        tester.getSize(find.byType(JamAddSongsRow)).height,
        kJamAddSongsRowHeight,
      );
      expect(
        tester.widget<Icon>(find.byIcon(CupertinoIcons.plus)).color,
        JamColors.light.tint,
      );
      expect(
        tester.widget<Text>(find.text(JamListStrings.addSongs)).style!.color,
        JamColors.light.tint,
      );
      expect(find.bySemanticsLabel(JamListStrings.addSongs), findsOneWidget);
      await tester.tap(find.byType(JamAddSongsRow));
      expect(taps, 1);
      handle.dispose();
    });

    testWidgets('on the backdrop it is white; busy swaps the plus', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(JamAddSongsRow(onTap: () {}, onBackdrop: true)),
      );
      expect(
        tester.widget<Icon>(find.byIcon(CupertinoIcons.plus)).color,
        JamNowPlayingColors.text,
      );
      await tester.pumpWidget(_host(JamAddSongsRow(onTap: () {}, busy: true)));
      expect(find.byIcon(CupertinoIcons.plus), findsNothing);
    });

    testWidgets('disabled: the tertiary ink; large text grows the row', (
      tester,
    ) async {
      await tester.pumpWidget(_host(const JamAddSongsRow(onTap: null)));
      expect(
        tester.widget<Icon>(find.byIcon(CupertinoIcons.plus)).color,
        JamColors.light.tertiaryLabel,
      );
      expect(find.byType(Opacity), findsNothing);

      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(3)),
          child: _host(JamAddSongsRow(onTap: () {})),
        ),
      );
      expect(
        tester.getSize(find.byType(JamAddSongsRow)).height,
        greaterThan(kJamAddSongsRowHeight),
      );
    });
  });
}
