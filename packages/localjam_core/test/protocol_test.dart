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
      // The fallback title is the filename minus its extension (§6.1).
      expect(decoded.displayTitle, 'a');
      expect(decoded.name, 'a.mp3'); // The real filename is kept as-is.
      // And an untagged item's JSON carries no null-valued tag keys.
      final json = untagged.toJson();
      expect(json.containsKey('title'), isFalse);
      expect(json.containsKey('artist'), isFalse);
      expect(json.containsKey('album'), isFalse);
      expect(json.containsKey('artworkId'), isFalse);
    });

    test('displayTitle strips the media extension from the filename '
        'fallback, and only that', () {
      MediaItem named(String name, {String? title}) => MediaItem(
        mediaId: 'm_1',
        kind: MediaKind.audio,
        name: name,
        mime: 'audio/mp4',
        sizeBytes: 10,
        sha256: '00000000',
        title: title,
      );

      // The reported bug: an untagged file showed as "track1.m4a".
      expect(named('track1.m4a').displayTitle, 'track1');
      expect(named('Track 01.MP3').displayTitle, 'Track 01');
      expect(named('a.b.flac').displayTitle, 'a.b');

      // A tag always wins, extension or not.
      final tagged = named('track1.m4a', title: 'Night Drive');
      expect(tagged.displayTitle, 'Night Drive');
      // An empty tag is not a tag.
      expect(named('track1.m4a', title: '').displayTitle, 'track1');

      // Only known media suffixes are noise: a track really called "Vol. 2"
      // keeps its number, and a name with no extension is untouched.
      expect(named('Vol. 2').displayTitle, 'Vol. 2');
      expect(named('Interview').displayTitle, 'Interview');
      expect(named('notes.txt').displayTitle, 'notes.txt');
      // A name that is nothing but an extension has no better form.
      expect(named('.mp3').displayTitle, '.mp3');
      expect(named('').displayTitle, '');

      // The untouched filename is always still there.
      expect(named('track1.m4a').name, 'track1.m4a');
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

    test('hello carries the stable clientId; omitted when null (§3.3)', () {
      final m = roundTrip(
        const HelloMessage(
          token: 'tok-123',
          clientName: 'Quirky Toucan',
          clientKind: 'flutter',
          clientId: 'c_abc123',
        ),
      );
      expect(m.clientId, 'c_abc123');
      final v01 = codec.encode(
        const HelloMessage(token: 't', clientName: 'n', clientKind: 'k'),
        seq: 1,
      );
      expect(v01, isNot(contains('clientId')));
      // A v0.1 hello still decodes: the field is additive.
      expect(HelloMessage.fromPayload({'token': 't'}).clientId, isNull);
    });

    test('session_ended round-trips; an unknown reason still ends the '
        'session (§3.4)', () {
      final m = roundTrip(
        const SessionEndedMessage(reason: SessionEndedReason.hostEnded),
      );
      expect(m.reason, SessionEndedReason.hostEnded);

      // Forward compatibility: a reason from a later version, or none at
      // all, decodes rather than throwing — the message is terminal either
      // way, and a guest that ignored it would sit in reconnect instead.
      expect(
        SessionEndedMessage.fromPayload({'reason': 'host_exploded'}).reason,
        SessionEndedReason.unknown,
      );
      expect(
        SessionEndedMessage.fromPayload(const {}).reason,
        SessionEndedReason.unknown,
      );
      final decoded = codec
          .decode(codec.encode(const SessionEndedMessage(), seq: 4))
          .message;
      expect(decoded, isA<SessionEndedMessage>());
      expect(decoded.type, 'session_ended');
    });

    test('welcome carries the host identity; absent = null (§3.1)', () {
      final m = roundTrip(
        const WelcomeMessage(
          sessionId: 's_1',
          sessionName: 'RoadTrip',
          selfPeerId: 'p_9',
          snapshot: PlaybackSnapshot.initial,
          host: PeerInfo(
            peerId: JamPermissions.hostPeerId,
            clientName: 'Silky Puffin',
            clientKind: 'flutter',
          ),
        ),
      );
      expect(m.host?.clientName, 'Silky Puffin');
      expect(m.host?.peerId, JamPermissions.hostPeerId);
      // The host is never smuggled into the peer list (§5.6).
      expect(m.peers, isEmpty);

      final legacy = WelcomeMessage.fromPayload({
        'sessionId': 's_1',
        'you': {'peerId': 'p_9'},
        'snapshot': PlaybackSnapshot.initial.toJson(),
      });
      expect(legacy.host, isNull);
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
    });

    // Review 2026-10-17 (S1): any finite rate used to decode, and
    // positionAt then threw on every guest's drift tick.
    String stateFrame(String rate) =>
        '{"v":1,"type":"state","seq":1,"payload":{"rev":1,'
        '"status":"playing","anchor":{"hostTime":0,"positionUs":0},'
        '"positionUs":0,"rate":$rate}}';

    test('a state rate outside [1/32, 32] (or not finite) is malformed', () {
      for (final rate in [
        '1e308',
        '-1e308',
        '1e400', // jsonDecode: Infinity
        '-2.0',
        '0',
        '0.03',
        '32.5',
      ]) {
        expect(
          () => codec.decode(stateFrame(rate)),
          throwsA(isA<ProtocolException>()),
          reason: 'rate $rate',
        );
      }
      for (final rate in ['0.03125', '1', '1.0', '2.5', '32']) {
        final snapshot =
            (codec.decode(stateFrame(rate)).message as StateMessage).snapshot;
        expect(snapshot.rate, double.parse(rate), reason: 'rate $rate');
      }
      // Absent still means 1.0.
      final noRate = codec.decode(
        '{"v":1,"type":"state","seq":1,"payload":{"rev":1,"status":"idle"}}',
      );
      expect((noRate.message as StateMessage).snapshot.rate, 1.0);
    });

    test('positionAt saturates instead of throwing, whatever the snapshot '
        'says', () {
      PlaybackSnapshot playing(double rate, {int positionUs = 0}) =>
          PlaybackSnapshot(
            rev: 1,
            status: PlaybackStatus.playing,
            anchor: PlaybackAnchor(hostTimeUs: 0, positionUs: positionUs),
            rate: rate,
          );
      const max = PlaybackSnapshot.maxPositionUs;
      expect(playing(1e308).positionAt(1000000), max);
      expect(playing(-1e308).positionAt(1000000), -max);
      expect(playing(double.infinity).positionAt(1000000), max);
      expect(playing(double.nan).positionAt(1000000), 0);
      expect(
        playing(1, positionUs: 0x7fffffffffffffff).positionAt(1000000),
        max,
      );
      expect(playing(32).positionAt(0x7fffffffffffffff), max);
      // Ordinary values are untouched.
      expect(playing(1.0, positionUs: 5).positionAt(1000000), 1000005);
      expect(playing(0.5).positionAt(1000001), 500001);
    });
  });

  group('protocol 1 version gate (§2)', () {
    test('a frame of another major version is not decoded past the '
        'envelope', () {
      final decoded = codec.decode(
        jsonEncode({
          'v': 2,
          'type': 'welcome',
          'seq': 3,
          // A v2 welcome shape this codec must not try to read as v1.
          'payload': {'room': 'whatever', 'you': 7},
        }),
      );
      expect(decoded.v, 2);
      expect(decoded.isSupportedVersion, isFalse);
      expect(decoded.message, isA<UnknownMessage>());
      expect(decoded.message.type, 'welcome');
    });

    test('only v and type are required of a foreign-version frame', () {
      final decoded = codec.decode(jsonEncode({'v': 7, 'type': 'hello'}));
      expect(decoded.isSupportedVersion, isFalse);
      expect(decoded.message.type, 'hello');
      expect(decoded.seq, 0);
    });

    test('v1 frames are supported', () {
      final decoded = codec.decode(
        codec.encode(const ClockPingMessage(t0: 1), seq: 1),
      );
      expect(decoded.isSupportedVersion, isTrue);
      expect(MessageCodec.supportsVersion(1), isTrue);
      expect(MessageCodec.supportsVersion(0), isFalse);
      expect(MessageCodec.supportsVersion(2), isFalse);
    });

    test('reject carries the versions the host speaks', () {
      final m = roundTrip(
        const RejectMessage(reason: RejectReason.version, versions: [1]),
      );
      expect(m.reason, RejectReason.version);
      expect(m.versions, [1]);
      expect(const RejectMessage(reason: RejectReason.full).payloadToJson(), {
        'reason': 'full',
      });
    });
  });

  group('tolerant decoding within protocol 1 (§2)', () {
    test('an unknown reject reason is still a reject', () {
      final decoded = codec.decode(
        jsonEncode({
          'v': 1,
          'type': 'reject',
          'seq': 1,
          'payload': {'reason': 'meteor_strike'},
        }),
      );
      expect((decoded.message as RejectMessage).reason, RejectReason.unknown);
      expect(
        RejectMessage.fromPayload(const {}).reason,
        RejectReason.unknown,
        reason: 'a reason-less reject still ends the join',
      );
      expect(RejectReason.fromWire('kicked'), RejectReason.kicked);
    });

    test('an unknown error code decodes to ErrorCode.unknown, fatal kept', () {
      final decoded = codec.decode(
        jsonEncode({
          'v': 1,
          'type': 'error',
          'seq': 1,
          'payload': {'code': 'solar_flare', 'message': 'x', 'fatal': true},
        }),
      );
      final m = decoded.message as ErrorMessage;
      expect(m.code, ErrorCode.unknown);
      expect(m.fatal, isTrue);
    });

    test('playlist items of an unknown kind are dropped, the rest kept', () {
      final decoded = codec.decode(
        jsonEncode({
          'v': 1,
          'type': 'playlist',
          'seq': 1,
          'payload': {
            'rev': 4,
            'items': [
              _itemJson('m_a', 'audio'),
              _itemJson('m_h', 'hologram'),
              {'kind': 'audio'}, // no mediaId: malformed, dropped too
              'not even an object',
              _itemJson('m_b', 'audio'),
            ],
          },
        }),
      );
      final m = decoded.message as PlaylistMessage;
      expect(m.rev, 4);
      expect(m.items.map((i) => i.mediaId), ['m_a', 'm_b']);
    });

    test('an unknown playback status holds still instead of killing the '
        'frame', () {
      final decoded = codec.decode(
        jsonEncode({
          'v': 1,
          'type': 'state',
          'seq': 1,
          'payload': {
            'rev': 9,
            'status': 'buffering',
            'mediaId': 'm_a',
            'anchor': null,
            'positionUs': 1234,
            'rate': 1.0,
          },
        }),
      );
      final snapshot = (decoded.message as StateMessage).snapshot;
      expect(snapshot.status, PlaybackStatus.loading);
      expect(snapshot.positionUs, 1234);
      expect(PlaybackStatus.fromWire('paused'), PlaybackStatus.paused);
    });

    test('an unknown media_status state counts as not holding the file', () {
      final decoded = codec.decode(
        jsonEncode({
          'v': 1,
          'type': 'media_status',
          'seq': 1,
          'payload': {'mediaId': 'm_a', 'state': 'verifying'},
        }),
      );
      expect(
        (decoded.message as MediaStatusMessage).state,
        MediaFetchState.none,
      );
    });

    test('non-positive item durations decode as unknown (§5.5)', () {
      expect(
        MediaItem.fromJson({
          ..._itemJson('m_a', 'audio'),
          'durationUs': 0,
        }).durationUs,
        isNull,
      );
      expect(
        MediaItem.fromJson({
          ..._itemJson('m_a', 'audio'),
          'durationUs': -5,
        }).durationUs,
        isNull,
      );
    });

    test('a future 1.x welcome full of things this guest does not know still '
        'admits it', () {
      final decoded = codec.decode(
        jsonEncode({
          'v': 1,
          'type': 'welcome',
          'seq': 0,
          'payload': {
            'sessionId': 's_1',
            'sessionName': 'Later',
            'you': {'peerId': 'p_2', 'uploadKey': 'k_1', 'avatar': 'fox'},
            'peers': [
              {'peerId': 'p_1', 'clientName': 'A', 'clientKind': 'vr'},
              {'clientName': 'no id'}, // malformed: dropped
            ],
            'snapshot': {
              'rev': 2,
              'status': 'crossfading',
              'mediaId': 'm_a',
              'anchor': null,
              'positionUs': 0,
              'rate': 1.0,
              'crossfadeUs': 3000000,
            },
            'playlist': [
              _itemJson('m_a', 'audio'),
              _itemJson('m_v', 'spatial_audio'),
            ],
            'permissions': {
              'rev': 1,
              'policy': {'addTracks': true, 'reactions': true},
              'cohosts': <String>[],
              'overrides': {
                'p_2': {'add_tracks': true, 'send_reactions': false},
              },
            },
            'hostAway': false,
            'roomTheme': 'sunset',
          },
        }),
      );
      final m = decoded.message as WelcomeMessage;
      expect(m.selfPeerId, 'p_2');
      expect(m.uploadKey, 'k_1');
      expect(m.peers.map((p) => p.peerId), ['p_1']);
      expect(m.snapshot.status, PlaybackStatus.loading);
      expect(m.playlist.map((i) => i.mediaId), ['m_a']);
      expect(m.permissions!.policy.addTracks, isTrue);
      expect(m.hostAway, isFalse);
    });

    test('welcome carries the upload key and the away flag; both omitted '
        'when unset', () {
      final m = roundTrip(
        const WelcomeMessage(
          sessionId: 's',
          sessionName: 'n',
          selfPeerId: 'p_1',
          snapshot: PlaybackSnapshot.initial,
          uploadKey: 'secret',
          hostAway: true,
        ),
      );
      expect(m.uploadKey, 'secret');
      expect(m.hostAway, isTrue);
      final bare = const WelcomeMessage(
        sessionId: 's',
        sessionName: 'n',
        selfPeerId: 'p_1',
        snapshot: PlaybackSnapshot.initial,
      ).payloadToJson();
      expect(bare.containsKey('hostAway'), isFalse);
      expect(bare['you'], {'peerId': 'p_1'});
    });

    test('host_status round-trips (§3.5)', () {
      expect(roundTrip(const HostStatusMessage(away: true)).away, isTrue);
      expect(roundTrip(const HostStatusMessage(away: false)).away, isFalse);
      expect(HostStatusMessage.fromPayload(const {}).away, isFalse);
    });
  });
}

/// A well-formed §6.1 item JSON of [kind].
Map<String, Object?> _itemJson(String mediaId, String kind) => {
  'mediaId': mediaId,
  'kind': kind,
  'name': '$mediaId.bin',
  'mime': 'application/octet-stream',
  'sizeBytes': 10,
  'durationUs': 1000,
  'sha256': '00',
};
