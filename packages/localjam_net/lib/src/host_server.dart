/// LocalJam host: serves the control plane (WebSocket `/ws`), the media
/// plane (HTTP `/media/{mediaId}`, and the catalog's `/catalog`, §6.6) and
/// the web guest's page (`/`, `/join`, `/web/…`, §1.1) on one TCP port
/// (PROTOCOL.md §1), and drives a [HostSession] as the single authoritative
/// state writer (§5).
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:localjam_core/localjam_core.dart';
import 'package:meta/meta.dart';

import 'catalog_provider.dart';
import 'connection_guard.dart';
import 'media_metadata.dart';
import 'monotonic.dart';
import 'static_site.dart';

export 'catalog_provider.dart';
export 'static_site.dart';

/// What a [JamHostServer] does when the current item reaches its end
/// (PROTOCOL.md §5.5). End of media is only detectable for items whose
/// playlist entry carries a `durationUs`; without one the anchor extrapolates
/// and no policy fires. Guests see only the ordinary state broadcasts the
/// policy produces — no protocol change.
enum JamEndPolicy {
  /// Pause, frozen at exactly the item's duration (the default).
  pause,

  /// Select the next playlist item (wrapping at the end of the playlist)
  /// and, if the room was playing, immediately schedule playback. A room
  /// that reaches the end while paused (a seek to the end) moves on but
  /// stays stopped, at the start of the next item.
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
  /// [JamHostEvent.mediaId] and [JamHostEvent.peerId] set — the peer the
  /// item is credited to: the one whose upload key the request presented,
  /// or the peerId that device rejoined under while the body was still
  /// arriving, §5.6). Emitted before the playlist broadcast the upload
  /// produces. Idempotent re-uploads of content still in the queue do not
  /// fire; re-uploading an item that was removed puts it back, and does.
  mediaUploaded,

  /// A catalog add landed (§6.6): an entry of the host's catalog became a
  /// playlist item ([JamHostEvent.peerId] — who it is credited to: the
  /// requesting guest's peerId, or [JamPermissions.hostPeerId] for
  /// [JamHostServer.addFromCatalog] — [JamHostEvent.mediaId] and
  /// [JamHostEvent.catalogId] set). Emitted before the playlist broadcast
  /// the add produces. An add whose content was already in the queue does
  /// not fire; one that put removed content back in does.
  catalogAdded,

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
    this.catalogId,
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

  /// The catalog entry that was added. Set for
  /// [JamHostEventKind.catalogAdded].
  final String? catalogId;

  @override
  String toString() =>
      'JamHostEvent(${kind.name}'
      '${peerId != null ? ', peerId: $peerId' : ''}'
      '${mediaId != null ? ', mediaId: $mediaId' : ''})';
}

/// One connected (or connecting) guest socket.
class _GuestConn {
  _GuestConn(this.ws, {required int nowUs, this.socket})
    : lastFrameUs = nowUs,
      openedUs = nowUs;

  final WebSocket ws;

  /// The connection under [ws], holding it to its pre-hello byte budget
  /// until a valid `hello` (§9.1). Null only if the connection was already
  /// gone when the upgrade finished.
  final GuardedSocket? socket;

  /// Assigned after a valid `hello`; null while the handshake is pending.
  String? peerId;
  PeerInfo? info;

  /// The stable per-device id this socket said hello with (§3.3), when it
  /// sent one. Two live sockets never share it: the newer supersedes the
  /// older, so one device is one peer.
  String? clientId;

  /// [clientId] when it can recognise the device (§3.3), else null: a
  /// socket that sent none, or an empty one, is no device in particular.
  String? get device {
    final id = clientId;
    return id == null || id.isEmpty ? null : id;
  }

  /// This peer's upload credential (§6.4), issued in its `welcome`. Uploads
  /// are accepted — and permission-checked as — the peer whose key they
  /// present, only while that peer is joined when the request arrives; they
  /// land only while it is still in the room when the body has arrived
  /// (joined, or dropped and inside its §3.3 grace window), and are
  /// credited to its device (§5.6).
  String? uploadKey;

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
  /// "honest" should not mean "unbounded"; §9.1 has the table):
  /// [maxConnections] and [maxConnectionsPerRemote] cap open TCP connections
  /// of every kind, [maxRequestHeaderBytes] caps a request's header block,
  /// [maxPeers] and [maxPendingConnections] cap joined and half-open
  /// sockets, [maxControlFrameBytes] caps one control frame from a joined
  /// peer and [maxPreHelloFrameBytes] what a socket may send before it has
  /// said hello, [helloTimeout] drops connections that never authenticate
  /// (and requests whose headers never finish), and [restrictToLanRemotes]
  /// enforces §9's "LAN interfaces only" per connection and per request.
  /// [uploadStallTimeout], [minUploadBytesPerSecond] and [maxUploadsPerPeer]
  /// bound how long and how many uploads may hold their reservations
  /// (§6.4). [maxArtworkBytes] caps the cover art the host will extract
  /// from an upload and serve, and bounds what reading an upload's tags may
  /// cost at all. [minPageSendTime] and [minPageBytesPerSecond] set the
  /// deadline by which a page response (§1.1) must have been sent.
  ///
  /// [readinessWait] is the §6.3 readiness gate: how long starting a newly
  /// selected track may wait for guests that are mid-transfer of it (zero
  /// disables the gate).
  ///
  /// [staticSite] is the browser player served to web guests (§1.1); see
  /// [staticSite] — it can also be set (or replaced) after [start].
  ///
  /// The catalog (§6.6, [setCatalog]) is bounded by
  /// [maxCatalogIdsPerRequest] (ids past it in one `catalog_add` are
  /// dropped), [maxPendingCatalogAdds] (adds waiting across all guests;
  /// past it a request is answered `busy`), [maxPendingCatalogAddsPerPeer]
  /// (the same, for one guest's device) and [catalogCoverCacheSize]
  /// (covers kept in memory for `GET /catalog/{id}/artwork`).
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
    this.maxInboundBytesPerSecond = defaultMaxInboundBytesPerSecond,
    this.maxInboundFramesPerSecond = defaultMaxInboundFramesPerSecond,
    this.maxPreHelloFrameBytes = 16 * 1024,
    this.helloTimeout = const Duration(seconds: 10),
    this.restrictToLanRemotes = true,
    this.maxArtworkBytes = defaultMaxArtworkBytes,
    this.readinessWait = const Duration(milliseconds: 2500),
    this.maxConnections = defaultMaxConnections,
    this.maxConnectionsPerRemote = defaultMaxConnectionsPerRemote,
    this.maxRequestHeaderBytes = 16 * 1024,
    this.uploadStallTimeout = const Duration(seconds: 30),
    this.minUploadBytesPerSecond = 32 * 1024,
    this.maxUploadsPerPeer = 2,
    this.minPageSendTime = const Duration(seconds: 10),
    this.minPageBytesPerSecond = 32 * 1024,
    this.admitLocalAddress,
    this.staticSite,
    this.maxCatalogIdsPerRequest = defaultMaxCatalogIdsPerRequest,
    this.maxPendingCatalogAdds = defaultMaxPendingCatalogAdds,
    this.maxPendingCatalogAddsPerPeer = defaultMaxPendingCatalogAddsPerPeer,
    this.catalogCoverCacheSize = defaultCatalogCoverCacheSize,
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
  static const int defaultMaxArtworkBytes = 8 * 1024 * 1024;
  static const int defaultMaxConnections = 128;
  static const int defaultMaxConnectionsPerRemote = 32;
  static const int defaultMaxCatalogIdsPerRequest = 50;
  static const int defaultMaxPendingCatalogAdds = 128;
  static const int defaultMaxInboundBytesPerSecond = 256 * 1024;
  static const int defaultMaxInboundFramesPerSecond = 100;

  /// One device's share of [defaultMaxPendingCatalogAdds]: a full
  /// [defaultMaxCatalogIdsPerRequest] selection fits whole.
  static const int defaultMaxPendingCatalogAddsPerPeer = 50;
  static const int defaultCatalogCoverCacheSize = 64;

  /// The most cover bytes the catalog's cover cache holds at once, whatever
  /// [catalogCoverCacheSize] says: 64 covers at the 8 MB cap would be half
  /// a gigabyte of a phone's memory.
  static const int catalogCoverCacheBytes = 32 * 1024 * 1024;

  /// How many catalog covers (§6.6) the host reads from their files at
  /// once; further requests wait their turn, up to
  /// [catalogCoverReadsWaiting] of them, and past that are answered `503`.
  static const int catalogCoverReadsAtOnce = 3;

  /// How many catalog cover reads may wait for one of the
  /// [catalogCoverReadsAtOnce] slots before the host answers `503`.
  static const int catalogCoverReadsWaiting = 16;

  /// The longest `X-LocalJam-Duration-Us` an upload may declare (§6.4): a
  /// week. Anything longer — or zero, or negative — is not a duration any
  /// file has, so it is treated as unknown rather than trusted.
  static const int maxPlausibleDurationUs = 7 * 24 * 60 * 60 * 1000000;

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

  /// Upper bound on one control message from a joined peer (§1, §9.1),
  /// counted in UTF-8 bytes and summed over its WebSocket fragments.
  ///
  /// `dart:io`'s WebSocket has no maximum-message option and reassembles a
  /// message completely before handing it over, so the cap is enforced on
  /// the raw stream instead: the connection guard reads each frame header
  /// as it arrives and closes the socket with `policyViolation` (1008) the
  /// moment a message declares more — before its payload is received, let
  /// alone buffered. Holding the token does not exempt a peer: discoverable
  /// rooms hand it to every LAN neighbour that asks.
  final int maxControlFrameBytes;

  /// The average rate, in raw bytes per second, at which a joined peer's
  /// control socket may send (§9.1), with bursts of four seconds' worth;
  /// past it the socket is closed with `policyViolation`. An honest guest
  /// sends a few hundred bytes a second at most — pings, the odd request —
  /// so the default of 256 KB/s (1 MB bursts, four maximum-size messages)
  /// only ever meets a flood. Null disables it.
  final int? maxInboundBytesPerSecond;

  /// The average rate, in WebSocket frames per second (control frames such
  /// as pings included), at which a joined peer's control socket may send
  /// (§9.1), with bursts of four seconds' worth; past it the socket is
  /// closed with `policyViolation`. An honest guest sends one ping every
  /// two seconds, a burst of eight on (re)join, and a frame per tap; the
  /// default of 100/s bounds the cost of a flood of tiny frames — each a
  /// parse, and a WebSocket ping a pong the host must queue — that the
  /// byte rate alone would let through. Null disables it.
  final int? maxInboundFramesPerSecond;

  /// Upper bound on what a control socket may send before it completes the
  /// §3.1 handshake (default 16 KB): the cap on one pre-hello frame, and —
  /// counted in raw bytes as they arrive, before `dart:io` reassembles
  /// anything — on everything the socket sends until its `hello` is
  /// accepted (plus [_preHelloFramingSlack] for WebSocket framing).
  ///
  /// A `hello` is a few hundred bytes — a token, a name, two short ids — so
  /// an unauthenticated socket has no honest reason to send anything near
  /// this, and one that does loses the socket instead of getting the host's
  /// memory.
  final int maxPreHelloFrameBytes;

  /// How long a connection may go without proving the token before it is
  /// dropped: a control socket without a valid `hello` (§3.1), and any
  /// connection whose request headers have not all arrived. Unauthenticated
  /// connections are the cheapest thing on the LAN to open and the least
  /// entitled to stay.
  final Duration helloTimeout;

  /// Upper bound on open TCP connections of every kind — control sockets,
  /// media and artwork transfers, uploads, and connections nobody has
  /// authenticated yet (§9.1, default [defaultMaxConnections]). Over-cap
  /// connections are answered `503` and closed before a byte of them is
  /// parsed. Together with [maxRequestHeaderBytes] and
  /// [maxPreHelloFrameBytes] this is what bounds the memory unauthenticated
  /// connections can hold.
  ///
  /// It is also what keeps the process inside its file-descriptor limit,
  /// which Dart cannot read: Apple platforms start an app at a soft limit
  /// of 256, a connection is one descriptor and a transfer holds a second
  /// (the file) while it runs, and the app needs its own. The default of
  /// 128 leaves that room; an embedder that raises `RLIMIT_NOFILE` natively
  /// (`setrlimit` at launch) can raise this with it. At the limit, `accept`
  /// fails and the host is unreachable to everyone — a cap only refuses
  /// the newest connections.
  final int maxConnections;

  /// Upper bound on open TCP connections from one remote address (§9.1,
  /// default [defaultMaxConnectionsPerRemote]), so one neighbour cannot take
  /// every [maxConnections] slot. A guest needs a handful: its control
  /// socket, a media fetch, an artwork fetch, an upload.
  final int maxConnectionsPerRemote;

  /// Upper bound on a request's request line plus headers, in bytes (§9.1,
  /// default 16 KB; a LocalJam client sends a few hundred). Counted as they
  /// arrive — `dart:io` buffers a header block whole, at eight bytes of
  /// memory per byte, up to its own limit of 1 MiB — and a connection that
  /// passes it is destroyed.
  final int maxRequestHeaderBytes;

  /// An upload is abandoned (`408`, reservation released, partial file
  /// deleted) when, over any window this long, its body delivers less than
  /// [minUploadBytesPerSecond] × the window — or nothing at all (§6.4).
  /// Without it a client that declares 512 MB and then goes quiet, or
  /// trickles a byte at a time, holds that much of [uploadBudgetBytes] and
  /// a playlist slot forever.
  final Duration uploadStallTimeout;

  /// The slowest average an upload may sustain over each
  /// [uploadStallTimeout] window (default 32 KB/s — a quarter of a 1 Mbit/s
  /// link). A body that has less than that left to send owes only what is
  /// left; zero means only total silence counts as a stall.
  final int minUploadBytesPerSecond;

  /// Upper bound on uploads one peer may have in flight at once (§6.4,
  /// default 2). Further uploads are answered `429` until one finishes.
  final int maxUploadsPerPeer;

  /// The least time a page response (§1.1) is given to be sent: a response
  /// of `n` bytes has `max(minPageSendTime, n ÷ minPageBytesPerSecond)`,
  /// and a connection still sending at its deadline is destroyed (§9.1).
  /// The page routes need no token, so without it any LAN device could ask
  /// for the biggest bundle file, read none of it, and hold a connection
  /// slot for as long as it liked — a handful of addresses, every slot
  /// (review 2026-10-21: six such sockets held a per-remote cap of six for
  /// as long as the test ran). Default 10 s.
  final Duration minPageSendTime;

  /// The slowest a page response may be read (default 32 KB/s, the same
  /// floor as [minUploadBytesPerSecond]); see [minPageSendTime].
  final int minPageBytesPerSecond;

  /// Whether a connection that arrived on the host's local address `local`
  /// may be served (§9). Null — the default — serves every interface the
  /// listener is bound to.
  ///
  /// The remote filter ([restrictToLanRemotes]) cannot tell a neighbour on
  /// the Wi-Fi from a stranger on the carrier's network: carriers hand out
  /// RFC1918 addresses too. A host bound to the wildcard address — so a
  /// hotspot that comes up later is served — also listens on its cellular
  /// and tunnel interfaces, and an embedder that knows which local
  /// addresses those are passes a predicate refusing them. Refused
  /// connections are answered `403` before a byte of them is parsed.
  /// Called once per connection: it must be synchronous and cheap (a
  /// lookup in a set the embedder refreshes as interfaces change).
  final bool Function(InternetAddress local)? admitLocalAddress;

  /// The web guest's page and its bundle (§1.1), served from memory and
  /// without a token: `GET /` and `GET /join` answer with its `index.html`,
  /// `GET /web/<path>` with the file keyed exactly `<path>`. Null (or a site
  /// without `index.html`) serves [builtInNoPlayerPage] at `/` and `/join`
  /// and `404` under `/web/`.
  ///
  /// Settable at any time — an embedder that loads its bundle in the
  /// background can start the room first. A request already being answered
  /// keeps the site it started with.
  StaticSite? staticSite;

  /// Whether requests from non-LAN remote addresses are refused with 403
  /// (§9: off-LAN remotes are refused on both planes). Binding a single LAN
  /// interface is not always possible (a phone on Wi-Fi AND a hotspot needs
  /// one port on several interfaces), so the address filter is the enforced
  /// half of the rule and applies on both planes. Loopback always passes —
  /// tests, the CLI and the host's own UI live there.
  final bool restrictToLanRemotes;

