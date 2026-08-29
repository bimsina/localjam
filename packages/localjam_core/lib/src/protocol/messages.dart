import 'package:meta/meta.dart';

import '../session/permissions.dart';
import '../session/playback_state.dart';

/// Wire message types for the LocalJam control plane (PROTOCOL.md).
///
/// Every concrete [Message] knows its wire `type` string and how to serialize
/// its payload; `fromPayload` factories perform the reverse. Unknown payload
/// fields are ignored on decode (forward compatibility, PROTOCOL.md §2), and
/// absent optional fields never crash decoding.
///
/// All times are integer microseconds.

// ---------------------------------------------------------------------------
// Supporting value types
// ---------------------------------------------------------------------------

/// Why the host rejected a join (PROTOCOL.md §3.1).
enum RejectReason {
  badToken('bad_token'),
  full('full'),
  version('version');

  const RejectReason(this.wire);

  /// Wire string for this reason.
  final String wire;

  static RejectReason fromWire(String wire) => values.firstWhere(
        (r) => r.wire == wire,
        orElse: () =>
            throw FormatException('Unknown reject reason: "$wire"'),
      );
}

/// Error codes carried by the `error` message (PROTOCOL.md §8).
enum ErrorCode {
  badToken('bad_token'),
  versionUnsupported('version_unsupported'),
  sessionFull('session_full'),
  mediaGone('media_gone'),

  /// The requesting peer lacks the capability for that action (§5.6).
  /// Never fatal: the connection stays up.
  notAllowed('not_allowed'),

  /// The peer was removed from the session by the host (§5.6). Always
  /// fatal; the close follows and clients must not auto-rejoin.
  kicked('kicked'),
  internal('internal');

  const ErrorCode(this.wire);

  /// Wire string for this code.
  final String wire;

  static ErrorCode fromWire(String wire) => values.firstWhere(
        (c) => c.wire == wire,
        orElse: () => throw FormatException('Unknown error code: "$wire"'),
      );
}

/// Kind of a playlist item (PROTOCOL.md §6.1).
enum MediaKind {
  audio('audio'),
  video('video'),
  image('image');

  const MediaKind(this.wire);

  /// Wire string for this kind.
  final String wire;

  static MediaKind fromWire(String wire) => values.firstWhere(
        (k) => k.wire == wire,
        orElse: () => throw FormatException('Unknown media kind: "$wire"'),
      );
}

/// A guest's local fetch state for one media item (PROTOCOL.md §6.3).
enum MediaFetchState {
  none('none'),
  fetching('fetching'),
  ready('ready');

  const MediaFetchState(this.wire);

  /// Wire string for this state.
  final String wire;

  static MediaFetchState fromWire(String wire) => values.firstWhere(
        (s) => s.wire == wire,
        orElse: () =>
            throw FormatException('Unknown media fetch state: "$wire"'),
      );
}

/// Action a guest asks the host to apply (PROTOCOL.md §5.2).
enum RequestAction {
  play('play'),
  pause('pause'),
  seek('seek'),
  setMedia('set_media'),

  /// Skip to the next queue item (wrapping). Unambiguous under races, unlike
  /// a guest-computed set_media.
  next('next'),

  /// Skip to the previous queue item (wrapping).
  previous('previous'),

  /// Move [RequestMessage.mediaId] to [RequestMessage.toIndex] (§5.6).
  queueMove('queue_move'),

  /// Remove [RequestMessage.mediaId] from the queue (§5.6).
  queueRemove('queue_remove');

  const RequestAction(this.wire);

  /// Wire string for this action.
  final String wire;

  static RequestAction fromWire(String wire) => values.firstWhere(
        (a) => a.wire == wire,
        orElse: () =>
            throw FormatException('Unknown request action: "$wire"'),
      );
}

/// A peer as announced by the host (PROTOCOL.md §3.1/§3.2).
@immutable
class PeerInfo {
  const PeerInfo({
    required this.peerId,
    required this.clientName,
    required this.clientKind,
  });

  final String peerId;
  final String clientName;

  /// Open-ended on the wire ("flutter", "web", ...); kept as a string.
  final String clientKind;

  Map<String, Object?> toJson() => {
        'peerId': peerId,
        'clientName': clientName,
        'clientKind': clientKind,
      };

