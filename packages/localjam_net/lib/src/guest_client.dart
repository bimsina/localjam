/// LocalJam guest: joins a host over the WebSocket control plane, runs the
/// clock-sync schedule (PROTOCOL.md §4), mirrors the authoritative playback
/// state and playlist (§5, §6), and fetches media over the HTTP plane (§6.2).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:localjam_core/localjam_core.dart';
import 'package:meta/meta.dart';

import 'guest_errors.dart';
import 'guest_transport.dart';
import 'jam_ticker.dart';
import 'media_sink.dart';
import 'monotonic.dart';

/// Thrown when the host answers the join handshake with `reject` (§3.1) —
/// or with anything in a major protocol version this client does not speak,
/// which is the same answer ([RejectReason.version], §2). Terminal: retrying
/// the same join against the same host gets the same answer.
class JamRejectedException implements Exception {
  const JamRejectedException(this.reason, {this.hostVersions = const []});

  /// Why the host rejected the join.
  final RejectReason reason;

  /// For [RejectReason.version]: the major versions the host speaks, when it
  /// said (empty otherwise) — enough to tell "update this app" from "the
  /// host's app is the old one".
  final List<int> hostVersions;

  @override
  String toString() => 'JamRejectedException(${reason.wire})';
}

/// Kind of a [JamPeerEvent].
enum JamPeerEventKind { joined, left }

/// A presence change observed by this guest (§3.2).
@immutable
class JamPeerEvent {
  const JamPeerEvent._(this.kind, this.peerId, [this.peer]);

  /// A peer is present. Also used by the reconnect layer to replay a
  /// resumed connection's roster as presence deltas.
  JamPeerEvent.joined(PeerInfo peer)
    : this._(JamPeerEventKind.joined, peer.peerId, peer);

  /// A peer is gone.
  const JamPeerEvent.left(String peerId)
    : this._(JamPeerEventKind.left, peerId);

  final JamPeerEventKind kind;
  final String peerId;

  /// Set for [JamPeerEventKind.joined].
  final PeerInfo? peer;

  @override
  String toString() => 'JamPeerEvent(${kind.name}, $peerId)';
}

/// A LocalJam guest connected to one host session.
///
/// Created via [connect]. The guest's local clock is a process-wide monotonic
/// microsecond clock (§4); [clock] maps it onto the host's session clock.
///
/// Runs anywhere Dart has a network: it talks to the host through a
/// [JamGuestTransport] — `dart:io` natively, the browser's `WebSocket` and
/// `fetch` on the web — and never touches `dart:io` itself. The file-backed
/// conveniences (`fetchMediaToFile`, `uploadMedia`) are extension methods
/// in `package:localjam_net/localjam_net.dart`, native only; the browser
/// uses [fetchMedia] / [fetchMediaToSink] and [uploadMediaStream].
class JamGuestClient {
  JamGuestClient._(
    this._ws,
    this._transport,
    this._host,
    this._port,
    this._token,
    this._pingInterval,
    this._livenessTimeout,
    this._mediaTimeout,
    this._localClockUs,
  ) {
    _lastFrameUs = monotonicNowUs();
    _sub = _ws.frames.listen(
      _onFrame,
      onDone: _onSocketDone,
      onError: (Object _) => _onSocketDone(),
      cancelOnError: true,
    );
  }

  /// The default for `connect(livenessTimeout:)`: three ping intervals (6 s
  /// at the default 2 s). The host answers every ping (§4), so three in a row
  /// unanswered is not a slow network, it is a host that is not there.
  static Duration defaultLivenessTimeout(Duration pingInterval) =>
      pingInterval * 3;

  /// Ceiling on one `GET /artwork/{id}` response (§6.5). Embedded cover art
  /// is tens of kilobytes; 8 MB is generous for a hi-res cover and still
  /// small enough to hold in memory on a phone.
  static const int maxArtworkBytes = 8 * 1024 * 1024;

  /// How far past a playlist item's declared `sizeBytes` a media response may
  /// run before [fetchMediaToSink] abandons it. Non-zero only so a host that
  /// pads a response (a trailing newline, a re-encode that grew a few bytes)
  /// still fails on the honest sha256 check rather than on this one.
  static const int sizeSlackBytes = 64 * 1024;

  /// The default ceiling on one media body (§6.2), whatever the host
  /// declares: the same 512 MB as the reference host's cap on one upload
  /// (§9.1), so anything a guest added fits. Without it the bound on a fetch
  /// would be the host's word alone — `sizeBytes: 0` means "unknown", and a
  /// JSON number such as `1e300` decodes as an `int` under dart2js — and a
  /// host that kept sending could fill a browser tab's memory until it died.
  /// A host's own file bigger than this does not reach its guests unless
  /// the caller passes a larger `maxBytes`.
  static const int defaultMaxMediaBytes = 512 * 1024 * 1024;

