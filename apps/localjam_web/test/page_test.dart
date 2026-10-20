/// The listener page's states against a faked room (docs/design/
/// WEB_GUEST.md "Web page behaviour"): landing, joining, the joined room
/// and its sync copy for every §3 state, controls only with
/// `control_playback` (§5.6), songs this browser cannot play, the nudge and
/// mute, and the ended and rejected screens — copy, never a spinner.
library;

import 'dart:async';

import 'package:flutter/cupertino.dart' show CupertinoActivityIndicator;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_client/localjam_client.dart';
import 'package:localjam_web/src/join_target.dart';
import 'package:localjam_web/src/listener_app.dart';
import 'package:localjam_web/src/room.dart';
import 'package:localjam_web/src/room_page.dart';

import 'fake_room.dart';

final Uri pageUrl = Uri.parse(
  'http://192.168.1.7:44100/join#v=1&token=t0k3n&name=Road+Trip'
  '&host=192.168.1.7,192.168.43.1',
);

/// Pumps the page joined (on tap) to [room], or failing with [joinError].
class Harness {
  Harness({this.room, this.joinError, Uri? url})
    : target = JoinTarget.fromPageUrl(url ?? pageUrl);

  final FakeRoom? room;
  final Object? joinError;
  final JoinTarget target;
  final List<String> events = [];
  final List<Uri> opened = [];
  Completer<void>? holdJoin;

  Widget build() => ListenerApp(
    target: target,
    joiner: (joinUri, name) async {
      events.add('join $joinUri as $name');
      await holdJoin?.future;
      final error = joinError;
      if (error != null) throw error;
      return room!;
    },
    defaultName: () async => 'Neon Walrus',
    saveName: (name) async => events.add('save $name'),
    unlockAudio: () => events.add('unlock'),
    openUrl: opened.add,
  );
}

Future<void> pumpPage(WidgetTester tester, Harness h) async {
  tester.view.physicalSize = const Size(390 * 3, 1800 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(h.build());
  await tester.pump();
}

Future<void> listen(WidgetTester tester) async {
  await tester.ensureVisible(find.text('Tap to Listen'));
  await tester.pump();
  await tester.tap(find.text('Tap to Listen'));
  await tester.pump();
  await tester.pump();
}

/// Ends the test cleanly: unmounts the room page and its ticker.
Future<void> unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
}

