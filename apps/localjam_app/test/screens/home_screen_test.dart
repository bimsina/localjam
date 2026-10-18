/// Home is the answer to "is there a jam here?", not a landing page.
library;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Icons;
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_client/localjam_client.dart';
import 'package:localjam_app/src/design/theme.dart';
import 'package:localjam_app/src/screens/history_screen.dart';
import 'package:localjam_app/src/screens/home_screen.dart';
import 'package:localjam_app/src/screens/settings_screen.dart';
import 'package:localjam_app/src/state/session_controller.dart';
import 'package:localjam_app/src/widgets/avatar.dart';
import 'package:localjam_app/src/widgets/buttons.dart';
import 'package:localjam_app/src/widgets/empty_state.dart';
import 'package:localjam_app/src/widgets/list.dart';
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

/// The filled Start a Jam button, if it is on screen.
Iterable<JamButton> filledButtons(WidgetTester tester) => tester
    .widgetList<JamButton>(find.byType(JamButton))
    .where((b) => b.variant == JamButtonVariant.filled);

void main() {
  testWidgets('home leads with discovery and one way to start', (tester) async {
    final session = testSession();
    await pumpApp(tester, session);
    await tester.pumpAndSettle();

    // The large title, and the one filled action pinned at the bottom (D3).
    expect(find.text(HomeStrings.title), findsWidgets);
    final primaries = filledButtons(tester).toList();
    expect(primaries.length, 1);
    expect(primaries.single.label, HomeStrings.host);
    expect(
      tester.getCenter(find.text(HomeStrings.host)).dy,
      greaterThan(tester.getSize(find.byType(HomeScreen)).height / 2),
    );

    // §1.2 Quiet when correct: no "Listening for rooms", no status dot, no
    // landing-page copy.
    expect(find.textContaining('Listening'), findsNothing);
    expect(find.textContaining('No internet'), findsNothing);
    expect(find.text('Host a Jam'), findsNothing);
    // History's old nav-bar clock icon is gone; the sidebar and "See All"
    // reach it instead.
    expect(find.byIcon(Icons.history_rounded), findsNothing);
    expect(find.byIcon(CupertinoIcons.clock), findsNothing);
  });

  testWidgets('the nav bar carries the scanner and your avatar', (
    tester,
  ) async {
    final session = testSession();
    await pumpApp(tester, session);
    await tester.pumpAndSettle();

    // Scan lives in the nav bar now (D3), not as a second big button.
    expect(find.bySemanticsLabel(HomeStrings.scan), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.qrcode_viewfinder), findsOneWidget);
    // "Join with a link" moved into the scanner.
    expect(find.text('Join with a link'), findsNothing);

    // Your avatar opens Settings, where your name is changed.
    expect(find.byType(JamAvatar), findsWidgets);
    await tester.tap(find.bySemanticsLabel(HomeStrings.settings));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);
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
    // Its action is quiet: Start a Jam is the only filled button.
    expect(filledButtons(tester).length, 1);
  });

  testWidgets('a discovered room is a plain row with a tinted Join', (
    tester,
  ) async {
    final session = testSession();
    await pumpApp(tester, session);
    publishNearby(session, [room('Bar Room'), room('Kitchen Sunday')]);
    await tester.pumpAndSettle();

    expect(find.text('Bar Room'), findsOneWidget);
    expect(find.text('Kitchen Sunday'), findsOneWidget);
    expect(find.byType(JamRow), findsNWidgets(2));
    final joins = tester
        .widgetList<JamButton>(find.byType(JamButton))
        .where((b) => b.label == HomeStrings.join)
        .toList();
    expect(joins.length, 2);
    expect(joins.every((b) => b.variant == JamButtonVariant.tinted), isTrue);
    expect(joins.every((b) => b.size == JamButtonSize.small), isTrue);
    // mDNS carries only a name and a URI: no invented subtitle, no
    // listener count, no machine text.
    expect(find.text('Tap to join'), findsNothing);
    expect(find.textContaining('listening'), findsNothing);
    expect(find.textContaining('localjam://'), findsNothing);
    expect(find.byType(JamEmptyState), findsNothing);
  });

  testWidgets('a default-named room shows its host’s initials', (tester) async {
    expect(jamHostNameFromRoom('Turbo Flamingo’s Jam'), 'Turbo Flamingo');
    expect(jamHostNameFromRoom("Mia's Jam"), 'Mia');
    expect(jamHostNameFromRoom('Kitchen Sunday'), 'Kitchen Sunday');
    // Only a name that says whose it is gets a face.
    expect(jamRoomNamesHost('Mia’s Jam'), isTrue);
    expect(jamRoomNamesHost('Van Jam'), isFalse);
  });

  testWidgets('a room named for no one shows a neutral mark, not initials', (
    tester,
  ) async {
    final session = testSession();
    await pumpApp(tester, session);
    publishNearby(session, [room('Van Jam')]);
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.widgetWithText(JamRow, 'Van Jam'),
        matching: find.byType(JamAvatar),
      ),
      findsNothing,
    );
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

    // One quiet line, not a second "you're hosting" block over the mini
    // player, and no duplicate "Open Jam" — the mini player is the way back.
    expect(find.text(HomeStrings.hostingBody('Bar Room')), findsOneWidget);
    expect(find.text(HomeStrings.quietTitle), findsNothing);
    expect(find.byType(JamEmptyState), findsNothing);
    expect(find.text('Open Jam'), findsNothing);
    // You cannot host two at once, and the mini player owns the bottom: the
    // Start a Jam button is gone while the jam runs.
    expect(filledButtons(tester), isEmpty);

    await leaveTestSession(tester, session);
    await tester.pumpAndSettle();
    expect(filledButtons(tester).length, 1);
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
    // The row's Join turns into a system spinner while the probe runs.
    expect(find.byType(CupertinoActivityIndicator), findsOneWidget);
    final join = tester.widget<JamButton>(
      find.ancestor(
        of: find.byType(CupertinoActivityIndicator),
        matching: find.byType(JamButton),
      ),
    );
    expect(join.loading, isTrue);

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

  testWidgets('on a wide pane, Start a Jam centres on the reading column, '
      'which centres in the pane', (tester) async {
    tester.view.physicalSize = const Size(1032, 800) * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final session = testSession();
    await pumpApp(tester, session);
    await tester.pumpAndSettle();

    final pane = tester.getRect(find.byType(HomeScreen));
    final button = tester.getRect(find.text(HomeStrings.host));
    final empty = tester.getRect(find.byType(JamEmptyState));
    // One axis: the empty state and the button share a centre line.
    expect(button.center.dx, closeTo(empty.center.dx, 1));
    expect(button.center.dx, closeTo(pane.center.dx, 1));
    // A phone's width, not a banner across the pane.
    expect(
      tester.getRect(find.byType(JamButton)).width,
      lessThanOrEqualTo(400),
    );
  });

  testWidgets('renders on the dark palette', (tester) async {
    final session = testSession();
    await pumpApp(tester, session, theme: jamDarkTheme());
    publishNearby(session, [room('Bar Room')]);
    await tester.pumpAndSettle();

    expect(find.text('Bar Room'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  group('recent jams', () {
    final now = DateTime(2026, 10, 18, 15);

    test('say who hosted, how many songs and when — the same line Past '
        'Jams uses', () {
      JamHistoryRecord record({required bool host, int songs = 0}) =>
          JamHistoryRecord(
            sessionId: 's',
            sessionName: 'Van Jam',
            wasHost: host,
            startedAt: DateTime(2026, 10, 17, 20),
            updatedAt: DateTime(2026, 10, 17, 22),
            tracks: [
              for (var i = 0; i < songs; i++)
                JamHistoryTrack(
                  item: MediaItem(
                    mediaId: 'm$i',
                    kind: MediaKind.audio,
                    name: 'song$i.mp3',
                    mime: 'audio/mpeg',
                    sizeBytes: 1,
                    sha256: 'x',
                  ),
                ),
            ],
          );
      expect(
        jamHistorySummary(record(host: true, songs: 12), now: now),
        'You hosted · 12 songs · Yesterday, 10:00 PM',
      );
      expect(
        jamHistorySummary(record(host: false, songs: 1), now: now),
        'You joined · 1 song · Yesterday, 10:00 PM',
      );
      // No "0 songs": the part is simply not there.
      expect(
        jamHistorySummary(record(host: true), now: now),
        'You hosted · Yesterday, 10:00 PM',
      );
    });
  });
}