  factory PeerInfo.fromJson(Map<String, Object?> json) => PeerInfo(
        peerId: json['peerId'] as String,
        clientName: (json['clientName'] as String?) ?? '',
        clientKind: (json['clientKind'] as String?) ?? '',
      );

  @override
  bool operator ==(Object other) =>
      other is PeerInfo &&
      other.peerId == peerId &&
      other.clientName == clientName &&
      other.clientKind == clientKind;

  @override
  int get hashCode => Object.hash(peerId, clientName, clientKind);
}

/// One playlist entry (PROTOCOL.md §6.1).
@immutable
class MediaItem {
  const MediaItem({
    required this.mediaId,
    required this.kind,
    required this.name,
    required this.mime,
    required this.sizeBytes,
    this.durationUs,
    required this.sha256,
    this.title,
    this.artist,
    this.album,
    this.artworkId,
    this.addedBy,
  });

  final String mediaId;
  final MediaKind kind;
  final String name;
  final String mime;
  final int sizeBytes;

  /// Null for items without an intrinsic duration (e.g. images).
  final int? durationUs;

  /// Lowercase hex digest of the file, for caching and verification.
  final String sha256;

  /// Tag metadata (§6.1), extracted by the host; null when the file carried
  /// no usable tags. [name] (the display filename) is the fallback.
  final String? title;
  final String? artist;
  final String? album;

  /// Content-derived id of the item's embedded artwork (`a_` + first 12 hex
  /// chars of the artwork bytes' sha256), fetchable via
  /// `GET /artwork/{artworkId}` (§6.5). Null when the item has none. Items
  /// sharing artwork bytes (an album) share one artworkId.
  final String? artworkId;

  /// Who contributed the item (§5.6 attribution): a peerId, the reserved
  /// [JamPermissions.hostPeerId], or null for legacy items.
  final String? addedBy;

  /// The best display title: [title] when tagged, else [name].
  String get displayTitle => (title?.isNotEmpty ?? false) ? title! : name;

  Map<String, Object?> toJson() => {
        'mediaId': mediaId,
        'kind': kind.wire,
        'name': name,
        'mime': mime,
        'sizeBytes': sizeBytes,
        'durationUs': durationUs,
        'sha256': sha256,
        if (title != null) 'title': title,
        if (artist != null) 'artist': artist,
        if (album != null) 'album': album,
        if (artworkId != null) 'artworkId': artworkId,
        if (addedBy != null) 'addedBy': addedBy,
      };

  factory MediaItem.fromJson(Map<String, Object?> json) => MediaItem(
        mediaId: json['mediaId'] as String,
        kind: MediaKind.fromWire(json['kind'] as String),
        name: (json['name'] as String?) ?? '',
        mime: (json['mime'] as String?) ?? '',
        sizeBytes: (json['sizeBytes'] as int?) ?? 0,
        durationUs: json['durationUs'] as int?,
        sha256: (json['sha256'] as String?) ?? '',
        title: json['title'] as String?,
        artist: json['artist'] as String?,
        album: json['album'] as String?,
        artworkId: json['artworkId'] as String?,
        addedBy: json['addedBy'] as String?,
      );

  @override
  bool operator ==(Object other) =>
      other is MediaItem &&
      other.mediaId == mediaId &&
      other.kind == kind &&
      other.name == name &&
      other.mime == mime &&
      other.sizeBytes == sizeBytes &&
      other.durationUs == durationUs &&
      other.sha256 == sha256 &&
      other.title == title &&
      other.artist == artist &&
      other.album == album &&
      other.artworkId == artworkId &&
      other.addedBy == addedBy;

  @override
  int get hashCode => Object.hash(mediaId, kind, name, mime, sizeBytes,
      durationUs, sha256, title, artist, album, artworkId, addedBy);
}

// ---------------------------------------------------------------------------
// Message hierarchy
// ---------------------------------------------------------------------------

/// Base class for every control-plane message (PROTOCOL.md §2).
///
/// The envelope fields (`v`, `seq`) live in the codec; a [Message] is the
/// `type` + `payload` pair.
@immutable
sealed class Message {
  const Message();

