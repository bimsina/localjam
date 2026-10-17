/// `JamHostEngine.start` must produce a room even when the platform under it
/// stops answering. The regression these cover: `bonsoir_darwin`'s
/// `broadcast.start` waited for the Bonjour daemon with a synchronous
/// `DNSServiceProcessResult` on the platform main thread, so on the iOS
/// Simulator (where mDNS never confirms) the method-channel reply never came
/// back and `start()` hung forever — spinner, no room, dead app.
///
/// The vendored plugin (`packages/third_party/bonsoir_darwin`) reads that
/// socket on a background queue, which splits the failure in two, and both
/// halves are covered below: a platform channel that never answers at all
/// (still fatal-looking, still latched off), and a daemon that takes the
/// registration and never confirms it (the Simulator, an unanswered Local
/// Network prompt — the built-in responder's cue, and nothing to latch).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_client/localjam_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'engine_test_utils.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => HttpOverrides.global = null);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    mockAudioChannel();
  });

  tearDown(() {
    JamHostEngine.networkInterfaceLister =
        JamHostEngine.defaultNetworkInterfaceLister;
    JamHostEngine.roomAdvertiserStarter = JamRoomAdvertiser.start;
    JamRoomAdvertiser.resetDaemonState();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_bonsoirChannel, null);
  });

  /// Everything start() may wait on, together, has to fit here.
  const budget = Duration(seconds: 2);

  group('start() is bounded', () {
    test('an interface list that never answers falls back to anyIPv4, '
        'with the LAN-remote filter still carrying §9', () async {
      JamHostEngine.networkInterfaceLister = () =>
          Completer<List<NetworkInterface>>().future; // never completes
      final stopwatch = Stopwatch()..start();
      final engine = await JamHostEngine.start(
        sessionName: 'HangJam',
        hostName: 'Silky Puffin',
        discoverable: false,
      );
      addTearDown(engine.close);
      stopwatch.stop();

      expect(stopwatch.elapsed, lessThan(budget));
      expect(engine.port, greaterThan(0));
      // A LAN we could not enumerate is not a LAN we do not have: binding
      // loopback would have made the room unjoinable.
      expect(
        JamHostEngine.bindAddressFor(const [], enumerated: false),
        InternetAddress.anyIPv4,
      );
      expect(
        JamHostEngine.bindAddressFor(const []),
        InternetAddress.loopbackIPv4,
      );

      // The room still works, on loopback, with the filter on.
      final guest = await JamGuestClient.connect(
        engine.joinUriFor(InternetAddress.loopbackIPv4),
        clientName: 'Funky Walrus',
      );
      addTearDown(guest.close);
      expect(guest.hostPeer?.clientName, 'Silky Puffin');
    });

    test('an advertiser that never answers does not hold the room', () async {
      var started = 0;
      JamHostEngine.roomAdvertiserStarter =
          ({
            required String sessionName,
            required int port,
            required String token,
            List<InternetAddress> addresses = const [],
            Duration timeout = JamRoomAdvertiser.defaultTimeout,
          }) {
            started++;
            return Completer<JamRoomAdvertiser?>().future; // wedged platform
          };

      final stopwatch = Stopwatch()..start();
      final engine = await JamHostEngine.start(
        sessionName: 'HangJam',
        hostName: 'Silky Puffin',
        address: InternetAddress.loopbackIPv4,
      );
      addTearDown(engine.close);
      stopwatch.stop();

      expect(started, 1);
      expect(stopwatch.elapsed, lessThan(budget));
      expect(engine.port, greaterThan(0));
      expect(
        engine.discoverable,
        isFalse,
        reason: 'advertising was abandoned; the room is QR-only',
      );
    });

    test('an advertiser that throws is not fatal either', () async {
      JamHostEngine.roomAdvertiserStarter =
          ({
            required String sessionName,
            required int port,
            required String token,
            List<InternetAddress> addresses = const [],
            Duration timeout = JamRoomAdvertiser.defaultTimeout,
          }) async => throw StateError('no mDNS on this platform');

      final engine = await JamHostEngine.start(
        sessionName: 'HangJam',
        hostName: 'Silky Puffin',
        address: InternetAddress.loopbackIPv4,
      );
      addTearDown(engine.close);
      expect(engine.discoverable, isFalse);
      expect(engine.snapshot.status, PlaybackStatus.idle);
    });

    test('a slow-but-finite interface list is still used', () async {
      final real = await JamHostEngine.defaultNetworkInterfaceLister();
      JamHostEngine.networkInterfaceLister = () =>
          Future.delayed(const Duration(milliseconds: 20), () => real);
      final engine = await JamHostEngine.start(
        sessionName: 'SlowJam',
        hostName: 'Silky Puffin',
        address: InternetAddress.loopbackIPv4,
        discoverable: false,
      );
      addTearDown(engine.close);
      final hosts = engine.joinUri.queryParameters['host']!.split(',');
      // Loopback is always the last candidate: a guest on this same machine
      // (a second simulator, the CLI) has no other path in.
      expect(hosts.last, InternetAddress.loopbackIPv4.address);
    });

    test('prefs that never answer cost start() at most one identity '
        'timeout', () async {
      JamIdentity.resetCacheForTesting();
      addTearDown(JamIdentity.resetCacheForTesting);
      // A platform channel with no handler at all: SharedPreferences throws
      // rather than resolving, which the identity swallows into a generated
      // name instead of propagating into start().
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/shared_preferences'),
            (call) async => throw MissingPluginException(),
          );
      final engine = await JamHostEngine.start(
        sessionName: 'PrefsJam',
        address: InternetAddress.loopbackIPv4,
        discoverable: false,
      );
      addTearDown(engine.close);
      expect(engine.hostPeer.clientName, isNotEmpty);
    });
  });

  group('the mDNS announcer speaks DNS', () {
    test('names are length-prefixed labels with a root terminator', () {
      expect(
        encodeDnsName(const ['_localjam', '_tcp', 'local']),
        Uint8List.fromList([
          9, ..._ascii('_localjam'), //
          4, ..._ascii('_tcp'), //
          5, ..._ascii('local'), //
          0,
        ]),
      );
    });

    test('question names are read back, compression pointers included', () {
      // One question for `_localjam._tcp.local` (PTR, IN), then a second
      // that points back at it.
      final packet = Uint8List.fromList([
        0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, // header, qdcount = 2
        ...encodeDnsName(const ['_localjam', '_tcp', 'local']),
        0, 12, 0, 1, // qtype PTR, qclass IN
        0xc0, 12, // pointer back to offset 12
        0, 12, 0, 1,
      ]);
      expect(parseDnsQuestions(packet), [
        '_localjam._tcp.local',
        '_localjam._tcp.local',
      ]);
    });

    test('announcements are rate-limited and coalesced', () async {
      // A responder that answers every query it hears is an amplifier: a
      // few dozen bytes of query buys a full record set multicast to the
      // whole segment, as often as the queries arrive.
      var sends = 0;
      final throttle = MdnsAnnounceThrottle(
        send: () => sends++,
        minInterval: const Duration(milliseconds: 120),
      );
      addTearDown(throttle.cancel);

      throttle.request();
      expect(sends, 1, reason: 'the first one goes out at once');
      // A burst inside the window collapses into ONE deferred send.
      for (var i = 0; i < 50; i++) {
        throttle.request();
      }
      expect(sends, 1, reason: 'nothing extra while the window is open');
      expect(throttle.hasPending, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(sends, 2, reason: 'the burst coalesced into one');
      expect(throttle.hasPending, isFalse);

      // And the window reopens: a request after it sends immediately again.
      await Future<void>.delayed(const Duration(milliseconds: 150));
      throttle.request();
      expect(sends, 3);
    });

    test('a pending announcement can be dropped without sending', () async {
      var sends = 0;
      final throttle = MdnsAnnounceThrottle(
        send: () => sends++,
        minInterval: const Duration(milliseconds: 100),
      );
      throttle.request();
      throttle.request();
      expect(throttle.hasPending, isTrue);
      throttle.cancel(); // stop(): the goodbye is sent unthrottled instead.
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(sends, 1);
    });

    test('a truncated packet yields nothing rather than throwing', () {
      expect(parseDnsQuestions(Uint8List.fromList([0, 0, 0])), isEmpty);
      expect(
        parseDnsQuestions(
          Uint8List.fromList([0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 9, 1]),
        ),
        isEmpty,
      );
    });

    test(
      'start() gives up inside its timeout when the socket is refused',
      () async {
        final stopwatch = Stopwatch()..start();
        final announcer = await MdnsAnnouncer.start(
          serviceName: 'Nope',
          serviceType: jamServiceType,
          // Port 1 is privileged: binding it fails everywhere the tests run.
          port: 1,
          attributes: const {},
          addresses: const [],
          timeout: const Duration(milliseconds: 200),
        );
        stopwatch.stop();
        addTearDown(() async => announcer?.stop());
        // Either it bound (a machine that allows 5353) or it gave up — what it
        // must never do is throw or block.
        expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
      },
    );
  });

  group('the OS Bonjour daemon goes first', () {
    test('a daemon that answers takes the room, and the built-in responder '
        'is never reached', () async {
      final calls = <String>[];
      _mockBonsoirDaemon(confirms: true, calls: calls);

      final advertiser = await JamRoomAdvertiser.start(
        sessionName: 'Van Jam',
        port: 44100,
        token: 'cafebabecafebabe',
      );
      addTearDown(() async => advertiser?.stop());

      expect(calls, ['broadcast.initialize', 'broadcast.start']);
      expect(advertiser?.transport, 'bonjour');
      expect(JamRoomAdvertiser.daemonWedged, isFalse);
    });

    test('a platform channel that never answers is abandoned inside its '
        'budget, and is not asked a second time', () async {
      var initializes = 0;
      _mockBonsoir((call) async {
        if (call.method == 'broadcast.initialize') {
          initializes++;
          return true;
        }
        if (call.method == 'broadcast.start') {
          // The platform thread is gone: not even the method call comes back.
          return Completer<Object?>().future;
        }
        return true;
      });

      final stopwatch = Stopwatch()..start();
      final first = await JamRoomAdvertiser.start(
        sessionName: 'Van Jam',
        port: 44100,
        token: 'cafebabecafebabe',
        timeout: const Duration(milliseconds: 200),
      );
      stopwatch.stop();
      addTearDown(() async => first?.stop());

      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
      expect(initializes, 1);
      expect(
        JamRoomAdvertiser.daemonWedged,
        isTrue,
        reason: 'the platform side is not answering; it has had its chance',
      );

      // A second room in the same process must not walk into it again.
      final second = await JamRoomAdvertiser.start(
        sessionName: 'Other Jam',
        port: 44101,
        token: 'deadbeefdeadbeef',
        timeout: const Duration(milliseconds: 200),
      );
      addTearDown(() async => second?.stop());
      expect(initializes, 1);
      expect(second?.transport, anyOf(isNull, 'builtin'));
    });

    test('a registration the daemon takes but never confirms hands over to '
        'the built-in responder, and does not latch the daemon off', () async {
      // The Apple Simulator, an unanswered Local Network prompt, a LAN that
      // filters Bonjour: `broadcast.start` returns, `broadcastStarted` never
      // arrives. Nothing is stuck, so the next room still gets to ask.
      final calls = <String>[];
      _mockBonsoirDaemon(confirms: false, calls: calls);

      final stopwatch = Stopwatch()..start();
      final advertiser = await JamRoomAdvertiser.start(
        sessionName: 'Van Jam',
        port: 44100,
        token: 'cafebabecafebabe',
        timeout: const Duration(milliseconds: 200),
      );
      stopwatch.stop();
      addTearDown(() async => advertiser?.stop());

      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
      expect(calls, contains('broadcast.start'));
      expect(advertiser?.transport, anyOf(isNull, 'builtin'));
      expect(
        JamRoomAdvertiser.daemonWedged,
        isFalse,
        reason: 'an unconfirmed registration is not a wedged thread',
      );
    });

    test('a daemon that refuses hands over without wedging the path', () async {
      _mockBonsoir((call) async => throw PlatformException(code: 'nope'));
      final advertiser = await JamRoomAdvertiser.start(
        sessionName: 'Van Jam',
        port: 44100,
        token: 'cafebabecafebabe',
      );
      addTearDown(() async => advertiser?.stop());
      expect(JamRoomAdvertiser.daemonWedged, isFalse);
      expect(advertiser?.transport, anyOf(isNull, 'builtin'));
    });
  });

  group('the registered instance name', () {
    test('carries token entropy so a restart never collides with its own '
        'stale registration', () {
      final name = JamRoomAdvertiser.instanceNameFor('Van Jam', 'cafebabe');
      expect(name, 'Van Jam cafe');
      expect(
        JamRoomAdvertiser.instanceNameFor('Van Jam', 'deadbeef'),
        isNot(name),
      );
    });

    test('fits in a 63-byte DNS-SD label, counting bytes not characters', () {
      final long = JamRoomAdvertiser.instanceNameFor('🎶' * 40, 'cafebabe');
      expect(utf8.encode(long).length, lessThanOrEqualTo(63));
    });

    test('is never empty, even for an unnamed room', () {
      expect(JamRoomAdvertiser.instanceNameFor('   ', 'cafebabe'), isNotEmpty);
      expect(JamRoomAdvertiser.instanceNameFor('', ''), isNotEmpty);
    });
  });
}

