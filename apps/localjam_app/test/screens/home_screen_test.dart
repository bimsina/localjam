/// Home is the answer to "is there a jam here?", not a landing page.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/widgets/rename_dialog.dart';
import 'package:localjam_client/localjam_client.dart';
import 'package:localjam_app/src/screens/home_screen.dart';
import 'package:localjam_app/src/screens/settings_screen.dart';
import 'package:localjam_app/src/state/session_controller.dart';
import 'package:localjam_app/src/widgets/avatar.dart';
import 'package:localjam_app/src/widgets/buttons.dart';
import 'package:localjam_app/src/widgets/empty_state.dart';
import 'package:localjam_app/src/widgets/notice.dart';

import '../harness.dart';

/// Publishes a discovered room without a real mDNS browse.
///
/// The controller owns the notifier the screen listens to, and hands it out
/// as a [ValueListenable]; a test is allowed to know it is the same object.
void publishNearby(JamSessionController session, List<JamNearbyRoom> rooms) {
  (session.nearbyRooms as ValueNotifier<List<JamNearbyRoom>>).value = rooms;
}

JamNearbyRoom room(String name) => JamNearbyRoom(
  key: '_$name._localjam._tcp',
  sessionName: name,
  joinUri: Uri.parse(
    'localjam://join?host=192.168.1.20&port=45999&token=t_$name&name=$name',
  ),
);

