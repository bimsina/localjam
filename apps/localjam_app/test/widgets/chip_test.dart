import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/design/theme.dart';
import 'package:localjam_app/src/design/tokens.dart';
import 'package:localjam_app/src/widgets/chip.dart';

Widget _host(Widget child, {bool dark = false}) => MaterialApp(
  theme: dark ? jamDarkTheme() : jamLightTheme(),
  home: Scaffold(body: Center(child: child)),
);

BoxDecoration _fillOf(WidgetTester tester) {
  final container = tester.widget<AnimatedContainer>(
    find.descendant(
      of: find.byType(JamChip),
      matching: find.byType(AnimatedContainer),
    ),
  );
  return container.decoration! as BoxDecoration;
}

Color _labelColor(WidgetTester tester, String label) =>
    tester.widget<Text>(find.text(label)).style!.color!;

void main() {
  testWidgets('idle wears the muted fill and a secondary label', (
    tester,
  ) async {
    await tester.pumpWidget(_host(const JamChip(label: 'Everything')));
    expect(_fillOf(tester).color, JamColors.light.surfaceMuted);
    expect(_labelColor(tester, 'Everything'), JamColors.light.textSecondary);
    expect(tester.getSize(find.byType(JamChip)).height, 32);
  });

  testWidgets('selected wears the soft accent fill', (tester) async {
    await tester.pumpWidget(
      _host(const JamChip(label: 'Add music', state: JamChipState.selected)),
    );
    expect(_fillOf(tester).color, JamColors.light.accentSoft);
    expect(_labelColor(tester, 'Add music'), JamColors.light.accent);
  });

  testWidgets('live carries the 6 dp apricot dot', (tester) async {
    await tester.pumpWidget(
      _host(const JamChip(label: 'LIVE', state: JamChipState.live)),
    );
    expect(_fillOf(tester).color, JamColors.light.highlightSoft);
    // Apricot fails AA as text, so the word is warning-brown and only the
    // dot is the highlight itself.
    expect(_labelColor(tester, 'LIVE'), JamColors.light.warning);

    // AnimatedContainer builds a Container of its own, so the dot is the
    // deeper of the two.
    final dotFinder = find
        .descendant(of: find.byType(JamChip), matching: find.byType(Container))
        .last;
    final decoration =
        tester.widget<Container>(dotFinder).decoration! as BoxDecoration;
    expect(decoration.color, JamColors.light.highlight);
    expect(decoration.shape, BoxShape.circle);
    expect(tester.getSize(dotFinder), const Size(6, 6));
  });

  testWidgets('a tappable chip fires and takes a 44 dp target', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      _host(JamChip(label: 'Nearby', onTap: () => taps++)),
    );
    // Painted 32, tapped 44 — the pill does not grow to satisfy the rule.
    expect(tester.getSize(find.byType(JamChip)).height, 44);
    await tester.tap(find.byType(JamChip));
    expect(taps, 1);
  });

  testWidgets('the close glyph fires on its own, not the chip', (tester) async {
    var taps = 0;
    var closes = 0;
    await tester.pumpWidget(
      _host(
        JamChip(
          label: 'Blues.mp3',
          onTap: () => taps++,
          onClose: () => closes++,
        ),
      ),
    );
    await tester.tap(find.byIcon(Icons.close_rounded));
    expect(closes, 1);
    expect(taps, 0);
  });

  testWidgets('an untapped chip is not announced as a button', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_host(const JamChip(label: 'Listen')));
    // matchesSemantics asserts every unlisted flag is absent, so this is
    // also the assertion that an inert chip is not announced as a button.
    expect(
      tester.getSemantics(find.byType(JamChip)),
      matchesSemantics(label: 'Listen'),
    );
    handle.dispose();
  });

  testWidgets('dark keeps the same three fills from its own palette', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const JamChip(label: 'Add music', state: JamChipState.selected),
        dark: true,
      ),
    );
    expect(_fillOf(tester).color, JamColors.dark.accentSoft);
    expect(_labelColor(tester, 'Add music'), JamColors.dark.accent);
  });
}
