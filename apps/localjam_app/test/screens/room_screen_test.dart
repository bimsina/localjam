/// The room screen: routing, the dismiss gesture, and what the player
/// actually puts on screen.
library;

import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/design/theme.dart';
import 'package:localjam_app/src/design/tokens.dart';
import 'package:localjam_app/src/screens/room_screen.dart';
import 'package:localjam_app/src/state/session_controller.dart';
import 'package:localjam_app/src/widgets/artwork.dart';
import 'package:localjam_app/src/widgets/avatar.dart';
import 'package:localjam_app/src/widgets/buttons.dart';
import 'package:localjam_app/src/widgets/drag_to_dismiss.dart';
import 'package:localjam_app/src/widgets/queue_sheet.dart';
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
    expect(find.text(JamRoomStrings.nothingPlaying), findsOneWidget);
    expect(find.text(JamRoomStrings.addSongs), findsOneWidget);
    // The footer: the people in the room, Sound Offset, Up Next.
    expect(find.byType(JamAvatarStack), findsOneWidget);
    expect(
      find.bySemanticsLabel('${JamRoomStrings.people}, 1'),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel(JamRoomStrings.soundOffset), findsOneWidget);
    expect(find.bySemanticsLabel(JamRoomStrings.queue), findsOneWidget);
    // An iOS pull-down, not a Material popup.
    expect(find.byType(PopupMenuButton<Object?>), findsNothing);
    expect(find.bySemanticsLabel(JamRoomStrings.more), findsOneWidget);
    // Quiet when correct: nothing says "in sync".
    expect(find.textContaining('sync'), findsNothing);
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

  testWidgets('a screen reader can press the footer: People and Up Next '
      'carry their tap, not just a label', (tester) async {
    // A tap that goes out with excluded semantics reads as a button that
    // does nothing when pressed — the fault the 2026-10-17 run found.
    final session = testSession();
    final router = await pumpApp(tester, session);
    await startTestHost(tester, session, 'Reader Jam');
    router.push('/room');
    await tester.pumpAndSettle();
    final handle = tester.ensureSemantics();
    await tester.pump();

    final people = tester.getSemantics(
      find.bySemanticsLabel('${JamRoomStrings.people}, 1'),
    );
    expect(
      people,
      matchesSemantics(
        label: '${JamRoomStrings.people}, 1',
        isButton: true,
        hasTapAction: true,
        hasSelectedState: true,
      ),
    );
    expect(
      tester.getSemantics(find.bySemanticsLabel(JamRoomStrings.queue)),
      matchesSemantics(
        label: JamRoomStrings.queue,
        isButton: true,
        hasTapAction: true,
        hasSelectedState: true,
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

    await tester.tap(find.bySemanticsLabel(JamRoomStrings.close));
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
      final ceiling = insets.top + 56; // The room's own header.
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
          'Up Next': find.byIcon(CupertinoIcons.list_bullet),
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
    expect(find.text(JamRoomStrings.nothingPlaying), findsOneWidget);
    expect(find.byType(JamAvatarStack), findsOneWidget);

    await leaveTestSession(tester, session);
  });

  testWidgets('ending the jam lives in the ••• menu, behind a confirmation', (
    tester,
  ) async {
    final session = testSession();
    await startTestHost(tester, session, 'Exit Jam');
    await resize(tester, const Size(390, 844));
    await pumpRoom(tester, session);

    // The chevron minimises; it never ends anything, and no red way out sits
    // on the screen itself.
    expect(find.text(JamRoomStrings.endJam), findsNothing);

    await tester.tap(find.bySemanticsLabel(JamRoomStrings.more));
    await tester.pumpAndSettle();
    for (final item in [
      JamRoomStrings.invite,
      JamRoomStrings.people,
      JamRoomStrings.menuSoundOffset,
      JamRoomStrings.diagnostics,
      JamRoomStrings.endJam,
    ]) {
      expect(find.text(item), findsOneWidget, reason: item);
    }

    await tester.tap(find.text(JamRoomStrings.endJam));
    await tester.pumpAndSettle();
    expect(find.text(JamRoomStrings.endTitle), findsOneWidget);
    await tester.tap(find.text(JamRoomStrings.cancel));
    await tester.pumpAndSettle();
    expect(session.isLive, isTrue);

    await leaveTestSession(tester, session);
  });

  testWidgets('the queue opens in place and the thumbnail brings the cover '
      'back', (tester) async {
    final session = testSession();
    await tester.runAsync(() async {
      await session.startHost(
        sessionName: 'Queue Jam',
        discoverable: false,
        paths: makeTestTracks(),
      );
      await session.hostImport!.done;
      session.hostEngine!.pause();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await resize(tester, const Size(390, 844));
    await pumpRoom(tester, session);
    expect(find.byType(QueuePanel), findsNothing);
    final cover = tester.getSize(find.byType(JamArtworkTile).first);
    expect(cover.width, greaterThan(300));

    await tester.tap(find.bySemanticsLabel(JamRoomStrings.queue));
    await tester.pumpAndSettle();
    // In place: no sheet, no new route — the list on the same page, the
    // cover shrunk to the 56 thumbnail, the transport still there.
    expect(find.byType(QueuePanel), findsOneWidget);
    expect(find.byType(DraggableScrollableSheet), findsNothing);
    expect(tester.getSize(find.byType(JamArtworkTile).first).width, 56);
    expect(find.byType(JamTransport), findsOneWidget);
    expect(find.text(QueueSheetStrings.title), findsOneWidget);

    // The thumbnail restores the big cover.
    await tester.tap(find.byType(JamArtworkTile).first);
    await tester.pumpAndSettle();
    expect(find.byType(QueuePanel), findsNothing);
    expect(tester.getSize(find.byType(JamArtworkTile).first), cover);

    await leaveTestSession(tester, session);
  });

  testWidgets('a paused cover springs back to 0.86', (tester) async {
    final session = testSession();
    await tester.runAsync(() async {
      await session.startHost(
        sessionName: 'Pause Jam',
        discoverable: false,
        paths: makeTestTracks(count: 1),
      );
      await session.hostImport!.done;
      session.hostEngine!.pause();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await resize(tester, const Size(390, 844));
    await pumpRoom(tester, session);

    final scale = tester
        .widgetList<Transform>(
          find.ancestor(
            of: find.byType(JamArtworkTile).first,
            matching: find.byType(Transform),
          ),
        )
        .map((t) => t.transform.entry(0, 0))
        .toList();
    expect(scale, contains(closeTo(0.86, 0.001)));

    await leaveTestSession(tester, session);
  });

  testWidgets('1.3× text on a small phone clips nothing, queue open or not', (
    tester,
  ) async {
    final session = testSession();
    await tester.runAsync(() async {
      await session.startHost(
        sessionName: 'A Rather Long Name For A Jam',
        discoverable: false,
        paths: makeTestTracks(),
      );
      await session.hostImport!.done;
      session.hostEngine!.pause();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    tester.view.physicalSize =
        const Size(375, 667) * tester.view.devicePixelRatio;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      JamSession(
        controller: session,
        child: MaterialApp(
          theme: jamLightTheme(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.3)),
            child: child!,
          ),
          home: const RoomScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.tap(find.bySemanticsLabel(JamRoomStrings.queue));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(QueuePanel), findsOneWidget);

    await leaveTestSession(tester, session);
  });

  testWidgets('the immersive page looks the same on either app theme', (
    tester,
  ) async {
    final session = testSession();
    await startTestHost(tester, session, 'Theme Jam');
    await resize(tester, const Size(390, 844));
    for (final theme in [jamLightTheme(), jamDarkTheme()]) {
      await pumpRoom(tester, session, theme: theme);
      expect(
        tester.widget<Text>(find.text('Theme Jam')).style!.color,
        JamNowPlayingColors.text,
      );
    }
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
      expect(find.text(JamRoomStrings.hostGoneTitle), findsOneWidget);
      expect(find.text(JamRoomStrings.tryAgain), findsOneWidget);
      expect(find.text(JamRoomStrings.back), findsOneWidget);

      final primary = tester.widget<JamButton>(
        find.ancestor(
          of: find.text(JamRoomStrings.tryAgain),
          matching: find.byType(JamButton),
        ),
      );
      expect(primary.variant, JamButtonVariant.filled);
      // §6.3: the way home is the plain one beside it.
      final back = tester.widget<JamButton>(
        find.ancestor(
          of: find.text(JamRoomStrings.back),
          matching: find.byType(JamButton),
        ),
      );
      expect(back.variant, JamButtonVariant.plain);
    });

    testWidgets('a rejected rejoin offers a rejoin too', (tester) async {
      await pumpEnded(tester, JamSessionEndReason.rejected);
      expect(find.text(JamRoomStrings.rejectedTitle), findsOneWidget);
      expect(find.text(JamRoomStrings.tryAgain), findsOneWidget);
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
      expect(find.text(JamRoomStrings.kickedTitle), findsOneWidget);
      expect(find.text(JamRoomStrings.tryAgain), findsNothing);
      expect(find.text(JamRoomStrings.back), findsOneWidget);
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
      expect(find.text(JamRoomStrings.hostEndedTitle), findsOneWidget);
      expect(find.text(JamRoomStrings.tryAgain), findsNothing);
      expect(find.text(JamRoomStrings.back), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('an end with no reason at all still has a way out', (
      tester,
    ) async {
      await pumpEnded(tester, null, onRetry: null);
      expect(find.text(JamRoomStrings.endedTitle), findsOneWidget);
      expect(find.text(JamRoomStrings.back), findsOneWidget);
    });
  });
}
