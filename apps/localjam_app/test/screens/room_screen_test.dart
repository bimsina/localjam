/// The room screen: routing, the dismiss gesture, and what the player
/// actually puts on screen.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/design/theme.dart';
import 'package:localjam_app/src/screens/room_screen.dart';
import 'package:localjam_app/src/state/session_controller.dart';
import 'package:localjam_app/src/widgets/avatar.dart';
import 'package:localjam_app/src/widgets/buttons.dart';
import 'package:localjam_app/src/widgets/drag_to_dismiss.dart';
import 'package:localjam_app/src/widgets/transport.dart';
import 'package:localjam_client/localjam_client.dart';

import '../harness.dart';

void main() {
  testWidgets('hosting takes you into a live room', (tester) async {
    final session = testSession();
    final router = await pumpApp(tester, session);
    await startTestHost(tester, session, 'Van Jam');

    expect(session.isLive, isTrue);
    expect(session.isHost, isTrue);

    router.go('/room');
    await tester.pumpAndSettle();

    expect(find.byType(DragToDismiss), findsOneWidget);
    expect(find.text('Van Jam'), findsWidgets);
    // An empty room says what to do rather than showing a dead player.
    expect(find.text('Nothing queued'), findsOneWidget);
    expect(find.text('Add music'), findsOneWidget);
    // The people strip is the door to both sheets, and both doors are
    // labelled — §8 check 3 forbids bare integers standing in for words.
    expect(find.byType(JamAvatarStack), findsOneWidget);
    expect(find.text('1 in the room'), findsOneWidget);
    expect(find.text('0 queued'), findsOneWidget);
    expect(find.byIcon(Icons.queue_music_rounded), findsOneWidget);
    // §6.1: three unrelated things behind an ellipsis is a tool, not a room.
    expect(find.byType(PopupMenuButton<Object?>), findsNothing);
    expect(find.byIcon(Icons.more_horiz_rounded), findsNothing);
    // The transport is present even with nothing to play — a host sees the
    // controls they are about to use.
    expect(find.byType(JamTransport), findsOneWidget);

    await leaveTestSession(tester, session);
  });

  testWidgets('the session survives leaving the room screen', (tester) async {
    // The whole point of moving engine ownership above the Navigator: before
    // the overhaul, popping the route called engine.close() from dispose and
    // silently ended the jam for everyone.
    final session = testSession();
    final router = await pumpApp(tester, session);
    await startTestHost(tester, session, 'Trek Jam');

    router.push('/room');
    await tester.pumpAndSettle();
    expect(find.byType(DragToDismiss), findsOneWidget);

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
    expect(find.byType(DragToDismiss), findsOneWidget);

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

  testWidgets('home keeps rendering behind the player', (tester) async {
    // Flutter stops building routes behind an OPAQUE route once its entrance
    // transition completes — which made dragging the player down reveal bare
    // black rather than the app. The room page must stay non-opaque.
    final session = testSession();
    final router = await pumpApp(tester, session);
    await startTestHost(tester, session, 'Behind Jam');
    router.push('/room');
    await tester.pumpAndSettle();

    expect(find.byType(DragToDismiss), findsOneWidget);
    expect(
      find.text('Nearby'),
      findsOneWidget,
      reason: 'home must still be built underneath, or a drag reveals void',
    );

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
    expect(find.byType(DragToDismiss), findsOneWidget);

    // A long one puts the player away without ending the jam.
    await tester.drag(find.byType(DragToDismiss), const Offset(0, 400));
    await tester.pumpAndSettle();
    expect(find.byType(DragToDismiss), findsNothing);
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
    expect(find.byType(DragToDismiss), findsOneWidget);

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

  /// Sizes the surface the way a window manager would.
  Future<void> resize(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size * tester.view.devicePixelRatio;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pump();
  }

  /// The room on its own, without the router shell — so a layout assertion
  /// fails on the room rather than on whatever Home is doing this week.
  Future<void> pumpRoom(
    WidgetTester tester,
    JamSessionController session, {
    ThemeData? theme,
  }) async {
    resetJamCelebration();
    await tester.pumpWidget(
      JamSession(
        controller: session,
        child: MaterialApp(
          theme: theme ?? jamLightTheme(),
          home: const RoomScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the room holds its shape in landscape', (tester) async {
    // An Android landscape build overflowed the player by 113 px: the hero
    // took a fixed share of the height and the people strip fell off the
    // bottom. Short windows turn the room side-on instead.
    final session = testSession();
    await startTestHost(tester, session, 'Landscape Jam');
    await resize(tester, const Size(844, 390));
    await pumpRoom(tester, session);

    expect(tester.takeException(), isNull);
    expect(find.byType(JamAvatarStack), findsOneWidget);
    expect(find.byType(JamTransport), findsOneWidget);
    expect(find.text('Landscape Jam'), findsOneWidget);

    await leaveTestSession(tester, session);
  });

  testWidgets('the room holds its shape on a tall phone and on dark', (
    tester,
  ) async {
    final session = testSession();
    await startTestHost(tester, session, 'Tall Jam');
    await resize(tester, const Size(390, 844));
    await pumpRoom(tester, session, theme: jamDarkTheme());

    expect(tester.takeException(), isNull);
    expect(find.text('Nothing queued'), findsOneWidget);
    expect(find.byType(JamAvatarStack), findsOneWidget);

    await leaveTestSession(tester, session);
  });

  testWidgets('ending the jam lives in the People sheet, not the app bar', (
    tester,
  ) async {
    final session = testSession();
    await startTestHost(tester, session, 'Exit Jam');
    await resize(tester, const Size(390, 844));
    await pumpRoom(tester, session);

    // §6.1: no ellipsis, and no second red way out beside the room's name
    // either — the chevron minimises, it never ends anything.
    expect(find.byType(PopupMenuButton<Object?>), findsNothing);
    expect(find.text('End jam'), findsNothing);

    // The faces are the door: they open the sheet the End row lives in, and
    // it asks before it does anything. The row is the last thing in a long
    // sheet, under the invite and the switches, so it has to be scrolled to.
    await tester.tap(find.text('1 in the room'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('End jam'),
      300,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();
    expect(find.text('End jam'), findsOneWidget);

    await tester.tap(find.text('End jam'));
    await tester.pumpAndSettle();
    expect(find.text('End this jam?'), findsOneWidget);
    await tester.tap(find.text('Stay'));
    await tester.pumpAndSettle();
    expect(session.isLive, isTrue);

    await leaveTestSession(tester, session);
  });

  group('terminal states', () {
    Future<void> pumpEnded(
      WidgetTester tester,
      JamSessionEndReason? reason, {
      VoidCallback? onRetry,
      ThemeData? theme,
    }) => tester.pumpWidget(
      MaterialApp(
        theme: theme ?? jamLightTheme(),
        home: JamSessionEndedView(
          reason: reason,
          onDone: () {},
          onRetry: onRetry ?? () {},
        ),
      ),
    );

    testWidgets('a closed room offers a rejoin first', (tester) async {
      // Addendum §2: the host probably went to sleep, and the sha-keyed
      // cache means getting back in re-fetches nothing.
      await pumpEnded(tester, JamSessionEndReason.hostGone);
      expect(find.text('The room closed'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
      expect(find.text('Back to nearby'), findsOneWidget);

      final primary = tester.widget<JamButton>(
        find.ancestor(
          of: find.text('Try again'),
          matching: find.byType(JamButton),
        ),
      );
      expect(primary.variant, JamButtonVariant.primary);
    });

    testWidgets('a rejected rejoin offers a rejoin too', (tester) async {
      await pumpEnded(tester, JamSessionEndReason.rejected);
      expect(find.text('Could not rejoin'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    });

    testWidgets('a kick never invites you back', (tester) async {
      await pumpEnded(tester, JamSessionEndReason.kicked);
      expect(find.text('You were removed'), findsOneWidget);
      expect(find.text('Try again'), findsNothing);
      expect(find.text('Back to nearby'), findsOneWidget);
    });

    testWidgets('a host who ended the jam says so, on either palette', (
      tester,
    ) async {
      // The host said goodbye on purpose (§3.4), so there is no room left to
      // try again for — even with a retry callback in hand.
      await pumpEnded(
        tester,
        JamSessionEndReason.hostEnded,
        theme: jamDarkTheme(),
      );
      expect(find.text('The host ended the jam'), findsOneWidget);
      expect(find.text('Try again'), findsNothing);
      expect(find.text('Back to nearby'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('an end with no reason at all still has a way out', (
      tester,
    ) async {
      await pumpEnded(tester, null, onRetry: null);
      expect(find.text('Jam ended'), findsOneWidget);
      expect(find.text('Back to nearby'), findsOneWidget);
    });
  });
}
