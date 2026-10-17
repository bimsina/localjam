/// Regression tests for what the 2026-10-17 three-device simulator run found
/// in the host: the host's own player needs the file a guest uploaded
/// (§6.4), a device that rejoins under a new peerId keeps its tracks (§5.6),
/// and selecting a track while the room plays keeps it playing (§5.2).
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:localjam_net/localjam_net.dart';
import 'package:test/test.dart';

import 'hardening_helpers.dart';

/// Guests may add tracks and nothing else: removing a track is only
/// possible as its owner (§5.6), which is what makes ownership observable.
const _addOnly = JamPolicy(
  addTracks: true,
  controlPlayback: false,
  editQueue: false,
);

Future<MediaItem> _upload(JamGuestClient guest, {int seed = 5}) async =>
    guest.uploadMedia(
      await writeTempMedia(makeMediaBytes(2048, seed: seed)),
      kind: MediaKind.audio,
      durationUs: 60 * 1000 * 1000,
    );

void main() {
  group('the host plays guest uploads from its own disk (§6.4)', () {
    test('storedUploadFile is the stored upload — not a host item or an '
        'unknown id — and outlives removal until close', () async {
      final host = await startHost();
      final guest = await joinGuest(host, clientId: 'c_up');
      final bytes = makeMediaBytes(3000, seed: 21);
      final sent = await writeTempMedia(bytes);
      final item = await guest.uploadMedia(sent, kind: MediaKind.audio);

      final stored = host.storedUploadFile(item.mediaId);
      expect(stored, isNotNull);
      expect(stored!.path, isNot(sent.path), reason: 'the host\'s own copy');
      expect(await stored.readAsBytes(), bytes);

      final own = await addTrack(host, seed: 22);
      expect(host.storedUploadFile(own.mediaId), isNull);
      expect(host.storedUploadFile('m_000000000000'), isNull);

      // Out of the queue is not off the disk: guests may be mid-fetch, and
      // the host may still be finishing it.
      host.removeMediaItem(item.mediaId);
      expect(host.storedUploadFile(item.mediaId)?.path, stored.path);
      expect(stored.existsSync(), isTrue);

      await host.close();
      expect(host.storedUploadFile(item.mediaId), isNull);
      expect(stored.existsSync(), isFalse);
    });

    test('the host adding the same bytes from its own library takes the '
        'upload\'s place', () async {
      final host = await startHost();
      final guest = await joinGuest(host);
      final bytes = makeMediaBytes(1024, seed: 23);
      final item = await guest.uploadMedia(
        await writeTempMedia(bytes),
        kind: MediaKind.audio,
      );
      expect(host.storedUploadFile(item.mediaId), isNotNull);

      final library = await writeTempMedia(bytes, name: 'mine.bin');
      host.addMedia(
        await JamHostServer.describeFile(library, kind: MediaKind.audio),
        library,
      );
      expect(host.storedUploadFile(item.mediaId), isNull);
    });
  });

  group('attribution follows the device (§5.6)', () {
    test('a guest killed and relaunched gets its tracks back without a '
        'state change, after everyone has heard who it is', () async {
      final host = await startHost(policy: _addOnly);
      final (_, watcher) = await rawJoin(host, clientId: 'c_watch');
      final first = await joinGuest(host, clientId: 'c_phone');
      final item = await _upload(first);
      expect(item.addedBy, first.selfPeerId);
      host
        ..setMedia(item.mediaId)
        ..play();
      final playing = host.snapshot;
      expect(playing.status, PlaybackStatus.playing);
      await waitFor(
        () => watcher.any(
          (f) =>
              f['type'] == 'state' &&
              (f['payload'] as Map)['rev'] == playing.rev,
        ),
        reason: 'the watcher to hear the room start',
      );
      final events = <JamHostEvent>[];
      host.events.listen(events.add);
      final seen = watcher.length;

      // Relaunched: same device, no resume, while the old socket is still
      // "live" here — the supersede path (§3.3).
      final second = await joinGuest(host, clientId: 'c_phone');
      expect(second.selfPeerId, isNot(first.selfPeerId));
      expect(host.playlist.single.addedBy, second.selfPeerId);
      expect(
        second.playlist.single.addedBy,
        second.selfPeerId,
        reason: 'the welcome already says so',
      );

      await waitFor(
        () => watcher
            .skip(seen)
            .any(
              (f) =>
                  f['type'] == 'playlist' && _addedBy(f) == second.selfPeerId,
            ),
        reason: 'the re-attributed playlist',
      );
      final after = watcher.skip(seen).toList();
      final joinedAt = after.indexWhere(
        (f) =>
            f['type'] == 'peer_joined' &&
            ((f['payload'] as Map)['peer'] as Map)['peerId'] ==
                second.selfPeerId,
      );
      final playlistAt = after.indexWhere((f) => f['type'] == 'playlist');
      expect(joinedAt, isNonNegative);
      expect(playlistAt, greaterThan(joinedAt));
      // Only the byline moved: nothing re-anchors anyone's audio.
      expect(after.where((f) => f['type'] == 'state'), isEmpty);
      expect(host.snapshot, playing);
      expect(
        events.where((e) => e.kind == JamHostEventKind.stateBroadcast),
        isEmpty,
      );

      // And it is its own again: removable without edit_queue.
      final errors = <ErrorMessage>[];
      second.errors.listen(errors.add);
      await second.requestQueueRemove(item.mediaId);
      await waitFor(() => host.playlist.isEmpty, reason: 'own track removed');
      expect(errors, isEmpty);
    });

    test('a device back while its old peerId is in grace: a resume keeps '
        'it as it was, a fresh join moves it', () async {
      final host = await startHost(policy: _addOnly);
      final (ws1, frames1) = await rawJoin(host, clientId: 'c_grace');
      final (id1, key1) = _you(frames1);
      expect(
        await rawUpload(host, makeMediaBytes(512, seed: 7), uploadKey: key1),
        HttpStatus.created,
      );
      expect(host.playlist.single.addedBy, id1);
      await ws1.close();
      await waitFor(() => host.peers.isEmpty, reason: 'the drop');

      final broadcasts = <JamHostEvent>[];
      host.events
          .where((e) => e.kind == JamHostEventKind.playlistBroadcast)
          .listen(broadcasts.add);
      final (ws2, frames2) = await rawJoin(
        host,
        clientId: 'c_grace',
        extraHello: {'resumePeerId': id1},
      );
      expect(_you(frames2).$1, id1, reason: 'a proper resume');
      expect(host.playlist.single.addedBy, id1);
      await ws2.close();
      await waitFor(() => host.peers.isEmpty, reason: 'the second drop');

      // Relaunched while id1's grace slot is still open: no resume, so a
      // fresh peerId — and the track goes with the device.
      final fresh = await joinGuest(host, clientId: 'c_grace');
      expect(fresh.selfPeerId, isNot(id1));
      expect(host.playlist.single.addedBy, fresh.selfPeerId);
      await waitFor(() => broadcasts.isNotEmpty, reason: 'the broadcast');
      expect(broadcasts, hasLength(1), reason: 'only the fresh join moved it');
    });

    test('a device kicked and let back in owns its tracks again', () async {
      final host = await startHost(policy: _addOnly);
      final first = await joinGuest(host, clientId: 'c_kick');
      final item = await _upload(first);
      final kickedId = first.selfPeerId;
      host.kickPeer(kickedId);
      await waitFor(() => host.peers.isEmpty, reason: 'the kick');
      expect(
        host.playlist.single.addedBy,
        kickedId,
        reason: 'a kick does not take the tracks away',
      );

      expect(host.unkickPeer(kickedId), isTrue);
      final back = await joinGuest(host, clientId: 'c_kick');
      expect(back.selfPeerId, isNot(kickedId));
      expect(host.playlist.single.addedBy, back.selfPeerId);
      await back.requestQueueRemove(item.mediaId);
      await waitFor(() => host.playlist.isEmpty, reason: 'own track removed');
    });

    test('a device that never comes back keeps its byline; nobody else '
        'inherits it', () async {
      final host = await startHost(policy: _addOnly);
      final gone = await joinGuest(host, clientId: 'c_gone');
      final item = await _upload(gone);
      final anonymous = await joinGuest(host); // No clientId at all.
      final anonymousItem = await _upload(anonymous, seed: 6);
      final goneId = gone.selfPeerId;
      final anonymousId = anonymous.selfPeerId;
      await gone.close();
      await anonymous.close();
      await waitFor(() => host.peers.isEmpty, reason: 'both to leave');

      final broadcasts = <JamHostEvent>[];
      host.events
          .where((e) => e.kind == JamHostEventKind.playlistBroadcast)
          .listen(broadcasts.add);
      final other = await joinGuest(host, clientId: 'c_other');
      final again = await joinGuest(host); // Unrecognisable: a new person.
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(
        {for (final i in host.playlist) i.mediaId: i.addedBy},
        {item.mediaId: goneId, anonymousItem.mediaId: anonymousId},
      );
      expect(broadcasts, isEmpty);
      expect(other.playlist.map((i) => i.addedBy), [goneId, anonymousId]);
      expect(again.selfPeerId, isNot(anonymousId));
    });

    test('an upload still arriving when its device rejoins is credited to '
        'the new peerId', () async {
      final host = await startHost(policy: _addOnly);
      final first = await joinGuest(host, clientId: 'c_slow');
      final bytes = makeMediaBytes(4096, seed: 31);
      final http = HttpClient();
      addTearDown(() => http.close(force: true));
      final req = await http.postUrl(
        Uri.parse('http://127.0.0.1:${host.port}/media'),
      );
      req.headers
        ..set(HttpHeaders.authorizationHeader, 'Bearer ${host.token}')
        ..set('X-LocalJam-Kind', 'audio')
        ..set(JamGuestClient.uploadKeyHeader, first.uploadKey!);
      req.contentLength = bytes.length;
      req.add(bytes.sublist(0, 1024));
      await req.flush();
      await waitFor(
        () => host.debugUploadsInFlight == 1,
        reason: 'the upload to be accepted',
      );
      final uploaded = <JamHostEvent>[];
      host.events
          .where((e) => e.kind == JamHostEventKind.mediaUploaded)
          .listen(uploaded.add);

      final second = await joinGuest(host, clientId: 'c_slow');
      req.add(bytes.sublist(1024));
      final res = await req.close();
      await res.drain<void>();
      expect(res.statusCode, HttpStatus.created);

      expect(host.playlist.single.addedBy, second.selfPeerId);
      await waitFor(() => uploaded.isNotEmpty, reason: 'the upload event');
      expect(uploaded.single.peerId, second.selfPeerId);
    });
  });

  group('an upload lands only for someone still in the room (§6.4)', () {
    test('a device kicked while its body is arriving is refused, and the '
        'room keeps nothing of it', () async {
      final dir = await Directory.systemTemp.createTemp('localjam_landing');
      addTearDown(() => dir.delete(recursive: true));
      const size = 4096;
      final host = await startHost(
        policy: _addOnly,
        uploadDir: dir,
        uploadBudgetBytes: size,
      );
      final guest = await joinGuest(host, clientId: 'c_kicked');
      final finish = await _startSlowUpload(
        host,
        guest.uploadKey!,
        makeMediaBytes(size, seed: 51),
      );
      final events = <JamHostEvent>[];
      host.events.listen(events.add);

      host.kickPeer(guest.selfPeerId);
      expect(await finish(), HttpStatus.forbidden);

      expect(host.playlist, isEmpty);
      expect(
        events.where(
          (e) =>
              e.kind == JamHostEventKind.mediaUploaded ||
              e.kind == JamHostEventKind.playlistBroadcast,
        ),
        isEmpty,
      );
      // The answer goes out before the clean-up finishes.
      await waitFor(
        () => dir.listSync().isEmpty && host.debugUploadsInFlight == 0,
        reason: 'the received bytes deleted and the reservation released',
      );
      expect(host.uploadedBytes, 0);
      // Its reservation went with it: the whole budget is someone else's.
      final other = await joinGuest(host, clientId: 'c_other');
      expect(
        await rawUpload(
          host,
          makeMediaBytes(size, seed: 52),
          uploadKey: other.uploadKey,
        ),
        HttpStatus.created,
      );
    });

    test(
      'so is one whose peer is gone with no device to come back as',
      () async {
        final host = await startHost(policy: _addOnly);
        final guest = await joinGuest(host); // No clientId: only its key.
        final finish = await _startSlowUpload(
          host,
          guest.uploadKey!,
          makeMediaBytes(4096, seed: 53),
        );

        host.kickPeer(guest.selfPeerId);
        expect(await finish(), HttpStatus.forbidden);
        expect(host.playlist, isEmpty);
        expect(host.uploadedBytes, 0);
      },
    );

    test('one whose control socket dropped mid-body lands, credited to its '
        'peerId, while its grace slot holds', () async {
      final host = await startHost(
        policy: _addOnly,
        silenceTimeout: const Duration(milliseconds: 400),
        livenessCheckInterval: const Duration(milliseconds: 50),
      );
      final (guest, proxy) = await _joinBehindProxy(host, clientId: 'c_blip');
      final peerId = guest.selfPeerId;
      final finish = await _startSlowUpload(
        host,
        guest.uploadKey!,
        makeMediaBytes(4096, seed: 54),
      );
      final uploaded = <JamHostEvent>[];
      host.events
          .where((e) => e.kind == JamHostEventKind.mediaUploaded)
          .listen(uploaded.add);

      // A Wi-Fi blip on the control socket only: the upload is a connection
      // of its own, and keeps going.
      proxy.blackhole();
      await waitFor(
        () => host.peers.isEmpty,
        reason: 'the host to drop the silent peer into its grace window',
      );

      expect(await finish(), HttpStatus.created);
      expect(host.playlist.single.addedBy, peerId);
      await waitFor(() => uploaded.isNotEmpty, reason: 'the upload event');
      expect(uploaded.single.peerId, peerId);
    });

    test('one whose grace window ran out before its body arrived is '
        'refused', () async {
      final host = await startHost(
        policy: _addOnly,
        silenceTimeout: const Duration(milliseconds: 400),
        reconnectGrace: const Duration(milliseconds: 200),
        livenessCheckInterval: const Duration(milliseconds: 50),
      );
      final (guest, proxy) = await _joinBehindProxy(host, clientId: 'c_gone');
      final peerId = guest.selfPeerId;
      // Only something to watch: a peerId gone for good is forgotten from
      // the permission document (§5.6) when its grace slot expires.
      host.setCapabilityOverride(
        peerId,
        JamCapability.addTracks,
        allowed: true,
      );
      final finish = await _startSlowUpload(
        host,
        guest.uploadKey!,
        makeMediaBytes(4096, seed: 55),
      );

      proxy.blackhole();
      await waitFor(
        () => !host.permissions.overrides.containsKey(peerId),
        reason: 'the grace window to expire',
      );

      expect(await finish(), HttpStatus.forbidden);
      expect(host.playlist, isEmpty);
      expect(host.uploadedBytes, 0);
    });
  });

  group('re-uploading a removed track puts it back (§6.4)', () {
    test('answered as an add — 201, queued, broadcast — and nothing new '
        'is stored or spent', () async {
      final host = await startHost(policy: _addOnly);
      final guest = await joinGuest(host, clientId: 'c_again');
      final bytes = makeMediaBytes(2048, seed: 61);
      expect(
        await rawUpload(host, bytes, uploadKey: guest.uploadKey),
        HttpStatus.created,
      );
      final mediaId = host.playlist.single.mediaId;
      final stored = host.storedUploadFile(mediaId)!;
      final spent = host.uploadedBytes;
      host.removeMediaItem(mediaId);
      await waitFor(() => guest.playlist.isEmpty, reason: 'the removal');

      final events = <JamHostEvent>[];
      host.events.listen(events.add);
      expect(
        await rawUpload(host, bytes, uploadKey: guest.uploadKey),
        HttpStatus.created,
      );
      expect(host.playlist.map((i) => i.mediaId), [mediaId]);
      expect(host.playlist.single.addedBy, guest.selfPeerId);
      await waitFor(
        () => guest.playlist.map((i) => i.mediaId).contains(mediaId),
        reason: 'the guest to see it queued again',
      );
      final uploaded = events.where(
        (e) => e.kind == JamHostEventKind.mediaUploaded,
      );
      expect(uploaded.map((e) => e.peerId), [guest.selfPeerId]);
      final broadcastAt = events.indexWhere(
        (e) => e.kind == JamHostEventKind.playlistBroadcast,
      );
      expect(broadcastAt, greaterThan(events.indexOf(uploaded.single)));
      expect(host.uploadedBytes, spent, reason: 'the bytes were already here');
      expect(host.storedUploadFile(mediaId)?.path, stored.path);
    });

    test('credited to whoever put it back, device and all; the first '
        'upload\'s metadata stays', () async {
      final host = await startHost(policy: _addOnly);
      final first = await joinGuest(host, clientId: 'c_first');
      final second = await joinGuest(host, clientId: 'c_second');
      final bytes = makeMediaBytes(2048, seed: 62);
      final item = await first.uploadMedia(
        await writeTempMedia(bytes),
        kind: MediaKind.audio,
        name: 'first.mp3',
      );
      host.removeMediaItem(item.mediaId);

      final back = await second.uploadMedia(
        await writeTempMedia(bytes),
        kind: MediaKind.audio,
        name: 'second.mp3',
      );
      expect(back.mediaId, item.mediaId);
      expect(back.addedBy, second.selfPeerId);
      expect(back.name, 'first.mp3');
      expect(host.playlist.single.addedBy, second.selfPeerId);

      // The first uploader's device coming back does not take it over
      // (§5.6), and may not remove what is no longer its own.
      final firstAgain = await joinGuest(host, clientId: 'c_first');
      expect(host.playlist.single.addedBy, second.selfPeerId);
      final errors = <ErrorMessage>[];
      firstAgain.errors.listen(errors.add);
      await firstAgain.requestQueueRemove(item.mediaId);
      await waitFor(() => errors.isNotEmpty, reason: 'the refusal');
      expect(errors.single.code, ErrorCode.notAllowed);
      expect(host.playlist, hasLength(1));

      await second.requestQueueRemove(item.mediaId);
      await waitFor(() => host.playlist.isEmpty, reason: 'own track removed');
    });

    test('judged like a fresh add: the queue cap and add_tracks', () async {
      final host = await startHost(policy: _addOnly, maxPlaylistLength: 1);
      final guest = await joinGuest(host, clientId: 'c_judged');
      final bytes = makeMediaBytes(2048, seed: 63);
      expect(
        await rawUpload(host, bytes, uploadKey: guest.uploadKey),
        HttpStatus.created,
      );
      final mediaId = host.playlist.single.mediaId;
      host.removeMediaItem(mediaId);

      final own = await addTrack(host, seed: 64);
      expect(
        await rawUpload(host, bytes, uploadKey: guest.uploadKey),
        HttpStatus.insufficientStorage,
      );
      expect(host.playlist.map((i) => i.mediaId), [own.mediaId]);

      host
        ..removeMediaItem(own.mediaId)
        ..setPolicy(JamPolicy.listenOnly);
      expect(
        await rawUpload(host, bytes, uploadKey: guest.uploadKey),
        HttpStatus.forbidden,
      );
      expect(host.playlist, isEmpty);
    });

    test('content still in the queue stays idempotent: 200, and nothing '
        'changes — not even whose it is', () async {
      final host = await startHost(policy: _addOnly);
      final guest = await joinGuest(host, clientId: 'c_owner');
      final other = await joinGuest(host, clientId: 'c_other');
      final bytes = makeMediaBytes(2048, seed: 65);
      expect(
        await rawUpload(host, bytes, uploadKey: guest.uploadKey),
        HttpStatus.created,
      );
      final spent = host.uploadedBytes;
      final events = <JamHostEvent>[];
      host.events.listen(events.add);

      expect(
        await rawUpload(host, bytes, uploadKey: other.uploadKey),
        HttpStatus.ok,
      );
      expect(host.playlist.single.addedBy, guest.selfPeerId);
      expect(host.uploadedBytes, spent);
      expect(
        events.where(
          (e) =>
              e.kind == JamHostEventKind.mediaUploaded ||
              e.kind == JamHostEventKind.playlistBroadcast,
        ),
        isEmpty,
      );
    });
  });

  group('selecting a track keeps the room going (§5.2 set_media)', () {
    test('while playing, a guest\'s pick plays from its start', () async {
      final host = await startHost();
      final a = await addTrack(host, seed: 41, durationUs: 60000000);
      final b = await addTrack(host, seed: 42, durationUs: 60000000);
      final guest = await joinGuest(host);
      host
        ..setMedia(a.mediaId)
        ..play();
      expect(host.snapshot.status, PlaybackStatus.playing);

      await guest.requestSetMedia(b.mediaId);
      await waitFor(
        () =>
            guest.snapshot.mediaId == b.mediaId &&
            guest.snapshot.status == PlaybackStatus.playing,
        reason: 'the room to play the pick',
      );
      final anchor = host.snapshot.anchor!;
      expect(anchor.positionUs, 0);
      expect(host.snapshot.mediaId, b.mediaId);
    });

    test(
      'while paused, it is cued: loading at 0, and nothing starts',
      () async {
        final host = await startHost();
        final a = await addTrack(host, seed: 43, durationUs: 60000000);
        final b = await addTrack(host, seed: 44, durationUs: 60000000);
        host
          ..setMedia(a.mediaId)
          ..play()
          ..pause();
        host.setMedia(b.mediaId);
        expect(host.snapshot.mediaId, b.mediaId);
        expect(host.snapshot.status, PlaybackStatus.loading);
        expect(host.snapshot.positionUs, 0);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(host.snapshot.status, PlaybackStatus.loading);
      },
    );

    test('a start held by the readiness gate moves to the pick and still '
        'waits for it (§6.3)', () async {
      final host = await startHost(readinessWait: const Duration(seconds: 5));
      final a = await addTrack(host, seed: 45);
      final b = await addTrack(host, seed: 46);
      final guest = await joinGuest(host);
      guest
        ..sendMediaStatus(a.mediaId, MediaFetchState.fetching)
        ..sendMediaStatus(b.mediaId, MediaFetchState.fetching);
      await waitFor(
        () =>
            host.peerMediaState(guest.selfPeerId, b.mediaId) ==
            MediaReadiness.fetching,
        reason: 'the reports',
      );
      host
        ..setMedia(a.mediaId)
        ..play();
      expect(host.isAwaitingReadiness, isTrue);

      host.setMedia(b.mediaId);
      expect(host.snapshot.mediaId, b.mediaId);
      expect(host.snapshot.status, PlaybackStatus.loading);
      expect(host.isAwaitingReadiness, isTrue, reason: 'held for the pick');

      guest.sendMediaStatus(b.mediaId, MediaFetchState.ready);
      await waitFor(
        () => host.snapshot.status == PlaybackStatus.playing,
        reason: 'the pick to start once fetched',
      );
      expect(host.snapshot.mediaId, b.mediaId);
    });

    test('picking the current track changes nothing — no restart for a '
        'double tap', () async {
      final host = await startHost();
      final a = await addTrack(host, seed: 47, durationUs: 60000000);
      final guest = await joinGuest(host);
      host
        ..setMedia(a.mediaId)
        ..play();
      final playing = host.snapshot;

      host.setMedia(a.mediaId);
      await guest.requestSetMedia(a.mediaId);
      await guest.requestSetMedia(a.mediaId);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(host.snapshot, playing);

      host.pause();
      final paused = host.snapshot;
      host.setMedia(a.mediaId);
      expect(host.snapshot, paused, reason: 'keeps its paused position');
    });

    test('a skip in a one-item playlist still starts it over', () async {
      final host = await startHost();
      final a = await addTrack(host, seed: 48, durationUs: 60000000);
      host
        ..setMedia(a.mediaId)
        ..play();
      final rev = host.snapshot.rev;
      host.next();
      expect(host.snapshot.rev, rev + 2, reason: 'select, then start');
      expect(host.snapshot.status, PlaybackStatus.playing);
      expect(host.snapshot.anchor!.positionUs, 0);
    });
  });
}

