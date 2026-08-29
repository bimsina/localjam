/// The [JamGuestEngine] session-end contract against real loopback hosts:
/// `hostGone` after [JamGuestEngine.hostGoneTimeout] of continuous
/// reconnecting, cancellation by a successful reconnect, immediate `rejected`
/// on an authoritative reject, and `closedLocally` on close().
library;

import 'dart:io';

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

  test('hostGone fires after hostGoneTimeout of continuous reconnecting', () async {
    mockAudioChannel();
    final host = await startHost();
    final engine = await joinEngine(
      host,
      hostGoneTimeout: const Duration(milliseconds: 400),
    );
    expect(engine.sessionEnded.value, isNull);

    await host.close(); // Host death: guests only see the socket close.
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
  });

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

  test('an authoritative reject ends the session as rejected immediately', () async {
    mockAudioChannel();
    final host = await startHost();
    final engine = await joinEngine(
      host,
      // Far longer than the test: rejected must NOT wait for this.
      hostGoneTimeout: const Duration(seconds: 30),
    );
    final port = host.port;
    await host.close();

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
