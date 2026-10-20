/// The formatters behind the numbers on screen.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/util/format.dart';
import 'package:localjam_client/localjam_client.dart';

import 'harness.dart';

void main() {
  group('people, said one way (R9)', () {
    test('the summary, from your side', () {
      const table = {
        <String>[]: 'Just you',
        ['Mia']: 'With Mia',
        ['Mia', 'Theo']: 'With Mia and Theo',
        ['Mia', 'Theo', 'Ana']: 'With Mia, Theo and Ana',
        ['Mia', 'Theo', 'Ana', 'Jo']: 'With Mia, Theo and 2 others',
        ['Mia', 'Theo', 'Ana', 'Jo', 'Okon']: 'With Mia, Theo and 3 others',
      };
      for (final MapEntry(key: others, value: said) in table.entries) {
        expect(jamPeopleSummary(others), said, reason: '$others');
        expect(JamPeoplePhrase.summary(others).text, said);
      }
    });

    test('a list without the "With"', () {
      expect(JamPeoplePhrase.list(const []).text, '');
      expect(JamPeoplePhrase.list(['Mia']).text, 'Mia');
      expect(
        JamPeoplePhrase.list(['Mia', 'Theo', 'Ana']).text,
        'Mia, Theo and Ana',
      );
      expect(
        JamPeoplePhrase.list(['Mia', 'Theo', 'Ana', 'Jo', 'Okon']).text,
        'Mia, Theo and 3 others',
      );
    });

    test('never "and 1 other": one person left over is named', () {
      final names = [for (var i = 0; i < 12; i++) 'P$i'];
      for (var n = 1; n <= names.length; n++) {
        final said = jamPeopleSummary(names.take(n).toList());
        expect(said, isNot(contains(' and 1 other')), reason: said);
        for (final named in [1, 2, 3]) {
          expect(
            JamPeoplePhrase.list(names.take(n).toList(), named: named).text,
            isNot(contains(' and 1 other')),
          );
        }
      }
    });

    test('its parts: the names apart from the words that are never cut', () {
      final phrase = JamPeoplePhrase.summary(['Mia', 'Theo', 'Ana', 'Jo']);
      expect(
        [
          for (final p in phrase.parts)
            if (p.name) p.text,
        ],
        ['Mia', 'Theo'],
      );
      expect(phrase.parts.last, (text: ' and 2 others', name: false));
      expect(phrase.counted, 'With 4 people');
      expect(JamPeoplePhrase.summary(const []).counted, isNull);
    });

    test('two people with one name are two people', () {
      expect(jamDistinctNames(['Sam', 'Mia', 'Sam']), ['Sam', 'Mia', 'Sam 2']);
      expect(jamDistinctNames(['Guest', 'Guest', 'Guest']), [
        'Guest',
        'Guest 2',
        'Guest 3',
      ]);
      // A real "Sam 2" keeps their name; the next Sam takes the next one.
      expect(jamDistinctNames(['Sam', 'Sam 2', 'Sam']), [
        'Sam',
        'Sam 2',
        'Sam 3',
      ]);
      // In the order asked: who keeps the plain name is decided by it.
      expect(jamDistinctNames(['Sam', 'Sam'], order: [1, 0]), ['Sam 2', 'Sam']);
    });
  });

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
      expect(formatSignedMs(-12300), '−12.3 ms');
    });

    test('uses a real minus, and seconds past a second', () {
      // "-272391.4 ms" was a guest's clock offset in Diagnostics.
      expect(formatSignedMs(-272391400), '−272.4 s');
      expect(formatSignedMs(1500000), '+1.5 s');
      expect(formatSignedMs(-999000), '−999.0 ms');
      expect(formatSignedMs(-5000), isNot(contains('-')));
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
      expect(formatSignedMs(-60), '−0.1 ms');
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