  /// Reads [joinUri] in either join form (§1 Discovery) — `localjam://join?…`
  /// or the 1.2 `http://host:port/join#…` URL — through [JoinLink], tries
  /// each `host` candidate in order, performs the §3.1 handshake, and starts
  /// the §4
  /// clock-sync schedule (a burst of 8 pings [burstPingSpacing] apart, then
  /// one every [pingInterval]).
  ///
  /// Pass [resumePeerId] to resume a dropped slot within the host's grace
  /// window (§3.3); it is carried in the `hello` payload. [clientId] is this
  /// device's stable id (§3.3): the host replaces any peer still joined
  /// under it, so a client that force-quit and came back never haunts the
  /// roster as a second copy of itself.
  ///
  /// [livenessTimeout] bounds how long the connection may go without a
  /// single frame from the host before it is declared dead and closed
  /// (§3.3; default [defaultLivenessTimeout]). A host that lost power, left
  /// the network or was suspended sends no FIN, so without this the socket
  /// would look open for minutes. [mediaTimeout] bounds the media plane the
  /// same way (§6.2/§6.4): connecting, waiting for a response, and every gap
  /// between body chunks.
  ///
  /// [localClockUs] is this guest's local clock for §4 — the `t0`/`t3` of
  /// every ping and the input side of [clock] ([localNowUs],
  /// [sessionNowUs]). It defaults to the process-wide monotonic clock and
  /// should be left alone outside tools: the CLI injects a skewed one to
  /// show two terminals on one machine converging as if they were two
  /// devices. Liveness and media timeouts always run on the real clock.
  ///
  /// Throws [FormatException] if [joinUri] is neither join form,
  /// [JamRejectedException] if the host rejects the join (or speaks another
  /// major protocol version), or [JamTransportException] if no candidate
  /// host is reachable — natively a `SocketException`, as it always was.
  static Future<JamGuestClient> connect(
    Uri joinUri, {
    String clientName = 'guest',
    String clientKind = 'dart',
    List<String> caps = const ['audio'],
    Duration pingInterval = const Duration(seconds: 2),
    Duration connectTimeout = const Duration(seconds: 5),
    String? resumePeerId,
    String? clientId,
    Duration? livenessTimeout,
    Duration mediaTimeout = const Duration(seconds: 10),
    int Function()? localClockUs,
  }) async {
    final link = JoinLink.fromUri(joinUri);
    if (link == null) {
      // Not echoed: a join link carries the room's token.
      throw const FormatException('Not a LocalJam join link');
    }
    final JoinLink(:hosts, :port, :token) = link;

    Object? lastError;
    for (final host in hosts) {
      final wsUri = Uri(scheme: 'ws', host: host, port: port, path: '/ws');
      final transport = JamGuestTransport(
        timeout: mediaTimeout,
        maxConnections: maxConnectionsToHost,
      );
      final JamControlSocket ws;
      try {
        // A late upgrade is closed by the transport, not left in the host's
        // pre-hello slots; no permessage-deflate is offered where the
        // platform lets the guest choose (§1, §9.1).
        ws = await transport.connectControl(wsUri, timeout: connectTimeout);
      } catch (e) {
        transport.close();
        lastError = e; // Try the next candidate (§1: guests try in order).
        continue;
      }
      final client = JamGuestClient._(
        ws,
        transport,
        host,
        port,
        token,
        pingInterval,
        livenessTimeout ?? defaultLivenessTimeout(pingInterval),
        mediaTimeout,
        localClockUs ?? monotonicNowUs,
      );
      try {
        await client._handshake(
          clientName: clientName,
          clientKind: clientKind,
          caps: caps,
          timeout: connectTimeout,
          resumePeerId: resumePeerId,
          clientId: clientId,
        );
        return client;
      } on JamRejectedException {
        await client.close();
        rethrow; // A reject is authoritative; other candidates are the same host.
      } catch (e) {
        await client.close();
        lastError = e;
      }
    }
    throw JamTransportException(
      'Could not join via any host candidate $hosts: $lastError',
      cause: lastError,
    );
  }

  static const MessageCodec _codec = MessageCodec();

  final JamControlSocket _ws;

  /// Media, artwork and uploads share this transport, and with it a bound
  /// on connections to the host: the host caps connections per address
  /// (§9.1), and an unbounded client answered a burst of 40 cover fetches
  /// with seven `503`s. Requests past the bound wait their turn instead.
  final JamGuestTransport _transport;
  final String _host;
  final int _port;
  final String _token;
  final Duration _pingInterval;
  final Duration _livenessTimeout;
  final Duration _mediaTimeout;
  final int Function() _localClockUs;

  /// How many media-plane connections a guest opens to its host at once
  /// (§9.1): well under the host's per-address cap, with room for the
  /// control socket and a reconnect.
  static const int maxConnectionsToHost = 6;

  late final StreamSubscription<Object?> _sub;
  final Completer<void> _done = Completer<void>();
  Completer<DecodedMessage>? _handshakeCompleter;
  Timer? _pingTimer;
  final List<Timer> _burstTimers = [];
  Timer? _livenessTimer;
  int _seq = 0;
  bool _closed = false;

  /// Local monotonic µs of the last frame of any kind from the host.
  late int _lastFrameUs;
  bool _hostSilent = false;

  /// This peer's upload credential from `welcome` (§6.4).
  String? _uploadKey;

  bool _hostAway = false;
  final StreamController<bool> _hostAwayChanges =
      StreamController<bool>.broadcast();

  final ClockSync _clock = ClockSync();
  PlaybackSnapshot _snapshot = PlaybackSnapshot.initial;
  List<MediaItem> _playlist = const [];
  final Map<String, PeerInfo> _peers = {};
  PeerInfo? _hostPeer;
  SessionEndedMessage? _sessionEnded;

  /// Until the host says otherwise, assume nothing is allowed (§5.6).
  JamPermissions _permissions = const JamPermissions.initial(
    policy: JamPolicy.listenOnly,
  );
  ErrorMessage? _lastFatalError;

