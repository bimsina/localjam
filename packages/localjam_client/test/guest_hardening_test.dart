/// [JamGuestEngine] hardening against a real loopback [JamHostServer]:
/// failed fetches retry with backoff and never strand the guest, a host that
/// said it is away is waited for, kicked-while-away ends as kicked, requests
/// while reconnecting never throw, a clock step re-schedules playback, and a
/// device sleep keeps output silent until the clock is trusted again.
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
  setUpAll(() => HttpOverrides.global = null);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<JamHostServer> startHost({JamPolicy policy = JamPolicy.open}) async {
    final host = JamHostServer(sessionName: 'HardJam', policy: policy);
    await host.start(address: InternetAddress.loopbackIPv4);
    addTearDown(host.close);
    return host;
  }

  /// Adds a track backed by a real file; returns both so a test can make the
  /// file vanish (the host then cannot serve it) and come back.
  Future<({MediaItem item, File file, List<int> bytes})> addTrack(
    JamHostServer host, {
    int seed = 42,
  }) async {
    final bytes = makeMediaBytes(4096, seed: seed);
    final file = await writeTempMedia(bytes, name: 'track_$seed.mp3');
    final item = await JamHostServer.describeFile(
      file,
      kind: MediaKind.audio,
      mime: 'audio/mpeg',
      durationUs: 60_000_000,
    );
    host.addMedia(item, file);
    return (item: item, file: file, bytes: bytes);
  }

  JamBackoff fast(int ms) => JamBackoff(
    initialDelay: Duration(milliseconds: ms),
    maxDelay: Duration(milliseconds: ms * 2),
    jitterRatio: 0,
  );

  Future<JamGuestEngine> join(
    JamHostServer host, {
    JamBackoff? backoff,
    JamBackoff? fetchRetryBackoff,
    int maxFetchRetries = 5,
    Duration hostGoneTimeout = const Duration(seconds: 90),
    Duration hostAwayTimeout = const Duration(minutes: 10),
    Duration clockWakeTimeout = const Duration(seconds: 8),
    String? clientId,
  }) async {
    final engine = await JamGuestEngine.join(
      host.joinUriFor(InternetAddress.loopbackIPv4),
      clientName: 'hard-guest',
      mediaCacheDir: await makeTempDir(),
      backoff: backoff ?? fast(20),
      fetchRetryBackoff: fetchRetryBackoff,
      maxFetchRetries: maxFetchRetries,
      hostGoneTimeout: hostGoneTimeout,
      hostAwayTimeout: hostAwayTimeout,
      clockWakeTimeout: clockWakeTimeout,
      clientId: clientId,
    );
    addTearDown(engine.close);
    return engine;
  }

  JamPrefetchState? stateOf(JamGuestEngine engine, MediaItem item) =>
      engine.prefetchStates.value[item.mediaId];

  group('failed track recovery (§6.2)', () {
    test('a failed fetch is retried with backoff and recovers once the host '
        'can serve it again', () async {
      mockAudioChannel();
      final host = await startHost();
      final track = await addTrack(host);
      await track.file.delete(); // The host cannot serve it for now.

      final engine = await join(host, fetchRetryBackoff: fast(150));
      await waitFor(
        () => stateOf(engine, track.item)?.phase == JamPrefetchPhase.failed,
        reason: 'the first fetch to fail',
      );
      final failed = stateOf(engine, track.item)!;
      expect(failed.willRetry, isTrue);
      expect(failed.failures, greaterThanOrEqualTo(1));
      expect(failed.error, isNotNull);

      await track.file.writeAsBytes(track.bytes);
      await waitFor(
        () => stateOf(engine, track.item)?.ready ?? false,
        reason: 'a backoff retry to fetch it',
      );
      expect(stateOf(engine, track.item)!.failures, 0);
    });

    test('a fetch that keeps failing gives up after maxFetchRetries and '
        'waits for retryFetch — never stuck "getting this track"', () async {
      mockAudioChannel();
      final host = await startHost();
      final track = await addTrack(host);
      await track.file.delete();

      final engine = await join(
        host,
        fetchRetryBackoff: fast(50),
        maxFetchRetries: 2,
      );
      await waitFor(
        () =>
            stateOf(engine, track.item)?.phase == JamPrefetchPhase.failed &&
            !stateOf(engine, track.item)!.willRetry,
        reason: 'the retries to run out',
      );
      expect(stateOf(engine, track.item)!.failures, 3);

      // Bounded: nothing more happens on its own.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(stateOf(engine, track.item)!.failures, 3);

      await track.file.writeAsBytes(track.bytes);
      expect(engine.retryFetch(track.item.mediaId), isTrue);
      await waitFor(
        () => stateOf(engine, track.item)?.ready ?? false,
        reason: 'the manual retry to fetch it',
      );
      expect(engine.retryFetch(track.item.mediaId), isFalse, reason: 'ready');
    });

    test('a reconnect retries a failed fetch at once', () async {
      mockAudioChannel();
      final host = await startHost();
      final track = await addTrack(host);
      await track.file.delete();

      final engine = await join(
        host,
        fetchRetryBackoff: fast(50),
        maxFetchRetries: 0,
      );
      await waitFor(
        () =>
            stateOf(engine, track.item)?.phase == JamPrefetchPhase.failed &&
            !stateOf(engine, track.item)!.willRetry,
        reason: 'the fetch to give up',
      );
      await track.file.writeAsBytes(track.bytes);

      // A Wi-Fi blip: dropped, resumed.
      host.kickPeer(engine.selfPeerId, allowResume: true);
      await waitFor(
        () => stateOf(engine, track.item)?.ready ?? false,
        reason: 'the reconnect to retry the fetch',
      );
    });

    test('a track that gave up while "up next" is tried again the moment '
        'the room moves to it', () async {
      mockAudioChannel();
      final host = await startHost();
      final current = await addTrack(host, seed: 1);
      final next = await addTrack(host, seed: 2);
      host.setMedia(current.item.mediaId);
      await next.file.delete(); // "Up next" cannot be served for now.

      final engine = await join(
        host,
        fetchRetryBackoff: fast(50),
        maxFetchRetries: 0,
      );
      await waitFor(
        () =>
            (stateOf(engine, current.item)?.ready ?? false) &&
            stateOf(engine, next.item)?.phase == JamPrefetchPhase.failed &&
            !stateOf(engine, next.item)!.willRetry,
        reason: 'the current track fetched, the next one given up on',
      );
      await next.file.writeAsBytes(next.bytes);
      // Bounded: given up means nothing happens on its own...
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(stateOf(engine, next.item)?.phase, JamPrefetchPhase.failed);

      // ...until the room needs it: no reconnect, no manual retry.
      host.setMedia(next.item.mediaId);
      await waitFor(
        () => stateOf(engine, next.item)?.ready ?? false,
        reason: 'the newly current track to be fetched again',
      );
      expect(engine.connectionState, JamConnectionState.connected);
    });
  });

  group('host away / host gone (§3.5)', () {
    test('a host that said it is away is waited for with the long timeout, '
        'and the flag is surfaced', () async {
      mockAudioChannel();
      final host = await startHost();
      final engine = await join(
        host,
        hostGoneTimeout: const Duration(milliseconds: 300),
        hostAwayTimeout: const Duration(milliseconds: 1500),
      );
      expect(engine.hostAway.value, isFalse);

      await host.announceAway(true);
      await waitFor(() => engine.hostAway.value, reason: 'host_status away');

      // The phone went to sleep: silence, no goodbye.
      await host.close(announce: false);
      await waitFor(
        () => engine.connectionState == JamConnectionState.reconnecting,
        reason: 'the drop',
      );
      final dropped = DateTime.now();
      await Future<void>.delayed(const Duration(milliseconds: 800));
      expect(
        engine.sessionEnded.value,
        isNull,
        reason: 'the short host-gone timeout must not apply to an away host',
      );
      await waitFor(
        () => engine.sessionEnded.value != null,
        timeout: const Duration(seconds: 3),
        reason: 'the long timeout',
      );
      expect(engine.sessionEnded.value, JamSessionEndReason.hostGone);
      expect(
        DateTime.now().difference(dropped),
        greaterThanOrEqualTo(const Duration(milliseconds: 1400)),
      );
    });

    test('a host that is back uses the short timeout again', () async {
      mockAudioChannel();
      final host = await startHost();
      final engine = await join(
        host,
        hostGoneTimeout: const Duration(milliseconds: 300),
        hostAwayTimeout: const Duration(seconds: 30),
      );
      await host.announceAway(true);
      await waitFor(() => engine.hostAway.value, reason: 'away');
      await host.announceAway(false);
      await waitFor(() => !engine.hostAway.value, reason: 'back');

      await host.close(announce: false);
      await waitFor(
        () => engine.sessionEnded.value != null,
        timeout: const Duration(seconds: 3),
        reason: 'the short timeout',
      );
      expect(engine.sessionEnded.value, JamSessionEndReason.hostGone);
    });

    test('a device kicked while it was reconnecting ends as kicked, not '
        'rejected', () async {
      mockAudioChannel();
      final host = await startHost();
      // This device, joined.
      final away = await join(
        host,
        clientId: 'c_same_device',
        backoff: fast(400),
      );
      // The same device again (a relaunch): it supersedes the first
      // connection, which starts reconnecting...
      final back = await join(host, clientId: 'c_same_device');
      await waitFor(
        () => away.connectionState == JamConnectionState.reconnecting,
        reason: 'the superseded connection to drop',
      );
      // ...and the host kicks the device before that reconnect lands.
      host.kickPeer(back.selfPeerId);
      await waitFor(
        () => away.sessionEnded.value != null,
        reason: 'the reconnect to be refused',
      );
      expect(away.sessionEnded.value, JamSessionEndReason.kicked);
      expect(away.connectionState, JamConnectionState.failed);
    });
  });

  group('requests while reconnecting', () {
    test(
      'return false instead of throwing; uploads throw a typed error',
      () async {
        mockAudioChannel();
        final host = await startHost();
        final engine = await join(host, backoff: fast(1500));
        expect(engine.canSendCommands, isTrue);

        host.kickPeer(engine.selfPeerId, allowResume: true);
        await waitFor(
          () => engine.connectionState == JamConnectionState.reconnecting,
          reason: 'the drop',
        );
        expect(engine.canSendCommands, isFalse);
        expect(await engine.requestPlay(), isFalse);
        expect(await engine.requestPause(), isFalse);
        expect(await engine.requestSeek(1000), isFalse);
        expect(await engine.requestNext(), isFalse);
        expect(await engine.requestPrevious(), isFalse);
        expect(await engine.requestSetMedia('m_x'), isFalse);
        expect(await engine.requestQueueMove('m_x', 0), isFalse);
        expect(await engine.requestQueueRemove('m_x'), isFalse);
        // The shared transport intents (lock screen, shared widgets) too.
        await engine.transportPlay();
        await engine.transportNext();
        await expectLater(
          engine.addMedia(await writeTempMedia(makeMediaBytes(64))),
          throwsA(isA<JamNotConnectedException>()),
        );

        await waitFor(
          () => engine.canSendCommands,
          timeout: const Duration(seconds: 5),
          reason: 'the reconnect',
        );
        expect(await engine.requestPause(), isTrue);
      },
    );
  });

  group('session clock on a guest (§4)', () {
    Future<({JamHostServer host, JamGuestEngine engine, List<MethodCall> log})>
    playingGuest({
      Duration clockWakeTimeout = const Duration(seconds: 8),
    }) async {
      final log = mockAudioChannel();
      final host = await startHost();
      final track = await addTrack(host);
      host.setMedia(track.item.mediaId);
      final engine = await join(host, clockWakeTimeout: clockWakeTimeout);
      await waitFor(
        () =>
            engine.clockSynced && (stateOf(engine, track.item)?.ready ?? false),
        reason: 'clock sync and the track',
      );
      host.play();
      await waitFor(
        () => log.any((c) => c.method == 'playAt'),
        reason: 'the guest to schedule',
      );
      return (host: host, engine: engine, log: log);
    }

    test('a device sleep keeps output silent until the clock is trusted '
        'again, instead of resuming at a stale position', () async {
      final setup = await playingGuest(
        clockWakeTimeout: const Duration(milliseconds: 700),
      );
      addTearDown(() => JamGuestEngine.wallClock = DateTime.now);

      // 30 s of wall time passed while the monotonic clock stood still.
      setup.log.clear();
      JamGuestEngine.wallClock = () =>
          DateTime.now().add(const Duration(seconds: 30));
      await setup.engine.handleLifecycleState(AppLifecycleState.resumed);
      expect(setup.log.map((c) => c.method), contains('pause'));
      expect(setup.log.where((c) => c.method == 'playAt'), isEmpty);

      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(
        setup.log.where((c) => c.method == 'playAt'),
        isEmpty,
        reason: 'silent while the clock is not trusted',
      );
      // No jump shows up (loopback: there was none) — the wake burst's
      // readings are accepted, or the window passes — so the clock is
      // trusted again and playback re-anchors.
      await waitFor(
        () => setup.log.any((c) => c.method == 'playAt'),
        timeout: const Duration(seconds: 3),
        reason: 'the re-anchor once trusted',
      );
    });

    test('a clock step re-schedules from the current anchor and is '
        'acknowledged', () async {
      final setup = await playingGuest();
      // Let the 8-ping join burst land: steps are only detected after it.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      setup.log.clear();

      // Two consistent readings 100 ms off the estimate: a confirmed step.
      final clock = setup.engine.clock;
      for (var i = 0; i < 2; i++) {
        final t0 = monotonicNowUs();
        final t3 = t0 + 200;
        final hostUs = clock.localToHostUs(t0 + 100) + 100000;
        clock.addSample(ClockSample(t0: t0, t1: hostUs, t2: hostUs, t3: t3));
      }
      expect(clock.needsHardResync, isTrue);
      await waitFor(
        () => setup.log.any((c) => c.method == 'playAt'),
        timeout: const Duration(seconds: 3),
        reason: 're-schedule on the step',
      );
      expect(clock.needsHardResync, isFalse, reason: 'acknowledged');
      expect(setup.engine.sync.resyncCount, greaterThanOrEqualTo(1));
    });
  });
}
