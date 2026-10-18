/// The engine states the hardened core can now report, and what the app does
/// with each: a phone whose own sound stopped, a host that went to sleep, a
/// host whose room stopped listening, a track a guest could not get, a
/// "Try again" that failed, a tap that could not reach anybody.
///
/// Real engines over loopback wherever the state can be produced for real;
/// the copy and the classification are pinned directly.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/design/theme.dart';
import 'package:localjam_app/src/screens/host_setup_screen.dart';
import 'package:localjam_app/src/screens/room_screen.dart';
import 'package:localjam_app/src/state/session_controller.dart';
import 'package:localjam_app/src/widgets/buttons.dart';
import 'package:localjam_app/src/widgets/nudge_slider.dart';
import 'package:localjam_app/src/widgets/room_banner.dart';
import 'package:localjam_app/src/widgets/session_gate.dart';
import 'package:localjam_app/src/widgets/sync_indicator.dart';
import 'package:localjam_app/src/widgets/transport.dart';
import 'package:localjam_client/localjam_client.dart';

import 'fixtures.dart';
import 'harness.dart';

Future<bool> _waitFor(
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

Directory _tempCache() {
  final dir = Directory.systemTemp.createTempSync('localjam_states_test');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return dir;
}

/// Makes every backgrounded host announce itself away (§3.5), as an iOS host
/// that is not producing sound does.
void _hostsSleepWhenBackgrounded() {
  final previous = JamHostEngine.backgroundSuspendPolicy;
  JamHostEngine.backgroundSuspendPolicy = (_) => true;
  addTearDown(() => JamHostEngine.backgroundSuspendPolicy = previous);
}

/// A native audio event, as the platform side would send it.
Future<void> _nativeEvent(WidgetTester tester, Map<String, Object?> event) =>
    tester.runAsync(() async {
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            'localjam_audio/events',
            const StandardMethodCodec().encodeSuccessEnvelope(event),
            (_) {},
          );
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });

/// [text] on the room screen itself — home (and its docked bar) stays
/// rendered under the room, which is not opaque.
Finder inRoom(String text) =>
    find.descendant(of: find.byType(RoomScreen), matching: find.text(text));

/// Lets real-zone work (sockets, engine streams) run, then paints it.
Future<void> _settleReal(WidgetTester tester, [int ms = 50]) async {
  await tester.runAsync(() => Future<void>.delayed(Duration(milliseconds: ms)));
  await tester.pump();
}

/// Ends [sessions] and takes the app down without leaving a nearby-rooms
/// sweep behind: home restarts discovery the moment nothing is live, and a
/// browse started from the test's fake zone is a periodic timer the test
/// would otherwise finish holding.
Future<void> _endApp(
  WidgetTester tester,
  List<JamSessionController> sessions,
) async {
  await tester.pumpWidget(const SizedBox.shrink());
  for (final session in sessions) {
    await tester.runAsync(() async {
      await session.leave();
      await session.stopBrowsing();
    });
  }
}

