/// LocalJam host: serves the control plane (WebSocket `/ws`) and the media
/// plane (HTTP `/media/{mediaId}`) on one TCP port (PROTOCOL.md §1), and
/// drives a [HostSession] as the single authoritative state writer (§5).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:localjam_core/localjam_core.dart';
import 'package:meta/meta.dart';

import 'media_metadata.dart';
import 'monotonic.dart';

/// What a [JamHostServer] does when the current item reaches its end
/// (PROTOCOL.md §5.5). End of media is only detectable for items whose
/// playlist entry carries a `durationUs`; without one the anchor extrapolates
/// and no policy fires. Guests see only the ordinary state broadcasts the
/// policy produces — no protocol change.
enum JamEndPolicy {
  /// Pause, frozen at exactly the item's duration (the default).
  pause,

  /// Select the next playlist item (wrapping at the end of the playlist)
  /// and immediately schedule playback.
  advance,

  /// Stop: back to idle with no media selected.
  stop,
}

/// Kind of a [JamHostEvent].
enum JamHostEventKind {
  /// A guest completed the join handshake ([JamHostEvent.peer] set).
  peerJoined,

  /// A guest was dropped or left ([JamHostEvent.peerId] set).
  peerLeft,

  /// A guest reported `media_status` ([JamHostEvent.peerId],
  /// [JamHostEvent.mediaId], and [JamHostEvent.mediaState] set;
  /// [JamHostEvent.progress] set when the report carried one).
  peerMediaStatus,

  /// A new authoritative state snapshot was broadcast
  /// ([JamHostEvent.snapshot] set).
  stateBroadcast,

  /// A new playlist was broadcast ([JamHostEvent.playlist] set).
  playlistBroadcast,

  /// A new permission document was broadcast (§5.6;
  /// [JamHostEvent.permissions] set).
  permissionsBroadcast,

  /// A guest's request was refused for lack of a capability (§5.6;
  /// [JamHostEvent.peerId] and [JamHostEvent.deniedAction] set). The guest
  /// got a non-fatal `not_allowed` error.
  requestDenied,

  /// A guest uploaded a new media item over the media plane (§6.4;
  /// [JamHostEvent.mediaId] set, [JamHostEvent.peerId] set when the upload
  /// carried `X-LocalJam-Peer-Id`). Emitted before the playlist broadcast the
  /// upload produces. Idempotent re-uploads of existing content do not fire.
  mediaUploaded,

  /// The current item reached its end ([JamHostEvent.mediaId] set to the
  /// ended item). Emitted exactly once per track end, before the state
  /// broadcast produced by the [JamEndPolicy].
  mediaEnded,
}

/// One observability event from a [JamHostServer]. Fields other than [kind]
/// are set per [JamHostEventKind]; unrelated fields are null.
@immutable
class JamHostEvent {
  const JamHostEvent._(
    this.kind, {
    this.peer,
    this.peerId,
    this.mediaId,
    this.mediaState,
    this.progress,
    this.snapshot,
    this.playlist,
    this.permissions,
    this.deniedAction,
  });

  final JamHostEventKind kind;
  final PeerInfo? peer;
  final String? peerId;
  final String? mediaId;
  final MediaFetchState? mediaState;

  /// Fetch progress in [0, 1] from the guest's `media_status` report, when
  /// it carried one (§6.3). Only set for [JamHostEventKind.peerMediaStatus].
  final double? progress;

  final PlaybackSnapshot? snapshot;
  final List<MediaItem>? playlist;

  /// Set for [JamHostEventKind.permissionsBroadcast].
  final JamPermissions? permissions;

  /// Set for [JamHostEventKind.requestDenied].
  final RequestAction? deniedAction;

  @override
  String toString() =>
      'JamHostEvent(${kind.name}'
      '${peerId != null ? ', peerId: $peerId' : ''}'
      '${mediaId != null ? ', mediaId: $mediaId' : ''})';
}

/// One connected (or connecting) guest socket.
class _GuestConn {
  _GuestConn(this.ws, {required int nowUs})
    : lastFrameUs = nowUs,
      openedUs = nowUs;

  final WebSocket ws;

  /// Assigned after a valid `hello`; null while the handshake is pending.
  String? peerId;
  PeerInfo? info;

  /// The stable per-device id this socket said hello with (§3.3), when it
  /// sent one. Two live sockets never share it: the newer supersedes the
  /// older, so one device is one peer.
  String? clientId;

  /// Monotonic µs of the last received frame, for liveness (§3.3).
  int lastFrameUs;

  /// Monotonic µs at which the socket was accepted, for the pre-hello
  /// timeout: silence alone cannot expire a socket that keeps chattering
  /// without ever authenticating.
  final int openedUs;

  bool get joined => peerId != null;
}

/// The LocalJam host: one [HttpServer] serving both protocol planes
/// (PROTOCOL.md §1), the join/presence/liveness lifecycle (§3), clock-sync
/// pong duty (§4), request application via [HostSession] (§5.2), and media
/// distribution (§6).
class JamHostServer {
  /// Creates a host for a session named [sessionName].
  ///
  /// [token] gates both planes (§9); defaults to a random 128-bit hex string.
  /// [leadTimeUs] is the scheduled-start lead (§5.3). [silenceTimeout],
  /// [reconnectGrace], and [livenessCheckInterval] implement §3.3 (defaults:
  /// drop after 10 s silence, 30 s reconnect grace) and are injectable so
  /// tests can exercise drops quickly. [endPolicy] is applied when the
  /// current item reaches its end (§5.5; checked at the
  /// [livenessCheckInterval] cadence, so end handling lags the exact end by
  /// up to one interval — the broadcast position still lands exactly on the
  /// duration because positions clamp to it).
  ///
  /// [uploadDir] is where guest uploads (§6.4) are stored; when null a fresh
  /// temp directory is created per server instance in [start] and deleted on
  /// [close]. [maxUploadBytes] caps one upload's size (default 512 MB;
  /// over-limit uploads are answered 413), [uploadBudgetBytes] caps their sum
  /// for the whole session and [maxPlaylistLength] the number of queue items
  /// guests can create (both answered 507).
  ///
  /// The remaining knobs bound what an unfriendly LAN neighbour can spend of
  /// the host's memory, sockets and disk (§9 is an honest-guest model, but
  /// "honest" should not mean "unbounded"): [maxPeers] and
  /// [maxPendingConnections] cap joined and half-open sockets,
  /// [maxControlFrameBytes] caps one control frame from a joined peer and
  /// [maxPreHelloFrameBytes] one from a socket that has not said hello yet,
  /// [helloTimeout] drops
  /// sockets that never authenticate, and [restrictToLanRemotes] enforces
  /// §9's "LAN interfaces only" at the request level.
  JamHostServer({
    required this.sessionName,
    this.hostName = '',
    this.hostKind = 'dart',
    String? token,
    int leadTimeUs = 750_000,
    this.endPolicy = JamEndPolicy.pause,
    JamPolicy policy = JamPolicy.jam,
    this.silenceTimeout = const Duration(seconds: 10),
    this.reconnectGrace = const Duration(seconds: 30),
    this.livenessCheckInterval = const Duration(seconds: 1),
    this.uploadDir,
    this.maxUploadBytes = defaultMaxUploadBytes,
    this.uploadBudgetBytes = defaultUploadBudgetBytes,
    this.maxPlaylistLength = defaultMaxPlaylistLength,
    this.maxPeers = defaultMaxPeers,
    this.maxPendingConnections = 8,
    this.maxControlFrameBytes = 256 * 1024,
    this.maxPreHelloFrameBytes = 16 * 1024,
    this.helloTimeout = const Duration(seconds: 10),
    this.restrictToLanRemotes = true,
  }) : token = token ?? _randomHex(16),
       sessionId = 's_${_randomHex(4)}',
       _permissions = JamPermissions.initial(policy: policy),
       _session = HostSession(leadTimeUs: leadTimeUs);

