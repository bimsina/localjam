/// The layout must change shape, not just stretch.
library;

import 'package:cupertino_ui/cupertino_ui.dart' show CupertinoIcons;
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/design/breakpoints.dart';
import 'package:localjam_app/src/design/theme.dart';
import 'package:localjam_app/src/design/tokens.dart';
import 'package:localjam_app/src/screens/home_screen.dart';
import 'package:localjam_app/src/screens/room_screen.dart';
import 'package:localjam_app/src/widgets/app_sidebar.dart';
import 'package:localjam_app/src/widgets/drag_to_dismiss.dart';
import 'package:localjam_app/src/widgets/queue_sheet.dart';
import 'package:localjam_app/src/widgets/room_bar.dart';
import 'package:localjam_app/src/widgets/room_sheet.dart';
import 'package:material_ui/material_ui.dart';

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
    expect(find.text(AppSidebarStrings.history), findsOneWidget);
    expect(find.text(AppSidebarStrings.settings), findsOneWidget);
    // Start a Jam is still the page's one filled action.
    expect(find.text(HomeStrings.host), findsOneWidget);
    // Identity lives in the sidebar, so the nav bar carries no avatar: the
    // only "Settings" node is the sidebar's own row. (go_router 18 keeps
    // shell chrome such as the sidebar in the semantics tree.)
    final settings = find.bySemanticsLabel('Settings');
    expect(settings, findsOneWidget);
    expect(
      find.descendant(of: find.byType(AppSidebar), matching: settings),
      findsOneWidget,
    );
  });

  testWidgets('the sidebar is plain: identity, then rows, no brand tile', (
    tester,
  ) async {
    final session = testSession();
    await resize(tester, _desktop);
    await pumpApp(tester, session);
    await tester.pumpAndSettle();

    // Like Music on the Mac: no wordmark, no gradient logo, no accent bar.
    expect(find.text('LocalJam'), findsNothing);
    final identity = tester.getCenter(find.text('Silky Puffin'));
    final nearby = tester.getCenter(
      find.descendant(
        of: find.byType(AppSidebar),
        matching: find.text(AppSidebarStrings.nearby),
      ),
    );
    expect(identity.dy, lessThan(nearby.dy));
    final row = tester.getSize(
      find
          .ancestor(
            of: find.text(AppSidebarStrings.history),
            matching: find.byType(Container),
          )
          .first,
    );
    expect(row.height, kJamSidebarRowHeight);
  });

  testWidgets('the selected sidebar row takes the tinted highlight', (
    tester,
  ) async {
    final session = testSession();
    await resize(tester, _desktop);
    await pumpApp(tester, session);
    await tester.pumpAndSettle();

    final tint = jamLightTheme().extension<JamColors>()!.tintFill;
    Finder highlighted() => find.descendant(
      of: find.byType(AppSidebar),
      matching: find.byWidgetPredicate(
        (w) =>
            w is Container &&
            w.decoration is BoxDecoration &&
            (w.decoration! as BoxDecoration).color == tint,
      ),
    );
    Finder within(String label) =>
        find.descendant(of: highlighted(), matching: find.text(label));

    // Exactly one, on the destination you are standing in.
    expect(highlighted(), findsOneWidget);
    expect(within(AppSidebarStrings.nearby), findsOneWidget);

    await tester.tap(find.text(AppSidebarStrings.settings));
    await tester.pumpAndSettle();
    expect(highlighted(), findsOneWidget);
    expect(within(AppSidebarStrings.settings), findsOneWidget);

    // Raspberry only where you are (D8): the other rows' icons are grey.
    final colors = jamLightTheme().extension<JamColors>()!;
    Color iconOf(IconData glyph) => tester
        .widget<Icon>(
          find.descendant(
            of: find.byType(AppSidebar),
            matching: find.byIcon(glyph),
          ),
        )
        .color!;
    expect(iconOf(CupertinoIcons.gear), colors.tint);
    expect(iconOf(CupertinoIcons.clock), colors.secondaryLabel);
    expect(
      iconOf(CupertinoIcons.antenna_radiowaves_left_right),
      colors.secondaryLabel,
    );
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

  testWidgets('a medium window floats the mini player, centred', (
    tester,
  ) async {
    final session = testSession();
    await resize(tester, _tablet);
    await pumpApp(tester, session);
    await startTestHost(tester, session, 'Tablet Jam');
    await tester.pumpAndSettle();

    // No sidebar at this width — phone chrome, with the mini player held to
    // a phone-ish width rather than stretched across the window.
    expect(find.byType(AppSidebar), findsNothing);
    final box = tester.getRect(find.byType(RoomBar));
    expect(box.width, lessThanOrEqualTo(720));
    expect(box.center.dx, closeTo(_tablet.width / 2, 1));
    expect(box.bottom, lessThanOrEqualTo(_tablet.height));

    await leaveTestSession(tester, session);
  });

  testWidgets('the mini player floats over the page, which scrolls under it', (
    tester,
  ) async {
    final session = testSession();
    await resize(tester, _phone);
    await pumpApp(tester, session);
    await startTestHost(tester, session, 'Phone Jam');
    await tester.pumpAndSettle();

    // Stacked over the screen, not in a column below it: the page still
    // reaches the window's bottom edge…
    expect(tester.getRect(find.byType(HomeScreen)).bottom, _phone.height);
    // …and sees the capsule as bottom padding, so its last row clears it.
    final padding = MediaQuery.paddingOf(
      tester.element(find.byType(HomeScreen)),
    );
    expect(padding.bottom, greaterThanOrEqualTo(jamRoomBarReach(0)));
    // Start a Jam gives way to the mini player.
    expect(find.text(HomeStrings.host), findsNothing);

    await leaveTestSession(tester, session);
  });

  testWidgets('a phone window has no sidebar', (tester) async {
    final session = testSession();
    await resize(tester, _phone);
    await pumpApp(tester, session);
    await tester.pumpAndSettle();

    expect(find.byType(AppSidebar), findsNothing);
    expect(find.text('Nearby'), findsWidgets);
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
