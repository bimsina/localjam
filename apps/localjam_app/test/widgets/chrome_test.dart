/// The translucent chrome and controls: glass buttons, the large-title
/// scaffold, the pull-down menu, the switch and segmented control, the press
/// building block and progress.
library;

import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/design/theme.dart';
import 'package:localjam_app/src/design/tokens.dart';
import 'package:localjam_app/src/widgets/buttons.dart';
import 'package:localjam_app/src/widgets/glass.dart';
import 'package:localjam_app/src/widgets/menu.dart';
import 'package:localjam_app/src/widgets/pressable.dart';
import 'package:localjam_app/src/widgets/progress.dart';
import 'package:localjam_app/src/widgets/scaffold.dart';
import 'package:localjam_app/src/widgets/switch.dart';

Widget _app(Widget home, {bool dark = false}) =>
    MaterialApp(theme: dark ? jamDarkTheme() : jamLightTheme(), home: home);

Widget _host(Widget child, {bool dark = false}) => _app(
  Scaffold(body: Center(child: child)),
  dark: dark,
);

void main() {
  group('JamGlassButton', () {
    testWidgets('44 hit, 36 blurred circle, labelled', (tester) async {
      final handle = tester.ensureSemantics();
      var taps = 0;
      await tester.pumpWidget(
        _host(
          JamGlassButton(
            icon: CupertinoIcons.chevron_down,
            semanticLabel: 'Close',
            onPressed: () => taps++,
          ),
        ),
      );
      expect(tester.getSize(find.byType(JamGlassButton)), const Size(44, 44));
      expect(find.byType(BackdropFilter), findsOneWidget);
      expect(
        tester.getSize(find.byType(BackdropFilter)),
        const Size(JamMetrics.glassButton, JamMetrics.glassButton),
      );
      expect(find.bySemanticsLabel('Close'), findsOneWidget);
      await tester.tap(find.byType(JamGlassButton));
      expect(taps, 1);
      handle.dispose();
    });

    testWidgets('over artwork it is glass with a white glyph', (tester) async {
      await tester.pumpWidget(
        _host(
          JamGlassButton(
            icon: CupertinoIcons.person_badge_plus,
            semanticLabel: 'Invite',
            onArtwork: true,
            onPressed: () {},
          ),
        ),
      );
      expect(
        tester.widget<Icon>(find.byType(Icon)).color,
        JamNowPlayingColors.text,
      );
      final surface = tester.widget<JamBlurSurface>(
        find.byType(JamBlurSurface),
      );
      expect(surface.kind, JamMaterialKind.glass);
    });

    testWidgets('selected is an opaque circle with a dark glyph', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          JamGlassButton(
            icon: CupertinoIcons.list_bullet,
            semanticLabel: 'Queue',
            onArtwork: true,
            selected: true,
            onPressed: () {},
          ),
        ),
      );
      expect(find.byType(BackdropFilter), findsNothing);
      // Warm ink, never pure black.
      expect(
        tester.widget<Icon>(find.byType(Icon)).color,
        JamNowPlayingColors.selectedGlyph,
      );
    });
  });

  group('JamScaffold', () {
    testWidgets('a large title over the content, trailing items in tint', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          JamScaffold(
            title: 'Nearby',
            trailing: [
              JamIconButton(
                icon: CupertinoIcons.qrcode_viewfinder,
                semanticLabel: 'Scan',
                onPressed: () {},
              ),
            ],
            children: [
              for (var i = 0; i < 40; i++)
                SizedBox(height: 44, child: Text('Row $i')),
            ],
          ),
        ),
      );
      expect(find.byType(CupertinoSliverNavigationBar), findsOneWidget);
      final large = tester
          .widgetList<Text>(find.text('Nearby'))
          .map((t) => t.data)
          .toList();
      expect(large, isNotEmpty);
      expect(find.byIcon(CupertinoIcons.qrcode_viewfinder), findsOneWidget);
      expect(
        tester
            .widget<Icon>(find.byIcon(CupertinoIcons.qrcode_viewfinder))
            .color,
        JamColors.light.tint,
      );
      // Scrolls without error and collapses the title.
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -400));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'the bottom action sits on material only once content is under it',
      (tester) async {
        await tester.pumpWidget(
          _app(
            JamScaffold(
              title: 'Nearby',
              bottomBar: JamButton.filled(
                label: 'Start a Jam',
                expand: true,
                onPressed: () {},
              ),
              children: [
                for (var i = 0; i < 40; i++)
                  SizedBox(height: 44, child: Text('Row $i')),
              ],
            ),
          ),
        );
        await tester.pumpAndSettle();
        final opacity = tester.widget<AnimatedOpacity>(
          find
              .descendant(
                of: find.byType(JamBottomBar),
                matching: find.byType(AnimatedOpacity),
              )
              .first,
        );
        expect(opacity.opacity, 1);

        await tester.pumpWidget(
          _app(
            JamScaffold(
              title: 'Nearby',
              bottomBar: JamButton.filled(
                label: 'Start a Jam',
                expand: true,
                onPressed: () {},
              ),
              children: const [SizedBox(height: 44, child: Text('Only'))],
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<AnimatedOpacity>(
                find
                    .descendant(
                      of: find.byType(JamBottomBar),
                      matching: find.byType(AnimatedOpacity),
                    )
                    .first,
              )
              .opacity,
          0,
        );
        expect(find.text('Start a Jam'), findsOneWidget);
      },
    );

    testWidgets('an empty page that fills the remainder neither scrolls nor '
        'paints the bottom strip', (tester) async {
      await tester.pumpWidget(
        _app(
          JamScaffold(
            title: 'Nearby',
            bottomBar: JamButton.filled(
              label: 'Start a Jam',
              expand: true,
              onPressed: () {},
            ),
            slivers: const [
              SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: Text('No Jams Nearby')),
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      final scrollable = tester.state<ScrollableState>(
        find.byType(Scrollable).first,
      );
      expect(scrollable.position.maxScrollExtent, 0);
      expect(
        tester
            .widget<AnimatedOpacity>(
              find
                  .descendant(
                    of: find.byType(JamBottomBar),
                    matching: find.byType(AnimatedOpacity),
                  )
                  .first,
            )
            .opacity,
        0,
      );
    });

    testWidgets('back is a bare chevron, even when a label is asked for', (
      tester,
    ) async {
      await tester.pumpWidget(_app(const Scaffold(body: Text('Root'))));
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      unawaited(
        navigator.push(
          MaterialPageRoute<void>(
            builder: (_) => const JamScaffold(
              title: 'Licenses',
              previousPageTitle: 'Settings',
              children: [Text('Body')],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(CupertinoNavigationBarBackButton), findsOneWidget);
      expect(find.text('Settings'), findsNothing);
    });

    test('a small gesture inset gets air; iOS keeps its indicator inset', () {
      expect(jamBottomBarInset(34), 34);
      expect(jamBottomBarInset(24), greaterThanOrEqualTo(34));
      expect(jamBottomBarInset(0), JamSpace.lg);
    });

    testWidgets('a reading column centres in the pane, title on its edge', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1000, 1300);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _app(
          const JamScaffold(
            title: 'Settings',
            maxContentWidth: 640,
            children: [SizedBox(height: 44, child: Text('Row'))],
          ),
        ),
      );
      await tester.pumpAndSettle();
      final row = tester.getRect(find.text('Row'));
      expect(row.left, closeTo((1000 - 640) / 2, 1));
      // The large title (the taller of the two) starts on the column's
      // margin, not the window's.
      final titles = [
        for (
          var i = 0;
          i < find.text('Settings', skipOffstage: false).evaluate().length;
          i++
        )
          tester.getRect(find.text('Settings', skipOffstage: false).at(i)),
      ];
      final large = titles.reduce((a, b) => a.left <= b.left ? a : b);
      expect(large.left, closeTo(row.left + JamSpace.pageFor(1000), 1));
    });

    testWidgets('grouped pages use groupedBackground; inline titles work', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          const JamScaffold(
            title: 'Settings',
            grouped: true,
            largeTitle: false,
            children: [Text('Body')],
          ),
        ),
      );
      expect(
        tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
        JamColors.light.groupedBackground,
      );
      expect(find.byType(CupertinoNavigationBar), findsOneWidget);
      expect(find.text('Body'), findsOneWidget);
    });
  });

  group('JamScaffold inline', () {
    testWidgets('content starts under the bar, not under the status bar', (
      tester,
    ) async {
      tester.view.padding = const FakeViewPadding(top: 141);
      addTearDown(tester.view.resetPadding);
      await tester.pumpWidget(
        _app(
          const JamScaffold(
            title: 'Detail',
            largeTitle: false,
            children: [Text('First line')],
          ),
        ),
      );
      final top = MediaQuery.paddingOf(
        tester.element(find.byType(JamScaffold)),
      ).top;
      expect(
        tester.getTopLeft(find.text('First line')).dy,
        greaterThanOrEqualTo(top + JamMetrics.navBarHeight),
      );
    });

    testWidgets('the inline bar is clear at rest and fills once content '
        'scrolls under it', (tester) async {
      await tester.pumpWidget(
        _app(
          JamScaffold(
            title: 'Detail',
            largeTitle: false,
            children: [
              for (var i = 0; i < 40; i++)
                SizedBox(height: 60, child: Text('$i')),
            ],
          ),
        ),
      );
      Color barColor() {
        final box = tester.widget<DecoratedBox>(
          find
              .descendant(
                of: find.byType(CupertinoNavigationBar),
                matching: find.byType(DecoratedBox),
              )
              .first,
        );
        return (box.decoration as BoxDecoration).color!;
      }

      expect(barColor().a, 0);
      await tester.drag(find.text('3'), const Offset(0, -300));
      await tester.pumpAndSettle();
      expect(barColor(), JamColors.light.material);
    });
  });

  group('JamMenuButton', () {
    testWidgets('opens an iOS pull-down with groups and a red row', (
      tester,
    ) async {
      var invited = 0;
      await tester.pumpWidget(
        _host(
          JamMenuButton(
            groups: [
              [
                JamMenuItem(
                  title: 'Invite People',
                  icon: CupertinoIcons.person_badge_plus,
                  onPressed: () => invited++,
                ),
              ],
              [
                JamMenuItem(
                  title: 'End Jam',
                  icon: CupertinoIcons.xmark_circle,
                  destructive: true,
                  onPressed: () {},
                ),
              ],
            ],
          ),
        ),
      );
      expect(find.byIcon(CupertinoIcons.ellipsis_circle), findsOneWidget);
      await tester.tap(find.byType(JamMenuButton));
      await tester.pumpAndSettle();
      expect(find.text('Invite People'), findsOneWidget);
      final items = tester
          .widgetList<JamMenuRow>(find.byType(JamMenuRow))
          .toList();
      expect(items, hasLength(2));
      expect(items.last.item.destructive, isTrue);
      // On LocalJam's own tokens: the warm menu ground and `danger`, not
      // Cupertino's grey and system red.
      expect(
        tester.widget<Text>(find.text('End Jam')).style!.color,
        JamColors.light.danger,
      );
      expect(
        tester
            .widgetList<DecoratedBox>(find.byType(DecoratedBox))
            .map((b) => b.decoration)
            .whereType<ShapeDecoration>()
            .map((d) => d.color),
        contains(JamColors.light.elevatedGroupedSurface),
      );
      expect(find.byType(CupertinoMenuItem), findsNothing);
      await tester.tap(find.text('Invite People'));
      await tester.pumpAndSettle();
      expect(invited, 1);
      expect(find.text('Invite People'), findsNothing);
    });

    testWidgets('titles carry a complete text style wherever the anchor '
        'sits — no fallback (debug-underlined) text', (tester) async {
      // No Material, no page: just the app and a Cupertino page, the way a
      // sheet hosts a menu.
      await tester.pumpWidget(
        MaterialApp(
          theme: jamLightTheme(),
          home: const CupertinoPageScaffold(
            child: Center(
              child: JamMenuButton(
                groups: [
                  [JamMenuItem(title: 'Add Music', subtitle: 'And more')],
                ],
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byType(JamMenuButton));
      await tester.pumpAndSettle();
      final style = DefaultTextStyle.of(
        tester.element(find.text('Add Music')),
      ).style;
      expect(style.decoration, isNot(TextDecoration.underline));
      expect(style.decorationColor, isNot(const Color(0xFFFFFF00)));
      expect(style.fontSize, 17);
    });

    testWidgets('brightness forces the menu dark on a light app', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const JamMenuButton(
            brightness: Brightness.dark,
            groups: [
              [JamMenuItem(title: 'People')],
            ],
          ),
        ),
      );
      await tester.tap(find.byType(JamMenuButton));
      await tester.pumpAndSettle();
      final item = tester.element(find.text('People'));
      expect(CupertinoTheme.brightnessOf(item), Brightness.dark);
      expect(MediaQuery.platformBrightnessOf(item), Brightness.dark);
    });

    testWidgets('a touch outside puts the menu away', (tester) async {
      await tester.pumpWidget(
        _app(
          Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: JamMenuButton(
                groups: [
                  [JamMenuItem(title: 'One', onPressed: () {})],
                ],
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byType(JamMenuButton));
      await tester.pumpAndSettle();
      expect(find.text('One'), findsOneWidget);
      await tester.tapAt(const Offset(20, 580));
      await tester.pumpAndSettle();
      expect(find.text('One'), findsNothing);
    });

    testWidgets('a menu is a 22-radius surface — and one row is a soft '
        'rectangle, never a capsule', (tester) async {
      Future<(double radius, double height)> open(int rows) async {
        // A fresh anchor each time: the last one's menu is still open.
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(
          _host(
            JamMenuButton(
              groups: [
                [
                  for (var i = 0; i < rows; i++)
                    JamMenuItem(title: 'Item $i', onPressed: () {}),
                ],
              ],
            ),
          ),
        );
        await tester.tap(find.byType(JamMenuButton));
        await tester.pumpAndSettle();
        final panel = find.byType(JamMenuPanel);
        final clip = tester.widget<ClipPath>(
          find.descendant(of: panel, matching: find.byType(ClipPath)).first,
        );
        expect(
          (clip.clipper! as ShapeBorderClipper).shape,
          isA<JamMenuBorder>(),
        );
        final height = tester.getSize(panel).height;
        return (JamRadius.menuFor(height), height);
      }

      final (two, _) = await open(2);
      expect(two, JamRadius.menu);
      final (one, height) = await open(1);
      expect(height, closeTo(JamMetrics.menuRow, 1));
      expect(one, lessThan(height / 2 - 4), reason: 'not a pill');
      expect(one, greaterThanOrEqualTo(JamRadius.md));
    });

    testWidgets('the menu\'s hairline edge is drawn in front of its rows', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          JamMenuButton(
            groups: [
              [JamMenuItem(title: 'One', onPressed: () {})],
              [JamMenuItem(title: 'Two', onPressed: () {})],
            ],
          ),
        ),
      );
      await tester.tap(find.byType(JamMenuButton));
      await tester.pumpAndSettle();
      final edges = tester
          .widgetList<DecoratedBox>(
            find.descendant(
              of: find.byType(JamMenuPanel),
              matching: find.byType(DecoratedBox),
            ),
          )
          .where((b) => b.position == DecorationPosition.foreground);
      expect(edges, hasLength(1));
      final shape = (edges.single.decoration as ShapeDecoration).shape;
      expect((shape as JamMenuBorder).side.style, BorderStyle.solid);
    });

    testWidgets('preferUp opens above the trigger where there is room, and '
        'below where there is not', (tester) async {
      Future<(Rect, Rect)> open(Alignment where) async {
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(
          _app(
            Scaffold(
              body: Align(
                alignment: where,
                child: JamMenuButton(
                  preferUp: true,
                  groups: [
                    [
                      JamMenuItem(title: 'Sound Offset', onPressed: () {}),
                      JamMenuItem(title: 'Diagnostics', onPressed: () {}),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
        final trigger = tester.getRect(find.byType(JamMenuButton));
        await tester.tap(find.byType(JamMenuButton));
        await tester.pumpAndSettle();
        return (trigger, tester.getRect(find.byType(JamMenuPanel)));
      }

      final (low, upMenu) = await open(Alignment.bottomRight);
      expect(upMenu.bottom, lessThanOrEqualTo(low.top));
      final (high, downMenu) = await open(Alignment.topRight);
      expect(downMenu.top, greaterThanOrEqualTo(high.bottom));
    });

    testWidgets('a row-wide trigger opens against its trailing edge', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: JamMenuButton(
                groups: [
                  [JamMenuItem(title: 'Listen Only', onPressed: () {})],
                ],
                builder: (context, open) => GestureDetector(
                  onTap: open,
                  child: const SizedBox(
                    width: 760,
                    height: 44,
                    child: Text('Guests Can'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final row = tester.getRect(find.text('Guests Can'));
      await tester.tap(find.text('Guests Can'));
      await tester.pumpAndSettle();
      final menu = tester.getRect(find.byType(JamMenuRow));
      expect(menu.right, closeTo(row.right - JamSpace.lg, 1));
      expect(menu.top, greaterThan(row.bottom));
    });

    testWidgets('a forced-dark menu draws on the dark tokens', (tester) async {
      await tester.pumpWidget(
        _host(
          JamMenuButton(
            brightness: Brightness.dark,
            groups: [
              [
                JamMenuItem(
                  title: 'End Jam',
                  destructive: true,
                  onPressed: () {},
                ),
              ],
            ],
          ),
        ),
      );
      await tester.tap(find.byType(JamMenuButton));
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(find.text('End Jam')).style!.color,
        JamColors.dark.danger,
      );
    });

    testWidgets('inside the room — or on its backdrop — a menu is the room\'s '
        'solid dark (R2)', (tester) async {
      for (final backdrop in [false, true]) {
        await tester.pumpWidget(const SizedBox());
        Widget menu = JamMenuButton(
          groups: [
            [JamMenuItem(title: 'Diagnostics', onPressed: () {})],
          ],
        );
        if (backdrop) menu = JamOnBackdrop(child: menu);
        await tester.pumpWidget(
          _host(
            Stack(
              alignment: Alignment.center,
              children: [
                const JamPresentationAppearance(brightness: Brightness.dark),
                menu,
              ],
            ),
          ),
        );
        await tester.tap(find.byType(JamMenuButton));
        await tester.pumpAndSettle();
        final item = tester.element(find.text('Diagnostics'));
        expect(Theme.of(item).brightness, Brightness.dark);
        // The menu's own ground, never the backdrop's see-through one.
        expect(
          item.jamColors.elevatedGroupedSurface,
          JamColors.dark.elevatedGroupedSurface,
        );
      }
    });

    testWidgets('JamMenuPanel hands the choice back when asked to', (
      tester,
    ) async {
      final chosen = <String>[];
      var ran = 0;
      await tester.pumpWidget(
        _host(
          JamMenuPanel(
            width: 250,
            groups: [
              [
                JamMenuItem(title: 'Play Next', onPressed: () => ran++),
                JamMenuItem(
                  title: 'Remove',
                  destructive: true,
                  onPressed: () {},
                ),
              ],
            ],
            onSelected: (item) => chosen.add(item.title),
          ),
        ),
      );
      await tester.tap(find.text('Play Next'));
      expect(chosen, ['Play Next']);
      expect(ran, 0, reason: 'the host runs it, after closing');
    });

    testWidgets('a menu row activates from the keyboard', (tester) async {
      var ran = 0;
      await tester.pumpWidget(
        _host(
          JamMenuPanel(
            width: 250,
            groups: [
              [JamMenuItem(title: 'Diagnostics', onPressed: () => ran++)],
            ],
          ),
        ),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(ran, 1);
    });

    testWidgets('the glass trigger over artwork', (tester) async {
      await tester.pumpWidget(
        _host(
          const JamMenuButton(
            trigger: JamMenuTrigger.glassOnArtwork,
            visualSize: 30,
            groups: [
              [JamMenuItem(title: 'Diagnostics')],
            ],
          ),
        ),
      );
      expect(find.byType(JamGlassButton), findsOneWidget);
      expect(find.byIcon(CupertinoIcons.ellipsis), findsOneWidget);
    });
  });

  group('controls', () {
    testWidgets('JamSwitch uses the accessible brand fill', (tester) async {
      var value = false;
      await tester.pumpWidget(
        _host(
          StatefulBuilder(
            builder: (context, setState) => JamSwitch(
              value: value,
              onChanged: (v) => setState(() => value = v),
            ),
          ),
        ),
      );
      final sw = tester.widget<CupertinoSwitch>(find.byType(CupertinoSwitch));
      expect(sw.activeTrackColor, JamColors.light.tintFilled);
      await tester.tap(find.byType(CupertinoSwitch));
      await tester.pumpAndSettle();
      expect(value, isTrue);
    });

    testWidgets('JamSegmentedControl picks a value', (tester) async {
      var mode = 'system';
      await tester.pumpWidget(
        _host(
          StatefulBuilder(
            builder: (context, setState) => SizedBox(
              width: 300,
              child: JamSegmentedControl<String>(
                segments: const {
                  'system': 'System',
                  'light': 'Light',
                  'dark': 'Dark',
                },
                groupValue: mode,
                onValueChanged: (v) => setState(() => mode = v),
              ),
            ),
          ),
        ),
      );
      expect(
        find.byType(CupertinoSlidingSegmentedControl<String>),
        findsOneWidget,
      );
      await tester.tap(find.text('Dark'));
      await tester.pumpAndSettle();
      expect(mode, 'dark');
    });

    testWidgets('JamPressable dims on press and restores', (tester) async {
      await tester.pumpWidget(
        _host(
          JamPressable(
            onTap: () {},
            child: const SizedBox(width: 60, height: 60),
          ),
        ),
      );
      final g = await tester.startGesture(
        tester.getCenter(find.byType(JamPressable)),
      );
      await tester.pump();
      expect(
        tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
        0.6,
      );
      await g.up();
      await tester.pumpAndSettle();
      expect(
        tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
        1,
      );
    });

    testWidgets('a squeezing control dims under reduced motion instead '
        '(RB-18)', (tester) async {
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: _host(
            JamPressable(
              style: JamPressStyle.scale,
              onTap: () {},
              child: const SizedBox(width: 76, height: 76),
            ),
          ),
        ),
      );
      double opacity() => tester
          .widget<Opacity>(
            find.descendant(
              of: find.byType(JamPressable),
              matching: find.byType(Opacity),
            ),
          )
          .opacity;
      expect(opacity(), 1);
      final g = await tester.startGesture(
        tester.getCenter(find.byType(JamPressable)),
      );
      await tester.pump();
      expect(opacity(), lessThan(1));
      expect(tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale, 1);
      await g.up();
      await tester.pump();
      expect(opacity(), 1);
    });

    testWidgets('progress is one ring — filling or turning — and a bar', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              JamSpinner(),
              JamSpinner(progress: 0.5),
              SizedBox(width: 100, child: JamProgressBar(value: 0.5)),
            ],
          ),
        ),
      );
      expect(find.byType(JamProgressRing), findsNWidgets(2));
      expect(find.byType(CupertinoActivityIndicator), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(
        tester.getSize(find.byType(JamProgressRing).first),
        const Size.square(20),
      );
      expect(tester.getSize(find.byType(JamProgressBar)).height, 4);
    });
  });
}
