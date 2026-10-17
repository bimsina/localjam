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
///
/// Every reject is terminal for the join it answers: a guest never retries
/// the same `hello` against the same host (§3.1). That includes a reason
/// this client does not know, which decodes to [unknown] instead of
/// throwing — otherwise a reason added in a later 1.x would be dropped as a
/// malformed frame and look like a host that never answered.
enum RejectReason {
  badToken('bad_token'),
  full('full'),

  /// The guest's major protocol version is not one the host speaks (§2).
  version('version'),

  /// This device was kicked from the session and the host has not let it
  /// back in (§5.6). Rejoining is the host's call, not a retry's.
  kicked('kicked'),

  /// A reason from a later protocol version. Still a reject, still final.
  unknown('unknown');

  const RejectReason(this.wire);

  /// Wire string for this reason.
  final String wire;

  /// The reason [wire] names, or [RejectReason.unknown] for anything this
  /// version does not know (tolerant decoding, §2).
  static RejectReason fromWire(String wire) =>
      values.firstWhere((r) => r.wire == wire, orElse: () => unknown);
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
  internal('internal'),

  /// A code from a later protocol version. The error's `fatal` flag still
  /// says whether the connection is ending (§8).
  unknown('unknown');

  const ErrorCode(this.wire);

  /// Wire string for this code.
  final String wire;

  /// The code [wire] names, or [ErrorCode.unknown] for anything this version
  /// does not know (tolerant decoding, §2).
  static ErrorCode fromWire(String wire) =>
      values.firstWhere((c) => c.wire == wire, orElse: () => unknown);
}

/// Why a session ended, as carried by `session_ended` (PROTOCOL.md §3.4).
enum SessionEndedReason {
  /// The host deliberately ended the room: "End jam", not a crash.
  hostEnded('host_ended'),

  /// A reason this client does not know. `session_ended` is terminal
  /// whatever the reason, so an unrecognized one decodes here instead of
  /// throwing — a later protocol version may name reasons we predate, and
  /// the guest still must leave rather than sit in reconnect (§2).
  unknown('unknown');

  const SessionEndedReason(this.wire);

  /// Wire string for this reason.
  final String wire;

  /// The reason [wire] names, or [SessionEndedReason.unknown] for anything
  /// this version does not know (forward compatibility, §2).
  static SessionEndedReason fromWire(String wire) =>
      values.firstWhere((r) => r.wire == wire, orElse: () => unknown);
}

/// Kind of a playlist item (PROTOCOL.md §6.1).
enum MediaKind {
  audio('audio'),
  video('video'),
  image('image');

  const MediaKind(this.wire);

  /// Wire string for this kind.
  final String wire;

  /// The kind [wire] names. Throws [FormatException] for a kind this
  /// version does not know — see [tryFromWire] for the tolerant form.
  static MediaKind fromWire(String wire) =>
      tryFromWire(wire) ??
      (throw FormatException('Unknown media kind: "$wire"'));

  /// The kind [wire] names, or null when this version does not know it. A
  /// playlist item of an unknown kind is one this client cannot play, so
  /// decoders drop the item rather than the whole playlist (§6.1).
  static MediaKind? tryFromWire(String wire) {
    for (final kind in values) {
      if (kind.wire == wire) return kind;
    }
    return null;
  }
}

/// A guest's local fetch state for one media item (PROTOCOL.md §6.3).
enum MediaFetchState {
  none('none'),
  fetching('fetching'),
  ready('ready');

  const MediaFetchState(this.wire);

  /// Wire string for this state.
  final String wire;

  /// The state [wire] names. A state this version does not know decodes as
  /// [none]: whatever a later guest means by it, the host cannot count it as
  /// possession, and the readiness gate (§6.3) must not wait on it.
  static MediaFetchState fromWire(String wire) =>
      values.firstWhere((s) => s.wire == wire, orElse: () => none);
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
    orElse: () => throw FormatException('Unknown request action: "$wire"'),
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