  /// Defaults for the caps above, named so embedders (JamHostEngine, host
  /// UIs) can forward or adjust them without restating the numbers.
  static const int defaultMaxUploadBytes = 512 * 1024 * 1024;
  static const int defaultUploadBudgetBytes = 2 * 1024 * 1024 * 1024;
  static const int defaultMaxPlaylistLength = 500;
  static const int defaultMaxPeers = 32;

  /// Human-readable session name, shared in the join URI and `welcome`.
  final String sessionName;

  /// The host's own display name (§3.1 `welcome.host`) — the persistent
  /// device identity ("Silky Puffin"), NOT the role word. Empty means the
  /// host stays anonymous and guests fall back to calling it "Host".
  final String hostName;

  /// `clientKind` reported for the host itself ("flutter", "dart", ...).
  final String hostKind;

  /// Session token (128-bit hex by default) gating both planes (§9).
  final String token;

  /// Random session id sent in `welcome` (§3.1).
  final String sessionId;

  /// A peer is dropped after this much silence (§3.3, default 10 s).
  final Duration silenceTimeout;

  /// How long a dropped peer's slot stays resumable (§3.3, default 30 s).
  final Duration reconnectGrace;

  /// How often liveness is evaluated. End of media (§5.5) is checked at the
  /// same cadence.
  final Duration livenessCheckInterval;

  /// End-of-media policy (§5.5): what happens when the current item's
  /// position reaches its playlist `durationUs`.
  final JamEndPolicy endPolicy;

  /// Where guest uploads (§6.4) are stored. Null means a per-instance temp
  /// directory, created in [start] and deleted (with its contents) on
  /// [close]; a caller-supplied directory is created if missing and never
  /// deleted.
  final Directory? uploadDir;

  /// Upper bound on a single guest upload's size in bytes (§6.4).
  final int maxUploadBytes;

  /// Upper bound on the SUM of all guest uploads accepted this session
  /// (§6.4). The per-file cap alone bounds nothing: a guest can repeat a
  /// just-under-the-cap upload until the host's disk is gone. Over-budget
  /// uploads are answered 507. Host-side [addMedia] calls (the host's own
  /// library) do not spend the budget — they are not remote input.
  final int uploadBudgetBytes;

  /// Upper bound on how many items guest uploads may put in the playlist
  /// (§6.1). Over-length uploads are answered 507; the host's own [addMedia]
  /// is not capped for the same reason as [uploadBudgetBytes].
  final int maxPlaylistLength;

  /// Upper bound on simultaneously joined peers (§3.1). Joins beyond it are
  /// answered `reject { reason: "full" }`.
  final int maxPeers;

  /// Upper bound on open sockets that have not completed the §3.1 handshake.
  /// Bounds the socket/memory a peer can hold without ever proving it has
  /// the token; over-cap upgrades are refused with 503.
  final int maxPendingConnections;

  /// Upper bound on one control frame from a joined peer (§1), counted in
  /// UTF-8 bytes.
  ///
  /// What this bounds is parse-and-act cost, not buffering: `dart:io`'s
  /// WebSocket has no maximum-message option and reassembles a message
  /// completely before handing it over, so by the time the cap is applied the
  /// bytes have already been received. (Counting raw bytes as they arrive
  /// would mean framing the socket by hand — `WebSocketTransformer.upgrade`
  /// offers no hook, and disabling compression does not help — which is out
  /// of scope for a LAN host.) What it does buy is that nothing large is ever
  /// JSON-parsed or dispatched, and that the sender does not get to do it
  /// twice: the socket is closed with `policyViolation` (1008).
  ///
  /// [maxPreHelloFrameBytes] is the cap that bounds memory usefully, because
  /// it applies to the sockets that have proved nothing.
  final int maxControlFrameBytes;

  /// Upper bound on one control frame from a socket that has not yet
  /// completed the §3.1 handshake (default 16 KB).
  ///
  /// A `hello` is a few hundred bytes — a token, a name, two short ids — so
  /// an unauthenticated socket has no honest reason to send anything near
  /// this, and one that does loses the socket on the first frame instead of
  /// getting [maxControlFrameBytes] of the host's memory per attempt.
  final int maxPreHelloFrameBytes;

  /// How long a socket may stay open without a valid `hello` (§3.1) before
  /// it is dropped. Unauthenticated sockets are the cheapest thing on the
  /// LAN to open and the least entitled to stay.
  final Duration helloTimeout;

  /// Whether requests from non-LAN remote addresses are refused with 403
  /// (§9: "Host MUST bind to LAN interfaces only"). Binding a single LAN
  /// interface is not always possible (a phone on Wi-Fi AND a hotspot needs
  /// one port on several interfaces), so the address filter is the enforced
  /// half of the rule and applies on both planes. Loopback always passes —
  /// tests, the CLI and the host's own UI live there.
  final bool restrictToLanRemotes;

  final HostSession _session;
  JamPermissions _permissions;
  static const MessageCodec _codec = MessageCodec();

  HttpServer? _server;
  Timer? _livenessTimer;

  /// The resolved upload directory (§6.4), set in [start].
  Directory? _uploadDir;

  /// Whether [_uploadDir] was created by this instance (and so is deleted on
  /// [close]).
  bool _ownsUploadDir = false;

  int _seq = 0;
  int _peerCounter = 0;
  int _playlistRev = 0;
  bool _closed = false;

  int _uploadedBytes = 0;

  /// Bytes claimed by uploads that are still arriving (§6.4): the sum of
  /// their `Content-Length`s, reconciled to the bytes actually stored when
  /// each finishes and released on every failure.
  int _reservedBytes = 0;

  /// Playlist entries claimed by uploads that are still arriving, for the
  /// same reason as [_reservedBytes].
  int _pendingUploads = 0;

  /// Bytes of guest uploads accepted this session (§6.4), against
  /// [uploadBudgetBytes]. Exposed for host UIs that want to show the
  /// remaining room.
  int get uploadedBytes => _uploadedBytes;

  /// All open sockets, joined or still handshaking.
  final Set<_GuestConn> _conns = {};

  /// Joined peers by peer id.
  final Map<String, _GuestConn> _peers = {};

  /// Dropped peers eligible for resume (§3.3): peerId → the expiry and the
  /// `clientId` the dropped connection had said hello with.
  ///
  /// The clientId is the half that matters. A peerId is public — it travels
  /// in `welcome.peers`, `peer_joined` and `peer_left` — so a slot keyed on
  /// the peerId alone is claimable by anyone who watched someone drop, and
  /// permissions outlive the drop for the whole grace window (§5.6). The
  /// slot therefore remembers *which device* held it, and only that device
  /// gets it back. A null clientId (a v0.1 client) is never resumable.
  final Map<String, ({int untilUs, String? clientId})> _grace = {};

  /// Media registry: mediaId → (playlist item, backing file).
  final Map<String, ({MediaItem item, File file})> _media = {};
  final List<MediaItem> _playlist = [];

  /// Artwork registry (§6.5): artworkId → (mime, backing file). Artwork ids
  /// are content-derived, so items sharing cover bytes share one entry.
  final Map<String, ({String mime, File file})> _artwork = {};

  final StreamController<JamHostEvent> _events =
      StreamController<JamHostEvent>.broadcast();

  /// Observability events (peer joined/left, media status, broadcasts).
  Stream<JamHostEvent> get events => _events.stream;

  /// The bound port. Throws [StateError] before [start].
  int get port {
    final server = _server;
    if (server == null) throw StateError('JamHostServer is not started');
    return server.port;
  }

  /// The current authoritative playback snapshot (§5.1).
  PlaybackSnapshot get snapshot => _session.snapshot;

  /// The current playlist (§6.1).
  List<MediaItem> get playlist => List.unmodifiable(_playlist);

  /// The room's authoritative permission document (§5.6).
  JamPermissions get permissions => _permissions;

  /// Currently joined peers. Never includes the host: the host is not a
  /// joined peer (§5.6) — see [hostPeer].
  List<PeerInfo> get peers =>
      List.unmodifiable([for (final c in _peers.values) c.info!]);