  final StreamController<PlaybackSnapshot> _states =
      StreamController<PlaybackSnapshot>.broadcast();
  final StreamController<List<MediaItem>> _playlists =
      StreamController<List<MediaItem>>.broadcast();
  final StreamController<JamPeerEvent> _peerEvents =
      StreamController<JamPeerEvent>.broadcast();
  final StreamController<JamPermissions> _permissionUpdates =
      StreamController<JamPermissions>.broadcast();
  final StreamController<ErrorMessage> _errors =
      StreamController<ErrorMessage>.broadcast();

  late final String _selfPeerId;
  late final String _sessionId;
  late final String _sessionName;

  /// This guest's peer id as assigned by the host (§3.1).
  String get selfPeerId => _selfPeerId;

  /// The session id from `welcome` (§3.1).
  String get sessionId => _sessionId;

  /// The session name from `welcome` (§3.1).
  String get sessionName => _sessionName;

  /// The most recent authoritative playback snapshot (§5.1). Starts at the
  /// `welcome` snapshot, so late join is just convergence.
  PlaybackSnapshot get snapshot => _snapshot;

  /// Every authoritative state broadcast after the handshake (§5.1).
  Stream<PlaybackSnapshot> get states => _states.stream;

  /// The current playlist (§6.1).
  List<MediaItem> get playlist => List.unmodifiable(_playlist);

  /// Playlist broadcasts after the handshake (§6.1).
  Stream<List<MediaItem>> get playlistUpdates => _playlists.stream;

  /// The clock-offset estimator fed by this client's ping schedule (§4).
  ClockSync get clock => _clock;

  /// Other peers currently in the session (excluding this guest).
  List<PeerInfo> get peers => List.unmodifiable(_peers.values);

  /// Presence changes (§3.2).
  Stream<JamPeerEvent> get peerEvents => _peerEvents.stream;

  /// The host as a person, from `welcome.host` (§3.1): the reserved host
  /// peer id plus its display name ("Silky Puffin"). Never a member of
  /// [peers] — the host is not a joined peer. Null when the host sent none
  /// (a host with no identity to share).
  PeerInfo? get hostPeer => _hostPeer;

  /// The `session_ended` the host sent before closing (§3.4), if any: a
  /// deliberate shutdown, which reconnect layers must treat as terminal
  /// instead of retrying against a host that is gone on purpose.
  SessionEndedMessage? get sessionEnded => _sessionEnded;

  /// The room's permission document (§5.6): from `welcome`, then every
  /// `permissions` broadcast. Listen-only until the host says otherwise.
  JamPermissions get permissions => _permissions;

  /// Permission-document broadcasts after the handshake (§5.6).
  Stream<JamPermissions> get permissionUpdates => _permissionUpdates.stream;

  /// This guest's own effective capabilities under [permissions] — what a
  /// UI enables/disables. The host re-validates every request regardless.
  Set<JamCapability> get myCapabilities =>
      _permissions.capabilitiesOf(_selfPeerId);

  /// Host error reports (§8), both transient (`not_allowed`, `media_gone`)
  /// and fatal.
  Stream<ErrorMessage> get errors => _errors.stream;

  /// The fatal error that ended (or is about to end) this connection, if
  /// any — e.g. `kicked` (§5.6), which reconnect layers must treat as
  /// terminal instead of retrying.
  ErrorMessage? get lastFatalError => _lastFatalError;

  /// Completes when the WebSocket to the host closes for any reason — host
  /// shutdown, a drop, the liveness watchdog ([hostSilent]), or a local
  /// [close]. Completes exactly once and never errors.
  Future<void> get done => _done.future;

  /// Whether this connection was closed by the liveness watchdog: nothing
  /// arrived from the host for `livenessTimeout` (§3.3). The host may be
  /// dead, out of range, or asleep — see [hostAway] for which one it said.
  bool get hostSilent => _hostSilent;

  /// Whether the host announced it is away (§3.5): from `welcome`, then
  /// every `host_status`. A host that is away is expected to go quiet —
  /// its phone is asleep — so a reconnect layer should wait much longer
  /// before calling it gone. Keeps its last value after the connection ends.
  bool get hostAway => _hostAway;

  /// Changes to [hostAway] after the handshake (§3.5).
  Stream<bool> get hostAwayChanges => _hostAwayChanges.stream;

  /// This peer's upload credential (§6.4), from `welcome`. [uploadMedia]
  /// presents it; exposed for tests and diagnostics only.
  @visibleForTesting
  String? get uploadKey => _uploadKey;

  /// This guest's local clock (µs, arbitrary epoch) — the `t0`/`t3` timebase
  /// of §4 and the input side of [clock]. The process-wide monotonic clock
  /// unless `connect(localClockUs:)` said otherwise.
  int get localNowUs => _localClockUs();

  /// The current session-clock time (host monotonic µs), i.e.
  /// `clock.localToHostUs(localNowUs)`.
  ///
  /// Throws [StateError] before [ClockSync.isSynchronized].
  int get sessionNowUs => _clock.localToHostUs(_localClockUs());

  // --- Handshake (§3.1) --------------------------------------------------------