  /// [PeerInfo.fromJson], or null for an entry that does not fit the schema
  /// — so one bad roster entry costs that entry, not the whole `welcome`.
  static PeerInfo? tryFromJson(Map<String, Object?> json) {
    try {
      return PeerInfo.fromJson(json);
    } catch (_) {
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is PeerInfo &&
      other.peerId == peerId &&
      other.clientName == clientName &&
      other.clientKind == clientKind;

  @override
  int get hashCode => Object.hash(peerId, clientName, clientKind);
}

/// Container extensions stripped from a filename when it stands in for a
/// missing tag title ([MediaItem.displayTitle]).
///
/// A whitelist, not "everything after the last dot": a track legitimately
/// called `Vol. 2` or `Ep. 04` must keep its number, and only a known media
/// suffix is noise worth hiding.
const Set<String> _strippableMediaExtensions = {
  'aac',
  'aif',
  'aiff',
  'alac',
  'caf',
  'flac',
  'm4a',
  'm4b',
  'mp3',
  'mp4',
  'oga',
  'ogg',
  'opus',
  'wav',
  'wma',
};

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

  /// The best display title: [title] when tagged, else the filename with its
  /// media extension stripped ("track1.m4a" reads as "track1"). The untouched
  /// filename stays available as [name] for anything that needs the real file
  /// — cache keys, downloads, diagnostics.
  ///
  /// A name that is all extension (`.mp3`) or carries an unrecognized suffix
  /// is returned whole; there is nothing better to show.
  String get displayTitle {
    final tagged = title;
    if (tagged != null && tagged.isNotEmpty) return tagged;
    final dot = name.lastIndexOf('.');
    if (dot <= 0) return name;
    final extension = name.substring(dot + 1).toLowerCase();
    if (!_strippableMediaExtensions.contains(extension)) return name;
    return name.substring(0, dot);
  }

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

  /// Decodes one §6.1 item. Throws for an unknown `kind` or a field of the
  /// wrong type; playlist decoders use [tryFromJson] instead.
  ///
  /// A non-positive `durationUs` decodes as null (unknown): no real item
  /// lasts zero or negative time, and passing one on would make every
  /// position "past the end" (§5.5).
  factory MediaItem.fromJson(Map<String, Object?> json) {
    final durationUs = json['durationUs'] as int?;
    return MediaItem(
      mediaId: json['mediaId'] as String,
      kind: MediaKind.fromWire(json['kind'] as String),
      name: (json['name'] as String?) ?? '',
      mime: (json['mime'] as String?) ?? '',
      sizeBytes: (json['sizeBytes'] as int?) ?? 0,
      durationUs: durationUs != null && durationUs > 0 ? durationUs : null,
      sha256: (json['sha256'] as String?) ?? '',
      title: json['title'] as String?,
      artist: json['artist'] as String?,
      album: json['album'] as String?,
      artworkId: json['artworkId'] as String?,
      addedBy: json['addedBy'] as String?,
    );
  }

  /// [MediaItem.fromJson], or null for an item this client cannot use: a
  /// `kind` from a later protocol version, or an entry that does not fit the
  /// schema. Playlists drop such items and keep the rest (§2, §6.1) — one
  /// video item must never cost an audio-only guest the whole queue.
  static MediaItem? tryFromJson(Map<String, Object?> json) {
    final kind = json['kind'];
    if (kind is! String || MediaKind.tryFromWire(kind) == null) return null;
    try {
      return MediaItem.fromJson(json);
    } catch (_) {
      return null;
    }
  }

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
  int get hashCode => Object.hash(
    mediaId,
    kind,
    name,
    mime,
    sizeBytes,
    durationUs,
    sha256,
    title,
    artist,
    album,
    artworkId,
    addedBy,
  );
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
    this.clientId,
  });

  static const wireType = 'hello';

  final String token;
  final String clientName;
  final String clientKind;

  /// Peer id to resume within the host's reconnect grace window (§3.3).
  /// Omitted from the wire when null (fresh join).
  final String? resumePeerId;

  /// Stable per-device id (optional): one device is one peer slot, so
  /// a host replaces any peer already joined under this id instead of
  /// leaving a ghost of it in the roster (§3.3). Omitted when null — a
  /// client without one can never resume or keep a role across rejoins.
  final String? clientId;

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
    if (clientId != null) 'clientId': clientId,
  };

  factory HelloMessage.fromPayload(Map<String, Object?> json) => HelloMessage(
    token: json['token'] as String,
    clientName: (json['clientName'] as String?) ?? '',
    clientKind: (json['clientKind'] as String?) ?? '',
    caps: _stringList(json['caps']),
    encodings: _stringList(json['encodings'], fallback: const ['json']),
    resumePeerId: json['resumePeerId'] as String?,
    clientId: json['clientId'] as String?,
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
    this.host,
    this.uploadKey,
    this.hostAway = false,
  });

  static const wireType = 'welcome';

  final String sessionId;
  final String sessionName;

  /// The joining guest's own peer id (wire shape: `you: {peerId}`).
  final String selfPeerId;

  /// This peer's upload credential (wire: `you.uploadKey`, §6.4): an opaque
  /// secret issued per join, presented as `X-LocalJam-Upload-Key` on
  /// `POST /media`. It is how the host knows WHICH peer is uploading — the
  /// session token only proves someone is in the room. Null from a host that
  /// accepts no uploads from this peer.
  final String? uploadKey;

  /// Whether the host had announced it is away (§3.5) when this guest
  /// joined. Omitted from the wire when false.
  final bool hostAway;

  final List<PeerInfo> peers;

  /// Full current playback state, so late join is just convergence.
  final PlaybackSnapshot snapshot;

  final List<MediaItem> playlist;

  /// The room permission document (§5.6). Null only from a host that omits it;
  /// clients then assume listen-only until a broadcast arrives.
  final JamPermissions? permissions;

  /// The host itself as a person (optional): peerId is the reserved
  /// [JamPermissions.hostPeerId] and `clientName` its display identity
  /// ("Silky Puffin"), so guests can name the host in a roster and in
  /// "added by" bylines instead of calling everyone's host "Host". NOT a
  /// member of [peers] — the host is not a joined peer (§5.6). Null from a
  /// host that does not send one; clients fall back to the role word.
  final PeerInfo? host;

  @override
  String get type => wireType;

  @override
  Map<String, Object?> payloadToJson() => {
    'sessionId': sessionId,
    'sessionName': sessionName,
    'you': {'peerId': selfPeerId, 'uploadKey': ?uploadKey},
    'peers': [for (final p in peers) p.toJson()],
    'snapshot': snapshot.toJson(),
    'playlist': [for (final i in playlist) i.toJson()],
    if (permissions != null) 'permissions': permissions!.toJson(),
    if (host != null) 'host': host!.toJson(),
    if (hostAway) 'hostAway': true,
  };

  factory WelcomeMessage.fromPayload(Map<String, Object?> json) {
    final you = json['you'] as Map<String, Object?>? ?? const {};
    final rawPermissions = json['permissions'];
    final rawHost = json['host'];
    final uploadKey = you['uploadKey'];
    return WelcomeMessage(
      sessionId: json['sessionId'] as String,
      sessionName: (json['sessionName'] as String?) ?? '',
      selfPeerId: you['peerId'] as String,
      peers: _tolerantList(json['peers'], PeerInfo.tryFromJson),
      snapshot: PlaybackSnapshot.fromJson(
        json['snapshot'] as Map<String, Object?>,
      ),
      playlist: _tolerantList(json['playlist'], MediaItem.tryFromJson),
      permissions: rawPermissions is Map
          ? JamPermissions.fromJson(rawPermissions.cast<String, Object?>())
          : null,
      host: rawHost is Map
          ? PeerInfo.tryFromJson(rawHost.cast<String, Object?>())
          : null,
      uploadKey: uploadKey is String && uploadKey.isNotEmpty ? uploadKey : null,
      hostAway: json['hostAway'] == true,
    );
  }
}

