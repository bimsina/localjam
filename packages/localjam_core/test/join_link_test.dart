import 'package:localjam_core/localjam_core.dart';
import 'package:test/test.dart';

void main() {
  final link = JoinLink(
    v: 1,
    token: 'tok123',
    name: 'Road Trip',
    hosts: const ['192.168.1.7', '192.168.43.1'],
    port: 44100,
  );

  group('localjam:// form (§1)', () {
    test('parses every key, candidates in order', () {
      final parsed = JoinLink.parse(
        'localjam://join?v=1&host=192.168.1.7,192.168.43.1&port=44100'
        '&token=tok123&name=Road%20Trip',
      );
      expect(parsed, link);
      expect(parsed!.primaryHost, '192.168.1.7');
      expect(parsed.displayName, 'Road Trip');
    });

    test('formats in the keys and order hosts have always written', () {
      final uri = link.toLocaljamUri();
      expect(uri.scheme, 'localjam');
      expect(uri.host, 'join');
      expect(uri.queryParameters.keys, ['v', 'host', 'port', 'token', 'name']);
      expect(uri.queryParameters['host'], '192.168.1.7,192.168.43.1');
      expect(JoinLink.fromUri(uri), link);
    });

    test('v and name are optional; host, port and token are not', () {
      final bare = JoinLink.parse(
        'localjam://join?host=10.0.0.1&port=80&token=t',
      );
      expect(bare, isNotNull);
      expect(bare!.v, isNull);
      expect(bare.name, isNull);
      expect(bare.displayName, isNull);
      expect(bare.toLocaljamUri().queryParameters.keys, [
        'host',
        'port',
        'token',
      ]);
      for (final bad in [
        'localjam://join',
        'localjam://join?host=10.0.0.1',
        'localjam://join?port=80&token=t',
        'localjam://join?host=10.0.0.1&token=t',
        'localjam://join?host=10.0.0.1&port=80&token=',
        'localjam://join?host=,,&port=80&token=t',
        'localjam://join?host=10.0.0.1&port=0&token=t',
        'localjam://join?host=10.0.0.1&port=65536&token=t',
        'localjam://join?host=10.0.0.1&port=eighty&token=t',
        'localjam://join?host=10.0.0.1&port=80&token=t&v=x',
        'localjam://join?host=10.0.0.1&port=80&token=t&v=0',
        'localjam://other?host=10.0.0.1&port=80&token=t',
        'localjam://join/deeper?host=10.0.0.1&port=80&token=t',
        'localjam://join?host=10.0.0.1&port=80&token=%zz',
        'localjam://join?host=10.0.0.1/x&port=80&token=t',
        'localjam://join?host=a%20b&port=80&token=t',
      ]) {
        expect(JoinLink.parse(bad), isNull, reason: bad);
      }
    });

    test('tolerates whitespace, chat-app <…> wrapping, case and a v2', () {
      expect(
        JoinLink.parse(
          '  <LOCALJAM://Join/?host=%2010.0.0.1%20,&port=80&token=t&v=2>  ',
        ),
        JoinLink(v: 2, token: 't', hosts: const ['10.0.0.1'], port: 80),
      );
    });

    test('IPv6 candidates stay bare, zone ids included', () {
      final parsed = JoinLink.parse(
        'localjam://join?host=fe80::1%25en0,[fd00::2]&port=1&token=t',
      );
      expect(parsed!.hosts, ['fe80::1%en0', 'fd00::2']);
    });
  });

  group('http form (§1, 1.2)', () {
    test('parses the brief example', () {
      final parsed = JoinLink.parse(
        'http://192.168.1.7:44100/join#v=1&token=tok123&name=Road%20Trip'
        '&host=192.168.1.7,192.168.43.1',
      );
      expect(parsed, link);
    });

    test('formats URL host = first candidate, fragment v/token/name/host', () {
      final uri = link.toHttpUri();
      expect(
        '$uri',
        'http://192.168.1.7:44100/join#v=1&token=tok123&name=Road+Trip'
            '&host=192.168.1.7,192.168.43.1',
      );
      expect(uri.query, isEmpty, reason: 'the token never rides the request');
      expect(JoinLink.fromUri(uri), link);
      expect(JoinLink.parse('$uri'), link);
    });

    test('without host the URL authority is the sole candidate', () {
      final parsed = JoinLink.parse('http://10.0.0.4:5000/join#token=t');
      expect(parsed!.hosts, ['10.0.0.4']);
      expect(parsed.port, 5000);
      // And a lone candidate is written without the redundant key.
      expect('${parsed.toHttpUri()}', 'http://10.0.0.4:5000/join#token=t');
    });

    test('with host, the list is the whole candidate list', () {
      final parsed = JoinLink.parse(
        'http://10.0.0.4:5000/join#token=t&host=192.168.1.2',
      );
      expect(parsed!.hosts, ['192.168.1.2']);
    });

    test('the URL port is every candidate\'s; a fragment port is ignored', () {
      final parsed = JoinLink.parse(
        'http://10.0.0.4:5000/join#token=t&port=9&host=10.0.0.4,10.0.0.5',
      );
      expect(parsed!.port, 5000);
      expect(JoinLink.parse('http://10.0.0.4/join#token=t')!.port, 80);
    });

    test('IPv6 authority in brackets comes out bare, with its zone', () {
      expect(JoinLink.parse('http://[FD00::7]:44100/join#token=t')!.hosts, [
        'fd00::7',
      ]);
      expect(
        JoinLink.parse('http://[fe80::1%25en0]:44100/join#token=t')!.hosts,
        ['fe80::1%en0'],
      );
      final v6 = JoinLink(
        token: 't',
        hosts: const ['fe80::1%en0', '10.0.0.1'],
        port: 44100,
      );
      final uri = v6.toHttpUri();
      expect(uri.authority, '[fe80::1%25en0]:44100');
      expect(JoinLink.fromUri(uri), v6);
      expect(JoinLink.fromUri(v6.toLocaljamUri()), v6);
    });

    test('percent-decoding: names, tokens, plus as space', () {
      final parsed = JoinLink.parse(
        'http://10.0.0.1:1/join#token=a%2Bb&name=Caf%C3%A9+%26+Bar',
      );
      expect(parsed!.token, 'a+b');
      expect(parsed.name, 'Café & Bar');
      final odd = JoinLink(
        token: 'a+b/c=d&e',
        name: 'Ünïcødé & co #1',
        hosts: const ['10.0.0.1'],
        port: 1,
      );
      expect(JoinLink.fromUri(odd.toHttpUri()), odd);
      expect(JoinLink.parse('${odd.toHttpUri()}'), odd);
      expect(JoinLink.fromUri(odd.toLocaljamUri()), odd);
    });

    test('rejects everything that is not exactly the http join form', () {
      for (final bad in [
        'http://10.0.0.1:1/join', // no fragment, no token
        'http://10.0.0.1:1/join#name=x', // no token
        'http://10.0.0.1:1/join#token=', // empty token
        'http://10.0.0.1:1/join?token=t', // token in the query, not fragment
        'http://10.0.0.1:1/#token=t', // wrong path
        'http://10.0.0.1:1/join/#token=t',
        'http://10.0.0.1:1/web/join#token=t',
        'https://10.0.0.1:1/join#token=t', // not http
        'ws://10.0.0.1:1/join#token=t',
        'http://user@10.0.0.1:1/join#token=t',
        'http://10.0.0.1:1/join#token=t&v=one',
        'http://10.0.0.1:1/join#token=%zz',
        'http://10.0.0.1:1/join#token=t&host=,',
        'http://10.0.0.1:1/join#token=t&host=a%2Fb',
        'http:///join#token=t',
        'mailto:x@y',
        'not a link at all',
        '',
        '   ',
      ]) {
        expect(JoinLink.parse(bad), isNull, reason: bad);
      }
    });
  });

  group('hosts the http form cannot render (review 2026-10-21)', () {
    // Each of these used to parse, and then `toHttpUri()` threw.
    const colonNotIPv6 = [
      '1.2.3.4:99', // A port where an address goes.
      'a:b',
      'x:',
      '1::2::3',
      '::1%', // Empty zone id.
      '::1%%', // A zone id holding a `%`.
      'fe80::1%en0%1',
    ];

    test('are not hosts in the http form', () {
      for (final host in colonNotIPv6) {
        final text =
            'http://192.168.1.7:44100/join#token=a'
            '&host=${Uri.encodeQueryComponent(host)}';
        expect(JoinLink.parse(text), isNull, reason: host);
      }
      expect(
        JoinLink.parse('http://192.168.1.7:44100/join#token=a&host=::1%25%25'),
        isNull,
      );
    });

    test('are not hosts in the localjam form either', () {
      for (final host in colonNotIPv6) {
        final text =
            'localjam://join?port=1&token=a'
            '&host=${Uri.encodeQueryComponent(host)}';
        expect(JoinLink.parse(text), isNull, reason: host);
      }
    });

    test('a % outside an IPv6 zone id is not a host', () {
      for (final host in ['a%b', 'abc%', '%41']) {
        expect(
          () => JoinLink(token: 't', hosts: [host], port: 1),
          throwsArgumentError,
          reason: host,
        );
      }
    });

    test('the constructor refuses them, wherever they stand in the list', () {
      for (final host in colonNotIPv6) {
        expect(
          () => JoinLink(token: 't', hosts: [host], port: 1),
          throwsArgumentError,
          reason: host,
        );
        expect(
          () => JoinLink(token: 't', hosts: ['10.0.0.1', host], port: 1),
          throwsArgumentError,
          reason: host,
        );
      }
    });

    test('real IPv6 literals still parse, render and round-trip', () {
      for (final host in [
        '::1',
        'fe80::1%en0',
        'fd00::2',
        '::ffff:192.168.1.7',
      ]) {
        final link = JoinLink(token: 't', hosts: [host], port: 44100);
        final uri = link.toHttpUri();
        expect(JoinLink.fromUri(uri), link, reason: host);
        expect(JoinLink.fromUri(link.toLocaljamUri()), link, reason: host);
      }
    });
  });

  group('value type', () {
    test('both forms of one room are one link', () {
      expect(JoinLink.fromUri(link.toHttpUri()), link);
      expect(JoinLink.fromUri(link.toLocaljamUri()), link);
      expect(
        JoinLink.fromUri(link.toHttpUri())!.toLocaljamUri(),
        link.toLocaljamUri(),
      );
    });

    test('equality covers every field and candidate order', () {
      expect(link.copyWith(), link);
      expect(link.copyWith().hashCode, link.hashCode);
      expect(link.copyWith(port: 1), isNot(link));
      expect(
        link.copyWith(hosts: const ['192.168.43.1', '192.168.1.7']),
        isNot(link),
      );
    });

    test('hosts are unmodifiable', () {
      expect(() => link.hosts.add('x'), throwsUnsupportedError);
    });

    test('the constructor refuses what parse would', () {
      expect(
        () => JoinLink(token: '', hosts: const ['a'], port: 1),
        throwsArgumentError,
      );
      expect(
        () => JoinLink(token: 't', hosts: const [], port: 1),
        throwsArgumentError,
      );
      expect(
        () => JoinLink(token: 't', hosts: const ['a/b'], port: 1),
        throwsArgumentError,
      );
      expect(
        () => JoinLink(token: 't', hosts: const ['a'], port: 0),
        throwsRangeError,
      );
    });

    test('toString leaves the token out', () {
      expect('$link', isNot(contains('tok123')));
    });
  });
}