  /// The wire `type` string (snake_case, per PROTOCOL.md).
  String get type;

  /// Serializes this message's `payload` object.
  Map<String, Object?> payloadToJson();
}

/// G→H join handshake (PROTOCOL.md §3.1).
class HelloMessage extends Message {
  const HelloMessage({
    required this.token,
    required this.clientName,
    required this.clientKind,
    this.caps = const [],
    this.encodings = const ['json'],
    this.resumePeerId,
  });

  static const wireType = 'hello';

  final String token;
  final String clientName;
  final String clientKind;

  /// Peer id to resume within the host's reconnect grace window (§3.3).
  /// Omitted from the wire when null (fresh join).
  final String? resumePeerId;

  /// Capabilities, e.g. "audio", "video".
  final List<String> caps;

  /// Reserved for future binary encoding negotiation.
  final List<String> encodings;

  @override
  String get type => wireType;

  @override
  Map<String, Object?> payloadToJson() => {
        'token': token,
        'clientName': clientName,
        'clientKind': clientKind,
        'caps': caps,
        'encodings': encodings,
        if (resumePeerId != null) 'resumePeerId': resumePeerId,
      };

  factory HelloMessage.fromPayload(Map<String, Object?> json) => HelloMessage(
        token: json['token'] as String,
        clientName: (json['clientName'] as String?) ?? '',
        clientKind: (json['clientKind'] as String?) ?? '',
        caps: _stringList(json['caps']),
        encodings: _stringList(json['encodings'], fallback: const ['json']),
        resumePeerId: json['resumePeerId'] as String?,
      );
}

/// H→G successful join response (PROTOCOL.md §3.1).
class WelcomeMessage extends Message {
  const WelcomeMessage({
    required this.sessionId,
    required this.sessionName,
    required this.selfPeerId,
    this.peers = const [],
    required this.snapshot,
    this.playlist = const [],
    this.permissions,
  });

  static const wireType = 'welcome';

  final String sessionId;
  final String sessionName;

  /// The joining guest's own peer id (wire shape: `you: {peerId}`).
  final String selfPeerId;

  final List<PeerInfo> peers;

  /// Full current playback state, so late join is just convergence.
  final PlaybackSnapshot snapshot;

  final List<MediaItem> playlist;

  /// The room permission document (§5.6). Null only from a pre-v0.2 host;
  /// clients then assume listen-only until a broadcast arrives.
  final JamPermissions? permissions;

  @override
  String get type => wireType;

  @override
  Map<String, Object?> payloadToJson() => {
        'sessionId': sessionId,
        'sessionName': sessionName,
        'you': {'peerId': selfPeerId},
        'peers': [for (final p in peers) p.toJson()],
        'snapshot': snapshot.toJson(),
        'playlist': [for (final i in playlist) i.toJson()],
        if (permissions != null) 'permissions': permissions!.toJson(),
      };

  factory WelcomeMessage.fromPayload(Map<String, Object?> json) {
    final you = json['you'] as Map<String, Object?>? ?? const {};
    final rawPermissions = json['permissions'];
    return WelcomeMessage(
      sessionId: json['sessionId'] as String,
      sessionName: (json['sessionName'] as String?) ?? '',
      selfPeerId: you['peerId'] as String,
      peers: [
        for (final p in _mapList(json['peers'])) PeerInfo.fromJson(p),
      ],
      snapshot: PlaybackSnapshot.fromJson(
        json['snapshot'] as Map<String, Object?>,
      ),
      playlist: [
        for (final i in _mapList(json['playlist'])) MediaItem.fromJson(i),
      ],
      permissions: rawPermissions is Map
          ? JamPermissions.fromJson(rawPermissions.cast<String, Object?>())
          : null,
    );
  }
}

/// H→G join rejection (PROTOCOL.md §3.1).
class RejectMessage extends Message {
  const RejectMessage({required this.reason});

  static const wireType = 'reject';

  final RejectReason reason;

  @override
  String get type => wireType;

  @override
  Map<String, Object?> payloadToJson() => {'reason': reason.wire};

  factory RejectMessage.fromPayload(Map<String, Object?> json) =>
      RejectMessage(reason: RejectReason.fromWire(json['reason'] as String));
}

