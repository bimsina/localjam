/// [JamHostEngine] against its real [JamHostServer] on loopback, with the
/// `localjam_audio` method channel mocked (TestDefaultBinaryMessenger): the
/// native audio side does not exist under flutter_test, but everything above
/// it — server, sockets, controller plumbing — is real.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_client/localjam_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'engine_test_utils.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // The test binding fakes every HttpClient with a 400 stub; these tests
  // talk to a real loopback server.
  setUpAll(() => HttpOverrides.global = null);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<JamHostEngine> startEngine({
    JamEndPolicy endPolicy = JamEndPolicy.pause,
  }) async {
    final engine = await JamHostEngine.start(
      sessionName: 'HostJam',
      endPolicy: endPolicy,
      address: InternetAddress.loopbackIPv4,
    );
    addTearDown(engine.close);
    return engine;
  }

  group('the host is a person (§3.1)', () {
    test('hostName defaults to the device identity, and reaches guests '
        'through welcome', () async {
      mockAudioChannel();
      JamIdentity.resetCacheForTesting();
      addTearDown(JamIdentity.resetCacheForTesting);
      SharedPreferences.setMockInitialValues({
        'localjam.displayName': 'Silky Puffin',
      });

      final engine = await startEngine();
      expect(engine.hostPeer.clientName, 'Silky Puffin');
      expect(engine.hostPeer.peerId, JamPermissions.hostPeerId);
      expect(
        engine.peers,
        isEmpty,
        reason: 'the host is not one of its own peers',
      );

      final guest = await JamGuestClient.connect(
        engine.joinUriFor(InternetAddress.loopbackIPv4),
        clientName: 'Funky Walrus',
      );
      addTearDown(guest.close);
      expect(guest.hostPeer?.clientName, 'Silky Puffin');
    });

    test("the host's own tracks are attributed to it by name, not by "
        'role', () async {
      mockAudioChannel();
      final engine = await JamHostEngine.start(
        sessionName: 'HostJam',
        hostName: 'Silky Puffin',
        address: InternetAddress.loopbackIPv4,
        discoverable: false,
      );
      addTearDown(engine.close);
      final item = await engine.addMediaFile(await makeTaggedMp3());
      expect(item.addedBy, JamPermissions.hostPeerId);
      // On the host's own screen it is still "You"...
      expect(engine.addedByLabel(item, engine.peers), 'You');

      // ...and to everyone else it is a name.
      final guest = await JamGuestEngine.join(
        engine.joinUriFor(InternetAddress.loopbackIPv4),
        clientName: 'Funky Walrus',
        mediaCacheDir: await makeTempDir(),
      );
      addTearDown(guest.close);
      expect(guest.addedByLabel(item, guest.peers), 'Silky Puffin');
    });

    test(
      'a contributor who shared no name is never bylined by peer id',
      () async {
        // The byline used to fall back to the peer id ("added by p_7f3a"): a
        // wire token on a screen about people.
        mockAudioChannel();
        final engine = await JamHostEngine.start(
          sessionName: 'HostJam',
          hostName: 'Silky Puffin',
          address: InternetAddress.loopbackIPv4,
          discoverable: false,
        );
        addTearDown(engine.close);
        final item = (await engine.addMediaFile(await makeTaggedMp3()));
        MediaItem by(String peerId) => MediaItem(
          mediaId: item.mediaId,
          kind: item.kind,
          name: item.name,
          mime: item.mime,
          sizeBytes: item.sizeBytes,
          sha256: item.sha256,
          addedBy: peerId,
        );
        const peers = [
          PeerInfo(peerId: 'p_anon', clientName: '', clientKind: 'flutter'),
          PeerInfo(peerId: 'p_blank', clientName: '   ', clientKind: 'web'),
          PeerInfo(peerId: 'p_ana', clientName: ' Ana ', clientKind: 'flutter'),
        ];

        for (final id in ['p_anon', 'p_blank']) {
          // A neutral word by default; the app's own copy when it passes one;
          // nothing at all on request — but never the id.
          expect(engine.addedByLabel(by(id), peers), 'Guest');
          expect(
            engine.addedByLabel(by(id), peers, unnamedLabel: 'Someone'),
            'Someone',
          );
          expect(
            engine.addedByLabel(by(id), peers, unnamedLabel: null),
            isNull,
          );
        }
        expect(engine.addedByLabel(by('p_ana'), peers), 'Ana');
        // Someone who already left has no byline (unchanged).
        expect(engine.addedByLabel(by('p_gone'), peers), isNull);
      },
    );
  });

  group('LAN-only binding (§9)', () {
    test('a room binds every interface whatever the scan found: no LAN, '
        'one, several, or an interface list that never came back', () async {
      mockAudioChannel();
      addTearDown(
        () => JamHostEngine.networkInterfaceLister =
            JamHostEngine.defaultNetworkInterfaceLister,
      );
      for (final interfaces in [
        // Cellular only — e.g. an iPhone whose hotspot has no client yet
        // (its bridge100 only appears once one joins): binding loopback
        // here used to leave the room unreachable for good.
        <NetworkInterface>[
          FakeNetworkInterface('pdp_ip0', ['10.1.1.1']),
        ],
        [
          FakeNetworkInterface('en0', ['192.168.1.7']),
        ],
        [
          FakeNetworkInterface('en0', ['192.168.1.7']),
          FakeNetworkInterface('bridge100', ['172.20.10.1']),
        ],
      ]) {
        JamHostEngine.networkInterfaceLister = () async => interfaces;
        final engine = await JamHostEngine.start(
          sessionName: 'BindJam',
          hostName: 'Silky Puffin',
          discoverable: false,
        );
        // One HttpServer binds one address: anyIPv4 reaches every LAN and
        // the machine itself. §9 is carried by the server's remote-address
        // filter, not by the bind.
        expect(engine.boundAddress, InternetAddress.anyIPv4);
        expect(engine.debugServer.restrictToLanRemotes, isTrue);
        await engine.close();
      }
    });

    test('lanCandidates never offers a loopback or public address', () async {
      final candidates = await JamHostEngine.lanCandidates();
      for (final address in candidates) {
        expect(address.isLoopback, isFalse, reason: address.address);
        expect(
          JamHostServer.isLanAddress(address),
          isTrue,
          reason: address.address,
        );
      }
    });
  });

  test(
    'start → addMediaFile probes the duration → play broadcasts playing',
    () async {
      final log = mockAudioChannel(durationUs: 42_000_000);
      final engine = await startEngine();

      expect(engine.sessionName, 'HostJam');
      expect(engine.port, greaterThan(0));
      // §1 (1.2): the QR carries the http form, token in the fragment; the
      // same room as a `localjam://` deep link is one getter away.
      expect(engine.joinUri.scheme, 'http');
      expect(engine.joinUri.path, '/join');
      expect(engine.joinUri.query, isEmpty);
      expect(engine.joinUri.port, engine.port);
      expect(JoinLink.fromUri(engine.joinUri), engine.joinLink);
      expect(engine.joinLink.token, engine.token);
      expect(engine.joinLink.name, 'HostJam');
      expect(engine.joinUri.host, engine.joinLink.hosts.first);
      expect(engine.localjamUri.scheme, 'localjam');
      expect(JoinLink.fromUri(engine.localjamUri), engine.joinLink);
      expect(engine.snapshot.status, PlaybackStatus.idle);

      // addMediaFile probes the §5.5 duration from the file's headers —
      // never by loading it into the shared engine, which would replace
      // (and could even play) the current track — and registers +
      // broadcasts the playlist item.
      final file = await writeTempMedia(makeMediaBytes(4096));
      final item = await engine.addMediaFile(file, name: 'Song A');
      expect(item.durationUs, 42_000_000);
      expect(item.name, 'Song A');
      expect(item.mime, 'audio/mpeg');
      expect(engine.playlist.map((i) => i.mediaId), [item.mediaId]);
      expect(
        log
            .where((c) => c.method == 'probeDuration')
            .map((c) => (c.arguments as Map)['path']),
        contains(file.path),
      );
      expect(
        log
            .where((c) => c.method == 'load')
            .map((c) => (c.arguments as Map)['path']),
        isNot(contains(file.path)),
        reason: 'a probe must not load the file into the player',
      );

      // A real guest sees the playing broadcast.
      final guest = await JamGuestClient.connect(
        engine.joinUriFor(InternetAddress.loopbackIPv4),
      );
      addTearDown(guest.close);

      final statesSeen = <PlaybackSnapshot>[];
      engine.states.listen(statesSeen.add);

      engine.setMedia(item.mediaId);
      engine.play();
      expect(engine.snapshot.status, PlaybackStatus.playing);
      expect(engine.snapshot.anchor, isNotNull);
      await waitFor(
        () =>
            statesSeen.isNotEmpty &&
            statesSeen.last.status == PlaybackStatus.playing,
        reason: 'states stream to carry the playing broadcast',
      );

      await waitFor(
        () => guest.snapshot.status == PlaybackStatus.playing,
        reason: 'guest to mirror the playing broadcast',
      );
      expect(guest.snapshot.rev, engine.snapshot.rev);

      // The host plays along: its own controller scheduled the anchor.
      await waitFor(
        () => log.any((c) => c.method == 'playAt'),
        reason: 'host-side playAt',
      );
    },
  );

  test('next()/previous() while playing keep the host player scheduled '
      'instead of releasing it (§5.5 ADVANCE parity)', () async {
    final log = mockAudioChannel(durationUs: 42_000_000);
    final engine = await startEngine();
    final a = await engine.addMediaFile(
      await writeTempMedia(makeMediaBytes(4096)),
      name: 'A',
    );
    final b = await engine.addMediaFile(
      await writeTempMedia(makeMediaBytes(4096, seed: 7)),
      name: 'B',
    );

    engine.setMedia(a.mediaId);
    engine.play();
    await waitFor(
      () => log.any((c) => c.method == 'playAt'),
      reason: 'the first scheduled start',
    );
    log.clear();

    // The reported bug: Next left the broadcast at `loading`, so the
    // controller paused the player and never scheduled anything again — the
    // new track sat at 00:00 with the transport showing the play glyph.
    engine.next();
    expect(engine.snapshot.mediaId, b.mediaId);
    expect(engine.snapshot.status, PlaybackStatus.playing);
    await waitFor(
      () => log.any((c) => c.method == 'playAt'),
      reason: 'the new track to be scheduled on the local host player',
    );
    expect(log.where((c) => c.method == 'stop'), isEmpty);
    expect(engine.sync.snapshot?.status, PlaybackStatus.playing);

    log.clear();
    engine.previous();
    expect(engine.snapshot.mediaId, a.mediaId);
    expect(engine.snapshot.status, PlaybackStatus.playing);
    await waitFor(
      () => log.any((c) => c.method == 'playAt'),
      reason: 'previous to re-schedule too',
    );

    // Paused stays paused: the track changes, nothing starts.
    engine.pause();
    log.clear();
    engine.next();
    expect(engine.snapshot.mediaId, b.mediaId);
    expect(engine.snapshot.status, isNot(PlaybackStatus.playing));
    expect(engine.snapshot.positionUs, 0);
    await pumpEventQueue();
    expect(log.where((c) => c.method == 'playAt'), isEmpty);
  });

  test('addMediaFile extracts tags + artwork (§6.1 v0.2, §6.5); the native '
      'duration probe wins over the tag duration', () async {
    mockAudioChannel(durationUs: 42_000_000);
    final engine = await startEngine();

    final item = await engine.addMediaFile(await makeTaggedMp3());
    expect(item.title, 'Night Drive');
    expect(item.artist, 'The Localhosts');
    expect(item.album, 'Loopback Sessions');
    expect(item.displayTitle, 'Night Drive');
    // The mocked native probe answered 42 s; the tag claims ~1 s. The
    // probe wins (§6.1: a decoder probe beats a tag claim).
    expect(item.durationUs, 42_000_000);
    expect(item.artworkId, startsWith('a_'));

    // The host reads artwork from its own registry, no HTTP.
    final artwork = await engine.artworkFor(item);
    expect(artwork, isNotNull);
    expect(artwork, isNotEmpty);

    // An untagged file yields an item with no artist, album or artwork,
    // titled after its name without the extension (§6.1).
    final untagged = await engine.addMediaFile(
      await writeTempMedia(makeMediaBytes(4096)),
      name: 'Untitled.mp3',
    );
    expect(untagged.title, 'Untitled');
    expect(untagged.artist, isNull);
    expect(untagged.artworkId, isNull);
    // The filename fallback drops the extension but keeps `name` intact.
    expect(untagged.name, 'Untitled.mp3');
    expect(untagged.displayTitle, 'Untitled');
    expect(await engine.artworkFor(untagged), isNull);
  });

  test(
    'host-side §5.6 surface: attribution, queue ops, policy/moderation',
    () async {
      mockAudioChannel();
      final engine = await startEngine();

      // The host holds every capability; its items carry host attribution.
      expect(engine.selfPeerId, JamPermissions.hostPeerId);
      expect(engine.can(JamCapability.manageMembers), isTrue);
      final a = await engine.addMediaFile(
        await writeTempMedia(makeMediaBytes(2048, seed: 1)),
        name: 'A.mp3',
      );
      final b = await engine.addMediaFile(
        await writeTempMedia(makeMediaBytes(2048, seed: 2)),
        name: 'B.mp3',
      );
      expect(a.addedBy, JamPermissions.hostPeerId);
      expect(engine.addedByLabel(a, engine.peers), 'You');

      // Queue ops mirror to a real guest.
      final guest = await JamGuestClient.connect(
        engine.joinUriFor(InternetAddress.loopbackIPv4),
      );
      addTearDown(guest.close);
      engine.moveMediaItem(b.mediaId, 0);
      await waitFor(
        () =>
            guest.playlist.isNotEmpty &&
            guest.playlist.first.mediaId == b.mediaId,
        reason: 'reorder to reach the guest',
      );
      engine.removeMediaItem(b.mediaId);
      await waitFor(
        () => guest.playlist.length == 1,
        reason: 'removal to reach the guest',
      );

      // Policy + promotion broadcasts reach the guest's document.
      engine.setPolicy(JamPolicy.open);
      engine.promotePeer(guest.selfPeerId);
      await waitFor(
        () => guest.permissions.cohosts.contains(guest.selfPeerId),
        reason: 'promotion to reach the guest',
      );
      expect(guest.permissions.policy, JamPolicy.open);
      expect(engine.permissions.rev, greaterThanOrEqualTo(2));

      // Kick drops the guest terminally.
      engine.kickPeer(guest.selfPeerId);
      await guest.done.timeout(const Duration(seconds: 5));
      expect(guest.lastFatalError?.code, ErrorCode.kicked);
      expect(engine.peers, isEmpty);
    },
  );

  test(
    'next/previous wrap the playlist; transport mirrors the server',
    () async {
      mockAudioChannel();
      final engine = await startEngine();
      final a = await engine.addMediaFile(
        await writeTempMedia(makeMediaBytes(512, seed: 1), name: 'a.mp3'),
      );
      final b = await engine.addMediaFile(
        await writeTempMedia(makeMediaBytes(512, seed: 2), name: 'b.mp3'),
      );

      engine.setMedia(a.mediaId);
      engine.next();
      expect(engine.snapshot.mediaId, b.mediaId);
      engine.next();
      expect(engine.snapshot.mediaId, a.mediaId, reason: 'wraps forward');
      engine.previous();
      expect(engine.snapshot.mediaId, b.mediaId, reason: 'wraps backward');

      engine.play();
      expect(engine.snapshot.status, PlaybackStatus.playing);
      engine.pause();
      expect(engine.snapshot.status, PlaybackStatus.paused);
      engine.stop();
      expect(engine.snapshot.status, PlaybackStatus.idle);
    },
  );

  test('setNudgeUs applies to the controller and persists', () async {
    mockAudioChannel();
    final engine = await startEngine();

    await engine.setNudgeUs(30_000);
    expect(engine.sync.manualOffsetUs, 30_000);
    expect(engine.nudgeUs.value, 30_000);

    // The persisted value is keyed by output route; the mock names none.
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('nudgeUs.routeId.unknown'), 30_000);
  });

  test(
    'positionUsNow is null with no media and clamps to the duration',
    () async {
      mockAudioChannel(durationUs: 1_000_000);
      final engine = await startEngine();
      expect(engine.positionUsNow(), isNull);

      final item = await engine.addMediaFile(
        await writeTempMedia(makeMediaBytes(256)),
      );
      engine.setMedia(item.mediaId);
      engine.seek(500_000);
      expect(engine.positionUsNow(), 500_000);

      engine.seek(999_999_000); // Server clamps the seek itself (§5.5)...
      expect(engine.positionUsNow(), lessThanOrEqualTo(1_000_000));
    },
  );

  test('the room serves the static site it was given, and one set later '
      '(§1.1)', () async {
    mockAudioChannel();
    final page = StaticSite({
      'index.html': StaticFile.text('<p>player</p>', 'text/html'),
    });
    final engine = await JamHostEngine.start(
      sessionName: 'WebJam',
      hostName: 'Silky Puffin',
      address: InternetAddress.loopbackIPv4,
      discoverable: false,
      staticSite: page,
    );
    addTearDown(engine.close);
    expect(engine.staticSite, same(page));
    Future<String> fetch() async {
      final client = HttpClient();
      try {
        final req = await client.getUrl(
          Uri.parse('http://127.0.0.1:${engine.port}/join'),
        );
        final res = await req.close();
        return await res.transform(const Utf8Decoder()).join();
      } finally {
        client.close(force: true);
      }
    }

    expect(await fetch(), '<p>player</p>');
    engine.staticSite = null;
    expect(await fetch(), contains('no browser player'));
  });
}
