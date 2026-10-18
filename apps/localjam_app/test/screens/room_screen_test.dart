/// The room screen: routing, the dismiss gesture, and what the player
/// actually puts on screen.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/design/theme.dart';
import 'package:localjam_app/src/screens/room_screen.dart';
import 'package:localjam_app/src/state/session_controller.dart';
import 'package:localjam_app/src/widgets/avatar.dart';
import 'package:localjam_app/src/widgets/buttons.dart';
import 'package:localjam_app/src/widgets/drag_to_dismiss.dart';
import 'package:localjam_app/src/widgets/room_sheet.dart';
import 'package:localjam_app/src/widgets/transport.dart';
import 'package:localjam_client/localjam_client.dart';

import '../fixtures.dart';
import '../harness.dart';

/// Polls [condition] on the real clock (call inside `tester.runAsync`).
Future<bool> _waitFor(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  return condition();
}

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

  testWidgets('a screen reader can press the people strip: its two doors '
      'carry their tap, not just a label', (tester) async {
    // Their InkWells' taps went out with their excluded semantics: each
    // read as a button that did nothing when pressed — the same fault the
    // 2026-10-17 run found on the room sheet.
    final session = testSession();
    final router = await pumpApp(tester, session);
    await startTestHost(tester, session, 'Reader Jam');
    router.push('/room');
    await tester.pumpAndSettle();
    final handle = tester.ensureSemantics();
    await tester.pump();

    final people = tester.getSemantics(find.text('1 in the room'));
    expect(
      people,
      matchesSemantics(
        label: '${JamRoomStrings.people}, 1',
        isButton: true,
        hasTapAction: true,
      ),
    );
    expect(
      tester.getSemantics(find.text(JamRoomStrings.queued(0))),
      matchesSemantics(
        label: '${JamRoomStrings.queue}, ${JamRoomStrings.queued(0)}',
        isButton: true,
        hasTapAction: true,
      ),
    );

    // Pressed the way a screen reader presses it: the People sheet opens.
    try {
      tester.semantics.tap(find.semantics.byLabel(people.label));
      await tester.pumpAndSettle();
      expect(find.byType(RoomPanel), findsOneWidget);
    } finally {
      handle.dispose();
    }

    await leaveTestSession(tester, session);
    await tester.pumpAndSettle();
  });

  testWidgets('a room left from somewhere else does not stay up as a blank '
      'page: it goes home', (tester) async {
    // 2026-10-17 run, ending a jam with a guest in it from the People
    // sheet: the sheet was unwound while the room was still closing, so it
    // never got to send the room home — and the router's redirect only
    // guards going TO /room, not a room already pushed. The host sat on an
    // empty page.
    final session = testSession();
    final router = await pumpApp(tester, session);
    await startTestHost(tester, session, 'Gone Jam');
    router.push('/room');
    await tester.pumpAndSettle();
    expect(find.byType(RoomScreen), findsOneWidget);

    await tester.runAsync(session.leave);
    await tester.pumpAndSettle();

    expect(find.byType(RoomScreen), findsNothing);
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

  // 2026-10-17 run: an Android phone on its side showed only the tops of
  // the people strip's faces — it sat past the end of a scrolling column —
  // and, once that was pinned, a gated guest's play button was cut in half.
  group('a phone held sideways', () {
    /// Starts a room playing a track with the tallest credit block there
    /// is: title, artist and album, and somebody else's name on it.
    Future<void> hostTaggedTrack(JamSessionController session) async {
      final tracks = makeTestTracks(count: 1);
      await session.startHost(
        sessionName: 'Dapper Zebra\u2019s Jam',
        discoverable: false,
      );
      final host = session.hostEngine!;
      final file = File(tracks.single);
      final item = await JamHostServer.describeFile(
        file,
        kind: MediaKind.audio,
        mime: 'audio/wav',
        durationUs: 300000000,
        title: 'Golf Long',
        artist: 'LocalJam E2E',
        album: 'E2E Fixtures',
        addedBy: 'p_9',
      );
      host.debugServer.addMedia(item, file);
      host.setMedia(item.mediaId);
    }

    Future<void> pumpSideways(
      WidgetTester tester,
      JamSessionController session,
      Size size,
      EdgeInsets insets,
    ) async {
      tester.view.physicalSize = size * tester.view.devicePixelRatio;
      addTearDown(tester.view.resetPhysicalSize);
      resetJamCelebration();
      await tester.pumpWidget(
        JamSession(
          controller: session,
          child: MaterialApp(
            theme: jamDarkTheme(),
            home: MediaQuery(
              data: MediaQueryData(
                size: size,
                padding: insets,
                viewPadding: insets,
              ),
              child: const RoomScreen(),
            ),
          ),
        ),
      );
      // Not pumpAndSettle: a guest's room keeps a fetch or sync indicator
      // moving.
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(tester.takeException(), isNull);
    }

    /// Every [finders] entry is drawn whole between the room's bar and the
    /// bottom inset; returns the scale the player was drawn at.
    double expectAllOnScreen(
      WidgetTester tester,
      Size size,
      EdgeInsets insets,
      Map<String, Finder> finders,
    ) {
      final ceiling = insets.top + 72; // The room's own bar.
      final floor = size.height - insets.bottom;
      for (final MapEntry(key: what, value: finder) in finders.entries) {
        expect(finder, findsOneWidget, reason: what);
        final rect = tester.getRect(finder);
        expect(rect.bottom, lessThanOrEqualTo(floor), reason: '$what clipped');
        expect(rect.top, greaterThanOrEqualTo(ceiling), reason: what);
      }
      expect(
        find.descendant(
          of: find.byType(RoomScreen),
          matching: find.byType(Scrollable),
        ),
        findsNothing,
        reason: 'nothing hides below a scroll edge',
      );
      final transport = find.byType(JamTransport);
      return tester.getRect(transport).height /
          tester.getSize(transport).height;
    }

    for (final (device, size, insets) in [
      // The Pixel 9 Pro emulator as measured on the 2026-10-17 run: status
      // bar and camera cut-out, gesture bar below.
      (
        'Pixel 9 Pro',
        const Size(952, 427),
        const EdgeInsets.only(left: 52, top: 52, bottom: 24),
      ),
      (
        'a 915×412 Android',
        const Size(915, 412),
        const EdgeInsets.only(top: 48, bottom: 24),
      ),
      // iPhone: the notch and the home indicator.
      (
        'iPhone',
        const Size(844, 390),
        const EdgeInsets.only(left: 47, right: 47, bottom: 21),
      ),
    ]) {
      testWidgets('$device: the host\'s whole player and the people strip, '
          'full size', (tester) async {
        final session = testSession();
        await tester.runAsync(() => hostTaggedTrack(session));
        await pumpSideways(tester, session, size, insets);

        final scale = expectAllOnScreen(tester, size, insets, {
          'the faces': find.byType(JamAvatarStack),
          'the queue count': find.text(JamRoomStrings.queued(1)),
          'the transport': find.byType(JamTransport),
          'the timeline': find.byType(JamScrubber),
          'the title': find.text('Golf Long'),
        });
        expect(scale, 1.0, reason: 'it fits as it is');
        await tester.runAsync(session.leave);
      });
    }

    testWidgets("Pixel 9 Pro: a guest without playback control sees the "
        "transport whole, and why it is dimmed", (tester) async {
      // The tallest player there is: the gated line under the transport.
      // The guest really fetches the track (the test binding's HttpClient
      // answers everything 400).
      final previousHttp = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = previousHttp);
      final host = testSession();
      final guest = testSession(identity: 'Velvet Sloth');
      final cache = Directory.systemTemp.createTempSync('localjam_land');
      addTearDown(() => cache.deleteSync(recursive: true));
      await tester.runAsync(() async {
        await hostTaggedTrack(host);
        expect(await guest.join(host.joinUri!, mediaCacheDir: cache), isTrue);
        expect(
          await _waitFor(() {
            final engine = guest.engine;
            final id = engine?.currentItem?.mediaId;
            return engine is JamGuestEngine &&
                id != null &&
                (engine.prefetchStates.value[id]?.ready ?? false);
          }),
          isTrue,
          reason: 'the track fetched: the transport, not a download line',
        );
      });
      expect(guest.engine!.can(JamCapability.controlPlayback), isFalse);
      const size = Size(952, 427);
      const insets = EdgeInsets.only(left: 52, top: 52, bottom: 24);
      await pumpSideways(tester, guest, size, insets);

      final scale = expectAllOnScreen(tester, size, insets, {
        'the faces': find.byType(JamAvatarStack),
        'the transport': find.byType(JamTransport),
        'why it is dimmed': find.text(jamHostControlsPlayback),
        'the timeline': find.byType(JamScrubber),
        'the title': find.text('Golf Long'),
      });
      expect(scale, greaterThan(0.75), reason: 'a little smaller at most');

      await tester.runAsync(guest.leave);
      await tester.runAsync(host.leave);
    });
  });

  testWidgets('a track whose file lands while the room is paused shows its '
      'own length at once, not the one before', (tester) async {
    final session = testSession();
    final tracks = makeTestTracks(count: 1);
    await tester.runAsync(() async {
      await session.startHost(sessionName: 'Paused Jam', discoverable: false);
      final host = session.hostEngine!;
      final item = await host.addMediaFile(File(tracks.single));
      host.setMedia(item.mediaId);
    });
    await resize(tester, const Size(390, 844));
    await pumpRoom(tester, session);
    final engine = session.hostEngine!;
    int? shownUs() =>
        tester.widget<JamScrubber>(find.byType(JamScrubber)).durationUs;

    // The room is paused, so the clock never moves to redraw anything: the
    // length has to follow the load by itself — first the file the native
    // side reports as 60 s (the tags said 3 s)...
    await tester.runAsync(
      () => _waitFor(() => engine.loadedDurationUs.value == 60000000),
    );
    await tester.pump();
    expect(shownUs(), 60000000);

    // ...then the same item loaded again, now 30 s long.
    mockNativeChannels(durationUs: 30000000);
    await tester.runAsync(() async {
      await engine.sync.invalidateLoadedMedia();
      await _waitFor(() => engine.loadedDurationUs.value == 30000000);
    });
    await tester.pump();
    expect(shownUs(), 30000000);

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

  testWidgets("a guest's play held for a download tells the host why the "
      'music waits', (tester) async {
    // The server announces nothing when it holds a start (§6.3) — the room
    // just stays `loading` — so a line read off the bare getter never knew
    // about a hold a guest's play request began. And behind the "waiting
    // for N people" count it could not have shown anyway: a hold only
    // exists while somebody is mid-download.
    final session = testSession();
    final tracks = makeTestTracks(count: 1);
    final router = await pumpApp(tester, session);
    late JamHostEngine host;
    late JamGuestClient guest;
    late MediaItem item;
    await tester.runAsync(() async {
      await session.startHost(
        sessionName: 'Gate Jam',
        discoverable: false,
        policy: JamPolicy.open,
      );
      host = session.hostEngine!;
      item = await host.addMediaFile(File(tracks.single));
      guest = await JamGuestClient.connect(
        host.joinUriFor(InternetAddress.loopbackIPv4),
        clientName: 'Ana',
      );
      guest.sendMediaStatus(
        item.mediaId,
        MediaFetchState.fetching,
        progress: .3,
      );
      expect(
        await _waitFor(
          () => host
              .peerMediaStates(item.mediaId)
              .containsValue(MediaReadiness.fetching),
        ),
        isTrue,
      );
      host.setMedia(item.mediaId);
    });
    router.push('/room');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));
    expect(find.text(JamRoomStrings.waiting(1)), findsOneWidget);
    expect(find.text(JamRoomStrings.awaitingReadiness), findsNothing);

    await tester.runAsync(() async {
      await guest.requestPlay();
      expect(await _waitFor(() => host.awaitingReadiness.value), isTrue);
    });
    await tester.pump();
    expect(find.text(JamRoomStrings.awaitingReadiness), findsOneWidget);

    await tester.runAsync(() async {
      guest.sendMediaStatus(item.mediaId, MediaFetchState.ready);
      expect(await _waitFor(() => !host.awaitingReadiness.value), isTrue);
    });
    await tester.pump();
    expect(find.text(JamRoomStrings.awaitingReadiness), findsNothing);
    expect(host.snapshot.status, PlaybackStatus.playing);

    await tester.runAsync(guest.close);
    await leaveTestSession(tester, session);
    await tester.pumpAndSettle();
  });

  group('terminal states', () {
    Future<void> pumpEnded(
      WidgetTester tester,
      JamSessionEndReason? reason, {
      RejectReason? rejectReason,
      VoidCallback? onRetry,
      ThemeData? theme,
    }) => tester.pumpWidget(
      MaterialApp(
        theme: theme ?? jamLightTheme(),
        home: JamSessionEndedView(
          reason: reason,
          rejectReason: rejectReason,
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
      expect(primary.variant, JamButtonVariant.filled);
    });

    testWidgets('a rejected rejoin offers a rejoin too', (tester) async {
      await pumpEnded(tester, JamSessionEndReason.rejected);
      expect(find.text(JamRoomStrings.rejectedTitle), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    });

    testWidgets('a refusal says which, and only offers a retry that could '
        'work', (tester) async {
      // `rejected` alone said "it may have restarted" to a full room and to
      // a version mismatch alike, and offered "Try again" to both — a
      // button that could never work for a restarted room or an update.
      final cases = <RejectReason?, (String, bool)>{
        RejectReason.badToken: (JamRoomStrings.restartedTitle, false),
        RejectReason.version: (JamRoomStrings.versionTitle, false),
        RejectReason.full: (JamRoomStrings.fullTitle, true),
        RejectReason.unknown: (JamRoomStrings.rejectedTitle, true),
        null: (JamRoomStrings.rejectedTitle, true),
      };
      for (final MapEntry(key: why, value: (title, retry)) in cases.entries) {
        await pumpEnded(
          tester,
          JamSessionEndReason.rejected,
          rejectReason: why,
        );
        expect(find.text(title), findsOneWidget, reason: '$why');
        expect(
          find.text(JamRoomStrings.tryAgain),
          retry ? findsOneWidget : findsNothing,
          reason: '$why',
        );
        // Whatever the reason, there is always a way out.
        expect(find.text(JamRoomStrings.back), findsOneWidget);
      }
      expect(find.text(JamRoomStrings.versionBody), findsNothing);
      await pumpEnded(
        tester,
        JamSessionEndReason.rejected,
        rejectReason: RejectReason.version,
      );
      expect(find.text(JamRoomStrings.versionBody), findsOneWidget);
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