/// H→* presence: a peer joined (PROTOCOL.md §3.2).
class PeerJoinedMessage extends Message {
  const PeerJoinedMessage({required this.peer});

  static const wireType = 'peer_joined';

  final PeerInfo peer;

  @override
  String get type => wireType;

  @override
  Map<String, Object?> payloadToJson() => {'peer': peer.toJson()};

  factory PeerJoinedMessage.fromPayload(Map<String, Object?> json) =>
      PeerJoinedMessage(
        peer: PeerInfo.fromJson(json['peer'] as Map<String, Object?>),
      );
}

/// H→* presence: a peer left (PROTOCOL.md §3.2).
class PeerLeftMessage extends Message {
  const PeerLeftMessage({required this.peerId});

  static const wireType = 'peer_left';

  final String peerId;

  @override
  String get type => wireType;

  @override
  Map<String, Object?> payloadToJson() => {'peerId': peerId};

  factory PeerLeftMessage.fromPayload(Map<String, Object?> json) =>
      PeerLeftMessage(peerId: json['peerId'] as String);
}

/// G→H clock sync ping (PROTOCOL.md §4). Times are monotonic microseconds.
class ClockPingMessage extends Message {
  const ClockPingMessage({required this.t0});

  static const wireType = 'clock_ping';

  /// Guest monotonic time (µs) at send.
  final int t0;

  @override
  String get type => wireType;

  @override
  Map<String, Object?> payloadToJson() => {'t0': t0};

  factory ClockPingMessage.fromPayload(Map<String, Object?> json) =>
      ClockPingMessage(t0: json['t0'] as int);
}

/// H→G clock sync pong (PROTOCOL.md §4).
class ClockPongMessage extends Message {
  const ClockPongMessage({required this.t0, required this.t1, required this.t2});

  static const wireType = 'clock_pong';

  /// Echoed guest send time (µs).
  final int t0;

  /// Host receive time (µs, session clock).
  final int t1;

  /// Host send time (µs, session clock).
  final int t2;

  @override
  String get type => wireType;

  @override
  Map<String, Object?> payloadToJson() => {'t0': t0, 't1': t1, 't2': t2};

  factory ClockPongMessage.fromPayload(Map<String, Object?> json) =>
      ClockPongMessage(
        t0: json['t0'] as int,
        t1: json['t1'] as int,
        t2: json['t2'] as int,
      );
}

/// G→H request that the host may apply (PROTOCOL.md §5.2).
///
/// Guests never mutate state directly. [mediaId] accompanies
/// [RequestAction.setMedia]; [positionUs] accompanies [RequestAction.seek].
class RequestMessage extends Message {
  const RequestMessage({
    required this.action,
    this.mediaId,
    this.positionUs,
    this.toIndex,
  });

  static const wireType = 'request';

  final RequestAction action;
  final String? mediaId;
  final int? positionUs;

  /// Target queue index for [RequestAction.queueMove] (§5.6).
  final int? toIndex;

  @override
  String get type => wireType;

  @override
  Map<String, Object?> payloadToJson() => {
        'action': action.wire,
        if (mediaId != null) 'mediaId': mediaId,
        if (positionUs != null) 'positionUs': positionUs,
        if (toIndex != null) 'toIndex': toIndex,
      };

  factory RequestMessage.fromPayload(Map<String, Object?> json) =>
      RequestMessage(
        action: RequestAction.fromWire(json['action'] as String),
        mediaId: json['mediaId'] as String?,
        positionUs: json['positionUs'] as int?,
        toIndex: json['toIndex'] as int?,
      );
}

/// H→* authoritative playback state broadcast (PROTOCOL.md §5.1).
///
/// The payload is exactly a [PlaybackSnapshot].
class StateMessage extends Message {
  const StateMessage({required this.snapshot});

  static const wireType = 'state';

  final PlaybackSnapshot snapshot;

  @override
  String get type => wireType;

  @override
  Map<String, Object?> payloadToJson() => snapshot.toJson();

  factory StateMessage.fromPayload(Map<String, Object?> json) =>
      StateMessage(snapshot: PlaybackSnapshot.fromJson(json));
}

/// H→* playlist broadcast (PROTOCOL.md §6.1).
class PlaylistMessage extends Message {
  const PlaylistMessage({required this.rev, this.items = const []});

