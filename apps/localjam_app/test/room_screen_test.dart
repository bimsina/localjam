import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/state/session_controller.dart';
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