  Future<void> _handshake({
    required String clientName,
    required String clientKind,
    required List<String> caps,
    required Duration timeout,
    String? resumePeerId,
    String? clientId,
  }) async {
    final completer = Completer<DecodedMessage>();
    _handshakeCompleter = completer;
    _send(
      HelloMessage(
        token: _token,
        clientName: clientName,
        clientKind: clientKind,
        caps: caps,
        resumePeerId: resumePeerId,
        clientId: clientId,
      ),
    );
    final decoded = await completer.future.timeout(timeout);
    _handshakeCompleter = null;
    final reply = decoded.message;
    if (!decoded.isSupportedVersion) {
      // §2: whatever the host answered — a version reject echoing our `v`
      // would decode as supported — it answered in a major version this
      // client cannot read. That is a version mismatch, and final.
      final versions = reply.payloadToJson()['versions'];
      throw JamRejectedException(
        RejectReason.version,
        hostVersions: {
          decoded.v,
          if (versions is List) ...versions.whereType<int>(),
        }.toList(),
      );
    }
    switch (reply) {
      case WelcomeMessage():
        break; // Already applied by [_onFrame] — see [_applyWelcome].
      case RejectMessage(:final reason, :final versions):
        throw JamRejectedException(reason, hostVersions: versions);
      default:
        throw StateError('Unexpected handshake reply: ${reply.type}');
    }
  }

  /// Adopts the `welcome` (§3.1) the moment it is received — synchronously,
  /// in the frame handler, not in [_handshake]'s continuation. A host may
  /// send its next broadcast (a `state`, a `playlist`, a `host_status`) right
  /// behind the welcome, and frames are handled as they arrive: applying the
  /// welcome any later would overwrite those newer values with older ones.
  void _applyWelcome(WelcomeMessage welcome) {
    _selfPeerId = welcome.selfPeerId;
    _sessionId = welcome.sessionId;
    _sessionName = welcome.sessionName;
    _snapshot = welcome.snapshot;
    _playlist = welcome.playlist;
    final permissions = welcome.permissions;
    if (permissions != null) _permissions = permissions;
    _hostPeer = welcome.host;
    _uploadKey = welcome.uploadKey;
    _hostAway = welcome.hostAway;
    for (final peer in welcome.peers) {
      _peers[peer.peerId] = peer;
    }
    _startClockSchedule();
    _startLivenessWatchdog();
  }

  // --- Liveness (§3.3) -----------------------------------------------------------

  /// The guest half of §3.3: the host answers every ping, so a connection
  /// that has heard nothing at all — no pong, no broadcast — for
  /// [_livenessTimeout] is dead, whatever the socket claims. A host that
  /// lost power, walked out of range or had its Wi-Fi switched off sends no
  /// FIN; without this, the guest would sit "connected" to nothing until TCP
  /// gave up minutes later, and every reconnect and host-gone timeout above
  /// it would only start then.
  void _startLivenessWatchdog() {
    final check = _livenessTimeout ~/ 6;
    // From [JamTicker], like the ping schedule: in a background browser tab
    // a throttled check would declare the host dead a minute late — or, its
    // pongs throttled with it, call a live host dead.
    _livenessTimer = JamTicker.periodic(
      check < const Duration(milliseconds: 50)
          ? const Duration(milliseconds: 50)
          : check > const Duration(seconds: 1)
          ? const Duration(seconds: 1)
          : check,
      (_) {
        if (_closed) return;
        final silentUs = monotonicNowUs() - _lastFrameUs;
        if (silentUs <= _livenessTimeout.inMicroseconds) return;
        _hostSilent = true;
        // Report the death now; the close handshake with a host that is not
        // there would only add the socket's own close timeout to it.
        if (!_done.isCompleted) _done.complete();
        unawaited(close());
      },
    );
  }

  // --- Clock schedule (§4) -------------------------------------------------------

  /// How far apart the 8 join-burst pings go out (§4).
  ///
  /// Spaced, not back to back: eight pings sent in one go share one Wi-Fi
  /// wake-up and one queue, so they all see the same delay — the burst then
  /// offers the min-RTT filter eight copies of one sample. Spread over
  /// 700 ms they sample the link at different moments, and the first
  /// minute's worst offset error (simulated, good Wi-Fi) drops from ~109 ms
  /// to under a millisecond.
  static const Duration burstPingSpacing = Duration(milliseconds: 100);

  void _startClockSchedule() {
    // Burst of 8 pings at join; the estimator keeps the min-RTT sample.
    _startBurst();
    // Steady state: one ping every 2 s (also our liveness heartbeat, §3.3),
    // from [JamTicker] — in a browser a worker, since a background tab
    // throttles its own timers to one a minute and the host drops a peer
    // after 10 s of silence.
    _pingTimer = JamTicker.periodic(_pingInterval, (_) => _sendPing());
  }

  /// Sends a fresh §4 burst now — 8 pings [burstPingSpacing] apart, on top
  /// of the steady schedule — for when this guest has reason to distrust
  /// its clock mapping: it just woke from a device sleep, or the network
  /// changed under it. The steady schedule alone takes ~16 s to re-gather
  /// what a burst gathers in under one. Restarts a burst already running.
  ///
  /// A clock discontinuity that [ClockSync] detects on its own (it resets
  /// and [ClockSync.isSynchronized] goes false) triggers one automatically.
  void resyncClock() {
    if (_closed) return;
    _startBurst();
  }

  void _startBurst() {
    for (final timer in _burstTimers) {
      timer.cancel();
    }
    _burstTimers.clear();
    _sendPing();
    for (var i = 1; i < 8; i++) {
      _burstTimers.add(JamTicker.after(burstPingSpacing * i, _sendPing));
    }
  }

  void _sendPing() {
    if (_closed) return;
    _send(ClockPingMessage(t0: _localClockUs()));
  }

  // --- Incoming frames -------------------------------------------------------------

