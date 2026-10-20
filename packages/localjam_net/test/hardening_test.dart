/// Regression tests for the protocol-1 hardening pass: liveness against a
/// host that goes silent without closing anything (§3.3), the major-version
/// gate and tolerant decoding (§2), the host "away" signal (§3.5), per-peer
/// upload credentials (§6.4), moderation keyed on the device (§5.6), upload
/// validation, compression, listener health, host-reported end of media
/// (§5.5) and the readiness gate (§6.3).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:localjam_net/localjam_net.dart';
import 'package:test/test.dart';

import 'hardening_helpers.dart';
import 'test_fixtures.dart';

const _codec = MessageCodec();

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('liveness against a silent host (§3.3)', () {
    test('a host that goes dark without closing anything is detected within '
        'the liveness window', () async {
      final host = await startHost();
      final proxy = await BlackholeProxy.start(host.port);
      final guest = await JamGuestClient.connect(
        host
            .joinUriFor(InternetAddress.loopbackIPv4)
            .replace(
              queryParameters: {
                ...host
                    .joinUriFor(InternetAddress.loopbackIPv4)
                    .queryParameters,
                'port': '${proxy.port}',
              },
            ),
        pingInterval: const Duration(milliseconds: 100),
        livenessTimeout: const Duration(milliseconds: 600),
      );
      addTearDown(guest.close);

      // Healthy for several windows: pongs keep the watchdog quiet.
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      var done = false;
      unawaited(guest.done.then((_) => done = true));
      expect(done, isFalse);
      expect(guest.hostSilent, isFalse);

      final darkAt = DateTime.now();
      proxy.blackhole();
      await guest.done.timeout(const Duration(seconds: 3));
      final took = DateTime.now().difference(darkAt);
      expect(guest.hostSilent, isTrue);
      expect(took, lessThan(const Duration(milliseconds: 1500)));
      // Not before the window: the last pong was at most one ping ago.
      expect(took, greaterThanOrEqualTo(const Duration(milliseconds: 400)));
    });

    test('the default window is three ping intervals', () {
      expect(
        JamGuestClient.defaultLivenessTimeout(const Duration(seconds: 2)),
        const Duration(seconds: 6),
      );
    });

    test('a session whose host went dark reconnects instead of hanging '
        '"connected"', () async {
      final host = await startHost();
      final proxy = await BlackholeProxy.start(host.port);
      final uri = host.joinUriFor(InternetAddress.loopbackIPv4);
      final session = await JamGuestSession.connect(
        uri.replace(
          queryParameters: {...uri.queryParameters, 'port': '${proxy.port}'},
        ),
        clientId: 'c_dark',
        pingInterval: const Duration(milliseconds: 100),
        livenessTimeout: const Duration(milliseconds: 500),
        backoff: JamBackoff(
          initialDelay: const Duration(milliseconds: 20),
          jitterRatio: 0,
        ),
      );
      addTearDown(session.close);
      final states = <JamConnectionState>[];
      session.connectionStates.listen(states.add);

      proxy.blackhole(); // The old connection is dead; new ones get through.
      await waitFor(
        () => states.contains(JamConnectionState.reconnecting),
        timeout: const Duration(seconds: 2),
        reason: 'the watchdog to notice',
      );
      await waitFor(
        () => session.connectionState == JamConnectionState.connected,
        timeout: const Duration(seconds: 3),
        reason: 'the reconnect',
      );
      // The device came back on a new socket and replaced its ghost (§3.3).
      await waitFor(() => host.peers.length == 1, reason: 'one peer');
    });

    test('a media fetch from a host that stops mid-body times out and '
        'reports none', () async {
      final item = MediaItem(
        mediaId: 'm_stall',
        kind: MediaKind.audio,
        name: 'stall.bin',
        mime: 'application/octet-stream',
        sizeBytes: 100000,
        sha256: '',
      );
      final fake = await FakeHost.start(
        onHello: (ws, _) {
          ws.add(_codec.encode(fakeWelcome(playlist: [item]), seq: 0));
        },
        onMedia: (req) async {
          req.response.contentLength = 100000;
          req.response.add(Uint8List(1000));
          await req.response.flush();
          // ...and then nothing, forever, with the connection open.
        },
      );
      final guest = await JamGuestClient.connect(
        joinUriForPort(fake.port),
        mediaTimeout: const Duration(milliseconds: 300),
      );
      addTearDown(guest.close);

      final dir = await Directory.systemTemp.createTemp('localjam_stall');
      addTearDown(() => dir.delete(recursive: true));
      final dest = File('${dir.path}/stall.bin');
      final started = DateTime.now();
      await expectLater(
        guest.fetchMediaToFile('m_stall', dest),
        throwsA(isA<TimeoutException>()),
      );
      expect(
        DateTime.now().difference(started),
        lessThan(const Duration(seconds: 3)),
      );
      expect(dest.existsSync(), isFalse, reason: 'partial file removed');
      await waitFor(
        () => fake.received.any(
          (f) =>
              f['type'] == 'media_status' &&
              (f['payload'] as Map)['state'] == 'none',
        ),
        reason: 'media_status none (§6.3)',
      );
    });

    test('a media fetch whose connection breaks mid-body deletes the '
        'partial file and reports none', () async {
      final item = MediaItem(
        mediaId: 'm_break',
        kind: MediaKind.audio,
        name: 'break.bin',
        mime: 'application/octet-stream',
        sizeBytes: 100000,
        sha256: '',
      );
      final fake = await FakeHost.start(
        onHello: (ws, _) {
          ws.add(_codec.encode(fakeWelcome(playlist: [item]), seq: 0));
        },
        onMedia: (req) async {
          req.response.contentLength = 100000;
          req.response.add(Uint8List(1000));
          await req.response.flush();
          // Ends short of the declared length: the server tears the
          // connection down, and the guest is left with a fragment.
          try {
            await req.response.close();
          } catch (_) {}
        },
      );
      final guest = await JamGuestClient.connect(joinUriForPort(fake.port));
      addTearDown(guest.close);

      final dir = await Directory.systemTemp.createTemp('localjam_break');
      addTearDown(() => dir.delete(recursive: true));
      final dest = File('${dir.path}/break.bin');
      await expectLater(
        guest.fetchMediaToFile('m_break', dest),
        throwsA(isNot(isA<TimeoutException>())),
      );
      expect(dest.existsSync(), isFalse, reason: 'partial file removed');
      await waitFor(
        () => fake.received.any(
          (f) =>
              f['type'] == 'media_status' &&
              (f['payload'] as Map)['state'] == 'none',
        ),
        reason: 'media_status none (§6.3)',
      );
    });

    test('a verified fetch with reportReady: false reports fetching, never '
        'ready', () async {
      final bytes = Uint8List.fromList(List.generate(5000, (i) => i & 0xff));
      final item = MediaItem(
        mediaId: 'm_quiet',
        kind: MediaKind.audio,
        name: 'quiet.bin',
        mime: 'application/octet-stream',
        sizeBytes: bytes.length,
        sha256: '',
      );
      final fake = await FakeHost.start(
        onHello: (ws, _) {
          ws.add(_codec.encode(fakeWelcome(playlist: [item]), seq: 0));
        },
        onMedia: (req) async {
          req.response.contentLength = bytes.length;
          req.response.add(bytes);
          await req.response.close();
        },
      );
      final guest = await JamGuestClient.connect(joinUriForPort(fake.port));
      addTearDown(guest.close);
      final sink = JamBytesMediaSink();
      await guest.fetchMediaToSink('m_quiet', sink, reportReady: false);
      expect(sink.takeBytes(), bytes);
      await waitFor(
        () => fake.received.any((f) => f['type'] == 'media_status'),
        reason: 'the fetching report',
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final states = [
        for (final f in fake.received)
          if (f['type'] == 'media_status') (f['payload'] as Map)['state'],
      ];
      expect(states, isNot(contains('ready')));
      expect(states, contains('fetching'));
    });

    group('a fetch that ends reports none, whatever ended it (§6.3)', () {
      Future<(FakeHost, JamGuestClient)> serving(
        MediaItem item,
        Uint8List body, {
        bool framed = true,
      }) async {
        final fake = await FakeHost.start(
          onHello: (ws, _) {
            ws.add(_codec.encode(fakeWelcome(playlist: [item]), seq: 0));
          },
          onMedia: (req) async {
            // Unframed: chunked, so nothing but the guest bounds the body.
            if (framed) req.response.contentLength = body.length;
            try {
              for (var at = 0; at < body.length; at += 16 * 1024) {
                req.response.add(
                  Uint8List.sublistView(
                    body,
                    at,
                    min(at + 16 * 1024, body.length),
                  ),
                );
                await req.response.flush();
              }
              await req.response.close();
            } catch (_) {
              // The guest hung up: the point of some of these.
            }
          },
        );
        final guest = await JamGuestClient.connect(joinUriForPort(fake.port));
        addTearDown(guest.close);
        return (fake, guest);
      }

      List<Object?> statesOf(FakeHost fake) => [
        for (final f in fake.received)
          if (f['type'] == 'media_status') (f['payload'] as Map)['state'],
      ];

      Future<void> reportsNone(FakeHost fake) => waitFor(
        () => statesOf(fake).contains('none'),
        reason: 'media_status none (§6.3)',
      );

      MediaItem itemOf(String id, int sizeBytes) => MediaItem(
        mediaId: id,
        kind: MediaKind.audio,
        name: '$id.bin',
        mime: 'application/octet-stream',
        sizeBytes: sizeBytes,
        sha256: '',
      );

      test('a sink whose open throws', () async {
        final body = Uint8List(5000);
        final (fake, guest) = await serving(itemOf('m_open', 5000), body);
        final sink = _ScriptedSink(failOpen: true);
        await expectLater(
          guest.fetchMediaToSink('m_open', sink),
          throwsA(isA<FileSystemException>()),
        );
        await reportsNone(fake);
        expect(statesOf(fake), ['fetching', 'none']);
        expect(sink.calls, ['open', 'close', 'abandon']);
      });

      test('a sink whose close throws (a full disk)', () async {
        final body = Uint8List(5000);
        final (fake, guest) = await serving(itemOf('m_close', 5000), body);
        final sink = _ScriptedSink(failClose: true);
        await expectLater(
          guest.fetchMediaToSink('m_close', sink),
          throwsA(isA<FileSystemException>()),
        );
        await reportsNone(fake);
        expect(statesOf(fake), isNot(contains('ready')));
        expect(sink.calls, ['open', 'add', 'close', 'abandon']);
      });

      test('an unframed body with no sizeBytes stops at maxBytes', () async {
        final body = Uint8List(300 * 1024);
        final (fake, guest) = await serving(
          itemOf('m_unbounded', 0),
          body,
          framed: false,
        );
        final sink = JamBytesMediaSink();
        await expectLater(
          guest.fetchMediaToSink('m_unbounded', sink, maxBytes: 100 * 1024),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('declared size'),
            ),
          ),
        );
        expect(sink.length, lessThanOrEqualTo(100 * 1024));
        await reportsNone(fake);
      });

      test('an absurd sizeBytes is no size at all', () async {
        // 2^60 (dart2js would take 1e300 the same way): past maxBytes, so
        // it is not the bound — the ceiling is.
        final body = Uint8List(300 * 1024);
        final (fake, guest) = await serving(
          itemOf('m_absurd', 1 << 60),
          body,
          framed: false,
        );
        await expectLater(
          guest.fetchMediaToSink(
            'm_absurd',
            JamBytesMediaSink(),
            maxBytes: 100 * 1024,
          ),
          throwsStateError,
        );
        await reportsNone(fake);
      });

      test('with no usable sizeBytes, Content-Length is the size', () async {
        final body = Uint8List.fromList(List.generate(50000, (i) => i & 0xff));
        for (final declared in [0, 1 << 60]) {
          final (_, guest) = await serving(itemOf('m_framed', declared), body);
          final progress = <double>[];
          final sink = JamBytesMediaSink();
          await guest.fetchMediaToSink(
            'm_framed',
            sink,
            onProgress: progress.add,
            maxBytes: 1024 * 1024,
          );
          expect(sink.takeBytes(), body, reason: '$declared');
          // Progress is measured against the Content-Length: without a
          // size it would read 0 until the end.
          expect(progress, everyElement(greaterThan(0)), reason: '$declared');
          expect(progress.last, 1.0);
        }
      });
    });

    test('an upload to a host that never answers times out', () async {
      final fake = await FakeHost.start(
        onHello: (ws, _) {
          ws.add(_codec.encode(fakeWelcome(uploadKey: 'k'), seq: 0));
        },
        onMedia: (req) async {
          // Read the body, never answer.
          await req.drain<void>();
        },
      );
      final guest = await JamGuestClient.connect(
        joinUriForPort(fake.port),
        mediaTimeout: const Duration(milliseconds: 200),
      );
      addTearDown(guest.close);
      final file = await writeTempMedia(makeMediaBytes(256));
      await expectLater(
        guest
            .uploadMedia(file, kind: MediaKind.audio)
            // The test's own bound fails differently from the client's.
            .timeout(
              const Duration(seconds: 5),
              onTimeout: () => throw StateError('the upload hung'),
            ),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('the host forgives silence it caused by napping itself', () async {
      final host = await startHost(
        silenceTimeout: const Duration(seconds: 1),
        livenessCheckInterval: const Duration(milliseconds: 50),
      );
      // A raw peer that never pings: only the silence rule can drop it.
      await rawJoin(host);
      expect(host.peers, hasLength(1));

      // The host's isolate freezes (an app suspended in the background)
      // for longer than the silence timeout.
      final sw = Stopwatch()..start();
      while (sw.elapsedMilliseconds < 1500) {}

      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(
        host.peers,
        hasLength(1),
        reason: 'the gap was the host\'s own, not the guest\'s silence',
      );
      // Real silence after the nap still counts.
      await waitFor(
        () => host.peers.isEmpty,
        timeout: const Duration(seconds: 3),
        reason: 'the genuinely silent peer to be dropped',
      );
    });
  });

  group('protocol 1 version gate (§2)', () {
    test('a hello of another major version gets reject{version}, in its own '
        'v, naming ours', () async {
      final host = await startHost();
      final ws = await WebSocket.connect('ws://127.0.0.1:${host.port}/ws');
      final frames = <Map<String, Object?>>[];
      final closed = Completer<void>();
      ws.listen(
        (data) => frames.add((jsonDecode(data as String) as Map).cast()),
        onDone: closed.complete,
      );
      ws.add(
        jsonEncode({
          'v': 2,
          'type': 'hello',
          'seq': 0,
          'payload': {'credentials': 'v2-shaped'},
        }),
      );
      await closed.future.timeout(const Duration(seconds: 3));
      expect(frames, hasLength(1));
      expect(frames.single['v'], 2);
      expect(frames.single['type'], 'reject');
      expect(frames.single['payload'], {
        'reason': 'version',
        'versions': [1],
      });
      expect(host.peers, isEmpty);
    });

    test('a guest refuses a welcome in a major version it does not speak — '
        'at once, as a version reject', () async {
      final fake = await FakeHost.start(
        onHello: (ws, _) {
          ws.add(
            jsonEncode({
              'v': 2,
              'type': 'welcome',
              'seq': 0,
              'payload': {'something': 'else'},
            }),
          );
        },
      );
      final started = DateTime.now();
      await expectLater(
        JamGuestClient.connect(joinUriForPort(fake.port)),
        throwsA(
          isA<JamRejectedException>()
              .having((e) => e.reason, 'reason', RejectReason.version)
              .having((e) => e.hostVersions, 'hostVersions', contains(2)),
        ),
      );
      expect(
        DateTime.now().difference(started),
        lessThan(const Duration(seconds: 2)),
        reason: 'not the 5 s handshake timeout',
      );
    });

    test('an unknown reject reason is a prompt, final reject — not a '
        'timeout and a retry forever', () async {
      var hellos = 0;
      var welcomeNext = true;
      final fake = await FakeHost.start(
        onHello: (ws, _) {
          hellos++;
          if (welcomeNext) {
            welcomeNext = false;
            ws.add(_codec.encode(fakeWelcome(), seq: 0));
            // Then drop it, so the session has to reconnect.
            Timer(const Duration(milliseconds: 100), ws.close);
            return;
          }
          ws.add(
            jsonEncode({
              'v': 1,
              'type': 'reject',
              'seq': 0,
              'payload': {'reason': 'room_on_fire'},
            }),
          );
        },
      );
      final session = await JamGuestSession.connect(
        joinUriForPort(fake.port),
        backoff: JamBackoff(
          initialDelay: const Duration(milliseconds: 20),
          jitterRatio: 0,
        ),
      );
      addTearDown(session.close);
      await waitFor(
        () => session.connectionState == JamConnectionState.failed,
        timeout: const Duration(seconds: 3),
        reason: 'the reject to end the session',
      );
      expect(session.lastRejectReason, RejectReason.unknown);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(hellos, 2, reason: 'one join, one refused reconnect, no more');
    });
  });

  group('tolerant decoding: future 1.x peers (§2)', () {
    test('a v1.x host full of things a 1.0 guest does not know — including '
        'frames right behind the welcome, which the welcome must not '
        'overwrite', () async {
      var sentError = false;
      MediaItem item(String id) => MediaItem(
        mediaId: id,
        kind: MediaKind.audio,
        name: '$id.mp3',
        mime: 'audio/mpeg',
        sizeBytes: 10,
        sha256: '',
      );
      Map<String, Object?> itemJson(String id, String kind) => {
        ...item(id).toJson(),
        'kind': kind,
        'loudnessLufs': -14,
      };
      final fake = await FakeHost.start(
        onHello: (ws, _) {
          final welcome = fakeWelcome(playlist: [item('m_a')]).payloadToJson()
            ..['playlist'] = [
              itemJson('m_a', 'audio'),
              itemJson('m_3d', 'spatial_scene'),
            ]
            ..['snapshot'] = {
              ...PlaybackSnapshot.initial.toJson(),
              'status': 'crossfading',
              'crossfadeUs': 2000000,
            }
            ..['lobbyMusic'] = true;
          ws.add(
            jsonEncode({
              'v': 1,
              'type': 'welcome',
              'seq': 0,
              'payload': welcome,
              'trace': 'abc',
            }),
          );
          // Right behind the welcome, before the guest's handshake has even
          // returned.
          for (final frame in [
            {
              'v': 1,
              'type': 'reaction',
              'seq': 1,
              'payload': {'emoji': 'fire'},
            },
            {
              'v': 1,
              'type': 'playlist',
              'seq': 2,
              'payload': {
                'rev': 2,
                'items': [
                  itemJson('m_a', 'audio'),
                  itemJson('m_v', 'video360'),
                  itemJson('m_b', 'audio'),
                ],
                'sections': ['A'],
              },
            },
            {
              'v': 1,
              'type': 'state',
              'seq': 3,
              'payload': {
                'rev': 5,
                'status': 'buffering',
                'mediaId': 'm_b',
                'anchor': null,
                'positionUs': 42,
                'rate': 1.0,
              },
            },
            {
              'v': 1,
              'type': 'host_status',
              'seq': 4,
              'payload': {'away': true, 'battery': 0.12},
            },
          ]) {
            ws.add(jsonEncode(frame));
          }
        },
        onFrame: (ws, envelope) {
          // Later on, an error code from the future.
          if (envelope['type'] != 'clock_ping' || sentError) return;
          sentError = true;
          ws.add(
            jsonEncode({
              'v': 1,
              'type': 'error',
              'seq': 5,
              'payload': {'code': 'too_loud', 'message': 'shh', 'fatal': false},
            }),
          );
        },
      );
      final guest = await JamGuestClient.connect(joinUriForPort(fake.port));
      addTearDown(guest.close);
      final errors = <ErrorMessage>[];
      guest.errors.listen(errors.add);

      await waitFor(
        () => guest.snapshot.rev == 5 && guest.hostAway && errors.isNotEmpty,
        reason: 'the later frames',
      );
      // Unknown kinds dropped, the rest kept; the newer playlist and state
      // stand (the welcome's older ones did not clobber them).
      expect(guest.playlist.map((i) => i.mediaId), ['m_a', 'm_b']);
      expect(guest.snapshot.status, PlaybackStatus.loading);
      expect(guest.snapshot.positionUs, 42);
      expect(errors.single.code, ErrorCode.unknown);
      var done = false;
      unawaited(guest.done.then((_) => done = true));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(done, isFalse);
    });

    test('a v1.x guest full of things a 1.0 host does not know', () async {
      final host = await startHost();
      final track = await addTrack(host);
      final (ws, frames) = await rawJoin(
        host,
        extraHello: {
          'caps': ['audio', 'haptics'],
          'encodings': ['cbor', 'json'],
          'avatar': {'emoji': '🦊'},
        },
      );
      for (final frame in [
        {
          'v': 1,
          'type': 'reaction',
          'seq': 1,
          'payload': {'emoji': '🔥'},
        },
        {
          'v': 1,
          'type': 'request',
          'seq': 2,
          'payload': {'action': 'crossfade', 'mediaId': track.mediaId},
        },
        {
          'v': 1,
          'type': 'media_status',
          'seq': 3,
          'payload': {
            'mediaId': track.mediaId,
            'state': 'verifying',
            'progress': 0.99,
            'checksum': 'sha512',
          },
        },
        {
          'v': 1,
          'type': 'clock_ping',
          'seq': 4,
          'payload': {'t0': 7, 'precision': 'ns'},
        },
      ]) {
        ws.add(jsonEncode(frame));
      }
      await waitFor(
        () => frames.any((f) => f['type'] == 'clock_pong'),
        reason: 'the pong after the unknowns',
      );
      expect(host.peers, hasLength(1));
      expect(
        host.peerMediaState(host.peers.single.peerId, track.mediaId),
        MediaReadiness.none,
        reason: 'an unknown fetch state is not possession',
      );
    });
  });

  group('host away signal (§3.5)', () {
    test('announced to joined guests and carried into later welcomes; a '
        'session keeps it through a drop', () async {
      final host = await startHost(reconnectGrace: const Duration(seconds: 5));
      final guest = await joinGuest(host);
      final session = await JamGuestSession.connect(
        host.joinUriFor(InternetAddress.loopbackIPv4),
        clientId: 'c_sess',
        backoff: JamBackoff(
          initialDelay: const Duration(milliseconds: 20),
          jitterRatio: 0,
        ),
      );
      addTearDown(session.close);
      final guestChanges = <bool>[];
      guest.hostAwayChanges.listen(guestChanges.add);
      final sessionChanges = <bool>[];
      session.hostAwayChanges.listen(sessionChanges.add);
      expect(guest.hostAway, isFalse);

      await host.announceAway(true);
      expect(host.isAway, isTrue);
      await waitFor(() => guest.hostAway && session.hostAway, reason: 'away');
      expect(guestChanges, [true]);
      expect(sessionChanges, [true]);

      final late = await joinGuest(host, clientName: 'late');
      expect(late.hostAway, isTrue, reason: 'from welcome.hostAway');

      // A drop mid-nap: the session still knows the host said it was away.
      final states = <JamConnectionState>[];
      session.connectionStates.listen(states.add);
      host.kickPeer(session.selfPeerId, allowResume: true);
      await waitFor(
        () => states.contains(JamConnectionState.reconnecting),
        reason: 'the drop',
      );
      expect(session.hostAway, isTrue);
      await waitFor(
        () => session.connectionState == JamConnectionState.connected,
        reason: 'the reconnect',
      );
      expect(session.hostAway, isTrue);

      await host.announceAway(false);
      await waitFor(
        () => !guest.hostAway && !session.hostAway && !late.hostAway,
        reason: 'back',
      );
      expect(sessionChanges, [true, false]);
      // Repeats are not re-broadcast.
      await host.announceAway(false);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(guestChanges, [true, false]);
    });
  });

  group('upload credentials (§6.4)', () {
    test(
      'the token alone, a claimed peer id, or "host" never uploads',
      () async {
        final host = await startHost(); // Open policy: everyone may add.
        final guest = await joinGuest(host);
        final bytes = makeMediaBytes(300, seed: 9);

        expect(await rawUpload(host, bytes), HttpStatus.forbidden);
        expect(
          await rawUpload(
            host,
            bytes,
            headers: {'X-LocalJam-Peer-Id': JamPermissions.hostPeerId},
          ),
          HttpStatus.forbidden,
        );
        expect(
          await rawUpload(
            host,
            bytes,
            headers: {'X-LocalJam-Peer-Id': guest.selfPeerId},
          ),
          HttpStatus.forbidden,
        );
        expect(
          await rawUpload(host, bytes, uploadKey: 'not-a-key'),
          HttpStatus.forbidden,
        );
        expect(host.playlist, isEmpty);

        // The real key works, and attribution follows the key, not a claim.
        expect(
          await rawUpload(
            host,
            bytes,
            uploadKey: guest.uploadKey,
            headers: {'X-LocalJam-Peer-Id': JamPermissions.hostPeerId},
          ),
          HttpStatus.created,
        );
        expect(host.playlist.single.addedBy, guest.selfPeerId);
      },
    );

    test('a key is judged as its peer, and dies with its connection', () async {
      final host = await startHost(policy: JamPolicy.listenOnly);
      final guest = await joinGuest(host, clientId: 'c_up');
      final key = guest.uploadKey!;
      final bytes = makeMediaBytes(300, seed: 10);
      expect(
        await rawUpload(host, bytes, uploadKey: key),
        HttpStatus.forbidden,
        reason: 'listen-only: the key proves who, the policy says no',
      );
      host.setCapabilityOverride(
        guest.selfPeerId,
        JamCapability.addTracks,
        allowed: true,
      );
      expect(await rawUpload(host, bytes, uploadKey: key), HttpStatus.created);

      await guest.close();
      await waitFor(() => host.peers.isEmpty, reason: 'the guest to leave');
      expect(
        await rawUpload(host, makeMediaBytes(300, seed: 11), uploadKey: key),
        HttpStatus.forbidden,
      );
    });

    test('each join gets its own key', () async {
      final host = await startHost();
      final a = await joinGuest(host);
      final b = await joinGuest(host);
      expect(a.uploadKey, isNotNull);
      expect(a.uploadKey, isNot(b.uploadKey));
      expect(a.uploadKey, isNot(host.token));
    });
  });

  group('moderation follows the device (§5.6)', () {
    test('a co-host whose grace expired rejoins as a co-host; an override '
        'survives too', () async {
      final host = await startHost(
        silenceTimeout: const Duration(milliseconds: 300),
        reconnectGrace: const Duration(milliseconds: 200),
        livenessCheckInterval: const Duration(milliseconds: 50),
      );
      final (ws, _) = await rawJoin(host, clientId: 'c_cohost');
      final firstId = host.peers.single.peerId;
      host.promotePeer(firstId);
      host.setCapabilityOverride(
        firstId,
        JamCapability.addTracks,
        allowed: false,
      );
      await ws.close();
      // Gone, then gone for good: the grace window expires.
      await waitFor(
        () => !host.permissions.cohosts.contains(firstId),
        reason: 'the grace window to expire',
      );

      final back = await joinGuest(host, clientId: 'c_cohost');
      expect(back.selfPeerId, isNot(firstId));
      expect(host.permissions.cohosts, {back.selfPeerId});
      expect(back.permissions.cohosts, {back.selfPeerId}, reason: 'welcome');
      expect(back.myCapabilities, isNot(contains(JamCapability.addTracks)));
      expect(back.myCapabilities, contains(JamCapability.controlPlayback));
    });

    test('a co-host that supersedes its own ghost keeps the role', () async {
      final host = await startHost();
      final (_, _) = await rawJoin(host, clientId: 'c_phone');
      host.promotePeer(host.peers.single.peerId);
      final back = await joinGuest(host, clientId: 'c_phone');
      expect(host.peers.map((p) => p.peerId), [back.selfPeerId]);
      expect(host.permissions.cohosts, {back.selfPeerId});
    });

    test('demoting is remembered as well', () async {
      final host = await startHost();
      final first = await joinGuest(host, clientId: 'c_x');
      host.promotePeer(first.selfPeerId);
      host.demotePeer(first.selfPeerId);
      final back = await joinGuest(host, clientId: 'c_x');
      expect(host.permissions.cohosts, isEmpty);
      expect(back.permissions.cohosts, isEmpty);
    });
  });

  group('upload validation (§6.4)', () {
    test('zero, negative and absurd declared durations are unknown, and do '
        'not end (or break) the track', () async {
      final host = await startHost(
        livenessCheckInterval: const Duration(milliseconds: 50),
      );
      final guest = await joinGuest(host);
      final ended = <JamHostEvent>[];
      host.events
          .where((e) => e.kind == JamHostEventKind.mediaEnded)
          .listen(ended.add);
      var seed = 20;
      for (final bogus in [0, -5, JamHostServer.maxPlausibleDurationUs + 1]) {
        final item = await guest.uploadMedia(
          await writeTempMedia(makeMediaBytes(200, seed: seed++)),
          kind: MediaKind.audio,
          durationUs: bogus,
        );
        expect(item.durationUs, isNull, reason: '$bogus');
        host.setMedia(item.mediaId);
        host.play();
        expect(() => host.seek(1000000), returnsNormally);
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(ended, isEmpty, reason: 'no end-of-media storm');
      expect(JamHostServer.plausibleDurationUs(180000000), 180000000);
    });

    test('oversized cover art is dropped, the track kept', () async {
      final host = await startHost(maxArtworkBytes: 16);
      final guest = await joinGuest(host);
      final item = await guest.uploadMedia(
        await makeTaggedMp3(),
        kind: MediaKind.audio,
      );
      expect(item.title, 'Night Drive');
      expect(item.artworkId, isNull);
    });
  });

  group('upload directory hygiene', () {
    Future<Directory> fakeUploadDir(
      Directory parent,
      String name, {
      String? owner,
    }) async {
      final dir = Directory('${parent.path}/$name');
      await dir.create();
      await File('${dir.path}/m_leftover').writeAsBytes([1, 2, 3]);
      if (owner != null) {
        final lock = File('${dir.path}/.localjam.lock');
        await lock.writeAsString(owner);
        // Old enough to be judged: a fresh lock file may belong to a host
        // that is still starting up.
        await lock.setLastModified(
          DateTime.now().subtract(const Duration(minutes: 5)),
        );
      }
      return dir;
    }

    test('leaked dirs of dead processes are swept; live and foreign ones '
        'are not', () async {
      final parent = await Directory.systemTemp.createTemp('localjam_sweep');
      addTearDown(() => parent.delete(recursive: true));
      final dead = await fakeUploadDir(
        parent,
        'localjam_upload_dead',
        owner: '999999999',
      );
      final ours = await fakeUploadDir(
        parent,
        'localjam_upload_ours',
        owner: '$pid',
      );
      final fresh = await fakeUploadDir(parent, 'localjam_upload_unlocked');
      final starting = await fakeUploadDir(
        parent,
        'localjam_upload_starting',
        owner: '999999998',
      );
      await File(
        '${starting.path}/.localjam.lock',
      ).setLastModified(DateTime.now());
      final foreign = await fakeUploadDir(
        parent,
        'not_localjam',
        owner: '999999999',
      );

      expect(await JamHostServer.sweepStaleUploadDirs(parent: parent), 1);
      expect(dead.existsSync(), isFalse);
      expect(ours.existsSync(), isTrue, reason: 'this process: maybe live');
      expect(fresh.existsSync(), isTrue, reason: 'too new to judge');
      expect(starting.existsSync(), isTrue, reason: 'lock file too new');
      expect(foreign.existsSync(), isTrue);
    });

    test('start() sweeps the system temp dir and keeps live rooms', () async {
      final live = await startHost();
      final dead = await fakeUploadDir(
        Directory.systemTemp,
        'localjam_upload_test_dead_${DateTime.now().microsecondsSinceEpoch}',
        owner: '999999999',
      );
      addTearDown(() async {
        if (dead.existsSync()) await dead.delete(recursive: true);
      });
      await startHost();
      await waitFor(() => !dead.existsSync(), reason: 'the sweep');
      // The live room in this process still has its uploads.
      final guest = await joinGuest(live);
      await guest.uploadMedia(
        await writeTempMedia(makeMediaBytes(100, seed: 30)),
        kind: MediaKind.audio,
      );
      expect(live.playlist, hasLength(1));
    });
  });

  group('no WebSocket compression (§9.1)', () {
    test('the host never negotiates permessage-deflate', () async {
      final host = await startHost();
      final http = HttpClient();
      addTearDown(() => http.close(force: true));
      final req = await http.getUrl(
        Uri.parse('http://127.0.0.1:${host.port}/ws'),
      );
      req.headers
        ..set(HttpHeaders.connectionHeader, 'Upgrade')
        ..set(HttpHeaders.upgradeHeader, 'websocket')
        ..set('Sec-WebSocket-Version', '13')
        ..set(
          'Sec-WebSocket-Key',
          base64.encode(List<int>.generate(16, (i) => i)),
        )
        ..set(
          'Sec-WebSocket-Extensions',
          'permessage-deflate; client_max_window_bits',
        );
      final res = await req.close();
      expect(res.statusCode, HttpStatus.switchingProtocols);
      expect(res.headers.value('sec-websocket-extensions'), isNull);
      (await res.detachSocket()).destroy();
    });

    test('the guest never offers it', () async {
      String? offered = 'unset';
      final fake = await FakeHost.start(
        onUpgrade: (req) =>
            offered = req.headers.value('sec-websocket-extensions'),
        onHello: (ws, _) => ws.add(_codec.encode(fakeWelcome(), seq: 0)),
      );
      final guest = await JamGuestClient.connect(joinUriForPort(fake.port));
      addTearDown(guest.close);
      expect(offered, isNull);
    });
  });

  group('listener health', () {
    test('selfProbe and listenerDone notice a listener that died under a '
        'live room', () async {
      final host = await startHost();
      final guest = await joinGuest(host);
      expect(host.isListening, isTrue);
      expect(await host.selfProbe(), isTrue);

      await host.debugKillListener();
      final failure = await host.listenerDone.timeout(
        const Duration(seconds: 2),
      );
      expect(failure, isNotNull);
      expect(host.isListening, isFalse);
      expect(await host.selfProbe(), isFalse);
      // Joined guests keep their own sockets.
      expect(host.peers.single.peerId, guest.selfPeerId);
    });

    test('restartListener reopens the same port and keeps the room', () async {
      final host = await startHost();
      final track = await addTrack(host);
      final before = await joinGuest(host, clientName: 'before');
      final token = host.token;
      final port = host.port;

      await host.debugKillListener();
      await host.listenerDone.timeout(const Duration(seconds: 2));
      expect(await host.selfProbe(), isFalse);

      await host.restartListener();
      expect(host.port, port);
      expect(host.isListening, isTrue);
      expect(await host.selfProbe(), isTrue);

      // The same join link still works, and the room is the same room.
      final after = await joinGuest(host, clientName: 'after');
      expect(host.token, token);
      expect(after.playlist.map((i) => i.mediaId), [track.mediaId]);
      expect(host.peers.map((p) => p.clientName), {'before', 'after'});
      expect(after.peers.map((p) => p.peerId), [before.selfPeerId]);
    });

    test('a deliberate close completes listenerDone with null', () async {
      final host = JamHostServer(sessionName: 'x');
      await host.start();
      await host.close();
      expect(await host.listenerDone, isNull);
      expect(await host.selfProbe(), isFalse);
    });

    test('concurrent restartListener calls share one restart', () async {
      // Review 2026-10-17 (N1): an app resume hook and a listenerDone
      // watcher both restarting raced each other for the port, and one of
      // them threw.
      final host = await startHost();
      final port = host.port;
      await host.debugKillListener();
      final results = await Future.wait([
        for (var i = 0; i < 3; i++)
          host.restartListener().then((_) => 'ok', onError: (Object e) => '$e'),
      ]);
      expect(results, everyElement('ok'));
      expect(host.port, port);
      expect(await host.selfProbe(), isTrue);
    });

    test('restartListener(address:) moves the room, same port and token, '
        'joined guests kept', () async {
      if (!await _canBind(InternetAddress.loopbackIPv6)) {
        markTestSkipped('no IPv6 loopback here');
        return;
      }
      final host = await startHost();
      final track = await addTrack(host);
      final before = await joinGuest(host, clientName: 'before');
      final port = host.port;
      final token = host.token;

      await host.restartListener(address: InternetAddress.loopbackIPv6);
      expect(host.port, port);
      expect(host.token, token);
      expect(await host.selfProbe(), isTrue);
      final after = await JamGuestClient.connect(
        host.joinUriFor(InternetAddress.loopbackIPv6),
        clientName: 'after',
      );
      addTearDown(after.close);
      expect(after.playlist.map((i) => i.mediaId), [track.mediaId]);
      expect(host.peers.map((p) => p.clientName), {'before', 'after'});
      expect(after.peers.map((p) => p.peerId), [before.selfPeerId]);
      // The old address no longer answers.
      await expectLater(
        Socket.connect(InternetAddress.loopbackIPv4, port),
        throwsA(isA<SocketException>()),
      );

      // Moving onto an address that overlaps the current binding (any vs.
      // a specific one) works too: closed first, then bound.
      await host.restartListener(address: InternetAddress.anyIPv6);
      expect(host.port, port);
      expect(await host.selfProbe(), isTrue);
    });

    test('a move whose port is taken fails and stays put — unless a new '
        'port is allowed', () async {
      if (!await _canBind(InternetAddress.loopbackIPv6)) {
        markTestSkipped('no IPv6 loopback here');
        return;
      }
      final host = await startHost();
      final port = host.port;
      final squatter = await ServerSocket.bind(
        InternetAddress.loopbackIPv6,
        port,
      );
      addTearDown(squatter.close);

      await expectLater(
        host.restartListener(address: InternetAddress.loopbackIPv6),
        throwsA(isA<SocketException>()),
      );
      expect(host.port, port);
      expect(host.isListening, isTrue);
      expect(await host.selfProbe(), isTrue, reason: 'still where it was');

      await host.restartListener(
        address: InternetAddress.loopbackIPv6,
        allowNewPort: true,
      );
      expect(host.port, isNot(port));
      expect(await host.selfProbe(), isTrue);
      expect(
        host.joinUriFor(InternetAddress.loopbackIPv6).queryParameters['port'],
        '${host.port}',
      );
      final guest = await JamGuestClient.connect(
        host.joinUriFor(InternetAddress.loopbackIPv6),
      );
      addTearDown(guest.close);
      expect(host.peers, hasLength(1));
    });
  });

  group('a guest that notices the drop first resumes (§3.3)', () {
    // Review 2026-10-17 (S2): the guest's watchdog (3 pings, 6 s) fires
    // before the host's silence timeout (10 s), so the guest is back while
    // its old socket is still "live" on the host. That used to supersede it
    // with a fresh peerId — losing its role and its own tracks (§5.6).
    // Scaled down: guest liveness 500 ms, host silence 1500 ms (and 300 ms,
    // where the host notices first, as the control).
    for (final silenceMs in [1500, 300]) {
      test('host silence ${silenceMs}ms: same peerId, own track still '
          'removable', () async {
        final host = await startHost(
          // Guests may add tracks but not edit the queue: own-removal only.
          policy: const JamPolicy(
            addTracks: true,
            controlPlayback: false,
            editQueue: false,
          ),
          silenceTimeout: Duration(milliseconds: silenceMs),
          livenessCheckInterval: const Duration(milliseconds: 50),
        );
        final proxy = await BlackholeProxy.start(host.port);
        final uri = host.joinUriFor(InternetAddress.loopbackIPv4);
        final session = await JamGuestSession.connect(
          uri.replace(
            queryParameters: {...uri.queryParameters, 'port': '${proxy.port}'},
          ),
          clientId: 'c_dark',
          pingInterval: const Duration(milliseconds: 100),
          livenessTimeout: const Duration(milliseconds: 500),
          backoff: JamBackoff(
            initialDelay: const Duration(milliseconds: 20),
            jitterRatio: 0,
          ),
        );
        addTearDown(session.close);
        final before = session.selfPeerId;
        final file = await writeTempMedia(makeMediaBytes(2048, seed: 9));
        final item = await session.uploadMedia(file, kind: MediaKind.audio);
        expect(item.addedBy, before);

        proxy.blackhole();
        await waitFor(
          () => session.connectionState == JamConnectionState.reconnecting,
          timeout: const Duration(seconds: 3),
          reason: 'the watchdog',
        );
        await waitFor(
          () => session.connectionState == JamConnectionState.connected,
          reason: 'the reconnect',
        );
        expect(session.selfPeerId, before);
        expect(host.peers.map((p) => p.peerId), [before]);

        final errors = <ErrorCode>[];
        session.errors.listen((e) => errors.add(e.code));
        await session.requestQueueRemove(item.mediaId);
        await waitFor(() => host.playlist.isEmpty, reason: 'own track removed');
        expect(errors, isEmpty);
      });
    }

    test('a hello naming another peerId still supersedes (one device, one '
        'peer)', () async {
      final host = await startHost();
      final (_, frames) = await rawJoin(host, clientId: 'dev');
      final first =
          ((frames.firstWhere((f) => f['type'] == 'welcome')['payload']
                      as Map)['you']
                  as Map)['peerId']
              as String;
      final (_, frames2) = await rawJoin(
        host,
        clientId: 'dev',
        extraHello: {'resumePeerId': 'p_999'},
      );
      final second =
          ((frames2.firstWhere((f) => f['type'] == 'welcome')['payload']
                      as Map)['you']
                  as Map)['peerId']
              as String;
      expect(second, isNot(first));
      expect(host.peers.map((p) => p.peerId), [second]);
    });
  });

  group('clock burst (§4)', () {
    /// A fake host that answers every ping, recording when each arrived.
    Future<(FakeHost, List<int>)> pingRecorder() async {
      final arrivals = <int>[];
      final clock = Stopwatch()..start();
      final fake = await FakeHost.start(
        onHello: (ws, _) => ws.add(_codec.encode(fakeWelcome(), seq: 0)),
        onFrame: (ws, envelope) {
          if (envelope['type'] != 'clock_ping') return;
          arrivals.add(clock.elapsedMicroseconds);
          final t0 = (envelope['payload'] as Map)['t0'] as int;
          final now = monotonicNowUs();
          ws.add(
            _codec.encode(ClockPongMessage(t0: t0, t1: now, t2: now), seq: 0),
          );
        },
      );
      return (fake, arrivals);
    }

    test('the join burst is 8 pings spread ~100 ms apart', () async {
      // Clock handoff C2: back-to-back pings share one radio wake-up and
      // one queue, so the min-RTT filter got eight copies of one sample.
      final (fake, arrivals) = await pingRecorder();
      final guest = await JamGuestClient.connect(
        joinUriForPort(fake.port),
        pingInterval: const Duration(seconds: 30),
      );
      addTearDown(guest.close);
      await waitFor(() => arrivals.length >= 8, reason: 'the burst');
      final gaps = [for (var i = 1; i < 8; i++) arrivals[i] - arrivals[i - 1]];
      expect(gaps, everyElement(greaterThan(60000)));
      expect(arrivals[7] - arrivals[0], greaterThan(600000));
      expect(guest.clock.isSynchronized, isTrue);
    });

    test('resyncClock sends a fresh burst, from the client and the '
        'session', () async {
      final (fake, arrivals) = await pingRecorder();
      final session = await JamGuestSession.connect(
        joinUriForPort(fake.port),
        pingInterval: const Duration(seconds: 30),
      );
      addTearDown(session.close);
      await waitFor(() => arrivals.length >= 8, reason: 'the join burst');
      await Future<void>.delayed(const Duration(milliseconds: 150));
      final joinBurst = arrivals.length;
      expect(joinBurst, 8, reason: 'nothing more until asked');
      session.resyncClock();
      await waitFor(
        () => arrivals.length >= joinBurst + 8,
        reason: 'the fresh burst',
      );
      expect(arrivals.last - arrivals[joinBurst], greaterThan(600000));
    });

    test('a clock discontinuity triggers a fresh burst by itself', () async {
      // ClockSync resets on a confirmed jump (§4: a device sleep, a
      // stepped clock); re-gathering samples at the steady 1 s cadence
      // would leave the guest unsynchronized for seconds.
      var shiftUs = 0;
      final fake = await FakeHost.start(
        onHello: (ws, _) => ws.add(_codec.encode(fakeWelcome(), seq: 0)),
        onFrame: (ws, envelope) {
          if (envelope['type'] != 'clock_ping') return;
          final t0 = (envelope['payload'] as Map)['t0'] as int;
          final now = monotonicNowUs() + shiftUs;
          ws.add(
            _codec.encode(ClockPongMessage(t0: t0, t1: now, t2: now), seq: 0),
          );
        },
      );
      final guest = await JamGuestClient.connect(
        joinUriForPort(fake.port),
        pingInterval: const Duration(seconds: 1),
      );
      addTearDown(guest.close);
      await waitFor(() => guest.clock.isSynchronized, reason: 'first sync');
      await Future<void>.delayed(const Duration(milliseconds: 800));
      shiftUs = 5000000; // The host clock "jumps" 5 s.
      await waitFor(
        () => !guest.clock.isSynchronized,
        reason: 'the discontinuity reset',
      );
      final reset = DateTime.now();
      await waitFor(() => guest.clock.isSynchronized, reason: 're-sync');
      expect(
        DateTime.now().difference(reset),
        lessThan(const Duration(milliseconds: 900)),
        reason: 'a burst, not four steady pings',
      );
      expect(guest.clock.offsetUs, closeTo(5000000, 50000));
    });

    test('an injected local clock is the t0/t3 timebase', () async {
      // Clock handoff C3: two CLI guests on one machine can show skew.
      const skewUs = 1000000000000; // ~11.5 days ahead.
      final host = await startHost();
      final guest = await JamGuestClient.connect(
        host.joinUriFor(InternetAddress.loopbackIPv4),
        localClockUs: () => monotonicNowUs() + skewUs,
      );
      addTearDown(guest.close);
      expect(guest.localNowUs - monotonicNowUs(), closeTo(skewUs, 1000000));
      await waitFor(() => guest.clock.isSynchronized, reason: 'sync');
      expect(guest.clock.offsetUs, closeTo(-skewUs, 50000));
      // The session clock is the host's: here, this process's monotonic.
      expect(guest.sessionNowUs - monotonicNowUs(), closeTo(0, 50000));
    });
  });

  group('kicked-device list changes (§5.6)', () {
    test('kicks and unkicks are announced on kickedPeersChanges', () async {
      final host = await startHost();
      final changes = <List<String>>[];
      host.kickedPeersChanges.listen(
        (list) => changes.add([for (final p in list) p.peerId]),
      );
      final guest = await joinGuest(host, clientId: 'kick-me');
      final other = await joinGuest(host, clientId: 'stay');
      host.kickPeer(other.selfPeerId, allowResume: true); // Not a kick.
      host.kickPeer(guest.selfPeerId);
      await waitFor(() => changes.isNotEmpty, reason: 'the kick');
      expect(changes, [
        [guest.selfPeerId],
      ]);
      expect(host.unkickPeer(guest.selfPeerId), isTrue);
      await waitFor(() => changes.length == 2, reason: 'the unkick');
      expect(changes.last, isEmpty);
      expect(host.unkickPeer(guest.selfPeerId), isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(changes, hasLength(2));
    });
  });

  group('who a kick keeps out (§5.6)', () {
    test('a device that sent a clientId is held, and kickKeepsOut says so '
        'before the kick', () async {
      final host = await startHost();
      final guest = await joinGuest(host, clientId: 'phone-1');
      expect(host.kickKeepsOut(guest.selfPeerId), isTrue);
      host.kickPeer(guest.selfPeerId);
      await waitFor(() => host.peers.isEmpty, reason: 'the kick');
      await expectLater(
        joinGuest(host, clientId: 'phone-1'),
        throwsA(
          isA<JamRejectedException>().having(
            (e) => e.reason,
            'reason',
            RejectReason.kicked,
          ),
        ),
      );
    });

    test('a device that sent none cannot be recognised: kickKeepsOut is '
        'false, and it can join again', () async {
      final host = await startHost();
      final guest = await joinGuest(host); // No clientId.
      expect(host.kickKeepsOut(guest.selfPeerId), isFalse);
      host.kickPeer(guest.selfPeerId);
      await waitFor(() => host.peers.isEmpty, reason: 'the kick');
      expect(host.kickedPeers, isEmpty, reason: 'nothing to hold it by');
      final back = await joinGuest(host);
      expect(host.peers.single.peerId, back.selfPeerId);
    });

    test('kickKeepsOut is false for a peer that is not joined', () async {
      final host = await startHost();
      expect(host.kickKeepsOut('nobody'), isFalse);
    });
  });

  group('end of media on time (§5.5)', () {
    test('the end policy runs at the end instant, not on the next liveness '
        'tick', () async {
      // Track transitions used to wait for the 1 Hz tick on top of the
      // start lead: up to 1.75 s of dead air. Now the gap is the lead.
      final host = await startHost(
        endPolicy: JamEndPolicy.advance,
        livenessCheckInterval: const Duration(seconds: 5),
        readinessWait: Duration.zero,
      );
      final a = await addTrack(host, seed: 1, durationUs: 300000);
      final b = await addTrack(host, seed: 2, durationUs: 300000);
      final endedAt = <int>[];
      host.events
          .where((e) => e.kind == JamHostEventKind.mediaEnded)
          .listen((_) => endedAt.add(monotonicNowUs()));
      host.setMedia(a.mediaId);
      host.play();
      final endAtUs = host.snapshot.anchor!.hostTimeUs + 300000;
      await waitFor(() => endedAt.isNotEmpty, reason: 'the end of a');
      expect(endedAt.single - endAtUs, inInclusiveRange(0, 150000));
      expect(host.snapshot.mediaId, b.mediaId);
      expect(host.snapshot.status, PlaybackStatus.playing);
      // And b's end, as promptly, exactly once.
      final bEndUs = host.snapshot.anchor!.hostTimeUs + 300000;
      await waitFor(() => endedAt.length == 2, reason: 'the end of b');
      expect(endedAt[1] - bEndUs, inInclusiveRange(0, 150000));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(host.snapshot.mediaId, a.mediaId, reason: 'wrapped');
    });

    test('a paused room sought to the end moves on under advance, but does '
        'not start playing', () async {
      // Review 2026-10-17 (N3): the end policy ran on a paused room the
      // same as on a playing one — set the next item, then play() — so a
      // scrub to the end of a paused track started the room playing.
      final host = await startHost(
        endPolicy: JamEndPolicy.advance,
        livenessCheckInterval: const Duration(milliseconds: 50),
        readinessWait: Duration.zero,
      );
      final a = await addTrack(host, seed: 1, durationUs: 60 * 1000000);
      final b = await addTrack(host, seed: 2, durationUs: 60 * 1000000);
      final ended = <String?>[];
      host.events
          .where((e) => e.kind == JamHostEventKind.mediaEnded)
          .listen((e) => ended.add(e.mediaId));
      host.setMedia(a.mediaId);
      host.play();
      host.pause();
      host.seek(60 * 1000000);
      await waitFor(() => ended.isNotEmpty, reason: 'the end of a');
      expect(ended.single, a.mediaId);
      expect(host.snapshot.mediaId, b.mediaId);
      expect(host.snapshot.status, isNot(PlaybackStatus.playing));
      expect(host.snapshot.anchor, isNull);
      // And it stays that way: nothing else ends, nothing starts.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(ended, hasLength(1));
      expect(host.snapshot.status, isNot(PlaybackStatus.playing));
    });
  });

  group('host-reported end of media (§5.5)', () {
    test('an item with no duration advances when the host player finishes '
        'it', () async {
      final host = await startHost(endPolicy: JamEndPolicy.advance);
      final a = await addTrack(host, seed: 1); // No durationUs.
      final b = await addTrack(host, seed: 2);
      final ended = <String?>[];
      host.events
          .where((e) => e.kind == JamHostEventKind.mediaEnded)
          .listen((e) => ended.add(e.mediaId));
      host.setMedia(a.mediaId);
      host.play();
      final rev = host.snapshot.rev;
      // Before the scheduled start nothing has played: ignored.
      host.reportHostPlaybackFinished(a.mediaId, snapshotRev: rev);
      expect(host.snapshot.mediaId, a.mediaId);
      await Future<void>.delayed(const Duration(milliseconds: 800));

      host.reportHostPlaybackFinished(b.mediaId); // Not the current item.
      host.reportHostPlaybackFinished(a.mediaId, snapshotRev: rev - 1);
      expect(host.snapshot.mediaId, a.mediaId, reason: 'stale/wrong: ignored');

      host.reportHostPlaybackFinished(a.mediaId, snapshotRev: rev);
      await Future<void>.delayed(Duration.zero);
      expect(ended, [a.mediaId]);
      expect(host.snapshot.mediaId, b.mediaId);
      expect(host.snapshot.status, PlaybackStatus.playing);
    });

    test(
      'with a known duration it is only a cross-check near the end',
      () async {
        final host = await startHost(endPolicy: JamEndPolicy.stop);
        final a = await addTrack(host, durationUs: 60 * 1000000);
        host.setMedia(a.mediaId);
        host.play();
        await Future<void>.delayed(const Duration(milliseconds: 800));
        host.reportHostPlaybackFinished(a.mediaId);
        expect(
          host.snapshot.status,
          PlaybackStatus.playing,
          reason: '59 s early is a glitch, not an end',
        );
        host.seek(58 * 1000000);
        await Future<void>.delayed(const Duration(milliseconds: 800));
        host.reportHostPlaybackFinished(a.mediaId);
        expect(host.snapshot.status, PlaybackStatus.idle);
      },
    );

    test('ignored while paused', () async {
      final host = await startHost();
      final a = await addTrack(host);
      host.setMedia(a.mediaId);
      host.play();
      await Future<void>.delayed(const Duration(milliseconds: 800));
      host.pause();
      final rev = host.snapshot.rev;
      host.reportHostPlaybackFinished(a.mediaId);
      expect(host.snapshot.rev, rev);
    });
  });

  group('readiness gate (§6.3)', () {
    test('a new track waits for a guest mid-transfer, and starts the moment '
        'it is ready', () async {
      final host = await startHost(readinessWait: const Duration(seconds: 3));
      final a = await addTrack(host, seed: 1);
      final b = await addTrack(host, seed: 2);
      final guest = await joinGuest(host);
      final states = <PlaybackSnapshot>[];
      guest.states.listen(states.add);
      guest.sendMediaStatus(b.mediaId, MediaFetchState.fetching, progress: .5);
      await waitFor(
        () =>
            host.peerMediaState(guest.selfPeerId, b.mediaId) ==
            MediaReadiness.fetching,
        reason: 'the fetching report',
      );

      host.setMedia(b.mediaId);
      host.play();
      expect(host.snapshot.status, PlaybackStatus.loading);
      expect(host.isAwaitingReadiness, isTrue);

      final readyAt = DateTime.now();
      guest.sendMediaStatus(b.mediaId, MediaFetchState.ready);
      await waitFor(
        () => host.snapshot.status == PlaybackStatus.playing,
        reason: 'the start',
      );
      expect(
        DateTime.now().difference(readyAt),
        lessThan(const Duration(seconds: 1)),
      );
      expect(host.isAwaitingReadiness, isFalse);
      await waitFor(
        () => states.isNotEmpty && states.last.status == PlaybackStatus.playing,
        reason: 'the guest to see it',
      );
      expect(a.mediaId, isNot(b.mediaId));
    });

    test('a stalled guest costs at most readinessWait', () async {
      final host = await startHost(
        readinessWait: const Duration(milliseconds: 300),
      );
      final a = await addTrack(host);
      final guest = await joinGuest(host);
      guest.sendMediaStatus(a.mediaId, MediaFetchState.fetching, progress: .1);
      await waitFor(
        () => host
            .peerMediaStates(a.mediaId)
            .values
            .contains(MediaReadiness.fetching),
        reason: 'the report',
      );
      host.setMedia(a.mediaId);
      host.play();
      expect(host.snapshot.status, PlaybackStatus.loading);
      await waitFor(
        () => host.snapshot.status == PlaybackStatus.playing,
        timeout: const Duration(seconds: 2),
        reason: 'the timeout to release the start',
      );
    });

    test('guests that never reported, gave up, or hold the file are never '
        'waited for', () async {
      final host = await startHost(readinessWait: const Duration(seconds: 5));
      final a = await addTrack(host);
      final quiet = await joinGuest(host);
      final gaveUp = await joinGuest(host);
      gaveUp.sendMediaStatus(a.mediaId, MediaFetchState.none);
      await waitFor(
        () => host.peerMediaStates(a.mediaId).length == 2,
        reason: 'both peers known',
      );
      host.setMedia(a.mediaId);
      host.play();
      expect(host.snapshot.status, PlaybackStatus.playing);
      expect(quiet.selfPeerId, isNotEmpty);
    });

    test('the fetching guest leaving releases the start; pause cancels it; '
        'a skip keeps the intent to play', () async {
      final host = await startHost(readinessWait: const Duration(seconds: 5));
      final a = await addTrack(host, seed: 1);
      final b = await addTrack(host, seed: 2);
      final leaver = await joinGuest(host);
      leaver.sendMediaStatus(a.mediaId, MediaFetchState.fetching);
      leaver.sendMediaStatus(b.mediaId, MediaFetchState.fetching);
      await waitFor(
        () => host
            .peerMediaStates(b.mediaId)
            .values
            .contains(MediaReadiness.fetching),
        reason: 'reports',
      );

      host.setMedia(a.mediaId);
      host.play();
      expect(host.isAwaitingReadiness, isTrue);
      host.pause();
      expect(host.isAwaitingReadiness, isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(host.snapshot.status, PlaybackStatus.loading);

      host.play();
      expect(host.isAwaitingReadiness, isTrue);
      host.next(); // Skipping during the wait still means "play".
      expect(host.snapshot.mediaId, b.mediaId);
      expect(host.isAwaitingReadiness, isTrue);

      await leaver.close();
      await waitFor(
        () => host.snapshot.status == PlaybackStatus.playing,
        reason: 'the leave to release the start',
      );
      expect(host.snapshot.mediaId, b.mediaId);
    });
  });
}

Future<bool> _canBind(InternetAddress address) async {
  try {
    final socket = await ServerSocket.bind(address, 0);
    await socket.close();
    return true;
  } on SocketException {
    return false;
  }
}

/// A [JamMediaSink] that records what the guest asks of it and fails where
/// it is told to, the way a native file sink does on a full disk.
class _ScriptedSink extends JamMediaSink {
  _ScriptedSink({this.failOpen = false, this.failClose = false});

  final bool failOpen;
  final bool failClose;
  final List<String> calls = [];

  @override
  Future<void> open() async {
    calls.add('open');
    if (failOpen) throw const FileSystemException('cannot open');
  }

  @override
  void add(List<int> chunk) {
    if (calls.last != 'add') calls.add('add');
  }

  @override
  Future<void> close() async {
    calls.add('close');
    if (failClose) throw const FileSystemException('no space left');
  }

  @override
  Future<void> abandon() async => calls.add('abandon');
}
