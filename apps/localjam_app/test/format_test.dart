/// The formatters behind the numbers on screen.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/util/format.dart';
import 'package:localjam_client/localjam_client.dart';

import 'harness.dart';

void main() {
  group('jamPeerName', () {
    test('a name, trimmed', () {
      expect(
        jamPeerName(
          const PeerInfo(
            peerId: 'p-7f3a',
            clientName: ' Ana ',
            clientKind: 'flutter',
          ),
        ),
        'Ana',
      );
    });

    test('never the peer id, even with no name at all', () {
      // A roster or a credit that prints "p-7f3a" is machine text on a page
      // about people (§8 check 3).
      for (final name in ['', '   ']) {
        expect(
          jamPeerName(
            PeerInfo(peerId: 'p-7f3a', clientName: name, clientKind: 'web'),
          ),
          kJamUnnamedPeer,
        );
      }
    });
  });

  testWidgets('a byline names the person, or says "Guest" — never a peer id', (
    tester,
  ) async {
    // The engine fell back to the peer id for a contributor who shared no
    // name, and the app patched it over by spotting the id coming back.
    final session = testSession();
    await tester.runAsync(() async {
      await session.startHost(sessionName: 'Byline Jam', discoverable: false);
      final engine = session.hostEngine!;
      final uri = engine.joinUriFor(InternetAddress.loopbackIPv4);
      final anon = await JamGuestClient.connect(uri, clientName: '  ');
      addTearDown(anon.close);
      final ana = await JamGuestClient.connect(uri, clientName: 'Ana');
      addTearDown(ana.close);
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (engine.peers.length < 2 && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(engine.peers, hasLength(2));

      MediaItem by(String? peerId) => MediaItem(
        mediaId: 'm_1',
        kind: MediaKind.audio,
        name: 'a.wav',
        mime: 'audio/wav',
        sizeBytes: 1,
        sha256: '00',
        addedBy: peerId,
      );
      expect(jamAddedByLabel(engine, by(anon.selfPeerId)), kJamUnnamedPeer);
      expect(jamAddedByLabel(engine, by(ana.selfPeerId)), 'Ana');
      expect(jamAddedByLabel(engine, by(engine.selfPeerId)), 'You');
      expect(jamAddedByLabel(engine, by('p_left')), isNull);
      expect(jamAddedByLabel(engine, by(null)), isNull);

      await session.leave();
    });
  });

  group('formatSignedMs', () {
    test('signs a real figure', () {
      expect(formatSignedMs(12300), '+12.3 ms');
      expect(formatSignedMs(-12300), '-12.3 ms');
    });

    test('renders anything that rounds to zero as an unsigned 0.0 ms', () {
      // The flap: drift hovering around perfect alternated between "+0.0 ms"
      // and "-0.0 ms" every sample, which reads as instability that is not
      // there. Two readings that round the same must print the same.
      expect(formatSignedMs(0), '0.0 ms');
      expect(formatSignedMs(1), '0.0 ms');
      expect(formatSignedMs(-1), '0.0 ms');
      expect(formatSignedMs(49), '0.0 ms');
      expect(formatSignedMs(-49), '0.0 ms');
    });

    test('starts signing again at the deadband edge', () {
      expect(formatSignedMs(60), '+0.1 ms');
      expect(formatSignedMs(-60), '-0.1 ms');
    });

    test('formatDriftMs is the same formatter', () {
      expect(formatDriftMs(-1), formatSignedMs(-1));
      expect(formatDriftMs(4200), '+4.2 ms');
    });
  });

  group('formatPositionUs', () {
    test('mm:ss, and h:mm:ss past an hour', () {
      expect(formatPositionUs(0), '00:00');
      expect(formatPositionUs(65 * 1000000), '01:05');
      expect(formatPositionUs(3725 * 1000000), '1:02:05');
    });
  });
}