/// H→G join rejection (PROTOCOL.md §3.1). Terminal for the join it answers.
class RejectMessage extends Message {
  const RejectMessage({required this.reason, this.versions = const []});

  static const wireType = 'reject';

  final RejectReason reason;

  /// For [RejectReason.version]: the major protocol versions the host does
  /// speak (§2), so a guest can tell "update this app" from "the host's app
  /// is the old one". Omitted from the wire when empty.
  final List<int> versions;

  @override
  String get type => wireType;

  @override
  Map<String, Object?> payloadToJson() => {
    'reason': reason.wire,
    if (versions.isNotEmpty) 'versions': versions,
  };

  factory RejectMessage.fromPayload(Map<String, Object?> json) {
    final rawVersions = json['versions'];
    return RejectMessage(
      // An absent reason is still a reject (§3.1): a guest that cannot say
      // why it was refused must still stop asking.
      reason: RejectReason.fromWire(
        (json['reason'] as String?) ?? RejectReason.unknown.wire,
      ),
      versions: rawVersions is List
          ? List.unmodifiable(rawVersions.whereType<int>())
          : const [],
    );
  }
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

/// H→* the room is over, deliberately (PROTOCOL.md §3.4).
///
/// Sent immediately before the host closes every socket, so a planned
/// shutdown ("End jam") is distinguishable from a crash or a walk out of
/// range — which is only detectable as silence, and so costs guests a long
/// reconnect timeout. Terminal: a guest that receives one must not attempt
/// to reconnect, whatever the [reason] says.
class SessionEndedMessage extends Message {
  const SessionEndedMessage({this.reason = SessionEndedReason.hostEnded});