  void _onFrame(Object? data) {
    final t3 = _localClockUs(); // §4: t3 = local receive time.
    // Any frame at all proves the host is there (§3.3) — measured on the
    // real clock, whatever [_localClockUs] is.
    _lastFrameUs = monotonicNowUs();
    if (data is! String) return;
    final DecodedMessage decoded;
    try {
      decoded = _codec.decode(data);
    } on ProtocolException {
      return; // Malformed frame: ignore.
    }
    final message = decoded.message;

    final handshake = _handshakeCompleter;
    if (handshake != null &&
        (!decoded.isSupportedVersion ||
            message is WelcomeMessage ||
            message is RejectMessage)) {
      // Exactly one handshake reply counts; a second welcome is ignored.
      _handshakeCompleter = null;
      if (handshake.isCompleted) return;
      if (decoded.isSupportedVersion && message is WelcomeMessage) {
        _applyWelcome(message);
      }
      handshake.complete(decoded);
      return;
    }
    if (!decoded.isSupportedVersion) return; // Not ours to read (§2).

    switch (message) {
      case ClockPongMessage(:final t0, :final t1, :final t2):
        final wasSynchronized = _clock.isSynchronized;
        _clock.addSample(ClockSample(t0: t0, t1: t1, t2: t2, t3: t3));
        // A discontinuity reset the estimator (§4): re-gather a burst now
        // instead of waiting out the steady schedule.
        if (wasSynchronized && !_clock.isSynchronized) _startBurst();
      case StateMessage(:final snapshot):
        _snapshot = snapshot;
        if (!_states.isClosed) _states.add(snapshot);
      case PlaylistMessage(:final items):
        _playlist = items;
        if (!_playlists.isClosed) _playlists.add(playlist);
      case PeerJoinedMessage(:final peer):
        _peers[peer.peerId] = peer;
        if (!_peerEvents.isClosed) {
          _peerEvents.add(
            JamPeerEvent._(JamPeerEventKind.joined, peer.peerId, peer),
          );
        }
      case PeerLeftMessage(:final peerId):
        _peers.remove(peerId);
        if (!_peerEvents.isClosed) {
          _peerEvents.add(JamPeerEvent._(JamPeerEventKind.left, peerId));
        }
      case PermissionsMessage(:final permissions):
        // §5.6: keep the highest rev (broadcasts can race a resume welcome).
        if (permissions.rev >= _permissions.rev) {
          _permissions = permissions;
          if (!_permissionUpdates.isClosed) {
            _permissionUpdates.add(permissions);
          }
        }
      case SessionEndedMessage():
        // §3.4: the host ended the room on purpose. Remember it so the
        // reconnect layer knows this close is not a drop to retry.
        _sessionEnded = message;
      case HostStatusMessage(:final away):
        // §3.5: the host is about to nap (or is back).
        if (away != _hostAway) {
          _hostAway = away;
          if (!_hostAwayChanges.isClosed) _hostAwayChanges.add(away);
        }
      case ErrorMessage():
        // §8: fatal errors are followed by a host-side close; remember the
        // reason so reconnect layers can tell a kick from a plain drop.
        if (message.fatal) _lastFatalError = message;
        if (!_errors.isClosed) _errors.add(message);
      default:
        break; // unknown: ignored (§2).
    }
  }

  void _onSocketDone() {
    final handshake = _handshakeCompleter;
    if (handshake != null && !handshake.isCompleted) {
      handshake.completeError(
        const JamTransportException('Connection closed during handshake'),
      );
    }
    if (!_done.isCompleted) _done.complete();
    unawaited(close());
  }

  // --- Requests (§5.2) ----------------------------------------------------------

  /// Asks the host to start playback (§5.2).
  Future<void> requestPlay() async =>
      _send(const RequestMessage(action: RequestAction.play));

  /// Asks the host to pause playback (§5.2).
  Future<void> requestPause() async =>
      _send(const RequestMessage(action: RequestAction.pause));

  /// Asks the host to seek to [positionUs] (§5.2).
  Future<void> requestSeek(int positionUs) async =>
      _send(RequestMessage(action: RequestAction.seek, positionUs: positionUs));

  /// Asks the host to select [mediaId] (§5.2): a playing room plays it from
  /// its start, a paused one cues it, and the current item stays as it is.
  Future<void> requestSetMedia(String mediaId) async =>
      _send(RequestMessage(action: RequestAction.setMedia, mediaId: mediaId));

  /// Asks the host to skip to the next queue item (§5.2).
  Future<void> requestNext() async =>
      _send(const RequestMessage(action: RequestAction.next));

  /// Asks the host to skip to the previous queue item (§5.2).
  Future<void> requestPrevious() async =>
      _send(const RequestMessage(action: RequestAction.previous));

  /// Asks the host to move [mediaId] to queue position [toIndex] (§5.6).
  Future<void> requestQueueMove(String mediaId, int toIndex) async => _send(
    RequestMessage(
      action: RequestAction.queueMove,
      mediaId: mediaId,
      toIndex: toIndex,
    ),
  );

  /// Asks the host to remove [mediaId] from the queue (§5.6). Removing your
  /// own contribution is always allowed; others' need
  /// [JamCapability.editQueue].
  Future<void> requestQueueRemove(String mediaId) async => _send(
    RequestMessage(action: RequestAction.queueRemove, mediaId: mediaId),
  );

  // --- Media plane (§6.2, §6.3) ----------------------------------------------------

