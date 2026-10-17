/// The [JamGuestEngine] session-end contract against real loopback hosts:
/// `hostGone` after [JamGuestEngine.hostGoneTimeout] of continuous
/// reconnecting, cancellation by a successful reconnect, immediate `rejected`
/// on an authoritative reject, an ended guest falling silent and letting go
/// of its guards, and `closedLocally` on close().
library;

import 'dart:io';

import 'package:flutter/services.dart' show MethodCall;
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_client/localjam_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'engine_test_utils.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // The test binding fakes every HttpClient with a 400 stub; these tests
  // exercise real loopback sockets.
  setUpAll(() => HttpOverrides.global = null);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<JamHostServer> startHost({int port = 0}) async {
    final host = JamHostServer(sessionName: 'EndTestJam');
    await host.start(address: InternetAddress.loopbackIPv4, port: port);
    addTearDown(host.close);
    return host;
  }

  /// Fast, jitterless reconnect schedule so tests run in milliseconds.
  JamBackoff fastBackoff() => JamBackoff(
    initialDelay: const Duration(milliseconds: 20),
    maxDelay: const Duration(milliseconds: 50),
    jitterRatio: 0,
  );

  Future<JamGuestEngine> joinEngine(
    JamHostServer host, {
    required Duration hostGoneTimeout,
  }) async {
    final engine = await JamGuestEngine.join(
      host.joinUriFor(InternetAddress.loopbackIPv4),
      clientName: 'end-test-guest',
      mediaCacheDir: await makeTempDir(),
      backoff: fastBackoff(),
      hostGoneTimeout: hostGoneTimeout,
    );
    addTearDown(engine.close);
    return engine;
  }

  test(
    'hostGone fires after hostGoneTimeout of continuous reconnecting',
    () async {
      mockAudioChannel();
      final host = await startHost();
      final engine = await joinEngine(
        host,
        hostGoneTimeout: const Duration(milliseconds: 400),
      );
      expect(engine.sessionEnded.value, isNull);

      // Host death with no goodbye: guests only see the socket close, which
      // is all a crash or a dead battery ever leaves behind.
      await host.close(announce: false);
      await waitFor(
        () => engine.connectionState == JamConnectionState.reconnecting,
        reason: 'session to enter reconnecting',
      );
      expect(engine.sessionEnded.value, isNull, reason: 'not terminal yet');

      await waitFor(
        () => engine.sessionEnded.value != null,
        reason: 'hostGone after the timeout',
      );
      expect(engine.sessionEnded.value, JamSessionEndReason.hostGone);
      // The engine stopped the underlying session's retries.
      expect(engine.connectionState, JamConnectionState.closed);
    },
  );

  test('a successful reconnect cancels the hostGone countdown', () async {
    mockAudioChannel();
    final host = await startHost();
    final engine = await joinEngine(
      host,
      hostGoneTimeout: const Duration(milliseconds: 500),
    );

    final seen = <JamConnectionState>[];
    engine.connectionStates.listen(seen.add);

    // Kick without closing the host: the drop starts the countdown, the
    // near-immediate resume (fast backoff) must cancel it.
    // A resumable forced drop (not a real kick — that would be terminal).
    host.kickPeer(engine.selfPeerId, allowResume: true);
    await waitFor(
      () => seen.contains(JamConnectionState.reconnecting),
      reason: 'drop observed',
    );
    await waitFor(
      () => engine.connectionState == JamConnectionState.connected,
      reason: 'reconnect to succeed',
    );

    // Well past the timeout: the countdown must not fire anymore.
    await Future<void>.delayed(const Duration(milliseconds: 700));
    expect(engine.sessionEnded.value, isNull);
    expect(engine.connectionState, JamConnectionState.connected);
  });

  test(
    'an authoritative reject ends the session as rejected immediately',
    () async {
      mockAudioChannel();
      final host = await startHost();
      final engine = await joinEngine(
        host,
        // Far longer than the test: rejected must NOT wait for this.
        hostGoneTimeout: const Duration(seconds: 30),
      );
      final port = host.port;
      await host.close(announce: false);

      // A different session on the same port: the guest's token is now
      // invalid, so the next reconnect attempt is answered with reject
      // (bad_token) — the JamGuestSession lands in failed.
      final imposter = JamHostServer(sessionName: 'SomeOtherJam');
      await imposter.start(address: InternetAddress.loopbackIPv4, port: port);
      addTearDown(imposter.close);

      await waitFor(
        () => engine.sessionEnded.value != null,
        reason: 'rejected to propagate',
      );
      expect(engine.sessionEnded.value, JamSessionEndReason.rejected);
      expect(engine.connectionState, JamConnectionState.failed);
    },
  );

  test(
    'a host that ends the jam is terminal at once, not after hostGone',
    () async {
      mockAudioChannel();
      final host = await startHost();
      final engine = await joinEngine(
        host,
        // A hostGone timeout that would outlast the test many times over:
        // the announced end must not wait for it.
        hostGoneTimeout: const Duration(seconds: 90),
      );
      expect(engine.sessionEnded.value, isNull);

      final started = DateTime.now();
      await host.close(); // "End jam": announced (§3.4), not inferred.

      await waitFor(
        () => engine.sessionEnded.value != null,
        timeout: const Duration(seconds: 1),
        reason: 'session_ended to land within a second',
      );
      expect(engine.sessionEnded.value, JamSessionEndReason.hostEnded);
      expect(
        DateTime.now().difference(started),
        lessThan(const Duration(seconds: 1)),
      );
      // Terminal: no reconnect attempts are left running.
      expect(engine.connectionState, JamConnectionState.failed);
    },
  );

  group('which refusal it was', () {
    // `rejected` alone hid the cause: a restarted room (never worth another
    // try with the same link), a full one (worth one later) and a version
    // mismatch (an update, not a retry) all looked the same to the app.

    test('a restarted room: bad_token, readable from the end listener, '
        'and no fatal code', () async {
      mockAudioChannel();
      final host = await startHost();
      final engine = await joinEngine(
        host,
        hostGoneTimeout: const Duration(seconds: 30),
      );
      expect(engine.lastRejectReason, isNull, reason: 'alive');
      expect(engine.lastFatalErrorCode, isNull, reason: 'alive');
      RejectReason? seenInListener;
      engine.sessionEnded.addListener(
        () => seenInListener ??= engine.lastRejectReason,
      );

      final port = host.port;
      await host.close(announce: false);
      final restarted = JamHostServer(sessionName: 'EndTestJam');
      await restarted.start(address: InternetAddress.loopbackIPv4, port: port);
      addTearDown(restarted.close);

      await waitFor(
        () => engine.sessionEnded.value != null,
        reason: 'the refused reconnect',
      );
      expect(engine.sessionEnded.value, JamSessionEndReason.rejected);
      expect(engine.lastRejectReason, RejectReason.badToken);
      expect(seenInListener, RejectReason.badToken);
      expect(engine.lastFatalErrorCode, isNull);
    });

    test('a room that filled up while this guest was away: full', () async {
      mockAudioChannel();
      final host = JamHostServer(sessionName: 'TinyJam', maxPeers: 1);
      await host.start(address: InternetAddress.loopbackIPv4);
      addTearDown(host.close);
      final engine = await JamGuestEngine.join(
        host.joinUriFor(InternetAddress.loopbackIPv4),
        clientName: 'end-test-guest',
        mediaCacheDir: await makeTempDir(),
        // Slow enough that someone else takes the only slot first.
        backoff: JamBackoff(
          initialDelay: const Duration(milliseconds: 400),
          jitterRatio: 0,
        ),
        hostGoneTimeout: const Duration(seconds: 30),
      );
      addTearDown(engine.close);

      host.kickPeer(engine.selfPeerId, allowResume: true); // A plain drop.
      await waitFor(
        () => engine.connectionState == JamConnectionState.reconnecting,
        reason: 'the drop',
      );
      final other = await JamGuestClient.connect(
        host.joinUriFor(InternetAddress.loopbackIPv4),
        clientName: 'Someone Else',
      );
      addTearDown(other.close);

      await waitFor(
        () => engine.sessionEnded.value != null,
        reason: 'the refused reconnect',
      );
      expect(engine.sessionEnded.value, JamSessionEndReason.rejected);
      expect(engine.lastRejectReason, RejectReason.full);
      expect(engine.lastFatalErrorCode, isNull);
    });

    test('a kick: the fatal code, and no reject reason', () async {
      mockAudioChannel();
      final host = await startHost();
      final engine = await joinEngine(
        host,
        hostGoneTimeout: const Duration(seconds: 30),
      );
      host.kickPeer(engine.selfPeerId);
      await waitFor(
        () => engine.sessionEnded.value != null,
        reason: 'the kick',
      );
      expect(engine.sessionEnded.value, JamSessionEndReason.kicked);
      expect(engine.lastFatalErrorCode, ErrorCode.kicked);
      expect(engine.lastRejectReason, isNull);
    });
  });

  group('an ended guest stops: the music is the host\'s (§10)', () {
    /// Records `localjam/keepalive` calls; `acquire` succeeds.
    List<String> mockKeepAlive() {
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(JamKeepAlive.channel, (call) async {
            calls.add(call.method);
            return call.method == 'acquire' ? true : null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(JamKeepAlive.channel, null),
      );
      return calls;
    }

    /// A guest audibly following a playing room, with the native event
    /// channel in the test's hands.
    Future<
      ({
        JamHostServer host,
        JamGuestEngine guest,
        List<MethodCall> log,
        void Function(Map<String, Object?>) push,
        List<String> keepAlive,
      })
    >
    playingGuest({
      Duration hostGoneTimeout = const Duration(seconds: 30),
    }) async {
      final log = mockAudioChannel();
      final push = mockAudioEvents();
      final keepAlive = mockKeepAlive();
      final host = await startHost();
      final file = await writeTempMedia(makeMediaBytes(4096, seed: 5));
      final item = await JamHostServer.describeFile(
        file,
        kind: MediaKind.audio,
        mime: 'audio/mpeg',
        durationUs: 60000000,
      );
      host
        ..addMedia(item, file)
        ..setMedia(item.mediaId);
      final guest = await joinEngine(host, hostGoneTimeout: hostGoneTimeout);
      expect(keepAlive, ['acquire']);
      host.play();
      await waitFor(
        () => log.any((c) => c.method == 'playAt'),
        reason: 'the guest playing',
      );
      return (
        host: host,
        guest: guest,
        log: log,
        push: push,
        keepAlive: keepAlive,
      );
    }

    /// Everything an ended guest must have let go of, and the proof that
    /// nothing brings its sound back.
    Future<void> expectStopped(
      ({
        JamHostServer host,
        JamGuestEngine guest,
        List<MethodCall> log,
        void Function(Map<String, Object?>) push,
        List<String> keepAlive,
      })
      s,
    ) async {
      final guest = s.guest;
      await waitFor(
        () => s.keepAlive.contains('release'),
        reason: 'the keep-alive (FGS + wake/Wi-Fi locks) released',
      );
      expect(guest.lifecycleObserverAttached, isFalse);
      expect(guest.mediaSessionController, isNull, reason: 'card cleared');
      expect(guest.sync.isHalted, isTrue);
      final afterEnd = s.log.lastIndexWhere((c) => c.method == 'playAt');
      expect(
        s.log.sublist(afterEnd).map((c) => c.method),
        contains('stop'),
        reason: 'output stopped',
      );
      s.log.clear();

      // Nothing local brings it back: the OS handing audio back, a route
      // change, the app coming forward, the user's own resume or play.
      s.push({'type': 'interruptionEnded', 'shouldResume': true});
      s.push({'type': 'routeChanged', 'routeId': 'speaker'});
      await guest.handleLifecycleState(AppLifecycleState.resumed);
      await guest.resumeLocalOutput();
      expect(await guest.transportPlay(), isFalse);
      await guest.setNudgeUs(30000, persist: false);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(s.log.where((c) => c.method == 'playAt'), isEmpty);
      expect(
        guest.sync.confirmedPlayingWithin(const Duration(minutes: 1)),
        isFalse,
      );
      // What the terminal screen shows is still there.
      expect(guest.playlist, isNotEmpty);
      expect(guest.snapshot.mediaId, isNotNull);
    }

    test('the host ended the jam (announced)', () async {
      final s = await playingGuest();
      await s.host.close();
      await waitFor(
        () => s.guest.sessionEnded.value != null,
        reason: 'the end',
      );
      expect(s.guest.sessionEnded.value, JamSessionEndReason.hostEnded);
      await expectStopped(s);
    });

    test('this guest was removed', () async {
      final s = await playingGuest();
      s.host.kickPeer(s.guest.selfPeerId);
      await waitFor(
        () => s.guest.sessionEnded.value != null,
        reason: 'the kick',
      );
      expect(s.guest.sessionEnded.value, JamSessionEndReason.kicked);
      await expectStopped(s);
    });

    test('the host vanished', () async {
      final s = await playingGuest(
        hostGoneTimeout: const Duration(milliseconds: 400),
      );
      await s.host.close(announce: false);
      await waitFor(
        () => s.guest.sessionEnded.value != null,
        reason: 'the host-gone timeout',
      );
      expect(s.guest.sessionEnded.value, JamSessionEndReason.hostGone);
      await expectStopped(s);
    });
  });

  test('local close() reports closedLocally', () async {
    mockAudioChannel();
    final host = await startHost();
    final engine = await joinEngine(
      host,
      hostGoneTimeout: const Duration(seconds: 30),
    );

    JamSessionEndReason? seen;
    void onEnded() => seen = engine.sessionEnded.value;
    engine.sessionEnded.addListener(onEnded);
    await engine.close();
    expect(seen, JamSessionEndReason.closedLocally);
  });
}
