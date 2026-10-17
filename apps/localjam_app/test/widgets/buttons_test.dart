import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/design/theme.dart';
import 'package:localjam_app/src/design/tokens.dart';
import 'package:localjam_app/src/widgets/buttons.dart';

Widget _host(Widget child, {bool dark = false, bool reduceMotion = false}) =>
    MediaQuery(
      data: MediaQueryData(disableAnimations: reduceMotion),
      child: MaterialApp(
        theme: dark ? jamDarkTheme() : jamLightTheme(),
        home: Scaffold(body: Center(child: child)),
      ),
    );

BoxDecoration _decorationOf(WidgetTester tester) {
  final box = tester.widget<DecoratedBox>(
    find
        .descendant(
          of: find.byType(JamButton),
          matching: find.byType(DecoratedBox),
        )
        .first,
  );
  return box.decoration as BoxDecoration;
}

TextStyle _labelStyle(WidgetTester tester, String label) =>
    tester.widget<Text>(find.text(label)).style!;

void main() {
  testWidgets('a primary button carries the brand gradient on light', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(JamButton.primary(label: 'Start a jam', onPressed: () {})),
    );

    final decoration = _decorationOf(tester);
    expect(decoration.gradient, isA<LinearGradient>());
    expect(
      (decoration.gradient! as LinearGradient).colors.first,
      JamColors.brandRaspberry,
    );
    expect(_labelStyle(tester, 'Start a jam').color, JamColors.light.onAccent);
    expect(tester.getSize(find.byType(JamButton)).height, 52);
  });

  testWidgets('a primary button is flat accent on dark', (tester) async {
    await tester.pumpWidget(
      _host(
        JamButton.primary(label: 'Start a jam', onPressed: () {}),
        dark: true,
      ),
    );

    final decoration = _decorationOf(tester);
    expect(decoration.gradient, isNull);
    expect(decoration.color, JamColors.dark.accent);
  });

  testWidgets('tapping fires, and a disabled button does not', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      _host(JamButton.primary(label: 'Join', onPressed: () => taps++)),
    );
    await tester.tap(find.byType(JamButton));
    expect(taps, 1);

    await tester.pumpWidget(_host(const JamButton.primary(label: 'Join')));
    await tester.tap(find.byType(JamButton));
    await tester.pump();
    expect(taps, 1);
    expect(_decorationOf(tester).color, JamColors.light.surfaceMuted);
    expect(_labelStyle(tester, 'Join').color, JamColors.light.textTertiary);
  });

  testWidgets('loading shows a spinner and holds the width', (tester) async {
    await tester.pumpWidget(
      _host(JamButton.primary(label: 'Start the jam', onPressed: () {})),
    );
    final idleWidth = tester.getSize(find.byType(JamButton)).width;

    var taps = 0;
    await tester.pumpWidget(
      _host(
        JamButton.primary(
          label: 'Start the jam',
          loading: true,
          onPressed: () => taps++,
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(tester.getSize(find.byType(JamButton)).width, idleWidth);
    // Loading is a disabled state, not a second chance to double-start a jam.
    await tester.tap(find.byType(JamButton));
    expect(taps, 0);
  });

  testWidgets('a tertiary label clears AA on cream and stays accent on dark', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(JamButton.tertiary(label: 'Not now', onPressed: () {})),
    );
    // `accent` on `canvas` is only 4.41:1, so light uses the pressed shade.
    expect(_labelStyle(tester, 'Not now').color, JamColors.light.accentPressed);
    expect(tester.getSize(find.byType(JamButton)).height, 44);

    await tester.pumpWidget(
      _host(JamButton.tertiary(label: 'Not now', onPressed: () {}), dark: true),
    );
    // MaterialApp lerps between themes; let it land before reading a colour.
    await tester.pumpAndSettle();
    expect(_labelStyle(tester, 'Not now').color, JamColors.dark.accent);
  });

  testWidgets('a secondary button is outlined, not filled', (tester) async {
    await tester.pumpWidget(
      _host(
        JamButton.secondary(
          label: 'Scan code',
          icon: Icons.qr_code_scanner_rounded,
          onPressed: () {},
        ),
      ),
    );
    final decoration = _decorationOf(tester);
    expect(decoration.color, Colors.transparent);
    expect(decoration.border, isNotNull);
    expect(find.byIcon(Icons.qr_code_scanner_rounded), findsOneWidget);
  });

  testWidgets('pressing scales to 0.97, and not at all with reduced motion', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(JamButton.primary(label: 'Join', onPressed: () {})),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(JamButton)),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale,
      0.97,
    );
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale, 1);

    await tester.pumpWidget(
      _host(
        JamButton.primary(label: 'Join', onPressed: () {}),
        reduceMotion: true,
      ),
    );
    final held = await tester.startGesture(
      tester.getCenter(find.byType(JamButton)),
    );
    await tester.pumpAndSettle();
    expect(tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale, 1);
    await held.up();
  });

  testWidgets('a destructive tertiary turns its label danger', (tester) async {
    // The way out of a room reads as a way out, not as another accent link.
    await tester.pumpWidget(
      _host(
        JamButton.tertiary(
          label: 'End jam',
          destructive: true,
          onPressed: () {},
        ),
      ),
    );
    expect(
      tester.widget<Text>(find.text('End jam')).style?.color,
      JamColors.light.danger,
    );

    // An ordinary tertiary is still the accent.
    await tester.pumpWidget(
      _host(JamButton.tertiary(label: 'Invite', onPressed: () {})),
    );
    expect(
      tester.widget<Text>(find.text('Invite')).style?.color,
      JamColors.light.accentPressed,
    );
  });

  testWidgets('a button announces itself as one', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _host(JamButton.primary(label: 'Start a jam', onPressed: () {})),
    );
    expect(
      tester.getSemantics(find.byType(JamButton)),
      matchesSemantics(
        label: 'Start a jam',
        isButton: true,
        isEnabled: true,
        hasEnabledState: true,
        hasTapAction: true,
      ),
    );
    handle.dispose();
  });
}
