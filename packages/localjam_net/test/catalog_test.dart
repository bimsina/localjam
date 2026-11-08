/// The host's library as a browsable catalog (PROTOCOL.md §6.6, protocol
/// 1.3): a real JamHostServer offering a catalog to real guests over
/// 127.0.0.1 loopback.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:localjam_net/localjam_net.dart';
import 'package:test/test.dart';

import 'test_fixtures.dart';

/// A catalog over files on disk, whose [open] can be held at a [gate] (and
/// [openForArtwork] at an [artGate], the probe at a [probeGate]) so a test
/// can see adds and cover reads pile up, and which records every call.
class _TestCatalog extends JamCatalogProvider {
  _TestCatalog(this.files, {List<CatalogEntry>? entries})
    : entriesNow =
          entries ??
          [
            for (final id in files.keys)
              CatalogEntry(catalogId: id, title: 'Song $id'),
          ];

  final Map<String, File> files;

  /// What [entries] answers; a test changes it and calls `setCatalog` with
  /// the same provider to refresh.
  List<CatalogEntry> entriesNow;
  bool entriesThrow = false;

  final List<String> opened = [];
  final List<String> openedForArtwork = [];
  Completer<void>? gate;
  Completer<void>? artGate;
  Completer<void>? probeGate;
  void Function(String catalogId)? onOpened;
  final Set<String> throwOnOpen = {};
  final Set<String> throwOnProbe = {};
  int? probed;
  int probeCalls = 0;
  int artActive = 0;
  int artMaxActive = 0;

  @override
  List<CatalogEntry> get entries {
    if (entriesThrow) throw StateError('library unavailable');
    return entriesNow;
  }

  @override
  Future<File?> open(String catalogId) async {
    opened.add(catalogId);
    final held = gate;
    if (held != null) await held.future;
    if (throwOnOpen.contains(catalogId)) throw const FileSystemException('x');
    onOpened?.call(catalogId);
    return files[catalogId];
  }

  @override
  Future<File?> openForArtwork(String catalogId) async {
    openedForArtwork.add(catalogId);
    artActive++;
    if (artActive > artMaxActive) artMaxActive = artActive;
    try {
      final held = artGate;
      if (held != null) await held.future;
      return files[catalogId];
    } finally {
      artActive--;
    }
  }

  @override
  Future<int?> probeDurationUs(String catalogId, File file) async {
    probeCalls++;
    final held = probeGate;
    if (held != null) await held.future;
    if (throwOnProbe.contains(catalogId)) throw StateError('no probe');
    return probed;
  }
}

/// Like [_TestCatalog] but leaves [openForArtwork] to the default.
class _OpenOnlyCatalog extends JamCatalogProvider {
  _OpenOnlyCatalog(this.files);

  final Map<String, File> files;
  final List<String> opened = [];

  @override
  List<CatalogEntry> get entries => [
    for (final id in files.keys) CatalogEntry(catalogId: id, title: id),
  ];

  @override
  Future<File?> open(String catalogId) async {
    opened.add(catalogId);
    return files[catalogId];
  }
}

Future<JamHostServer> _startHost({
  JamPolicy policy = JamPolicy.open,
  int maxCatalogIdsPerRequest = JamHostServer.defaultMaxCatalogIdsPerRequest,
  int maxPendingCatalogAdds = JamHostServer.defaultMaxPendingCatalogAdds,
  int maxPendingCatalogAddsPerPeer =
      JamHostServer.defaultMaxPendingCatalogAddsPerPeer,
  int maxPlaylistLength = JamHostServer.defaultMaxPlaylistLength,
  Directory? uploadDir,
}) async {
  final host = JamHostServer(
    sessionName: 'CatalogJam',
    hostName: 'Silky Puffin',
    policy: policy,
    maxCatalogIdsPerRequest: maxCatalogIdsPerRequest,
    maxPendingCatalogAdds: maxPendingCatalogAdds,
    maxPendingCatalogAddsPerPeer: maxPendingCatalogAddsPerPeer,
    maxPlaylistLength: maxPlaylistLength,
    uploadDir: uploadDir,
  );
  await host.start(address: InternetAddress.loopbackIPv4);
  addTearDown(host.close);
  return host;
}

Future<JamGuestClient> _join(
  JamHostServer host, {
  String clientName = 'guest',
  String? clientId,
}) async {
  final guest = await JamGuestClient.connect(
    host.joinUriFor(InternetAddress.loopbackIPv4),
    clientName: clientName,
    clientId: clientId,
  );
  addTearDown(guest.close);
  return guest;
}

Future<void> _waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
  String reason = 'condition',
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('Timed out waiting for $reason');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// `GET [path]` on [host] with its bearer token (or [bearer]): the status
/// and the body.
Future<({int status, Uint8List body, String? contentType})> _get(
  JamHostServer host,
  String path, {
  String? bearer,
}) async {
  final http = HttpClient();
  try {
    final req = await http.getUrl(
      Uri.parse('http://127.0.0.1:${host.port}$path'),
    );
    req.headers.set(
      HttpHeaders.authorizationHeader,
      'Bearer ${bearer ?? host.token}',
    );
    final res = await req.close();
    final builder = BytesBuilder();
    await res.forEach(builder.add);
    return (
      status: res.statusCode,
      body: builder.takeBytes(),
      contentType: res.headers.contentType?.mimeType,
    );
  } finally {
    http.close(force: true);
  }
}

/// Distinct untagged MP3s: each length is different content.
Future<Map<String, File>> _untagged(List<String> ids) async => {
  for (var i = 0; i < ids.length; i++)
    ids[i]: await makeUntaggedMp3(frames: 20 + i, name: '${ids[i]}.mp3'),
};