  static const wireType = 'session_ended';

  final SessionEndedReason reason;

  @override
  String get type => wireType;

  @override
  Map<String, Object?> payloadToJson() => {'reason': reason.wire};

  factory SessionEndedMessage.fromPayload(Map<String, Object?> json) =>
      SessionEndedMessage(
        // An absent or unrecognized reason still ends the session (§2).
        reason: SessionEndedReason.fromWire(
          (json['reason'] as String?) ?? SessionEndedReason.unknown.wire,
        ),
      );
}

/// H→* the host's own availability (PROTOCOL.md §3.5).
///
/// `away: true` is sent just before the host expects to stop answering —
/// typically a phone host going to the background, which the OS may suspend
/// — and `away: false` when it is back. It turns the silence that follows
/// from "the host died" into "the host's phone is asleep": guests still
/// notice the dead connection quickly (§3.3) and keep reconnecting, but give
/// up on the room only after a much longer wait. The latest value also rides
/// `welcome.hostAway`, so a guest that (re)joins mid-nap is told too.
class HostStatusMessage extends Message {
  const HostStatusMessage({required this.away});

  static const wireType = 'host_status';

  final bool away;

  @override
  String get type => wireType;

  @override
  Map<String, Object?> payloadToJson() => {'away': away};

  factory HostStatusMessage.fromPayload(Map<String, Object?> json) =>
      HostStatusMessage(away: json['away'] == true);
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
  const ClockPongMessage({
    required this.t0,
    required this.t1,
    required this.t2,
  });

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

  /// Items this client cannot use (an unknown `kind`, a malformed entry)
  /// are dropped; the rest of the playlist stands (§2, §6.1).
  factory PlaylistMessage.fromPayload(Map<String, Object?> json) =>
      PlaylistMessage(
        rev: json['rev'] as int,
        items: _tolerantList(json['items'], MediaItem.tryFromJson),
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

/// Decodes each object entry of [value] with [decode], keeping the ones it
/// accepts: the list survives entries it cannot use (§2).
List<T> _tolerantList<T>(
  Object? value,
  T? Function(Map<String, Object?> json) decode,
) => [for (final e in _mapList(value)) ?decode(e)];
