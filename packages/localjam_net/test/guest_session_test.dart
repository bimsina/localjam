/// Integration tests for [JamGuestSession] connection resilience: a real
/// JamHostServer over 127.0.0.1 loopback, exercising the PROTOCOL.md §3.3
/// reconnect path (kick, host death, resume, bad_token) with short timings.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:localjam_net/localjam_net.dart';
import 'package:test/test.dart';

/// Deterministic pseudo-random media payload.
Uint8List makeMediaBytes(int length, {int seed = 42}) {
  final rng = Random(seed);
  return Uint8List.fromList([
    for (var i = 0; i < length; i++) rng.nextInt(256),
  ]);
}

Future<File> writeTempMedia(Uint8List bytes) async {
  final dir = await Directory.systemTemp.createTemp('localjam_session_test');
  addTearDown(() => dir.delete(recursive: true));
  final file = File('${dir.path}/track.bin');
  await file.writeAsBytes(bytes);
  return file;
}

Future<JamHostServer> startHost({String sessionName = 'TestJam'}) async {
  final host = JamHostServer(sessionName: sessionName);
  await host.start(address: InternetAddress.loopbackIPv4);
  addTearDown(host.close);
  return host;
}

/// A session with test-friendly reconnect timings (fast, jitterless).
Future<JamGuestSession> connectSession(
  JamHostServer host, {
  JamBackoff? backoff,
}) async {
  final session = await JamGuestSession.connect(
    host.joinUriFor(InternetAddress.loopbackIPv4),
    backoff:
        backoff ??
        JamBackoff(
          initialDelay: const Duration(milliseconds: 20),
          maxDelay: const Duration(milliseconds: 100),
          jitterRatio: 0,
        ),
    connectTimeout: const Duration(seconds: 2),
  );
  addTearDown(session.close);
  return session;
}

/// Counts how many reconnect delays were requested.
class CountingBackoff extends JamBackoff {
  CountingBackoff()
    : super(
        initialDelay: const Duration(milliseconds: 20),
        maxDelay: const Duration(milliseconds: 50),
        jitterRatio: 0,
      );

  int calls = 0;

  @override
  Duration delay(int attempt) {
    calls++;
    return super.delay(attempt);
  }
}

