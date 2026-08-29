import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/state/session_controller.dart';
import 'package:localjam_app/src/widgets/drag_to_dismiss.dart';
import 'package:localjam_client/localjam_client.dart';

import 'harness.dart';

void main() {
  testWidgets('hosting takes you into a live room', (tester) async {
    final session = testSession();
    final router = await pumpApp(tester, session);
    await startTestHost(tester, session, 'Van Jam');

    expect(session.isLive, isTrue);
    expect(session.isHost, isTrue);

    router.go('/room');
    await tester.pumpAndSettle();

    expect(find.text('Van Jam'), findsOneWidget);
    // An empty room says what to do rather than showing a dead player.
    expect(find.text('Nothing queued'), findsOneWidget);
    expect(find.text('Add something to get the room going'), findsOneWidget);
    // Presence and the queue are behind the utility row, not on the player.
    expect(find.byIcon(Icons.queue_music_rounded), findsOneWidget);

    await leaveTestSession(tester, session);
  });

  testWidgets('the session survives leaving the room screen', (tester) async {
    // The whole point of moving engine ownership above the Navigator: before
    // the overhaul, popping the route called engine.close() from dispose and
    // silently ended the jam for everyone.
    final session = testSession();
    final router = await pumpApp(tester, session);
    await startTestHost(tester, session, 'Trek Jam');

    router.go('/room');
    await tester.pumpAndSettle();
    expect(find.text('Trek Jam'), findsOneWidget);

    router.go('/');
    await tester.pumpAndSettle();

    expect(session.isLive, isTrue);
    expect(session.engine, isNotNull);
    // ...and the docked room bar keeps it one tap away.
    expect(find.text('Trek Jam'), findsWidgets);

    await leaveTestSession(tester, session);
  });

  testWidgets('the room is only reachable while one exists', (tester) async {
    final session = testSession();
    final router = await pumpApp(tester, session);

    router.go('/room');
    await tester.pumpAndSettle();

    // Redirected home rather than rendering an empty room.
    expect(find.text('Nearby'), findsOneWidget);
  });

  testWidgets('leaving ends the session', (tester) async {
    final session = testSession();
    final router = await pumpApp(tester, session);
    await startTestHost(tester, session, 'Hostel Jam');
    router.go('/room');
    await tester.pumpAndSettle();

    await leaveTestSession(tester, session);

    expect(session.isLive, isFalse);
    expect(session.phase, JamSessionPhase.idle);
    expect(session.engine, isNull);
  });

  /// Offsets of everything mid-slide, ignoring the settled ones.
  List<Offset> slidingOffsets(WidgetTester tester) => tester
      .widgetList<SlideTransition>(find.byType(SlideTransition))
      .map((w) => w.position.value)
      .where((o) => o != Offset.zero)
      .toList();

  testWidgets('the room rises from the bottom and drops back down', (
    tester,
  ) async {
    // Minimising the player should read as putting it away, not as
    // navigating somewhere else. Two things conspire against that: the
    // platform's default page transition is a horizontal fade-forwards, and
    // `go` REPLACES the stack — a replacement drops the outgoing route
    // without running its reverse transition, so the room would vanish
    // instantly while home slid in sideways. Hence a pushed route with its
    // own vertical transition, popped to dismiss.
    final session = testSession();
    final router = await pumpApp(tester, session);
    await startTestHost(tester, session, 'Slide Jam');

    router.push('/room');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    final entering = slidingOffsets(tester);
    expect(entering, isNotEmpty, reason: 'the room should be mid-slide');
    for (final offset in entering) {
      expect(offset.dx, 0, reason: 'must not travel horizontally');
      expect(offset.dy, greaterThan(0), reason: 'must rise from below');
    }

    await tester.pumpAndSettle();
    expect(find.text('Slide Jam'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.keyboard_arrow_down_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final leaving = slidingOffsets(tester);
    expect(
      leaving,
      isNotEmpty,
      reason: 'the room must animate out, not disappear',
    );
    for (final offset in leaving) {
      expect(offset.dx, 0, reason: 'must not travel horizontally');
      expect(offset.dy, greaterThan(0), reason: 'must drop back down');
    }

    await tester.pumpAndSettle();
    // Dismissing minimises; it does not end the jam.
    expect(session.isLive, isTrue);
    await leaveTestSession(tester, session);
  });

  testWidgets('dragging the player down dismisses it', (tester) async {
    final session = testSession();
    final router = await pumpApp(tester, session);
    await startTestHost(tester, session, 'Drag Jam');
    router.push('/room');
    await tester.pumpAndSettle();

    // A short drag is not a dismissal — it springs back.
    await tester.drag(find.byType(DragToDismiss), const Offset(0, 40));
    await tester.pumpAndSettle();
    expect(find.text('Drag Jam'), findsOneWidget);

    // A long one puts the player away without ending the jam.
    await tester.drag(find.byType(DragToDismiss), const Offset(0, 400));
    await tester.pumpAndSettle();
    expect(find.text('Nearby'), findsOneWidget);
    expect(session.isLive, isTrue);

    await leaveTestSession(tester, session);
  });

  testWidgets('dragging up does not lift the player off the screen', (
    tester,
  ) async {
    final session = testSession();
    final router = await pumpApp(tester, session);
    await startTestHost(tester, session, 'Up Jam');
    router.push('/room');
    await tester.pumpAndSettle();

    await tester.drag(find.byType(DragToDismiss), const Offset(0, -300));
    await tester.pumpAndSettle();

    // The outermost Transform under DragToDismiss is the one it applies;
    // everything deeper belongs to icons and ink.
    final translate = tester
        .widgetList<Transform>(
          find.descendant(
            of: find.byType(DragToDismiss),
            matching: find.byType(Transform),
          ),
        )
        .first
        .transform
        .getTranslation();
    expect(translate.y, 0, reason: 'upward drags are clamped away');
    expect(find.text('Up Jam'), findsOneWidget);

    await leaveTestSession(tester, session);
  });

  test('a host holds every capability; the room policy gates guests', () {
    // Guarding the gate the whole Room UI is built on.
    const open = JamPermissions.initial(policy: JamPolicy.open);
    const listen = JamPermissions.initial(policy: JamPolicy.listenOnly);
    expect(
      open.capabilitiesOf(JamPermissions.hostPeerId),
      containsAll(JamCapability.values),
    );
    expect(
      listen.capabilitiesOf(JamPermissions.hostPeerId),
      containsAll(JamCapability.values),
    );
    expect(listen.allows('p_1', JamCapability.controlPlayback), isFalse);
    expect(open.allows('p_1', JamCapability.controlPlayback), isTrue);
  });
}