  /// The host as a person (§3.1 `welcome.host`): the reserved peer id plus
  /// [hostName]. Sent to every joining guest so the host can be named in a
  /// roster and in "added by" bylines.
  PeerInfo get hostPeer => PeerInfo(
    peerId: JamPermissions.hostPeerId,
    clientName: hostName,
    clientKind: hostKind,
  );

  /// Whether every joined peer has reported `ready` for [mediaId] (§6.3).
  bool allPeersReady(String mediaId) => _session.allPeersReady(mediaId);

  /// The readiness [peerId] last reported for [mediaId] (§6.3;
  /// [MediaReadiness.none] if it never reported on that item).
  MediaReadiness peerMediaState(String peerId, String mediaId) =>
      _session.peerMediaState(peerId, mediaId);

  /// Readiness for [mediaId] across all known peers: peerId -> readiness,
  /// defaulting to [MediaReadiness.none] for peers with no report on it.
  Map<String, MediaReadiness> peerMediaStates(String mediaId) =>
      _session.peerMediaStates(mediaId);

  /// Whether [address] belongs to a network a LocalJam room may span (§9):
  /// loopback, RFC1918 private v4 (10/8, 172.16/12, 192.168/16 — which
  /// covers both phone hotspot ranges), link-local v4 (169.254/16, ad-hoc
  /// links), and their v6 equivalents (::1, fe80::/10, fc00::/7). Everything
  /// else — carrier-grade NAT space included — is "the internet" as far as a
  /// host is concerned.
  ///
  /// One exception, and the reason for [hostAddresses]: a native-IPv6 home
  /// network gives every device a *global* unicast address (2000::/3), so
  /// treating all of those as off-LAN locks the neighbours out of the room
  /// they are standing in. Such an address passes only when it shares a /64
  /// — the subnet SLAAC actually hands out — with one of this host's own
  /// interface addresses, which is as close to "same link" as an address
  /// alone can get. With no [hostAddresses] to compare against, global
  /// unicast stays refused.
  ///
  /// Public because choosing which interfaces to bind and advertise is the
  /// caller's job (see `JamHostEngine.start`) and it must agree with the
  /// filter the server enforces.
  static bool isLanAddress(
    InternetAddress address, {
    Iterable<InternetAddress> hostAddresses = const [],
  }) {
    if (address.isLoopback || address.isLinkLocal) return true;
    final bytes = address.rawAddress;
    if (address.type == InternetAddressType.IPv4) {
      if (bytes.length != 4) return false;
      if (bytes[0] == 10) return true;
      if (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) return true;
      if (bytes[0] == 192 && bytes[1] == 168) return true;
      return false;
    }
    if (bytes.length != 16) return false;
    // Unique local addresses (fc00::/7).
    if ((bytes[0] & 0xfe) == 0xfc) return true;
    // A v4 client reaching a dual-stack socket arrives as ::ffff:a.b.c.d.
    final isV4Mapped =
        bytes[10] == 0xff &&
        bytes[11] == 0xff &&
        !bytes.take(10).any((b) => b != 0);
    if (isV4Mapped) {
      return isLanAddress(
        InternetAddress.fromRawAddress(
          Uint8List.fromList(bytes.sublist(12)),
          type: InternetAddressType.IPv4,
        ),
        hostAddresses: hostAddresses,
      );
    }
    // Global unicast (2000::/3): local only if it is on one of our own /64s.
    if ((bytes[0] & 0xe0) == 0x20) {
      for (final own in hostAddresses) {
        final ownBytes = own.rawAddress;
        if (own.type != InternetAddressType.IPv6 || ownBytes.length != 16) {
          continue;
        }
        if ((ownBytes[0] & 0xe0) != 0x20) continue; // Not a GUA of ours.
        var sharesPrefix = true;
        for (var i = 0; i < 8; i++) {
          if (ownBytes[i] != bytes[i]) {
            sharesPrefix = false;
            break;
          }
        }
        if (sharesPrefix) return true;
      }
    }
    return false;
  }

  /// This host's own interface addresses, read once in [start] and used to
  /// judge IPv6 global-unicast remotes (see [isLanAddress]). Best-effort: a
  /// platform that refuses the enumeration just leaves global unicast
  /// refused, which is the pre-v6 behaviour.
  List<InternetAddress> _ownAddresses = const [];

  /// §9 enforcement: a request from off-LAN is served nothing. A missing
  /// remote address (the socket died mid-request) counts as untrusted.
  bool _remoteAllowed(InternetAddress? remote) {
    if (!restrictToLanRemotes) return true;
    return remote != null &&
        isLanAddress(remote, hostAddresses: _ownAddresses);
  }

  /// Length-independent-ish comparison for the session token: an early-exit
  /// `==` leaks how many leading characters a guess got right, which on a
  /// LAN is a practical oracle. The length difference still leaks (it is not
  /// secret — the token is fixed-width hex), the content does not.
  static bool _secureEquals(String a, String b) {
    final x = utf8.encode(a);
    final y = utf8.encode(b);
    var diff = x.length ^ y.length;
    final n = min(x.length, y.length);
    for (var i = 0; i < n; i++) {
      diff |= x[i] ^ y[i];
    }
    return diff == 0;
  }

  /// Whether an `Authorization` header carries this session's token (§6.2,
  /// §6.4, §6.5).
  bool _bearerMatches(String? header) {
    const prefix = 'Bearer ';
    if (header == null || !header.startsWith(prefix)) return false;
    return _secureEquals(header.substring(prefix.length), token);
  }

