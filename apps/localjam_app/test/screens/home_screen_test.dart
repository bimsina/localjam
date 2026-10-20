/// Home is the answer to "is there a jam here?", not a landing page.
library;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Icons, MaterialApp;
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_client/localjam_client.dart';
import 'package:localjam_app/src/design/theme.dart';
import 'package:localjam_app/src/design/tokens.dart';
import 'package:localjam_app/src/screens/history_screen.dart';
import 'package:localjam_app/src/screens/home_screen.dart';
import 'package:localjam_app/src/screens/settings_screen.dart';
import 'package:localjam_app/src/state/session_controller.dart';
import 'package:localjam_app/src/util/network.dart';
import 'package:localjam_app/src/widgets/avatar.dart';
import 'package:localjam_app/src/widgets/buttons.dart';
import 'package:localjam_app/src/widgets/empty_state.dart';
import 'package:localjam_app/src/widgets/jam_mark.dart';
import 'package:localjam_app/src/widgets/join_link_dialog.dart';
import 'package:localjam_app/src/widgets/notice.dart';
import 'package:localjam_app/src/widgets/permission_sheet.dart';
import 'package:localjam_app/src/widgets/progress.dart';
import 'package:localjam_app/src/widgets/room_sheet.dart';
import 'package:localjam_app/src/widgets/wifi_glyph.dart';

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

const JamNetworkStatus lan = JamNetworkStatus(
  addresses: ['192.168.1.20'],
  interface: 'en0',
);
const JamNetworkStatus hotspot = JamNetworkStatus(
  addresses: ['172.20.10.1'],
  interface: 'bridge100',
);

JamHistoryRecord record(String name) => JamHistoryRecord(
  sessionId: 's_$name',
  sessionName: name,
  wasHost: true,
  startedAt: DateTime(2026, 10, 17, 20),
  updatedAt: DateTime(2026, 10, 17, 22),
  tracks: const [],
);