  /// Sends a §6.3 `media_status` report directly, without an in-flight
  /// fetch — e.g. a cache hit, where the guest already possesses the file
  /// and never touches the network for it. [fetchMediaToSink]/[fetchMedia]
  /// send their own reports as a fetch progresses; this is the public door
  /// for callers (the prefetch pipeline) that resolve readiness some other
  /// way.
  ///
  /// Permissive by design: [mediaId] need not be in the current playlist
  /// (mirrors the wire protocol itself, which carries no such constraint —
  /// the host just records readiness per (peer, mediaId) and a report for
  /// an id it doesn't yet know about is simply inert until that id shows up
  /// in a playlist). Silently dropped if the socket isn't open, exactly like
  /// every other outgoing message on this client (see [_send]) — a report
  /// that arrives too late to matter is not worth surfacing as an error.
  void sendMediaStatus(
    String mediaId,
    MediaFetchState state, {
    double? progress,
  }) {
    _send(
      MediaStatusMessage(mediaId: mediaId, state: state, progress: progress),
    );
  }

  /// Fetches `GET /media/{mediaId}` with Bearer auth (§6.2), streaming the
  /// body into [sink] while hashing incrementally — the body is never held
  /// in memory unless the sink holds it. Reports `media_status` upstream
  /// (§6.3): `fetching` with progress while downloading, `ready` once the
  /// sha256 digest matches the playlist entry. The sink sees the order its
  /// docs promise ([JamMediaSink]): opened only after a `200`, closed always,
  /// abandoned before `none` is reported.
  ///
  /// The transfer is also bounded by the size the host gave for it: the
  /// playlist entry's `sizeBytes` — or, when that is 0 (unknown) or past
  /// [maxBytes], the response's `Content-Length` — plus [sizeSlackBytes],
  /// and never more than [maxBytes] (default [defaultMaxMediaBytes]), which
  /// is also the bound when the host gave neither. A host that keeps sending past
  /// that is either broken or hostile, and either way the guest stops taking
  /// bytes instead of filling the device's disk (or a tab's memory). The
  /// digest check alone is too late — it only fires once the whole body has
  /// landed.
  ///
  /// [onProgress] receives values in [0, 1]. Throws [ArgumentError] if
  /// [mediaId] is not in the current playlist, [JamHttpStatusException] on a
  /// non-200 response (natively an `HttpException`), [TimeoutException] when
  /// the host stops answering (no connection, no response, or no body bytes
  /// within `mediaTimeout` — a host that died mid-transfer must not hang the
  /// fetch forever), [StateError] on a digest mismatch or an over-size body,
  /// and the platform's connection error when the connection breaks
  /// ([JamTransportException] in a browser; `dart:io`'s `SocketException` or
  /// `HttpException` natively). A stall, an over-size body and a digest
  /// mismatch abandon the sink and report `media_status: none`, and so do a
  /// connection that breaks mid-body and a sink whose [JamMediaSink.open] or
  /// [JamMediaSink.close] throws (a full disk): that error propagates after
  /// the report, so the host's §6.3 gate never waits on a fetch that ended.
  ///
  /// With [reportReady] false the verified body is NOT reported `ready`:
  /// the caller reports it once the bytes are usable, which is later than
  /// "they arrived" for a guest that must decode first (§3.1: a browser
  /// guest reports `ready` only once an item has decoded). Everything else
  /// — `fetching` with progress, `none` on failure — is reported as usual.
  Future<void> fetchMediaToSink(
    String mediaId,
    JamMediaSink sink, {
    void Function(double progress)? onProgress,
    bool reportReady = true,
    int maxBytes = defaultMaxMediaBytes,
  }) async {
    final item = _playlist.firstWhere(
      (i) => i.mediaId == mediaId,
      orElse: () => throw ArgumentError.value(
        mediaId,
        'mediaId',
        'not in the current playlist',
      ),
    );
    final uri = Uri(
      scheme: 'http',
      host: _host,
      port: _port,
      path: '/media/$mediaId',
    );
    final response = await _get(uri);
    if (response.statusCode != _httpOk) {
      await _discard(response);
      throw JamHttpStatusException(
        response.statusCode,
        'GET $uri failed with ${response.statusCode}',
        uri: uri,
      );
    }

    _send(
      MediaStatusMessage(
        mediaId: mediaId,
        state: MediaFetchState.fetching,
        progress: 0,
      ),
    );
    // The host's two words for the size, each only when it is one: zero or
    // less is "unknown", and so is more than [maxBytes] (§6.1's `sizeBytes`
    // is a JSON number, and dart2js takes `1e300` for an int).
    int given(int size) => size > 0 && size <= maxBytes ? size : 0;
    final declared = given(item.sizeBytes);
    final framed = given(response.contentLength);
    // The playlist's size is the item's (its sha256 is of exactly that
    // many bytes), so it wins when there is one; the response's framing
    // stands in when there is not, and [maxBytes] when neither is given.
    final total = declared > 0 ? declared : framed;
    final limit = total > 0 ? min(total + sizeSlackBytes, maxBytes) : maxBytes;
    final digestSink = _DigestSink();
    final hasher = sha256.startChunkedConversion(digestSink);
    try {
      await sink.open();
    } catch (e, trace) {
      // `fetching` has been reported: the host's §6.3 gate counts this guest
      // in until it hears otherwise. The sink gets its `close` (always) and
      // its `abandon` (a failure) like any failed transfer.
      response.abort();
      try {
        await sink.close();
      } catch (_) {}
      await _abandonFetch(mediaId, sink);
      Error.throwWithStackTrace(e, trace);
    }
    var received = 0;
    var lastReported = 0.0;
    var overSize = false;
    Object? stalled;
    Object? broken;
    StackTrace? brokenTrace;
    try {
      await for (final chunk in _idleBounded(response)) {
        if (received + chunk.length > limit) {
          overSize = true;
          break;
        }
        hasher.add(chunk);
        sink.add(chunk);
        received += chunk.length;
        final progress = total > 0 ? (received / total).clamp(0.0, 1.0) : 0.0;
        onProgress?.call(progress);
        // Throttle upstream progress reports to quarter steps (§6.3 is for
        // host UX, not telemetry).
        if (progress - lastReported >= 0.25 && progress < 1.0) {
          lastReported = progress;
          _send(
            MediaStatusMessage(
              mediaId: mediaId,
              state: MediaFetchState.fetching,
              progress: progress,
            ),
          );
        }
      }
    } on TimeoutException catch (e) {
      stalled = e;
    } catch (e, trace) {
      // The connection broke mid-body: what arrived is a fragment.
      broken = e;
      brokenTrace = trace;
    }
    try {
      await sink.close();
    } catch (e, trace) {
      // A sink that cannot flush (a native file on a full disk) holds no
      // usable body, however the transfer went; report it as a break unless
      // something already broke first.
      if (broken == null && stalled == null) {
        broken = e;
        brokenTrace = trace;
      }
    }
    hasher.close();

    if (broken != null) {
      // §6.2: a fragment is not possession. Discard it and say so, or the
      // host's readiness view keeps this guest at `fetching` until the next
      // report (§6.3 gate: a guest that gave up counts as `none`).
      await _abandonFetch(mediaId, sink);
      Error.throwWithStackTrace(broken, brokenTrace!);
    }

    if (stalled != null) {
      // The error ended the `await for`, which cancelled the response and
      // with it the connection.
      await _abandonFetch(mediaId, sink);
      throw stalled;
    }

    if (overSize) {
      // Breaking out of the `await for` above already cancelled the response
      // subscription, which tears the connection down: nothing more arrives.
      await _abandonFetch(mediaId, sink);
      throw StateError(
        'media $mediaId exceeded its declared size: $limit bytes at most '
        '(sizeBytes ${item.sizeBytes}, Content-Length '
        '${response.contentLength})',
      );
    }

    // §6.2: sha256 verifies the transfer (and enables cross-session caching).
    final digest = digestSink.value!.toString();
    if (item.sha256.isNotEmpty && digest != item.sha256) {
      await _abandonFetch(mediaId, sink);
      throw StateError(
        'sha256 mismatch for $mediaId: expected ${item.sha256}, got $digest',
      );
    }
    onProgress?.call(1.0);
    if (reportReady) {
      _send(MediaStatusMessage(mediaId: mediaId, state: MediaFetchState.ready));
    }
  }