  /// Shape check for a media/artwork id taken off the wire.
  ///
  /// Ids are only ever keys into the in-memory [_media] / [_artwork]
  /// registries — never joined into a filesystem path — so traversal is
  /// structurally impossible and an unknown id is a plain 404. This rejects
  /// separators and dot segments anyway, so a future refactor that does
  /// touch the filesystem cannot silently turn a 404 into a file read.
  static bool _isSafeResourceId(String id) =>
      id.isNotEmpty &&
      id.length <= 128 &&
      !id.contains('/') &&
      !id.contains(r'\') &&
      !id.contains('..') &&
      !id.contains(' ');

  static String _randomHex(int bytes) {
    final rng = Random.secure();
    final sb = StringBuffer();
    for (var i = 0; i < bytes; i++) {
      sb.write(rng.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  int _nowUs() => monotonicNowUs();

  // --- Lifecycle -------------------------------------------------------------

  /// Binds one [HttpServer] serving both planes (§1). Defaults to IPv4
  /// loopback; per §9 the host must serve LAN interfaces only — choosing
  /// which one to bind is the caller's job (see `JamHostEngine.start`), and
  /// [restrictToLanRemotes] enforces the rule per request whichever address
  /// is bound, so a caller that has to bind every interface (one port,
  /// several networks) still cannot serve the internet.
  Future<void> start({InternetAddress? address, int port = 0}) async {
    if (_server != null) throw StateError('JamHostServer already started');
    final configuredDir = uploadDir;
    if (configuredDir == null) {
      _uploadDir = await Directory.systemTemp.createTemp('localjam_upload_');
      _ownsUploadDir = true;
    } else {
      await configuredDir.create(recursive: true);
      _uploadDir = configuredDir;
    }
    try {
      _ownAddresses = [
        for (final iface in await NetworkInterface.list(
          includeLoopback: false,
        ))
          ...iface.addresses,
      ];
    } catch (_) {
      _ownAddresses = const []; // Enumeration refused: see [_ownAddresses].
    }
    final server = await HttpServer.bind(
      address ?? InternetAddress.loopbackIPv4,
      port,
    );
    _server = server;
    server.listen(_handleRequest, cancelOnError: false);
    _livenessTimer = Timer.periodic(
      livenessCheckInterval,
      (_) => _checkLiveness(),
    );
  }

  /// The `localjam://join?...` URI (§1 Discovery) for [iface], which should
  /// be one of the addresses this server is reachable on.
  Uri joinUriFor(InternetAddress iface) => Uri(
    scheme: 'localjam',
    host: 'join',
    queryParameters: {
      'v': '${MessageCodec.protocolVersion}',
      'host': iface.address,
      'port': '$port',
      'token': token,
      'name': sessionName,
    },
  );

  /// Stops timers, closes every guest socket and the server.
  ///
  /// Deliberate shutdown is announced, not inferred (§3.4): every joined
  /// guest is sent `session_ended { reason: host_ended }` first, and the
  /// sockets then close with `normalClosure` rather than `goingAway`. A
  /// guest that receives it leaves at once instead of spending its
  /// host-gone timeout reconnecting to a host that is never coming back —
  /// which is the only thing silence can mean, and the reason a crash still
  /// costs that timeout.
  /// Pass `announce: false` to leave silently — what a crashed or killed
  /// host looks like on the wire, and what the guest-side host-gone timeout
  /// exists for.
  Future<void> close({bool announce = true}) async {
    if (_closed) return;
    if (announce) {
      _broadcast(
        const SessionEndedMessage(reason: SessionEndedReason.hostEnded),
      );
    }
    _closed = true;
    _livenessTimer?.cancel();
    for (final conn in List.of(_conns)) {
      unawaited(
        conn.ws.close(
          announce ? WebSocketStatus.normalClosure : WebSocketStatus.goingAway,
        ),
      );
    }
    _conns.clear();
    _peers.clear();
    await _server?.close(force: true);
    if (_ownsUploadDir) {
      try {
        await _uploadDir?.delete(recursive: true);
      } catch (_) {
        // Best-effort cleanup of the per-instance temp dir.
      }
    }
    await _events.close();
  }

  // --- HTTP routing ----------------------------------------------------------

  Future<void> _handleRequest(HttpRequest req) async {
    try {
      // §9, defense in depth: even when the socket had to be bound on every
      // interface (one port, several networks), nothing off-LAN is served.
      if (!_remoteAllowed(req.connectionInfo?.remoteAddress)) {
        req.response.statusCode = HttpStatus.forbidden;
        req.response.persistentConnection = false;
        await req.response.close();
        return;
      }
      final path = req.uri.path;
      if (path == '/ws') {
        await _handleWsUpgrade(req);
      } else if (path == '/media') {
        await _handleUpload(req);
      } else if (path.startsWith('/media/')) {
        await _serveMedia(req);
      } else if (path.startsWith('/artwork/')) {
        await _serveArtwork(req);
      } else {
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
      }
    } catch (_) {
      try {
        await req.response.close();
      } catch (_) {}
    }
  }

  Future<void> _handleWsUpgrade(HttpRequest req) async {
    if (!WebSocketTransformer.isUpgradeRequest(req)) {
      // §1: /ws is WebSocket-only.
      req.response.statusCode = HttpStatus.upgradeRequired;
      await req.response.close();
      return;
    }
    // The upgrade itself is unauthenticated (the token arrives in `hello`,
    // §3.1), so the two things a pre-hello socket can spend — a socket slot
    // and the LAN's trust — are checked before it exists at all.
    if (!_remoteAllowed(req.connectionInfo?.remoteAddress)) {
      req.response.statusCode = HttpStatus.forbidden;
      await req.response.close();
      return;
    }
    final pending = _conns.where((c) => !c.joined).length;
    if (pending >= maxPendingConnections) {
      req.response.statusCode = HttpStatus.serviceUnavailable;
      await req.response.close();
      return;
    }
    final ws = await WebSocketTransformer.upgrade(req);
    final conn = _GuestConn(ws, nowUs: _nowUs());
    _conns.add(conn);
    ws.listen(
      (data) => _onFrame(conn, data),
      onDone: () => _dropConn(conn),
      onError: (Object _) => _dropConn(conn),
      cancelOnError: true,
    );
  }

  // --- Media plane (§1, §6.2) --------------------------------------------------

  Future<void> _serveMedia(HttpRequest req) async {
    final res = req.response;
    // §6.2: Authorization: Bearer <sessionToken> gates the media plane.
    if (!_bearerMatches(req.headers.value(HttpHeaders.authorizationHeader))) {
      res.statusCode = HttpStatus.unauthorized;
      await res.close();
      return;
    }
    if (req.method != 'GET') {
      res.statusCode = HttpStatus.methodNotAllowed;
      await res.close();
      return;
    }
    final mediaId = req.uri.path.substring('/media/'.length);
    final entry = _isSafeResourceId(mediaId) ? _media[mediaId] : null;
    if (entry == null) {
      res.statusCode = HttpStatus.notFound;
      await res.close();
      return;
    }

    final size = await entry.file.length();
    res.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    try {
      res.headers.contentType = ContentType.parse(entry.item.mime);
    } catch (_) {
      res.headers.contentType = ContentType.binary;
    }

    var start = 0;
    var end = size - 1;
    final rangeHeader = req.headers.value(HttpHeaders.rangeHeader);
    if (rangeHeader != null) {
      final range = _parseRange(rangeHeader, size);
      if (range != null && !range.satisfiable) {
        // RFC 9110 §14: unsatisfiable single range → 416 with the length.
        res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        res.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$size');
        await res.close();
        return;
      }
      if (range != null) {
        start = range.start;
        end = range.end;
        res.statusCode = HttpStatus.partialContent;
        res.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/$size',
        );
      }
      // A syntactically invalid Range header is ignored → full 200 body.
    }
    res.contentLength = end - start + 1;
    await entry.file.openRead(start, end + 1).pipe(res);
  }

  // --- Artwork plane (§6.5) ------------------------------------------------------

  /// Serves `GET /artwork/{artworkId}` (§6.5): bearer-gated like the media
  /// plane, full-body responses only (artwork is small; no Range support).
  Future<void> _serveArtwork(HttpRequest req) async {
    final res = req.response;
    if (!_bearerMatches(req.headers.value(HttpHeaders.authorizationHeader))) {
      res.statusCode = HttpStatus.unauthorized;
      await res.close();
      return;
    }
    if (req.method != 'GET') {
      res.statusCode = HttpStatus.methodNotAllowed;
      await res.close();
      return;
    }
    final artworkId = req.uri.path.substring('/artwork/'.length);
    final entry = _isSafeResourceId(artworkId) ? _artwork[artworkId] : null;
    if (entry == null) {
      res.statusCode = HttpStatus.notFound;
      await res.close();
      return;
    }
    try {
      res.headers.contentType = ContentType.parse(entry.mime);
    } catch (_) {
      res.headers.contentType = ContentType.binary;
    }
    res.contentLength = await entry.file.length();
    await entry.file.openRead().pipe(res);
  }

  /// Registers [bytes] as servable artwork (§6.5) and returns its
  /// content-derived artworkId (`a_` + first 12 hex chars of the sha256).
  /// Idempotent: re-adding the same bytes (every track of an album) returns
  /// the existing id without rewriting. The bytes are stored on disk next to
  /// uploads, so the server must be started.
  Future<String> addArtwork(Uint8List bytes, {required String mime}) async {
    final dir = _uploadDir;
    if (dir == null) throw StateError('JamHostServer is not started');
    final digest = sha256.convert(bytes).toString();
    final artworkId = 'a_${digest.substring(0, 12)}';
    if (_artwork.containsKey(artworkId)) return artworkId;
    final file = File('${dir.path}/$artworkId');
    // Temp + rename so a crash never leaves a partial under the final name.
    final tmp = File('${file.path}.part');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(file.path);
    _artwork[artworkId] = (mime: mime, file: file);
    return artworkId;
  }

  /// The backing file for [artworkId], or null if unknown — the host's own
  /// UI reads artwork from here instead of fetching over HTTP.
  File? artworkFile(String artworkId) => _artwork[artworkId]?.file;

  // --- Guest uploads (§6.4) ------------------------------------------------------

  /// Handles `POST /media`: streams the raw body to disk while hashing
  /// incrementally (never buffering the file in memory), derives the mediaId
  /// from the host-computed sha256 exactly like [describeFile], registers the
  /// item via [addMedia], and answers 201 with the MediaItem JSON — or 200
  /// with the existing item when the content was already uploaded
  /// (idempotency, §6.4).
  Future<void> _handleUpload(HttpRequest req) async {
    final res = req.response;
    // §6.4/§9: Authorization: Bearer <sessionToken> gates uploads too.
    if (!_bearerMatches(req.headers.value(HttpHeaders.authorizationHeader))) {
      res.statusCode = HttpStatus.unauthorized;
      await res.close();
      return;
    }
    if (req.method != 'POST') {
      res.statusCode = HttpStatus.methodNotAllowed;
      await res.close();
      return;
    }

    final MediaKind kind;
    try {
      kind = MediaKind.fromWire(req.headers.value('X-LocalJam-Kind') ?? '');
    } on FormatException {
      res.statusCode = HttpStatus.badRequest;
      await res.close();
      return;
    }
    final String? rawName = req.headers.value('X-LocalJam-Name');
    final String name;
    try {
      // §6.4: the name header is percent-encoded UTF-8.
      name = rawName == null ? 'upload' : Uri.decodeComponent(rawName);
    } on ArgumentError {
      res.statusCode = HttpStatus.badRequest;
      await res.close();
      return;
    }
    final mime =
        req.headers.value('X-LocalJam-Mime') ?? 'application/octet-stream';
    final durationUs = int.tryParse(
      req.headers.value('X-LocalJam-Duration-Us') ?? '',
    );
    final peerId = req.headers.value('X-LocalJam-Peer-Id');

    // §5.6: uploads need addTracks. Attribution rides the peer-id header —
    // spoofable within the session, which §9's honest-guest model accepts;
    // an absent header is judged as a plain guest under the room policy.
    if (!_permissions.allows(peerId ?? '_anonymous', JamCapability.addTracks)) {
      res.statusCode = HttpStatus.forbidden;
      await res.close();
      return;
    }

    // §6.4: the size is decided before a single body byte is read.
    //
    // A body of undeclared length (chunked) cannot be budgeted up front and
    // is the one shape that can only be stopped mid-stream, so it is refused
    // outright: every LocalJam client sends Content-Length, and 411 tells an
    // unknown one exactly what is missing.
    final declared = req.contentLength;
    if (declared < 0) {
      res.persistentConnection = false;
      res.statusCode = HttpStatus.lengthRequired;
      await res.close();
      return;
    }
    if (declared > maxUploadBytes) {
      res.persistentConnection = false;
      res.statusCode = HttpStatus.requestEntityTooLarge;
      await res.close();
      return;
    }
    // Per-file limits bound one upload; these bound the session — a guest
    // that loops just-under-the-cap uploads would otherwise own the host's
    // disk and the queue.
    //
    // Uploads in flight count against both caps. Checking only what has
    // already landed is a check that N simultaneous uploads all pass and
    // then all invalidate: each one read the counters before any of them
    // wrote them, and the session sails past its budget by however many
    // guests uploaded at once.
    if (_playlist.length + _pendingUploads >= maxPlaylistLength ||
        _uploadedBytes + _reservedBytes + declared > uploadBudgetBytes) {
      res.persistentConnection = false;
      res.statusCode = HttpStatus.insufficientStorage;
      await res.close();
      return;
    }

    // Reserved for the whole request and released on every exit — the 200,
    // the 413, an over-long body, and the client that vanishes mid-body
    // (which arrives here as an exception out of the body stream). A stored
    // upload reconciles the reservation to the bytes it actually received.
    _reservedBytes += declared;
    _pendingUploads++;
    try {
      await _receiveUpload(
        req,
        declared: declared,
        kind: kind,
        name: name,
        mime: mime,
        durationUs: durationUs,
        peerId: peerId,
      );
    } finally {
      _reservedBytes -= declared;
      _pendingUploads--;
    }
  }

  /// The body half of [_handleUpload], from the first byte on: streams to
  /// disk while hashing, then stores, registers and answers. Runs inside the
  /// caller's budget reservation of [declared] bytes.
  Future<void> _receiveUpload(
    HttpRequest req, {
    required int declared,
    required MediaKind kind,
    required String name,
    required String mime,
    required int? durationUs,
    required String? peerId,
  }) async {
    final res = req.response;
    final dir = _uploadDir!;
    final tmp = File('${dir.path}/incoming_${_randomHex(8)}.part');
    final digestSink = _DigestSink();
    final hasher = sha256.startChunkedConversion(digestSink);
    final sink = tmp.openWrite();
    var received = 0;
    var overLimit = false;
    var overBudget = false;
    try {
      // Stream to disk while hashing — the file is never held in memory.
      await for (final chunk in req) {
        received += chunk.length;
        // A declared Content-Length is a claim, not a promise: the body is
        // held to both caps again as it arrives.
        if (received > maxUploadBytes) {
          overLimit = true;
          break;
        }
        // A declared Content-Length is a claim: a body that outruns it is
        // spending budget it never reserved (`_reservedBytes` already holds
        // `declared` on this request's behalf, so it is discounted here).
        if (_uploadedBytes + _reservedBytes - declared + received >
            uploadBudgetBytes) {
          overBudget = true;
          break;
        }
        hasher.add(chunk);
        sink.add(chunk);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    hasher.close();

    if (overLimit || overBudget) {
      try {
        await tmp.delete();
      } catch (_) {}
      res.persistentConnection = false;
      res.statusCode = overBudget
          ? HttpStatus.insufficientStorage
          : HttpStatus.requestEntityTooLarge;
      await res.close();
      return;
    }

    final digest = digestSink.value!.toString();
    final mediaId = 'm_${digest.substring(0, 12)}';

    final existing = _media[mediaId];
    if (existing != null) {
      // §6.4 idempotency: the mediaId is content-derived, so an existing id
      // means the same bytes — answer 200 with the existing item, keep its
      // original metadata, and broadcast nothing.
      try {
        await tmp.delete();
      } catch (_) {}
      res.statusCode = HttpStatus.ok;
      res.headers.contentType = ContentType.json;
      res.write(jsonEncode(existing.item.toJson()));
      await res.close();
      return;
    }

    final stored = await tmp.rename('${dir.path}/$mediaId');
    // Only new content spends the budget: an idempotent re-upload returned
    // above without storing anything.
    _uploadedBytes += received;
    // §6.1/§6.5: the host extracts tags + artwork itself — one implementation
    // for uploads and host files, and guests never need a tag parser. The
    // uploader's declared duration wins over the tag value (a decoder probe
    // beats a tag claim); everything is best-effort.
    var tags = const JamAudioTags();
    String? artworkId;
    if (kind == MediaKind.audio) {
      tags = await readAudioTags(stored);
      final artworkBytes = tags.artworkBytes;
      if (tags.hasArtwork) {
        artworkId = await addArtwork(artworkBytes!, mime: tags.artworkMime!);
      }
    }
    final item = MediaItem(
      mediaId: mediaId,
      kind: kind,
      name: name,
      mime: mime,
      sizeBytes: received,
      durationUs: durationUs ?? tags.durationUs,
      sha256: digest,
      title: tags.title,
      artist: tags.artist,
      album: tags.album,
      artworkId: artworkId,
      addedBy: peerId,
    );
    // §6.4: the upload event first, then addMedia's playlist broadcast
    // (which also threads durationUs into the session per §5.5).
    _emit(
      JamHostEvent._(
        JamHostEventKind.mediaUploaded,
        peerId: peerId,
        mediaId: mediaId,
      ),
    );
    addMedia(item, stored);

    res.statusCode = HttpStatus.created;
    res.headers.contentType = ContentType.json;
    res.write(jsonEncode(item.toJson()));
    await res.close();
  }

  /// Parses a single-range `Range` header against a resource of [size] bytes.
  ///
  /// Returns null for a malformed header (caller serves the full body per
  /// RFC 9110), a record with `satisfiable: false` for a well-formed but
  /// unsatisfiable range (caller answers 416), or the resolved byte range.
  static ({int start, int end, bool satisfiable})? _parseRange(
    String header,
    int size,
  ) {
    final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(header.trim());
    if (match == null) return null;
    final rawStart = match.group(1)!;
    final rawEnd = match.group(2)!;
    if (rawStart.isEmpty && rawEnd.isEmpty) return null;
    const unsatisfiable = (start: 0, end: 0, satisfiable: false);
    if (rawStart.isEmpty) {
      // Suffix range: last <rawEnd> bytes.
      final suffix = int.parse(rawEnd);
      if (suffix == 0 || size == 0) return unsatisfiable;
      return (start: max(0, size - suffix), end: size - 1, satisfiable: true);
    }
    final start = int.parse(rawStart);
    final end = rawEnd.isEmpty ? size - 1 : min(int.parse(rawEnd), size - 1);
    if (start >= size || start > end) return unsatisfiable;
    return (start: start, end: end, satisfiable: true);
  }

  // --- Control plane (§3–§6) ---------------------------------------------------

  void _onFrame(_GuestConn conn, Object? data) {
    final receivedUs = _nowUs();
    conn.lastFrameUs = receivedUs;

    // §1: control frames are small JSON. Anything past the cap is not a
    // client we can talk to — refusing the frame but keeping the socket
    // would just invite the next one, so the socket goes. A socket that has
    // not said hello yet is held to the much smaller pre-hello cap.
    final cap = conn.joined ? maxControlFrameBytes : maxPreHelloFrameBytes;
    if (_frameExceeds(data, cap)) {
      unawaited(
        conn.ws.close(WebSocketStatus.policyViolation).catchError((_) {}),
      );
      _dropConn(conn);
      return;
    }

    if (data is! String) return; // v1 control frames are JSON text (§1).

    final DecodedMessage decoded;
    try {
      decoded = _codec.decode(data);
    } on ProtocolException {
      return; // Malformed frame: log-and-ignore territory.
    }

    final message = decoded.message;
    if (!conn.joined) {
      if (message is HelloMessage) _onHello(conn, message);
      return; // Anything else before hello is ignored.
    }
    switch (message) {
      case ClockPingMessage(:final t0):
        // §4: t1 = host receive, t2 = host send, both session-clock µs.
        _sendTo(
          conn.ws,
          ClockPongMessage(t0: t0, t1: receivedUs, t2: _nowUs()),
        );
      case RequestMessage():
        _onRequest(conn, message);
      case MediaStatusMessage():
        _onMediaStatus(conn, message);
      case HelloMessage():
        break; // Already joined; ignore duplicate hello.
      default:
        break; // Unknown/unexpected types are ignored (§2).
    }
  }

  /// Whether [data] is larger than [cap] bytes on the wire.
  ///
  /// For a text frame that means UTF-8 bytes, not `String.length` (UTF-16
  /// code units): a body of three-byte characters is three times its length
  /// and would otherwise sail through a cap it is well over. Encoding every
  /// frame just to measure it would cost what the cap exists to avoid, so
  /// the usual cases are settled by arithmetic — never fewer than 1 byte per
  /// code unit, never more than 3 (a surrogate pair is 2 units and 4 bytes)
  /// — and only the ambiguous middle is measured exactly.
  static bool _frameExceeds(Object? data, int cap) {
    if (data is String) {
      if (data.length > cap) return true;
      if (data.length * 3 <= cap) return false;
      return utf8.encode(data).length > cap;
    }
    if (data is List<int>) return data.length > cap;
    return false;
  }

  void _onHello(_GuestConn conn, HelloMessage hello) {
    if (!_secureEquals(hello.token, token)) {
      _sendTo(conn.ws, const RejectMessage(reason: RejectReason.badToken));
      unawaited(conn.ws.close(WebSocketStatus.policyViolation));
      // A rejected socket is gone: dropping it now frees the pending slot it
      // holds against [maxPendingConnections] immediately, instead of
      // leaving it there until the close handshake finishes or the hello
      // timeout expires — which is how a wrong-token flood would take the
      // room's whole handshake capacity.
      _dropConn(conn);
      return;
    }

    // §3.3, one device is one peer: a client that says hello with a
    // clientId already held by a live socket has come back from the dead
    // (force-quit, killed while backgrounded) faster than the silence
    // timeout could reap the corpse. Without this the rejoining guest is
    // handed a ghost of ITSELF in `welcome.peers`, everyone sees a phantom
    // in the roster, and it lands in the session's history. The old socket
    // goes with no grace slot — the device is right here, on a new one.
    final clientId = hello.clientId;
    conn.clientId = clientId;
    if (clientId != null && clientId.isNotEmpty) {
      for (final other in List.of(_conns)) {
        if (other == conn || other.clientId != clientId) continue;
        final supersededId = other.peerId;
        _dropConn(other, allowResume: false);
        if (supersededId != null) {
          _setPermissions(_permissions.forgetPeer(supersededId));
        }
      }
    }

    // §3.1: a room has a size. A resuming peer (§3.3) competes for a slot
    // like anyone else — its old slot is not reserved, only its identity.
    if (_peers.length >= maxPeers) {
      _sendTo(conn.ws, const RejectMessage(reason: RejectReason.full));
      unawaited(conn.ws.close(WebSocketStatus.policyViolation));
      _dropConn(conn); // As above: free the pending slot with the socket.
      return;
    }

    // §3.3 reconnect: the token, the peerId, AND the stable clientId that
    // held the slot. The token is shared by the whole room and the peerId is
    // public, so those two prove only membership; without the third, a guest
    // that saw a co-host's `peer_left` could echo the id back and inherit the
    // role and overrides the grace window is still holding (§5.6). An
    // unproven resume is not an error — it is simply a fresh join: a new
    // peerId, the room's default role, nothing carried over. A client that
    // sends no clientId (v0.1) can therefore never resume.
    String peerId;
    final resumeId = hello.resumePeerId;
    final slot = resumeId == null ? null : _grace[resumeId];
    final resumes =
        slot != null &&
        slot.untilUs >= _nowUs() &&
        slot.clientId != null &&
        slot.clientId!.isNotEmpty &&
        slot.clientId == clientId &&
        !_peers.containsKey(resumeId);
    if (resumes) {
      peerId = resumeId!;
      _grace.remove(resumeId);
    } else {
      peerId = 'p_${++_peerCounter}';
    }

    final info = PeerInfo(
      peerId: peerId,
      clientName: hello.clientName,
      clientKind: hello.clientKind,
    );
    conn.peerId = peerId;
    conn.info = info;
    _peers[peerId] = conn;
    _session.upsertPeer(peerId);

    // §3.1: welcome carries the full snapshot + playlist + permissions +
    // existing peers.
    _sendTo(
      conn.ws,
      WelcomeMessage(
        sessionId: sessionId,
        sessionName: sessionName,
        selfPeerId: peerId,
        peers: [
          for (final other in _peers.values)
            if (other != conn) other.info!,
        ],
        snapshot: _session.snapshot,
        playlist: playlist,
        permissions: _permissions,
        host: hostPeer,
      ),
    );
    // §3.2: announce to everyone else.
    _broadcast(PeerJoinedMessage(peer: info), except: conn);
    _emit(JamHostEvent._(JamHostEventKind.peerJoined, peer: info));
  }

  void _onRequest(_GuestConn conn, RequestMessage request) {
    // §5.2/§5.6: guests never mutate state; the host validates each request
    // against the peer's effective capabilities and applies or refuses it.
    if (!_requestAllowed(conn.peerId!, request)) {
      _sendTo(
        conn.ws,
        ErrorMessage(
          code: ErrorCode.notAllowed,
          message: 'not allowed: ${request.action.wire}',
        ),
      );
      _emit(
        JamHostEvent._(
          JamHostEventKind.requestDenied,
          peerId: conn.peerId,
          deniedAction: request.action,
        ),
      );
      return;
    }
    try {
      switch (request.action) {
        case RequestAction.play:
          play();
        case RequestAction.pause:
          pause();
        case RequestAction.seek:
          final positionUs = request.positionUs;
          if (positionUs != null) seek(positionUs);
        case RequestAction.setMedia:
          final mediaId = request.mediaId;
          if (mediaId != null) setMedia(mediaId);
        case RequestAction.next:
          next();
        case RequestAction.previous:
          previous();
        case RequestAction.queueMove:
          final mediaId = request.mediaId;
          final toIndex = request.toIndex;
          if (mediaId != null && toIndex != null) {
            moveMediaItem(mediaId, toIndex);
          }
        case RequestAction.queueRemove:
          final mediaId = request.mediaId;
          if (mediaId != null) removeMediaItem(mediaId);
      }
    } on StateError catch (e) {
      _sendTo(
        conn.ws,
        ErrorMessage(code: ErrorCode.internal, message: e.message),
      );
    } on ArgumentError catch (e) {
      _sendTo(
        conn.ws,
        ErrorMessage(code: ErrorCode.mediaGone, message: '${e.message}'),
      );
    }
  }

  /// §5.6 validation: playback actions need [JamCapability.controlPlayback];
  /// queue reorder needs [JamCapability.editQueue]; queue removal needs
  /// editQueue OR ownership (removing your own contribution is always
  /// allowed).
  bool _requestAllowed(String peerId, RequestMessage request) {
    switch (request.action) {
      case RequestAction.play:
      case RequestAction.pause:
      case RequestAction.seek:
      case RequestAction.setMedia:
      case RequestAction.next:
      case RequestAction.previous:
        return _permissions.allows(peerId, JamCapability.controlPlayback);
      case RequestAction.queueMove:
        return _permissions.allows(peerId, JamCapability.editQueue);
      case RequestAction.queueRemove:
        if (_permissions.allows(peerId, JamCapability.editQueue)) return true;
        final mediaId = request.mediaId;
        if (mediaId == null) return true; // No-op either way; let it through.
        final index = _playlist.indexWhere((i) => i.mediaId == mediaId);
        return index >= 0 && _playlist[index].addedBy == peerId;
    }
  }

  void _onMediaStatus(_GuestConn conn, MediaStatusMessage status) {
    // §6.3: track readiness in the session state machine.
    final readiness = switch (status.state) {
      MediaFetchState.none => MediaReadiness.none,
      MediaFetchState.fetching => MediaReadiness.fetching,
      MediaFetchState.ready => MediaReadiness.ready,
    };
    _session.setPeerMediaState(conn.peerId!, status.mediaId, readiness);
    _emit(
      JamHostEvent._(
        JamHostEventKind.peerMediaStatus,
        peerId: conn.peerId,
        mediaId: status.mediaId,
        mediaState: status.state,
        progress: status.progress,
      ),
    );
  }

  // --- Host-initiated controls (§5) --------------------------------------------

  /// Selects [mediaId] and broadcasts the new state (§5.1). The item's
  /// playlist `durationUs` (when set) is threaded into the session so seeks
  /// clamp to it and end of media is detectable (§5.5).
  ///
  /// Throws [ArgumentError] if [mediaId] is not in the media registry.
  void setMedia(String mediaId) {
    final entry = _media[mediaId];
    if (entry == null) {
      throw ArgumentError.value(mediaId, 'mediaId', 'unknown media id');
    }
    _apply(
      (now) => _session.setMedia(
        mediaId,
        nowUs: now,
        durationUs: entry.item.durationUs,
      ),
    );
  }

  /// Starts (or resumes) playback with a scheduled anchor (§5.3).
  void play() => _apply((now) => _session.play(nowUs: now));

  /// Pauses playback, freezing the position (§5.1).
  void pause() => _apply((now) => _session.pause(nowUs: now));

  /// Seeks to [positionUs] (§5.1/§5.3), clamped to the current item's
  /// duration when known (§5.5).
  void seek(int positionUs) =>
      _apply((now) => _session.seek(positionUs, nowUs: now));

  /// Stops playback: back to idle with no media selected (§5.5).
  void stop() => _apply((now) => _session.stop(nowUs: now));

  /// Selects the next playlist item (wrapping) and keeps a playing session
  /// playing; no-op on an empty playlist.
  void next() => _skipTo(1);

  /// Selects the previous playlist item (wrapping) and keeps a playing
  /// session playing; no-op on an empty playlist.
  void previous() => _skipTo(-1);

  /// A manual skip is the same transition as the §5.5 ADVANCE policy and as
  /// removing the current item: select the adjacent track, and if the session
  /// was playing, schedule it from position 0 with a fresh anchor. Selecting
  /// alone would leave the state at `loading` — every follower (the host's own
  /// audio controller included) would pause and sit there, which reads as
  /// "Next stopped the music".
  void _skipTo(int delta) {
    if (_playlist.isEmpty) return;
    final wasPlaying = _session.snapshot.status == PlaybackStatus.playing;
    final index = _playlist.indexWhere(
      (i) => i.mediaId == _session.snapshot.mediaId,
    );
    final target = (index + delta) % _playlist.length;
    setMedia(
      _playlist[target < 0 ? target + _playlist.length : target].mediaId,
    );
    if (wasPlaying) play();
  }

  void _apply(PlaybackSnapshot Function(int nowUs) mutate) {
    final before = _session.snapshot.rev;
    final after = mutate(_nowUs());
    if (after.rev == before) return; // No-op: suppress redundant broadcast.
    _broadcast(StateMessage(snapshot: after));
    _emit(JamHostEvent._(JamHostEventKind.stateBroadcast, snapshot: after));
  }

  // --- Media registry (§6.1) -----------------------------------------------------

  /// Registers (or replaces) a playlist item backed by [file] and broadcasts
  /// the updated playlist (§6.1). The caller precomputes [item] — see
  /// [describeFile].
  void addMedia(MediaItem item, File file) {
    _media[item.mediaId] = (item: item, file: file);
    final index = _playlist.indexWhere((i) => i.mediaId == item.mediaId);
    if (index >= 0) {
      _playlist[index] = item;
    } else {
      _playlist.add(item);
    }
    _broadcastPlaylist();
  }

  /// Moves the playlist item [mediaId] to [toIndex] (clamped) and broadcasts
  /// the reordered playlist (§5.6). Throws [ArgumentError] for an unknown id.
  void moveMediaItem(String mediaId, int toIndex) {
    final from = _playlist.indexWhere((i) => i.mediaId == mediaId);
    if (from < 0) {
      throw ArgumentError.value(mediaId, 'mediaId', 'unknown media id');
    }
    final to = toIndex.clamp(0, _playlist.length - 1);
    if (to == from) return;
    final item = _playlist.removeAt(from);
    _playlist.insert(to, item);
    _broadcastPlaylist();
  }

  /// Removes [mediaId] from the playlist and broadcasts (§5.6). The media
  /// registry keeps serving its bytes (guests may be mid-fetch; re-adding is
  /// instant). Removing the CURRENT item advances to the next remaining item
  /// — resuming playback if it was playing — or stops when the playlist
  /// empties. Throws [ArgumentError] for an id not in the playlist.
  void removeMediaItem(String mediaId) {
    final index = _playlist.indexWhere((i) => i.mediaId == mediaId);
    if (index < 0) {
      throw ArgumentError.value(mediaId, 'mediaId', 'not in the playlist');
    }
    final wasCurrent = _session.snapshot.mediaId == mediaId;
    final wasPlaying = _session.snapshot.status == PlaybackStatus.playing;
    _playlist.removeAt(index);
    _broadcastPlaylist();
    if (!wasCurrent) return;
    if (_playlist.isEmpty) {
      stop();
      return;
    }
    // The item that slid into the removed slot (wrapping at the end) is the
    // natural "next".
    setMedia(_playlist[index % _playlist.length].mediaId);
    if (wasPlaying) play();
  }

  void _broadcastPlaylist() {
    _playlistRev++;
    _broadcast(PlaylistMessage(rev: _playlistRev, items: playlist));
    _emit(
      JamHostEvent._(JamHostEventKind.playlistBroadcast, playlist: playlist),
    );
  }

  // --- Permissions & moderation (§5.6) --------------------------------------

  /// Replaces the guest-role policy and broadcasts the new document.
  void setPolicy(JamPolicy policy) =>
      _setPermissions(_permissions.withPolicy(policy));

  /// Promotes [peerId] to co-host and broadcasts. No-op if already one.
  void promotePeer(String peerId) =>
      _setPermissions(_permissions.promote(peerId));

  /// Demotes [peerId] back to guest and broadcasts. No-op if not a co-host.
  void demotePeer(String peerId) =>
      _setPermissions(_permissions.demote(peerId));

  /// Sets (or clears, with `allowed: null`) one per-peer capability override
  /// and broadcasts.
  void setCapabilityOverride(
    String peerId,
    JamCapability capability, {
    required bool? allowed,
  }) => _setPermissions(
    _permissions.withOverride(peerId, capability, allowed: allowed),
  );

  void _setPermissions(JamPermissions next) {
    if (identical(next, _permissions)) return; // No-op mutation.
    _permissions = next;
    _broadcast(PermissionsMessage(permissions: next));
    _emit(
      JamHostEvent._(JamHostEventKind.permissionsBroadcast, permissions: next),
    );
  }

  /// Builds a [MediaItem] for [file]: computes [MediaItem.sizeBytes] and the
  /// streaming sha256 digest (§6.1). [mediaId] defaults to `m_` + the first
  /// 12 hex chars of the digest (stable across sessions, which is what makes
  /// guest-side caching by sha256 work); [name] defaults to the file name.
  ///
  /// This never probes the file for its duration — duration extraction is
  /// platform-dependent (afinfo, ffprobe, the app's audio engine), so callers
  /// SHOULD supply [durationUs] for audio items (§5.5): without it the host
  /// cannot detect end of media and no [JamEndPolicy] fires.
  static Future<MediaItem> describeFile(
    File file, {
    required MediaKind kind,
    String? mediaId,
    String? name,
    String mime = 'application/octet-stream',
    int? durationUs,
    String? title,
    String? artist,
    String? album,
    String? artworkId,
    String? addedBy,
  }) async {
    final size = await file.length();
    final digest = (await sha256.bind(file.openRead()).first).toString();
    return MediaItem(
      mediaId: mediaId ?? 'm_${digest.substring(0, 12)}',
      kind: kind,
      name: name ?? Uri.file(file.path).pathSegments.last,
      mime: mime,
      sizeBytes: size,
      durationUs: durationUs,
      sha256: digest,
      title: title,
      artist: artist,
      album: album,
      artworkId: artworkId,
      addedBy: addedBy,
    );
  }

  // --- Liveness (§3.3) -----------------------------------------------------------

  void _checkLiveness() {
    final now = _nowUs();
    final silenceUs = silenceTimeout.inMicroseconds;
    final helloUs = helloTimeout.inMicroseconds;
    for (final conn in List.of(_conns)) {
      if (now - conn.lastFrameUs > silenceUs) {
        _dropConn(conn);
        continue;
      }
      // A socket that chatters without ever sending a valid `hello` never
      // goes silent, so silence alone would keep it forever (§3.1).
      if (!conn.joined && now - conn.openedUs > helloUs) _dropConn(conn);
    }
    // A peer whose grace slot expires is gone for good: forget its role and
    // overrides (§5.6) — a later fresh join gets a new peerId anyway.
    final expired = [
      for (final entry in _grace.entries)
        if (entry.value.untilUs < now) entry.key,
    ];
    for (final peerId in expired) {
      _grace.remove(peerId);
      _setPermissions(_permissions.forgetPeer(peerId));
    }
    _checkEndOfMedia(now);
  }

  // --- End of media (§5.5) ---------------------------------------------------

  /// Set once the current track end has been handled; reset as soon as the
  /// session is observed not-ended (new track, seek back, stop). Guards the
  /// periodic check so [JamHostEventKind.mediaEnded] and the policy fire
  /// exactly once per track end.
  bool _endHandled = false;

  void _checkEndOfMedia(int now) {
    if (!_session.hasEnded(now)) {
      _endHandled = false;
      return;
    }
    if (_endHandled) return;
    _endHandled = true;

    final endedId = _session.snapshot.mediaId;
    // §5.5: the end event first, then the policy's resulting state broadcast.
    _emit(JamHostEvent._(JamHostEventKind.mediaEnded, mediaId: endedId));
    switch (endPolicy) {
      case JamEndPolicy.pause:
        pause(); // Positions clamp to the duration: freezes exactly at it.
      case JamEndPolicy.advance:
        final next = _nextMediaId(endedId);
        if (next == null) {
          pause(); // Empty playlist: nothing to advance to.
        } else {
          setMedia(next);
          play();
        }
      case JamEndPolicy.stop:
        stop();
    }
  }

  /// The playlist item after [current], wrapping; null if the playlist is
  /// empty. An unknown [current] yields the first item.
  String? _nextMediaId(String? current) {
    if (_playlist.isEmpty) return null;
    final index = _playlist.indexWhere((i) => i.mediaId == current);
    return _playlist[(index + 1) % _playlist.length].mediaId;
  }

  /// Disconnects [peerId] (host moderation, §5.6).
  ///
  /// By default this is a real kick: the guest first gets a fatal
  /// `error {code: kicked}` — so it knows the removal was deliberate and
  /// must not auto-rejoin — then its socket closes with `goingAway`,
  /// `peer_left` is broadcast (§3.2), no §3.3 grace slot is kept, and the
  /// peer's role and overrides are forgotten.
  ///
  /// With `allowResume: true` this is instead a plain forced disconnect —
  /// exactly like a silence drop: no error is sent, the grace slot is kept,
  /// and a reconnecting guest reclaims the same peerId (and role).
  ///
  /// Throws [ArgumentError] if [peerId] is not a currently joined peer.
  void kickPeer(String peerId, {bool allowResume = false}) {
    final conn = _peers[peerId];
    if (conn == null) {
      throw ArgumentError.value(peerId, 'peerId', 'not a joined peer');
    }
    if (!allowResume) {
      _sendTo(
        conn.ws,
        const ErrorMessage(
          code: ErrorCode.kicked,
          message: 'removed from the session by the host',
          fatal: true,
        ),
      );
    }
    _dropConn(conn, allowResume: allowResume);
    if (!allowResume) _setPermissions(_permissions.forgetPeer(peerId));
  }

  void _dropConn(_GuestConn conn, {bool allowResume = true}) {
    if (!_conns.remove(conn)) return; // Already dropped.
    unawaited(conn.ws.close(WebSocketStatus.goingAway).catchError((_) {}));
    final peerId = conn.peerId;
    if (peerId == null || _closed) return;
    _peers.remove(peerId);
    _session.removePeer(peerId);
    if (allowResume) {
      // §3.3: keep a grace slot so the guest can resume with the same peerId
      // — the device that held it, and no one else: the slot records the
      // clientId a resume has to present.
      _grace[peerId] = (
        untilUs: _nowUs() + reconnectGrace.inMicroseconds,
        clientId: conn.clientId,
      );
    }
    _broadcast(PeerLeftMessage(peerId: peerId));
    _emit(JamHostEvent._(JamHostEventKind.peerLeft, peerId: peerId));
  }

  // --- Wire helpers ----------------------------------------------------------------

  void _sendTo(WebSocket ws, Message message) {
    _safeAdd(ws, _codec.encode(message, seq: _seq++));
  }

  void _broadcast(Message message, {_GuestConn? except}) {
    final encoded = _codec.encode(message, seq: _seq++);
    for (final conn in _peers.values) {
      if (conn == except) continue;
      _safeAdd(conn.ws, encoded);
    }
  }

  /// Adds a frame, swallowing the race where the socket's close handshake
  /// began between frame receipt and the reply (liveness will reap the conn).
  static void _safeAdd(WebSocket ws, String frame) {
    if (ws.readyState != WebSocket.open) return;
    try {
      ws.add(frame);
    } on StateError {
      // Sink closed underneath us: the peer is going away.
    }
  }

  void _emit(JamHostEvent event) {
    if (!_events.isClosed) _events.add(event);
  }
}

/// Terminal sink for one chunked sha256 conversion (avoids a package:convert
/// dependency for `AccumulatorSink`).
class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
