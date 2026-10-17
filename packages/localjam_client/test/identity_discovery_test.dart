/// Quirky identity + nearby-room record parsing.
library;

import 'dart:math';

import 'package:bonsoir/bonsoir.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_client/localjam_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('JamIdentity', () {
    setUp(() {
      JamIdentity.resetCacheForTesting();
      SharedPreferences.setMockInitialValues({});
    });

    test(
      'generates a quirky "Adjective Animal" name and persists it',
      () async {
        final name = await JamIdentity.displayName();
        final parts = name.split(' ');
        expect(parts, hasLength(2));
        expect(jamNameAdjectives, contains(parts[0]));
        expect(jamNameAnimals, contains(parts[1]));
        // Stable across calls and across a fresh in-process cache.
        expect(await JamIdentity.displayName(), name);
        JamIdentity.resetCacheForTesting();
        expect(await JamIdentity.displayName(), name);
      },
    );

    test('renames persist; blank renames are rejected', () async {
      await JamIdentity.setDisplayName('  DJ Sloth  ');
      expect(await JamIdentity.displayName(), 'DJ Sloth');
      expect(await JamIdentity.setDisplayName('   '), 'DJ Sloth');
    });

    test('generator is deterministic under an injected Random', () {
      expect(generateJamName(Random(7)), generateJamName(Random(7)));
    });
  });

  group('JamRoomBrowser record parsing', () {
    JamNearbyRoom? parse({
      List<String> hosts = const ['192.168.1.7'],
      String? hostname,
      Map<String, String> attributes = const {
        'v': '1',
        'name': 'RoadTrip',
        'token': 'cafe',
      },
    }) => JamRoomBrowser.roomFromService(
      BonsoirService(
        name: 'RoadTrip',
        type: jamServiceType,
        port: 44100,
        hostAddresses: hosts,
        hostname: hostname,
        attributes: attributes,
      ),
    );

    test('a resolved record becomes a joinable URI', () {
      final room = parse(hosts: ['192.168.1.7', '10.0.0.3'])!;
      expect(room.sessionName, 'RoadTrip');
      final params = room.joinUri.queryParameters;
      expect(room.joinUri.scheme, 'localjam');
      expect(params['host'], '192.168.1.7,10.0.0.3');
      expect(params['port'], '44100');
      expect(params['token'], 'cafe');
      expect(params['v'], '1');
    });

    test('IPv4 candidates come before IPv6 (zone-id URIs burn timeouts)', () {
      final room = parse(
        hosts: ['fe80::145a:142%en0', '192.168.1.7', 'fd00::5'],
      )!;
      expect(
        room.joinUri.queryParameters['host'],
        '192.168.1.7,fe80::145a:142%en0,fd00::5',
      );
    });

    test('a hostname is never a candidate, however it resolved', () {
      // mDNS is unauthenticated — anyone on the segment can answer — and a
      // name is a promise about what some resolver returns later, which the
      // join path cannot check. Only resolved numeric addresses are offered,
      // so a record with none is not a room.
      expect(parse(hosts: const [], hostname: 'phone.local'), isNull);
      expect(parse(hosts: const ['phone.local']), isNull);
    });

    test('an off-LAN address advertised over mDNS is dropped', () {
      // The half of the record an attacker controls: point the A record at a
      // public host and every browsing app becomes its client.
      expect(parse(hosts: const ['8.8.8.8']), isNull);
      expect(parse(hosts: const ['2606:4700::1111']), isNull);
      final room = parse(hosts: const ['8.8.8.8', '192.168.1.7'])!;
      expect(room.joinUri.queryParameters['host'], '192.168.1.7');
    });

    test('records without a token or any address are unjoinable', () {
      expect(parse(attributes: const {'name': 'RoadTrip'}), isNull);
      expect(parse(hosts: const []), isNull);
    });
  });
}