  /// Fetches `GET /media/{mediaId}` into memory (§6.2), reporting
  /// `media_status` upstream (§6.3): `fetching` with progress while
  /// downloading, `ready` once the sha256 digest matches the playlist entry.
  ///
  /// [fetchMediaToSink] with a [JamBytesMediaSink]: the whole body is held
  /// in memory (bounded by the item's declared size), which is what a
  /// browser wants (§6.2 full prefetch, no file system). Natively, prefer
  /// `fetchMediaToFile` for anything large.
  ///
  /// [onProgress] receives values in [0, 1]. Throws as [fetchMediaToSink]
  /// does: [ArgumentError] if [mediaId] is not in the current playlist,
  /// [JamHttpStatusException] on a non-200 response, [TimeoutException] on a
  /// stall, and [StateError] on a digest mismatch (after reporting
  /// `media_status: none`).
  Future<Uint8List> fetchMedia(
    String mediaId, {
    void Function(double progress)? onProgress,
  }) async {
    final sink = JamBytesMediaSink();
    await fetchMediaToSink(mediaId, sink, onProgress: onProgress);
    return sink.takeBytes();
  }

  /// Discards what [sink] received and tells the host this guest no longer
  /// holds [mediaId] (§6.3) — the shared tail of every failed fetch.
  Future<void> _abandonFetch(String mediaId, JamMediaSink sink) async {
    try {
      await sink.abandon();
    } catch (_) {
      // Nothing to undo, or nothing we can: the report matters more.
    }
    _send(MediaStatusMessage(mediaId: mediaId, state: MediaFetchState.none));
  }

