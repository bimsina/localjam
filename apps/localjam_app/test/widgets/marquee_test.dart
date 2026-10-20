/// The Now Playing title's marquee (R1): still when it fits; when it does
/// not, a rest, a pass, a rest — a few times, then still; never moving
/// under reduced motion; always the whole title to a screen reader.
library;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/widgets/marquee.dart';

const _style = TextStyle(fontSize: 20, height: 1.2);
const _long = 'Kun Jaat Ko Ho Timi (feat. Bipul Chettri)';

Future<void> _pump(
  WidgetTester tester,
  String text, {
  double width = 200,
  bool reduced = false,
}) => tester.pumpWidget(
  MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: reduced),
      child: Scaffold(
        body: Center(
          child: SizedBox(
            width: width,
            child: JamMarquee(text, style: _style),
          ),
        ),
      ),
    ),
  ),
);

bool _ticking() => SchedulerBinding.instance.transientCallbackCount > 0;

void main() {
  testWidgets('a title that fits is plain text, and nothing moves', (
    tester,
  ) async {
    await _pump(tester, 'Golf', width: 200);
    await tester.pump();
    expect(find.text('Golf'), findsOneWidget);
    expect(_ticking(), isFalse);
  });

  testWidgets('a title that does not fit rests, scrolls, and comes back to '
      'where it began — a couple of times, then stays still', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, _long);
    await tester.pump();
    expect(_ticking(), isTrue);
    // At rest first: one copy, from its start.
    await tester.pump(const Duration(milliseconds: 1500));
    expect(find.text(_long), findsOneWidget);
    // Then it moves: the copy that follows it round appears.
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.text(_long), findsNWidgets(2));
    // A screen reader hears the title once, whole, moving or not.
    expect(find.bySemanticsLabel(_long), findsOneWidget);

    // Two passes, then still, at its start.
    await tester.pumpAndSettle();
    expect(_ticking(), isFalse);
    expect(find.text(_long), findsOneWidget);
    handle.dispose();
  });

  testWidgets('a new title goes round again', (tester) async {
    await _pump(tester, _long);
    await tester.pumpAndSettle();
    expect(_ticking(), isFalse);
    await _pump(tester, '$_long (Live at the Lakeside)');
    await tester.pump();
    expect(_ticking(), isTrue);
    await tester.pumpAndSettle();
  });

  testWidgets('under reduced motion it never moves: it ends in an ellipsis', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, _long, reduced: true);
    await tester.pump();
    expect(_ticking(), isFalse);
    final text = tester.widget<Text>(find.text(_long));
    expect(text.maxLines, 1);
    expect(text.overflow, TextOverflow.ellipsis);
    expect(find.bySemanticsLabel(_long), findsOneWidget);
    handle.dispose();
  });

  testWidgets('given room to fit, a scrolling title stops', (tester) async {
    tester.view.physicalSize = const Size(2400, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await _pump(tester, _long);
    await tester.pump();
    expect(_ticking(), isTrue);
    await _pump(tester, _long, width: 2000);
    await tester.pump();
    await tester.pump();
    expect(_ticking(), isFalse);
    expect(find.text(_long), findsOneWidget);
  });
}
