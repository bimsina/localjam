import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/design/theme.dart';
import 'package:localjam_app/src/design/tokens.dart';
import 'package:localjam_app/src/widgets/buttons.dart';

Widget _host(Widget child, {bool dark = false}) => MaterialApp(
  theme: dark ? jamDarkTheme() : jamLightTheme(),
  home: Scaffold(body: Center(child: child)),
);

ShapeDecoration? _groundOf(WidgetTester tester) {
  final containers = tester.widgetList<Container>(
    find.descendant(
      of: find.byType(JamButton),
      matching: find.byType(Container),
    ),
  );
  for (final c in containers) {
    final d = c.decoration;
    if (d is ShapeDecoration) return d;
  }
  return null;
}

TextStyle _labelStyle(WidgetTester tester, String label) =>
    tester.widget<Text>(find.text(label)).style!;

double _opacityOf(WidgetTester tester) => tester
    .widget<Opacity>(
      find
          .descendant(
            of: find.byType(JamButton),
            matching: find.byType(Opacity),
          )
          .first,
    )
    .opacity;

void main() {
  testWidgets('filled: tint rounded rectangle, white 17 semibold, 50 tall', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(JamButton.filled(label: 'Start a Jam', onPressed: () {})),
    );
    final ground = _groundOf(tester)!;
    expect(ground.color, JamColors.light.tint);
    expect(ground.shape, isA<RoundedRectangleBorder>());
    final style = _labelStyle(tester, 'Start a Jam');
    expect(style.color, JamColors.light.onTint);
    expect(style.fontSize, 17);
    expect(style.fontWeight, FontWeight.w600);
    expect(tester.getSize(find.byType(JamButton)).height, 50);
  });

  testWidgets('tinted, gray and plain grounds', (tester) async {
    await tester.pumpWidget(
      _host(JamButton.tinted(label: 'Join', onPressed: () {})),
    );
    expect(_groundOf(tester)!.color, JamColors.light.tintFill);
    expect(_labelStyle(tester, 'Join').color, JamColors.light.tint);

    await tester.pumpWidget(
      _host(JamButton.gray(label: 'Host Again', onPressed: () {})),
    );
    expect(_groundOf(tester)!.color, JamColors.light.fill);
    expect(_labelStyle(tester, 'Host Again').color, JamColors.light.tint);

    await tester.pumpWidget(
      _host(JamButton.plain(label: 'See All', onPressed: () {})),
    );
    expect(_groundOf(tester), isNull);
    expect(_labelStyle(tester, 'See All').color, JamColors.light.tint);
  });

  testWidgets('small is 30 painted inside a 44 hit area', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      _host(
        JamButton.tinted(
          label: 'Join',
          size: JamButtonSize.small,
          onPressed: () => taps++,
        ),
      ),
    );
    expect(tester.getSize(find.byType(JamButton)).height, 44);
    final painted = tester.getSize(
      find
          .descendant(
            of: find.byType(JamButton),
            matching: find.byType(Container),
          )
          .first,
    );
    expect(painted.height, 30);
    expect(_labelStyle(tester, 'Join').fontSize, 15);
    // The transparent band still takes the tap.
    final rect = tester.getRect(find.byType(JamButton));
    await tester.tapAt(Offset(rect.center.dx, rect.top + 3));
    expect(taps, 1);
  });

  testWidgets('destructive turns the fill or label danger', (tester) async {
    await tester.pumpWidget(
      _host(
        JamButton.filled(label: 'End Jam', destructive: true, onPressed: () {}),
      ),
    );
    expect(_groundOf(tester)!.color, JamColors.light.dangerFilled);

    await tester.pumpWidget(
      _host(
        JamButton.plain(
          label: 'Leave Jam',
          destructive: true,
          onPressed: () {},
        ),
      ),
    );
    expect(_labelStyle(tester, 'Leave Jam').color, JamColors.light.danger);
  });

  testWidgets('tapping fires; disabled dims to 0.35 and ignores taps', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      _host(JamButton.filled(label: 'Join', onPressed: () => taps++)),
    );
    await tester.tap(find.byType(JamButton));
    expect(taps, 1);
    expect(_opacityOf(tester), 1);

    await tester.pumpWidget(_host(const JamButton.filled(label: 'Join')));
    await tester.tap(find.byType(JamButton), warnIfMissed: false);
    await tester.pump();
    expect(taps, 1);
    expect(_opacityOf(tester), 0.35);
  });

  testWidgets('pressing dims to 0.7, no ink', (tester) async {
    await tester.pumpWidget(
      _host(JamButton.filled(label: 'Join', onPressed: () {})),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(JamButton)),
    );
    await tester.pump();
    expect(
      tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
      0.7,
    );
    expect(find.byType(InkWell), findsNothing);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(
      tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
      1,
    );
  });

  testWidgets('loading shows the activity indicator and holds the width', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(JamButton.filled(label: 'Start the Jam', onPressed: () {})),
    );
    final idleWidth = tester.getSize(find.byType(JamButton)).width;

    var taps = 0;
    await tester.pumpWidget(
      _host(
        JamButton.filled(
          label: 'Start the Jam',
          loading: true,
          onPressed: () => taps++,
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(CupertinoActivityIndicator), findsOneWidget);
    expect(tester.getSize(find.byType(JamButton)).width, idleWidth);
    await tester.tap(find.byType(JamButton));
    expect(taps, 0);
  });

  testWidgets('an icon sits before the label', (tester) async {
    await tester.pumpWidget(
      _host(
        JamButton.gray(
          label: 'Play',
          icon: CupertinoIcons.play_fill,
          onPressed: () {},
        ),
      ),
    );
    expect(find.byIcon(CupertinoIcons.play_fill), findsOneWidget);
    expect(
      tester.getCenter(find.byIcon(CupertinoIcons.play_fill)).dx,
      lessThan(tester.getCenter(find.text('Play')).dx),
    );
  });

  testWidgets('a copy button confirms in place, then goes back', (
    tester,
  ) async {
    var copies = 0;
    await tester.pumpWidget(
      _host(JamCopyButton(label: 'Copy Link', onCopy: () => copies++)),
    );
    await tester.tap(find.text('Copy Link'));
    await tester.pump();
    expect(copies, 1);
    expect(find.text(JamConfirmationStrings.copied), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.checkmark), findsOneWidget);
    await tester.pump(kJamInPlaceConfirmation);
    expect(find.text('Copy Link'), findsOneWidget);
  });

  testWidgets('a button announces itself as one', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _host(JamButton.filled(label: 'Start a Jam', onPressed: () {})),
    );
    expect(
      tester.getSemantics(find.byType(JamButton)),
      matchesSemantics(
        label: 'Start a Jam',
        isButton: true,
        isEnabled: true,
        hasEnabledState: true,
        hasTapAction: true,
      ),
    );
    handle.dispose();
  });

  testWidgets('JamTextButton and JamIconButton keep 44 targets', (
    tester,
  ) async {
    var done = 0;
    await tester.pumpWidget(
      _host(
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            JamTextButton(label: 'Done', bold: true, onPressed: () => done++),
            JamIconButton(
              icon: CupertinoIcons.qrcode_viewfinder,
              semanticLabel: 'Scan',
              onPressed: () {},
            ),
          ],
        ),
      ),
    );
    expect(
      tester.getSize(find.byType(JamTextButton)).height,
      greaterThanOrEqualTo(44),
    );
    expect(tester.getSize(find.byType(JamIconButton)), const Size(44, 44));
    expect(_labelStyle(tester, 'Done').fontWeight, FontWeight.w600);
    await tester.tap(find.text('Done'));
    expect(done, 1);
  });
}