void main() {
  group('offering a catalog (§6.6)', () {
    test(
      'a joiner sees the catalog in welcome; a change is broadcast',
      () async {
        final host = await _startHost();
        final catalog = _TestCatalog(await _untagged(['c_1', 'c_2']));
        expect(host.catalog, isNull);
        host.setCatalog(catalog);
        expect(host.catalog, const CatalogSummary(rev: 1, count: 2));

        final guest = await _join(host);
        expect(guest.catalog, const CatalogSummary(rev: 1, count: 2));

        final late = await _join(host, clientName: 'late');
        final updated = late.catalogUpdates.first;
        // The library changed: a new rev.
        catalog.entriesNow = [
          ...catalog.entriesNow,
          const CatalogEntry(catalogId: 'c_3', title: 'Three'),
        ];
        host.setCatalog(catalog);
        expect(await updated, const CatalogSummary(rev: 2, count: 3));
        await _waitFor(() => guest.catalog?.rev == 2, reason: 'broadcast');

        // Nothing was opened just to offer it.
        expect(catalog.opened, isEmpty);
      },
    );

    test('a host without a catalog sends none, and /catalog is 404', () async {
      final host = await _startHost();
      final guest = await _join(host);
      expect(guest.catalog, isNull);
      expect(await guest.fetchCatalogListing(), isNull);
      expect((await _get(host, '/catalog')).status, 404);
      host.setCatalog(null); // Nothing to turn off: no broadcast, no rev.
      expect(host.catalog, isNull);
    });

    test('the session fetches the listing, cached by rev', () async {
      final host = await _startHost();
      host.setCatalog(
        _TestCatalog(
          await _untagged(['c_1', 'c_2']),
          entries: const [
            CatalogEntry(
              catalogId: 'c_1',
              title: 'One',
              artist: 'A',
              durationUs: 1_000_000,
              hasArtwork: false,
            ),
            CatalogEntry(catalogId: 'c_2', title: 'Two'),
            // Not a path segment: never offered.
            CatalogEntry(catalogId: 'a/b', title: 'Bad id'),
            // A repeated id: the first wins.
            CatalogEntry(catalogId: 'c_1', title: 'Duplicate'),
          ],
        ),
      );
      expect(host.catalog!.count, 2);
      final session = await JamGuestSession.connect(
        host.joinUriFor(InternetAddress.loopbackIPv4),
        clientName: 'browser',
      );
      addTearDown(session.close);
      expect(session.catalog, const CatalogSummary(rev: 1, count: 2));

      final first = await session.fetchCatalog();
      expect([for (final e in first) e.catalogId], ['c_1', 'c_2']);
      expect(first.first.title, 'One');
      expect(first.first.artist, 'A');
      expect(first.first.hasArtwork, isFalse);
      // Same rev: the cached listing, no new request.
      expect(identical(await session.fetchCatalog(), first), isTrue);

      final changed = session.catalogChanges.first;
      host.setCatalog(
        _TestCatalog(
          await _untagged(['c_9']),
          entries: const [CatalogEntry(catalogId: 'c_9', title: 'Nine')],
        ),
      );
      expect(await changed, const CatalogSummary(rev: 2, count: 1));
      final second = await session.fetchCatalog();
      expect([for (final e in second) e.catalogId], ['c_9']);

      final gone = session.catalogChanges.first;
      host.setCatalog(null);
      expect(await gone, isNull);
      expect(await session.fetchCatalog(), isEmpty);
    });

    test('/catalog needs the token and GET', () async {
      final host = await _startHost();
      host.setCatalog(_TestCatalog(await _untagged(['c_1'])));
      expect((await _get(host, '/catalog', bearer: 'nope')).status, 401);
      final ok = await _get(host, '/catalog');
      expect(ok.status, 200);
      expect(ok.contentType, 'application/json');
      expect(
        (await _get(host, '/catalog/c_1/artwork', bearer: 'nope')).status,
        401,
      );
    });
  });

  group('catalog_add (§6.6)', () {
    test('an add lands as a playlist item credited to the requester, '
        'with host-extracted tags and cover', () async {
      final host = await _startHost();
      final tagged = await makeTaggedMp3(name: 'night.mp3');
      final catalog = _TestCatalog(
        {'c_7': tagged},
        entries: const [
          CatalogEntry(
            catalogId: 'c_7',
            title: 'Library Title',
            durationUs: 2_000_000,
          ),
        ],
      )..probed = 1_234_000;
      host.setCatalog(catalog);
      final guest = await _join(host);
      final events = <JamHostEvent>[];
      final sub = host.events.listen(events.add);
      addTearDown(sub.cancel);

      await guest.requestCatalogAdd(['c_7']);
      await _waitFor(() => guest.playlist.isNotEmpty, reason: 'the add');

      final item = guest.playlist.single;
      final digest = sha256.convert(await tagged.readAsBytes()).toString();
      expect(item.mediaId, 'm_${digest.substring(0, 12)}');
      expect(item.sha256, digest);
      expect(item.addedBy, guest.selfPeerId);
      expect(item.title, 'Night Drive'); // The file's tag beats the library.
      expect(item.artist, 'The Localhosts');
      expect(item.durationUs, 1_234_000); // A probe beats both.
      expect(item.mime, 'audio/mpeg');
      expect(item.artworkId, isNotNull);
      expect(await guest.fetchArtwork(item.artworkId!), tinyPngBytes);
      expect(host.mediaFile(item.mediaId)!.path, tagged.path);

      final added = events.singleWhere(
        (e) => e.kind == JamHostEventKind.catalogAdded,
      );
      expect(added.peerId, guest.selfPeerId);
      expect(added.mediaId, item.mediaId);
      expect(added.catalogId, 'c_7');
      // The event comes before the broadcast it produces.
      expect(
        events.indexOf(added),
        lessThan(
          events.indexWhere(
            (e) => e.kind == JamHostEventKind.playlistBroadcast,
          ),
        ),
      );

      // It is a playlist item now: its bytes are servable like any.
      final bytes = await guest.fetchMedia(item.mediaId);
      expect(bytes, await tagged.readAsBytes());
    });

    test('an untagged file falls back to the library metadata', () async {
      final host = await _startHost();
      host.setCatalog(
        _TestCatalog(
          await _untagged(['c_1']),
          entries: const [
            CatalogEntry(
              catalogId: 'c_1',
              title: 'From The Library',
              artist: 'Lib Artist',
              durationUs: 3_000_000,
            ),
          ],
        ),
      );
      final guest = await _join(host);
      await guest.requestCatalogAdd(['c_1']);
      await _waitFor(() => guest.playlist.isNotEmpty, reason: 'the add');
      final item = guest.playlist.single;
      expect(item.title, 'From The Library');
      expect(item.artist, 'Lib Artist');
      expect(item.durationUs, 3_000_000); // No probe: the library's.
      expect(item.name, 'c_1.mp3');
    });

    test('a library title that is a filename loses its extension', () async {
      final host = await _startHost();
      host.setCatalog(
        _TestCatalog(
          await _untagged(['c_1']),
          entries: const [CatalogEntry(catalogId: 'c_1', title: 'memo.mp3')],
        ),
      );
      final guest = await _join(host);
      await guest.requestCatalogAdd(['c_1']);
      await _waitFor(() => guest.playlist.isNotEmpty, reason: 'the add');
      expect(guest.playlist.single.title, 'memo');
    });

    test('without add_tracks: not_allowed, and nothing is opened', () async {
      final host = await _startHost(policy: JamPolicy.listenOnly);
      final catalog = _TestCatalog(await _untagged(['c_1']));
      host.setCatalog(catalog);
      final guest = await _join(host);
      final error = guest.errors.first;
      await guest.requestCatalogAdd(['c_1']);
      final refused = await error;
      expect(refused.code, ErrorCode.notAllowed);
      expect(refused.fatal, isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(catalog.opened, isEmpty);
      expect(host.playlist, isEmpty);
    });

    test('unknown ids are skipped; the known ones land in order', () async {
      final host = await _startHost();
      host.setCatalog(_TestCatalog(await _untagged(['c_1', 'c_2'])));
      final guest = await _join(host);
      await guest.requestCatalogAdd(['c_404', 'c_2', 'nope', 'c_1', 'c_2']);
      await _waitFor(() => guest.playlist.length == 2, reason: 'two adds');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(
        [for (final i in guest.playlist) i.title],
        ['Song c_2', 'Song c_1'],
      );
      expect(host.debugCatalogAddsPending, 0);
    });

    test('ids past the per-request cap are dropped', () async {
      final host = await _startHost(maxCatalogIdsPerRequest: 2);
      final catalog = _TestCatalog(await _untagged(['c_1', 'c_2', 'c_3']));
      host.setCatalog(catalog);
      final guest = await _join(host);
      await guest.requestCatalogAdd(['c_1', 'c_2', 'c_3']);
      await _waitFor(() => guest.playlist.length == 2, reason: 'two adds');
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(guest.playlist, hasLength(2));
      expect(catalog.opened, ['c_1', 'c_2']);
      expect(JamHostServer.defaultMaxCatalogIdsPerRequest, 50);
    });

    test('past the pending-adds bound the host answers busy', () async {
      final host = await _startHost(maxPendingCatalogAdds: 2);
      final catalog = _TestCatalog(
        await _untagged(['c_1', 'c_2', 'c_3', 'c_4']),
      )..gate = Completer<void>();
      host.setCatalog(catalog);
      final guest = await _join(host);
      final other = await _join(host, clientName: 'other');

      final busy = guest.errors.first;
      await guest.requestCatalogAdd(['c_1', 'c_2', 'c_3']);
      final first = await busy;
      expect(first.code, ErrorCode.busy);
      expect(first.fatal, isFalse);
      expect(host.debugCatalogAddsPending, 2);

      // The bound is across all peers.
      final otherBusy = other.errors.first;
      await other.requestCatalogAdd(['c_4']);
      expect((await otherBusy).code, ErrorCode.busy);

      catalog.gate!.complete();
      await _waitFor(() => guest.playlist.length == 2, reason: 'two adds');
      await _waitFor(() => host.debugCatalogAddsPending == 0, reason: 'drain');
      expect(catalog.opened, ['c_1', 'c_2']);
      expect(JamHostServer.defaultMaxPendingCatalogAdds, 128);
    });

    test('the guests’ playlist cap counts catalog adds', () async {
      final host = await _startHost(maxPlaylistLength: 2);
      final own = await makeUntaggedMp3(frames: 99, name: 'own.mp3');
      host.addMedia(
        await JamHostServer.describeFile(own, kind: MediaKind.audio),
        own,
      );
      host.setCatalog(_TestCatalog(await _untagged(['c_1', 'c_2'])));
      final guest = await _join(host);
      final busy = guest.errors.first;
      await guest.requestCatalogAdd(['c_1', 'c_2']);
      expect((await busy).code, ErrorCode.busy);
      await _waitFor(() => guest.playlist.length == 2, reason: 'one add');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(guest.playlist, hasLength(2));
    });

    test('adds are idempotent; removed content goes back in, credited to '
        'whoever put it back', () async {
      final host = await _startHost();
      host.setCatalog(_TestCatalog(await _untagged(['c_1'])));
      final alice = await _join(host, clientName: 'alice');
      final bob = await _join(host, clientName: 'bob');
      final added = <JamHostEvent>[];
      final sub = host.events
          .where((e) => e.kind == JamHostEventKind.catalogAdded)
          .listen(added.add);
      addTearDown(sub.cancel);

      await alice.requestCatalogAdd(['c_1']);
      await _waitFor(() => alice.playlist.length == 1, reason: 'the add');
      final mediaId = alice.playlist.single.mediaId;

      // Again, by someone else: already queued, nothing changes.
      await bob.requestCatalogAdd(['c_1']);
      await _waitFor(
        () => host.debugCatalogAddsPending == 0,
        reason: 'the no-op',
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(host.playlist.single.addedBy, alice.selfPeerId);
      expect(added, hasLength(1));

      host.removeMediaItem(mediaId);
      await _waitFor(() => bob.playlist.isEmpty, reason: 'the removal');
      await bob.requestCatalogAdd(['c_1']);
      await _waitFor(() => bob.playlist.length == 1, reason: 'back in');
      expect(bob.playlist.single.mediaId, mediaId);
      expect(bob.playlist.single.addedBy, bob.selfPeerId);
      expect(added, hasLength(2));
      expect(added.last.peerId, bob.selfPeerId);
    });

    test('the host adds from its own catalog, credited to "host"', () async {
      final host = await _startHost();
      host.setCatalog(_TestCatalog(await _untagged(['c_1'])));
      final first = await host.addFromCatalog('c_1');
      expect(first!.added, isTrue);
      expect(first.item.addedBy, JamPermissions.hostPeerId);
      expect(host.playlist.single.mediaId, first.item.mediaId);
      final again = await host.addFromCatalog('c_1');
      expect(again!.added, isFalse);
      expect(host.playlist, hasLength(1));
      expect(await host.addFromCatalog('c_404'), isNull);
    });

    test('turning the catalog off broadcasts count 0, 404s the listing, and '
        'stops pending adds', () async {
      final host = await _startHost();
      final catalog = _TestCatalog(await _untagged(['c_1', 'c_2']))
        ..gate = Completer<void>();
      host.setCatalog(catalog);
      final guest = await _join(host);
      await guest.requestCatalogAdd(['c_1', 'c_2']);
      await _waitFor(() => catalog.opened.isNotEmpty, reason: 'first open');

      final off = guest.catalogUpdates.first;
      host.setCatalog(null);
      expect(await off, isNull); // The wire said {rev: 2, count: 0}.
      expect(host.catalog, isNull);
      expect(host.debugCatalogAddsPending, lessThanOrEqualTo(1));

      catalog.gate!.complete();
      await _waitFor(() => host.debugCatalogAddsPending == 0, reason: 'drain');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(host.playlist, isEmpty);
      expect(catalog.opened, ['c_1']);
      expect((await _get(host, '/catalog')).status, 404);
      expect((await _get(host, '/catalog/c_1/artwork')).status, 404);

      // And a request now changes nothing.
      await guest.requestCatalogAdd(['c_2']);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(catalog.opened, ['c_1']);

      // A joiner after that is told nothing.
      final joiner = await _join(host, clientName: 'joiner');
      expect(joiner.catalog, isNull);
    });

    test('the wire form of turning it off is rev+1, count 0', () async {
      final host = await _startHost();
      host.setCatalog(_TestCatalog(await _untagged(['c_1'])));
      final ws = await WebSocket.connect('ws://127.0.0.1:${host.port}/ws');
      addTearDown(ws.close);
      const codec = MessageCodec();
      final frames = ws.map((f) => codec.decode(f as String).message);
      final seen = <Message>[];
      final sub = frames.listen(seen.add);
      addTearDown(sub.cancel);
      ws.add(
        codec.encode(
          HelloMessage(
            token: host.token,
            clientName: 'raw',
            clientKind: 'dart',
          ),
          seq: 0,
        ),
      );
      await _waitFor(() => seen.any((m) => m is WelcomeMessage));
      expect(
        seen.whereType<WelcomeMessage>().single.catalog,
        const CatalogSummary(rev: 1, count: 1),
      );
      // Malformed ids change nothing and cost nothing: not a list, not
      // strings, far too many.
      for (final ids in <Object?>[
        'c_1',
        [1, 2, null],
        {'c_1': true},
        [for (var i = 0; i < 5000; i++) 'c_$i'],
      ]) {
        ws.add(
          '{"v":1,"type":"request","seq":1,"payload":'
          '{"action":"catalog_add","catalogIds":${jsonEncode(ids)}}}',
        );
      }
      ws.add(codec.encode(const ClockPingMessage(t0: 1), seq: 2));
      await _waitFor(() => seen.any((m) => m is ClockPongMessage));
      await _waitFor(() => host.playlist.length == 1, reason: 'c_1 (capped)');

      host.setCatalog(null);
      await _waitFor(() => seen.any((m) => m is CatalogMessage));
      expect(seen.whereType<CatalogMessage>().single.payloadToJson(), {
        'rev': 2,
        'count': 0,
      });
    });
  });

  group('playlist items name their catalog entry (§6.1 catalogId, 1.3)', () {
    test('set on guest and host catalog adds, absent on uploads and host '
        'files, and kept through idempotent adds and re-adds', () async {
      final host = await _startHost();
      final files = await _untagged(['c_1', 'c_2', 'c_3']);
      host.setCatalog(_TestCatalog(files));
      final alice = await _join(host, clientName: 'alice');
      final bob = await _join(host, clientName: 'bob');

      // A guest's add.
      await alice.requestCatalogAdd(['c_1']);
      await _waitFor(() => alice.playlist.length == 1, reason: 'the add');
      final c1 = alice.playlist.single;
      expect(c1.catalogId, 'c_1');
      expect(c1.addedBy, alice.selfPeerId);
      expect(host.playlist.single.catalogId, 'c_1');

      // The host's own add.
      final own = await host.addFromCatalog('c_2');
      expect(own!.item.catalogId, 'c_2');
      await _waitFor(() => bob.playlist.length == 2, reason: 'host add');
      expect(bob.playlist.last.catalogId, 'c_2');

      // An upload, and a host file: no catalog row.
      final upload = await bob.uploadMedia(
        await makeUntaggedMp3(frames: 90, name: 'up.mp3'),
        kind: MediaKind.audio,
      );
      expect(upload.catalogId, isNull);
      final hostFile = await makeUntaggedMp3(frames: 91, name: 'hostfile.mp3');
      host.addMedia(
        await JamHostServer.describeFile(hostFile, kind: MediaKind.audio),
        hostFile,
      );
      await _waitFor(() => alice.playlist.length == 4, reason: 'four items');
      expect(
        [for (final i in alice.playlist) i.catalogId],
        ['c_1', 'c_2', null, null],
      );
      expect(upload.toJson().containsKey('catalogId'), isFalse);

      // Content already queued (as an upload of c_3's bytes) keeps what it
      // has: the catalog add is a no-op.
      final asUpload = await bob.uploadMedia(
        files['c_3']!,
        kind: MediaKind.audio,
      );
      expect(asUpload.catalogId, isNull);
      expect((await host.addFromCatalog('c_3'))!.added, isFalse);
      await alice.requestCatalogAdd(['c_3']);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(
        host.playlist
            .singleWhere((i) => i.mediaId == asUpload.mediaId)
            .catalogId,
        isNull,
      );

      // Removed, then put back by a catalog add: it carries the id again,
      // credited to whoever put it back.
      host.removeMediaItem(c1.mediaId);
      await _waitFor(
        () => bob.playlist.every((i) => i.mediaId != c1.mediaId),
        reason: 'the removal',
      );
      await bob.requestCatalogAdd(['c_1']);
      await _waitFor(
        () => bob.playlist.any((i) => i.mediaId == c1.mediaId),
        reason: 'back in',
      );
      final back = bob.playlist.singleWhere((i) => i.mediaId == c1.mediaId);
      expect(back.catalogId, 'c_1');
      expect(back.addedBy, bob.selfPeerId);
      expect(back.title, c1.title);

      // Removed, then put back by an upload of the same bytes: an upload.
      host.removeMediaItem(c1.mediaId);
      await _waitFor(
        () => alice.playlist.every((i) => i.mediaId != c1.mediaId),
        reason: 'removed again',
      );
      final reUploaded = await alice.uploadMedia(
        files['c_1']!,
        kind: MediaKind.audio,
      );
      expect(reUploaded.mediaId, c1.mediaId);
      expect(reUploaded.catalogId, isNull);
    });
  });

  group('listing is not serving (§6.6)', () {
    test('a catalog entry’s bytes are not fetchable until added', () async {
      final host = await _startHost();
      final file = await makeUntaggedMp3(frames: 33, name: 'secret.mp3');
      host.setCatalog(_TestCatalog({'c_1': file}));
      final digest = sha256.convert(await file.readAsBytes()).toString();
      final mediaId = 'm_${digest.substring(0, 12)}';

      expect((await _get(host, '/media/c_1')).status, 404);
      expect((await _get(host, '/media/$mediaId')).status, 404);
      expect((await _get(host, '/catalog/c_1')).status, 404);
      expect((await _get(host, '/catalog/c_1/bytes')).status, 404);

      expect((await host.addFromCatalog('c_1'))!.item.mediaId, mediaId);
      final served = await _get(host, '/media/$mediaId');
      expect(served.status, 200);
      expect(served.body, await file.readAsBytes());
    });
  });

  group('catalog covers (§6.6)', () {
    test(
      'a cover is read lazily, cached, and 404s when there is none',
      () async {
        final host = await _startHost();
        final catalog = _TestCatalog(
          {
            'c_art': await makeTaggedMp3(name: 'art.mp3'),
            'c_bare': await makeTaggedMp3(withArtwork: false, name: 'bare.mp3'),
            'c_said_none': await makeTaggedMp3(name: 'said.mp3'),
          },
          entries: const [
            CatalogEntry(catalogId: 'c_art', title: 'Art'),
            CatalogEntry(catalogId: 'c_bare', title: 'Bare'),
            CatalogEntry(
              catalogId: 'c_said_none',
              title: 'Said none',
              hasArtwork: false,
            ),
          ],
        );
        host.setCatalog(catalog);
        final guest = await _join(host);
        expect(catalog.openedForArtwork, isEmpty);

        expect(await guest.fetchCatalogArtwork('c_art'), tinyPngBytes);
        expect(catalog.openedForArtwork, ['c_art']);
        final raw = await _get(host, '/catalog/c_art/artwork');
        expect(raw.status, 200);
        expect(raw.contentType, 'image/png');
        expect(catalog.openedForArtwork, ['c_art']); // From the cache.

        expect(await guest.fetchCatalogArtwork('c_bare'), isNull);
        expect(await guest.fetchCatalogArtwork('c_bare'), isNull);
        expect(catalog.openedForArtwork, [
          'c_art',
          'c_bare',
        ]); // "None" is cached too.

        // The host was told there is none: the file is never read.
        expect(await guest.fetchCatalogArtwork('c_said_none'), isNull);
        expect(await guest.fetchCatalogArtwork('c_unknown'), isNull);
        expect(catalog.openedForArtwork, ['c_art', 'c_bare']);
        expect(host.debugCatalogCoversCached, 2);
      },
    );

    test('the listing says hasArtwork once the host knows, without a new '
        'rev', () async {
      final host = await _startHost();
      final catalog = _TestCatalog(
        {
          'c_art': await makeTaggedMp3(name: 'art.mp3'),
          'c_bare': await makeTaggedMp3(withArtwork: false, name: 'bare.mp3'),
          'c_added': await makeTaggedMp3(title: 'Added', name: 'added.mp3'),
          'c_said': await makeTaggedMp3(name: 'said.mp3'),
        },
        entries: const [
          CatalogEntry(catalogId: 'c_art', title: 'Art'),
          CatalogEntry(catalogId: 'c_bare', title: 'Bare'),
          CatalogEntry(catalogId: 'c_added', title: 'Added'),
          CatalogEntry(catalogId: 'c_said', title: 'Said', hasArtwork: false),
        ],
      );
      host.setCatalog(catalog);
      final guest = await _join(host);
      Map<String, bool?> known(CatalogListing listing) => {
        for (final e in listing.items) e.catalogId: e.hasArtwork,
      };

      final first = (await guest.fetchCatalogListing())!;
      expect(known(first), {
        'c_art': null,
        'c_bare': null,
        'c_added': null,
        'c_said': false,
      });

      await guest.fetchCatalogArtwork('c_art');
      await guest.fetchCatalogArtwork('c_bare');
      await guest.requestCatalogAdd(['c_added']);
      await _waitFor(() => guest.playlist.isNotEmpty, reason: 'the add');

      final later = (await guest.fetchCatalogListing())!;
      expect(later.rev, first.rev, reason: 'the same songs');
      expect(known(later), {
        'c_art': true,
        'c_bare': false,
        'c_added': true,
        'c_said': false, // The provider's word stands.
      });
    });

    test('the cover cache is bounded', () async {
      final host = JamHostServer(
        sessionName: 'Covers',
        catalogCoverCacheSize: 2,
      );
      await host.start(address: InternetAddress.loopbackIPv4);
      addTearDown(host.close);
      final files = <String, File>{
        for (var i = 0; i < 3; i++)
          'c_$i': await makeTaggedMp3(name: 'cover$i.mp3'),
      };
      final catalog = _TestCatalog(files);
      host.setCatalog(catalog);
      final guest = await _join(host);
      for (final id in files.keys) {
        expect(await guest.fetchCatalogArtwork(id), tinyPngBytes);
      }
      expect(host.debugCatalogCoversCached, 2);
      // c_0 was evicted: read again.
      await guest.fetchCatalogArtwork('c_0');
      expect(catalog.openedForArtwork, ['c_0', 'c_1', 'c_2', 'c_0']);
      expect(JamHostServer.defaultCatalogCoverCacheSize, 64);
    });
  });

  group('setCatalog (§6.6)', () {
    test('the same listing again bumps nothing, from the same provider or '
        'another', () async {
      final host = await _startHost();
      final files = await _untagged(['c_1', 'c_2']);
      final catalog = _TestCatalog(files);
      host.setCatalog(catalog);
      final guest = await _join(host);
      final seen = <CatalogSummary?>[];
      final sub = guest.catalogUpdates.listen(seen.add);
      addTearDown(sub.cancel);

      host.setCatalog(catalog);
      host.setCatalog(_TestCatalog(files));
      expect(host.catalog, const CatalogSummary(rev: 1, count: 2));

      // A change does bump, and is what the guest hears first.
      host.setCatalog(
        _TestCatalog(
          files,
          entries: const [CatalogEntry(catalogId: 'c_1', title: 'Renamed')],
        ),
      );
      await _waitFor(() => seen.isNotEmpty, reason: 'the broadcast');
      expect(seen, [const CatalogSummary(rev: 2, count: 1)]);
    });

    test(
      'a provider whose entries throw leaves the old catalog in place',
      () async {
        final host = await _startHost();
        final catalog = _TestCatalog(await _untagged(['c_1']));
        host.setCatalog(catalog);
        final broken = _TestCatalog(await _untagged(['c_9']))
          ..entriesThrow = true;
        expect(() => host.setCatalog(broken), throwsStateError);
        catalog.entriesThrow = true;
        expect(() => host.setCatalog(catalog), throwsStateError);
        expect(host.catalog, const CatalogSummary(rev: 1, count: 1));
        expect([for (final e in host.catalogEntries) e.catalogId], ['c_1']);
        // And it still serves from the old provider.
        expect((await host.addFromCatalog('c_1'))!.added, isTrue);
      },
    );

    test('unsafe and repeated ids are dropped when offered', () async {
      final host = await _startHost();
      final files = await _untagged(['ok']);
      host.setCatalog(
        _TestCatalog(
          files,
          entries: [
            const CatalogEntry(catalogId: 'ok', title: 'Ok'),
            const CatalogEntry(catalogId: '..', title: 'Dots'),
            const CatalogEntry(catalogId: 'a..b', title: 'Inner dots'),
            const CatalogEntry(catalogId: 'a/b', title: 'Slash'),
            const CatalogEntry(catalogId: r'a\b', title: 'Backslash'),
            const CatalogEntry(catalogId: 'n\u0000', title: 'Nul'),
            const CatalogEntry(catalogId: '', title: 'Empty'),
            CatalogEntry(catalogId: 'x' * 129, title: 'Long'),
            const CatalogEntry(catalogId: 'ok', title: 'Repeat'),
          ],
        ),
      );
      expect(host.catalog!.count, 1);
      expect(host.catalogEntries.single.title, 'Ok');
      final listing = jsonDecode(
        utf8.decode((await _get(host, '/catalog')).body),
      );
      expect((listing as Map)['items'], hasLength(1));
      final guest = await _join(host);
      await guest.requestCatalogAdd(['..', 'a/b', '']);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(host.playlist, isEmpty);
    });

    test('a refresh by the same provider drops the adds for ids it no longer '
        'offers', () async {
      final host = await _startHost();
      final catalog = _TestCatalog(await _untagged(['c_1', 'c_2', 'c_3']))
        ..gate = Completer<void>();
      host.setCatalog(catalog);
      final guest = await _join(host);
      await guest.requestCatalogAdd(['c_1', 'c_2', 'c_3']);
      await _waitFor(() => catalog.opened.isNotEmpty, reason: 'first open');
      expect(host.debugCatalogAddsPending, 3);

      catalog.entriesNow = [
        for (final e in catalog.entriesNow)
          if (e.catalogId != 'c_2') e,
      ];
      host.setCatalog(catalog);
      expect(host.catalog, const CatalogSummary(rev: 2, count: 2));
      expect(host.debugCatalogAddsPending, 2); // c_2's slot is back.

      catalog.gate!.complete();
      await _waitFor(() => guest.playlist.length == 2, reason: 'two adds');
      await _waitFor(() => host.debugCatalogAddsPending == 0, reason: 'drain');
      expect(
        [for (final i in guest.playlist) i.title],
        ['Song c_1', 'Song c_3'],
      );
      expect(catalog.opened, ['c_1', 'c_3']);
    });
  });

  group('catalog adds, hardened (§6.6, §9.1)', () {
    test(
      'the same id across many requests is opened and hashed once',
      () async {
        final host = await _startHost();
        final catalog = _TestCatalog(await _untagged(['c_1']))
          ..gate = Completer<void>();
        host.setCatalog(catalog);
        final alice = await _join(host, clientName: 'alice');
        final bob = await _join(host, clientName: 'bob');

        await alice.requestCatalogAdd(['c_1']);
        await _waitFor(
          () => host.debugCatalogAddsPending == 1,
          reason: 'queued',
        );
        // Waiting already: a no-op, no second slot.
        for (var i = 0; i < 5; i++) {
          await alice.requestCatalogAdd(['c_1']);
          await bob.requestCatalogAdd(['c_1']);
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(host.debugCatalogAddsPending, 1);

        catalog.gate!.complete();
        await _waitFor(() => alice.playlist.length == 1, reason: 'the add');
        await _waitFor(
          () => host.debugCatalogAddsPending == 0,
          reason: 'drain',
        );

        // In the queue now: not even opened again.
        for (var i = 0; i < 5; i++) {
          await alice.requestCatalogAdd(['c_1']);
          await bob.requestCatalogAdd(['c_1']);
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect((await host.addFromCatalog('c_1'))!.added, isFalse);
        expect(catalog.opened, ['c_1']);
        expect(host.playlist, hasLength(1));
        expect(host.debugCatalogAddsPending, 0);

        // Removed from the queue: opened again to go back in.
        host.removeMediaItem(host.playlist.single.mediaId);
        await bob.requestCatalogAdd(['c_1']);
        await _waitFor(() => host.playlist.length == 1, reason: 'back in');
        expect(catalog.opened, ['c_1', 'c_1']);
      },
    );

    test(
      'past the per-peer pending bound that guest is answered busy',
      () async {
        final host = await _startHost(maxPendingCatalogAddsPerPeer: 2);
        final catalog = _TestCatalog(
          await _untagged(['c_1', 'c_2', 'c_3', 'c_4', 'c_5']),
        )..gate = Completer<void>();
        host.setCatalog(catalog);
        final greedy = await _join(
          host,
          clientName: 'greedy',
          clientId: 'dev-g',
        );
        final other = await _join(host, clientName: 'other', clientId: 'dev-o');

        final errors = <ErrorMessage>[];
        final sub = greedy.errors.listen(errors.add);
        addTearDown(sub.cancel);
        await greedy.requestCatalogAdd(['c_1', 'c_2', 'c_3']);
        await _waitFor(() => errors.isNotEmpty, reason: 'busy');
        expect(errors.single.code, ErrorCode.busy);
        expect(host.debugCatalogAddsPending, 2);
        // Still full for it, one busy per request.
        await greedy.requestCatalogAdd(['c_3']);
        await _waitFor(() => errors.length == 2, reason: 'second busy');

        // Someone else still has room.
        final otherErrors = <ErrorMessage>[];
        final otherSub = other.errors.listen(otherErrors.add);
        addTearDown(otherSub.cancel);
        await other.requestCatalogAdd(['c_4', 'c_5']);
        await _waitFor(
          () => host.debugCatalogAddsPending == 4,
          reason: 'queued',
        );

        catalog.gate!.complete();
        await _waitFor(() => host.playlist.length == 4, reason: 'four adds');
        await _waitFor(
          () => host.debugCatalogAddsPending == 0,
          reason: 'drain',
        );
        expect(otherErrors, isEmpty);
        expect(errors, hasLength(2));
        expect(JamHostServer.defaultMaxPendingCatalogAddsPerPeer, 50);
        // Coherent defaults: one full request fits a device's share whole,
        // and the room holds more than one device's worth.
        expect(
          JamHostServer.defaultMaxPendingCatalogAddsPerPeer,
          greaterThanOrEqualTo(JamHostServer.defaultMaxCatalogIdsPerRequest),
        );
        expect(
          JamHostServer.defaultMaxPendingCatalogAdds,
          greaterThan(JamHostServer.defaultMaxPendingCatalogAddsPerPeer),
        );
      },
    );

    test(
      'a kicked requester’s queued adds never land and free their slots',
      () async {
        final host = await _startHost(maxPendingCatalogAdds: 3);
        final catalog = _TestCatalog(
          await _untagged(['c_1', 'c_2', 'c_3', 'c_4']),
        )..gate = Completer<void>();
        host.setCatalog(catalog);
        final guest = await _join(host, clientId: 'dev-kick');
        final other = await _join(host, clientName: 'other', clientId: 'dev-2');
        await guest.requestCatalogAdd(['c_1', 'c_2', 'c_3']);
        await _waitFor(() => catalog.opened.isNotEmpty, reason: 'first open');
        expect(host.debugCatalogAddsPending, 3);

        host.kickPeer(guest.selfPeerId);
        catalog.gate!.complete();
        await _waitFor(
          () => host.debugCatalogAddsPending == 0,
          reason: 'drain',
        );
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(host.playlist, isEmpty);
        expect(catalog.opened, ['c_1']); // The rest were not even opened.

        // The slots are free again.
        await other.requestCatalogAdd(['c_4']);
        await _waitFor(() => other.playlist.length == 1, reason: 'the add');
        expect(other.playlist.single.addedBy, other.selfPeerId);
      },
    );

    test('a requester that drops and rejoins is credited under its new '
        'peerId', () async {
      final host = await _startHost();
      final catalog = _TestCatalog(await _untagged(['c_1']))
        ..gate = Completer<void>();
      host.setCatalog(catalog);
      final first = await JamGuestClient.connect(
        host.joinUriFor(InternetAddress.loopbackIPv4),
        clientName: 'phone',
        clientId: 'dev-rejoin',
      );
      await first.requestCatalogAdd(['c_1']);
      await _waitFor(() => catalog.opened.isNotEmpty, reason: 'first open');
      final oldPeerId = first.selfPeerId;
      // A drop the host keeps a grace slot for, then a fresh join from the
      // same device.
      host.kickPeer(oldPeerId, allowResume: true);
      await first.close();
      final again = await _join(
        host,
        clientName: 'phone',
        clientId: 'dev-rejoin',
      );

      catalog.gate!.complete();
      await _waitFor(() => host.playlist.length == 1, reason: 'the add');
      expect(host.playlist.single.addedBy, again.selfPeerId);
    });

    test(
      'add_tracks revoked between queue and landing: nothing lands',
      () async {
        final host = await _startHost();
        final catalog = _TestCatalog(await _untagged(['c_1', 'c_2']))
          ..gate = Completer<void>();
        host.setCatalog(catalog);
        final guest = await _join(host, clientId: 'dev-revoke');
        await guest.requestCatalogAdd(['c_1', 'c_2']);
        await _waitFor(() => catalog.opened.isNotEmpty, reason: 'first open');
        host.setCapabilityOverride(
          guest.selfPeerId,
          JamCapability.addTracks,
          allowed: false,
        );
        catalog.gate!.complete();
        await _waitFor(
          () => host.debugCatalogAddsPending == 0,
          reason: 'drain',
        );
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(host.playlist, isEmpty);
        expect(catalog.opened, ['c_1']);
      },
    );

    test(
      'a provider that throws in open or the probe costs only that song',
      () async {
        final host = await _startHost();
        final catalog =
            _TestCatalog(
                await _untagged(['c_1', 'c_2', 'c_3']),
                entries: const [
                  CatalogEntry(catalogId: 'c_1', title: 'One'),
                  CatalogEntry(
                    catalogId: 'c_2',
                    title: 'Two',
                    durationUs: 2_000_000,
                  ),
                  CatalogEntry(catalogId: 'c_3', title: 'Three'),
                ],
              )
              ..throwOnOpen.add('c_1')
              ..throwOnProbe.add('c_2');
        host.setCatalog(catalog);
        final guest = await _join(host);
        await guest.requestCatalogAdd(['c_1', 'c_2', 'c_3']);
        await _waitFor(() => guest.playlist.length == 2, reason: 'two adds');
        await _waitFor(
          () => host.debugCatalogAddsPending == 0,
          reason: 'drain',
        );
        expect([for (final i in guest.playlist) i.title], ['Two', 'Three']);
        expect(
          guest.playlist.first.durationUs,
          2_000_000,
        ); // No probe: the library's.
      },
    );

    test(
      'the playlist filled meanwhile: busy at the landing, once per request, '
      'and no cover left behind',
      () async {
        final uploads = await Directory.systemTemp.createTemp(
          'catalog_uploads',
        );
        addTearDown(() => uploads.delete(recursive: true));
        final host = await _startHost(maxPlaylistLength: 2, uploadDir: uploads);
        final catalog = _TestCatalog({
          'c_a': await makeTaggedMp3(name: 'a.mp3'),
          'c_b': await makeTaggedMp3(title: 'Other', name: 'b.mp3'),
        })..gate = Completer<void>();
        host.setCatalog(catalog);
        final guest = await _join(host);
        final errors = <ErrorMessage>[];
        final sub = guest.errors.listen(errors.add);
        addTearDown(sub.cancel);
        await guest.requestCatalogAdd(['c_a', 'c_b']);
        await _waitFor(() => catalog.opened.isNotEmpty, reason: 'first open');
        expect(errors, isEmpty); // Room for both when asked.

        // The host's own additions are not held to the cap.
        for (var i = 0; i < 2; i++) {
          final own = await makeUntaggedMp3(frames: 70 + i, name: 'own$i.mp3');
          host.addMedia(
            await JamHostServer.describeFile(own, kind: MediaKind.audio),
            own,
          );
        }
        catalog.gate!.complete();
        await _waitFor(
          () => host.debugCatalogAddsPending == 0,
          reason: 'drain',
        );
        await _waitFor(() => errors.isNotEmpty, reason: 'busy');
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(errors.single.code, ErrorCode.busy);
        expect(errors.single.fatal, isFalse);
        expect(host.playlist, hasLength(2));
        expect(host.artworkFile(_tinyPngArtworkId), isNull);
        expect(uploads.listSync(), isEmpty);
      },
    );
  });

  group('an add abandoned midway leaves nothing behind (§6.6)', () {
    test('the catalog turned off mid-hash: hashing stops there, and no '
        'cover or file is left', () async {
      final uploads = await Directory.systemTemp.createTemp('catalog_uploads');
      addTearDown(() => uploads.delete(recursive: true));
      final host = await _startHost(uploadDir: uploads);
      final big = await _bigTaggedMp3('big.mp3');
      // Turned off the moment the first chunk has been read for the hash.
      final counted = _CountingFile(big)
        ..onChunk = (_) {
          if (host.catalog != null) host.setCatalog(null);
        };
      final catalog = _TestCatalog({'c_big': counted});
      host.setCatalog(catalog);
      final guest = await _join(host);
      await guest.requestCatalogAdd(['c_big']);
      await _waitFor(() => host.catalog == null, reason: 'turned off');
      await _waitFor(() => host.debugCatalogAddsPending == 0, reason: 'drain');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(counted.bytesRead, lessThan(await big.length()));
      expect(catalog.probeCalls, 0);
      expect(host.playlist, isEmpty);
      expect(host.artworkFile(_tinyPngArtworkId), isNull);
      expect(uploads.listSync(), isEmpty);
    });

    test('the provider replaced mid-probe: no cover, no files', () async {
      final uploads = await Directory.systemTemp.createTemp('catalog_uploads');
      addTearDown(() => uploads.delete(recursive: true));
      final host = await _startHost(uploadDir: uploads);
      final catalog = _TestCatalog({
        'c_art': await makeTaggedMp3(name: 'art.mp3'),
      })..probeGate = Completer<void>();
      host.setCatalog(catalog);
      final guest = await _join(host);
      await guest.requestCatalogAdd(['c_art']);
      await _waitFor(() => catalog.probeCalls == 1, reason: 'the probe');
      host.setCatalog(
        _TestCatalog({'c_art': await makeTaggedMp3(name: 'other.mp3')}),
      );
      catalog.probeGate!.complete();
      await _waitFor(() => host.debugCatalogAddsPending == 0, reason: 'drain');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(host.playlist, isEmpty);
      expect(host.artworkFile(_tinyPngArtworkId), isNull);
      expect(uploads.listSync(), isEmpty);
    });
  });

  group('catalog covers, bounded (§6.6, §9.1)', () {
    test('cover reads go through openForArtwork, never open', () async {
      final host = await _startHost();
      final catalog = _TestCatalog({
        'c_art': await makeTaggedMp3(name: 'art.mp3'),
      });
      host.setCatalog(catalog);
      final guest = await _join(host);
      expect(await guest.fetchCatalogArtwork('c_art'), tinyPngBytes);
      expect(catalog.openedForArtwork, ['c_art']);
      expect(catalog.opened, isEmpty);
      await guest.requestCatalogAdd(['c_art']);
      await _waitFor(() => guest.playlist.isNotEmpty, reason: 'the add');
      expect(catalog.opened, ['c_art']);
      expect(catalog.openedForArtwork, ['c_art']);

      // A provider that does not override it gets open's file.
      final plain = _OpenOnlyCatalog({
        'c_p': await makeTaggedMp3(name: 'p.mp3'),
      });
      host.setCatalog(plain);
      expect(await guest.fetchCatalogArtwork('c_p'), tinyPngBytes);
      expect(plain.opened, ['c_p']);
    });

    test('a burst of 20 cover reads: 3 at a time, 16 waiting, the rest 503 '
        'and not remembered', () async {
      final host = await _startHost();
      final files = <String, File>{
        for (var i = 0; i < 20; i++)
          'c_$i': await makeTaggedMp3(name: 'b$i.mp3'),
      };
      final catalog = _TestCatalog(files)..artGate = Completer<void>();
      host.setCatalog(catalog);
      final statuses = <String, int>{};
      final reads = [
        for (final id in files.keys)
          _get(
            host,
            '/catalog/$id/artwork',
          ).then((r) => statuses[id] = r.status),
      ];
      await _waitFor(() => statuses.values.contains(503), reason: 'a 503');
      expect(catalog.artActive, JamHostServer.catalogCoverReadsAtOnce);
      catalog.artGate!.complete();
      await Future.wait(reads);
      expect(catalog.artMaxActive, JamHostServer.catalogCoverReadsAtOnce);
      final busy = [
        for (final e in statuses.entries)
          if (e.value == 503) e.key,
      ];
      expect(busy, hasLength(20 - 3 - JamHostServer.catalogCoverReadsWaiting));
      expect(statuses.values.where((s) => s == 200), hasLength(19));
      // A 503 is not "no cover": asked again, it is served.
      final again = await _get(host, '/catalog/${busy.single}/artwork');
      expect(again.status, 200);
      expect(again.body, tinyPngBytes);
    });

    test('odd cover paths are 404', () async {
      final host = await _startHost();
      host.setCatalog(_TestCatalog({'x': await makeTaggedMp3(name: 'x.mp3')}));
      expect(await _rawStatus(host, '/catalog/x/artwork'), 200);
      expect(await _rawStatus(host, '/catalog/%2E%2E/artwork'), 404);
      expect(await _rawStatus(host, '/catalog/../artwork'), 404);
      expect(await _rawStatus(host, '/catalog/x/artwork/extra'), 404);
      expect(await _rawStatus(host, '/catalog/x%2Fy/artwork'), 404);
      expect(await _rawStatus(host, '/catalog//artwork'), 404);
    });

    test(
      'a cover read across a provider swap is 404, and not cached',
      () async {
        final host = await _startHost();
        final catalog = _TestCatalog({
          'c_1': await makeTaggedMp3(name: 'one.mp3'),
        })..artGate = Completer<void>();
        host.setCatalog(catalog);
        final read = _get(host, '/catalog/c_1/artwork');
        await _waitFor(() => catalog.artActive == 1, reason: 'the read');
        final next = _TestCatalog({
          'c_1': await makeTaggedMp3(name: 'two.mp3'),
        });
        host.setCatalog(next);
        catalog.artGate!.complete();
        expect((await read).status, 404);
        expect(host.debugCatalogCoversCached, 0);
        expect((await _get(host, '/catalog/c_1/artwork')).status, 200);
        expect(next.openedForArtwork, ['c_1']);
      },
    );
  });

  group('the guest’s listing is never stale (§6.6)', () {
    test('a fetch overtaken by a newer rev fetches again', () async {
      final host = await _startHost();
      final catalog = _TestCatalog(
        await _untagged(['c_1', 'c_2']),
        entries: const [CatalogEntry(catalogId: 'c_1', title: 'One')],
      );
      host.setCatalog(catalog);
      final proxy = await _HoldingProxy.start(host.port);
      addTearDown(proxy.close);
      final direct = host.joinUriFor(InternetAddress.loopbackIPv4);
      final session = await JamGuestSession.connect(
        direct.replace(
          queryParameters: {...direct.queryParameters, 'port': '${proxy.port}'},
        ),
        clientName: 'browser',
      );
      addTearDown(session.close);
      expect(session.catalog?.rev, 1);

      proxy.hold = Completer<void>();
      final first = session.fetchCatalog();
      // The host has answered (rev 1); the answer is held on its way.
      await _waitFor(() => proxy.heldChunks > 0, reason: 'a held answer');

      final changed = session.catalogChanges.first;
      catalog.entriesNow = const [CatalogEntry(catalogId: 'c_2', title: 'Two')];
      host.setCatalog(catalog);
      expect(await changed, const CatalogSummary(rev: 2, count: 1));

      final second = session.fetchCatalog();
      proxy.hold!.complete();
      expect([for (final e in await second) e.catalogId], ['c_2']);
      expect([for (final e in await first) e.catalogId], ['c_2']);
      expect(proxy.catalogRequests, 2);
      // Fresh now: from the cache.
      expect(
        [for (final e in await session.fetchCatalog()) e.catalogId],
        ['c_2'],
      );
      expect(proxy.catalogRequests, 2);
    });
  });
}

/// `a_` + the sha256 prefix of [tinyPngBytes]: the artworkId every tagged
/// fixture's cover registers under (§6.5).
final String _tinyPngArtworkId =
    'a_${sha256.convert(tinyPngBytes).toString().substring(0, 12)}';

/// A tagged MP3 (with a cover) padded with 8 MB, so hashing it takes many
/// chunks.
Future<File> _bigTaggedMp3(String name) async {
  final file = await makeTaggedMp3(name: name);
  final raf = await file.open(mode: FileMode.append);
  final chunk = Uint8List(1 << 20);
  for (var i = 0; i < 8; i++) {
    await raf.writeFrom(chunk);
  }
  await raf.close();
  return file;
}

/// [file], counting the bytes read through [openRead] (the hash) and
/// calling [onChunk] as each chunk is handed on. Nothing else of `File` is
/// needed before the hash is done.
class _CountingFile implements File {
  _CountingFile(this._file);

  final File _file;
  int bytesRead = 0;
  void Function(int bytesSoFar)? onChunk;

  @override
  String get path => _file.path;

  @override
  Future<int> length() => _file.length();

  @override
  Stream<List<int>> openRead([int? start, int? end]) =>
      _file.openRead(start, end).map((chunk) {
        bytesRead += chunk.length;
        onChunk?.call(bytesRead);
        return chunk;
      });

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('_CountingFile: ${invocation.memberName}');
}

/// The status of a raw `GET [path]` — sent as written, with no client-side
/// path normalisation — with [host]'s token.
Future<int> _rawStatus(JamHostServer host, String path) async {
  final socket = await Socket.connect(InternetAddress.loopbackIPv4, host.port);
  try {
    socket.write(
      'GET $path HTTP/1.1\r\n'
      'Host: 127.0.0.1:${host.port}\r\n'
      'Authorization: Bearer ${host.token}\r\n'
      'Connection: close\r\n\r\n',
    );
    final bytes = <int>[];
    await socket.forEach(bytes.addAll);
    final statusLine = latin1.decode(bytes).split('\r\n').first;
    return int.parse(statusLine.split(' ')[1]);
  } finally {
    socket.destroy();
  }
}

/// A TCP proxy in front of a host that can hold the host's answers to
/// `GET /catalog` while [hold] is pending — everything else passes.
class _HoldingProxy {
  _HoldingProxy._(this._server, this._upstreamPort);

  final ServerSocket _server;
  final int _upstreamPort;
  final List<Socket> _sockets = [];

  Completer<void>? hold;
  int catalogRequests = 0;
  int heldChunks = 0;

  static Future<_HoldingProxy> start(int upstreamPort) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final proxy = _HoldingProxy._(server, upstreamPort);
    server.listen(proxy._accept);
    return proxy;
  }

  int get port => _server.port;

  Future<void> _accept(Socket client) async {
    final upstream = await Socket.connect(
      InternetAddress.loopbackIPv4,
      _upstreamPort,
    );
    _sockets
      ..add(client)
      ..add(upstream);
    var catalogConnection = false;
    client.listen(
      (data) {
        if (latin1.decode(data).contains('GET /catalog ')) {
          catalogConnection = true;
          catalogRequests++;
        }
        upstream.add(data);
      },
      onDone: upstream.destroy,
      onError: (Object _) => upstream.destroy(),
    );
    var chain = Future<void>.value();
    upstream.listen(
      (data) {
        final gate = hold;
        final held = catalogConnection && gate != null && !gate.isCompleted;
        if (held) heldChunks++;
        chain = chain.then((_) async {
          if (held) await gate.future;
          client.add(data);
        });
      },
      onDone: () => chain = chain.then((_) => client.destroy()),
      onError: (Object _) => chain = chain.then((_) => client.destroy()),
    );
  }

  Future<void> close() async {
    final held = hold;
    if (held != null && !held.isCompleted) held.complete();
    await _server.close();
    for (final socket in _sockets) {
      socket.destroy();
    }
  }
}
