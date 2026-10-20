/// The sync line under the room's name: silent when fine, one plain sentence
/// when not (DESIGN_SPEC v3 §1.2) — no dot, no pulse.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/design/theme.dart';
import 'package:localjam_app/src/design/tokens.dart';
import 'package:localjam_app/src/widgets/sync_indicator.dart';

Widget _host(
  JamSyncState state, {
  VoidCallback? onShowDetails,
  JamStatusLine? fallback,
  bool dark = false,
}) => MaterialApp(
  theme: dark ? jamDarkTheme() : jamLightTheme(),
  home: Scaffold(
    body: Center(
      child: JamSyncIndicator(
        state: state,
        fallback: fallback,
        onShowDetails: onShowDetails,
      ),
    ),
  ),
);

Color? _colorOf(WidgetTester tester, String text) =>
    tester.widget<Text>(find.text(text)).style!.color;

Color? _glyphColor(WidgetTester tester) => tester
    .widget<Icon>(
      find
          .descendant(
            of: find.byType(JamSyncIndicator),
            matching: find.byType(Icon),
          )
          .last,
    )
    .color;

/// The combined opacity the switcher's fades give [text].
double _opacityOf(WidgetTester tester, String text) {
  var opacity = 1.0;
  for (final fade in tester.widgetList<FadeTransition>(
    find.ancestor(of: find.text(text), matching: find.byType(FadeTransition)),
  )) {
    opacity *= fade.opacity.value;
  }
  return opacity;
}

void main() {
  testWidgets('in sync and idle say nothing at all', (tester) async {
    for (final state in [JamSyncState.inSync, JamSyncState.idle]) {
      await tester.pumpWidget(_host(state));
      await tester.pumpAndSettle();
      expect(find.byType(Text), findsNothing, reason: '$state');
    }
  });

  testWidgets('no dot: the indicator paints no decoration', (tester) async {
    await tester.pumpWidget(_host(JamSyncState.reconnecting));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(JamSyncIndicator),
        matching: find.byType(DecoratedBox),
      ),
      findsNothing,
    );
  });

  testWidgets('the words are always white; the glyph carries the tone', (
    tester,
  ) async {
    await tester.pumpWidget(_host(JamSyncState.catchingUp));
    await tester.pumpAndSettle();
    expect(find.text(JamSyncStrings.catchingUp), findsOneWidget);
    expect(
      _colorOf(tester, JamSyncStrings.catchingUp),
      JamNowPlayingColors.text,
    );
    expect(_glyphColor(tester), JamNowPlayingColors.warning);

    await tester.pumpWidget(_host(JamSyncState.reconnecting));
    await tester.pumpAndSettle();
    expect(
      _colorOf(tester, JamSyncStrings.reconnecting),
      JamNowPlayingColors.text,
    );
    expect(_glyphColor(tester), JamNowPlayingColors.warning);

    // A calm line is words alone: a glyph at this size reads as a dot.
    await tester.pumpWidget(_host(JamSyncState.hostAway));
    await tester.pumpAndSettle();
    expect(
      _colorOf(tester, JamSyncStrings.hostAsleep),
      JamNowPlayingColors.text,
    );
    expect(
      find.descendant(
        of: find.byType(JamSyncIndicator),
        matching: find.byType(Icon),
      ),
      findsNothing,
    );
  });

  testWidgets('out of sync is the only red glyph', (tester) async {
    await tester.pumpWidget(_host(JamSyncState.offSync));
    await tester.pumpAndSettle();
    expect(_colorOf(tester, JamSyncStrings.offSync), JamNowPlayingColors.text);
    expect(_glyphColor(tester), JamNowPlayingColors.destructive);
  });

  testWidgets('the same colours in either app theme (D4)', (tester) async {
    await tester.pumpWidget(_host(JamSyncState.offSync, dark: true));
    await tester.pumpAndSettle();
    expect(_colorOf(tester, JamSyncStrings.offSync), JamNowPlayingColors.text);
    expect(_glyphColor(tester), JamNowPlayingColors.destructive);
  });

  testWidgets('a swap fades through: the two lines are never both visible', (
    tester,
  ) async {
    await tester.pumpWidget(_host(JamSyncState.syncing));
    await tester.pumpAndSettle();
    await tester.pumpWidget(_host(JamSyncState.reconnecting));
    for (var ms = 0; ms <= 400; ms += 25) {
      await tester.pump(const Duration(milliseconds: 25));
      final visible = [
        for (final text in [
          JamSyncStrings.syncing,
          JamSyncStrings.reconnecting,
        ])
          if (find.text(text).evaluate().isNotEmpty &&
              _opacityOf(tester, text) > 0.01)
            text,
      ];
      expect(visible.length, lessThanOrEqualTo(1), reason: '$ms ms: $visible');
    }
    await tester.pumpAndSettle();
    expect(find.text(JamSyncStrings.syncing), findsNothing);
    expect(find.text(JamSyncStrings.reconnecting), findsOneWidget);
  });

  testWidgets('a count updates in place rather than fading through', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        JamSyncState.inSync,
        fallback: const JamStatusLine('Getting this song… 14%'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      _host(
        JamSyncState.inSync,
        fallback: const JamStatusLine('Getting this song… 15%'),
      ),
    );
    await tester.pump();
    expect(find.text('Getting this song… 14%'), findsNothing);
    expect(find.text('Getting this song… 15%'), findsOneWidget);
  });

  testWidgets('nothing animates on its own', (tester) async {
    await tester.pumpWidget(_host(JamSyncState.syncing));
    await tester.pumpAndSettle();
    expect(find.text(JamSyncStrings.syncing), findsOneWidget);
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('a sync problem outranks the fallback line', (tester) async {
    const news = JamStatusLine('Getting this song… 40%');
    await tester.pumpWidget(_host(JamSyncState.inSync, fallback: news));
    await tester.pumpAndSettle();
    expect(find.text(news.text), findsOneWidget);

    await tester.pumpWidget(_host(JamSyncState.reconnecting, fallback: news));
    await tester.pumpAndSettle();
    expect(find.text(news.text), findsNothing);
    expect(find.text(JamSyncStrings.reconnecting), findsOneWidget);
  });

  testWidgets('long-press opens the numbers; a tap does not', (tester) async {
    var opened = 0;
    await tester.pumpWidget(
      _host(JamSyncState.offSync, onShowDetails: () => opened++),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(JamSyncStrings.offSync));
    await tester.pump();
    expect(opened, 0);

    await tester.longPress(find.text(JamSyncStrings.offSync));
    await tester.pump();
    expect(opened, 1);
  });

  test('every problem has words, and the calm states have none', () {
    expect(jamSyncStatusLine(JamSyncState.inSync), isNull);
    expect(jamSyncStatusLine(JamSyncState.idle), isNull);
    for (final state in [
      JamSyncState.syncing,
      JamSyncState.reconnecting,
      JamSyncState.hostAway,
      JamSyncState.catchingUp,
      JamSyncState.offSync,
    ]) {
      expect(jamSyncStatusLine(state)?.text, isNotEmpty, reason: '$state');
    }
  });
}