/// Home on its own, on a network and with recents of the test's choosing.
Future<void> pumpHome(
  WidgetTester tester, {
  required JamNetworkStatus network,
  List<JamHistoryRecord> records = const [],
}) async {
  final session = testSession();
  await tester.pumpWidget(
    JamSession(
      controller: session,
      child: MaterialApp(
        theme: jamLightTheme(),
        home: HomeScreen(
          key: UniqueKey(),
          networkReader: () async => network,
          loadRecords: () async => records,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

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
    // History's old nav-bar clock icon is gone; the sidebar and "See all"
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

  testWidgets('a discovered room is a jam card with a tinted Join', (
    tester,
  ) async {
    final session = testSession();
    await pumpApp(tester, session);
    publishNearby(session, [room('Bar Room'), room('Kitchen Sunday')]);
    await tester.pumpAndSettle();

    expect(find.text('Bar Room'), findsOneWidget);
    expect(find.text('Kitchen Sunday'), findsOneWidget);
    // Each room is drawn as a jam — its mark — and its name in Manrope, as
    // where the name is born (Start a Jam's field).
    expect(find.byType(JamMark), findsNWidgets(2));
    expect(
      tester.widget<Text>(find.text('Bar Room')).style?.fontFamily,
      'Manrope',
    );
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
    // No circles posing as a jam: a person is a circle, a jam a square.
    expect(find.byIcon(CupertinoIcons.music_note_2), findsNothing);
  });

  testWidgets('a room card is one button that joins', (tester) async {
    final session = testSession();
    await pumpApp(tester, session);
    publishNearby(session, [room('Bar Room')]);
    await tester.pumpAndSettle();

    expect(find.bySemanticsLabel(HomeStrings.joinRoom('Bar Room')), findsOne);
  });

  testWidgets('a nearby jam is its monogram, with no face — not even one '
      'its name suggests', (tester) async {
    final session = testSession();
    await pumpApp(tester, session);
    publishNearby(session, [room('Van Jam'), room('Mia’s Jam')]);
    await tester.pumpAndSettle();

    final marks = tester.widgetList<JamMark>(find.byType(JamMark)).toList();
    expect(marks, hasLength(2));
    // "Mia’s Jam" may be hosted by Theo: discovery says no more than a
    // name, so no face is guessed from it.
    expect(marks.every((m) => m.hostName == null), isTrue);
    expect(
      find.descendant(
        of: find.byType(JamMark),
        matching: find.byType(JamAvatar),
      ),
      findsNothing,
    );
    // No cover travels over mDNS: the monogram, never a guessed picture.
    expect(marks.every((m) => m.cover == null), isTrue);
    // On the card's surface the mark takes `fill`, which still reads there.
    final colors = tester.element(find.byType(JamMark).first).jamColors;
    expect(marks.every((m) => m.ground == colors.fill), isTrue);
  });

  testWidgets('a jam’s name in a row is Manrope at row scale', (tester) async {
    final session = testSession();
    await pumpApp(tester, session);
    publishNearby(session, [room('Bar Room')]);
    await tester.pumpAndSettle();

    final style = tester.widget<Text>(find.text('Bar Room')).style!;
    expect(style.fontFamily, 'Manrope');
    expect(style.fontSize, 17);
    expect(style.fontWeight, FontWeight.w700);
  });

  testWidgets('at large text a long name keeps the width, and Join goes '
      'under it', (tester) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final session = testSession();
    await pumpApp(tester, session);
    const name = 'Electric Mongoose Supreme’s Jam';
    publishNearby(session, [room(name)]);
    await tester.pumpAndSettle();
    Rect join() => tester.getRect(
      find.ancestor(
        of: find.text(HomeStrings.join),
        matching: find.byType(JamButton),
      ),
    );

    // 1×: beside the name, centred on it.
    final beside = join();
    expect(
      beside.center.dy,
      closeTo(tester.getRect(find.text(name)).center.dy, 1),
    );
    expect(beside.left, greaterThan(tester.getRect(find.text(name)).right));

    // 2×: under it, and nothing overflows.
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final under = join();
    expect(
      under.top,
      greaterThanOrEqualTo(tester.getRect(find.text(name)).bottom),
    );
    expect(under.left, closeTo(tester.getRect(find.text(name)).left, 1));
    // The name is the card's only identifier: it wraps whole, never cut at
    // two lines (R10).
    final text = tester.renderObject<RenderParagraph>(find.text(name));
    expect(text.didExceedMaxLines, isFalse);
  });

  testWidgets('"Don’t see your jam?" keeps its line on a narrow phone at '
      'large text, with the ways in under it', (tester) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final session = testSession();
    await pumpApp(tester, session);
    publishNearby(session, [room('Bar Room')]);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text(HomeStrings.joinWithLink), 80);

    expect(tester.takeException(), isNull);
    final sentence = tester.getRect(find.text(HomeStrings.notListed));
    final scan = tester.getRect(find.text(HomeStrings.scan));
    expect(scan.top, greaterThan(sentence.bottom));
    // The buttons themselves wrap rather than run off the edge.
    expect(
      tester.getRect(find.text(HomeStrings.joinWithLink)).right,
      lessThanOrEqualTo(320),
    );
  });

  testWidgets('under the rooms, the other ways in — the link without the '
      'camera', (tester) async {
    final session = testSession();
    await pumpApp(tester, session);
    publishNearby(session, [room('Bar Room')]);
    await tester.pumpAndSettle();

    expect(find.text(HomeStrings.notListed), findsOneWidget);
    expect(find.text(HomeStrings.scan), findsOneWidget);
    await tester.tap(find.text(HomeStrings.joinWithLink));
    await tester.pumpAndSettle();
    // Straight to the link alert: no camera primer on the way.
    expect(find.byType(JoinLinkDialog), findsOneWidget);
    expect(find.byType(JamPermissionSheet), findsNothing);
  });

  testWidgets('the empty state offers the link beside the scanner', (
    tester,
  ) async {
    await pumpHome(tester, network: lan);

    final empty = tester.widget<JamEmptyState>(find.byType(JamEmptyState));
    expect(empty.title, HomeStrings.quietTitle);
    expect(empty.actionLabel, HomeStrings.scan);
    expect(empty.secondaryActionLabel, HomeStrings.joinWithLink);
    await tester.tap(find.text(HomeStrings.joinWithLink));
    await tester.pumpAndSettle();
    expect(find.byType(JoinLinkDialog), findsOneWidget);
    expect(find.byType(JamPermissionSheet), findsNothing);
  });

  testWidgets('a phone sharing its hotspot is talked to as the host', (
    tester,
  ) async {
    await pumpHome(tester, network: hotspot);

    final empty = tester.widget<JamEmptyState>(find.byType(JamEmptyState));
    expect(empty.title, HomeStrings.hotspotTitle);
    // The viewfinder the nav bar and the camera primer show — one QR glyph.
    expect(empty.icon, CupertinoIcons.qrcode_viewfinder);
    // Start a Jam stays the one filled action; scanning stays neutral.
    expect(empty.actionVariant, JamButtonVariant.gray);
    expect(filledButtons(tester).length, 1);
  });

  testWidgets('offline, there is nothing to scan or paste into', (
    tester,
  ) async {
    await pumpHome(tester, network: JamNetworkStatus.offline);

    final empty = tester.widget<JamEmptyState>(find.byType(JamEmptyState));
    expect(empty.title, HomeStrings.offlineTitle);
    expect(empty.actionLabel, isNull);
    expect(empty.secondaryActionLabel, isNull);
  });

  testWidgets('the empty state sits at the same height whatever it says', (
    tester,
  ) async {
    // Centring moved the glyph 20–30 pt between states (one action, two, or
    // none); anchored, it does not move at all.
    await pumpHome(tester, network: JamNetworkStatus.offline);
    final offline = tester.getTopLeft(find.byType(JamWifiGlyph));
    await pumpHome(tester, network: lan);
    final quiet = tester.getTopLeft(
      find.byIcon(CupertinoIcons.antenna_radiowaves_left_right),
    );
    expect(offline.dy, closeTo(quiet.dy, 0.5));
  });

  testWidgets('with Recent below, one line with every way in', (tester) async {
    await pumpHome(tester, network: lan, records: [record('Van Jam')]);

    expect(find.byType(JamEmptyState), findsNothing);
    expect(find.text(HomeStrings.quietLine), findsOneWidget);
    expect(find.text(HomeStrings.scan), findsOneWidget);
    expect(find.text(HomeStrings.joinWithLink), findsOneWidget);
  });

  testWidgets('a recent jam is the row Past Jams draws it with: its mark — '
      'its monogram with no cover left — name and people', (tester) async {
    await pumpHome(tester, network: lan, records: [record('Van Jam')]);

    expect(find.byType(JamHistoryRow), findsOneWidget);
    final mark = tester.widget<JamMark>(find.byType(JamMark));
    expect(mark.name, 'Van Jam');
    expect(mark.size, JamMarkSize.row);
    expect(mark.cover, isNull);
    expect(find.byIcon(CupertinoIcons.music_note), findsNothing);
    // The jam's name in Manrope, as on Past Jams.
    expect(
      tester.widget<Text>(find.text('Van Jam')).style?.fontFamily,
      'Manrope',
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

    // With nothing else on the page, the jam itself: its mark, whose it is,
    // and the host's likeliest next step. No "No Jams" over your own room,
    // and no duplicate "Open Jam" — the mini player is the way back.
    final empty = tester.widget<JamEmptyState>(find.byType(JamEmptyState));
    expect(empty.title, 'Bar Room');
    expect(empty.body, HomeStrings.hostingEnds);
    expect(find.text(HomeStrings.quietTitle), findsNothing);
    expect(find.text('Open Jam'), findsNothing);
    final mark = tester.widget<JamMark>(find.byType(JamMark));
    expect(mark.name, 'Bar Room');
    // Your own jam: no face of yours on it.
    expect(mark.hostName, isNull);
    final invite = tester
        .widgetList<JamButton>(find.byType(JamButton))
        .singleWhere((b) => b.label == HomeStrings.invite);
    expect(invite.variant, JamButtonVariant.gray);
    // You cannot host two at once, and the mini player owns the bottom: the
    // Start a Jam button is gone while the jam runs.
    expect(filledButtons(tester), isEmpty);

    await tester.tap(find.text(HomeStrings.invite));
    await tester.pumpAndSettle();
    expect(find.byType(InvitePanel), findsOneWidget);
    Navigator.of(tester.element(find.byType(InvitePanel))).pop();
    await tester.pumpAndSettle();

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
    // The row's Join turns into a turning ring while the probe runs.
    expect(find.byType(JamProgressRing), findsOneWidget);
    final join = tester.widget<JamButton>(
      find.ancestor(
        of: find.byType(JamProgressRing),
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
    await tester.pump(kJamNoticeMaxDuration);
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
