/// The session controller's failure paths, over a real host and a real guest
/// on the loopback interface.
///
/// These exercise the states that only appear when something goes wrong —
/// a session that ended while the user was elsewhere, a rejected join, a file
/// that will not add — which is exactly where the app used to go quiet or,
/// worse, lock.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/state/session_controller.dart';
import 'package:localjam_client/localjam_client.dart';

import 'harness.dart';

/// Polls [condition] on the real clock. The engines work over actual sockets,
/// so the alternative is a fixed sleep long enough to be slow and short
/// enough to be flaky.
Future<bool> waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  return condition();
}

Directory tempCache() {
  final dir = Directory.systemTemp.createTempSync('localjam_test_cache');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return dir;
}

void main() {
  testWidgets('hosting defaults to the jam preset, not to open', (
    tester,
  ) async {
    // The engine's own default, and the one the setup screen preselects:
    // guests may add music, the transport stays with the host.
    final host = testSession();
    await tester.runAsync(() async {
      await host.startHost(sessionName: 'Default Room', discoverable: false);
      expect(host.engine!.permissions.policy, JamPolicy.jam);
      expect(host.engine!.permissions.policy.addTracks, isTrue);
      expect(host.engine!.permissions.policy.controlPlayback, isFalse);
      await host.leave();
    });
  });

  testWidgets('a join that points off the network never opens a socket', (
    tester,
  ) async {
    // §9. The check used to live only on the deep-link path, so a scanned QR
    // or a pasted link could aim the app at anything routable. It lives in
    // join() now, which is the one door all four entry points share.
    final session = testSession();
    await tester.runAsync(() async {
      for (final host in [
        '8.8.8.8',
        'evil.example.com',
        '192.168.1.5,8.8.8.8',
      ]) {
        final joined = await session.join(
          Uri.parse('localjam://join?v=1&host=$host&port=44100&token=t'),
          mediaCacheDir: tempCache(),
        );
        expect(joined, isFalse, reason: host);
        expect(session.phase, JamSessionPhase.idle);
        expect(session.error, contains('outside your network'));
      }
    });
  });

  /// Three real files, so the engine has something it can register and play.
  List<String> media() => [
    for (final name in ['track1.m4a', 'track2.m4a', 'track3.m4a'])
      '../../test-media/$name',
  ];

  testWidgets('starting a jam with a queue starts the music', (tester) async {
    // "Start the jam" landed in a room paused at 00:00 holding a full
    // queue — one tap to sound cost two taps and a hunt for the transport.
    // "Host it again" comes down this same path with the old queue.
    final host = testSession();
    await tester.runAsync(() async {
      final started = await host.startHost(
        sessionName: 'One Tap',
        discoverable: false,
        paths: media(),
      );
      expect(started, isTrue);
      expect(host.engine!.playlist, hasLength(3));
      // Cued *and* running: the first track is selected and the transport is
      // playing, not idle and not paused.
      expect(
        host.engine!.snapshot.mediaId,
        host.engine!.playlist.first.mediaId,
      );
      expect(host.engine!.snapshot.status, PlaybackStatus.playing);
      await host.leave();
    });
  });

  testWidgets('a jam started with nothing queued stays silent', (tester) async {
    // Nothing to play is not a reason to enter a "playing" state with no
    // media: the room would claim to be running with an empty transport.
    final host = testSession();
    await tester.runAsync(() async {
      await host.startHost(sessionName: 'Empty Room', discoverable: false);
      expect(host.engine!.playlist, isEmpty);
      expect(host.engine!.snapshot.status, isNot(PlaybackStatus.playing));
      await host.leave();
    });
  });

  testWidgets('a removed track can be put back where it was', (tester) async {
    // Queue Undo. No engine has a re-insert API, so this re-adds the file the
    // host registered the item from — same bytes, so the same content-hashed
    // mediaId — and moves it back to its old index.
    final host = testSession();
    await tester.runAsync(() async {
      await host.startHost(
        sessionName: 'Undo Room',
        discoverable: false,
        paths: media(),
      );
      final ids = [for (final i in host.engine!.playlist) i.mediaId];
      expect(ids, hasLength(3));

      expect(host.canReinsert(ids[1]), isTrue);
      host.hostEngine!.removeMediaItem(ids[1]);
      expect(await waitFor(() => host.engine!.playlist.length == 2), isTrue);
      // The path outlives the item it belonged to; that is the whole trick.
      expect(host.canReinsert(ids[1]), isTrue);

      expect(await host.reinsertItem(ids[1], 1), isTrue);
      expect(await waitFor(() => host.engine!.playlist.length == 3), isTrue);
      expect([for (final i in host.engine!.playlist) i.mediaId], ids);

      // Idempotent: an undo that races the removal it undoes is a no-op.
      expect(await host.reinsertItem(ids[1], 1), isTrue);
      expect(host.engine!.playlist, hasLength(3));

      await host.leave();
    });
  });

  testWidgets('an unknown track cannot be reinserted, and says so', (
    tester,
  ) async {
    final host = testSession();
    await tester.runAsync(() async {
      await host.startHost(sessionName: 'Undo Room 2', discoverable: false);
      expect(host.canReinsert('nothing-like-this'), isFalse);
      expect(await host.reinsertItem('nothing-like-this', 0), isFalse);
      await host.leave();
    });
  });

  testWidgets('a guest is never offered an undo it cannot honour', (
    tester,
  ) async {
    // A guest would have to re-upload and then ask the host to move it, and
    // either half can be refused — an undo that might half-happen is worse
    // than no undo.
    final host = testSession();
    final guest = testSession();
    final cache = tempCache();
    await tester.runAsync(() async {
      await host.startHost(
        sessionName: 'Guest Undo',
        discoverable: false,
        paths: media(),
      );
      expect(await guest.join(host.joinUri!, mediaCacheDir: cache), isTrue);
      expect(await waitFor(() => guest.engine!.playlist.isNotEmpty), isTrue);
      final id = guest.engine!.playlist.first.mediaId;

      expect(guest.canReinsert(id), isFalse);
      expect(await guest.reinsertItem(id, 0), isFalse);

      await guest.leave();
      await host.leave();
    });
  });

  testWidgets('a keep-alive that goes takes a notice with it', (tester) async {
    // Android can revoke the foreground service under a backgrounded app,
    // and a host in that state loses the room the moment the screen locks.
    final host = testSession();
    // Unset inside the body, not in a tearDown: the framework checks the
    // foundation debug flags before tearDowns run.
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await tester.runAsync(() async {
        final notices = <String>[];
        final sub = host.notices.listen((n) => notices.add(n.message));
        addTearDown(sub.cancel);

        await host.startHost(sessionName: 'Pocket Jam', discoverable: false);
        // Held: nothing to say. The warning is about the transition, not
        // about a keep-alive that was never granted in the first place.
        JamKeepAlive.active.value = true;
        await pumpEventQueue();
        expect(notices, isNot(contains(kJamKeepAliveLost)));

        JamKeepAlive.active.value = false;
        await pumpEventQueue();
        expect(notices, contains(kJamKeepAliveLost));

        await host.leave();
      });
    } finally {
      debugDefaultTargetPlatformOverride = null;
      JamKeepAlive.active.value = false;
    }
  });

  testWidgets('an ended session does not lock the app out of a new one', (
    tester,
  ) async {
    // The P0: a guest kicked while looking at Home reached the terminal
    // `ended` phase, and startHost/join then early-returned false forever.
    final host = testSession();
    final guest = testSession();
    final cache = tempCache();

    await tester.runAsync(() async {
      await host.startHost(sessionName: 'Kick Room', discoverable: false);
      final joined = await guest.join(host.joinUri!, mediaCacheDir: cache);
      expect(joined, isTrue);
      expect(await waitFor(() => host.engine!.peers.isNotEmpty), isTrue);

      host.hostEngine!.kickPeer(host.engine!.peers.first.peerId);
      expect(
        await waitFor(() => guest.phase == JamSessionPhase.ended),
        isTrue,
        reason: 'the kick should end the guest session',
      );
      expect(guest.endReason, JamSessionEndReason.kicked);

      // The terminal state stays reachable from wherever the user is.
      expect(guest.hasRoom, isTrue);

      // ...and the next join clears it instead of refusing.
      final again = await guest.join(host.joinUri!, mediaCacheDir: cache);
      expect(again, isTrue, reason: 'a new join must auto-acknowledge the end');
      expect(guest.phase, JamSessionPhase.live);

      await guest.leave();
      await host.leave();
    });
  });

  testWidgets('a terminal end can be rejoined with the retained link', (
    tester,
  ) async {
    final host = testSession();
    final guest = testSession();
    final cache = tempCache();

    await tester.runAsync(() async {
      await host.startHost(sessionName: 'Rejoin Room', discoverable: false);
      await guest.join(host.joinUri!, mediaCacheDir: cache);
      expect(guest.lastJoinUri, host.joinUri);
      expect(await waitFor(() => host.engine!.peers.isNotEmpty), isTrue);

      host.hostEngine!.kickPeer(host.engine!.peers.first.peerId);
      expect(await waitFor(() => guest.phase == JamSessionPhase.ended), isTrue);

      // The URI survives the engine being torn down — that is what makes
      // "Try again" possible at all.
      expect(guest.lastJoinUri, isNotNull);
      expect(await guest.rejoin(mediaCacheDir: cache), isTrue);
      expect(guest.isLive, isTrue);

      await guest.leave();
      await host.leave();
    });
  });

  testWidgets('a host hears people arrive and leave', (tester) async {
    final host = testSession();
    final guest = testSession();
    final cache = tempCache();

    await tester.runAsync(() async {
      final heard = <String>[];
      final sub = host.notices.listen((n) => heard.add(n.message));
      addTearDown(sub.cancel);

      await host.startHost(sessionName: 'Notice Room', discoverable: false);
      await guest.join(host.joinUri!, clientName: 'Ana', mediaCacheDir: cache);
      expect(await waitFor(() => heard.any((m) => m.contains('joined'))), true);
      expect(heard, contains('Ana joined'));

      await guest.leave();
      expect(await waitFor(() => heard.contains('Ana left')), isTrue);

      await host.leave();
    });
  });

  testWidgets('a join in flight is visible, and one at a time', (tester) async {
    final host = testSession();
    final guest = testSession();
    final cache = tempCache();

    await tester.runAsync(() async {
      await host.startHost(sessionName: 'Slow Room', discoverable: false);

      final joining = guest.join(
        host.joinUri!,
        roomName: 'Slow Room',
        mediaCacheDir: cache,
      );
      // The handshake plus the clock burst is long enough that a tap with no
      // feedback reads as a dead row.
      expect(guest.isBusy, isTrue);
      expect(guest.joiningUri, host.joinUri);
      expect(guest.joiningName, 'Slow Room');
      // A second tap while the first is in flight must not start a second
      // handshake.
      expect(await guest.join(host.joinUri!, mediaCacheDir: cache), isFalse);

      expect(await joining, isTrue);
      expect(guest.joiningUri, isNull);
      expect(guest.isBusy, isFalse);

      await guest.leave();
      await host.leave();
    });
  });

  testWidgets('unreadable files are reported, not swallowed', (tester) async {
    final host = testSession();

    await tester.runAsync(() async {
      final heard = <String>[];
      final sub = host.notices.listen((n) => heard.add(n.message));
      addTearDown(sub.cancel);

      // The host still comes up: one bad file must not sink the session.
      final started = await host.startHost(
        sessionName: 'Broken Files',
        discoverable: false,
        paths: [
          '${Directory.systemTemp.path}/localjam_missing_one.mp3',
          '${Directory.systemTemp.path}/localjam_missing_two.mp3',
        ],
      );
      expect(started, isTrue);
      // Broadcast notices land a microtask later.
      await Future<void>.delayed(Duration.zero);
      expect(host.addFailures, hasLength(2));
      expect(host.addFailures.first.name, 'localjam_missing_one.mp3');
      expect(
        heard.single,
        "2 files couldn't be added: localjam_missing_one.mp3, "
        'localjam_missing_two.mp3',
      );

      await host.leave();
    });
  });

  test('failure copy names files and counts, never stack traces', () {
    expect(
      describeAddFailures([const JamAddFailure('a.mp3', 'boom')]),
      'Could not add a.mp3',
    );
    expect(
      describeAddFailures([
        const JamAddFailure('a.mp3', 'boom'),
        const JamAddFailure('b.mp3', 'boom'),
        const JamAddFailure('c.mp3', 'boom'),
        const JamAddFailure('d.mp3', 'boom'),
        const JamAddFailure('e.mp3', 'boom'),
      ]),
      "5 files couldn't be added: a.mp3, b.mp3, c.mp3 and 2 more",
    );
  });

  testWidgets('an end that arrives off the room screen is still visible', (
    tester,
  ) async {
    // The visible half of the soft lock: the docked bar used to disappear the
    // moment the phase went terminal, so a guest sitting on Home had a dead
    // session with nothing on screen to acknowledge it.
    final host = testSession();
    final guest = testSession();
    final cache = tempCache();
    final router = await pumpApp(tester, guest);

    await tester.runAsync(() async {
      await host.startHost(sessionName: 'Bar Room', discoverable: false);
      await guest.join(host.joinUri!, mediaCacheDir: cache);
      await waitFor(() => host.engine!.peers.isNotEmpty);
      host.hostEngine!.kickPeer(host.engine!.peers.first.peerId);
      await waitFor(() => guest.phase == JamSessionPhase.ended);
    });
    await tester.pump();

    // We never left home, and the bar is still there saying so.
    expect(find.text('This jam ended'), findsOneWidget);

    await tester.tap(find.text('This jam ended'));
    await tester.pumpAndSettle();
    // ...and it lands on the screen that explains it, with a way back in.
    expect(find.text('You were removed'), findsOneWidget);
    expect(find.text('Back to nearby'), findsOneWidget);

    await tester.tap(find.text('Back to nearby'));
    await tester.pump();
    // Dismissing closes a real engine, which only unwinds on the real clock.
    await tester.runAsync(
      () => waitFor(
        () => guest.phase == JamSessionPhase.idle,
        timeout: const Duration(seconds: 3),
      ),
    );
    await tester.pumpAndSettle();
    expect(guest.phase, JamSessionPhase.idle);
    expect(find.text('Nearby'), findsOneWidget);
    expect(router.state.matchedLocation, '/');
    expect(find.text('This jam ended'), findsNothing);

    await tester.runAsync(host.leave);

    // Landing back on home restarts the nearby browse, and a browse owns a
    // periodic sweep timer for as long as the app is idle — correct in the
    // app, a pending timer at the end of a test. Stopped here (and not
    // pumped after, or home's `didChangeDependencies` starts another) rather
    // than by relaxing the assertions above, which are what this test is for.
    await tester.runAsync(guest.stopBrowsing);
  });

  testWidgets('the room you are in is never a room you can join', (
    tester,
  ) async {
    // A host's own daemon answers its own browse, and so does a guest's host.
    // The filter used to live in the home screen, where it only ran while
    // `isLive` was already true — which is a race with every start.
    final host = testSession();
    final guest = testSession();
    final cache = tempCache();

    await tester.runAsync(() async {
      expect(host.excludedToken, isNull);

      await host.startHost(sessionName: 'Own Room', discoverable: false);
      final token = host.joinUri!.queryParameters['token'];
      expect(token, isNotNull);
      expect(host.excludedToken, token, reason: 'a host cannot join itself');

      expect(await guest.join(host.joinUri!, mediaCacheDir: cache), isTrue);
      expect(guest.excludedToken, token, reason: 'nor can its guest');

      await guest.leave();
      expect(guest.excludedToken, isNull, reason: 'out is joinable again');
      await host.leave();
      expect(host.excludedToken, isNull);
    });
  });

  testWidgets('a browse started with a session running carries the filter', (
    tester,
  ) async {
    final host = testSession();
    await tester.runAsync(() async {
      await host.startHost(sessionName: 'Own Room', discoverable: false);
      // The browse is normally stopped for the life of a session; this is
      // the race it used to lose — a screen rebuilding behind a permission
      // dialog restarting discovery while the start was still in flight.
      final browser = JamRoomBrowser.withSources(
        events: const Stream<Never>.empty(),
      );
      await host.startBrowsing(browser: browser);
      expect(host.browser, isNull, reason: 'a live jam keeps the radio down');
      // ...and the browse that comes back on the way out inherits it.
      await host.leave();
      await host.stopBrowsing();
      await browser.stop();
    });
  });

  testWidgets('adding bytes the room already has says so', (tester) async {
    // Media ids are content hashes, so re-adding the same file is a no-op the
    // protocol answers with the item it already had (§6.4) — indistinguishable
    // from a silent failure to whoever just picked it.
    final host = testSession();
    final heard = <String>[];
    await tester.runAsync(() async {
      await host.startHost(
        sessionName: 'Dup Room',
        discoverable: false,
        paths: [media().first],
      );
      expect(host.engine!.playlist, hasLength(1));

      final sub = host.notices.listen((n) => heard.add(n.message));
      addTearDown(sub.cancel);

      final failures = await host.addFiles([File(media().first)]);
      expect(failures, isEmpty, reason: 'nothing failed — nothing changed');
      expect(host.engine!.playlist, hasLength(1));
      // Broadcast notices land a microtask later.
      await Future<void>.delayed(Duration.zero);
      expect(heard, contains(kJamAlreadyQueued));

      await host.leave();
    });
  });

  testWidgets('leaving a room brings nearby discovery back', (tester) async {
    // The P1: joining or hosting stops the mDNS browse and nothing ever
    // started it again, so every jam after the first opened onto a nearby
    // list that could never fill.
    final host = testSession();
    final guest = testSession();
    final cache = tempCache();

    await tester.runAsync(() async {
      await guest.startBrowsing();
      expect(guest.discovering, isTrue);

      await host.startHost(sessionName: 'Browse Room', discoverable: false);
      expect(await guest.join(host.joinUri!, mediaCacheDir: cache), isTrue);
      expect(
        guest.discovering,
        isFalse,
        reason: 'a live jam must not keep the radio up',
      );

      await guest.leave();
      expect(
        guest.discovering,
        isTrue,
        reason: 'back on idle is back to looking around',
      );

      // The same holds for the host side's stop.
      await host.startBrowsing();
      await host.startHost(sessionName: 'Browse Room 2', discoverable: false);
      expect(host.discovering, isFalse);
      await host.leave();
      expect(host.discovering, isTrue);

      // An explicit stop is not undone by the next session ending.
      await host.stopBrowsing();
      await host.startHost(sessionName: 'Quiet Room', discoverable: false);
      await host.leave();
      expect(host.discovering, isFalse);
    });
  });

  testWidgets('a kick closes the sheet sitting over the room', (tester) async {
    // A guest kicked with the queue sheet open kept a live-looking queue on
    // top of a dead session, hiding the screen that explains what happened.
    final host = testSession();
    final guest = testSession();
    final cache = tempCache();
    await pumpApp(tester, guest);

    await tester.runAsync(() async {
      await host.startHost(sessionName: 'Sheet Room', discoverable: false);
      await guest.join(host.joinUri!, mediaCacheDir: cache);
      await waitFor(() => host.engine!.peers.isNotEmpty);
    });
    await tester.pumpAndSettle();

    final navigator = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    unawaited(
      showModalBottomSheet<void>(
        context: navigator.context,
        builder: (context) => const Text('Queue sheet'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Queue sheet'), findsOneWidget);

    await tester.runAsync(() async {
      host.hostEngine!.kickPeer(host.engine!.peers.first.peerId);
      await waitFor(() => guest.phase == JamSessionPhase.ended);
    });
    await tester.pumpAndSettle();

    expect(
      find.text('Queue sheet'),
      findsNothing,
      reason: 'the sheet must not outlive the session under it',
    );

    await tester.runAsync(host.leave);
  });

  testWidgets('a guest hears the host say no', (tester) async {
    // JamGuestEngine.errors had no subscriber anywhere in the app, so a
    // request the host refused (§8 not_allowed) was a button that did
    // nothing at all.
    final host = testSession();
    final guest = testSession();
    final cache = tempCache();

    await tester.runAsync(() async {
      final heard = <String>[];
      final sub = guest.notices.listen((n) => heard.add(n.message));
      addTearDown(sub.cancel);

      await host.startHost(
        sessionName: 'Listen Only',
        policy: JamPolicy.listenOnly,
        discoverable: false,
      );
      await guest.join(host.joinUri!, mediaCacheDir: cache);
      expect(guest.engine!.can(JamCapability.controlPlayback), isFalse);

      await guest.guestEngine!.requestPlay();
      expect(
        await waitFor(() => heard.isNotEmpty),
        isTrue,
        reason: 'a refused request must reach the user',
      );
      expect(heard.first, 'The host has not given you that yet.');

      await guest.leave();
      await host.leave();
    });
  });
}