void main() {
  group('JoinTarget', () {
    test('joins its own origin with the fragment\'s token and keeps every '
        'candidate for Open in App', () {
      final t = JoinTarget.fromPageUrl(pageUrl);
      expect(t.canJoin, isTrue);
      expect(t.jamName, 'Road Trip');
      expect(t.link!.hosts, ['192.168.1.7']);
      expect(t.link!.port, 44100);
      expect(t.link!.token, 't0k3n');
      expect(
        t.joinUri.toString(),
        startsWith('http://192.168.1.7:44100/join#'),
      );
      final app = JoinLink.fromUri(t.appLink!)!;
      expect(t.appLink!.scheme, 'localjam');
      expect(app.hosts, ['192.168.1.7', '192.168.43.1']);
      expect(app.port, 44100);
      expect(app.token, 't0k3n');
    });

    test('a page served at / reads the same fragment; the origin wins over '
        'a fragment that names other hosts', () {
      final t = JoinTarget.fromPageUrl(
        Uri.parse('http://10.0.0.2:5000/#v=1&token=abc&host=10.0.0.9'),
      );
      expect(t.link!.hosts, ['10.0.0.2']);
      expect(t.link!.port, 5000);
    });

    test('startup remembers the invitation and drops it from the address; a '
        'reload without it reads the remembered one', () {
      final opened = InviteStartup.resolve(pageUrl, null);
      expect(opened.page, pageUrl);
      expect(opened.remember, pageUrl.fragment);
      expect(
        opened.cleanAddress.toString(),
        'http://192.168.1.7:44100/join',
        reason: 'same path, no token',
      );

      final reloaded = InviteStartup.resolve(
        opened.cleanAddress!,
        opened.remember,
      );
      expect(reloaded.remember, isNull);
      expect(reloaded.cleanAddress, isNull);
      final target = JoinTarget.fromPageUrl(reloaded.page);
      expect(target.link!.token, 't0k3n');
      expect(target.jamName, 'Road Trip');
      expect(JoinLink.fromUri(target.appLink!)!.hosts, [
        '192.168.1.7',
        '192.168.43.1',
      ], reason: 'Open in App keeps every candidate after a reload');

      // A new link in the same tab replaces the remembered one.
      final other = Uri.parse('http://192.168.1.7:44100/join#v=1&token=n3w');
      final replaced = InviteStartup.resolve(other, opened.remember);
      expect(replaced.remember, other.fragment);
      expect(JoinTarget.fromPageUrl(replaced.page).link!.token, 'n3w');

      // A fragment that is no invitation is read as it is, never mixed
      // with a remembered one; nothing remembered is nothing to join.
      final junk = Uri.parse('http://192.168.1.7:44100/join#v=1&name=x');
      final kept = InviteStartup.resolve(junk, opened.remember);
      expect(kept.page, junk);
      expect(kept.cleanAddress, isNull);
      expect(
        JoinTarget.fromPageUrl(
          InviteStartup.resolve(opened.cleanAddress!, null).page,
        ).canJoin,
        isFalse,
      );
    });

    test('no token, or not http, is no invitation', () {
      for (final url in [
        'http://192.168.1.7:44100/join',
        'http://192.168.1.7:44100/join#v=1&name=x',
        'https://192.168.1.7/join#token=t',
        'file:///join#token=t',
      ]) {
        expect(
          JoinTarget.fromPageUrl(Uri.parse(url)).canJoin,
          isFalse,
          reason: url,
        );
      }
    });
  });

  testWidgets('landing: brand, the jam from the link, a generated name and '
      'one button; the tap unlocks audio before joining', (tester) async {
    final h = Harness(room: FakeRoom());
    h.holdJoin = Completer<void>();
    await pumpPage(tester, h);
    expect(find.text('LocalJam'), findsOneWidget);
    expect(find.text('Road Trip'), findsOneWidget);
    expect(find.text('Tap to Listen'), findsOneWidget);
    expect(find.text('Open in App'), findsOneWidget);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, 'Neon Walrus');

    await tester.enterText(find.byType(TextField), '  Bibek ');
    await listen(tester);
    expect(h.events.first, 'unlock', reason: 'inside the gesture');
    expect(h.events, contains('save Bibek'));
    expect(
      h.events.firstWhere((e) => e.startsWith('join')),
      'join http://192.168.1.7:44100/join#v=1&token=t0k3n&name=Road+Trip as '
      'Bibek',
    );
    // Joining: the button spins, nothing else to do.
    expect(find.byType(CupertinoActivityIndicator), findsOneWidget);
    h.holdJoin!.complete();
    await tester.pump();
    await tester.pump();
    expect(find.text('Playing in sync'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('Open in App opens the localjam:// link with every candidate', (
    tester,
  ) async {
    final h = Harness(room: FakeRoom());
    await pumpPage(tester, h);
    await tester.tap(find.text('Open in App'));
    expect(h.opened.single.scheme, 'localjam');
    expect(h.opened.single.queryParameters['host'], '192.168.1.7,192.168.43.1');
  });

  testWidgets('a link without an invitation says so, with nothing to tap', (
    tester,
  ) async {
    final h = Harness(url: Uri.parse('http://192.168.1.7:44100/join'));
    await pumpPage(tester, h);
    expect(find.text('No Invite in This Link'), findsOneWidget);
    expect(find.text('Tap to Listen'), findsNothing);
  });

  testWidgets('joined and synced: cover, title, artist, the sync line, '
      "who's here named after welcome.host", (tester) async {
    final h = Harness(room: FakeRoom());
    await pumpPage(tester, h);
    await listen(tester);
    expect(find.text('Road Trip'), findsOneWidget);
    expect(find.text('Hosted by Silky Puffin'), findsOneWidget);
    expect(find.text('Night Drive'), findsWidgets);
    expect(find.text('Kai'), findsOneWidget);
    expect(find.text('Playing in sync'), findsOneWidget);
    expect(find.text('0:42'), findsOneWidget);
    // Who's here: the host by name, you, the others.
    expect(find.text('Silky Puffin'), findsOneWidget);
    expect(find.text('Host'), findsOneWidget);
    expect(find.text('Neon Walrus'), findsOneWidget);
    expect(find.text('You'), findsOneWidget);
    expect(find.text('Mia'), findsOneWidget);
    expect(find.text('Keep this page open', findRichText: true), findsNothing);
    expect(find.textContaining('Keep this page open'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('a host that shares no name is "Host"', (tester) async {
    final room = FakeRoom()..hostPeer = null;
    await pumpPage(tester, Harness(room: room));
    await listen(tester);
    expect(find.text('Hosted by Host'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('controls are hidden without control_playback (§5.6)', (
    tester,
  ) async {
    final room = FakeRoom(
      queue: [
        track('m_a', title: 'One'),
        track('m_b', title: 'Two'),
      ],
      prefetch: {'m_a': readyState, 'm_b': readyState},
    );
    await pumpPage(tester, Harness(room: room));
    await listen(tester);
    expect(find.bySemanticsLabel('Pause'), findsNothing);
    expect(find.bySemanticsLabel('Next'), findsNothing);
    expect(find.bySemanticsLabel('Previous'), findsNothing);
    await tester.tap(find.text('Two'));
    await tester.pump();
    expect(room.calls, isNot(contains('select m_b')));
    await unmount(tester);
  });

  testWidgets('…and shown with it: play/pause, skip and tap-to-select send '
      'requests', (tester) async {
    final room = FakeRoom(
      canControl: true,
      queue: [
        track('m_a', title: 'One'),
        track('m_b', title: 'Two'),
      ],
      prefetch: {'m_a': readyState, 'm_b': readyState},
    );
    await pumpPage(tester, Harness(room: room));
    await listen(tester);
    await tester.tap(find.bySemanticsLabel('Pause'));
    await tester.tap(find.bySemanticsLabel('Next'));
    await tester.tap(find.bySemanticsLabel('Previous'));
    await tester.tap(find.text('Two'));
    await tester.pump();
    expect(room.calls, ['pause', 'next', 'previous', 'select m_b']);

    // A permissions change mid-jam takes them away again.
    room
      ..canControl = false
      ..changed();
    await tester.pump();
    expect(find.bySemanticsLabel('Next'), findsNothing);
    await unmount(tester);
  });

  testWidgets('a song this browser cannot decode is marked in the queue and '
      'said plainly when it is the current one', (tester) async {
    final room = FakeRoom(
      queue: [
        track('m_a', title: 'Ogg Song'),
        track('m_b', title: 'Fine'),
      ],
      prefetch: {
        'm_a': const JamPrefetchState(phase: JamPrefetchPhase.unplayable),
        'm_b': readyState,
      },
    );
    await pumpPage(tester, Harness(room: room));
    await listen(tester);
    expect(find.text("Can't play in this browser"), findsOneWidget);
    expect(find.text("Can't play this song in this browser"), findsOneWidget);
    // The next song is fine, and the room is not blocked by this one.
    room
      ..snapshot = const PlaybackSnapshot(
        rev: 4,
        status: PlaybackStatus.playing,
        mediaId: 'm_b',
        anchor: PlaybackAnchor(hostTimeUs: 0, positionUs: 0),
      )
      ..changed();
    await tester.pump();
    expect(find.text('Playing in sync'), findsOneWidget);
    expect(find.text("Can't play in this browser"), findsOneWidget);
    await unmount(tester);
  });

  group('the sync line says every §3 state', () {
    Future<void> expectLine(
      WidgetTester tester,
      void Function(FakeRoom room) setUp,
      String line,
    ) async {
      final room = FakeRoom();
      setUp(room);
      await pumpPage(tester, Harness(room: room));
      await listen(tester);
      expect(find.text(line), findsOneWidget, reason: line);
      expect(find.byType(CupertinoActivityIndicator), findsNothing);
      await unmount(tester);
    }

    testWidgets('fetching, with progress', (tester) async {
      await expectLine(
        tester,
        (r) => r.prefetch = {
          'm_a': const JamPrefetchState(
            phase: JamPrefetchPhase.fetching,
            progress: 0.42,
          ),
        },
        'Getting this song… 42%',
      );
    });

    testWidgets('waiting for the host', (tester) async {
      await expectLine(
        tester,
        (r) => r.snapshot = const PlaybackSnapshot(
          rev: 1,
          status: PlaybackStatus.loading,
          mediaId: 'm_a',
        ),
        'Waiting for the host to play',
      );
      await expectLine(
        tester,
        (r) => r.snapshot = const PlaybackSnapshot(
          rev: 1,
          status: PlaybackStatus.paused,
          mediaId: 'm_a',
        ),
        'Paused by the host',
      );
      await expectLine(
        tester,
        (r) => r
          ..queue = []
          ..snapshot = PlaybackSnapshot.initial,
        'Waiting for the host to add music',
      );
    });

    testWidgets("the host's phone is asleep (§3.5)", (tester) async {
      await expectLine(
        tester,
        (r) => r
          ..hostAway = true
          ..connection = JamConnectionState.reconnecting,
        "The host's phone is asleep",
      );
    });

    testWidgets('reconnecting (§3.3)', (tester) async {
      await expectLine(
        tester,
        (r) => r.connection = JamConnectionState.reconnecting,
        'Reconnecting…',
      );
    });

    testWidgets('syncing (§4)', (tester) async {
      await expectLine(
        tester,
        (r) => r.clockSynced = false,
        'Syncing with the room…',
      );
    });

    testWidgets('the browser held the sound: one tap resumes it', (
      tester,
    ) async {
      final room = FakeRoom()
        ..outputSuspension = const JamOutputSuspension(
          JamOutputSuspendReason.interruption,
        );
      await pumpPage(tester, Harness(room: room));
      await listen(tester);
      expect(find.text('Sound paused on this page'), findsOneWidget);
      await tester.tap(find.text('Tap to Resume'));
      expect(room.calls, ['resume']);
      await unmount(tester);
    });
  });

  testWidgets('the sync nudge moves in 10 ms steps within ±500 ms, and mute '
      'toggles this page only', (tester) async {
    final room = FakeRoom();
    await pumpPage(tester, Harness(room: room));
    await listen(tester);
    expect(find.text('0 ms'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Earlier'));
    await tester.pump();
    expect(find.text('10 ms earlier'), findsOneWidget, reason: 'shown at once');
    expect(room.calls, isEmpty, reason: 'sent once the taps settle');
    await tester.pump(RoomPage.nudgeTapSettle);
    expect(room.calls.last, 'nudge 10000');
    expect(find.text('10 ms earlier'), findsOneWidget);
    room
      ..nudgeUs = -500000
      ..changed();
    await tester.pump();
    expect(find.text('500 ms later'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Later'));
    await tester.pump(RoomPage.nudgeTapSettle);
    expect(room.calls.last, 'nudge 10000', reason: 'at the bound: disabled');
    await tester.tap(find.text('Reset'));
    expect(room.calls.last, 'nudge 0', reason: 'a reset is sent at once');
    await tester.pump();

    await tester.tap(find.bySemanticsLabel('Mute'));
    await tester.pump();
    expect(room.calls.last, 'muted true');
    expect(find.bySemanticsLabel('Unmute'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('a run of nudge taps re-anchors once, and a slider drag at '
      'most a few times a second plus where it ends', (tester) async {
    final room = FakeRoom();
    await pumpPage(tester, Harness(room: room));
    await listen(tester);
    final earlier = find.bySemanticsLabel('Earlier');
    await tester.ensureVisible(earlier);
    for (var i = 0; i < 5; i++) {
      await tester.tap(earlier);
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('50 ms earlier'), findsOneWidget);
    expect(room.calls, isEmpty);
    await tester.pump(RoomPage.nudgeTapSettle);
    expect(room.calls, ['nudge 50000']);

    room.calls.clear();
    final slider = find.byType(Slider);
    await tester.ensureVisible(slider);
    await tester.pump();
    final gesture = await tester.startGesture(tester.getCenter(slider));
    // 30 moves over 1.5 s: each one is a new value on screen.
    for (var i = 0; i < 30; i++) {
      await gesture.moveBy(const Offset(3, 0));
      await tester.pump(const Duration(milliseconds: 50));
    }
    final live = room.calls.where((c) => c.endsWith('(live)')).length;
    expect(live, inInclusiveRange(1, 6), reason: '${room.calls}');
    await gesture.up();
    await tester.pump();
    expect(room.calls.last, isNot(endsWith('(live)')), reason: 'stored');
    expect(room.calls.where((c) => !c.endsWith('(live)')), hasLength(1));
    await tester.pump(RoomPage.nudgeTapSettle);
    await unmount(tester);
  });

  testWidgets('buttons expose a tap action that assistive tech can press', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final room = FakeRoom();
    final h = Harness(room: room);
    await pumpPage(tester, h);
    final listenButton = find.bySemanticsLabel('Tap to Listen');
    expect(
      tester
          .getSemantics(listenButton)
          .getSemanticsData()
          .hasAction(SemanticsAction.tap),
      isTrue,
    );
    tester.semantics.tap(find.semantics.byLabel('Tap to Listen'));
    await tester.pump();
    await tester.pump();
    expect(h.events.first, 'unlock');
    expect(find.byType(RoomPage), findsOneWidget);

    final mute = find.bySemanticsLabel('Mute');
    expect(
      tester
          .getSemantics(mute)
          .getSemanticsData()
          .hasAction(SemanticsAction.tap),
      isTrue,
    );
    tester.semantics.tap(find.semantics.byLabel('Mute'));
    await tester.pump();
    expect(room.calls.last, 'muted true');
    await unmount(tester);
    semantics.dispose();
  });

  testWidgets('a double tap on Tap to Listen starts one join', (tester) async {
    final h = Harness(room: FakeRoom())..holdJoin = Completer<void>();
    await pumpPage(tester, h);
    // An empty name: the join first asks for the generated one (an await).
    await tester.enterText(find.byType(TextField), '');
    await tester.ensureVisible(find.text('Tap to Listen'));
    await tester.pump();
    await tester.tap(find.text('Tap to Listen'));
    await tester.tap(find.text('Tap to Listen'));
    await tester.pump();
    await tester.pump();
    expect(h.events.where((e) => e == 'unlock'), hasLength(1));
    expect(h.events.where((e) => e.startsWith('join')), hasLength(1));
    h.holdJoin!.complete();
    await tester.pump();
    await unmount(tester);
  });

  testWidgets('the sync line is announced when its state changes, not at '
      'every percent', (tester) async {
    final semantics = tester.ensureSemantics();
    final room = FakeRoom(
      prefetch: {
        'm_a': const JamPrefetchState(
          phase: JamPrefetchPhase.fetching,
          progress: 0.42,
        ),
      },
    );
    await pumpPage(tester, Harness(room: room));
    await listen(tester);
    final line = find.bySemanticsLabel('Getting this song…');
    final data = tester.getSemantics(line).getSemanticsData();
    expect(data.flagsCollection.isLiveRegion, isTrue);
    room
      ..prefetch = {
        'm_a': const JamPrefetchState(
          phase: JamPrefetchPhase.fetching,
          progress: 0.43,
        ),
      }
      ..changed();
    await tester.pump();
    expect(find.text('Getting this song… 43%'), findsOneWidget);
    expect(tester.getSemantics(line).label, 'Getting this song…');
    await unmount(tester);
    semantics.dispose();
  });

  testWidgets('a failed song says "trying again" only while it is, then '
      'offers Try Again', (tester) async {
    final room = FakeRoom(
      prefetch: {
        'm_a': const JamPrefetchState(
          phase: JamPrefetchPhase.failed,
          failures: 2,
          willRetry: true,
        ),
      },
    );
    await pumpPage(tester, Harness(room: room));
    await listen(tester);
    expect(find.text("Couldn't get this song. Trying again…"), findsOneWidget);
    expect(find.text('Try Again'), findsNothing);
    room
      ..prefetch = {
        'm_a': const JamPrefetchState(
          phase: JamPrefetchPhase.failed,
          failures: 6,
        ),
      }
      ..changed();
    await tester.pump();
    expect(find.text("Couldn't get this song"), findsOneWidget);
    await tester.tap(find.text('Try Again'));
    expect(room.calls, ['retry m_a']);
    await unmount(tester);
  });

  testWidgets('a song too long or too big for a browser says which', (
    tester,
  ) async {
    final room = FakeRoom(
      queue: [
        track('m_a', title: 'Two-Hour Mix'),
        track('m_b', title: 'Huge'),
      ],
      prefetch: {
        'm_a': const JamPrefetchState(
          phase: JamPrefetchPhase.unplayable,
          error: JamMediaStore.tooLong,
        ),
        'm_b': const JamPrefetchState(
          phase: JamPrefetchPhase.unplayable,
          error: JamMediaStore.tooLarge,
        ),
      },
    );
    await pumpPage(tester, Harness(room: room));
    await listen(tester);
    expect(
      find.text('This song is too long to play in a browser'),
      findsOneWidget,
    );
    expect(find.text('Too long to play in a browser'), findsOneWidget);
    expect(find.text('Too big to play in a browser'), findsOneWidget);
    await unmount(tester);
  });

  group('ended (§3.4, §5.6): copy, never a spinner', () {
    Future<void> expectEnded(
      WidgetTester tester,
      JamSessionEndReason reason,
      String title, {
      bool tryAgain = false,
      RejectReason? reject,
    }) async {
      final room = FakeRoom();
      await pumpPage(tester, Harness(room: room));
      await listen(tester);
      room
        ..endReason = reason
        ..rejectReason = reject
        ..changed();
      await tester.pump();
      expect(find.text(title), findsOneWidget, reason: '$reason');
      expect(find.byType(CupertinoActivityIndicator), findsNothing);
      expect(find.text('Try Again'), tryAgain ? findsOneWidget : findsNothing);
      expect(find.byType(RoomPage), findsNothing);
      await unmount(tester);
    }

    testWidgets('the host ended the jam', (tester) async {
      await expectEnded(
        tester,
        JamSessionEndReason.hostEnded,
        'The Jam Has Ended',
      );
    });

    testWidgets('a reason that is not the host ending it never says so', (
      tester,
    ) async {
      await expectEnded(
        tester,
        JamSessionEndReason.listenerFailed,
        'Listening Stopped',
      );
      expect(
        find.text('The host ended the jam. Thanks for listening.'),
        findsNothing,
      );
    });

    testWidgets('the host disappeared: worth another try', (tester) async {
      await expectEnded(
        tester,
        JamSessionEndReason.hostGone,
        'The Host Disappeared',
        tryAgain: true,
      );
    });

    testWidgets('removed by the host', (tester) async {
      await expectEnded(tester, JamSessionEndReason.kicked, 'You Were Removed');
    });

    testWidgets('a reconnect refused (the room restarted)', (tester) async {
      await expectEnded(
        tester,
        JamSessionEndReason.rejected,
        'This Jam Has Ended',
        reject: RejectReason.badToken,
      );
    });
  });

  group('rejected joins (§3.1): final, said plainly', () {
    Future<void> expectRejected(
      WidgetTester tester,
      RejectReason reason,
      String title, {
      bool tryAgain = false,
    }) async {
      final h = Harness(joinError: JamRejectedException(reason));
      await pumpPage(tester, h);
      await listen(tester);
      expect(find.text(title), findsOneWidget, reason: reason.wire);
      expect(find.byType(CupertinoActivityIndicator), findsNothing);
      expect(find.text('Try Again'), tryAgain ? findsOneWidget : findsNothing);
      await unmount(tester);
    }

    testWidgets('bad token', (tester) async {
      await expectRejected(tester, RejectReason.badToken, 'This Jam Has Ended');
    });

    testWidgets('full: the one reason worth another try', (tester) async {
      await expectRejected(
        tester,
        RejectReason.full,
        'This Jam Is Full',
        tryAgain: true,
      );
    });

    testWidgets('version', (tester) async {
      await expectRejected(tester, RejectReason.version, "Can't Join This Jam");
    });

    testWidgets('kicked', (tester) async {
      await expectRejected(tester, RejectReason.kicked, 'You Were Removed');
    });

    testWidgets('a reason from a later version', (tester) async {
      await expectRejected(tester, RejectReason.unknown, "Couldn't Join");
    });
  });

  testWidgets('an unreachable host offers Try Again, which joins again', (
    tester,
  ) async {
    final h = Harness(joinError: TimeoutException('no host'));
    await pumpPage(tester, h);
    await listen(tester);
    expect(find.text("Couldn't Reach the Jam"), findsOneWidget);
    await tester.tap(find.text('Try Again'));
    await tester.pump();
    expect(h.events.where((e) => e == 'unlock'), hasLength(2));
    expect(h.events.where((e) => e.startsWith('join')), hasLength(2));
  });

  testWidgets('the room survives the largest text sizes and a laptop width', (
    tester,
  ) async {
    final room = FakeRoom(
      canControl: true,
      queue: [
        for (var i = 0; i < 6; i++)
          track(
            'm_$i',
            title: 'A rather long song title number $i that wraps',
            artist: 'Somebody With A Long Name',
          ),
      ],
      prefetch: {'m_0': readyState},
      snapshot: const PlaybackSnapshot(
        rev: 1,
        status: PlaybackStatus.playing,
        mediaId: 'm_0',
        anchor: PlaybackAnchor(hostTimeUs: 0, positionUs: 0),
      ),
    );
    for (final (size, scale) in [
      (const Size(320, 640), 2.0),
      (const Size(1440, 900), 1.0),
    ]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final h = Harness(room: room);
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(
            size: size,
            textScaler: TextScaler.linear(scale),
          ),
          child: h.build(),
        ),
      );
      await tester.pump();
      await listen(tester);
      expect(tester.takeException(), isNull, reason: '$size × $scale');
      expect(find.byType(RoomPage), findsOneWidget);
      await unmount(tester);
    }
  });

  test('RoomStatus.isProblem is false only when all is well or waiting', () {
    final room = FakeRoom();
    expect(RoomStatus.of(room).isProblem, isFalse);
    room.connection = JamConnectionState.reconnecting;
    expect(RoomStatus.of(room).isProblem, isTrue);
  });
}