  /// Upper bound on embedded cover art taken from a guest upload (§6.5).
  /// Larger art is dropped — the track still plays, it just has no cover —
  /// so one upload cannot make the host store and serve an arbitrarily large
  /// "image". Matches the guest-side cap (`JamGuestClient.maxArtworkBytes`).
  final int maxArtworkBytes;

  /// The §6.3 readiness gate. When [play] starts a freshly selected track
  /// (the session is `loading`) while some joined guest is mid-transfer of
  /// it — its latest `media_status` for the item is `fetching` — the start
  /// is held for up to this long, and released early the moment no guest is
  /// fetching it any more (each finished, gave up, or left). Guests that
  /// never reported, reported `none`, or already hold the file are never
  /// waited for, so a stalled or broken guest costs the room at most this
  /// wait, once per track. Stragglers late-join per §5.3. [Duration.zero]
  /// disables the gate.
  final Duration readinessWait;

  /// The most catalog ids one `catalog_add` request may carry (§6.6); the
  /// rest are dropped.
  final int maxCatalogIdsPerRequest;

  /// The most catalog adds waiting to land across all guests (§6.6, §9.1).
  /// A request that would go past it is answered `error { code: "busy" }`
  /// for the ids that did not fit.
  final int maxPendingCatalogAdds;

  /// The most catalog adds waiting to land for one guest (§6.6, §9.1) —
  /// counted by its device, so across its rejoins; past it that guest's
  /// request is answered `busy`, whatever room [maxPendingCatalogAdds]
  /// leaves.
  final int maxPendingCatalogAddsPerPeer;

  /// How many catalog covers (§6.6) the host keeps in memory, most recently
  /// served first; see also [catalogCoverCacheBytes].
  final int catalogCoverCacheSize;

  final HostSession _session;
  JamPermissions _permissions;
  static const MessageCodec _codec = MessageCodec();

  /// WebSocket framing a pre-hello socket may send on top of
  /// [maxPreHelloFrameBytes]: a frame header is at most 14 bytes, so this
  /// covers a hello split into many frames and nothing that matters.
  static const int _preHelloFramingSlack = 1024;

  /// How late an upload's stall check may run and still judge its window
  /// (§6.4). Later than this, the host itself was not running — and not
  /// reading what the client sent — so the window is extended instead.
  static const int _stallCheckSlackUs = 100 * 1000;

  HttpServer? _server;

  /// The listening socket under [_server]. `HttpServer.listenOn` never
  /// closes the socket it was given, so [close], [restartListener] and
  /// [debugKillListener] do.
  ServerSocket? _listener;

  /// Admission and pre-authentication byte accounting for every connection
  /// [_listener] accepts (§9.1). Created in [start]; survives
  /// [restartListener], so connections that outlive a listener stay counted.
  ConnectionGuard? _guard;

  /// A [restartListener] in progress, which concurrent callers share.
  Future<void>? _restarting;

  Timer? _livenessTimer;

  /// The resolved upload directory (§6.4), set in [start].
  Directory? _uploadDir;

  /// Whether [_uploadDir] was created by this instance (and so is deleted on
  /// [close]).
  bool _ownsUploadDir = false;

  /// Held for the lifetime of an owned [_uploadDir]: an exclusive lock on its
  /// lock file, which is how a later host start tells a live room's
  /// directory from one a killed process leaked (see [sweepStaleUploadDirs]).
  RandomAccessFile? _uploadDirLock;

  /// Completes when the current listening socket stops (see
  /// [listenerDone]); replaced by [restartListener].
  Completer<Object?> _listenerDone = Completer<Object?>();

  /// Whether the host has announced it is away (§3.5).
  bool _away = false;

  /// A [play] held by the §6.3 readiness gate (see [readinessWait]).
  Timer? _pendingStart;

  /// When [_checkLiveness] last ran, to notice the host's OWN naps (see
  /// [_checkLiveness]).
  int? _lastLivenessTickUs;

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

  /// Uploads in flight per uploading peerId, against [maxUploadsPerPeer].
  final Map<String, int> _uploadsInFlight = {};

  // --- Catalog (§6.6) ---

  /// Where the catalog's songs come from; null while the host offers none.
  JamCatalogProvider? _catalogProvider;

  /// The entries [_catalogProvider] gave at the last [setCatalog], in order
  /// and by id.
  List<CatalogEntry> _catalogList = const [];
  Map<String, CatalogEntry> _catalogById = const {};

  /// The catalog's `rev` (§6.6): bumped by every [setCatalog] that changes
  /// anything, on or off.
  int _catalogRev = 0;

  /// Bumped whenever the provider itself changes (or goes): adds queued for
  /// an earlier provider, and covers read from it, are not this one's.
  int _catalogGeneration = 0;

  /// `GET /catalog`'s body for the current rev, encoded on first request.
  Uint8List? _catalogBody;

  /// Catalog adds waiting to land, in arrival order; one lands at a time.
  final Queue<_CatalogAdd> _catalogQueue = Queue<_CatalogAdd>();
  bool _catalogDraining = false;

  /// Guest catalog adds queued or landing, against [maxPendingCatalogAdds]
  /// — and, like uploads in flight, against [maxPlaylistLength].
  int _catalogPending = 0;

  /// The same, per guest device (see [_catalogPeerKey]), against
  /// [maxPendingCatalogAddsPerPeer].
  final Map<Object, int> _catalogPendingByPeer = {};

  /// Ids of guest catalog adds queued or landing under the current
  /// generation: a second request for one is a no-op, not a second hash.
  final Set<String> _catalogQueuedIds = {};

  /// catalogId → the mediaId its file hashed to, under the current
  /// generation: an id whose content is already in the queue is a no-op
  /// without opening or hashing it again.
  final Map<String, String> _catalogMediaIds = {};

  /// Catalog cover reads under way, against [catalogCoverReadsAtOnce], and
  /// those waiting for a slot, against [catalogCoverReadsWaiting].
  int _coverReadsActive = 0;
  final Queue<Completer<void>> _coverReadTurns = Queue<Completer<void>>();

  /// Names staged catalog covers apart (see [_stageArtwork]).
  int _stagedArtworkSeq = 0;

  /// Recently served catalog covers, least recently used first. A null
  /// value remembers a song without one, so its file is not read again.
  final LinkedHashMap<String, _CatalogCover?> _coverCache =
      LinkedHashMap<String, _CatalogCover?>();
  int _coverCacheBytes = 0;

  /// Cover reads under way, so concurrent requests for one song share one.
  final Map<String, Future<_CatalogCover?>> _coverLoads = {};

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
  /// gets it back. A null clientId is never resumable.
  final Map<String, ({int untilUs, String? clientId})> _grace = {};

  /// Media registry (§6.1): mediaId → the item, its backing file, and where
  /// both came from. Never pruned during a session — a removed item's bytes
  /// stay servable (see [removeMediaItem]).
  final Map<String, _MediaEntry> _media = {};
  final List<MediaItem> _playlist = [];

  /// Artwork registry (§6.5): artworkId → (mime, backing file). Artwork ids
  /// are content-derived, so items sharing cover bytes share one entry.
  final Map<String, ({String mime, File file})> _artwork = {};

  /// Moderation that outlives a peerId (§5.6), keyed by the stable
  /// `hello.clientId`: a co-host whose phone napped past the grace window, or
  /// a muted guest who rejoins from scratch, comes back as what the host
  /// made them — not as a fresh guest with a clean slate. Kept for the whole
  /// session; never broadcast (clientIds never leave the host).
  final Map<String, _ClientModeration> _moderation = {};

  /// Devices kicked this session (§5.6), by clientId, with the identity they
  /// had when kicked — so the host UI can list them and [unkickPeer] them.
  final Map<String, PeerInfo> _kicked = {};

  final StreamController<JamHostEvent> _events =
      StreamController<JamHostEvent>.broadcast();

  /// Observability events (peer joined/left, media status, broadcasts).
  Stream<JamHostEvent> get events => _events.stream;

  /// The bound port. Throws [StateError] before [start]; stays readable
  /// after [close].
  int get port {
    final bound = _bound;
    if (bound == null) throw StateError('JamHostServer is not started');
    return bound.port;
  }

  /// What [start] bound, kept so [port] and [selfProbe] still work once the
  /// listener is gone (a closed [HttpServer] no longer reports either).
  ({InternetAddress address, int port})? _bound;

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

  /// Whether a [play] is currently held by the §6.3 readiness gate — the
  /// session is `loading` and will start on its own within [readinessWait].
  bool get isAwaitingReadiness => _pendingStart != null;

  /// Whether the host has announced it is away (§3.5, [announceAway]).
  bool get isAway => _away;

  /// Devices kicked this session and not yet let back in (§5.6), as they
  /// were known when kicked (their peerId then, and display name). A kicked
  /// device's `hello` is answered `reject { reason: "kicked" }`.
  List<PeerInfo> get kickedPeers => List.unmodifiable(_kicked.values);

  /// Whether kicking [peerId] would keep its device out for the rest of the
  /// session (§5.6): true when that joined peer's `hello` carried a
  /// `clientId`, which is what a later `hello` is refused by. A device that
  /// sent none cannot be recognised when it comes back — not by its name,
  /// which anyone can share, nor by its address, which a NAT or a hotspot
  /// shares between phones — so for it a kick is only a removal. False for
  /// a peerId that is not joined.
  bool kickKeepsOut(String peerId) {
    final clientId = _peers[peerId]?.clientId;
    return clientId != null && clientId.isNotEmpty;
  }

  /// [kickedPeers] after every change to it — a kick ([kickPeer] without
  /// `allowResume`) or an [unkickPeer] that let someone back — whoever made
  /// it, so a host UI listing the kicked stays right when another layer
  /// (or a test) kicks on the server directly.
  Stream<List<PeerInfo>> get kickedPeersChanges => _kickedChanges.stream;

  final StreamController<List<PeerInfo>> _kickedChanges =
      StreamController<List<PeerInfo>>.broadcast();

  void _emitKickedChanged() {
    if (!_kickedChanges.isClosed) _kickedChanges.add(kickedPeers);
  }

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
    return remote != null && isLanAddress(remote, hostAddresses: _ownAddresses);
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
      !id.contains('\u0000');

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
  ///
  /// With no [uploadDir], the per-instance temp directory is created under
  /// the system temp dir and locked for the server's lifetime, and any
  /// directories earlier hosts leaked there (a process killed mid-session
  /// never reaches [close]) are swept in the background — see
  /// [sweepStaleUploadDirs].
  Future<void> start({InternetAddress? address, int port = 0}) async {
    if (_server != null) throw StateError('JamHostServer already started');
    final configuredDir = uploadDir;
    if (configuredDir == null) {
      final dir = await Directory.systemTemp.createTemp(_uploadDirPrefix);
      _uploadDir = dir;
      _ownsUploadDir = true;
      _uploadDirLock = await _lockUploadDir(dir);
      unawaited(sweepStaleUploadDirs());
    } else {
      await configuredDir.create(recursive: true);
      _uploadDir = configuredDir;
    }
    await _refreshOwnAddresses();
    _guard = ConnectionGuard(
      maxConnections: maxConnections,
      maxConnectionsPerRemote: maxConnectionsPerRemote,
      maxHeaderBytes: maxRequestHeaderBytes,
      headerTimeout: helloTimeout,
      admitRemote: _remoteAllowed,
      admitLocal: admitLocalAddress,
    );
    final listener = await ServerSocket.bind(
      address ?? InternetAddress.loopbackIPv4,
      port,
    );
    _bound = (address: listener.address, port: listener.port);
    _listen(listener);
    _lastLivenessTickUs = _nowUs();
    _livenessTimer = Timer.periodic(
      livenessCheckInterval,
      (_) => _checkLiveness(),
    );
  }

  // --- Listener health ---------------------------------------------------------

  /// Serves both planes on [listener], every connection admitted through
  /// [_guard] first (§9.1).
  void _listen(ServerSocket listener) {
    final server = HttpServer.listenOn(_guard!.wrap(listener));
    _listener = listener;
    _server = server;
    final done = _listenerDone;
    server.listen(
      _handleRequest,
      onError: (Object error) => _onListenerError(done, error),
      onDone: () => _onListenerDone(done),
      cancelOnError: false,
    );
  }

  /// Completes when the listening socket stops accepting connections: with
  /// null after a deliberate [close], or with the error (a [StateError] when
  /// the platform simply ended the listener) when it died underneath a live
  /// room — e.g. iOS reclaiming a suspended app's listening socket. Joined
  /// guests keep their own sockets, but nobody new can join or reconnect, so
  /// a host UI that still shows the room as open is lying: it should
  /// [restartListener] (or say so). Never completes with an error. After a
  /// [restartListener] this is the NEW listener's future.
  Future<Object?> get listenerDone => _listenerDone.future;

  /// Re-opens the listening socket on the same address and port after it
  /// died ([listenerDone] completed with an error, or [selfProbe] said so) —
  /// without ending the room. The session, playlist, permissions and token
  /// are untouched, joined guests keep their sockets, and the join link the
  /// room handed out stays valid, so guests that dropped meanwhile simply
  /// reconnect and resume (§3.3). Throws (a [SocketException]) if the port
  /// cannot be bound again — another app took it — in which case only a new
  /// room will do.
  ///
  /// With [address], the room moves to that address instead — e.g. a room
  /// that started with no LAN, on loopback, rebinding once Wi-Fi or a
  /// hotspot comes up. Same session, same token, and the same port when it
  /// is free there; joined guests keep their sockets. A failed move leaves
  /// the room listening where it was. The port changes only when
  /// [allowNewPort] is true and the old one cannot be had: then [port] (and
  /// so [joinUriFor]) reports the new one, every link and QR code handed
  /// out before names a port nobody answers on, and a host UI must re-render
  /// its invite — fine for a room nobody could reach yet, stranding for
  /// one people had joined.
  ///
  /// Single-flight: a call made while a restart is already running (an app
  /// resume hook and a [listenerDone] watcher both reacting to the same
  /// death) shares that restart and its outcome instead of racing it for
  /// the port. A call for a different [address] waits for the running one
  /// and then moves.
  Future<void> restartListener({
    InternetAddress? address,
    bool allowNewPort = false,
  }) {
    if (_bound == null || _closed) {
      return Future.error(StateError('JamHostServer is not running'));
    }
    final running = _restarting;
    if (running != null &&
        (address == null || _sameAddress(address, _restartTarget))) {
      return running;
    }
    final Future<void> next = (running ?? Future<void>.value())
        .then<void>((_) {}, onError: (Object _) {})
        .then((_) => _rebind(address, allowNewPort: allowNewPort));
    _restarting = next;
    _restartTarget = address;
    return next.whenComplete(() {
      if (identical(_restarting, next)) {
        _restarting = null;
        _restartTarget = null;
      }
    });
  }

  /// The address a running [restartListener] is moving to (null: staying).
  InternetAddress? _restartTarget;

  Future<void> _rebind(
    InternetAddress? address, {
    required bool allowNewPort,
  }) async {
    final bound = _bound;
    if (bound == null || _closed) {
      throw StateError('JamHostServer is not running');
    }
    final target = address ?? bound.address;
    final moving = !_sameAddress(target, bound.address);
    // Moving: open the new socket while the old one still serves, so a
    // failure costs nothing. (It may clash with the old binding — the any-
    // address and a specific one — in which case it is retried below, once
    // the old one is closed.)
    ServerSocket? fresh;
    if (moving) {
      try {
        fresh = await ServerSocket.bind(target, bound.port);
      } on SocketException {
        fresh = null;
      }
    }
    final old = _server;
    final oldListener = _listener;
    _server = null;
    _listener = null;
    _listenerFailed(StateError('listener restarted'));
    try {
      await old?.close();
      await oldListener?.close();
    } catch (_) {
      // Already gone underneath us, which is why we are here.
    }
    try {
      fresh ??= await _bindPort(target, bound.port, allowNewPort: allowNewPort);
    } catch (_) {
      if (moving && !_closed) {
        // Stay where the room was rather than nowhere.
        try {
          final back = await ServerSocket.bind(bound.address, bound.port);
          _listenerDone = Completer<Object?>();
          _listen(back);
        } catch (_) {
          // The old address is gone too; [listenerDone] already says so.
        }
      }
      rethrow;
    }
    if (_closed) {
      await fresh.close();
      return;
    }
    _bound = (address: fresh.address, port: fresh.port);
    _listenerDone = Completer<Object?>();
    _listen(fresh);
    if (moving) await _refreshOwnAddresses();
  }