/// bonsoir's method channel; the plugin registers no Dart-side fake, so a
/// test that wants a daemon has to be one.
const MethodChannel _bonsoirChannel = MethodChannel('fr.skyost.bonsoir');

void _mockBonsoir(Future<Object?>? Function(MethodCall call) handler) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_bonsoirChannel, handler);
}

/// A fake Bonjour daemon: the method channel AND the per-broadcast event
/// channel the plugin opens.
///
/// Both are needed now. The vendored `bonsoir_darwin` answers
/// `broadcast.start` as soon as the registration has been *requested*, so what
/// says the room is actually on the wire is the `broadcastStarted` event —
/// [confirms] is whether this daemon ever sends it.
void _mockBonsoirDaemon({required bool confirms, List<String>? calls}) {
  _mockBonsoir((call) async {
    calls?.add(call.method);
    final arguments = Map<String, Object?>.from(call.arguments as Map);
    if (call.method == 'broadcast.initialize') {
      // The event channel is named after the action id the Dart side made up.
      final channel = EventChannel(
        'fr.skyost.bonsoir.broadcast.'
        '${arguments['id']}',
      );
      final service = <String, Object?>{
        for (final entry in arguments.entries)
          if (entry.key.startsWith('service.')) entry.key: entry.value,
      };
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockStreamHandler(
            channel,
            MockStreamHandler.inline(
              onListen: (Object? _, MockStreamHandlerEventSink sink) {
                if (confirms) {
                  sink.success(<String, Object?>{
                    'id': 'broadcastStarted',
                    'service': service,
                  });
                }
              },
            ),
          );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockStreamHandler(channel, null),
      );
    }
    return true;
  });
}

List<int> _ascii(String value) => value.codeUnits;