void main() {
  testWidgets('home leads with live discovery, not a pitch', (tester) async {
    final session = testSession();
    await pumpApp(tester, session);
    await tester.pump();

    // The screen's job is to answer "is there a jam here?".
    expect(find.text(HomeStrings.title), findsOneWidget);
    expect(find.text(HomeStrings.host), findsOneWidget);
    // And it says the radio is on, without inventing a network name it has
    // no way to read.
    expect(find.text(HomeStrings.listening), findsOneWidget);
    expect(find.textContaining('Wi-Fi name'), findsNothing);

    // None of the landing-page copy the overhaul removed. The app is already
    // installed; it does not need to sell itself.
    expect(find.textContaining('No internet'), findsNothing);
    expect(find.textContaining('No accounts'), findsNothing);
    expect(find.textContaining('Same Wi-Fi'), findsNothing);
    expect(find.textContaining('Synchronized playback'), findsNothing);
    expect(find.text('Host a Jam'), findsNothing);
    expect(find.text('Join a Jam'), findsNothing);
  });

  testWidgets('home shows your identity and lets you rename', (tester) async {
    // JamIdentity.displayName caches per process, so every test in this file
    // sees the identity the first one resolved.
    final session = testSession();
    await pumpApp(tester, session);
    await tester.pump();

    expect(find.text('Silky Puffin'), findsOneWidget);
    expect(find.byType(JamAvatar), findsWidgets);

    await tester.tap(find.text('Silky Puffin'));
    await tester.pumpAndSettle();
    // JamIdentity.setDisplayName shipped in v1 with no caller anywhere.
    expect(find.text(RenameStrings.title), findsOneWidget);
  });

  testWidgets('the empty state names the situation', (tester) async {
    final session = testSession();
    await pumpApp(tester, session);
    await tester.pumpAndSettle();

    // Whichever branch the test machine's network lands on, the screen must
    // say something concrete rather than shrug — through the shared empty
    // state, not a bespoke column.
    expect(find.byType(JamEmptyState), findsOneWidget);
    expect(
      find.textContaining(
        RegExp('${HomeStrings.offlineTitle}|${HomeStrings.quietTitle}'),
      ),
      findsWidgets,
    );
  });

  testWidgets('the two ways in are a secondary and one primary', (
    tester,
  ) async {
    final session = testSession();
    await pumpApp(tester, session);
    await tester.pumpAndSettle();

    final primaries = tester
        .widgetList<JamButton>(find.byType(JamButton))
        .where((b) => b.variant == JamButtonVariant.filled)
        .toList();
    // Exactly one raspberry-filled control in view (§8.5).
    expect(primaries.length, 1);
    expect(primaries.single.label, HomeStrings.host);
    expect(find.text(HomeStrings.scan), findsOneWidget);
  });

  testWidgets('joining by link is a tertiary under the two main actions', (
    tester,
  ) async {
    final session = testSession();
    await pumpApp(tester, session);
    await tester.pumpAndSettle();

    // No overflow menu: three trailing app-bar icons read as a toolbar, and
    // the third way in is quieter *and* visible in the bottom bar instead.
    expect(find.byIcon(Icons.more_horiz_rounded), findsNothing);
    final link = find.text(HomeStrings.joinWithLink);
    expect(link, findsOneWidget);
    // Under the two buttons, not beside them.
    expect(
      tester.getTopLeft(link).dy,
      greaterThan(tester.getBottomLeft(find.text(HomeStrings.host)).dy),
    );
  });

  testWidgets('a discovered room is a card with a real Join action', (
    tester,
  ) async {
    final session = testSession();
    await pumpApp(tester, session);
    publishNearby(session, [room('Bar Room'), room('Kitchen Sunday')]);
    await tester.pumpAndSettle();

    expect(find.text('Bar Room'), findsOneWidget);
    // The byline never implies a listener count or a host name: mDNS carries
    // neither.
    expect(find.text(HomeStrings.tapToJoin), findsNWidgets(2));
    expect(find.textContaining('listening'), findsNothing);
    expect(find.text(HomeStrings.join), findsNWidgets(2));
    // A card, not a settings row.
    expect(find.byIcon(Icons.chevron_right_rounded), findsNothing);
    // No machine text.
    expect(find.textContaining('localjam://'), findsNothing);
  });

  testWidgets('home says you are hosting rather than "nobody is hosting"', (
    tester,
  ) async {
    // The review's flat contradiction: "Nobody on this network is hosting
    // yet" over a room this device was running.
    final session = testSession();
    await pumpApp(tester, session);
    await startTestHost(tester, session, 'Bar Room');
    await tester.pumpAndSettle();

    expect(find.text(HomeStrings.hostingTitle('Bar Room')), findsOneWidget);
    expect(find.text(HomeStrings.hostingBody), findsOneWidget);
    expect(find.text(HomeStrings.quietTitle), findsNothing);
    // ...and the way back into it, since the bottom actions are gone.
    expect(find.text(HomeStrings.openRoom), findsOneWidget);

    await leaveTestSession(tester, session);
  });

  testWidgets('a nearby room that has gone says so instead of hanging', (
    tester,
  ) async {
    // An mDNS record outlives its room by up to two TTLs, so the list can
    // offer a jam whose host went home. The tap probes first: a dead room
    // fails in a blink with a sentence, rather than as a join timeout.
    final session = testSession();
    await session.startBrowsing(
      // `Stream<Never>` stands in for the bonsoir event stream, which this
      // package does not depend on directly: nothing is discovered through
      // the platform, the room below is published straight onto the list.
      browser: JamRoomBrowser.withSources(
        events: const Stream<Never>.empty(),
        // The host is not answering any more. The delay is the point of the
        // probe: it is what the row spins over.
        connect: (_, _, _) async {
          await Future<void>.delayed(const Duration(milliseconds: 200));
          return false;
        },
      ),
    );
    await pumpApp(tester, session);
    publishNearby(session, [room('Bar Room')]);
    await tester.pumpAndSettle();

    await tester.tap(find.text(HomeStrings.join));
    await tester.pump();
    // The row says it is working on it while the probe runs.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.text(kJamRoomGone), findsOneWidget);
    // Nothing was dialled, so no join error and no room screen.
    expect(session.phase, JamSessionPhase.idle);
    expect(session.error, isNull);

    // Let the notice go on its own rather than leaving its timer pending.
    await tester.pump(kJamNoticeDuration);
    await tester.pumpAndSettle();

    // Not pumped after: home restarts the browse on its next rebuild, and a
    // browse owns a periodic sweep timer.
    await session.stopBrowsing();
  });

  testWidgets('history and settings are one tap away', (tester) async {
    final session = testSession();
    await pumpApp(tester, session);
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.settings_rounded));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);
  });
}
