import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/util/network.dart';

void main() {
  test('offline is the absence of an address', () {
    expect(JamNetworkStatus.offline.connected, isFalse);
    expect(JamNetworkStatus.offline.primaryAddress, isNull);
  });

  test('a bound address means guests can reach a host here', () {
    const status = JamNetworkStatus(
      addresses: ['192.168.1.5'],
      interface: 'en0',
    );
    expect(status.connected, isTrue);
    expect(status.primaryAddress, '192.168.1.5');
    expect(status.isHotspotHost, isFalse);
  });

  test('recognises the interfaces a personal hotspot bridges onto', () {
    // Matters because mDNS does not cross a hotspot: on these, the nearby
    // list stays empty however well things are working, and the QR is the
    // only way in.
    for (final name in ['bridge100', 'ap0', 'swlan0', 'rndis0']) {
      expect(
        JamNetworkStatus(
          addresses: const ['172.20.10.1'],
          interface: name,
        ).isHotspotHost,
        isTrue,
        reason: '$name should read as a hotspot',
      );
    }
    for (final name in ['en0', 'wlan0', 'eth0']) {
      expect(
        JamNetworkStatus(
          addresses: const ['192.168.1.5'],
          interface: name,
        ).isHotspotHost,
        isFalse,
        reason: '$name should not read as a hotspot',
      );
    }
  });

  group('join-link addresses', () {
    test('accepts every shape of "on this network"', () {
      for (final address in [
        '10.0.0.4',
        '172.16.3.9',
        '172.31.255.254',
        '192.168.1.5',
        '169.254.1.1', // link-local
        '127.0.0.1',
        '::1',
        'fe80::1',
        'fd00::1', // unique-local
      ]) {
        expect(
          isLocalNetworkAddress(address),
          isTrue,
          reason: '$address is a local address',
        );
      }
    });

    test('refuses anything routable, and anything that is not an IP', () {
      // A localjam:// link is a bare instruction to open a socket, and it can
      // arrive from a web page. Pointing it at a public host would make the
      // app someone else's HTTP client.
      for (final address in [
        '8.8.8.8',
        '172.15.0.1', // just below the RFC1918 block
        '172.32.0.1', // just above it
        '192.169.1.1',
        '2606:4700::1111',
        'evil.example.com',
        'localhost',
        '',
        'not an address',
      ]) {
        expect(
          isLocalNetworkAddress(address),
          isFalse,
          reason: '$address must not pass as local',
        );
      }
    });

    test('a link is local only when every candidate is', () {
      Uri link(String hosts) => Uri.parse(
        'localjam://join?v=1&host=$hosts&port=8080&token=abc&name=Trip',
      );
      expect(joinUriIsLocalOnly(link('192.168.1.5,10.0.0.4')), isTrue);
      // One public candidate is enough to refuse: the guest client tries them
      // in order and would reach it.
      expect(joinUriIsLocalOnly(link('192.168.1.5,8.8.8.8')), isFalse);
      expect(joinUriIsLocalOnly(Uri.parse('localjam://join?port=1')), isFalse);
    });

    test('a zone id names an interface, not another host', () {
      // mDNS hands these out constantly on Apple platforms; refusing them
      // would quietly drop every IPv6 candidate a nearby room offers.
      expect(isLocalNetworkAddress('fe80::145a:142%en0'), isTrue);
      expect(isLocalNetworkAddress('2606:4700::1111%en0'), isFalse);
    });

    test(
      'names are refused; only *.local is resolved, then re-checked',
      () async {
        Future<List<InternetAddress>> lookupTo(List<String> addresses) async =>
            [for (final a in addresses) InternetAddress(a)];
        var asked = <String>[];
        Future<List<InternetAddress>> spy(String host) async {
          asked.add(host);
          return lookupTo(const ['192.168.1.5']);
        }

        // An IP literal is decided without ever touching a resolver.
        expect(await isLocalNetworkHost('192.168.1.5', lookup: spy), isTrue);
        expect(await isLocalNetworkHost('8.8.8.8', lookup: spy), isFalse);
        expect(asked, isEmpty, reason: 'literals are not names');

        // A DNS name is refused flat: what it resolves to today says nothing
        // about tomorrow, and the link is the thing being vouched for.
        for (final name in [
          'evil.example.com',
          'localhost',
          'router',
          'local',
          'not a host',
        ]) {
          expect(
            await isLocalNetworkHost(name, lookup: spy),
            isFalse,
            reason: name,
          );
        }
        expect(asked, isEmpty, reason: 'no DNS name is worth a lookup');

        // `*.local` is multicast DNS — link-local by definition, and what
        // Apple platforms and mDNS discovery hand out — so it is resolved.
        expect(await isLocalNetworkHost('phone.local', lookup: spy), isTrue);
        expect(asked, ['phone.local']);
        // A trailing root dot is the same name.
        expect(await isLocalNetworkHost('phone.local.', lookup: spy), isTrue);

        // But the answer is checked: a resolver that points a .local name at
        // the internet is exactly what this gate is for.
        expect(
          await isLocalNetworkHost(
            'phone.local',
            lookup: (_) => lookupTo(const ['8.8.8.8']),
          ),
          isFalse,
        );
        expect(
          await isLocalNetworkHost(
            'phone.local',
            lookup: (_) => lookupTo(const ['192.168.1.5', '8.8.8.8']),
          ),
          isFalse,
          reason: 'one routable answer is enough to refuse',
        );
        expect(
          await isLocalNetworkHost('phone.local', lookup: (_) async => []),
          isFalse,
          reason: 'nothing resolved is nothing vouched for',
        );
        expect(
          await isLocalNetworkHost(
            'phone.local',
            lookup: (_) => Future.error(const SocketException('no mDNS')),
          ),
          isFalse,
        );
      },
    );

    test('the resolving gate is the one every join passes', () async {
      Uri link(String hosts) => Uri.parse(
        'localjam://join?v=1&host=$hosts&port=8080&token=abc&name=Trip',
      );
      Future<List<InternetAddress>> lan(String _) async => [
        InternetAddress('192.168.1.5'),
      ];
      expect(await joinUriIsLocalOnlyResolved(link('10.0.0.4')), isTrue);
      expect(await joinUriIsLocalOnlyResolved(link('8.8.8.8')), isFalse);
      expect(
        await joinUriIsLocalOnlyResolved(link('phone.local'), lookup: lan),
        isTrue,
      );
      expect(
        await joinUriIsLocalOnlyResolved(
          link('192.168.1.5,phone.local'),
          lookup: (_) async => [InternetAddress('8.8.8.8')],
        ),
        isFalse,
        reason: 'guests try candidates in order and would reach it',
      );
      expect(
        await joinUriIsLocalOnlyResolved(Uri.parse('localjam://join?port=1')),
        isFalse,
      );
    });

    test('reads the room name off a link', () {
      expect(
        joinUriName(
          Uri.parse(
            'localjam://join?host=10.0.0.1&port=1&token=t&name=Road%20Trip',
          ),
        ),
        'Road Trip',
      );
      expect(joinUriName(Uri.parse('localjam://join?host=10.0.0.1')), isNull);
      expect(
        joinUriName(
          Uri.parse('http://10.0.0.1:1/join#token=t&name=Road%20Trip'),
        ),
        'Road Trip',
      );
    });

    test('the http form (§1, 1.2) is held to the same on-LAN rule, every '
        'candidate of it', () async {
      Uri link(String authority, [String? hosts]) => Uri.parse(
        'http://$authority/join#v=1&token=abc&name=Trip'
        '${hosts == null ? '' : '&host=$hosts'}',
      );
      // No `host`: the URL's own host is the one candidate.
      expect(joinUriHosts(link('192.168.1.5:44100')), ['192.168.1.5']);
      expect(joinUriIsLocalOnly(link('192.168.1.5:44100')), isTrue);
      expect(joinUriIsLocalOnly(link('8.8.8.8:44100')), isFalse);
      expect(joinUriIsLocalOnly(link('[fe80::1%25en0]:44100')), isTrue);
      // With `host`: that list is every candidate, and every one is judged —
      // a local authority does not vouch for a public candidate behind it.
      expect(joinUriHosts(link('192.168.1.5:44100', '192.168.1.5,10.0.0.4')), [
        '192.168.1.5',
        '10.0.0.4',
      ]);
      expect(
        joinUriIsLocalOnly(link('192.168.1.5:44100', '192.168.1.5,8.8.8.8')),
        isFalse,
      );
      expect(
        await joinUriIsLocalOnlyResolved(
          link('192.168.1.5:44100', '192.168.1.5,8.8.8.8'),
        ),
        isFalse,
      );
      expect(
        await joinUriIsLocalOnlyResolved(link('example.com:44100')),
        isFalse,
        reason: 'a name that is not .local is never vouched for',
      );
      expect(
        await joinUriIsLocalOnlyResolved(
          link('phone.local:44100'),
          lookup: (_) async => [InternetAddress('8.8.8.8')],
        ),
        isFalse,
      );
    });
  });

  group('parseJoinUri', () {
    test('takes a link with everything the transport needs', () {
      final uri = parseJoinUri(
        '  localjam://join?v=1&host=192.168.1.5&port=8080&token=abc  ',
      );
      expect(uri, isNotNull);
      expect(uri!.queryParameters['token'], 'abc');
    });

    test('unwraps the angle brackets chat apps add', () {
      expect(
        parseJoinUri('<localjam://join?host=10.0.0.1&port=80&token=t>'),
        isNotNull,
      );
    });

    test('takes the http form a host QR carries (§1, 1.2), and keeps it', () {
      final uri = parseJoinUri(
        ' <http://192.168.1.5:44100/join#v=1&token=abc&name=Van'
        '&host=192.168.1.5,127.0.0.1> ',
      );
      expect(uri, isNotNull);
      expect(uri!.scheme, 'http');
      expect(joinUriHosts(uri), ['192.168.1.5', '127.0.0.1']);
      expect(joinUriName(uri), 'Van');
      expect(
        parseJoinUri('localjam://join?host=10.0.0.1&port=80&token=t')!.scheme,
        'localjam',
      );
    });

    test('refuses garbage rather than letting it reach the socket', () {
      for (final text in [
        '',
        'hello',
        'https://example.com',
        'http://192.168.1.5:44100/', // the page, not a join link
        'http://192.168.1.5:44100/join', // no token
        'http://192.168.1.5:44100/join?token=t', // token not in the fragment
        'https://192.168.1.5:44100/join#token=t',
        'localjam://join', // no host/port/token
        'localjam://join?host=10.0.0.1', // no port or token
        'localjam://join?port=80&token=t', // no host
      ]) {
        expect(parseJoinUri(text), isNull, reason: 'refuse "$text"');
      }
    });
  });
}