void main() {
  group('copy', () {
    test('every suspension reason has its own words', () {
      String copy(JamOutputSuspendReason reason, {bool retry = false}) =>
          jamOutputSuspensionCopy(
            JamOutputSuspension(reason, willRetry: retry),
          );
      expect(copy(JamOutputSuspendReason.interruption), 'Paused for a call');
      expect(copy(JamOutputSuspendReason.focusLost), 'Another app is playing');
      expect(
        copy(JamOutputSuspendReason.outputLost),
        'Headphones disconnected',
      );
      expect(copy(JamOutputSuspendReason.playbackError), 'Playback error');
      expect(
        copy(JamOutputSuspendReason.playbackError, retry: true),
        contains('Retrying'),
      );
    });

    test('a fetch only "fails" once the engine stops retrying', () {
      expect(jamTrackFetchOf(null), JamTrackFetch.ready);
      expect(
        jamTrackFetchOf(
          const JamPrefetchState(phase: JamPrefetchPhase.ready, path: '/x'),
        ),
        JamTrackFetch.ready,
      );
      expect(
        jamTrackFetchOf(
          const JamPrefetchState(phase: JamPrefetchPhase.fetching),
        ),
        JamTrackFetch.fetching,
      );
      // A failure with a retry on the way is still "getting this track".
      expect(
        jamTrackFetchOf(
          const JamPrefetchState(
            phase: JamPrefetchPhase.failed,
            failures: 1,
            willRetry: true,
          ),
        ),
        JamTrackFetch.fetching,
      );
      expect(
        jamTrackFetchOf(
          const JamPrefetchState(phase: JamPrefetchPhase.failed, failures: 6),
        ),
        JamTrackFetch.failed,
      );
    });

    test('an upload the host refused says what to do about it', () {
      JamAddFailure refused(int status) => JamAddFailure.of(
        '/music/a.mp3',
        JamHttpStatusException(status, 'HTTP $status'),
      );
      expect(refused(507).why, contains('upload space is full'));
      expect(refused(429).why, contains('other uploads'));
      expect(refused(403).why, contains('listen-only'));
      expect(refused(413).why, contains('too big'));
      expect(refused(401).why, contains('no longer valid'));
      // A stall, a cut-off body, a socket error: "could not add", nothing
      // that sends people to rejoin a room that is fine.
      expect(
        JamAddFailure.of('/a.mp3', const SocketException('reset')).why,
        isNull,
      );
      expect(
        JamAddFailure.of('/a.mp3', const HttpException('closed')).why,
        isNull,
      );
      expect(
        JamAddFailure.of('/a.mp3', TimeoutException('stalled')).why,
        isNull,
      );

      expect(
        describeAddFailures([refused(507)]),
        'Could not add a.mp3. The room’s upload space is full.',
      );
      // Mixed reasons stay at the names; nothing raw either way.
      final mixed = describeAddFailures([
        refused(507),
        JamAddFailure.of('/b.mp3', const SocketException('reset')),
      ]);
      expect(mixed, "2 files couldn't be added: a.mp3, b.mp3");
      expect(mixed, isNot(contains('Exception')));
    });
  });

  group('host asleep', () {
    testWidgets('a tap that cannot reach a sleeping host says why', (
      tester,
    ) async {
      _hostsSleepWhenBackgrounded();
      final host = testSession();
      final guest = testSession(identity: 'Ana');
      final cache = _tempCache();
      final heard = <String>[];
      final sub = guest.notices.listen((n) => heard.add(n.message));
      addTearDown(sub.cancel);

      await tester.runAsync(() async {
        await host.startHost(
          sessionName: 'Nap Room',
          policy: JamPolicy.open,
          discoverable: false,
        );
        expect(await guest.join(host.joinUri!, mediaCacheDir: cache), isTrue);
        expect(guest.canSendCommands, isTrue);

        var notified = 0;
        guest.addListener(() => notified++);
        await host.hostEngine!.handleLifecycleState(AppLifecycleState.paused);
        expect(await _waitFor(() => guest.hostAway), isTrue);
        // A lifecycle fact: everything that disables controls rebuilds.
        expect(notified, greaterThan(0));
        expect(guest.canSendCommands, isFalse);

        // The intent answers false without sending — and the user hears why.
        expect(await guest.act((e) => e.transportPlay()), isFalse);
        await Future<void>.delayed(Duration.zero);
        expect(heard, contains(kJamHostAsleepTryLater));

        // An add is refused before a byte is read, once, with the reason.
        heard.clear();
        final failures = await guest.addFiles(makeTestTracks().map(File.new));
        await Future<void>.delayed(Duration.zero);
        expect(failures, isEmpty);
        expect(heard, [kJamHostAsleepTryLater]);

        await host.hostEngine!.handleLifecycleState(AppLifecycleState.resumed);
        expect(await _waitFor(() => !guest.hostAway), isTrue);
        expect(guest.canSendCommands, isTrue);
        expect(await guest.act((e) => e.transportPause()), isTrue);

        await guest.leave();
        await host.leave();
      });
    });

    testWidgets('the room says the host is asleep, not "reconnecting"', (
      tester,
    ) async {
      _hostsSleepWhenBackgrounded();
      final host = testSession();
      final guest = testSession(identity: 'Ana');
      final cache = _tempCache();
      await tester.runAsync(() async {
        await host.startHost(
          sessionName: 'Nap Room',
          policy: JamPolicy.open,
          discoverable: false,
          // A queue: an empty one would dim the transport on its own, and
          // the test would prove nothing about the host being asleep.
          paths: makeTestTracks(),
        );
        await host.hostImport!.done;
        host.hostEngine!.pause();
        expect(await guest.join(host.joinUri!, mediaCacheDir: cache), isTrue);
        expect(
          await _waitFor(() => guest.engine!.playlist.length == 3),
          isTrue,
        );
      });
      final router = await pumpApp(tester, guest);
      router.push('/room');
      // One frame for the push to land, then let the room settle.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 800));
      expect(
        tester.widget<JamTransport>(find.byType(JamTransport)).enabled,
        isTrue,
        reason: 'awake host, queue, open room: the transport is live',
      );

      await tester.runAsync(() async {
        await host.hostEngine!.handleLifecycleState(AppLifecycleState.paused);
        expect(await _waitFor(() => guest.hostAway), isTrue);
      });
      await tester.pump();

      // One calm line under the room's name — not a banner, and not
      // "Reconnecting…".
      expect(inRoom(JamSyncStrings.hostAsleep), findsOneWidget);
      expect(inRoom(JamSyncStrings.reconnecting), findsNothing);
      // The room lets this guest play and skip — but nobody is listening on
      // the other end, so the controls are held, with the reason under them.
      final transport = tester.widget<JamTransport>(find.byType(JamTransport));
      expect(transport.enabled, isFalse);
      expect(find.text(JamRoomStrings.waitForHost), findsOneWidget);

      await tester.runAsync(() async {
        await host.hostEngine!.handleLifecycleState(AppLifecycleState.resumed);
        expect(await _waitFor(() => !guest.hostAway), isTrue);
      });
      await tester.pump();
      expect(inRoom(JamSyncStrings.hostAsleep), findsNothing);

      await _endApp(tester, [guest, host]);
    });
  });

  group('this phone’s sound', () {
    testWidgets('a suspended output offers "Resume Audio" until it clears', (
      tester,
    ) async {
      final session = testSession();
      final router = await pumpApp(tester, session);
      await startTestHost(tester, session, 'Call Jam');
      router.push('/room');
      await tester.pumpAndSettle();
      expect(find.text(JamRoomBannerStrings.resume), findsNothing);

      // Another app took the audio and is not giving it back.
      await _nativeEvent(tester, {
        'type': 'interruptionBegan',
        'shouldResume': false,
      });
      await tester.pump();
      expect(inRoom(JamRoomBannerStrings.focusLost), findsOneWidget);
      expect(inRoom(JamRoomBannerStrings.resume), findsOneWidget);

      // ...and on the docked bar, where the user usually is.
      router.pop();
      await tester.pumpAndSettle();
      expect(find.byType(RoomScreen), findsNothing);
      expect(find.text(JamRoomBannerStrings.focusLost), findsOneWidget);
      expect(
        find.bySemanticsLabel(JamRoomBannerStrings.resume),
        findsOneWidget,
      );

      router.push('/room');
      await tester.pumpAndSettle();
      await tester.tap(inRoom(JamRoomBannerStrings.resume));
      await _settleReal(tester);
      expect(session.engine!.outputSuspension.value, isNull);
      expect(find.text(JamRoomBannerStrings.focusLost), findsNothing);
      expect(find.text(JamRoomBannerStrings.resume), findsNothing);

      // A call ends by itself, with the OS's resume hint: the banner goes
      // without anyone touching it.
      await _nativeEvent(tester, {'type': 'interruptionBegan'});
      await tester.pump();
      expect(inRoom(JamRoomBannerStrings.interruption), findsOneWidget);
      await _nativeEvent(tester, {
        'type': 'interruptionEnded',
        'shouldResume': true,
      });
      await tester.pump();
      expect(find.text(JamRoomBannerStrings.interruption), findsNothing);

      await _endApp(tester, [session]);
    });
  });

  group('this phone’s sound, on the play buttons', () {
    testWidgets('while suspended it is "Resume audio" — and resumes this '
        'phone, never pausing the room', (tester) async {
      final session = testSession();
      final router = await pumpApp(tester, session);
      await tester.runAsync(() async {
        await session.startHost(
          sessionName: 'Call Jam',
          discoverable: false,
          paths: makeTestTracks(),
        );
        await session.hostImport!.done;
      });
      expect(session.engine!.snapshot.status, PlaybackStatus.playing);
      router.push('/room');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 800));
      JamTransport transport() => tester.widget<JamTransport>(
        find.descendant(
          of: find.byType(RoomScreen),
          matching: find.byType(JamTransport),
        ),
      );
      expect(transport().state, JamPlaybackState.playing);

      // Another app took the audio: the room plays on, this phone is silent.
      await _nativeEvent(tester, {
        'type': 'interruptionBegan',
        'shouldResume': false,
      });
      await tester.pump();
      expect(session.engine!.outputSuspension.value, isNotNull);
      expect(transport().state, JamPlaybackState.paused);
      expect(transport().enabled, isTrue);
      expect(transport().playLabel, JamRoomBannerStrings.resume);
      expect(
        find.descendant(
          of: find.byType(RoomScreen),
          matching: find.bySemanticsLabel(JamRoomBannerStrings.resume),
        ),
        findsWidgets,
      );

      transport().onPlayPause();
      await _settleReal(tester);
      expect(
        session.engine!.snapshot.status,
        PlaybackStatus.playing,
        reason: 'the room was not paused for everyone',
      );
      expect(session.engine!.outputSuspension.value, isNull);
      expect(transport().state, JamPlaybackState.playing);

      await _endApp(tester, [session]);
    });

    testWidgets('a guest\'s big button turns into "Resume audio" the moment '
        'its sound is suspended, with nothing else in the room changing', (
      tester,
    ) async {
      // A host repaints on its own state broadcasts; a guest's suspension
      // changes nothing the room sends, so the screen must follow it.
      final host = testSession();
      final guest = testSession(identity: 'Ana');
      final cache = _tempCache();
      await tester.runAsync(() async {
        await host.startHost(
          sessionName: 'Call Jam',
          policy: JamPolicy.open,
          discoverable: false,
          paths: makeTestTracks(),
        );
        await host.hostImport!.done;
        // Held, so no state broadcast repaints the room under the test
        // (three-second fixtures would otherwise advance it).
        host.hostEngine!.pause();
        // The guest joins last, so the native event channel is its player's.
        expect(await guest.join(host.joinUri!, mediaCacheDir: cache), isTrue);
        expect(
          await _waitFor(
            () =>
                guest.engine!.snapshot.status == PlaybackStatus.paused &&
                guest.engine!.playlist.length == 3,
          ),
          isTrue,
        );
        // Let the guest's prefetch settle too.
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      final router = await pumpApp(tester, guest);
      router.push('/room');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 800));
      JamTransport transport() => tester.widget<JamTransport>(
        find.descendant(
          of: find.byType(RoomScreen),
          matching: find.byType(JamTransport),
        ),
      );
      expect(transport().playLabel, isNull);

      await _nativeEvent(tester, {
        'type': 'interruptionBegan',
        'shouldResume': false,
      });
      expect(guest.engine!.outputSuspension.value, isNotNull);
      await tester.pump();
      expect(transport().playLabel, JamRoomBannerStrings.resume);
      expect(transport().enabled, isTrue);

      await _endApp(tester, [guest, host]);
    });

    testWidgets('on the docked bar it resumes this phone, never pausing the '
        'room', (tester) async {
      final session = testSession();
      await pumpApp(tester, session);
      await tester.runAsync(() async {
        await session.startHost(
          sessionName: 'Call Jam',
          discoverable: false,
          paths: makeTestTracks(),
        );
        await session.hostImport!.done;
      });
      await tester.pump();
      expect(session.engine!.snapshot.status, PlaybackStatus.playing);
      await _nativeEvent(tester, {
        'type': 'interruptionBegan',
        'shouldResume': false,
      });
      await tester.pump();
      expect(find.text(JamRoomBannerStrings.focusLost), findsOneWidget);

      await tester.tap(find.bySemanticsLabel(JamRoomBannerStrings.resume));
      await _settleReal(tester);
      expect(session.engine!.outputSuspension.value, isNull);
      expect(
        session.engine!.snapshot.status,
        PlaybackStatus.playing,
        reason: 'the room was not paused for everyone',
      );
      await tester.pump();
      expect(find.text(JamRoomBannerStrings.focusLost), findsNothing);

      await _endApp(tester, [session]);
    });
  });

  group('a track a guest could not get', () {
    testWidgets('says so, offers Retry, and keeps the transport', (
      tester,
    ) async {
      final host = testSession();
      final guest = testSession(identity: 'Ana');
      final cache = _tempCache();
      final tracks = makeTestTracks();
      late String current;
      await tester.runAsync(() async {
        await host.startHost(
          sessionName: 'Gone Files',
          policy: JamPolicy.open,
          discoverable: false,
          paths: tracks,
        );
        await host.hostImport!.done;
        // Held on the first track: three-second fixtures would otherwise
        // advance the room under the test.
        host.hostEngine!.pause();
        current = host.engine!.snapshot.mediaId!;
        // The host's copies vanish (an SD card pulled, a cloud file evicted)
        // so the guest's fetch fails — and, with no retries left, gives up.
        for (final path in tracks) {
          File(path).deleteSync();
        }
        expect(
          await guest.join(
            host.joinUri!,
            mediaCacheDir: cache,
            maxFetchRetries: 0,
          ),
          isTrue,
        );
        final states = guest.guestEngine!.prefetchStates;
        expect(
          await _waitFor(
            () =>
                jamTrackFetchOf(states.value[current]) == JamTrackFetch.failed,
          ),
          isTrue,
          reason: 'the fetch should fail for good',
        );
      });

      final router = await pumpApp(tester, guest);
      router.push('/room');
      // One frame for the push to land, then let the room settle.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 800));

      expect(find.text(JamRoomStrings.fetchFailed), findsOneWidget);
      expect(find.text(JamRoomStrings.retry), findsOneWidget);
      // Heard on its own, "Retry" would not say what it retries.
      expect(find.bySemanticsLabel(JamRoomStrings.retryFetch), findsOneWidget);
      expect(find.textContaining('Getting this song'), findsNothing);
      // Anyone the room lets skip keeps the skip button: a track that will
      // not come down is exactly when someone wants "next".
      expect(find.byType(JamTransport), findsOneWidget);
      expect(
        tester.widget<JamTransport>(find.byType(JamTransport)).enabled,
        isTrue,
      );

      // A listen-only guest keeps the dimmed transport (gated, never hidden)
      // and the failure keeps its Try Again.
      await tester.runAsync(() async {
        host.hostEngine!.setPolicy(JamPolicy.listenOnly);
        expect(
          await _waitFor(
            () => !guest.engine!.can(JamCapability.controlPlayback),
          ),
          isTrue,
        );
      });
      await tester.pump();
      expect(
        tester.widget<JamTransport>(find.byType(JamTransport)).enabled,
        isFalse,
      );
      expect(find.text(JamRoomStrings.fetchFailed), findsOneWidget);
      expect(find.text(JamRoomStrings.retry), findsOneWidget);

      // Try Again goes back to "Getting this song…" at once...
      final states = guest.guestEngine!.prefetchStates;
      await tester.tap(find.text(JamRoomStrings.retry));
      await tester.pump();
      expect(find.text(JamRoomStrings.fetchFailed), findsNothing);
      expect(find.textContaining('Getting this song'), findsOneWidget);
      // ...and a retry that fails again comes back to Retry, rather than
      // sitting on a percentage that will never move.
      for (var i = 0; i < 80; i++) {
        if (jamTrackFetchOf(states.value[current]) == JamTrackFetch.failed) {
          break;
        }
        await _settleReal(tester, 25);
      }
      await tester.pump();
      expect(find.text(JamRoomStrings.fetchFailed), findsOneWidget);

      await _endApp(tester, [guest, host]);
    });
  });

  group('session end', () {
    testWidgets(
      'a host whose room stops listening gets an end, and a restart',
      (tester) async {
        // The OS reclaimed the listening socket while the app was away and the
        // port could not be bound again. Only guests used to be watched for an
        // end, so this host kept showing a QR nobody could use.
        final prober = JamHostEngine.listenerProber;
        final restarter = JamHostEngine.listenerRestarter;
        JamHostEngine.listenerProber = (_) async => false;
        JamHostEngine.listenerRestarter = (_) async =>
            throw const SocketException('address in use');
        addTearDown(() {
          JamHostEngine.listenerProber = prober;
          JamHostEngine.listenerRestarter = restarter;
        });

        final host = testSession();
        final tracks = makeTestTracks();
        await tester.runAsync(() async {
          await host.startHost(
            sessionName: 'Pocket Jam',
            discoverable: false,
            paths: tracks,
          );
          await host.hostImport!.done;
          final engine = host.hostEngine!;
          await engine.handleLifecycleState(AppLifecycleState.paused);
          await engine.handleLifecycleState(AppLifecycleState.resumed);
          expect(
            await _waitFor(() => host.phase == JamSessionPhase.ended),
            isTrue,
          );
        });
        expect(host.endReason, JamSessionEndReason.listenerFailed);
        expect(host.hasRoom, isTrue);
        // "Start a new jam" reopens setup on the same room, queue and all.
        expect(host.restartArgs?.name, 'Pocket Jam');
        expect(host.restartArgs?.paths, unorderedEquals(tracks));

        await tester.pumpWidget(
          MaterialApp(
            theme: jamLightTheme(),
            home: JamSessionEndedView(
              reason: host.endReason,
              onDone: () {},
              onRetry: () {},
              onStartNew: () {},
            ),
          ),
        );
        expect(find.text(JamRoomStrings.listenerFailedTitle), findsOneWidget);
        expect(find.text(JamRoomStrings.tryAgain), findsNothing);
        final primary = tester.widget<JamButton>(
          find.ancestor(
            of: find.text(JamRoomStrings.startNew),
            matching: find.byType(JamButton),
          ),
        );
        expect(primary.variant, JamButtonVariant.filled);
        expect(find.text(JamRoomStrings.back), findsOneWidget);

        await tester.runAsync(host.acknowledgeEnd);
        expect(host.phase, JamSessionPhase.idle);
        expect(host.restartArgs, isNull);
      },
    );

    testWidgets('"Start a new jam" opens host setup on the old room — its '
        'queue, and the rest of what was picked', (tester) async {
      final prober = JamHostEngine.listenerProber;
      final restarter = JamHostEngine.listenerRestarter;
      JamHostEngine.listenerProber = (_) async => false;
      JamHostEngine.listenerRestarter = (_) async =>
          throw const SocketException('address in use');
      addTearDown(() {
        JamHostEngine.listenerProber = prober;
        JamHostEngine.listenerRestarter = restarter;
      });
      final host = testSession();
      final tracks = makeTestTracks();
      // Picked, but never made it into the queue (here: it will not add;
      // just as well an import the room died in the middle of).
      final unimported = '${File(tracks.first).parent.path}/later.wav';
      final router = await pumpApp(tester, host);
      await tester.runAsync(() async {
        await host.startHost(
          sessionName: 'Pocket Jam',
          discoverable: false,
          paths: [...tracks, unimported],
        );
        await host.hostImport!.done;
        // Taken out of the queue on purpose: it stays out.
        final second = host.engine!.playlist[1];
        expect(await host.act((e) => e.queueRemove(second.mediaId)), isTrue);
      });
      router.push('/room');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 800));
      await tester.runAsync(() async {
        final engine = host.hostEngine!;
        await engine.handleLifecycleState(AppLifecycleState.paused);
        await engine.handleLifecycleState(AppLifecycleState.resumed);
        expect(
          await _waitFor(() => host.phase == JamSessionPhase.ended),
          isTrue,
        );
      });
      await tester.pump();
      final expected = [tracks[0], tracks[2], unimported];
      expect(host.restartArgs?.paths, expected);

      await tester.tap(find.text(JamRoomStrings.startNew));
      for (var i = 0; i < 10; i++) {
        await _settleReal(tester, 30);
      }
      await tester.pumpAndSettle();
      final setup = tester.widget<HostSetupScreen>(
        find.byType(HostSetupScreen),
      );
      expect(setup.initialName, 'Pocket Jam');
      expect(setup.initialPaths, expected);

      await _endApp(tester, [host]);
    });

    testWidgets('host setup opens on the draft the router lost', (
      tester,
    ) async {
      // A route's `extra` is in-memory state; the controller's draft is what
      // a rebuild without it falls back to.
      final session = testSession();
      final router = await pumpApp(tester, session);
      session.hostSetupDraft = (name: 'Old Jam', paths: makeTestTracks());
      router.push('/host'); // No extra.
      await tester.pumpAndSettle();
      final setup = tester.widget<HostSetupScreen>(
        find.byType(HostSetupScreen),
      );
      expect(setup.initialName, 'Old Jam');
      expect(setup.initialPaths, session.hostSetupDraft!.paths);
      await _endApp(tester, [session]);
    });

    testWidgets('a failed "Try again" lands back on the ended room', (
      tester,
    ) async {
      final host = testSession();
      final guest = testSession(identity: 'Ana');
      final cache = _tempCache();
      await tester.runAsync(() async {
        await host.startHost(sessionName: 'Short Jam', discoverable: false);
        expect(await guest.join(host.joinUri!, mediaCacheDir: cache), isTrue);
      });
      final router = await pumpApp(tester, guest);
      router.push('/room');
      // One frame for the push to land, then let the room settle.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 800));

      await tester.runAsync(() async {
        await host.leave();
        expect(
          await _waitFor(() => guest.phase == JamSessionPhase.ended),
          isTrue,
        );
      });
      await tester.pump();
      expect(find.text(JamRoomStrings.hostEndedTitle), findsOneWidget);

      // The rejoin passes through `starting`. The room used to vanish for
      // that moment — the router's redirect unmounted it and the user landed
      // on home with a snackbar.
      final hadRoom = <bool>[];
      void record() => hadRoom.add(guest.hasRoom);
      guest.addListener(record);
      addTearDown(() => guest.removeListener(record));
      late bool rejoined;
      await tester.runAsync(() async {
        rejoined = await guest.rejoin(mediaCacheDir: cache);
      });
      await tester.pump();

      expect(rejoined, isFalse);
      expect(hadRoom, isNotEmpty);
      expect(hadRoom, everyElement(isTrue));
      expect(guest.phase, JamSessionPhase.ended);
      expect(guest.endReason, JamSessionEndReason.hostEnded);
      expect(guest.rejoining, isFalse);
      expect(
        find.byType(RoomScreen),
        findsOneWidget,
        reason: 'the ended room stays on screen',
      );
      expect(find.text(JamRoomStrings.hostEndedTitle), findsOneWidget);
      // ...saying why the retry failed, in place.
      expect(find.text(guest.error!), findsOneWidget);

      await _endApp(tester, [guest, host]);
    });

    testWidgets('a retry in flight spins in place and cannot be left', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: jamLightTheme(),
          home: JamSessionEndedView(
            reason: JamSessionEndReason.hostGone,
            retrying: true,
            onDone: null,
            onRetry: () {},
          ),
        ),
      );
      final retry = tester.widget<JamButton>(
        find.ancestor(
          of: find.text(JamRoomStrings.tryAgain),
          matching: find.byType(JamButton),
        ),
      );
      expect(retry.loading, isTrue);
      final back = tester.widget<JamButton>(
        find.ancestor(
          of: find.text(JamRoomStrings.back),
          matching: find.byType(JamButton),
        ),
      );
      expect(back.onPressed, isNull);
    });
  });

  group('one jam at a time', () {
    testWidgets('a new session asks before ending the live one', (
      tester,
    ) async {
      final session = testSession();
      await startTestHost(tester, session, 'Van Jam');
      late BuildContext context;
      await tester.pumpWidget(
        JamSession(
          controller: session,
          child: MaterialApp(
            theme: jamLightTheme(),
            home: Builder(
              builder: (c) {
                context = c;
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );

      // Stay: nothing changes, and the new session does not start.
      final stay = jamReadyForNewSession(context, session);
      await tester.pumpAndSettle();
      expect(
        find.text(JamSessionGateStrings.endTitle('Van Jam')),
        findsOneWidget,
      );
      await tester.tap(find.text(JamSessionGateStrings.stay));
      await tester.pumpAndSettle();
      expect(await stay, isFalse);
      expect(session.isLive, isTrue);

      // End it: the jam goes, and the way is clear.
      var cleared = false;
      unawaited(
        jamReadyForNewSession(context, session).then((ok) => cleared = ok),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(JamSessionGateStrings.endJam));
      for (var i = 0; i < 40 && !cleared; i++) {
        await _settleReal(tester);
      }
      expect(cleared, isTrue);
      expect(session.phase, JamSessionPhase.idle);
    });

    testWidgets('a jam that ends under the question is not a "Stay": the '
        'way is clear, and the new session goes ahead', (tester) async {
      final host = testSession();
      final guest = testSession(identity: 'Ana');
      final cache = _tempCache();
      await tester.runAsync(() async {
        await host.startHost(sessionName: 'Van Jam', discoverable: false);
        expect(await guest.join(host.joinUri!, mediaCacheDir: cache), isTrue);
      });
      final router = await pumpApp(tester, guest);
      await tester.pump();
      final context = router.routerDelegate.navigatorKey.currentContext!;
      bool? cleared;
      unawaited(
        jamReadyForNewSession(context, guest).then((ok) => cleared = ok),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.text(JamSessionGateStrings.leaveTitle('Van Jam')),
        findsOneWidget,
      );

      // The host ends the jam while the question is up; the router takes
      // the dialog down with the session.
      await tester.runAsync(() async {
        await host.leave();
        expect(
          await _waitFor(() => guest.phase == JamSessionPhase.ended),
          isTrue,
        );
      });
      for (var i = 0; i < 10 && cleared == null; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(cleared, isTrue, reason: 'the link or start must not be lost');

      await _endApp(tester, [guest, host]);
    });

    testWidgets('idle goes straight through', (tester) async {
      final session = testSession();
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (c) {
              context = c;
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(await jamReadyForNewSession(context, session), isTrue);
    });
  });

  group('nudge', () {
    testWidgets('the slider follows the engine’s per-route value', (
      tester,
    ) async {
      // The engine owns persistence and reloads the nudge itself when the
      // output route changes; the slider only has to follow it.
      final session = testSession();
      await startTestHost(tester, session, 'Nudge Jam');
      await tester.pumpWidget(
        MaterialApp(
          theme: jamLightTheme(),
          home: Scaffold(body: NudgeSlider(engine: session.engine!)),
        ),
      );
      expect(find.text(JamNudgeStrings.value(0)), findsWidgets);

      await tester.runAsync(() => session.engine!.setNudgeUs(120000));
      await tester.pump();
      expect(find.text(JamNudgeStrings.value(120)), findsWidgets);

      await leaveTestSession(tester, session);
    });
  });
}
