/// The host's display name in discovery (`hname`, PROTOCOL.md §1, 1.1): what
/// a host puts in its TXT record, what a joiner reads back out of one, and
/// how one room's several advertisements settle on one name.
///
/// `hname` is a 1.x addition, so the other half of every test here is that
/// nothing a 1.0 peer reads changes because of it.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:bonsoir/bonsoir.dart';
import 'package:flutter/widgets.dart' show StringCharacters;
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_client/localjam_client.dart';

/// Reads TXT record data the way any DNS-SD browser does (RFC 6763 §6):
/// length-prefixed strings, each split at its first `=`.
Map<String, String> decodeTxt(Uint8List data) {
  final out = <String, String>{};
  var offset = 0;
  while (offset < data.length) {
    final length = data[offset++];
    if (length == 0) continue;
    final pair = utf8.decode(data.sublist(offset, offset + length));
    offset += length;
    final split = pair.indexOf('=');
    if (split <= 0) continue;
    out.putIfAbsent(pair.substring(0, split), () => pair.substring(split + 1));
  }
  return out;
}

int bytesOf(String text) => utf8.encode(text).length;

/// Whether [cut] ends between two of [whole]'s graphemes.
bool isGraphemePrefix(String cut, String whole) {
  final a = cut.characters.toList();
  final b = whole.characters.toList();
  if (a.length > b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('building the record', () {
    Map<String, String> record(String? hostName) =>
        JamRoomAdvertiser.attributesFor(
          sessionName: 'Van Jam',
          token: 'cafe',
          hostName: hostName,
        );

    test(
      'carries the host’s name beside the 1.0 keys, which are unchanged',
      () {
        expect(record('Silky Puffin'), {
          'v': '${MessageCodec.protocolVersion}',
          'name': 'Van Jam',
          'token': 'cafe',
          'hname': 'Silky Puffin',
        });
        expect(jamHostNameTxtKey, 'hname');
      },
    );

    test('leaves the key out when there is no name to carry', () {
      for (final blank in [null, '', '   ', '\t\n', '\u0000\u001f']) {
        expect(record(blank), {
          'v': '1',
          'name': 'Van Jam',
          'token': 'cafe',
        }, reason: 'hostName: ${jsonEncode(blank)}');
      }
    });

    test('trims the ends and folds whitespace and control characters into '
        'one space', () {
      expect(record('  Mia  ')['hname'], 'Mia');
      expect(record('Mia\n\tChen')['hname'], 'Mia Chen');
      expect(record('Mia\u0007 \u0085Chen')['hname'], 'Mia Chen');
    });

    test('a long name is cut to 63 bytes, and trimmed again after', () {
      final long = 'A' * 100;
      expect(record(long)['hname'], 'A' * 63);
      expect(jamTxtHostName('B' * 63), 'B' * 63, reason: 'exactly fits');
      // The cut lands just after a space: no trailing blank survives it.
      final spaced = '${'C' * 62} DDDDD';
      expect(jamTxtHostName(spaced), 'C' * 62);
    });

    test('multi-byte names are cut between characters, never inside one', () {
      final names = [
        // Three bytes a letter, with combining vowel signs.
        'बिबेक तिमसिना बिबेक तिमसिना बिबेक तिमसिना',
        // A ZWJ family is one grapheme of 25 bytes.
        '👨‍👩‍👧‍👦' * 4,
        // Flags: two regional indicators, 8 bytes, one grapheme.
        '🇳🇵' * 12,
        // An accent as a combining mark must stay with its letter.
        'é' * 40,
        // Two-byte letters with a three-byte one to shift the boundary.
        '€${'ö' * 40}',
      ];
      for (final name in names) {
        final cut = jamTxtHostName(name)!;
        expect(bytesOf(cut), lessThanOrEqualTo(jamHostNameTxtMaxBytes));
        expect(isGraphemePrefix(cut, name), isTrue, reason: name);
        // As long as it can be: one more grapheme would not fit.
        final next = name.characters.elementAt(cut.characters.length);
        expect(bytesOf(cut + next), greaterThan(jamHostNameTxtMaxBytes));
        // Round-trips as valid UTF-8: no half a character on the wire.
        expect(utf8.decode(utf8.encode(cut)), cut);
      }
      expect(jamTxtHostName('👨‍👩‍👧‍👦' * 4), '👨‍👩‍👧‍👦' * 2);
      expect(jamTxtHostName('é' * 40), 'é' * 21);
    });

    test(
      'a single character too long to fit leaves nothing, not a fragment',
      () {
        // One grapheme: a letter under 40 combining marks (81 bytes).
        expect(jamTxtHostName('a${'́' * 40}'), isNull);
      },
    );

    test('on the wire, the built-in responder’s TXT decodes to the same '
        'record, every pair inside a TXT string', () {
      final attributes = record('बिबेक ${'x' * 200}');
      // A pair over 255 bytes would have been left out; every one is there.
      expect(decodeTxt(encodeTxtRecord(attributes)), attributes);
      expect(
        bytesOf('hname=${attributes['hname']}'),
        lessThanOrEqualTo(6 + jamHostNameTxtMaxBytes),
      );
    });
  });

  group('reading a record', () {
    JamNearbyRoom? parse(Map<String, String> attributes) =>
        JamRoomBrowser.roomFromService(
          BonsoirService(
            name: 'Van Jam 6537',
            type: jamServiceType,
            port: 44100,
            hostAddresses: const ['192.168.1.7'],
            attributes: attributes,
          ),
        );
    const v10 = {'v': '1', 'name': 'Van Jam', 'token': 'cafe'};

    test('hname becomes the room’s host name', () {
      expect(
        parse({...v10, 'hname': 'Silky Puffin'})!.hostName,
        'Silky Puffin',
      );
    });

    test('absent or blank, there is no host name', () {
      expect(parse(v10)!.hostName, isNull);
      expect(parse({...v10, 'hname': ''})!.hostName, isNull);
      expect(parse({...v10, 'hname': '   \t'})!.hostName, isNull);
    });

    test('what arrives is held to the shape a host sends: trimmed, folded '
        'and capped', () {
      expect(parse({...v10, 'hname': '  Mia\nChen '})!.hostName, 'Mia Chen');
      final oversize = parse({...v10, 'hname': 'Ж' * 200})!.hostName!;
      expect(oversize, 'Ж' * 31); // 62 bytes; a 32nd would make 64.
      expect(bytesOf(oversize), lessThanOrEqualTo(jamHostNameTxtMaxBytes));
    });

    test('a 1.0 reader ignores hname: everything it reads is the same, and '
        'the join URI does not carry it', () {
      final withName = parse({...v10, 'hname': 'Silky Puffin'})!;
      final without = parse(v10)!;
      expect(withName.sessionName, without.sessionName);
      expect(withName.joinUri, without.joinUri);
      expect(withName.token, without.token);
      expect(withName.key, without.key);
      expect(withName.candidates, without.candidates);
      expect(withName.joinUri.queryParameters.keys, isNot(contains('hname')));
      // The record a 1.x host advertises, as a 1.0 browser decodes it off
      // the wire, still holds every 1.0 key exactly.
      final wire = decodeTxt(
        encodeTxtRecord(
          JamRoomAdvertiser.attributesFor(
            sessionName: 'Van Jam',
            token: 'cafe',
            hostName: 'Silky Puffin',
          ),
        ),
      );
      for (final key in v10.keys) {
        expect(wire[key], v10[key], reason: key);
      }
    });

    test('keys it does not know are still ignored', () {
      final room = parse({
        ...v10,
        'hname': 'Theo',
        'zz': 'whatever',
        'hname2': 'Mallory',
        'cover': 'x' * 200,
      })!;
      expect(room.hostName, 'Theo');
      expect(room.sessionName, 'Van Jam');
      expect(room.joinUri, parse(v10)!.joinUri);
    });

    test('a host name alone never makes a record joinable', () {
      expect(parse({'name': 'Van Jam', 'hname': 'Theo'}), isNull);
    });
  });

  group('one room, one name', () {
    late StreamController<BonsoirDiscoveryEvent> events;
    late StreamController<MdnsPtrAnswer> answers;
    late JamRoomBrowser browser;

    setUp(() async {
      events = StreamController<BonsoirDiscoveryEvent>.broadcast();
      answers = StreamController<MdnsPtrAnswer>.broadcast();
      browser = JamRoomBrowser.withSources(
        events: events.stream,
        answers: answers.stream,
        sweepInterval: const Duration(days: 1),
      );
      await browser.start();
    });

    tearDown(() async {
      await browser.stop();
      await events.close();
      await answers.close();
    });

    Future<void> settle() => Future<void>.delayed(Duration.zero);

    BonsoirService service(String instance, {String? hname}) => BonsoirService(
      name: instance,
      type: jamServiceType,
      port: 44100,
      hostAddresses: const ['192.168.1.7'],
      attributes: {
        'v': '1',
        'name': 'Van Jam',
        'token': 'cafe',
        'hname': ?hname,
      },
    );

    test('the advertisement that arrived last names the host, and '
        're-confirming an older one does not change it', () async {
      events
        ..add(
          BonsoirDiscoveryServiceResolvedEvent(
            service: service('Van Jam 6537', hname: 'Old Name'),
          ),
        )
        ..add(
          BonsoirDiscoveryServiceResolvedEvent(
            service: service('Van Jam 6537b', hname: 'Silky Puffin'),
          ),
        );
      await settle();
      expect(browser.rooms.value.single.hostName, 'Silky Puffin');

      events.add(
        BonsoirDiscoveryServiceResolvedEvent(
          service: service('Van Jam 6537', hname: 'Old Name'),
        ),
      );
      answers.add(
        const MdnsPtrAnswer(
          serviceType: '_localjam._tcp.local',
          instanceName: 'Van Jam 6537',
          ttl: 120,
        ),
      );
      await settle();
      expect(browser.rooms.value.single.hostName, 'Silky Puffin');
    });

    test('a newer record without a name is the room as it is now', () async {
      events
        ..add(
          BonsoirDiscoveryServiceResolvedEvent(
            service: service('Van Jam 6537', hname: 'Silky Puffin'),
          ),
        )
        ..add(
          BonsoirDiscoveryServiceResolvedEvent(
            service: service('Van Jam 6537b'),
          ),
        );
      await settle();
      expect(browser.rooms.value.single.hostName, isNull);
    });

    test(
      'an updated record changes the name; a PTR refresh keeps it',
      () async {
        events.add(
          BonsoirDiscoveryServiceResolvedEvent(
            service: service('Van Jam 6537', hname: 'Silky Puffin'),
          ),
        );
        await settle();
        events.add(
          BonsoirDiscoveryServiceUpdatedEvent(
            service: service('Van Jam 6537', hname: 'DJ Sloth'),
          ),
        );
        await settle();
        expect(browser.rooms.value.single.hostName, 'DJ Sloth');

        final before = browser.rooms.value.single.lastSeen;
        answers.add(
          const MdnsPtrAnswer(
            serviceType: '_localjam._tcp.local',
            instanceName: 'Van Jam 6537',
            ttl: 120,
          ),
        );
        await settle();
        final room = browser.rooms.value.single;
        expect(room.lastSeen.isBefore(before), isFalse);
        expect(room.hostName, 'DJ Sloth');
      },
    );
  });
}
