/// The un-discovery half of nearby rooms: a room that stops answering has to
/// leave the list. Platform browsers only reliably tell you about arrivals,
/// so [JamRoomBrowser] verifies presence on a schedule and expires what goes
/// quiet — this drives that policy off injected event sources, with no
/// network and no clock to wait on.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:bonsoir/bonsoir.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_client/localjam_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  BonsoirService service(
    String name, {
    String token = 'cafe',
    int port = 44100,
    List<String> hosts = const ['192.168.1.7'],
  }) => BonsoirService(
    name: name,
    type: jamServiceType,
    port: port,
    hostAddresses: hosts,
    attributes: {'v': '1', 'name': name, 'token': token},
  );

  /// A browser wired to a controllable event stream and a frozen clock.
  ({
    JamRoomBrowser browser,
    StreamController<BonsoirDiscoveryEvent> events,
    StreamController<MdnsPtrAnswer> answers,
    void Function(Duration) advance,
    List<({String host, int port})> attempts,
    void Function(bool) setReachable,
  })
  harness({Duration? staleAfter}) {
    final events = StreamController<BonsoirDiscoveryEvent>.broadcast();
    final answers = StreamController<MdnsPtrAnswer>.broadcast();
    var now = DateTime(2026);
    final attempts = <({String host, int port})>[];
    var reachable = true;
    final browser = JamRoomBrowser.withSources(
      events: events.stream,
      answers: answers.stream,
      clock: () => now,
      staleAfter: staleAfter ?? JamRoomBrowser.defaultStaleAfter,
      // A sweep interval that never fires inside a test; sweeps are driven
      // explicitly so nothing here waits on a wall clock.
      sweepInterval: const Duration(days: 1),
      connect: (host, port, _) async {
        attempts.add((host: host, port: port));
        return reachable;
      },
    );
    addTearDown(() async {
      await browser.stop();
      await events.close();
      await answers.close();
    });
    return (
      browser: browser,
      events: events,
      answers: answers,
      advance: (d) => now = now.add(d),
      attempts: attempts,
      setReachable: (v) => reachable = v,
    );
  }

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  group('staleness', () {
    test('a room that stops answering ages out; one that keeps answering '
        'does not', () async {
      final h = harness();
      await h.browser.start();
      h.events.add(
        BonsoirDiscoveryServiceResolvedEvent(service: service('RoadTrip')),
      );
      h.events.add(
        BonsoirDiscoveryServiceResolvedEvent(
          service: service('Kitchen', token: 'beef'),
        ),
      );
      await settle();
      expect(h.browser.rooms.value, hasLength(2));

      // Half a staleness window in, both are still fresh.
      h.advance(JamRoomBrowser.defaultStaleAfter ~/ 2);
      // Only one of them answers the re-query.
      h.answers.add(
        const MdnsPtrAnswer(
          serviceType: '_localjam._tcp.local',
          instanceName: 'RoadTrip',
          ttl: 120,
        ),
      );
      await settle();
      h.browser.sweep();
      expect(h.browser.rooms.value, hasLength(2), reason: 'neither is stale');

      // Past the deadline for the one that never answered again.
      h.advance(
        JamRoomBrowser.defaultStaleAfter ~/ 2 + const Duration(seconds: 1),
      );
      h.browser.sweep();
      expect(
        h.browser.rooms.value.map((r) => r.sessionName),
        ['RoadTrip'],
        reason: 'the refreshed room survives, the silent one is dropped',
      );
    });

    test('a PTR goodbye retires a room immediately', () async {
      final h = harness();
      await h.browser.start();
      h.events.add(
        BonsoirDiscoveryServiceResolvedEvent(service: service('RoadTrip')),
      );
      await settle();
      expect(h.browser.rooms.value, hasLength(1));

      // TTL 0, RFC 6762 §10.1 — and the case matters not at all.
      h.answers.add(
        const MdnsPtrAnswer(
          serviceType: '_localjam._tcp.local',
          instanceName: 'roadtrip',
          ttl: 0,
        ),
      );
      await settle();
      expect(h.browser.rooms.value, isEmpty);
    });

    test("bonsoir's own service-lost event still removes a room", () async {
      final h = harness();
      await h.browser.start();
      h.events.add(
        BonsoirDiscoveryServiceResolvedEvent(service: service('RoadTrip')),
      );
      await settle();
      h.events.add(
        BonsoirDiscoveryServiceLostEvent(service: service('RoadTrip')),
      );
      await settle();
      expect(h.browser.rooms.value, isEmpty);
    });

    test('a PTR answer alone never invents a room', () async {
      // It carries no token and no address, so it could not be joined or
      // checked (§9) — presence only refreshes what discovery already found.
      final h = harness();
      await h.browser.start();
      h.answers.add(
        const MdnsPtrAnswer(
          serviceType: '_localjam._tcp.local',
          instanceName: 'Ghost',
          ttl: 120,
        ),
      );
      await settle();
      expect(h.browser.rooms.value, isEmpty);
    });
  });

  group('the host is never offered its own room', () {
    test('excludedToken filters by token, across address lists', () async {
      final h = harness();
      await h.browser.start();
      h.events.add(
        BonsoirDiscoveryServiceResolvedEvent(
          service: service('Ours', token: 'mine'),
        ),
      );
      h.events.add(
        BonsoirDiscoveryServiceResolvedEvent(
          service: service('Theirs', token: 'yours'),
        ),
      );
      await settle();
      expect(h.browser.rooms.value, hasLength(2));

      h.browser.excludedToken = 'mine';
      expect(h.browser.rooms.value.map((r) => r.sessionName), ['Theirs']);

      // A second interface for the same room: different addresses, same
      // token, still ours.
      h.events.add(
        BonsoirDiscoveryServiceResolvedEvent(
          service: service(
            'Ours on the hotspot',
            token: 'mine',
            hosts: const ['10.0.0.5'],
          ),
        ),
      );
      await settle();
      expect(h.browser.rooms.value.map((r) => r.sessionName), ['Theirs']);

      // Leaving the room brings it back rather than losing it forever.
      h.browser.excludedToken = null;
      expect(h.browser.rooms.value, hasLength(3));
    });
  });

  group('probe / remove', () {
    test('a probe that answers refreshes the room; one that does not leaves '
        'it for the caller to remove', () async {
      final h = harness();
      await h.browser.start();
      h.events.add(
        BonsoirDiscoveryServiceResolvedEvent(
          service: service('RoadTrip', hosts: const ['192.168.1.7'], port: 7),
        ),
      );
      await settle();
      final room = h.browser.rooms.value.single;
      final seenBefore = room.lastSeen;

      h.advance(const Duration(seconds: 30));
      expect(await h.browser.probe(room), isTrue);
      expect(h.attempts, [(host: '192.168.1.7', port: 7)]);
      expect(
        h.browser.rooms.value.single.lastSeen.isAfter(seenBefore),
        isTrue,
        reason: 'a socket that answered is the strongest confirmation there is',
      );

      h.setReachable(false);
      expect(await h.browser.probe(room), isFalse);
      expect(
        h.browser.rooms.value,
        hasLength(1),
        reason: 'probing asks a question; it does not enforce a policy',
      );

      h.browser.remove(room);
      expect(h.browser.rooms.value, isEmpty);
    });

    test('every candidate gets a try, in order', () async {
      final h = harness();
      await h.browser.start();
      h.setReachable(false);
      h.events.add(
        BonsoirDiscoveryServiceResolvedEvent(
          service: service(
            'RoadTrip',
            hosts: const ['fe80::1%en0', '192.168.1.7', 'fd00::5'],
            port: 9,
          ),
        ),
      );
      await settle();
      expect(await h.browser.probe(h.browser.rooms.value.single), isFalse);
      expect(h.attempts.map((a) => a.host), [
        '192.168.1.7', // IPv4 first (§1).
        'fe80::1%en0',
        'fd00::5',
      ]);
    });
  });

  group('mDNS querier wire format', () {
    test('a PTR query names the type and asks for a unicast answer', () {
      final query = buildPtrQuery(jamServiceType);
      expect(parseDnsQuestions(query), ['_localjam._tcp.local']);
      expect((query[4] << 8) | query[5], 1, reason: 'one question');
      expect(query[2] & 0x80, 0, reason: 'a query, not a response');
      // qtype PTR, qclass QU|IN.
      expect(query.sublist(query.length - 4), [0, 12, 0x80, 0x01]);
    });

    test('PTR answers are read back out of a response, goodbyes included', () {
      final packet = _ptrResponse([
        (instance: 'RoadTrip', ttl: 120),
        (instance: 'Kitchen', ttl: 0),
      ]);
      final answers = parseMdnsPtrAnswers(packet);
      expect(answers.map((a) => a.instanceName), ['RoadTrip', 'Kitchen']);
      expect(answers.every((a) => a.serviceType == '_localjam._tcp.local'),
          isTrue);
      expect(answers.first.isGoodbye, isFalse);
      expect(answers.last.isGoodbye, isTrue);
    });

    test('a question, a truncated record and junk all parse to nothing', () {
      expect(parseMdnsPtrAnswers(buildPtrQuery(jamServiceType)), isEmpty);
      final packet = _ptrResponse([(instance: 'RoadTrip', ttl: 120)]);
      expect(parseMdnsPtrAnswers(packet.sublist(0, packet.length - 4)),
          isEmpty);
      expect(parseMdnsPtrAnswers(Uint8List.fromList([1, 2, 3])), isEmpty);
    });
  });
}

/// A minimal mDNS response carrying PTR answers for `_localjam._tcp.local`.
Uint8List _ptrResponse(List<({String instance, int ttl})> answers) {
  final type = encodeDnsName(const ['_localjam', '_tcp', 'local']);
  final builder = BytesBuilder()
    ..add([0, 0, 0x84, 0, 0, 0]) // id, AA response, qdcount = 0
    ..add([answers.length >> 8, answers.length & 0xff])
    ..add(const [0, 0, 0, 0]);
  for (final answer in answers) {
    final target = encodeDnsName([
      answer.instance,
      '_localjam',
      '_tcp',
      'local',
    ]);
    builder
      ..add(type)
      ..add([
        0, 12, // PTR
        0, 1, // IN
        (answer.ttl >> 24) & 0xff,
        (answer.ttl >> 16) & 0xff,
        (answer.ttl >> 8) & 0xff,
        answer.ttl & 0xff,
        target.length >> 8,
        target.length & 0xff,
      ])
      ..add(target);
  }
  return builder.toBytes();
}
