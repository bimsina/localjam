/// The guest in a browser: `package:localjam_net/guest.dart` compiles for
/// the web, and its `package:web` transport (WebSocket + fetch) does what
/// the `dart:io` one does against a real host (PROTOCOL.md §1, §3.1, §4,
/// §6.2–§6.5). The host runs in the VM next to the browser
/// (`web_smoke_host.dart`, via `spawnHybridUri`).
///
/// Browser only:
///
///     dart test -p chrome test/web_smoke_test.dart
///
/// The page the test runner serves is not the host's origin, as the real
/// listener page is (docs/design/WEB_GUEST.md D2), so `dart_test.yaml`
/// launches Chrome with `--disable-web-security`: the host sends no CORS
/// headers and needs none for its own page.
@TestOn('browser')
@Tags(['web'])
library;

import 'dart:async';

import 'package:crypto/crypto.dart';
import 'package:localjam_net/guest.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';

void main() {
  test('an unreachable host fails with JamTransportException, '
      'within the connect bound', () async {
    final watch = Stopwatch()..start();
    await expectLater(
      JamGuestClient.connect(
        Uri.parse('localjam://join?v=1&token=t&host=127.0.0.1&port=1'),
        connectTimeout: const Duration(seconds: 5),
      ),
      throwsA(isA<JamTransportException>()),
    );
    expect(watch.elapsed, lessThan(const Duration(seconds: 6)));
  });

  group('against a real host', () {
    late _HostChannel channel;
    late Map<String, Object?> info;

    setUpAll(() async {
      channel = _HostChannel(spawnHybridUri('web_smoke_host.dart'));
      info = ((await channel.next())! as Map).cast<String, Object?>();
    });

    test('a host that never answers the upgrade fails the join after '
        'connectTimeout, as a JamTransportException', () async {
      final watch = Stopwatch()..start();
      await expectLater(
        JamGuestClient.connect(
          Uri.parse(
            'localjam://join?v=1&token=t&host=127.0.0.1'
            // Numbers cross the hybrid channel as JSON (doubles under wasm).
            '&port=${(info['silentPort']! as num).toInt()}',
          ),
          connectTimeout: const Duration(seconds: 1),
        ),
        throwsA(
          isA<JamTransportException>().having(
            (e) => e.cause,
            'cause',
            isA<TimeoutException>(),
          ),
        ),
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
    });

    test('joins, syncs its clock, fetches media and artwork, uploads, '
        'and sees refusals as JamHttpStatusException', () async {
      final guest = await JamGuestClient.connect(
        Uri.parse(info['joinUri']! as String),
        clientName: 'browser',
        clientKind: 'web',
      );
      addTearDown(guest.close);
      expect(guest.sessionName, 'WebSmoke');
      final mediaId = info['mediaId']! as String;
      expect(guest.playlist.map((i) => i.mediaId), [mediaId]);

      // §4: the join burst lands within a second on loopback.
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (!guest.clock.isSynchronized) {
        if (DateTime.now().isAfter(deadline)) fail('clock never synced');
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      // §6.2: the whole body, verified, with progress; §6.3: `ready`.
      final progress = <double>[];
      final bytes = await guest.fetchMedia(mediaId, onProgress: progress.add);
      expect(bytes.length, info['sizeBytes']);
      expect(sha256.convert(bytes).toString(), info['sha256']);
      expect(progress.length, greaterThan(2));
      expect(progress.last, 1.0);
      var ready = false;
      for (var i = 0; i < 50 && !ready; i++) {
        channel.send(['ready', mediaId]);
        ready = (await channel.next())! as bool;
        if (!ready) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      }
      expect(ready, isTrue, reason: 'host recorded media_status ready');

      // §6.5: artwork, and a refused request's status.
      final art = await guest.fetchArtwork(info['artworkId']! as String);
      expect(art.length, info['artworkBytes']);
      await expectLater(
        guest.fetchArtwork('a_000000000000'),
        throwsA(
          isA<JamHttpStatusException>().having(
            (e) => e.statusCode,
            'statusCode',
            404,
          ),
        ),
      );

      // Several fetches at once share the connection bound (§6.2) and all
      // complete.
      final many = await Future.wait([
        for (var i = 0; i < JamGuestClient.maxConnectionsToHost * 2; i++)
          guest.fetchArtwork(info['artworkId']! as String),
      ]);
      expect(many.every((a) => a.length == info['artworkBytes']), isTrue);

      // §6.4: an upload from bytes (the browser's file picker case).
      final upload = List<int>.generate(48 * 1024, (i) => (i * 31) & 0xff);
      final uploadProgress = <double>[];
      final added = await guest.uploadMediaStream(
        Stream.value(upload),
        length: upload.length,
        name: 'from the browser.bin',
        kind: MediaKind.audio,
        onProgress: uploadProgress.add,
      );
      expect(added.sha256, sha256.convert(upload).toString());
      expect(added.name, 'from the browser.bin');
      expect(uploadProgress.last, 1.0);
      channel.send(['playlist']);
      expect(await channel.next(), contains(added.mediaId));

      // An id that is not in the playlist never reaches the network.
      await expectLater(
        guest.fetchMedia('m_nope'),
        throwsA(isA<ArgumentError>()),
      );

      await guest.close();
      await guest.done.timeout(const Duration(seconds: 2));
    });

    test('the ping schedule and the liveness watchdog tick from the '
        'worker, not from page timers a hidden tab throttles (§3.3)', () async {
      expect(JamTicker.usesWorker, isTrue);
      // Every Timer.periodic the guest makes goes through this zone: none
      // may, or a background tab would ping once a minute.
      var pagePeriodic = 0;
      var clockReads = 0;
      final guest = await runZoned(
        () => JamGuestClient.connect(
          Uri.parse(info['joinUri']! as String),
          clientName: 'browser ticker',
          clientKind: 'web',
          pingInterval: const Duration(milliseconds: 200),
          // t0 of every ping and t3 of every frame (§4): counts the pings.
          localClockUs: () {
            clockReads++;
            return monotonicNowUs();
          },
        ),
        zoneSpecification: ZoneSpecification(
          createPeriodicTimer: (self, parent, zone, period, f) {
            pagePeriodic++;
            return parent.createPeriodicTimer(zone, period, f);
          },
        ),
      );
      addTearDown(guest.close);
      // Past the join burst (8 pings over 0.7 s): only the steady schedule.
      await Future<void>.delayed(const Duration(seconds: 1));
      final before = clockReads;
      await Future<void>.delayed(const Duration(seconds: 1));
      // ~5 pings and their pongs, two reads each.
      expect(clockReads - before, greaterThanOrEqualTo(6));
      expect(pagePeriodic, 0, reason: 'no page-timer schedule');
      expect(guest.hostSilent, isFalse);
    });

    test('the self-healing session joins too', () async {
      final session = await JamGuestSession.connect(
        Uri.parse(info['joinUri']! as String),
        clientName: 'browser session',
        clientKind: 'web',
      );
      addTearDown(session.close);
      expect(session.connectionState, JamConnectionState.connected);
      final bytes = await session.fetchMedia(info['mediaId']! as String);
      expect(sha256.convert(bytes).toString(), info['sha256']);
      await session.close();
      expect(session.connectionState, JamConnectionState.closed);
    });
  });
}

/// Request/response over the hybrid channel, one message at a time.
class _HostChannel {
  _HostChannel(this._channel) : _incoming = StreamIterator(_channel.stream);

  final StreamChannel<Object?> _channel;
  final StreamIterator<Object?> _incoming;

  void send(Object? message) => _channel.sink.add(message);

  Future<Object?> next() async {
    if (!await _incoming.moveNext()) throw StateError('hybrid host exited');
    return _incoming.current;
  }
}