  /// Fetches `GET /artwork/{artworkId}` with Bearer auth (§6.5) into memory.
  /// Artwork is small (an embedded cover), so no streaming/progress plumbing.
  ///
  /// Capped at [maxArtworkBytes]: artwork is the one response a guest holds
  /// whole in memory, and its size is asserted by the host alone (no
  /// playlist entry declares it), so an over-cap body is abandoned mid-stream
  /// rather than grown until the app dies.
  ///
  /// Throws [JamHttpStatusException] on a non-200 response (404 for an
  /// unknown id), [TimeoutException] when the host stops answering, and
  /// [StateError] when the body exceeds [maxArtworkBytes].
  Future<Uint8List> fetchArtwork(String artworkId) async {
    final uri = Uri(
      scheme: 'http',
      host: _host,
      port: _port,
      path: '/artwork/$artworkId',
    );
    final response = await _get(uri);
    if (response.statusCode != _httpOk) {
      await _discard(response);
      throw JamHttpStatusException(
        response.statusCode,
        'GET $uri failed with ${response.statusCode}',
        uri: uri,
      );
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in _idleBounded(response)) {
      if (builder.length + chunk.length > maxArtworkBytes) {
        builder.clear();
        throw StateError(
          'artwork $artworkId exceeds the $maxArtworkBytes byte cap',
        );
      }
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  /// Uploads [length] bytes from [body] to the host over the media plane
  /// (`POST /media`, §6.4) as [name]. Metadata travels in `X-LocalJam-*`
  /// headers; the host computes the sha256 and mediaId itself, adds the
  /// item to the playlist, and broadcasts it. Natively `uploadMedia` wraps
  /// this for a file, streaming it from disk; in a browser, pass the picked
  /// file's bytes (it is sent as one body there, see
  /// [JamGuestTransport.post]).
  ///
  /// [name] is sent percent-encoded (§6.4). [onProgress] receives values in
  /// [0, 1] as body bytes are handed to the connection (natively, per
  /// chunk; in a browser, once, when the host answers).
  ///
  /// The request carries this peer's upload key from `welcome` (§6.4) —
  /// it is what tells the host who is uploading, and so whether they may.
  ///
  /// Returns the host's [MediaItem] — the newly added item (201; also
  /// content the room had but that was removed from the queue, now back in
  /// it and credited to this peer), or the queued item when this content is
  /// already in the queue (200, idempotent). Throws
  /// [JamHttpStatusException] (natively an `HttpException`) on any other
  /// response — 401 bad token, 403 not allowed to add tracks (or no longer
  /// in the room by the time the body arrived), 429 too many uploads in
  /// flight, 507 the room's budget is spent, ... (§6.4) — and
  /// [TimeoutException] when the host stops reading the body or never
  /// answers it (a host that died mid-upload must not hang it forever).
  ///
  /// The status arrives once the body has been sent: the host reads a
  /// refused body to its end so it can say why, but only up to
  /// `JamHostServer.refusedUploadDrainBytes` (64 MB) and for a bounded
  /// time. A refusal of a larger or slower body — a 413 always is one, and
  /// a 408 usually — ends the upload with the connection error the host's
  /// cut-off causes (natively a `SocketException` or a status-less
  /// `HttpException`; in a browser a [JamTransportException]).
  Future<MediaItem> uploadMediaStream(
    Stream<List<int>> body, {
    required int length,
    required String name,
    required MediaKind kind,
    String mime = 'application/octet-stream',
    int? durationUs,
    void Function(double progress)? onProgress,
  }) async {
    final uri = Uri(scheme: 'http', host: _host, port: _port, path: '/media');
    final uploadKey = _uploadKey;
    final response = await _transport.post(
      uri,
      headers: {
        'authorization': 'Bearer $_token',
        uploadKeyHeader: ?uploadKey,
        'X-LocalJam-Kind': kind.wire,
        'X-LocalJam-Name': Uri.encodeComponent(name),
        'X-LocalJam-Mime': mime,
        if (durationUs != null) 'X-LocalJam-Duration-Us': '$durationUs',
        'content-type': 'application/octet-stream',
      },
      contentLength: length,
      body: body,
      // The host hashes as it receives, then reads tags and stores the file
      // before it answers (§6.4): allow it a while, not forever.
      responseTimeout: _mediaTimeout * 6,
      onSent: onProgress == null
          ? null
          : (sent) =>
                onProgress(length > 0 ? (sent / length).clamp(0.0, 1.0) : 1.0),
    );
    final String text;
    try {
      text = await utf8.decodeStream(_idleBounded(response));
    } on TimeoutException {
      response.abort();
      rethrow;
    }
    if (response.statusCode != _httpCreated && response.statusCode != _httpOk) {
      throw JamHttpStatusException(
        response.statusCode,
        'POST $uri failed with ${response.statusCode}',
        uri: uri,
      );
    }
    return MediaItem.fromJson(jsonDecode(text) as Map<String, Object?>);
  }

  /// The request header carrying this peer's upload key (§6.4).
  static const String uploadKeyHeader = 'X-LocalJam-Upload-Key';

  static const int _httpOk = 200;
  static const int _httpCreated = 201;

  /// `GET [uri]` with Bearer auth, bounded by `mediaTimeout` from connect to
  /// response headers (the transport's own bound).
  Future<JamMediaResponse> _get(Uri uri) =>
      _transport.get(uri, headers: {'authorization': 'Bearer $_token'});

  /// [response]'s body, failing with a [TimeoutException] when the host
  /// goes quiet for `mediaTimeout` between chunks — a dead host never closes
  /// the stream on its own.
  Stream<List<int>> _idleBounded(JamMediaResponse response) =>
      response.body.timeout(_mediaTimeout);

  /// Drains an unwanted response body, without waiting on a host that has
  /// stopped sending it.
  Future<void> _discard(JamMediaResponse response) async {
    try {
      await _idleBounded(response).drain<void>();
    } catch (_) {}
  }

  // --- Teardown ------------------------------------------------------------------

  /// Closes the control socket and all streams. Idempotent.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _pingTimer?.cancel();
    for (final timer in _burstTimers) {
      timer.cancel();
    }
    _livenessTimer?.cancel();
    await _sub.cancel();
    try {
      // Bounded: against a host that is not there, the close handshake can
      // only end in the socket's own timeout.
      await _ws
          .close(JamCloseCode.normalClosure)
          .timeout(const Duration(seconds: 1));
    } catch (_) {}
    if (!_done.isCompleted) _done.complete();
    _transport.close();
    await _states.close();
    await _playlists.close();
    await _peerEvents.close();
    await _permissionUpdates.close();
    await _errors.close();
    await _hostAwayChanges.close();
  }

  // --- Wire helper -----------------------------------------------------------------

  void _send(Message message) {
    if (_closed || !_ws.isOpen) return;
    try {
      _ws.send(_codec.encode(message, seq: _seq++));
    } on StateError {
      // Sink closed underneath us mid-teardown; close() handles the rest.
    }
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