/// Starts a `POST /media` of [bytes] under [uploadKey] and holds its body
/// back after the first [split] bytes, returning once the host has accepted
/// the request (its reservation is held). The returned function sends the
/// rest and completes with the response status.
Future<Future<int> Function()> _startSlowUpload(
  JamHostServer host,
  String uploadKey,
  Uint8List bytes, {
  int split = 1024,
}) async {
  final http = HttpClient();
  addTearDown(() => http.close(force: true));
  final req = await http.postUrl(
    Uri.parse('http://127.0.0.1:${host.port}/media'),
  );
  req.headers
    ..set(HttpHeaders.authorizationHeader, 'Bearer ${host.token}')
    ..set('X-LocalJam-Kind', 'audio')
    ..set(JamGuestClient.uploadKeyHeader, uploadKey);
  req.contentLength = bytes.length;
  req.add(bytes.sublist(0, split));
  await req.flush();
  await waitFor(
    () => host.debugUploadsInFlight == 1,
    reason: 'the upload to be accepted',
  );
  return () async {
    req.add(bytes.sublist(split));
    final res = await req.close();
    await res.drain<void>();
    return res.statusCode;
  };
}

/// A guest whose control socket runs through a [BlackholeProxy], so the
/// test can make it go dark — an unexpected drop the host notices only by
/// silence (§3.3) — while uploads, made straight to the host, keep going.
Future<(JamGuestClient, BlackholeProxy)> _joinBehindProxy(
  JamHostServer host, {
  required String clientId,
}) async {
  final proxy = await BlackholeProxy.start(host.port);
  final uri = host.joinUriFor(InternetAddress.loopbackIPv4);
  final guest = await JamGuestClient.connect(
    uri.replace(
      queryParameters: {...uri.queryParameters, 'port': '${proxy.port}'},
    ),
    clientName: 'guest',
    clientId: clientId,
    pingInterval: const Duration(milliseconds: 100),
  );
  addTearDown(guest.close);
  return (guest, proxy);
}

/// The `addedBy` of a raw `playlist` frame's only item.
String? _addedBy(Map<String, Object?> frame) {
  final items = (frame['payload'] as Map)['items'] as List;
  return items.isEmpty ? null : (items.single as Map)['addedBy'] as String?;
}

/// `(peerId, uploadKey)` from a raw welcome (§3.1 `welcome.you`).
(String, String) _you(List<Map<String, Object?>> frames) {
  final payload =
      frames.firstWhere((f) => f['type'] == 'welcome')['payload'] as Map;
  final you = payload['you'] as Map;
  return (you['peerId'] as String, you['uploadKey'] as String);
}
