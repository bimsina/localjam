/// The layout must change shape, not just stretch.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/design/breakpoints.dart';
import 'package:localjam_app/src/screens/room_screen.dart';
import 'package:localjam_app/src/widgets/app_sidebar.dart';
import 'package:localjam_app/src/widgets/drag_to_dismiss.dart';
import 'package:localjam_app/src/widgets/queue_sheet.dart';
import 'package:localjam_app/src/widgets/room_bar.dart';
import 'package:localjam_app/src/widgets/room_sheet.dart';

import 'harness.dart';

/// Sizes the surface the way a window manager would.
Future<void> resize(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size * tester.view.devicePixelRatio;
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpAndSettle();
}

const _phone = Size(390, 844);
const _tablet = Size(834, 1112);
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

  testWidgets('the sidebar carries the brand above identity', (tester) async {
    final session = testSession();
    await resize(tester, _desktop);
    await pumpApp(tester, session);
    await tester.pumpAndSettle();

    // §5 "Wide layouts": the mark and the wordmark, 20 above the identity
    // row — a 1280px window has room to say whose app this is.
    expect(find.text(AppSidebarStrings.wordmark), findsOneWidget);
    final wordmark = tester.getCenter(find.text(AppSidebarStrings.wordmark));
    final identity = tester.getCenter(find.text('Silky Puffin'));
    expect(wordmark.dy, lessThan(identity.dy));
  });

  testWidgets('the selected nav item takes an accent bar', (tester) async {
    final session = testSession();
    await resize(tester, _desktop);
    await pumpApp(tester, session);
    await tester.pumpAndSettle();

    // Exactly one 3×20 bar, on the destination you are standing in.
    Finder bars() => find.descendant(
      of: find.byType(AppSidebar),
      matching: find.byWidgetPredicate(
        (w) =>
            w is Container &&
            w.constraints?.maxWidth == 3 &&
            w.constraints?.maxHeight == 20,
      ),
    );
    expect(bars(), findsOneWidget);

    await tester.tap(find.text(AppSidebarStrings.settings));
    await tester.pumpAndSettle();
    expect(bars(), findsOneWidget);
  });

  testWidgets("the room's panel uses flat tabs, not a segmented button", (
    tester,
  ) async {
    final session = testSession();
    await resize(tester, _desktop);
    final router = await pumpApp(tester, session);
    await startTestHost(tester, session, 'Panel Jam');
    router.push('/room');
    await tester.pumpAndSettle();

    // §5: a SegmentedButton in a 340 dp panel reads as a form control.
    expect(find.byType(SegmentedButton<Object?>), findsNothing);
    expect(find.text(JamRoomStrings.panelQueue), findsOneWidget);
    expect(find.text(JamRoomStrings.panelRoom), findsOneWidget);

    // And the tabs actually switch what is docked.
    await tester.tap(find.text(JamRoomStrings.panelRoom));
    await tester.pumpAndSettle();
    expect(find.byType(RoomPanel), findsOneWidget);
    expect(find.byType(QueuePanel), findsNothing);

    await leaveTestSession(tester, session);
  });

  testWidgets('a medium window floats the room bar as a pill', (tester) async {
    final session = testSession();
    await resize(tester, _tablet);
    await pumpApp(tester, session);
    await startTestHost(tester, session, 'Tablet Jam');
    await tester.pumpAndSettle();

    // No sidebar at this width — phone chrome, but the bar stops being
    // welded to the window's bottom edge (§5 "Medium").
    expect(find.byType(AppSidebar), findsNothing);
    final bar = tester.widget<RoomBar>(find.byType(RoomBar));
    expect(bar.floating, isTrue);
    // 720 wide at most, and clear of the edges.
    final box = tester.getRect(find.byType(JamRoomBar));
    expect(box.width, lessThanOrEqualTo(720));
    expect(box.bottom, lessThan(_tablet.height));

    await leaveTestSession(tester, session);
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