/// Polls [condition] every 10 ms until true or [timeout] elapses.
Future<void> waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
  String reason = 'condition',
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for $reason');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  test(
    'kickPeer with resume: session reconnects and regains the same peerId',
    () async {
      final host = await startHost();
      final file = await writeTempMedia(makeMediaBytes(1024));
      final item = await JamHostServer.describeFile(
        file,
        kind: MediaKind.audio,
      );
      host.addMedia(item, file);

      final session = await connectSession(host);
      final oldId = session.selfPeerId;
      expect(session.connectionState, JamConnectionState.connected);

      final connStates = <JamConnectionState>[];
      session.connectionStates.listen(connStates.add);
      final presence = <JamHostEventKind>[];
      host.events.listen((e) {
        if (e.kind == JamHostEventKind.peerLeft ||
            e.kind == JamHostEventKind.peerJoined) {
          presence.add(e.kind);
        }
      });
      // Subscribed before the kick: the states stream must survive it.
      final playing = session.states
          .firstWhere((s) => s.status == PlaybackStatus.playing)
          .timeout(const Duration(seconds: 5));

      host.kickPeer(oldId);
      await waitFor(
        () =>
            session.connectionState == JamConnectionState.connected &&
            connStates.contains(JamConnectionState.reconnecting),
        reason: 'session to resume after kick',
      );
      // §3.3: resume within the grace window reclaims the same peerId.
      expect(session.selfPeerId, oldId);
      expect(connStates, [
        JamConnectionState.reconnecting,
        JamConnectionState.connected,
      ]);
      await waitFor(
        () => presence.length >= 2,
        reason: 'host peer_left then peer_joined',
      );
      expect(presence.sublist(0, 2), [
        JamHostEventKind.peerLeft,
        JamHostEventKind.peerJoined,
      ]);

      // A post-resume broadcast arrives on the same (pre-kick) subscription.
      host.setMedia(item.mediaId);
      host.play();
      final snapshot = await playing;
      expect(snapshot.mediaId, item.mediaId);
    },
  );

  test(
    'kickPeer(allowResume: false): session recovers with a NEW peerId',
    () async {
      final host = await startHost();
      final session = await connectSession(host);
      final oldId = session.selfPeerId;

      host.kickPeer(oldId, allowResume: false);
      await waitFor(
        () =>
            session.connectionState == JamConnectionState.connected &&
            session.selfPeerId != oldId,
        reason: 'fresh join with a new peerId',
      );
      expect(session.selfPeerId, isNot(oldId));
      expect(session.selfPeerId, startsWith('p_'));
      expect(host.peers.map((p) => p.peerId), contains(session.selfPeerId));
    },
  );

  test('host closed for good: session keeps retrying until close()', () async {
    final host = await startHost();
    final backoff = CountingBackoff();
    final session = await connectSession(host, backoff: backoff);

    final connStates = <JamConnectionState>[];
    session.connectionStates.listen(connStates.add);

    await host.close();
    await waitFor(
      () => session.connectionState == JamConnectionState.reconnecting,
      reason: 'reconnecting after host death',
    );
    await waitFor(
      () => backoff.calls >= 2,
      reason: 'at least two reconnect attempts',
    );
    expect(session.connectionState, JamConnectionState.reconnecting);

    await session.close();
    expect(session.connectionState, JamConnectionState.closed);
    expect(connStates, [
      JamConnectionState.reconnecting,
      JamConnectionState.closed,
    ]);
    // Idempotent.
    await session.close();
    expect(session.connectionState, JamConnectionState.closed);
  });

  test(
    'request and fetch methods throw StateError while reconnecting',
    () async {
      final host = await startHost();
      final session = await connectSession(host);
      await host.close();
      await waitFor(
        () => session.connectionState == JamConnectionState.reconnecting,
        reason: 'reconnecting after host death',
      );

      expect(session.requestPlay, throwsStateError);
      expect(session.requestPause, throwsStateError);
      expect(() => session.requestSeek(1000), throwsStateError);
      expect(() => session.requestSetMedia('m_x'), throwsStateError);
      expect(() => session.fetchMedia('m_x'), throwsStateError);

      await session.close();
    },
  );

  test('sendMediaStatus reaches the host, and is a silent no-op while '
      'reconnecting rather than throwing', () async {
    final host = await startHost();
    final file = await writeTempMedia(makeMediaBytes(1024));
    final item = await JamHostServer.describeFile(file, kind: MediaKind.audio);
    host.addMedia(item, file);
    final session = await connectSession(host);

    final statusEvent = host.events
        .firstWhere((e) => e.kind == JamHostEventKind.peerMediaStatus)
        .timeout(const Duration(seconds: 5));
    session.sendMediaStatus(item.mediaId, MediaFetchState.ready);
    final event = await statusEvent;
    expect(event.peerId, session.selfPeerId);
    expect(host.allPeersReady(item.mediaId), isTrue);

    await host.close();
    await waitFor(
      () => session.connectionState == JamConnectionState.reconnecting,
      reason: 'reconnecting after host death',
    );
    // Unlike requestPlay/requestPause/etc, this is close-tolerant: no
    // StateError while not connected.
    expect(
      () => session.sendMediaStatus(item.mediaId, MediaFetchState.ready),
      returnsNormally,
    );

    await session.close();
  });

  test(
    'new host on the same port with a different token: reject -> failed',
    () async {
      final host = await startHost();
      final port = host.port;
      final backoff = CountingBackoff();
      final session = await connectSession(host, backoff: backoff);
      final connStates = <JamConnectionState>[];
      session.connectionStates.listen(connStates.add);

      await host.close();
      await waitFor(
        () => session.connectionState == JamConnectionState.reconnecting,
        reason: 'reconnecting after host death',
      );

      // A different session on the same port: its fresh random token makes
      // every resume attempt answer `reject bad_token`.
      final imposter = JamHostServer(sessionName: 'Imposter');
      await imposter.start(address: InternetAddress.loopbackIPv4, port: port);
      addTearDown(imposter.close);
      expect(imposter.token, isNot(host.token));

      await waitFor(
        () => session.connectionState == JamConnectionState.failed,
        reason: 'failed after bad_token reject',
      );
      expect(connStates, [
        JamConnectionState.reconnecting,
        JamConnectionState.failed,
      ]);

      // No further retries after failed.
      final callsAtFailure = backoff.calls;
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(backoff.calls, callsAtFailure);
      expect(session.connectionState, JamConnectionState.failed);
      expect(imposter.peers, isEmpty);
    },
  );
}
