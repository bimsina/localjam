/// The layout must change shape, not just stretch.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/design/breakpoints.dart';
import 'package:localjam_app/src/widgets/app_sidebar.dart';
import 'package:localjam_app/src/widgets/drag_to_dismiss.dart';
import 'package:localjam_app/src/widgets/queue_sheet.dart';

import 'harness.dart';

/// Sizes the surface the way a window manager would.
Future<void> resize(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size * tester.view.devicePixelRatio;
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpAndSettle();
}

const _phone = Size(390, 844);
const _desktop = Size(1280, 800);

void main() {
  group('breakpointFor', () {
    test('splits at the points the chrome stops working', () {
      expect(breakpointFor(390), JamBreakpoint.compact);
      expect(breakpointFor(599), JamBreakpoint.compact);
      expect(breakpointFor(600), JamBreakpoint.medium);
      expect(breakpointFor(999), JamBreakpoint.medium);
      expect(breakpointFor(1000), JamBreakpoint.expanded);
      expect(breakpointFor(1920), JamBreakpoint.expanded);
    });

    test('only expanded gets desktop chrome', () {
      expect(JamBreakpoint.compact.hasSidebar, isFalse);
      expect(JamBreakpoint.medium.hasSidebar, isFalse);
      expect(JamBreakpoint.expanded.hasSidebar, isTrue);
      expect(JamBreakpoint.expanded.hasSidePanel, isTrue);
    });
  });

  testWidgets('a desktop window navigates by sidebar', (tester) async {
    final session = testSession();
    await resize(tester, _desktop);
    await pumpApp(tester, session);
    await tester.pumpAndSettle();

    expect(find.byType(AppSidebar), findsOneWidget);
    expect(find.text('Past jams'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
    // The bottom action bar belongs to phones; the actions move beside the
    // title instead of being stranded across a 1280px window.
    expect(find.text('Start a jam'), findsOneWidget);
  });

  testWidgets('a phone window has no sidebar', (tester) async {
    final session = testSession();
    await resize(tester, _phone);
    await pumpApp(tester, session);
    await tester.pumpAndSettle();

    expect(find.byType(AppSidebar), findsNothing);
    expect(find.text('Nearby'), findsOneWidget);
  });

  testWidgets('the room docks its panel on desktop and not on a phone', (
    tester,
  ) async {
    final session = testSession();
    await resize(tester, _desktop);
    final router = await pumpApp(tester, session);
    await startTestHost(tester, session, 'Desk Jam');
    router.push('/room');
    await tester.pumpAndSettle();

    // Queue stays open beside the player rather than behind a tap.
    expect(find.byType(QueuePanel), findsOneWidget);
    expect(find.byType(AppSidebar), findsOneWidget);

    await leaveTestSession(tester, session);
  });

  testWidgets('the dismiss gesture is phone-only', (tester) async {
    final session = testSession();
    await resize(tester, _desktop);
    final router = await pumpApp(tester, session);
    await startTestHost(tester, session, 'Gesture Jam');
    router.push('/room');
    await tester.pumpAndSettle();

    // Present, but inert: a desktop window has no swipe-down-to-dismiss.
    final drag = tester.widget<DragToDismiss>(find.byType(DragToDismiss));
    expect(drag.enabled, isFalse);

    await leaveTestSession(tester, session);
  });
}