  static bool _sameAddress(InternetAddress a, InternetAddress? b) =>
      b != null && a.type == b.type && a.address == b.address;

  /// Binds [address]:[port], or — with [allowNewPort] — any free port there
  /// when that one is taken.
  static Future<ServerSocket> _bindPort(
    InternetAddress address,
    int port, {
    required bool allowNewPort,
  }) async {
    try {
      return await ServerSocket.bind(address, port);
    } on SocketException {
      if (!allowNewPort) rethrow;
      return ServerSocket.bind(address, 0);
    }
  }

  /// Re-reads [_ownAddresses] (see [isLanAddress]).
  Future<void> _refreshOwnAddresses() async {
    try {
      _ownAddresses = [
        for (final iface in await NetworkInterface.list(includeLoopback: false))
          ...iface.addresses,
      ];
    } catch (_) {
      _ownAddresses = const []; // Enumeration refused: see [_ownAddresses].
    }
  }

  /// Whether the listening socket is believed alive: started, not closed,
  /// and not failed. A suspended-then-resumed host should not take this on
  /// faith — the OS may have reclaimed the socket without telling anyone;
  /// see [selfProbe].
  bool get isListening =>
      _server != null && !_closed && !_listenerDone.isCompleted;

  void _onListenerError(Completer<Object?> done, Object error) {
    // An accept error can be transient (out of file descriptors for a
    // moment), so it is only a death certificate if the listener also
    // stopped answering. Ask it.
    if (_closed || done.isCompleted || !identical(done, _listenerDone)) {
      return;
    }
    unawaited(
      selfProbe().then((alive) {
        if (!alive && identical(done, _listenerDone)) {
          _listenerFailed(error);
        }
      }),
    );
  }

  void _onListenerDone(Completer<Object?> done) {
    if (done.isCompleted) return; // Already reported (a restart, a failure).
    done.complete(
      _closed ? null : StateError('the listening socket closed underneath us'),
    );
  }

  void _listenerFailed(Object error) {
    if (!_listenerDone.isCompleted) _listenerDone.complete(error);
  }

  /// Checks, end to end, that this server still accepts connections: opens a
  /// fresh connection to its own port and expects an HTTP answer (a plain
  /// GET of `/ws` is answered 426). Cheap — call it when the host app returns from the
  /// background, where a reclaimed listening socket can otherwise go
  /// unnoticed (the listener's stream need not end when the OS takes the
  /// socket). A failed probe also completes [listenerDone].
  Future<bool> selfProbe({
    Duration timeout = const Duration(seconds: 2),
  }) async {
    final bound = _bound;
    if (bound == null || _closed) return false;
    final target = bound.address.address == InternetAddress.anyIPv4.address
        ? InternetAddress.loopbackIPv4
        : bound.address.address == InternetAddress.anyIPv6.address
        ? InternetAddress.loopbackIPv6
        : bound.address;
    final client = HttpClient()..connectionTimeout = timeout;
    var alive = false;
    try {
      final request = await client
          .getUrl(
            Uri(
              scheme: 'http',
              host: target.address,
              port: bound.port,
              path: '/ws',
            ),
          )
          .timeout(timeout);
      final response = await request.close().timeout(timeout);
      // Any answer at all proves the listener accepted and the server is
      // serving (`/ws` normally says 426; a §9 address filter may say 403).
      alive = true;
      await response.drain<void>().timeout(timeout);
    } catch (_) {
      // Refused, reset, or silent: all mean nobody new gets in.
    } finally {
      client.close(force: true);
    }
    if (!alive && !_closed) {
      _listenerFailed(
        SocketException('self-probe of port ${bound.port} failed'),
      );
    }
    return alive;
  }

  /// Stops the listening socket WITHOUT closing the room — what the OS does
  /// to a suspended app — so tests can exercise [listenerDone] and
  /// [selfProbe].
  @visibleForTesting
  Future<void> debugKillListener() async => _listener?.close();

  /// TCP connections currently counted against [maxConnections] — so tests
  /// can prove every way a connection ends gives its slot back.
  @visibleForTesting
  int get debugOpenConnections => _guard?.openConnections ?? 0;

  /// Guest uploads (§6.4) whose request has been accepted and whose body is
  /// still arriving — so tests can act while one is mid-flight.
  @visibleForTesting
  int get debugUploadsInFlight => _pendingUploads;

  // --- Upload directory hygiene ------------------------------------------------

  static const String _uploadDirPrefix = 'localjam_upload_';
  static const String _uploadLockName = '.localjam.lock';

  /// Creates and exclusively locks [dir]'s lock file, recording this
  /// process's pid in it. The lock dies with the process — that is the
  /// point: it is how [sweepStaleUploadDirs] knows the owner is gone.
  ///
  /// The lock is taken BLOCKING: another process's sweep may be probing
  /// this very file at this moment (its probe holds the lock for an
  /// instant), and a non-blocking attempt that lost that race would leave
  /// a live room's directory unlocked — and so sweepable — for good.
  static Future<RandomAccessFile?> _lockUploadDir(Directory dir) async {
    try {
      final raf = await File(
        '${dir.path}/$_uploadLockName',
      ).open(mode: FileMode.write);
      await raf.lock(FileLock.blockingExclusive);
      await raf.writeString('$pid');
      await raf.flush();
      return raf;
    } catch (_) {
      return null; // Locking unsupported: the dir is just never swept.
    }
  }

  /// Deletes `localjam_upload_*` directories under [parent] (default: the
  /// system temp dir) that a host which never reached [close] left behind —
  /// an app killed while hosting, which on a phone is the normal way a jam
  /// ends — and returns how many it removed. Best-effort and never throws.
  ///
  /// A directory is stale when the process that created it is gone: its
  /// lock file is not held by anyone. Three rules keep a LIVE room's
  /// directory safe. One recorded under this process's own pid is never
  /// touched — record locks do not conflict within a process, so another
  /// server in this process (another isolate, a test) would look abandoned.
  /// One whose lock file is younger than [_sweepMinAge], or names no owner
  /// yet, is left alone, since its host may be between creating the file
  /// and locking it. And one with no lock file at all is only removed once
  /// its directory is that old.
  static Future<int> sweepStaleUploadDirs({Directory? parent}) async {
    var removed = 0;
    try {
      final root = parent ?? Directory.systemTemp;
      await for (final entity in root.list(followLinks: false)) {
        if (entity is! Directory) continue;
        final name = entity.uri.pathSegments.lastWhere(
          (segment) => segment.isNotEmpty,
          orElse: () => '',
        );
        if (!name.startsWith(_uploadDirPrefix)) continue;
        if (!await _isAbandoned(entity)) continue;
        try {
          await entity.delete(recursive: true);
          removed++;
        } catch (_) {
          // Raced another sweeper, or not ours to delete: leave it.
        }
      }
    } catch (_) {
      // Temp dir unlistable: nothing to sweep.
    }
    return removed;
  }

  /// How old an upload directory's lock file must be before a sweep will
  /// even consider it (see [sweepStaleUploadDirs]).
  static const Duration _sweepMinAge = Duration(minutes: 1);

  static Future<bool> _isAbandoned(Directory dir) async {
    final lockFile = File('${dir.path}/$_uploadLockName');
    if (!await lockFile.exists()) {
      final modified = (await dir.stat()).modified;
      return DateTime.now().difference(modified) > const Duration(minutes: 10);
    }
    final String owner;
    try {
      if (DateTime.now().difference(await lockFile.lastModified()) <
          _sweepMinAge) {
        return false;
      }
      owner = (await lockFile.readAsString()).trim();
    } catch (_) {
      return false;
    }
    if (owner.isEmpty || owner == '$pid') return false;
    RandomAccessFile? probe;
    try {
      probe = await lockFile.open(mode: FileMode.append);
      // Non-blocking: throws while the owning process holds its lock.
      await probe.lock(FileLock.exclusive);
      return true;
    } catch (_) {
      return false;
    } finally {
      try {
        await probe?.close(); // Also releases our probe lock.
      } catch (_) {}
    }
  }

  /// The join parameters (§1 Discovery) for [iface], which should be one of
  /// the addresses this server is reachable on. [JoinLink.toHttpUri] is what
  /// a QR code carries since 1.2; [joinUriFor] is the `localjam://` form.
  JoinLink joinLinkFor(InternetAddress iface) => JoinLink(
    v: MessageCodec.protocolVersion,
    token: token,
    name: sessionName,
    hosts: [iface.address],
    port: port,
  );