  static const wireType = 'playlist';

  /// Increments on every playlist change.
  final int rev;

  final List<MediaItem> items;

  @override
  String get type => wireType;

  @override
  Map<String, Object?> payloadToJson() => {
        'rev': rev,
        'items': [for (final i in items) i.toJson()],
      };

  factory PlaylistMessage.fromPayload(Map<String, Object?> json) =>
      PlaylistMessage(
        rev: json['rev'] as int,
        items: [
          for (final i in _mapList(json['items'])) MediaItem.fromJson(i),
        ],
      );
}

/// H→* room permission document broadcast (PROTOCOL.md §5.6). The payload
/// is exactly a [JamPermissions] (rev included), mirroring how `state`
/// carries a snapshot.
class PermissionsMessage extends Message {
  const PermissionsMessage({required this.permissions});

  static const wireType = 'permissions';

  final JamPermissions permissions;

  @override
  String get type => wireType;

  @override
  Map<String, Object?> payloadToJson() => permissions.toJson();

  factory PermissionsMessage.fromPayload(Map<String, Object?> json) =>
      PermissionsMessage(permissions: JamPermissions.fromJson(json));
}

/// G→H media readiness report (PROTOCOL.md §6.3, §7).
class MediaStatusMessage extends Message {
  const MediaStatusMessage({
    required this.mediaId,
    required this.state,
    this.progress,
    this.reportedLatencyUs,
  });

  static const wireType = 'media_status';

  final String mediaId;
  final MediaFetchState state;

  /// Fetch progress in [0, 1]; meaningful while fetching.
  final double? progress;

  /// Optional platform-reported output latency for host diagnostics (§7).
  final int? reportedLatencyUs;

  @override
  String get type => wireType;

  @override
  Map<String, Object?> payloadToJson() => {
        'mediaId': mediaId,
        'state': state.wire,
        if (progress != null) 'progress': progress,
        if (reportedLatencyUs != null) 'reportedLatencyUs': reportedLatencyUs,
      };

  factory MediaStatusMessage.fromPayload(Map<String, Object?> json) =>
      MediaStatusMessage(
        mediaId: json['mediaId'] as String,
        state: MediaFetchState.fromWire(json['state'] as String),
        progress: (json['progress'] as num?)?.toDouble(),
        reportedLatencyUs: json['reportedLatencyUs'] as int?,
      );
}

/// H→G error report (PROTOCOL.md §8). Fatal errors are followed by a close.
class ErrorMessage extends Message {
  const ErrorMessage({
    required this.code,
    this.message = '',
    this.fatal = false,
  });

  static const wireType = 'error';

  final ErrorCode code;
  final String message;
  final bool fatal;

  @override
  String get type => wireType;

  @override
  Map<String, Object?> payloadToJson() => {
        'code': code.wire,
        'message': message,
        'fatal': fatal,
      };

  factory ErrorMessage.fromPayload(Map<String, Object?> json) => ErrorMessage(
        code: ErrorCode.fromWire(json['code'] as String),
        message: (json['message'] as String?) ?? '',
        fatal: (json['fatal'] as bool?) ?? false,
      );
}

/// A message whose `type` this client does not know.
///
/// PROTOCOL.md §2 requires unknown types to be ignored, not rejected; the
/// codec decodes them into this carrier so callers can log and skip them.
/// It is never produced by this client's own code paths and re-encodes its
/// raw payload verbatim.
class UnknownMessage extends Message {
  const UnknownMessage({required this.type, this.payload = const {}});

  @override
  final String type;

  /// The raw, unparsed payload.
  final Map<String, Object?> payload;

  @override
  Map<String, Object?> payloadToJson() => payload;
}

// ---------------------------------------------------------------------------
// Decode helpers
// ---------------------------------------------------------------------------

List<String> _stringList(Object? value, {List<String> fallback = const []}) {
  if (value is! List) return fallback;
  return List.unmodifiable(value.whereType<String>());
}

List<Map<String, Object?>> _mapList(Object? value) {
  if (value is! List) return const [];
  return [
    for (final e in value)
      if (e is Map) e.cast<String, Object?>(),
  ];
}
