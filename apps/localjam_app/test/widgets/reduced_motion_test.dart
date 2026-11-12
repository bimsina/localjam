/// Reduced motion from either source.
///
/// Android's "Remove animations" sets MediaQuery's `disableAnimations`; iOS's
/// Reduce Motion sets only `AccessibilityFeatures.reduceMotion`, which the
/// app never read — so on an iPhone set to Reduce Motion the title still
/// marqueed and nothing else held still either.
library;

import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/design/motion.dart';
import 'package:localjam_app/src/widgets/marquee.dart';
import 'package:material_ui/material_ui.dart';

const _long = 'Kun Jaat Ko Ho Timi (feat. Bipul Chettri)';

void main() {
  late bool reduced;

  Widget probe() => Builder(
    builder: (context) {
      reduced = jamReducedMotion(context);
      return const SizedBox.shrink();
    },
  );

  Future<void> pump(
    WidgetTester tester, {
    bool disableAnimations = false,
    bool scoped = false,
    Widget? child,
  }) => tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: disableAnimations),
        child: scoped
            ? JamReducedMotion(child: child ?? probe())
            : child ?? probe(),
      ),
    ),
  );

  void setReduceMotion(WidgetTester tester, bool on) {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        FakeAccessibilityFeatures(reduceMotion: on);
  }

  tearDown(() {
    TestWidgetsFlutterBinding.instance.platformDispatcher
        .clearAccessibilityFeaturesTestValue();
  });

  testWidgets('neither source: things move', (tester) async {
    await pump(tester);
    expect(reduced, isFalse);
  });

  testWidgets('Android’s Remove animations (MediaQuery) holds things still', (
    tester,
  ) async {
    await pump(tester, disableAnimations: true);
    expect(reduced, isTrue);
  });

  testWidgets('iOS’s Reduce Motion (the platform flag) holds things still', (
    tester,
  ) async {
    setReduceMotion(tester, true);
    await pump(tester);
    expect(reduced, isTrue);
    await pump(tester, scoped: true);
    expect(reduced, isTrue);
  });

  testWidgets('switching Reduce Motion on while the app runs stills it', (
    tester,
  ) async {
    await pump(tester, scoped: true);
    expect(reduced, isFalse);
    setReduceMotion(tester, true);
    await tester.pump();
    expect(reduced, isTrue);
    setReduceMotion(tester, false);
    await tester.pump();
    expect(reduced, isFalse);
  });

  testWidgets('a long title under iOS Reduce Motion ends in an ellipsis', (
    tester,
  ) async {
    setReduceMotion(tester, true);
    await pump(
      tester,
      scoped: true,
      child: const Scaffold(
        body: Center(
          child: SizedBox(
            width: 200,
            child: JamMarquee(_long, style: TextStyle(fontSize: 20)),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(SchedulerBinding.instance.transientCallbackCount, 0);
    final text = tester.widget<Text>(find.text(_long));
    expect(text.overflow, TextOverflow.ellipsis);
  });
}