  /// The `localjam://join?...` URI (§1 Discovery) for [iface], which should
  /// be one of the addresses this server is reachable on.
  Uri joinUriFor(InternetAddress iface) => joinLinkFor(iface).toLocaljamUri();

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
    _endTimer?.cancel();
    _cancelPendingStart();
    _catalogGeneration++;
    _dropQueuedCatalogAdds();
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
    try {
      await _listener?.close();
    } catch (_) {
      // Already reclaimed underneath us.
    }
    if (!_listenerDone.isCompleted) _listenerDone.complete(null);
    try {
      await _uploadDirLock?.close(); // Releases the lock with the handle.
    } catch (_) {}
    _uploadDirLock = null;
    if (_ownsUploadDir) {
      try {
        await _uploadDir?.delete(recursive: true);
      } catch (_) {
        // Best-effort cleanup of the per-instance temp dir.
      }
    }
    await _events.close();
    await _kickedChanges.close();
  }

  // --- HTTP routing ----------------------------------------------------------

  Future<void> _handleRequest(HttpRequest req) async {
    final path = req.uri.path;
    final upgrade = path == '/ws' && WebSocketTransformer.isUpgradeRequest(req);
    // Every handler but an upload's leaves the request body unread, and
    // left alone `dart:io` drains an unread body before it sends a
    // response's headers — so a request that declares a gigabyte and sends
    // nothing would never be answered and would hold its connection for
    // good. Its body is therefore subscribed to (and dropped) up front,
    // held paused, and cancelled once the request is answered, which tears
    // the connection down. An upload reads its own (see [_answer]).
    final body = upgrade || path == '/media'
        ? null
        : (req.listen(null)..pause());
    try {
      // §9.1: one request per connection. The connection guard counts the
      // header bytes of a connection's FIRST request only — the bytes after
      // it are a body or WebSocket frames, which it cannot tell apart from
      // a second request without parsing HTTP itself — so a kept-alive
      // connection would let an unauthenticated sender's next header block
      // through uncounted. On a LAN a fresh TCP connection per transfer
      // costs nothing. (A successful `/ws` upgrade is the one connection
      // that outlives its request, and it is held to the pre-hello budget.)
      if (!upgrade) req.response.persistentConnection = false;
      // §9, defense in depth: even when the socket had to be bound on every
      // interface (one port, several networks), nothing off-LAN is served.
      if (!_remoteAllowed(req.connectionInfo?.remoteAddress)) {
        await _answer(req, HttpStatus.forbidden);
        return;
      }
      if (path == '/ws') {
        await _handleWsUpgrade(req);
      } else if (path == '/' || path == '/join') {
        await _serveIndex(req);
      } else if (path.startsWith(_webPrefix)) {
        await _serveWebFile(req, path.substring(_webPrefix.length));
      } else if (path == '/media') {
        await _handleUpload(req);
      } else if (path.startsWith('/media/')) {
        await _serveMedia(req);
      } else if (path.startsWith('/artwork/')) {
        await _serveArtwork(req);
      } else if (path == '/catalog') {
        await _serveCatalog(req);
      } else if (path.startsWith('/catalog/')) {
        await _serveCatalogArtwork(req);
      } else {
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
      }
    } catch (_) {
      // A handler bug or a vanished client. Say so if nothing has been sent
      // yet — an unexplained exception must not read as a `200`.
      await _answer(req, HttpStatus.internalServerError);
    } finally {
      unawaited(body?.cancel());
    }
  }

  // --- Web guest page (§1.1) ---------------------------------------------------

  static const String _webPrefix = '/web/';

  /// The page's own caching: never stored, so a phone that scanned last
  /// week's room never runs last week's player against this week's host.
  /// That holds for every route the page is served at — `/`, `/join`, and
  /// `/web/index.html` too, should anything ask for it there.
  static const String _indexCacheControl = 'no-store';

  /// Bundle files: revalidated on every load (`no-cache`), and the `ETag`
  /// makes that a `304` with no body unless the host's bundle changed.
  static const String _webCacheControl = 'no-cache';

  /// The bundle key that is the page itself (see [_indexCacheControl]).
  static const String _indexKey = 'index.html';

  /// `GET /` and `GET /join` (§1.1): the page, unauthenticated — the token
  /// rides the URL fragment, which no request carries, and is needed to do
  /// anything with the page.
  Future<void> _serveIndex(HttpRequest req) async {
    final res = req.response;
    if (await _refusedMethod(req)) return;
    final index = staticSite?.index;
    final bytes = index?.bytes ?? _builtInPageBytes;
    res.statusCode = HttpStatus.ok;
    res.headers
      ..contentType = ContentType
          .html // text/html; charset=utf-8
      ..set(HttpHeaders.cacheControlHeader, _indexCacheControl);
    res.contentLength = bytes.length;
    await _sendPage(req, bytes);
  }

  /// Sends a page response (§1.1) — [bytes] as its body, or none — and
  /// closes it, by the deadline of [minPageSendTime]: a connection still
  /// sending then is destroyed, freeing its slot (§9.1). The route needs no
  /// token, so a reader that takes nothing must not be able to keep it.
  Future<void> _sendPage(HttpRequest req, [Uint8List? bytes]) async {
    final res = req.response;
    final atRate = Duration(
      microseconds:
          (bytes?.length ?? 0) *
          Duration.microsecondsPerSecond ~/
          max(1, minPageBytesPerSecond),
    );
    final deadline = atRate > minPageSendTime ? atRate : minPageSendTime;
    // `dart:io` destroys the connection at a response's deadline; the race
    // below is so this handler is not left waiting on a close that a
    // destroyed connection may never complete.
    res.deadline = deadline;
    final expired = Completer<void>();
    final watchdog = Timer(deadline, expired.complete);
    try {
      if (bytes != null) res.add(bytes);
      await Future.any([
        res.close().then<void>((_) {}, onError: (Object _) {}),
        expired.future,
      ]);
    } finally {
      watchdog.cancel();
      try {
        res.deadline = null; // Sent in time: nothing left to destroy.
      } catch (_) {}
    }
  }

  static final Uint8List _builtInPageBytes = Uint8List.fromList(
    utf8.encode(builtInNoPlayerPage),
  );

  /// `GET /web/<path>` (§1.1): the bundle file keyed exactly [rawPath]
  /// (percent-decoded, after `dart:io` has removed dot segments from the
  /// request path, RFC 3986 §5.2.4, before routing ever sees it), with its
  /// MIME, `Cache-Control: no-cache` (`no-store` for the page itself) and
  /// its `ETag`, or `304` when `If-None-Match` already names that `ETag`.
  /// Only keys of [staticSite] are ever served — there is no filesystem
  /// behind this — so anything else, traversal attempts included, is `404`.
  Future<void> _serveWebFile(HttpRequest req, String rawPath) async {
    final res = req.response;
    if (await _refusedMethod(req)) return;
    String? path;
    try {
      path = Uri.decodeComponent(rawPath);
    } catch (_) {
      path = null; // Malformed escape: names no file.
    }
    final file = path == null ? null : staticSite?.files[path];
    if (file == null) {
      res.statusCode = HttpStatus.notFound;
      await _sendPage(req);
      return;
    }
    res.headers
      ..set(
        HttpHeaders.cacheControlHeader,
        path == _indexKey ? _indexCacheControl : _webCacheControl,
      )
      ..set(HttpHeaders.etagHeader, file.etag);
    if (_etagMatches(req.headers[HttpHeaders.ifNoneMatchHeader], file.etag)) {
      await _sendNotModified(res);
      return;
    }
    res.statusCode = HttpStatus.ok;
    try {
      res.headers.contentType = ContentType.parse(file.mime);
    } catch (_) {
      res.headers.contentType = ContentType.binary;
    }
    res.contentLength = file.length;
    await _sendPage(req, file.bytes);
  }

  /// A `304` is its head and nothing else (RFC 9110 §15.4.5): no
  /// `Content-Type` — `dart:io` would otherwise send its default,
  /// `text/plain` — and no framing, where `dart:io` would write
  /// `Content-Length: 0` on a GET (which a 304 must not send unless it is
  /// the 200's length, §8.6) and `Transfer-Encoding: chunked` on a HEAD. So
  /// the head is written by detaching the socket, which writes the headers
  /// as they stand and frames nothing, and the connection is then closed
  /// (§9.1: one request per connection) with the guard's usual linger.
  Future<void> _sendNotModified(HttpResponse res) async {
    res.statusCode = HttpStatus.notModified;
    res.headers
      ..contentType = null
      ..chunkedTransferEncoding = false;
    final socket = await res.detachSocket();
    try {
      await socket.flush();
    } catch (_) {
      // Gone already.
    }
    unawaited(socket.close().then<void>((_) {}, onError: (Object _) {}));
  }

  /// `GET` (and `HEAD`, which `dart:io` answers with the same headers and
  /// no body) only; anything else is answered `405` here, and true says so.
  Future<bool> _refusedMethod(HttpRequest req) async {
    if (req.method == 'GET' || req.method == 'HEAD') return false;
    final res = req.response;
    res.statusCode = HttpStatus.methodNotAllowed;
    res.headers.set(HttpHeaders.allowHeader, 'GET, HEAD');
    await res.close();
    return true;
  }

  /// RFC 9110 §13.1.2: `*`, or any listed tag equal under weak comparison.
  static bool _etagMatches(List<String>? headers, String etag) {
    if (headers == null) return false;
    String strip(String tag) => tag.startsWith('W/') ? tag.substring(2) : tag;
    for (final header in headers) {
      for (final candidate in header.split(',')) {
        final tag = candidate.trim();
        if (tag == '*' || strip(tag) == etag) return true;
      }
    }
    return false;
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
      req.response.persistentConnection = false;
      req.response.statusCode = HttpStatus.forbidden;
      await req.response.close();
      return;
    }
    final pending = _conns.where((c) => !c.joined).length;
    if (pending >= maxPendingConnections) {
      req.response.persistentConnection = false;
      req.response.statusCode = HttpStatus.serviceUnavailable;
      await req.response.close();
      return;
    }
    // §9.1: until its `hello` is accepted, the socket may send this many raw
    // bytes in all — counted as they arrive, because `dart:io` reassembles a
    // whole WebSocket message before the per-frame cap in [_onFrame] can
    // look at it.
    // Past it the socket is closed with `policyViolation`, like an
    // oversized pre-hello frame (the bytes stop being read either way).
    _GuestConn? conn;
    final socket = _guard?.socketFor(req.connectionInfo);
    final withinBudget =
        socket?.limitUntilTrusted(
          maxPreHelloFrameBytes + _preHelloFramingSlack,
          maxMessageBytes: maxPreHelloFrameBytes,
          onExceeded: () {
            final c = conn;
            if (c == null) return; // Still upgrading: destroyed shortly.
            unawaited(
              c.ws.close(WebSocketStatus.policyViolation).catchError((_) {}),
            );
            _dropConn(c);
          },
        ) ??
        true;
    if (!withinBudget) {
      // Frames that came in the same read as the upgrade request already
      // break the budget, and `dart:io` would hand them to the WebSocket
      // whole: the guard has destroyed the connection, so it is not
      // upgraded. (Answering only lets `dart:io` finish the request.)
      await _closeQuietly(req.response, HttpStatus.badRequest);
      return;
    }
    // No permessage-deflate (§9.1): the frame caps are applied to messages
    // after reassembly, so with compression on, the 16 KB pre-hello cap
    // would be measured after inflation — a few hundred bytes on the wire
    // from a socket that has proved nothing could inflate into megabytes
    // before any cap looks at it. Control frames are small JSON anyway.
    final ws = await WebSocketTransformer.upgrade(
      req,
      compression: CompressionOptions.compressionOff,
    );
    final opened = conn = _GuestConn(ws, nowUs: _nowUs(), socket: socket);
    _conns.add(opened);
    ws.listen(
      (data) => _onFrame(opened, data),
      onDone: () => _dropConn(opened),
      onError: (Object _) => _dropConn(opened),
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

  /// The file this server stored for a guest upload of [mediaId] (§6.4) —
  /// what the host's own player plays when the room selects a guest's
  /// track: the host never fetches its own media plane, and the bytes are
  /// already on its disk. Null when [mediaId] is not an upload (an item the
  /// host registered with [addMedia] is backed by the caller's own file,
  /// which the caller already knows — and one that replaced an upload with
  /// the same content takes its place here too), when no such item was ever
  /// stored, and once [close] has deleted the server's own upload directory.
  ///
  /// The file lives for the whole session, whatever happens to the item:
  /// nothing deletes an upload before [close] — removing an item from the
  /// playlist keeps its bytes servable (see [removeMediaItem]), and
  /// [sweepStaleUploadDirs] never touches a live server's directory. A
  /// caller that wants an upload to outlive the room (a history entry it
  /// can replay later) must copy it before [close].
  File? storedUploadFile(String mediaId) {
    if (_closed && _ownsUploadDir) return null;
    final entry = _media[mediaId];
    return entry != null && entry.uploaded ? entry.file : null;
  }

  // --- Catalog (§6.6) ------------------------------------------------------------

  /// The catalog as the control plane announces it (§6.6): what `welcome`
  /// carries, or null while the host offers none.
  CatalogSummary? get catalog => _catalogProvider == null
      ? null
      : CatalogSummary(rev: _catalogRev, count: _catalogList.length);

  /// The entries the catalog offers, as read at the last [setCatalog]
  /// (empty while the host offers none).
  List<CatalogEntry> get catalogEntries => _catalogList;

  /// Offers [provider]'s songs to the room as a catalog (§6.6), or stops
  /// offering one (`null`). A call that changes what is offered bumps the
  /// catalog's `rev` and broadcasts `catalog { rev, count }` — `count: 0`
  /// when turned off — and later `welcome`s carry the same. A call that
  /// leaves the listing as it was (the same entries, whether from the same
  /// provider or another) bumps nothing and broadcasts nothing.
  ///
  /// [provider]'s entries are read first, once: call this again with the
  /// same provider when its library changed. If reading them throws, the
  /// catalog stays exactly as it was and the error is rethrown. Entries
  /// whose id could not be a URL path segment, and repeats of an id (the
  /// first wins), are dropped.
  ///
  /// Adds still waiting keep their place across a refresh by the same
  /// provider, except those for ids it no longer offers, which are dropped;
  /// a different provider, or `null`, drops them all, and an add already
  /// under way is abandoned before it lands. While the host offers none,
  /// `GET /catalog` is `404` and `catalog_add` changes nothing.
  ///
  /// A no-op before anything was offered when [provider] is null, and after
  /// [close].
  void setCatalog(JamCatalogProvider? provider) {
    if (_closed) return;
    if (provider == null && _catalogProvider == null) return;
    // Read first: a provider that throws leaves the old catalog in place.
    final list = <CatalogEntry>[];
    final byId = <String, CatalogEntry>{};
    if (provider != null) {
      for (final entry in provider.entries) {
        // The id is a path segment of `/catalog/{id}/artwork`; the first of
        // two entries that share one wins.
        if (!_isSafeResourceId(entry.catalogId)) continue;
        if (byId.containsKey(entry.catalogId)) continue;
        byId[entry.catalogId] = entry;
        list.add(entry);
      }
    }
    final listingChanged =
        provider == null ||
        _catalogProvider == null ||
        !_sameCatalogEntries(list, _catalogList);
    if (!identical(provider, _catalogProvider)) {
      // Another provider's ids are not this one's: nothing queued, hashed
      // or cover read under the old one carries over.
      _catalogGeneration++;
      _dropQueuedCatalogAdds();
      _catalogQueuedIds.clear();
      _catalogMediaIds.clear();
      _coverCache.clear();
      _coverCacheBytes = 0;
      _coverLoads.clear();
    }
    _catalogProvider = provider;
    if (!listingChanged) return;
    _catalogList = List.unmodifiable(list);
    _catalogById = byId;
    _catalogBody = null;
    _withdrawCatalogIds(byId);
    _catalogRev++;
    _broadcast(
      CatalogMessage(
        summary: CatalogSummary(rev: _catalogRev, count: list.length),
      ),
    );
  }

  static bool _sameCatalogEntries(List<CatalogEntry> a, List<CatalogEntry> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      final x = a[i];
      final y = b[i];
      if (identical(x, y)) continue;
      if (x.catalogId != y.catalogId ||
          x.title != y.title ||
          x.artist != y.artist ||
          x.album != y.album ||
          x.durationUs != y.durationUs ||
          x.sizeBytes != y.sizeBytes ||
          x.hasArtwork != y.hasArtwork) {
        return false;
      }
    }
    return true;
  }

  /// After a refresh by the same provider: adds waiting for ids it no
  /// longer offers are dropped (their slots released), and their covers
  /// forgotten.
  void _withdrawCatalogIds(Map<String, CatalogEntry> offered) {
    if (_catalogQueue.isNotEmpty) {
      final keep = <_CatalogAdd>[];
      while (_catalogQueue.isNotEmpty) {
        final job = _catalogQueue.removeFirst();
        if (offered.containsKey(job.catalogId)) {
          keep.add(job);
        } else {
          _releaseCatalogAdd(job);
          if (!job.done.isCompleted) job.done.complete(null);
        }
      }
      _catalogQueue.addAll(keep);
    }
    final gone = [
      for (final id in _coverCache.keys)
        if (!offered.containsKey(id)) id,
    ];
    for (final id in gone) {
      _coverCacheBytes -= _coverCache.remove(id)?.bytes.length ?? 0;
    }
  }

  /// Adds the catalog entry [catalogId] to the queue for the host itself —
  /// its own UI's "add from my library" — credited to
  /// [JamPermissions.hostPeerId], through the same path a guest's
  /// `catalog_add` takes (§6.6), behind any adds already waiting.
  ///
  /// Completes with the item and whether it was added (`added: false`: its
  /// content was already in the queue, which is left as it was), or null
  /// when nothing could be added — the host offers no catalog, [catalogId]
  /// is not in it (any more), its file could not be opened, or the catalog
  /// was turned off meanwhile. Host additions are not remote input: no
  /// pending-adds bound and no playlist cap apply.
  Future<({MediaItem item, bool added})?> addFromCatalog(String catalogId) {
    if (_closed ||
        _catalogProvider == null ||
        !_catalogById.containsKey(catalogId)) {
      return Future.value();
    }
    final job = _CatalogAdd(
      catalogId,
      requester: null,
      generation: _catalogGeneration,
    );
    _catalogQueue.add(job);
    _pumpCatalog();
    return job.done.future;
  }

  /// The file backing [mediaId] in the media registry (§6.1) — what the
  /// host's own player plays for an item it did not register itself: a
  /// catalog add ([JamHostEventKind.catalogAdded]; the provider's file, or
  /// whatever file the registry already held for the same content) or a
  /// guest upload (see [storedUploadFile]). Null for an id never
  /// registered.
  File? mediaFile(String mediaId) => _media[mediaId]?.file;

  /// A guest's `catalog_add` (§6.6), its `add_tracks` already checked: the
  /// first [maxCatalogIdsPerRequest] ids, less repeats, ids the catalog
  /// does not hold, ids already waiting to land and ids whose content is
  /// already in the queue, are queued to land one at a time, as far as
  /// [maxPendingCatalogAdds], [maxPendingCatalogAddsPerPeer] and the
  /// playlist cap leave room — and the ids past that room are answered
  /// with one `busy`. A request with no usable id changes nothing and gets
  /// no answer: the playlist broadcasts are the answer (§6.6).
  void _onCatalogAdd(_GuestConn conn, List<String> requested) {
    if (_catalogProvider == null) return;
    final wanted = <String>[];
    final seen = <String>{};
    for (final id in requested.take(maxCatalogIdsPerRequest)) {
      if (!seen.add(id) || !_catalogById.containsKey(id)) continue;
      // On its way already, or its content (hashed before) already in the
      // queue: a no-op, and no slot taken.
      if (_catalogQueuedIds.contains(id)) continue;
      final known = _catalogMediaIds[id];
      if (known != null && _inPlaylist(known)) continue;
      wanted.add(id);
    }
    if (wanted.isEmpty) return;
    final peerKey = _catalogPeerKey(conn);
    final pendingRoom = maxPendingCatalogAdds - _catalogPending;
    final peerRoom =
        maxPendingCatalogAddsPerPeer - (_catalogPendingByPeer[peerKey] ?? 0);
    final queueRoom =
        maxPlaylistLength -
        _playlist.length -
        _pendingUploads -
        _catalogPending;
    final room = max(0, min(min(pendingRoom, peerRoom), queueRoom));
    final accepted = min(room, wanted.length);
    final request = _CatalogRequest();
    for (final id in wanted.take(accepted)) {
      _catalogPending++;
      _catalogPendingByPeer[peerKey] =
          (_catalogPendingByPeer[peerKey] ?? 0) + 1;
      _catalogQueuedIds.add(id);
      _catalogQueue.add(
        _CatalogAdd(
          id,
          requester: conn,
          generation: _catalogGeneration,
          peerKey: peerKey,
          request: request,
        ),
      );
    }
    if (accepted < wanted.length) {
      request.busySent = true;
      final dropped = wanted.length - accepted;
      _sendTo(
        conn.ws,
        ErrorMessage(
          code: ErrorCode.busy,
          message: queueRoom <= min(pendingRoom, peerRoom)
              ? 'the queue is full: $dropped not added'
              : 'too many songs are being added: $dropped not added',
        ),
      );
    }
    if (accepted > 0) _pumpCatalog();
  }

  /// Whose share of [maxPendingCatalogAddsPerPeer] a guest's adds count
  /// against: its device (so a rejoin under a new peerId does not reset
  /// it), or the connection when it sent no clientId.
  static Object _catalogPeerKey(_GuestConn conn) => conn.device ?? conn;

  bool _inPlaylist(String mediaId) =>
      _playlist.any((i) => i.mediaId == mediaId);

  /// Lands queued catalog adds one at a time until the queue is empty.
  void _pumpCatalog() {
    if (_catalogDraining) return;
    _catalogDraining = true;
    unawaited(() async {
      try {
        while (_catalogQueue.isNotEmpty && !_closed) {
          final job = _catalogQueue.removeFirst();
          ({MediaItem item, bool added})? result;
          try {
            result = await _landCatalogAdd(job);
          } catch (_) {
            // An unreadable file, a full disk, a provider bug: this song is
            // skipped, and the next one gets its turn.
            result = null;
          } finally {
            _releaseCatalogAdd(job);
          }
          if (!job.done.isCompleted) job.done.complete(result);
        }
      } finally {
        _catalogDraining = false;
      }
    }());
  }

  /// Every add still waiting is dropped (the catalog went, or changed
  /// provider): nothing of it lands, and its reservations are released.
  void _dropQueuedCatalogAdds() {
    while (_catalogQueue.isNotEmpty) {
      final job = _catalogQueue.removeFirst();
      _releaseCatalogAdd(job);
      if (!job.done.isCompleted) job.done.complete(null);
    }
  }

  /// Gives back what [job] held — its place among the ids waiting, and,
  /// for a guest's add, its pending-adds and playlist slots. Once per job.
  void _releaseCatalogAdd(_CatalogAdd job) {
    if (job.released) return;
    job.released = true;
    if (!job.remote) return;
    // A later generation's set does not hold this one's ids.
    if (job.generation == _catalogGeneration) {
      _catalogQueuedIds.remove(job.catalogId);
    }
    _catalogPending--;
    final key = job.peerKey!;
    final left = (_catalogPendingByPeer[key] ?? 1) - 1;
    if (left <= 0) {
      _catalogPendingByPeer.remove(key);
    } else {
      _catalogPendingByPeer[key] = left;
    }
  }

  /// Whether [job]'s entry is still offered by the provider it was queued
  /// under.
  bool _catalogStillOffers(_CatalogAdd job) =>
      !_closed &&
      job.generation == _catalogGeneration &&
      _catalogProvider != null &&
      _catalogById.containsKey(job.catalogId);

  /// Whether [job] could still land: its entry still offered and, for a
  /// guest's add, its requester still credited.
  bool _catalogMayLand(_CatalogAdd job) {
    if (!_catalogStillOffers(job)) return false;
    final requester = job.requester;
    return requester == null || _catalogCredit(requester) != null;
  }

  /// Who a guest's catalog add is credited to, if it may land now: the
  /// peerId its device holds (the same test an upload's landing passes,
  /// §6.4/§5.6), while that peer still has `add_tracks`. Null otherwise.
  String? _catalogCredit(_GuestConn requester) {
    final peerId = _landingPeer(requester);
    if (peerId == null) return null;
    return _permissions.allows(peerId, JamCapability.addTracks) ? peerId : null;
  }

  /// One catalog add, the way the host adds its own files: open, sha256;
  /// for content the room does not have yet, probe, read tags (in full: the
  /// host's own library is not remote input, §6.4) and cover; then land it
  /// — or not, judged again at the landing, with no await between that
  /// judgement and the registry write.
  ///
  /// Judged again after every await before that, too: an add the catalog
  /// or its requester no longer wants stops there — mid-hash included —
  /// and leaves nothing behind (its cover is written to disk only to be
  /// registered at the landing, and deleted if it does not land).
  Future<({MediaItem item, bool added})?> _landCatalogAdd(
    _CatalogAdd job,
  ) async {
    bool wanted() => _catalogMayLand(job);
    if (!wanted()) return null;
    final requester = job.requester;
    final provider = _catalogProvider!;
    final id = job.catalogId;
    final entry = _catalogById[id]!;

    // Hashed under this catalog already, and still in the queue: a no-op,
    // without opening or hashing it again.
    final known = _catalogMediaIds[id];
    final knownEntry = known == null ? null : _media[known];
    if (knownEntry != null && _inPlaylist(known!)) {
      return (item: knownEntry.item, added: false);
    }

    final file = await provider.open(id);
    if (file == null || !wanted()) return null;
    final hashed = await _hashCatalogFile(file, cancelled: () => !wanted());
    if (hashed == null || !wanted()) return null;
    final mediaId = 'm_${hashed.digest.substring(0, 12)}';
    _catalogMediaIds[id] = mediaId;
    var item = MediaItem(
      mediaId: mediaId,
      kind: MediaKind.audio,
      name: Uri.file(file.path).pathSegments.last,
      mime: provider.mimeFor(id, file),
      sizeBytes: hashed.size,
      sha256: hashed.digest,
    );

    _StagedArtwork? staged;
    try {
      if (!_media.containsKey(mediaId)) {
        int? probed;
        try {
          probed = plausibleDurationUs(
            await provider.probeDurationUs(id, file),
          );
        } catch (_) {
          // No probe: the library's duration, then the tag's.
        }
        if (!wanted()) return null;
        final tags = await readAudioTags(file);
        if (!wanted()) return null;
        if (tags.hasArtwork) {
          staged = await _stageArtwork(
            tags.artworkBytes!,
            mime: tags.artworkMime!,
          );
          if (!wanted()) return null;
        }
        item = MediaItem(
          mediaId: item.mediaId,
          kind: item.kind,
          name: item.name,
          mime: item.mime,
          sizeBytes: item.sizeBytes,
          durationUs:
              probed ??
              plausibleDurationUs(entry.durationUs) ??
              plausibleDurationUs(tags.durationUs),
          sha256: item.sha256,
          // §6.1: host-extracted tags; what the library said is the
          // fallback for a file that carries none (it is what the guest
          // browsed).
          title: tags.title ?? _nonBlank(entry.title),
          artist: tags.artist ?? _nonBlank(entry.artist),
          album: tags.album ?? _nonBlank(entry.album),
          artworkId: staged?.artworkId,
        );
      }

      // The landing: from here to the registry write nothing awaits.
      if (!_catalogStillOffers(job)) return null;
      final String addedBy;
      if (requester == null) {
        addedBy = JamPermissions.hostPeerId;
      } else {
        final credit = _catalogCredit(requester);
        if (credit == null) return null;
        addedBy = credit;
      }
      final existing = _media[item.mediaId];
      if (existing != null && _inPlaylist(item.mediaId)) {
        // §6.6: idempotent like an upload — already queued, nothing changes
        // (the item keeps whatever catalogId it has).
        return (item: existing.item, added: false);
      }
      // §9.1: the guests' playlist cap counts catalog adds. This one's own
      // slot was reserved when it was queued, but the host's own additions
      // are not held to the cap and may have filled it meanwhile.
      if (requester != null &&
          _playlist.length + _pendingUploads + _catalogPending >
              maxPlaylistLength) {
        _catalogBusy(job, addedBy, 'the queue is full: not added');
        return null;
      }
      final MediaItem landed;
      final File backing;
      final bool uploaded;
      if (existing != null) {
        // Removed content goes back in, credited to whoever put it back,
        // with the metadata it had (§6.4) — and as this catalog row.
        landed = _creditedTo(existing.item, addedBy, catalogId: id);
        backing = existing.file;
        uploaded = existing.uploaded;
      } else {
        if (staged != null) _registerStagedArtwork(staged);
        landed = _creditedTo(item, addedBy, catalogId: id);
        backing = file;
        uploaded = false;
      }
      _emit(
        JamHostEvent._(
          JamHostEventKind.catalogAdded,
          peerId: addedBy,
          mediaId: landed.mediaId,
          catalogId: id,
        ),
      );
      _addMedia(landed, backing, uploaded: uploaded, device: requester?.device);
      return (item: landed, added: true);
    } finally {
      // A cover written for an add that did not land (or whose bytes were
      // registered meanwhile by someone else) is not kept.
      final stray = staged?.file;
      if (stray != null && !staged!.kept) {
        try {
          await stray.delete();
        } catch (_) {
          // Already gone (the upload dir went with close()).
        }
      }
    }
  }

  /// Tells [job]'s requester (as [peerId] now, or on the connection it
  /// asked on) that its add did not fit — once per request (§6.6).
  void _catalogBusy(_CatalogAdd job, String peerId, String message) {
    final request = job.request;
    final requester = job.requester;
    if (request == null || requester == null || request.busySent) return;
    request.busySent = true;
    _sendTo(
      (_peers[peerId] ?? requester).ws,
      ErrorMessage(code: ErrorCode.busy, message: message),
    );
  }

  /// sha256 and size of [file], streamed in chunks, giving up (null) as
  /// soon as [cancelled] says so — a song turned off mid-hash does not
  /// keep the host reading it to the end.
  static Future<({int size, String digest})?> _hashCatalogFile(
    File file, {
    required bool Function() cancelled,
  }) async {
    final digestSink = _DigestSink();
    final hasher = sha256.startChunkedConversion(digestSink);
    var size = 0;
    await for (final chunk in file.openRead()) {
      if (cancelled()) return null;
      hasher.add(chunk);
      size += chunk.length;
    }
    hasher.close();
    return (size: size, digest: digestSink.value!.toString());
  }

  /// Writes cover [bytes] for a catalog add that has not landed yet, under
  /// a name of its own, without registering it: [_registerStagedArtwork]
  /// does that at the landing, and an add that does not land deletes the
  /// file. Nothing is written when the registry holds these bytes already.
  Future<_StagedArtwork> _stageArtwork(
    Uint8List bytes, {
    required String mime,
  }) async {
    final dir = _uploadDir;
    if (dir == null) throw StateError('JamHostServer is not started');
    final digest = sha256.convert(bytes).toString();
    final artworkId = 'a_${digest.substring(0, 12)}';
    if (_artwork.containsKey(artworkId)) {
      return _StagedArtwork(artworkId, mime, null);
    }
    final file = File('${dir.path}/$artworkId.c${_stagedArtworkSeq++}');
    final tmp = File('${file.path}.part');
    try {
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(file.path);
    } catch (_) {
      try {
        await tmp.delete();
      } catch (_) {}
      rethrow;
    }
    return _StagedArtwork(artworkId, mime, file);
  }

  /// Registers [staged] as servable artwork (§6.5) — synchronously, at a
  /// catalog add's landing — unless the same bytes were registered
  /// meanwhile, in which case the staged copy is left to be deleted.
  void _registerStagedArtwork(_StagedArtwork staged) {
    final file = staged.file;
    if (file == null || _artwork.containsKey(staged.artworkId)) return;
    _artwork[staged.artworkId] = (mime: staged.mime, file: file);
    staged.kept = true;
  }

  static String? _nonBlank(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  /// Serves `GET /catalog` (§6.6): the current listing as JSON, `404` while
  /// the host offers no catalog. Bearer-gated like the media plane.
  Future<void> _serveCatalog(HttpRequest req) async {
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
    if (_catalogProvider == null) {
      res.statusCode = HttpStatus.notFound;
      await res.close();
      return;
    }
    final body = _catalogBody ??= utf8.encode(
      jsonEncode(CatalogListing(rev: _catalogRev, items: _catalogList)),
    );
    res.headers.contentType = ContentType.json;
    res.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    res.contentLength = body.length;
    res.add(body);
    await res.close();
  }

  /// Serves `GET /catalog/{catalogId}/artwork` (§6.6): the song's embedded
  /// cover, read from its file on demand and kept in a small cache. `404`
  /// for an id the catalog does not hold, a song without a cover (or one
  /// over [maxArtworkBytes]), and while no catalog is offered — or when the
  /// catalog changed provider while the cover was being read. `503` when
  /// [catalogCoverReadsAtOnce] reads are under way and
  /// [catalogCoverReadsWaiting] more are waiting (not remembered: ask
  /// again).
  Future<void> _serveCatalogArtwork(HttpRequest req) async {
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
    final segments = req.uri.pathSegments;
    final id = segments.length == 3 && segments[2] == 'artwork'
        ? segments[1]
        : null;
    final entry = id != null && _isSafeResourceId(id) ? _catalogById[id] : null;
    final generation = _catalogGeneration;
    final cover = entry == null || entry.hasArtwork == false
        ? null
        : await _catalogCover(entry.catalogId);
    if (identical(cover, _coverBusy)) {
      res.statusCode = HttpStatus.serviceUnavailable;
      res.headers.set(HttpHeaders.retryAfterHeader, '1');
      await res.close();
      return;
    }
    // Turned off, replaced, or the song withdrawn while its cover was read.
    if (cover == null ||
        generation != _catalogGeneration ||
        !_catalogById.containsKey(id)) {
      res.statusCode = HttpStatus.notFound;
      await res.close();
      return;
    }
    try {
      res.headers.contentType = ContentType.parse(cover.mime);
    } catch (_) {
      res.headers.contentType = ContentType.binary;
    }
    res.contentLength = cover.bytes.length;
    res.add(cover.bytes);
    await res.close();
  }

  /// What [_catalogCover] answers when too many cover reads are under way
  /// and waiting: not a cover, not "none" — come back later (`503`).
  static final _CatalogCover _coverBusy = _CatalogCover('', Uint8List(0));

  /// The cover of [catalogId], from the cache or read now (one read per
  /// song at a time, at most [catalogCoverReadsAtOnce] songs at a time,
  /// [catalogCoverReadsWaiting] more waiting their turn; past that,
  /// [_coverBusy]).
  Future<_CatalogCover?> _catalogCover(String catalogId) {
    if (_coverCache.containsKey(catalogId)) {
      // Most recently used goes last.
      final cover = _coverCache.remove(catalogId);
      _coverCache[catalogId] = cover;
      return Future.value(cover);
    }
    final loading = _coverLoads[catalogId];
    if (loading != null) return loading;
    if (_coverReadsActive >= catalogCoverReadsAtOnce &&
        _coverReadTurns.length >= catalogCoverReadsWaiting) {
      return Future.value(_coverBusy);
    }
    final load = _loadCatalogCover(catalogId);
    _coverLoads[catalogId] = load;
    unawaited(
      load.whenComplete(() {
        if (identical(_coverLoads[catalogId], load)) {
          _coverLoads.remove(catalogId);
        }
      }),
    );
    return load;
  }

  /// [_readCatalogCover] once a read slot is free; null when the catalog
  /// changed provider (or the server closed) while it waited.
  Future<_CatalogCover?> _loadCatalogCover(String catalogId) async {
    final generation = _catalogGeneration;
    if (_coverReadsActive < catalogCoverReadsAtOnce) {
      _coverReadsActive++;
    } else {
      final turn = Completer<void>();
      _coverReadTurns.add(turn);
      await turn.future; // The slot is handed over: see the finally below.
    }
    try {
      if (_closed ||
          generation != _catalogGeneration ||
          !_catalogById.containsKey(catalogId)) {
        return null;
      }
      return await _readCatalogCover(catalogId, generation);
    } finally {
      if (_coverReadTurns.isNotEmpty) {
        _coverReadTurns.removeFirst().complete();
      } else {
        _coverReadsActive--;
      }
    }
  }

  /// Reads [catalogId]'s cover from the file the provider gives for it
  /// ([JamCatalogProvider.openForArtwork] — never [JamCatalogProvider.open],
  /// which may copy), bounded like an upload's tags (§6.4): a cover over
  /// [maxArtworkBytes] is not read, and not served. Never throws; a file
  /// that cannot be opened is a song without a cover this time, and is not
  /// remembered as one.
  Future<_CatalogCover?> _readCatalogCover(
    String catalogId,
    int generation,
  ) async {
    final provider = _catalogProvider;
    if (provider == null) return null;
    _CatalogCover? cover;
    try {
      final file = await provider.openForArtwork(catalogId);
      if (file == null) return null;
      final tags = await readAudioTags(file, maxMetadataBytes: maxArtworkBytes);
      final bytes = tags.artworkBytes;
      if (tags.hasArtwork && bytes!.length <= maxArtworkBytes) {
        cover = _CatalogCover(
          tags.artworkMime ?? 'application/octet-stream',
          bytes,
        );
      }
    } catch (_) {
      return null;
    }
    if (generation == _catalogGeneration &&
        _catalogById.containsKey(catalogId)) {
      _cacheCover(catalogId, cover);
    }
    return cover;
  }

  /// Remembers [cover] (or that there is none) for [catalogId], evicting
  /// the least recently used past [catalogCoverCacheSize] entries or
  /// [catalogCoverCacheBytes] bytes.
  void _cacheCover(String catalogId, _CatalogCover? cover) {
    if (catalogCoverCacheSize <= 0) return;
    final size = cover?.bytes.length ?? 0;
    if (size > catalogCoverCacheBytes) return;
    final previous = _coverCache.remove(catalogId);
    _coverCacheBytes -= previous?.bytes.length ?? 0;
    while (_coverCache.isNotEmpty &&
        (_coverCache.length >= catalogCoverCacheSize ||
            _coverCacheBytes + size > catalogCoverCacheBytes)) {
      final oldest = _coverCache.keys.first;
      _coverCacheBytes -= _coverCache.remove(oldest)?.bytes.length ?? 0;
    }
    _coverCache[catalogId] = cover;
    _coverCacheBytes += size;
  }

  /// How many catalog covers are cached right now (tests).
  @visibleForTesting
  int get debugCatalogCoversCached => _coverCache.length;

  /// Guest catalog adds queued or landing right now (tests).
  @visibleForTesting
  int get debugCatalogAddsPending => _catalogPending;

  // --- Guest uploads (§6.4) ------------------------------------------------------

  /// Handles `POST /media`: streams the raw body to disk while hashing
  /// incrementally (never buffering the file in memory), derives the mediaId
  /// from the host-computed sha256 exactly like [describeFile], registers the
  /// item via [addMedia], and answers 201 with the MediaItem JSON — or 200
  /// with the existing item when the content is already queued
  /// (idempotency, §6.4). Content that was removed from the queue goes back
  /// in, as a 201.
  Future<void> _handleUpload(HttpRequest req) async {
    // §6.4/§9: Authorization: Bearer <sessionToken> gates uploads too.
    if (!_bearerMatches(req.headers.value(HttpHeaders.authorizationHeader))) {
      await _refuseUpload(req, HttpStatus.unauthorized);
      return;
    }
    if (req.method != 'POST') {
      await _refuseUpload(req, HttpStatus.methodNotAllowed);
      return;
    }

    final MediaKind kind;
    try {
      kind = MediaKind.fromWire(req.headers.value('X-LocalJam-Kind') ?? '');
    } on FormatException {
      await _refuseUpload(req, HttpStatus.badRequest);
      return;
    }
    final String? rawName = req.headers.value('X-LocalJam-Name');
    final String name;
    try {
      // §6.4: the name header is percent-encoded UTF-8. A bad escape
      // (`%zz`) is an ArgumentError, a good escape of bytes that are not
      // UTF-8 (`%FF`) a FormatException: both are a malformed header.
      name = rawName == null ? 'upload' : Uri.decodeComponent(rawName);
    } on Object catch (e) {
      if (e is! ArgumentError && e is! FormatException) rethrow;
      await _refuseUpload(req, HttpStatus.badRequest);
      return;
    }
    final mime =
        req.headers.value('X-LocalJam-Mime') ?? 'application/octet-stream';
    final durationUs = plausibleDurationUs(
      int.tryParse(req.headers.value('X-LocalJam-Duration-Us') ?? ''),
    );

    // §6.4/§5.6: WHO is uploading is proved by the per-peer upload key from
    // that peer's `welcome`, never by a claim. The session token only proves
    // the request comes from someone holding the invite — which, for a
    // discoverable room, is everyone on the Wi-Fi — and a self-declared
    // peer id let any of them upload under Listen-only, as anyone, or as
    // the host ("host" holds every capability). A key belongs to a joined
    // peer and is judged exactly as that peer.
    final uploader = _uploaderFor(req.headers.value('X-LocalJam-Upload-Key'));
    final peerId = uploader?.peerId;
    if (peerId == null ||
        !_permissions.allows(peerId, JamCapability.addTracks)) {
      await _refuseUpload(req, HttpStatus.forbidden);
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
      await _refuseUpload(req, HttpStatus.lengthRequired);
      return;
    }
    if (declared > maxUploadBytes) {
      await _refuseUpload(req, HttpStatus.requestEntityTooLarge);
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
    if (_playlist.length + _pendingUploads + _catalogPending >=
            maxPlaylistLength ||
        _uploadedBytes + _reservedBytes + declared > uploadBudgetBytes) {
      await _refuseUpload(req, HttpStatus.insufficientStorage);
      return;
    }
    // §6.4: one peer's uploads in flight are capped, so the time bound on
    // each ([uploadStallTimeout]) is also a bound on how much of the room's
    // budget one peer can hold at a time.
    final inFlight = _uploadsInFlight[peerId] ?? 0;
    if (inFlight >= maxUploadsPerPeer) {
      await _refuseUpload(req, HttpStatus.tooManyRequests);
      return;
    }

    // Reserved for the whole request and released on every exit — stored,
    // idempotent, over a cap, stalled, or a client that vanished mid-body.
    // A stored upload reconciles the reservation to the bytes it actually
    // received.
    _reservedBytes += declared;
    _pendingUploads++;
    _uploadsInFlight[peerId] = inFlight + 1;
    try {
      await _receiveUpload(
        req,
        declared: declared,
        kind: kind,
        name: name,
        mime: mime,
        durationUs: durationUs,
        uploader: uploader!,
      );
    } finally {
      _reservedBytes -= declared;
      _pendingUploads--;
      final left = (_uploadsInFlight[peerId] ?? 1) - 1;
      if (left <= 0) {
        _uploadsInFlight.remove(peerId);
      } else {
        _uploadsInFlight[peerId] = left;
      }
    }
  }

  /// The body half of [_handleUpload], from the first byte on: streams to
  /// disk while hashing, then stores, registers and answers. Runs inside the
  /// caller's budget reservation of [declared] bytes.
  ///
  /// The partial file is deleted on every path that does not store it —
  /// it lives only inside that reservation, so one that outlived its
  /// request would be disk the budget no longer counts (§6.4).
  Future<void> _receiveUpload(
    HttpRequest req, {
    required int declared,
    required MediaKind kind,
    required String name,
    required String mime,
    required int? durationUs,
    required _GuestConn uploader,
  }) async {
    final res = req.response;
    final dir = _uploadDir!;
    final tmp = File('${dir.path}/incoming_${_randomHex(8)}.part');
    var stored = false;
    try {
      final outcome = await _receiveBody(req, tmp, declared: declared);
      final failure = switch (outcome.end) {
        _BodyEnd.complete => null,
        _BodyEnd.overLimit => HttpStatus.requestEntityTooLarge,
        _BodyEnd.overBudget => HttpStatus.insufficientStorage,
        _BodyEnd.stalled => HttpStatus.requestTimeout,
        // Most likely nobody is left to read it.
        _BodyEnd.aborted => HttpStatus.badRequest,
        _BodyEnd.writeFailed => HttpStatus.insufficientStorage,
      };
      if (failure != null) {
        // A body cut off by a cap is read to its end first, within bounds,
        // so the client gets to see why (see [_refuseUpload]). A stalled
        // one would only make the host wait for what it is too slow to
        // send, and a vanished one has nobody left to tell.
        if (outcome.end != _BodyEnd.stalled &&
            outcome.end != _BodyEnd.aborted) {
          await _drainRefused(
            outcome.body,
            remaining: declared - outcome.received,
          );
        }
        // Answered while the body is merely paused (or done), then let go:
        // cancelling a request body destroys its connection on the spot,
        // so the other order would hand the client a reset instead of the
        // reason.
        await _closeQuietly(res, failure);
        unawaited(outcome.body.cancel());
        return;
      }
      final digest = outcome.digest!;
      final received = outcome.received;
      final mediaId = 'm_${digest.substring(0, 12)}';

      // §6.1/§6.5: the host extracts tags + artwork itself — one
      // implementation for uploads and host files, and guests never need a
      // tag parser — from the bytes as they arrived, before they are stored
      // (see below). Content the room already has keeps its first upload's
      // metadata (§6.4), so it is not read again.
      var tags = const JamAudioTags();
      String? artworkId;
      if (kind == MediaKind.audio && !_media.containsKey(mediaId)) {
        // Remote input: the parser is only let at what it can read within
        // the artwork cap's budget (§6.5) — a crafted multi-hundred-megabyte
        // "cover" or tag frame is skipped, not loaded.
        tags = await readAudioTags(tmp, maxMetadataBytes: maxArtworkBytes);
        final artworkBytes = tags.artworkBytes;
        // Cover art is served to every guest (§6.5) and held whole in
        // memory on each of them: an oversized "cover" is dropped, not
        // stored.
        if (tags.hasArtwork && artworkBytes!.length <= maxArtworkBytes) {
          artworkId = await addArtwork(artworkBytes, mime: tags.artworkMime!);
        }
      }

      // The landing. The headers were judged when the request arrived, but
      // a body takes a while and the room moves on meanwhile (§6.4/§5.6):
      // whether this may still be added, and as whose, is decided now —
      // and from here until the registry holds the outcome nothing awaits,
      // so neither can change again first.
      final addedBy = _landingPeer(uploader);
      if (addedBy == null) {
        await _closeQuietly(res, HttpStatus.forbidden);
        return;
      }
      final existing = _media[mediaId];
      final MediaItem item;
      final int status;
      if (existing == null) {
        // Synchronous so that the landing above holds (one metadata
        // operation in the upload directory).
        final file = tmp.renameSync('${dir.path}/$mediaId');
        stored = true;
        // Only new content spends the budget (§6.4).
        _uploadedBytes += received;
        item = MediaItem(
          mediaId: mediaId,
          kind: kind,
          name: name,
          mime: mime,
          sizeBytes: received,
          // The uploader's declared duration wins over the tag value (a
          // decoder probe beats a tag claim).
          durationUs: durationUs ?? plausibleDurationUs(tags.durationUs),
          sha256: digest,
          title: tags.title,
          artist: tags.artist,
          album: tags.album,
          artworkId: artworkId,
          addedBy: addedBy,
        );
        _addUpload(item, file, uploaded: true, device: uploader.device);
        status = HttpStatus.created;
      } else if (_playlist.any((i) => i.mediaId == mediaId)) {
        // §6.4 idempotency: the mediaId is content-derived, so an existing
        // id means the same bytes — answer 200 with the existing item, keep
        // its original metadata, and broadcast nothing.
        item = existing.item;
        status = HttpStatus.ok;
      } else {
        // §6.4: the same bytes as an item removed from the queue. The
        // registry still holds them (§5.6 removal keeps bytes servable),
        // so nothing is stored or spent — but this is an add, and it is
        // answered as one: back in the queue, credited to whoever put it
        // back. A 200 would tell the guest "already queued" about a track
        // that is not. Its permission and its playlist slot were judged
        // and reserved like any upload's.
        item = _creditedTo(existing.item, addedBy);
        _addUpload(
          item,
          existing.file,
          uploaded: existing.uploaded,
          device: uploader.device,
        );
        status = HttpStatus.created;
      }
      res.statusCode = status;
      res.headers.contentType = ContentType.json;
      res.write(jsonEncode(item.toJson()));
      await res.close();
    } finally {
      if (!stored) {
        try {
          await tmp.delete();
        } catch (_) {
          // Never created, or the room's directory is already gone.
        }
      }
    }
  }

  /// Streams an upload body into [tmp] while hashing it — the file is never
  /// held in memory — and says how it ended. Never throws.
  ///
  /// The body is held to [maxUploadBytes] and the session budget as it
  /// arrives (a `Content-Length` is a claim, not a promise), and to the
  /// stall rule of [uploadStallTimeout] / [minUploadBytesPerSecond]:
  /// `dart:io` puts no time bound on a request body, so without one a
  /// client that declares 512 MB and goes quiet holds its reservation, its
  /// playlist slot and a file descriptor forever.
  Future<
    ({
      _BodyEnd end,
      int received,
      String? digest,
      StreamSubscription<Uint8List> body,
    })
  >
  _receiveBody(HttpRequest req, File tmp, {required int declared}) async {
    final digestSink = _DigestSink();
    final hasher = sha256.startChunkedConversion(digestSink);
    final sink = tmp.openWrite();
    final ended = Completer<_BodyEnd>();
    var received = 0;
    late final StreamSubscription<Uint8List> body;
    void finish(_BodyEnd end) {
      if (ended.isCompleted) return;
      // Stop reading; the caller answers, then cancels.
      if (end != _BodyEnd.complete) body.pause();
      ended.complete(end);
    }

    // Handlers in place before the first byte: listening makes `dart:io`
    // parse whatever body bytes arrived with the headers synchronously.
    body = req.listen(
      (chunk) {
        if (ended.isCompleted) return;
        received += chunk.length;
        if (received > maxUploadBytes) return finish(_BodyEnd.overLimit);
        // A body that outruns its declared length is spending budget it
        // never reserved (`_reservedBytes` already holds `declared` on this
        // request's behalf, so it is discounted here).
        if (_uploadedBytes + _reservedBytes - declared + received >
            uploadBudgetBytes) {
          return finish(_BodyEnd.overBudget);
        }
        hasher.add(chunk);
        sink.add(chunk);
      },
      // The client vanished mid-body (reset, or the connection closed).
      onError: (Object _) => finish(_BodyEnd.aborted),
      onDone: () =>
          finish(received == declared ? _BodyEnd.complete : _BodyEnd.aborted),
    );

    // The stall rule: each window must deliver what the minimum rate says
    // for the time the host was listening, or everything that is left if
    // that is less, and never nothing.
    //
    // Windows are measured, not assumed. A periodic timer keeps its grid,
    // so a tick delayed by a host stall (a GC pause, a blocked isolate)
    // shortened the next window while the full window's bytes were still
    // owed — a false 408 for a guest sending well above the minimum. And a
    // late tick judges nothing: whatever the client sent meanwhile is still
    // in the socket buffer, unread, so the window is extended instead, and
    // the time the host was away is not counted against the client.
    final clock = Stopwatch()..start();
    var windowStartUs = 0;
    var hostAwayUs = 0;
    var receivedAtWindowStart = 0;
    Timer? watchdog;
    void watch() {
      final dueUs =
          clock.elapsedMicroseconds + uploadStallTimeout.inMicroseconds;
      watchdog = Timer(uploadStallTimeout, () {
        if (ended.isCompleted) return;
        final nowUs = clock.elapsedMicroseconds;
        final lateUs = nowUs - dueUs;
        if (lateUs > _stallCheckSlackUs) {
          hostAwayUs += lateUs;
          return watch();
        }
        final listenedUs = nowUs - lateUs - windowStartUs - hostAwayUs;
        final dueBytes =
            minUploadBytesPerSecond *
            listenedUs ~/
            Duration.microsecondsPerSecond;
        final owed = max(1, min(declared - receivedAtWindowStart, dueBytes));
        if (received - receivedAtWindowStart < owed) {
          return finish(_BodyEnd.stalled);
        }
        windowStartUs = nowUs;
        hostAwayUs = 0;
        receivedAtWindowStart = received;
        watch();
      });
    }

    watch();
    final end = await ended.future;
    watchdog?.cancel();
    var outcome = end;
    try {
      await sink.flush();
      await sink.close();
    } catch (_) {
      // Disk full or the directory gone: nothing was stored.
      if (outcome == _BodyEnd.complete) outcome = _BodyEnd.writeFailed;
    }
    hasher.close();
    return (
      end: outcome,
      received: received,
      digest: outcome == _BodyEnd.complete
          ? digestSink.value!.toString()
          : null,
      body: body,
    );
  }

  /// Answers a refused `POST /media` with [status], having first read and
  /// dropped what is left of its body — when that is at most
  /// [refusedUploadDrainBytes] and arrives within [helloTimeout].
  ///
  /// Most HTTP clients, `dart:io`'s among them, send a whole request body
  /// before they read any response. A refusal sent mid-body never reaches
  /// them: the host closing a connection with input still unread resets
  /// it, and the guest sees a broken pipe where the `507` (or `429`, or
  /// `403`) should have said why (§6.4). A body over the bound is not
  /// worth the wait or the airtime, and one that does not arrive in time
  /// holds its connection no longer than an unauthenticated one may
  /// (§9.1): both are answered and cut off at once, as before.
  Future<void> _refuseUpload(HttpRequest req, int status) async {
    StreamSubscription<Uint8List>? body;
    try {
      body = req.listen(null);
    } on StateError {
      // Already being read; its reader lets it go.
    }
    if (body != null) {
      await _drainRefused(body, remaining: req.contentLength);
    }
    await _closeQuietly(req.response, status);
    unawaited(body?.cancel());
  }

  /// Reads and drops the [remaining] bytes of a refused request [body] if
  /// that is at most [refusedUploadDrainBytes], until the body ends or
  /// [helloTimeout] passes; [body] is left paused unless it ended. Nothing
  /// is waited for when [remaining] is not positive: no body is left (a
  /// body read to its end already), or none was declared.
  Future<void> _drainRefused(
    StreamSubscription<Uint8List> body, {
    required int remaining,
  }) async {
    if (remaining <= 0 || remaining > refusedUploadDrainBytes) {
      if (!body.isPaused) body.pause();
      return;
    }
    final ended = Completer<void>();
    void end() {
      if (!ended.isCompleted) ended.complete();
    }

    body
      ..onData(null)
      ..onError((Object _) => end())
      ..onDone(end);
    if (body.isPaused) body.resume();
    await ended.future.timeout(helloTimeout, onTimeout: () {});
    if (!ended.isCompleted) body.pause();
  }

  /// The most of a refused upload's body the host reads, and drops, so
  /// that its client sees the refusal (§6.4): 64 MB, a few seconds of a
  /// good Wi-Fi link. A refusal of a larger body — a `413` always is one —
  /// reaches a client that only reads its response after sending the whole
  /// body as a connection error.
  static const int refusedUploadDrainBytes = 64 * 1024 * 1024;

  /// Answers [status] without reading what is left of [req]'s body — see
  /// [_handleRequest] for why an unread body must be subscribed to first.
  static Future<void> _answer(HttpRequest req, int status) async {
    StreamSubscription<Uint8List>? unread;
    try {
      unread = req.listen(null)..pause();
    } on StateError {
      // Already being read; its reader lets it go.
    }
    await _closeQuietly(req.response, status);
    unawaited(unread?.cancel());
  }

  /// Answers [status] and closes, for responses whose client may well be
  /// gone already.
  static Future<void> _closeQuietly(HttpResponse res, int status) async {
    try {
      res.persistentConnection = false;
      res.statusCode = status;
    } catch (_) {
      // Headers already sent: all that is left to do is end it.
    }
    try {
      await res.close();
    } catch (_) {
      // Nobody left to tell.
    }
  }

  /// Who an upload whose body has just arrived is credited to — the
  /// peerId its device holds now — or null when it must not land (`403`,
  /// §6.4/§5.6).
  ///
  /// The request was judged at its headers as the peer whose key it
  /// presented, but a body takes a while. A device kicked meanwhile is out
  /// of the room, and so is what it was in the middle of adding: the kick
  /// would otherwise be followed by its track arriving in the queue. A
  /// device that rejoined fresh meanwhile (§3.3) is back under a new
  /// peerId, and is credited there: crediting the old one would cost it the
  /// right to remove its own track (§5.6).
  ///
  /// A peer that merely dropped is still in the room while its §3.3 grace
  /// slot holds — its peerId, role and tracks are kept for it — so its
  /// upload lands, credited to that peerId. The body rides on a connection
  /// of its own: a Wi-Fi blip on the control socket must not throw away a
  /// file that arrived whole. Only a peer gone for good, with its device not
  /// back — kicked without a clientId for the kick check to recognise,
  /// superseded, or past its grace window — is refused, like a request that
  /// presented a dead key.
  String? _landingPeer(_GuestConn uploader) {
    final device = uploader.device;
    if (device != null) {
      if (_kicked.containsKey(device)) return null;
      final rejoined = _joinedPeerOf(device);
      if (rejoined != null) return rejoined;
    }
    final peerId = uploader.peerId;
    if (peerId == null) return null;
    if (identical(_peers[peerId], uploader)) return peerId;
    // Dropped, not gone: the same expiry test a resume is held to (a slot
    // outlives its window until the next liveness tick reaps it).
    final slot = _grace[peerId];
    return slot != null && slot.untilUs >= _nowUs() ? peerId : null;
  }

  /// Puts a guest upload's [item] in the registry and the queue: the
  /// `mediaUploaded` event first, then [_addMedia]'s playlist broadcast
  /// (which also threads durationUs into the session per §5.5).
  void _addUpload(
    MediaItem item,
    File file, {
    required bool uploaded,
    required String? device,
  }) {
    _emit(
      JamHostEvent._(
        JamHostEventKind.mediaUploaded,
        peerId: item.addedBy,
        mediaId: item.mediaId,
      ),
    );
    _addMedia(item, file, uploaded: uploaded, device: device);
  }

  /// [durationUs] when it is a duration a real file could have — positive and
  /// at most [maxPlausibleDurationUs] — else null (unknown). Durations from
  /// the wire are claims (§6.4): a zero would end the track the moment it
  /// started, a negative one breaks clamping (§5.5), and "unknown" is always
  /// a safe answer.
  static int? plausibleDurationUs(int? durationUs) =>
      durationUs != null &&
          durationUs > 0 &&
          durationUs <= maxPlausibleDurationUs
      ? durationUs
      : null;

  /// The joined peer that holds [key] as its upload credential (§6.4), or
  /// null. Compared in constant time per peer, like the session token.
  _GuestConn? _uploaderFor(String? key) {
    if (key == null || key.isEmpty) return null;
    for (final conn in _peers.values) {
      final own = conn.uploadKey;
      if (own != null && _secureEquals(own, key)) return conn;
    }
    return null;
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
    // Digits only, so the only way to fail parsing is to overflow int64 — a
    // number past any file's size, which is what it is treated as.
    int parse(String digits) => int.tryParse(digits) ?? (1 << 62);
    if (rawStart.isEmpty) {
      // Suffix range: last <rawEnd> bytes.
      final suffix = parse(rawEnd);
      if (suffix == 0 || size == 0) return unsatisfiable;
      return (start: max(0, size - suffix), end: size - 1, satisfiable: true);
    }
    final start = parse(rawStart);
    final end = rawEnd.isEmpty ? size - 1 : min(parse(rawEnd), size - 1);
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
    if (!decoded.isSupportedVersion) {
      // §2: a `hello` of another major version gets a version reject; any
      // other foreign-version frame is not ours to read.
      if (!conn.joined && message.type == HelloMessage.wireType) {
        _rejectVersion(conn, decoded.v);
      }
      return;
    }
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

  /// Answers a `hello` of major version [helloV] (§2). The reject is the one
  /// frame a host ever sends in a version it does not speak: it echoes the
  /// hello's `v`, so the guest's own codec reads it, and names the versions
  /// this host does speak. `hello`'s envelope and `reject { reason }` are
  /// the part of the protocol every major version keeps for exactly this.
  void _rejectVersion(_GuestConn conn, int helloV) {
    _safeAdd(
      conn.ws,
      _codec.encode(
        const RejectMessage(
          reason: RejectReason.version,
          versions: [MessageCodec.protocolVersion],
        ),
        seq: _seq++,
        v: helloV,
      ),
    );
    unawaited(
      conn.ws.close(WebSocketStatus.policyViolation).catchError((_) {}),
    );
    _dropConn(conn); // Free the pending slot at once, like any reject.
  }

  void _onHello(_GuestConn conn, HelloMessage hello) {
    if (!_secureEquals(hello.token, token)) {
      _reject(conn, RejectReason.badToken);
      return;
    }

    final clientId = hello.clientId;
    final hasClientId = clientId != null && clientId.isNotEmpty;
    // §5.6: a kick lasts the session. The device is refused by its stable
    // id until the host lets it back in ([unkickPeer]) — refused with a
    // reject, which a guest treats as final, not with a closed socket it
    // would read as a drop and retry forever.
    if (hasClientId && _kicked.containsKey(clientId)) {
      _reject(conn, RejectReason.kicked);
      return;
    }

    // §3.3, one device is one peer: a client that says hello with a
    // clientId already held by a live socket has come back from the dead
    // (force-quit, killed while backgrounded) faster than the silence
    // timeout could reap the corpse. Without this the rejoining guest is
    // handed a ghost of ITSELF in `welcome.peers`, everyone sees a phantom
    // in the roster, and it lands in the session's history. The old socket
    // goes with no grace slot — the device is right here, on a new one.
    //
    // Unless the new hello asks to resume exactly that socket's peerId: then
    // it is not a second copy of the device but the same session noticing
    // the drop first. A guest's watchdog (§3.3: three ping intervals, 6 s)
    // fires well before the host's 10 s silence timeout, so a guest whose
    // Wi-Fi blipped is back with `resumePeerId` while its old socket is still
    // "live" here. Superseding that would hand it a fresh peerId — and with
    // it lose everything keyed on the old one: its role and overrides, and
    // the `addedBy` that lets it remove its own tracks (§5.6). So the old
    // socket is dropped the way a silence timeout would drop it, grace slot
    // and all, and the resume check below reclaims the slot at once.
    conn.clientId = clientId;
    if (hasClientId) {
      for (final other in List.of(_conns)) {
        if (other == conn || other.clientId != clientId) continue;
        final supersededId = other.peerId;
        final takeover =
            supersededId != null && supersededId == hello.resumePeerId;
        _dropConn(other, allowResume: takeover);
        if (supersededId != null && !takeover) {
          _setPermissions(_permissions.forgetPeer(supersededId));
        }
      }
    }

    // §3.1: a room has a size. A resuming peer (§3.3) competes for a slot
    // like anyone else — its old slot is not reserved, only its identity.
    if (_peers.length >= maxPeers) {
      _reject(conn, RejectReason.full);
      return;
    }

    // §3.3 reconnect: the token, the peerId, AND the stable clientId that
    // held the slot. The token is shared by the whole room and the peerId is
    // public, so those two prove only membership; without the third, a guest
    // that saw a co-host's `peer_left` could echo the id back and inherit the
    // role and overrides the grace window is still holding (§5.6). An
    // unproven resume is not an error — it is simply a fresh join: a new
    // peerId, the room's default role, nothing carried over. A client that
    // sends no clientId can therefore never resume.
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

    // §5.6: what the host made this device (co-host, a revoked or granted
    // capability) is keyed on its clientId and outlives the peerId — a
    // fresh join after the grace window, or a supersede, would otherwise
    // hand a co-host back a plain guest. Applied before the welcome so the
    // joiner's own document already says so; the others get the broadcast.
    if (hasClientId) {
      _setPermissions(_withModeration(_permissions, peerId, clientId));
    }

    conn.peerId = peerId;
    conn.info = info;
    conn.uploadKey = _randomHex(16); // §6.4: a fresh credential per join.
    // §9.1: proved the token, so the pre-hello byte budget is lifted — but
    // not every bound: messages stay capped as they arrive, and bytes and
    // frames rate-limited.
    conn.socket?.trust(
      maxMessageBytes: maxControlFrameBytes,
      bytesPerSecond: maxInboundBytesPerSecond,
      framesPerSecond: maxInboundFramesPerSecond,
    );
    _peers[peerId] = conn;
    _session.upsertPeer(peerId);

    // §5.6: a device that rejoined under a new peerId gets its own tracks
    // back. Done before the welcome, so the joiner's playlist already says
    // so; everyone else hears it after `peer_joined`, so the new id is a
    // name they can print by the time a byline uses it.
    final reattributed = hasClientId && _reattribute(clientId, peerId);

    // §3.1: welcome carries the full snapshot + playlist + permissions +
    // existing peers, this peer's upload key, and whether the host is away.
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
        uploadKey: conn.uploadKey,
        hostAway: _away,
        catalog: catalog,
      ),
    );
    // §3.2: announce to everyone else.
    _broadcast(PeerJoinedMessage(peer: info), except: conn);
    _emit(JamHostEvent._(JamHostEventKind.peerJoined, peer: info));
    // Only `addedBy` changed: no state broadcast, so playback is untouched.
    if (reattributed) _broadcastPlaylist(except: conn);
  }

  /// Answers a `hello` with a reject (§3.1) and drops the socket. Dropping
  /// it now frees the pending slot it holds against [maxPendingConnections]
  /// immediately, instead of leaving it there until the close handshake
  /// finishes or the hello timeout expires — which is how a wrong-token
  /// flood would take the room's whole handshake capacity.
  void _reject(_GuestConn conn, RejectReason reason) {
    _sendTo(conn.ws, RejectMessage(reason: reason));
    unawaited(
      conn.ws.close(WebSocketStatus.policyViolation).catchError((_) {}),
    );
    _dropConn(conn);
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
        case RequestAction.catalogAdd:
          _onCatalogAdd(conn, request.catalogIds ?? const []);
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
  /// allowed); a catalog add (§6.6) needs [JamCapability.addTracks], like an
  /// upload.
  bool _requestAllowed(String peerId, RequestMessage request) {
    switch (request.action) {
      case RequestAction.catalogAdd:
        return _permissions.allows(peerId, JamCapability.addTracks);
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
    // §6.3: readiness is about media this host serves. A report on any
    // other id is noise at best — and at worst a guest growing the host's
    // per-peer readiness table without bound, one made-up id at a time.
    if (!_media.containsKey(status.mediaId)) return;
    // §6.3: track readiness in the session state machine.
    final readiness = switch (status.state) {
      MediaFetchState.none => MediaReadiness.none,
      MediaFetchState.fetching => MediaReadiness.fetching,
      MediaFetchState.ready => MediaReadiness.ready,
    };
    _session.setPeerMediaState(conn.peerId!, status.mediaId, readiness);
    _releasePendingStartIfReady();
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

  /// Selects [mediaId] — the §5.2 `set_media` request, and the host UI's
  /// "play this one" — and broadcasts the new state (§5.1).
  ///
  /// Selecting keeps the room doing what it was doing. A room that is
  /// playing, or starting (a start held by the §6.3 readiness gate), plays
  /// the selected item from its start: it is selected, then started with a
  /// fresh scheduled anchor (§5.3) through the readiness gate like any new
  /// track — the same transition as [next]. A room that is not playing
  /// cues it: `loading` at position 0, waiting for a [play]. (Selecting
  /// alone used to leave a playing room at `loading`, so tapping a queue row
  /// mid-song stopped the music for everyone.)
  ///
  /// Selecting the item that is already current changes nothing: a
  /// double-tapped row, or a request repeated after a reconnect, must not
  /// restart the song for the room — starting it over is a [seek] to 0.
  ///
  /// The item's playlist `durationUs` (when set) is threaded into the
  /// session so seeks clamp to it and end of media is detectable (§5.5).
  ///
  /// Throws [ArgumentError] if [mediaId] is not in the media registry.
  void setMedia(String mediaId) {
    if (!_media.containsKey(mediaId)) {
      throw ArgumentError.value(mediaId, 'mediaId', 'unknown media id');
    }
    if (_session.snapshot.mediaId == mediaId) return;
    final wasPlaying = _playingOrStarting;
    _select(mediaId);
    if (wasPlaying) play();
  }

  /// The selection half of every track change ([setMedia], skips, removing
  /// the current item, the §5.5 advance policy): [mediaId] becomes current
  /// at position 0, `loading`. Callers decide whether it then plays.
  void _select(String mediaId) {
    final entry = _media[mediaId];
    if (entry == null) {
      throw ArgumentError.value(mediaId, 'mediaId', 'unknown media id');
    }
    _cancelPendingStart(); // A start held for the previous item is moot.
    _apply(
      (now) => _session.setMedia(
        mediaId,
        nowUs: now,
        durationUs: entry.item.durationUs,
      ),
    );
  }

  /// Starts (or resumes) playback with a scheduled anchor (§5.3).
  ///
  /// Starting a freshly selected track (the session is `loading`) goes
  /// through the §6.3 readiness gate: while some joined guest is
  /// mid-transfer of it, the start is held — the room stays `loading` — for
  /// at most [readinessWait], and goes out the moment nobody is fetching it
  /// any more ([isAwaitingReadiness] says whether one is held). Resuming from
  /// `paused` never waits. Throws [StateError] if no media is selected.
  void play() {
    if (_pendingStart != null) return; // Already on its way.
    final snapshot = _session.snapshot;
    final mediaId = snapshot.mediaId;
    if (snapshot.status == PlaybackStatus.loading &&
        mediaId != null &&
        readinessWait > Duration.zero &&
        _session.peersFetching(mediaId).isNotEmpty) {
      _pendingStart = Timer(readinessWait, _startNow);
      return;
    }
    _startNow();
  }

  void _startNow() {
    _cancelPendingStart();
    _apply((now) => _session.play(nowUs: now));
  }

  void _cancelPendingStart() {
    _pendingStart?.cancel();
    _pendingStart = null;
  }

  /// Lets a held start go as soon as nobody is mid-transfer of the item any
  /// more: everyone finished, gave up, or left (§6.3).
  void _releasePendingStartIfReady() {
    if (_pendingStart == null) return;
    final mediaId = _session.snapshot.mediaId;
    if (mediaId == null || _session.peersFetching(mediaId).isEmpty) {
      _startNow();
    }
  }

  /// Whether the room is playing or about to (a start held by the §6.3
  /// gate) — what a skip or a removal must preserve.
  bool get _playingOrStarting =>
      _session.snapshot.status == PlaybackStatus.playing ||
      _pendingStart != null;

  /// Pauses playback, freezing the position (§5.1). Also cancels a start
  /// held by the readiness gate.
  void pause() {
    _cancelPendingStart();
    _apply((now) => _session.pause(nowUs: now));
  }

  /// Seeks to [positionUs] (§5.1/§5.3), clamped to the current item's
  /// duration when known (§5.5).
  void seek(int positionUs) =>
      _apply((now) => _session.seek(positionUs, nowUs: now));

  /// Stops playback: back to idle with no media selected (§5.5).
  void stop() {
    _cancelPendingStart();
    _apply((now) => _session.stop(nowUs: now));
  }

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
    final wasPlaying = _playingOrStarting;
    final index = _playlist.indexWhere(
      (i) => i.mediaId == _session.snapshot.mediaId,
    );
    final target = (index + delta) % _playlist.length;
    // [_select], not [setMedia]: a skip in a one-item playlist lands on the
    // current item, and there it means "from the top".
    _select(_playlist[target < 0 ? target + _playlist.length : target].mediaId);
    if (wasPlaying) play();
  }

  void _apply(PlaybackSnapshot Function(int nowUs) mutate) {
    final before = _session.snapshot.rev;
    final after = mutate(_nowUs());
    if (after.rev == before) return; // No-op: suppress redundant broadcast.
    // A new anchor starts a new run towards an end (§5.5): whatever end was
    // handled before is not this one's.
    if (after.status == PlaybackStatus.playing) _endHandled = false;
    _broadcast(StateMessage(snapshot: after));
    _emit(JamHostEvent._(JamHostEventKind.stateBroadcast, snapshot: after));
    _scheduleEndCheck();
  }

  // --- Media registry (§6.1) -----------------------------------------------------

  /// Registers (or replaces) a playlist item backed by [file] and broadcasts
  /// the updated playlist (§6.1). The caller precomputes [item] — see
  /// [describeFile].
  ///
  /// A [MediaItem.addedBy] naming a peer that is joined (or in its §3.3
  /// grace window) ties the item to that peer's device, so the attribution
  /// follows the device to the next peerId it joins under (§5.6).
  void addMedia(MediaItem item, File file) =>
      _addMedia(item, file, uploaded: false, device: _deviceOf(item.addedBy));

  void _addMedia(
    MediaItem item,
    File file, {
    required bool uploaded,
    required String? device,
  }) {
    _media[item.mediaId] = _MediaEntry(
      item,
      file,
      uploaded: uploaded,
      device: device,
    );
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
    final wasPlaying = _playingOrStarting;
    _playlist.removeAt(index);
    _broadcastPlaylist();
    if (!wasCurrent) return;
    if (_playlist.isEmpty) {
      stop();
      return;
    }
    // The item that slid into the removed slot (wrapping at the end) is the
    // natural "next".
    _select(_playlist[index % _playlist.length].mediaId);
    if (wasPlaying) play();
  }

  void _broadcastPlaylist({_GuestConn? except}) {
    _playlistRev++;
    _broadcast(
      PlaylistMessage(rev: _playlistRev, items: playlist),
      except: except,
    );
    _emit(
      JamHostEvent._(JamHostEventKind.playlistBroadcast, playlist: playlist),
    );
  }

  /// The clientId of the device [peerId] is — joined, or dropped and still
  /// in its §3.3 grace window — or null (the host, a peer gone for good, or
  /// one that sent no clientId).
  String? _deviceOf(String? peerId) {
    if (peerId == null) return null;
    final clientId = _peers[peerId]?.clientId ?? _grace[peerId]?.clientId;
    return clientId == null || clientId.isEmpty ? null : clientId;
  }

  /// The peerId [device] is joined under right now, or null.
  String? _joinedPeerOf(String? device) {
    if (device == null) return null;
    for (final conn in _peers.values) {
      if (conn.clientId == device) return conn.peerId;
    }
    return null;
  }

  /// §5.6, attribution follows the device: credits every item [device]
  /// contributed this session to [peerId], the id it has just joined
  /// under, and says whether the playlist changed.
  ///
  /// A phone that was killed and relaunched, or kicked and let back in,
  /// joins fresh — with a new peerId (§3.3). Its tracks are still its own:
  /// left on the old id, the `addedBy` byline would name a peer that no
  /// longer exists and the device would lose the right to remove its own
  /// contributions. Items of a device that never comes back keep the
  /// peerId they were added under. Removed items are re-credited too: the
  /// registry still serves them.
  bool _reattribute(String device, String peerId) {
    var playlistChanged = false;
    for (final entry in _media.values) {
      if (entry.device != device || entry.item.addedBy == peerId) continue;
      entry.item = _creditedTo(entry.item, peerId);
      final index = _playlist.indexWhere(
        (i) => i.mediaId == entry.item.mediaId,
      );
      if (index >= 0) {
        _playlist[index] = entry.item;
        playlistChanged = true;
      }
    }
    return playlistChanged;
  }

  /// [item] with `addedBy` set to [peerId] and nothing else changed.
  /// [item] credited to [peerId] (§5.6), carrying [catalogId] (§6.1, 1.3):
  /// the catalog entry a catalog add landed it from, or null — an upload or
  /// a host file is no catalog row, whatever the same bytes were before.
  static MediaItem _creditedTo(
    MediaItem item,
    String peerId, {
    String? catalogId,
  }) => MediaItem(
    mediaId: item.mediaId,
    kind: item.kind,
    name: item.name,
    mime: item.mime,
    sizeBytes: item.sizeBytes,
    durationUs: item.durationUs,
    sha256: item.sha256,
    title: item.title,
    artist: item.artist,
    album: item.album,
    artworkId: item.artworkId,
    addedBy: peerId,
    catalogId: catalogId,
  );

  // --- Permissions & moderation (§5.6) --------------------------------------

  /// Replaces the guest-role policy and broadcasts the new document.
  void setPolicy(JamPolicy policy) =>
      _setPermissions(_permissions.withPolicy(policy));

  /// Promotes [peerId] to co-host and broadcasts. No-op if already one.
  ///
  /// The role follows the DEVICE for the rest of the session (§5.6): a peer
  /// that said hello with a clientId keeps it across a fresh rejoin, not
  /// just a resume.
  void promotePeer(String peerId) {
    _moderationFor(peerId)?.cohost = true;
    _setPermissions(_permissions.promote(peerId));
  }

  /// Demotes [peerId] back to guest and broadcasts. No-op if not a co-host.
  void demotePeer(String peerId) {
    _moderationFor(peerId)?.cohost = false;
    _setPermissions(_permissions.demote(peerId));
  }

  /// Sets (or clears, with `allowed: null`) one per-peer capability override
  /// and broadcasts. Like a role, it follows the device (§5.6).
  void setCapabilityOverride(
    String peerId,
    JamCapability capability, {
    required bool? allowed,
  }) {
    final record = _moderationFor(peerId);
    if (record != null) {
      if (allowed == null) {
        record.overrides.remove(capability);
      } else {
        record.overrides[capability] = allowed;
      }
    }
    _setPermissions(
      _permissions.withOverride(peerId, capability, allowed: allowed),
    );
  }

  /// The clientId-keyed moderation record for [peerId] — joined, or dropped
  /// and still in its grace window — created on demand; null for a peer
  /// without a clientId, whose moderation lives and dies with its peerId.
  _ClientModeration? _moderationFor(String peerId) {
    final clientId = _peers[peerId]?.clientId ?? _grace[peerId]?.clientId;
    if (clientId == null || clientId.isEmpty) return null;
    return _moderation.putIfAbsent(clientId, _ClientModeration.new);
  }

  /// [doc] with [clientId]'s recorded role and overrides applied to
  /// [peerId] — `doc` itself when there is nothing to add.
  JamPermissions _withModeration(
    JamPermissions doc,
    String peerId,
    String clientId,
  ) {
    final record = _moderation[clientId];
    if (record == null) return doc;
    var next = record.cohost ? doc.promote(peerId) : doc;
    for (final entry in record.overrides.entries) {
      next = next.withOverride(peerId, entry.key, allowed: entry.value);
    }
    return next;
  }

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

  // --- Host availability (§3.5) -------------------------------------------------

  /// Tells every guest the host is about to stop answering (`away: true`) —
  /// call it right before the app goes where the OS may suspend it (a phone
  /// host moving to the background) — or that it is back (`away: false`, on
  /// resume). Broadcasts `host_status` on a change and is carried in every
  /// later `welcome`, so guests that drop and rejoin during the nap know
  /// too. Guests still notice the silence within seconds (§3.3); what the
  /// flag changes is that they read it as "the host's phone is asleep" and
  /// wait much longer before calling the room dead.
  ///
  /// The returned future completes once the frame has been handed to every
  /// socket, so a caller about to be suspended can await it.
  Future<void> announceAway(bool away) async {
    if (_closed || away == _away) return;
    _away = away;
    _broadcast(HostStatusMessage(away: away));
    // One event-loop turn: the frame leaves the WebSocket sinks for the
    // sockets before the caller lets the OS freeze this isolate.
    await Future<void>.delayed(Duration.zero);
  }

  // --- Liveness (§3.3) -----------------------------------------------------------

  void _checkLiveness() {
    final now = _nowUs();
    final silenceUs = silenceTimeout.inMicroseconds;
    final helloUs = helloTimeout.inMicroseconds;

    // The host's OWN nap (an app suspended in the background, a debugger
    // pause) shows up as a gap between these ticks. Every guest went
    // "silent" during it only because nobody was listening, and their
    // frames may still be waiting in the socket buffers — so the silence
    // clock and the grace windows restart from now instead of passing
    // judgement on time the host was not there for.
    final lastTick = _lastLivenessTickUs;
    _lastLivenessTickUs = now;
    if (lastTick != null) {
      final gapUs = now - lastTick;
      // Well past any timer jitter, and short enough that a nap cannot
      // push a guest's silence over the timeout before it is noticed.
      final napThresholdUs = max(
        silenceUs ~/ 2,
        livenessCheckInterval.inMicroseconds * 4,
      );
      if (gapUs > napThresholdUs) {
        for (final conn in _conns) {
          conn.lastFrameUs = now;
        }
        _grace.updateAll(
          (_, slot) => (untilUs: slot.untilUs + gapUs, clientId: slot.clientId),
        );
        return;
      }
    }

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
      // The peerId is gone for good; the DEVICE's role is not — it is kept
      // by clientId and re-applied if it joins again (§5.6).
      _setPermissions(_permissions.forgetPeer(peerId));
    }
    _checkEndOfMedia(now);
  }

  // --- End of media (§5.5) ---------------------------------------------------

  /// Set once the current track end has been handled; reset as soon as the
  /// session is observed not-ended (new track, seek back, stop) or a new
  /// anchor is broadcast. Guards the checks so [JamHostEventKind.mediaEnded]
  /// and the policy fire exactly once per track end.
  bool _endHandled = false;

  /// Fires [_checkEndOfMedia] at the instant the current item ends.
  Timer? _endTimer;

  /// Arms [_endTimer] for the current snapshot (§5.5). The liveness tick
  /// would notice an end too, but up to a whole [livenessCheckInterval]
  /// late — on top of the scheduled-start lead the next track then waits
  /// for (§5.3), a second of dead air between tracks. With the timer the
  /// end policy runs at the end instant, and the gap is the lead alone.
  void _scheduleEndCheck() {
    _endTimer?.cancel();
    _endTimer = null;
    if (_closed) return;
    final snapshot = _session.snapshot;
    final anchor = snapshot.anchor;
    final durationUs = _session.currentDurationUs;
    if (snapshot.status != PlaybackStatus.playing ||
        anchor == null ||
        durationUs == null) {
      return;
    }
    final endAtUs =
        anchor.hostTimeUs +
        ((durationUs - anchor.positionUs) / snapshot.rate).ceil();
    // A millisecond late rather than early: the position rounds.
    final delayUs = max(0, endAtUs - _nowUs()) + 1000;
    if (delayUs > maxPlausibleDurationUs) return; // The tick has it.
    _endTimer = Timer(Duration(microseconds: delayUs), () {
      _endTimer = null;
      _checkEndOfMedia(_nowUs());
    });
  }

  void _checkEndOfMedia(int now) {
    if (!_session.hasEnded(now)) {
      _endHandled = false;
      return;
    }
    if (_endHandled) return;
    _endHandled = true;

    _applyEndPolicy(_session.snapshot.mediaId);
  }

  /// Tells the server the host's own player reached the end of [mediaId] —
  /// the §5.5 end of media for an item whose playlist entry has no
  /// `durationUs`, which the server cannot otherwise detect (the anchor
  /// extrapolates forever and the queue would never move on). Applies the
  /// [endPolicy] exactly as a duration-detected end does, [JamHostEventKind.mediaEnded]
  /// included.
  ///
  /// Ignored unless [mediaId] is the current item and the room is playing
  /// it. Pass the [snapshotRev] the player was following when it finished:
  /// a report from before a later seek or re-anchor is stale and ignored.
  /// When the item's duration IS known this is a cross-check — accepted
  /// only within [hostFinishTolerance] of that duration, so it can bring a
  /// slightly overlong declared duration forward but cannot cut a track
  /// short on a glitch.
  void reportHostPlaybackFinished(String mediaId, {int? snapshotRev}) {
    if (_closed) return;
    final snapshot = _session.snapshot;
    if (snapshot.mediaId != mediaId ||
        snapshot.status != PlaybackStatus.playing) {
      return;
    }
    if (snapshotRev != null && snapshotRev != snapshot.rev) return;
    final now = _nowUs();
    final anchor = snapshot.anchor;
    if (anchor != null && now < anchor.hostTimeUs) return; // Not started.
    final durationUs = _session.currentDurationUs;
    if (durationUs != null &&
        snapshot.positionAt(now) <
            durationUs - hostFinishTolerance.inMicroseconds) {
      return;
    }
    _endHandled = true;
    _applyEndPolicy(mediaId);
  }

  /// How far before a KNOWN duration [reportHostPlaybackFinished] is still
  /// believed (§5.5).
  static const Duration hostFinishTolerance = Duration(seconds: 5);

  void _applyEndPolicy(String? endedId) {
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
          // A paused room is at the end because someone sought there; it
          // moves on, but nothing starts playing that nobody started.
          final wasPlaying = _session.snapshot.status == PlaybackStatus.playing;
          // [_select]: advancing past the only item replays it.
          _select(next);
          if (wasPlaying) play();
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
  /// peer's role is forgotten. The DEVICE stays out for the rest of the
  /// session: a later `hello` with its clientId is answered
  /// `reject { reason: "kicked" }` until [unkickPeer]. (A device that sends
  /// no clientId cannot be recognised, so for it a kick is just a removal.)
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
      final clientId = conn.clientId;
      if (clientId != null && clientId.isNotEmpty) {
        _kicked[clientId] = conn.info!;
        // A kick is not a pause on a co-host's role: if the host lets the
        // device back in, it returns as a guest. Restrictions stay.
        _moderation[clientId]?.cohost = false;
      }
    }
    _dropConn(conn, allowResume: allowResume);
    if (!allowResume) {
      _setPermissions(_permissions.forgetPeer(peerId));
      if (conn.clientId?.isNotEmpty ?? false) _emitKickedChanged();
    }
  }

  /// Lets a device kicked earlier this session join again (§5.6). [peerId]
  /// is the id it had when kicked, as listed in [kickedPeers]. Returns
  /// whether there was such a device. It rejoins as a new peer, through a
  /// fresh join of its own — nothing reconnects it automatically.
  bool unkickPeer(String peerId) {
    final before = _kicked.length;
    _kicked.removeWhere((_, info) => info.peerId == peerId);
    final changed = _kicked.length != before;
    if (changed) _emitKickedChanged();
    return changed;
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
    // A held start may have been waiting on exactly this peer (§6.3).
    _releasePendingStartIfReady();
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

/// One media registry entry (§6.1). See `JamHostServer._media`.
class _MediaEntry {
  _MediaEntry(this.item, this.file, {required this.uploaded, this.device});

  /// The item as the room knows it. Replaced (never mutated) when its
  /// attribution moves to its device's new peerId (§5.6).
  MediaItem item;

  final File file;

  /// Whether [file] is a guest upload this server stored (§6.4) — see
  /// `JamHostServer.storedUploadFile`.
  final bool uploaded;

  /// The stable `hello.clientId` of the device [MediaItem.addedBy] names:
  /// what lets a contribution follow its device to every peerId it joins
  /// under this session (§5.6). Null for the host's own items and for a
  /// peer that sent no clientId — attribution then stays with the peerId.
  final String? device;
}

/// One catalog add waiting to land (§6.6). See `JamHostServer._catalogQueue`.
class _CatalogAdd {
  _CatalogAdd(
    this.catalogId, {
    required this.requester,
    required this.generation,
    this.peerKey,
    this.request,
  });

  final String catalogId;

  /// The guest connection whose `catalog_add` this is — judged again, and
  /// credited, when it lands — or null for the host's own
  /// `JamHostServer.addFromCatalog`.
  final _GuestConn? requester;

  /// The catalog generation it was queued under.
  final int generation;

  /// Completes with what landed, or null.
  final Completer<({MediaItem item, bool added})?> done =
      Completer<({MediaItem item, bool added})?>();

  /// Whose per-peer pending count it holds (a guest's add only).
  final Object? peerKey;

  /// The `catalog_add` it came in with (a guest's add only), so a request
  /// gets at most one `busy`.
  final _CatalogRequest? request;

  /// Whether its slots were given back (once).
  bool released = false;

  /// Whether it is remote input, held to the pending-adds bound and the
  /// playlist cap.
  bool get remote => requester != null;
}

/// One guest `catalog_add` request (§6.6), shared by the adds it queued.
class _CatalogRequest {
  /// Whether this request was answered `busy` already.
  bool busySent = false;
}

/// A catalog add's cover, written to disk but not registered until the add
/// lands (see `JamHostServer._stageArtwork`). [file] is null when the
/// registry held these bytes already, so nothing was written.
class _StagedArtwork {
  _StagedArtwork(this.artworkId, this.mime, this.file);

  final String artworkId;
  final String mime;
  final File? file;

  /// Whether [file] became the registered artwork (else it is deleted).
  bool kept = false;
}

/// One cached catalog cover (§6.6).
class _CatalogCover {
  const _CatalogCover(this.mime, this.bytes);

  final String mime;
  final Uint8List bytes;
}

/// What the host made one device (§5.6), kept by its stable clientId so it
/// outlives any one peerId. See `JamHostServer._moderation`.
class _ClientModeration {
  bool cohost = false;
  final Map<JamCapability, bool> overrides = {};
}

/// How an upload body (§6.4) stopped arriving.
enum _BodyEnd {
  /// Every declared byte arrived.
  complete,

  /// Past [JamHostServer.maxUploadBytes].
  overLimit,

  /// Past the session's upload budget.
  overBudget,

  /// Too slow for [JamHostServer.uploadStallTimeout] (or silent).
  stalled,

  /// The client went away, or the body ended short of its declared length.
  aborted,

  /// The bytes could not be written to disk.
  writeFailed,
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
