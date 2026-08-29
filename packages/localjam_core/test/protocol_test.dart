import 'dart:convert';

import 'package:localjam_core/src/protocol/codec.dart';
import 'package:localjam_core/src/protocol/messages.dart';
import 'package:localjam_core/src/session/permissions.dart';
import 'package:localjam_core/src/session/playback_state.dart';
import 'package:test/test.dart';

void main() {
  const codec = MessageCodec();

  /// Encodes [message], decodes it back, checks the envelope, and returns the
  /// decoded message. Also verifies the round trip is byte-stable
  /// (encode -> decode -> encode yields the identical JSON string).
  T roundTrip<T extends Message>(T message, {int seq = 7}) {
    final wire = codec.encode(message, seq: seq);
    final decoded = codec.decode(wire);
    expect(decoded.v, 1);
    expect(decoded.seq, seq);
    expect(decoded.message, isA<T>());
    expect(codec.encode(decoded.message, seq: seq), wire);
    return decoded.message as T;
  }

  group('envelope', () {
    test('encode produces the §2 envelope shape', () {
      final wire = codec.encode(const ClockPingMessage(t0: 123), seq: 42);
      final map = jsonDecode(wire) as Map<String, Object?>;
      expect(map, {
        'v': 1,
        'type': 'clock_ping',
        'seq': 42,
        'payload': {'t0': 123},
      });
    });
  });

  group('round trips', () {
    test('hello', () {
      final m = roundTrip(
        const HelloMessage(
          token: 'tok-123',
          clientName: 'Bibek’s phone',
          clientKind: 'flutter',
          caps: ['audio', 'video'],
          encodings: ['json'],
        ),
      );
      expect(m.token, 'tok-123');
      expect(m.clientName, 'Bibek’s phone');
      expect(m.clientKind, 'flutter');
      expect(m.caps, ['audio', 'video']);
      expect(m.encodings, ['json']);
      expect(m.resumePeerId, isNull);
    });

    test('hello with resumePeerId (§3.3 reconnect)', () {
      final m = roundTrip(
        const HelloMessage(
          token: 'tok-123',
          clientName: 'Bibek’s phone',
          clientKind: 'flutter',
          resumePeerId: 'p_7',
        ),
      );
      expect(m.resumePeerId, 'p_7');
      // Omitted from the wire entirely when null (fresh join).
      final fresh = codec.encode(
        const HelloMessage(token: 't', clientName: 'n', clientKind: 'k'),
        seq: 1,
      );
      expect(fresh, isNot(contains('resumePeerId')));
    });

    test('welcome', () {
      const snapshot = PlaybackSnapshot(
        rev: 3,
        status: PlaybackStatus.paused,
        mediaId: 'm_1',
        positionUs: 5000000,
      );
      const item = MediaItem(
        mediaId: 'm_1',
        kind: MediaKind.audio,
        name: 'track.mp3',
        mime: 'audio/mpeg',
        sizeBytes: 1024,
        durationUs: 180000000,
        sha256: 'abababab', // stand-in digest
      );
      final m = roundTrip(
        const WelcomeMessage(
          sessionId: 's_1',
          sessionName: 'RoadTrip',
          selfPeerId: 'p_9',
          peers: [
            PeerInfo(peerId: 'p_1', clientName: 'Host', clientKind: 'flutter'),
          ],
          snapshot: snapshot,
          playlist: [item],
        ),
      );
      expect(m.sessionId, 's_1');
      expect(m.sessionName, 'RoadTrip');
      expect(m.selfPeerId, 'p_9');
      expect(m.peers, hasLength(1));
      expect(m.peers.single.peerId, 'p_1');
      expect(m.snapshot, snapshot);
      expect(m.playlist, [item]);
    });

    test('welcome serializes selfPeerId as you.peerId', () {
      const m = WelcomeMessage(
        sessionId: 's',
        sessionName: 'n',
        selfPeerId: 'p_me',
        snapshot: PlaybackSnapshot.initial,
      );
      expect(m.payloadToJson()['you'], {'peerId': 'p_me'});
    });

    test('reject', () {
      final m = roundTrip(const RejectMessage(reason: RejectReason.badToken));
      expect(m.reason, RejectReason.badToken);
      expect(m.payloadToJson()['reason'], 'bad_token');
    });

    test('peer_joined', () {
      final m = roundTrip(
        const PeerJoinedMessage(
          peer: PeerInfo(peerId: 'p_2', clientName: 'Ana', clientKind: 'web'),
        ),
      );
      expect(
        m.peer,
        const PeerInfo(peerId: 'p_2', clientName: 'Ana', clientKind: 'web'),
      );
    });

    test('peer_left', () {
      final m = roundTrip(const PeerLeftMessage(peerId: 'p_2'));
      expect(m.peerId, 'p_2');
    });

    test('clock_ping', () {
      final m = roundTrip(const ClockPingMessage(t0: 987654321));
      expect(m.t0, 987654321);
    });

    test('clock_pong', () {
      final m = roundTrip(const ClockPongMessage(t0: 1, t1: 2, t2: 3));
      expect(m.t0, 1);
      expect(m.t1, 2);
      expect(m.t2, 3);
    });

    test('request (seek)', () {
      final m = roundTrip(
        const RequestMessage(action: RequestAction.seek, positionUs: 42000000),
      );
      expect(m.action, RequestAction.seek);
      expect(m.positionUs, 42000000);
      expect(m.mediaId, isNull);
    });

    test('request (set_media) uses snake_case action', () {
      final m = roundTrip(
        const RequestMessage(action: RequestAction.setMedia, mediaId: 'm_9f2c'),
      );
      expect(m.action, RequestAction.setMedia);
      expect(m.mediaId, 'm_9f2c');
      expect(m.payloadToJson()['action'], 'set_media');
    });

    test('state round-trips a full PlaybackSnapshot including anchor', () {
      const snapshot = PlaybackSnapshot(
        rev: 17,
        status: PlaybackStatus.playing,
        mediaId: 'm_9f2c',
        anchor: PlaybackAnchor(hostTimeUs: 8123456789, positionUs: 45000000),
        positionUs: 45000000,
        rate: 1.0,
      );
      final m = roundTrip(const StateMessage(snapshot: snapshot));
      expect(m.snapshot, snapshot);
      expect(
        m.snapshot.anchor,
        const PlaybackAnchor(hostTimeUs: 8123456789, positionUs: 45000000),
      );

      // The payload IS the snapshot (no extra wrapper), per §5.1.
      final wire = codec.encode(m, seq: 1);
      final payload =
          (jsonDecode(wire) as Map<String, Object?>)['payload'] as Map;
      expect(payload['rev'], 17);
      expect(payload['anchor'], {
        'hostTime': 8123456789,
        'positionUs': 45000000,
      });
    });

    test('playlist', () {
      const items = [
        MediaItem(
          mediaId: 'm_1',
          kind: MediaKind.audio,
          name: 'a.mp3',
          mime: 'audio/mpeg',
          sizeBytes: 10,
          durationUs: 1000000,
          sha256: '00000000',
        ),
        MediaItem(
          mediaId: 'm_2',
          kind: MediaKind.image,
          name: 'b.png',
          mime: 'image/png',
          sizeBytes: 20,
          sha256: '11111111',
        ),
      ];
      final m = roundTrip(const PlaylistMessage(rev: 5, items: items));
      expect(m.rev, 5);
      expect(m.items, items);
      expect(m.items[1].durationUs, isNull);
    });

    test('playlist item tag metadata round-trips (§6.1 v0.2)', () {
      const tagged = MediaItem(
        mediaId: 'm_3',
        kind: MediaKind.audio,
        name: 'c.m4a',
        mime: 'audio/mp4',
        sizeBytes: 30,
        durationUs: 2000000,
        sha256: '22222222',
        title: 'Night Drive',
        artist: 'The Localhosts',
        album: 'Loopback Sessions',
        artworkId: 'a_0123456789ab',
      );
      final m = roundTrip(const PlaylistMessage(rev: 6, items: [tagged]));
      expect(m.items.single, tagged);
      expect(m.items.single.displayTitle, 'Night Drive');
    });

    test('playlist item without tag fields decodes as null tags (v0.1 '
        'compatibility) and omits them when encoding', () {
      const untagged = MediaItem(
        mediaId: 'm_1',
        kind: MediaKind.audio,
        name: 'a.mp3',
        mime: 'audio/mpeg',
        sizeBytes: 10,
        sha256: '00000000',
      );
      // A v0.1 peer's JSON has no tag keys at all.
      final decoded = MediaItem.fromJson({
        'mediaId': 'm_1',
        'kind': 'audio',
        'name': 'a.mp3',
        'mime': 'audio/mpeg',
        'sizeBytes': 10,
        'sha256': '00000000',
      });
      expect(decoded, untagged);
      expect(decoded.title, isNull);
      expect(decoded.artworkId, isNull);
      expect(decoded.displayTitle, 'a.mp3');
      // And an untagged item's JSON carries no null-valued tag keys.
      final json = untagged.toJson();
      expect(json.containsKey('title'), isFalse);
      expect(json.containsKey('artist'), isFalse);
      expect(json.containsKey('album'), isFalse);
      expect(json.containsKey('artworkId'), isFalse);
    });

    test('request queue ops carry mediaId/toIndex (§5.6)', () {
      final move = roundTrip(
        const RequestMessage(
          action: RequestAction.queueMove,
          mediaId: 'm_1',
          toIndex: 3,
        ),
      );
      expect(move.action, RequestAction.queueMove);
      expect(move.mediaId, 'm_1');
      expect(move.toIndex, 3);

      final remove = roundTrip(
        const RequestMessage(action: RequestAction.queueRemove, mediaId: 'm_2'),
      );
      expect(remove.action, RequestAction.queueRemove);
      expect(remove.mediaId, 'm_2');
      expect(remove.toIndex, isNull);

      expect(
        roundTrip(const RequestMessage(action: RequestAction.next)).action,
        RequestAction.next,
      );
      expect(
        roundTrip(const RequestMessage(action: RequestAction.previous)).action,
        RequestAction.previous,
      );
    });

    test('permissions broadcast round-trips (§5.6)', () {
      final perms = const JamPermissions.initial()
          .promote('p_2')
          .withOverride('p_3', JamCapability.addTracks, allowed: false);
      final m = roundTrip(PermissionsMessage(permissions: perms));
      expect(m.permissions, perms);
    });

    test('welcome carries the permission document; absent = null (§5.6)', () {
      final perms = const JamPermissions.initial(policy: JamPolicy.open);
      final m = roundTrip(
        WelcomeMessage(
          sessionId: 's_1',
          sessionName: 'RoadTrip',
          selfPeerId: 'p_9',
          snapshot: PlaybackSnapshot.initial,
          permissions: perms,
        ),
      );
      expect(m.permissions, perms);

      final legacy = WelcomeMessage.fromPayload({
        'sessionId': 's_1',
        'you': {'peerId': 'p_9'},
        'snapshot': PlaybackSnapshot.initial.toJson(),
      });
      expect(legacy.permissions, isNull);
    });

    test('playlist item addedBy round-trips and is omitted when null', () {
      const item = MediaItem(
        mediaId: 'm_1',
        kind: MediaKind.audio,
        name: 'a.mp3',
        mime: 'audio/mpeg',
        sizeBytes: 10,
        sha256: '00000000',
        addedBy: 'p_4',
      );
      expect(MediaItem.fromJson(item.toJson()), item);
      const bare = MediaItem(
        mediaId: 'm_1',
        kind: MediaKind.audio,
        name: 'a.mp3',
        mime: 'audio/mpeg',
        sizeBytes: 10,
        sha256: '00000000',
      );
      expect(bare.toJson().containsKey('addedBy'), isFalse);
    });

    test('media_status', () {
      final m = roundTrip(
        const MediaStatusMessage(
          mediaId: 'm_1',
          state: MediaFetchState.fetching,
          progress: 0.87,
          reportedLatencyUs: 150000,
        ),
      );
      expect(m.mediaId, 'm_1');
      expect(m.state, MediaFetchState.fetching);
      expect(m.progress, closeTo(0.87, 1e-9));
      expect(m.reportedLatencyUs, 150000);
    });

    test('media_status without optional fields', () {
      final m = roundTrip(
        const MediaStatusMessage(mediaId: 'm_1', state: MediaFetchState.ready),
      );
      expect(m.progress, isNull);
      expect(m.reportedLatencyUs, isNull);
    });

    test('error', () {
      final m = roundTrip(
        const ErrorMessage(
          code: ErrorCode.mediaGone,
          message: 'file removed',
          fatal: true,
        ),
      );
      expect(m.code, ErrorCode.mediaGone);
      expect(m.message, 'file removed');
      expect(m.fatal, isTrue);
      expect(m.payloadToJson()['code'], 'media_gone');
    });
  });

  group('forward compatibility', () {
    test('unknown type decodes to UnknownMessage, never throws', () {
      final decoded = codec.decode(
        jsonEncode({
          'v': 1,
          'type': 'hologram_mode',
          'seq': 99,
          'payload': {'intensity': 11},
        }),
      );
      final m = decoded.message;
      expect(m, isA<UnknownMessage>());
      m as UnknownMessage;
      expect(m.type, 'hologram_mode');
      expect(m.payload, {'intensity': 11});
      // Re-encodes the raw payload verbatim.
      final re = jsonDecode(codec.encode(m, seq: 99)) as Map<String, Object?>;
      expect(re['type'], 'hologram_mode');
      expect(re['payload'], {'intensity': 11});
    });

    test('unknown payload fields on known types are ignored', () {
      final decoded = codec.decode(
        jsonEncode({
          'v': 1,
          'type': 'peer_left',
          'seq': 1,
          'payload': {
            'peerId': 'p_3',
            'futureField': [1, 2, 3],
          },
        }),
      );
      expect((decoded.message as PeerLeftMessage).peerId, 'p_3');
    });

    test('absent optional fields do not crash decoding', () {
      final decoded = codec.decode(
        jsonEncode({
          'v': 1,
          'type': 'hello',
          'seq': 1,
          // caps and encodings absent
          'payload': {'token': 't', 'clientName': 'x', 'clientKind': 'flutter'},
        }),
      );
      final m = decoded.message as HelloMessage;
      expect(m.caps, isEmpty);
      expect(m.encodings, ['json']);
    });
  });

  group('malformed input', () {
    test('non-JSON text throws ProtocolException', () {
      expect(
        () => codec.decode('not json {'),
        throwsA(isA<ProtocolException>()),
      );
    });

    test('non-object frame throws ProtocolException', () {
      expect(() => codec.decode('[1,2,3]'), throwsA(isA<ProtocolException>()));
      expect(() => codec.decode('"hi"'), throwsA(isA<ProtocolException>()));
    });

    test('missing or mistyped envelope fields throw ProtocolException', () {
      expect(
        () => codec.decode(jsonEncode({'type': 'error', 'seq': 1})),
        throwsA(isA<ProtocolException>()),
      );
      expect(
        () => codec.decode(jsonEncode({'v': 1, 'seq': 1})),
        throwsA(isA<ProtocolException>()),
      );
      expect(
        () => codec.decode(jsonEncode({'v': 1, 'type': 'error'})),
        throwsA(isA<ProtocolException>()),
      );
      expect(
        () => codec.decode(
          jsonEncode({'v': '1', 'type': 'error', 'seq': 1, 'payload': {}}),
        ),
        throwsA(isA<ProtocolException>()),
      );
    });

    test('known type with invalid payload throws ProtocolException', () {
      expect(
        () => codec.decode(
          jsonEncode({
            'v': 1,
            'type': 'clock_ping',
            'seq': 1,
            'payload': {'t0': 'not-an-int'},
          }),
        ),
        throwsA(isA<ProtocolException>()),
      );
      expect(
        () => codec.decode(
          jsonEncode({
            'v': 1,
            'type': 'reject',
            'seq': 1,
            'payload': {'reason': 'meteor_strike'},
          }),
        ),
        throwsA(isA<ProtocolException>()),
      );
    });
  });
}
