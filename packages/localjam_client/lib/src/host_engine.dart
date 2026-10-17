/// The whole host side of a jam behind one object: a [JamHostServer] plus
/// local synchronized playback, so the host hears its own jam through the
/// same [AudioSyncController] a guest uses — with the identity session→local
/// clock mapping, because the host's monotonic clock IS the session clock
/// (PROTOCOL.md §4).
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:localjam_audio/localjam_audio.dart';
import 'package:localjam_net/localjam_net.dart';

import 'audio_sync_controller.dart';
import 'jam_discovery.dart';
import 'jam_engine.dart';
import 'jam_identity.dart';
import 'media_mime.dart';

/// One hosted session: server + registry + local playback.
///
/// Create with [start]; add tracks with [addMediaFile]; drive the transport
/// with [play]/[pause]/[seek]/[setMedia]/[stop]/[next]/[previous]; release
/// with [close].
class JamHostEngine extends JamEngine {
  JamHostEngine._(this._server, this.joinUri) {
    sync = AudioSyncController(
      player: player,
      sessionNowUs: monotonicNowUs,
      localNowUs: monotonicNowUs,
      sessionToLocalUs: (sessionUs) => sessionUs,
      resolveMediaPath: (mediaId) async => _mediaPaths[mediaId],
    );
    _eventsSub = _server.events.listen(_onHostEvent);
  }

  /// Starts a [JamHostServer] for [sessionName] and the host's own playback
  /// engine.
  ///
  /// Binds [port] (default: ephemeral) on [address], or — when no address is
  /// given — on whatever reaches every guest without ever serving the
  /// internet (§9). The IPv4 interfaces are enumerated and the
  /// private/link-local ones kept ([JamHostServer.isLanAddress]); a device
  /// with any LAN at all binds `anyIPv4`, because one [HttpServer] binds one
  /// address and a room has to be reachable both across the LAN and on the
  /// machine itself (two simulators, two emulators, the CLI beside the app).
  /// §9 is then carried by the server's own remote-address filter
  /// ([JamHostServer.restrictToLanRemotes], on by default), which refuses
  /// every off-LAN request on both planes. With no LAN interface at all the
  /// host binds loopback and is a room of one — see [bindAddressFor].
  ///
  /// [endPolicy] is applied when the current item reaches its end (§5.5); the
  /// engine defaults to advancing through the playlist.
  ///
  /// [maxPeers], [maxUploadBytes], [uploadBudgetBytes] and
  /// [maxPlaylistLength] forward the server's room-size and guest-upload
  /// caps (§6.4) so a host UI can offer a smaller room or a tighter disk
  /// budget than the defaults.
  ///
  /// Advertising, identity, the saved nudge and the OS session guards are all
  /// best-effort and time-boxed; a room appears even when every one of them
  /// is unavailable.
  ///
  /// With [discoverable] (the default) the room is advertised over mDNS so
  /// nearby devices list it for one-tap join — which means ANYONE on the
  /// network can join without the QR (the advertisement carries the token,
  /// §1/§9). Pass false for invite-only rooms. Best-effort: platforms
  /// without mDNS just stay QR-only.
  ///
  /// [hostName] is how guests see the person hosting — in the room roster and
  /// in "added by" bylines. It defaults to this device's persistent
  /// [JamIdentity.displayName] ("Silky Puffin"), the same identity a guest
  /// announces, so the host is a person in the room rather than the word
  /// "Host". Pass an empty string to host anonymously.
  static Future<JamHostEngine> start({
    required String sessionName,
    String? hostName,
    JamEndPolicy endPolicy = JamEndPolicy.advance,
    JamPolicy policy = JamPolicy.jam,
    bool discoverable = true,
    int port = 0,
    InternetAddress? address,
    int maxPeers = JamHostServer.defaultMaxPeers,
    int maxUploadBytes = JamHostServer.defaultMaxUploadBytes,
    int uploadBudgetBytes = JamHostServer.defaultUploadBudgetBytes,
    int maxPlaylistLength = JamHostServer.defaultMaxPlaylistLength,
  }) async {
    // Nothing on the way to a room may be unbounded: every step below either
    // finishes inside its own budget or is abandoned for a working fallback,
    // so start() returns in well under two seconds on every platform —
    // including one whose prefs, interface list or mDNS stack has stopped
    // answering. Only the socket bind is allowed to fail the call: a host
    // without a server is not a host.
    final displayName =
        hostName ??
        await _bounded<String>(
          JamIdentity.displayName(),
          _identityBudget,
          () => generateJamName(),
        );
    final server = JamHostServer(
      sessionName: sessionName,
      hostName: displayName,
      hostKind: 'flutter',
      endPolicy: endPolicy,
      policy: policy,
      maxPeers: maxPeers,
      maxUploadBytes: maxUploadBytes,
      uploadBudgetBytes: uploadBudgetBytes,
      maxPlaylistLength: maxPlaylistLength,
    );
    final scan = await _scanLan();
    try {
      await server.start(
        address:
            address ??
            bindAddressFor(scan.addresses, enumerated: scan.enumerated),
        port: port,
      );
      final joinUri = _buildCombinedJoinUri(server, scan.addresses);
      final engine = JamHostEngine._(server, joinUri);
      // Neither the saved nudge nor the OS-level guards are worth a room:
      // both are bounded and both are allowed to fail.
      await _bounded<void>(engine.restorePersistedNudge(), _guardBudget, () {});
      await _bounded<void>(engine.startSessionGuards(), _guardBudget, () {});
      if (discoverable) {
        final advertiser = await _bounded<JamRoomAdvertiser?>(
          roomAdvertiserStarter(
            sessionName: sessionName,
            port: server.port,
            token: server.token,
            addresses: scan.addresses,
            timeout: _advertiseBudget,
          ),
          // The outer bound has to cover BOTH responders, or a daemon that
          // eats its whole slice would take the fallback down with it.
          JamRoomAdvertiser.totalTimeout,
          () => null,
        );
        // The room may already be over by the time mDNS answered.
        if (engine._closed) {
          await advertiser?.stop();
        } else {
          engine._advertiser = advertiser;
        }
      }
      // Preload whatever the (idle) snapshot says — a no-op until setMedia.
      unawaited(engine.sync.onSnapshot(server.snapshot));
      return engine;
    } catch (_) {
      await server.close();
      rethrow;
    }
  }

  /// Time each optional step of [start] is given before the fallback wins.
  static const Duration _identityBudget = Duration(milliseconds: 400);
  static const Duration _lanScanBudget = Duration(milliseconds: 400);
  static const Duration _guardBudget = Duration(milliseconds: 500);

  /// The Bonjour daemon's own slice; [JamRoomAdvertiser.totalTimeout] is the
  /// whole step, daemon plus built-in-responder fallback.
  static const Duration _advertiseBudget = JamRoomAdvertiser.defaultTimeout;

  /// [future] with a deadline: on timeout OR on error the [fallback] value is
  /// used and the room still happens. A timed-out future is abandoned, not
  /// cancelled — Dart cannot cancel one — so its own error, if it ever
  /// arrives, is swallowed rather than left to reach the zone.
  static Future<T> _bounded<T>(
    Future<T> future,
    Duration budget,
    T Function() fallback,
  ) async {
    // The abandoned future keeps running — Dart cannot cancel one — so it is
    // given a listener of its own; without it a late failure would surface as
    // an unhandled error long after the room opened.
    unawaited(future.then((_) {}, onError: (Object _) {}));
    try {
      return await future.timeout(budget);
    } catch (error) {
      debugPrint('localjam: host start step gave up after $budget ($error)');
      return fallback();
    }
  }

  /// Starts the room advertisement. A seam so tests can make advertising
  /// hang, fail, or succeed without an mDNS stack.
  @visibleForTesting
  static Future<JamRoomAdvertiser?> Function({
    required String sessionName,
    required int port,
    required String token,
    List<InternetAddress> addresses,
    Duration timeout,
  })
  roomAdvertiserStarter = JamRoomAdvertiser.start;

  /// Enumerates the device's network interfaces. A seam so tests can make
  /// enumeration slow, huge, or broken.
  @visibleForTesting
  static Future<List<NetworkInterface>> Function() networkInterfaceLister =
      defaultNetworkInterfaceLister;

  /// The real enumeration, and what [networkInterfaceLister] must be put back
  /// to after a test replaces it.
  @visibleForTesting
  static Future<List<NetworkInterface>> defaultNetworkInterfaceLister() =>
      NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );

  /// The LAN scan plus whether it actually finished: a device whose interface
  /// list is slow or refused is NOT a device without a LAN, and must not be
  /// demoted to a loopback room of one.
  static Future<({List<InternetAddress> addresses, bool enumerated})>
  _scanLan() async {
    try {
      final interfaces = await networkInterfaceLister().timeout(_lanScanBudget);
      return (
        addresses: [
          for (final iface in interfaces)
            for (final address in iface.addresses)
              if (JamHostServer.isLanAddress(address)) address,
        ],
        enumerated: true,
      );
    } catch (error) {
      // NetworkInterface.list can fail on locked-down systems, and can hang
      // on a device whose network stack is mid-transition.
      debugPrint(
        'localjam: interface enumeration failed ($error); '
        'binding anyIPv4 behind the LAN-remote filter.',
      );
      return (addresses: const <InternetAddress>[], enumerated: false);
    }
  }

  /// The device's own LAN-facing IPv4 addresses (§9): every non-loopback
  /// interface address that [JamHostServer.isLanAddress] accepts — private
  /// RFC1918, link-local, or hotspot-range. A machine with a public IPv4 on
  /// an interface contributes nothing: a jam is never hosted on the
  /// internet.
  ///
  /// Empty when the device has no LAN at all (airplane mode) or when the
  /// platform refuses to enumerate interfaces.
  @visibleForTesting
  static Future<List<InternetAddress>> lanCandidates() async =>
      (await _scanLan()).addresses;

  /// The address to bind so every guest can reach the room, and nobody else
  /// can (§9).
  ///
  /// `anyIPv4` whenever the device has any LAN at all. One [HttpServer] binds
  /// exactly one address, and a room has to be reachable on two kinds of
  /// path: the LAN, and the machine itself — two iOS simulators or two
  /// Android emulators on one host, a desktop app beside the CLI, a
  /// dev-machine pair. Binding the single Wi-Fi address instead drops
  /// loopback, which is how a co-located guest is reachable at all on an iOS
  /// Simulator, whose apps do not receive inbound connections on the host's
  /// LAN address. §9 is not weakened by that: the server refuses every
  /// off-LAN remote itself ([JamHostServer.restrictToLanRemotes], on by
  /// default), on both planes, whichever address is bound.
  ///
  /// Loopback — a room of one — only when there is no LAN at all, and only
  /// when the interface list actually came back: [enumerated] false means an
  /// unknown LAN, not an absent one, so the host binds `anyIPv4` rather than
  /// shrinking to a room nobody can join.
  @visibleForTesting
  static InternetAddress bindAddressFor(
    List<InternetAddress> lan, {
    bool enumerated = true,
  }) => lan.isEmpty && enumerated
      ? InternetAddress.loopbackIPv4
      : InternetAddress.anyIPv4;

  /// One `localjam://join?...` URI carrying every candidate a guest may try,
  /// comma-joined (§1: guests try them in order): the LAN addresses first,
  /// then loopback, which is the only path that works for a guest running on
  /// this same machine (two simulators, two emulators, the CLI beside the
  /// app). Off-machine guests spend nothing on it — a connect to their own
  /// loopback is refused at once.
  static Uri _buildCombinedJoinUri(
    JamHostServer server,
    List<InternetAddress> lan,
  ) {
    final addresses = [...lan, InternetAddress.loopbackIPv4];
    return Uri(
      scheme: 'localjam',
      host: 'join',
      queryParameters: {
        'v': '${MessageCodec.protocolVersion}',
        'host': addresses.map((a) => a.address).join(','),
        'port': '${server.port}',
        'token': server.token,
        'name': server.sessionName,
      },
    );
  }

  final JamHostServer _server;

  /// The combined multi-interface join URI for QR codes and copy/paste.
  final Uri joinUri;

  @override
  final LocaljamAudio player = LocaljamAudio();

  @override
  late final AudioSyncController sync;

  StreamSubscription<JamHostEvent>? _eventsSub;
  JamRoomAdvertiser? _advertiser;
  bool _closed = false;

  /// Whether the room is currently advertised over mDNS (§1).
  bool get discoverable => _advertiser != null;

  /// mediaId → absolute local path, for the controller's media resolver.
  final Map<String, String> _mediaPaths = {};

  /// Latest in-flight fetch progress per peer (§6.3); entries are removed
  /// when the peer's report leaves `fetching` or the peer drops.
  final Map<String, ({String mediaId, double progress})> _fetchProgress = {};

  final StreamController<PlaybackSnapshot> _states =
      StreamController<PlaybackSnapshot>.broadcast();
  final StreamController<List<MediaItem>> _playlists =
      StreamController<List<MediaItem>>.broadcast();
  final StreamController<String?> _mediaEnded =
      StreamController<String?>.broadcast();
  final StreamController<({String mediaId, String? peerId})> _mediaUploads =
      StreamController<({String mediaId, String? peerId})>.broadcast();

  // --- Server mirror -----------------------------------------------------------

  /// Human-readable session name (also in [joinUri]).
  @override
  String get sessionName => _server.sessionName;

  /// Random session id sent in `welcome` (§3.1).
  @override
  String get sessionId => _server.sessionId;

  /// The bound port.
  int get port => _server.port;

  /// Session token gating both planes (§9).
  String get token => _server.token;

  /// The join URI for one specific interface (e.g. loopback in tests).
  Uri joinUriFor(InternetAddress iface) => _server.joinUriFor(iface);

  @override
  PlaybackSnapshot get snapshot => _server.snapshot;

  @override
  Stream<PlaybackSnapshot> get states => _states.stream;

  @override
  List<MediaItem> get playlist => _server.playlist;

  @override
  Stream<List<MediaItem>> get playlistUpdates => _playlists.stream;

  /// Currently joined peers (never this host — see [hostPeer]).
  @override
  List<PeerInfo> get peers => _server.peers;

  /// This host as a person: the reserved host peer id plus the display name
  /// [start] was given, which is what every guest sees in `welcome.host`.
  @override
  PeerInfo get hostPeer => _server.hostPeer;

  @override
  String get selfPeerId => JamPermissions.hostPeerId;

  @override
  String? localPathFor(MediaItem item) => _mediaPaths[item.mediaId];

  @override
  JamPermissions get permissions => _server.permissions;

  @override
  Stream<JamPermissions> get permissionUpdates => _server.events
      .where((e) => e.kind == JamHostEventKind.permissionsBroadcast)
      .map((e) => e.permissions!);

  /// Raw host observability events (peer joins/leaves, media status,
  /// broadcasts) — everything a host UI needs to repaint on.
  Stream<JamHostEvent> get events => _server.events;

  /// The ended item's mediaId each time the current track reaches its end
  /// (§5.5), before the [JamEndPolicy]'s resulting state broadcast.
  Stream<String?> get mediaEnded => _mediaEnded.stream;

  /// Each guest upload that added a new item (§6.4): the new mediaId plus
  /// the uploader's peerId when the upload carried `X-LocalJam-Peer-Id`.
  /// By the time an event is delivered the item is already in [playlist]
  /// (idempotent re-uploads of existing content do not fire).
  Stream<({String mediaId, String? peerId})> get mediaUploads =>
      _mediaUploads.stream;

  /// Readiness for [mediaId] across all joined peers (§6.3).
  Map<String, MediaReadiness> peerMediaStates(String mediaId) =>
      _server.peerMediaStates(mediaId);

  /// Whether every joined peer has reported `ready` for [mediaId] (§6.3).
  bool allPeersReady(String mediaId) => _server.allPeersReady(mediaId);

  /// Latest in-flight fetch progress per peerId (§6.3).
  Map<String, ({String mediaId, double progress})> get peerFetchProgress =>
      Map.unmodifiable(_fetchProgress);

  @override
  int? get sessionNowUsOrNull => monotonicNowUs();

  // --- Media registry (§6.1) ------------------------------------------------

  /// Registers [file] as an audio playlist item and broadcasts the updated
  /// playlist (§6.1). Returns the new item.
  ///
  /// The host must supply durations (§5.5) and the audio engine is the
  /// duration probe: the file is loaded once through this engine's own
  /// [player] to read its duration. (The plugin drives one shared native
  /// engine per app, so a throwaway [LocaljamAudio] instance would clobber
  /// the same engine anyway.) Afterwards the controller's loaded-media cache
  /// is invalidated so the current track is reloaded — and re-scheduled from
  /// its authoritative anchor if it was playing. When the native side is
  /// unavailable the tag-declared duration is the fallback; without either,
  /// end of media is undetectable for the item (§5.5).
  ///
  /// Tags and embedded artwork are extracted here (§6.1/§6.5) — same
  /// best-effort path guest uploads go through on the server — so the
  /// broadcast item carries title/artist/album/artworkId when the file has
  /// them.
  Future<MediaItem> addMediaFile(File file, {String? name}) async =>
      (await addMedia(file, name: name)).item;

  /// [addMediaFile], plus what the add did — the host's half of the same
  /// answer [JamGuestEngine.addMedia] gives, so one app call site serves both
  /// sides. Media ids are content-derived, so re-adding a file that is
  /// already in the queue changes nothing and reports
  /// [JamAddOutcome.alreadyQueued] rather than silently succeeding.
  Future<JamAddResult> addMedia(File file, {String? name}) async {
    final knownBefore = {for (final item in playlist) item.mediaId};
    final durationUs = await _probeDurationUs(file.path);
    final tags = await readAudioTags(file);
    String? artworkId;
    final artworkBytes = tags.artworkBytes;
    if (tags.hasArtwork) {
      artworkId = await _server.addArtwork(
        artworkBytes!,
        mime: tags.artworkMime!,
      );
    }
    final item = await JamHostServer.describeFile(
      file,
      kind: MediaKind.audio,
      name: name,
      mime: mimeForPath(file.path),
      durationUs: durationUs ?? tags.durationUs,
      title: tags.title,
      artist: tags.artist,
      album: tags.album,
      artworkId: artworkId,
      addedBy: JamPermissions.hostPeerId,
    );
    if (knownBefore.contains(item.mediaId)) {
      // Same bytes, same id: the registry already points at a copy, and
      // re-adding would broadcast a playlist that did not change.
      return JamAddResult(item, JamAddOutcome.alreadyQueued);
    }
    _mediaPaths[item.mediaId] = file.path;
    _server.addMedia(item, file);
    return JamAddResult(item, JamAddOutcome.added);
  }

  /// Artwork bytes for [item], read straight from the server's registry
  /// (§6.5) — the host never fetches over HTTP. Null when the item has no
  /// artwork or the backing file went away.
  @override
  Future<Uint8List?> artworkFor(MediaItem item) async {
    final artworkId = item.artworkId;
    if (artworkId == null) return null;
    final file = _server.artworkFile(artworkId);
    if (file == null) return null;
    try {
      return await file.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  Future<int?> _probeDurationUs(String path) async {
    final int durationUs;
    try {
      durationUs = await player.load(path);
    } catch (_) {
      return null; // Native side unavailable; register without a duration.
    }
    // The probe replaced whatever the controller had loaded: reload (and
    // re-schedule, if playing) the current track.
    await sync.invalidateLoadedMedia();
    return durationUs;
  }

  // --- Transport (§5) ----------------------------------------------------------

  /// Starts (or resumes) playback with a scheduled anchor (§5.3).
  void play() => _server.play();

  /// Pauses playback, freezing the position (§5.1).
  void pause() => _server.pause();

  /// Seeks to [positionUs], clamped to the current item's duration (§5.5).
  void seek(int positionUs) => _server.seek(positionUs);

  /// Selects [mediaId] (§5.1). Throws [ArgumentError] for unknown ids.
  void setMedia(String mediaId) => _server.setMedia(mediaId);

  /// Stops playback: back to idle with no media selected (§5.5).
  void stop() => _server.stop();

  /// Selects the next playlist item, wrapping at the end.
  void next() => _server.next();

  /// Selects the previous playlist item, wrapping at the start.
  void previous() => _server.previous();

  // --- Queue ops (§5.6) ------------------------------------------------------

  /// Moves [mediaId] to queue position [toIndex] (clamped) and broadcasts.
  /// Throws [ArgumentError] for an unknown id.
  void moveMediaItem(String mediaId, int toIndex) =>
      _server.moveMediaItem(mediaId, toIndex);

  /// Removes [mediaId] from the queue and broadcasts; removing the current
  /// item advances (see [JamHostServer.removeMediaItem]). Throws
  /// [ArgumentError] for an id not in the playlist.
  void removeMediaItem(String mediaId) => _server.removeMediaItem(mediaId);

  // --- Permissions & moderation (§5.6) ---------------------------------------

  /// Replaces the guest-role policy and broadcasts.
  void setPolicy(JamPolicy policy) => _server.setPolicy(policy);

  /// Promotes [peerId] to co-host and broadcasts.
  void promotePeer(String peerId) => _server.promotePeer(peerId);

  /// Demotes [peerId] back to guest and broadcasts.
  void demotePeer(String peerId) => _server.demotePeer(peerId);

  /// Sets (or clears, with `allowed: null`) one per-peer capability override
  /// and broadcasts.
  void setCapabilityOverride(
    String peerId,
    JamCapability capability, {
    required bool? allowed,
  }) => _server.setCapabilityOverride(peerId, capability, allowed: allowed);

  /// Kicks [peerId] from the session (§5.6): fatal `kicked` error, socket
  /// close, no resume, role forgotten. Throws [ArgumentError] if not joined.
  void kickPeer(String peerId) => _server.kickPeer(peerId);

  // --- Transport intents (host = direct mutation) ---------------------------

  @override
  Future<void> transportPlay() async => play();

  @override
  Future<void> transportPause() async => pause();

  @override
  Future<void> transportNext() async => next();

  @override
  Future<void> transportPrevious() async => previous();

  @override
  Future<void> transportSeek(int positionUs) async => seek(positionUs);

  // --- Event plumbing --------------------------------------------------------

  void _onHostEvent(JamHostEvent event) {
    switch (event.kind) {
      case JamHostEventKind.stateBroadcast:
        final snapshot = event.snapshot!;
        unawaited(sync.onSnapshot(snapshot));
        if (!_states.isClosed) _states.add(snapshot);
      case JamHostEventKind.playlistBroadcast:
        if (!_playlists.isClosed) _playlists.add(event.playlist!);
      case JamHostEventKind.peerMediaStatus:
        final progress = event.progress;
        if (event.mediaState == MediaFetchState.fetching && progress != null) {
          _fetchProgress[event.peerId!] = (
            mediaId: event.mediaId!,
            progress: progress,
          );
        } else {
          _fetchProgress.remove(event.peerId);
        }
      case JamHostEventKind.peerLeft:
        _fetchProgress.remove(event.peerId);
      case JamHostEventKind.mediaEnded:
        // The end policy's own state broadcast follows and drives the sync
        // controller; this stream just surfaces the moment.
        if (!_mediaEnded.isClosed) _mediaEnded.add(event.mediaId);
      case JamHostEventKind.mediaUploaded:
        if (!_mediaUploads.isClosed) {
          _mediaUploads.add((mediaId: event.mediaId!, peerId: event.peerId));
        }
      case JamHostEventKind.peerJoined:
      case JamHostEventKind.permissionsBroadcast:
      case JamHostEventKind.requestDenied:
        // Surfaced via permissionUpdates / the raw events stream.
        break;
    }
  }

  // --- Teardown ------------------------------------------------------------------

  /// Tears the session down: server, sockets, local playback.
  ///
  /// Session-end contract for guests: this is a DELIBERATE end, so the
  /// server says so (§3.4). Every guest is sent
  /// `session_ended { reason: host_ended }` and its socket is then closed
  /// with `normalClosure`; each guest engine publishes
  /// [JamSessionEndReason.hostEnded] on the spot — no "Reconnecting…"
  /// banner, no waiting out a 90 s `hostGoneTimeout` for a host that is
  /// never coming back. Guests keep whatever they were playing locally; the
  /// transport is what ends.
  ///
  /// Silence still means the same thing it always did: a host that crashes,
  /// runs out of battery or leaves the network sends nothing, and guests
  /// fall back to [JamSessionEndReason.hostGone] after their timeout
  /// (PROTOCOL.md §10: host death ends the room).
  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _advertiser?.stop();
    _advertiser = null;
    await stopSessionGuards();
    await _eventsSub?.cancel();
    _eventsSub = null;
    await sync.dispose();
    try {
      await player.dispose();
    } catch (_) {
      // Native side may not be up (tests, stub platforms).
    }
    await _server.close();
    await _states.close();
    await _playlists.close();
    await _mediaEnded.close();
    await _mediaUploads.close();
    nudgeUs.dispose();
  }
}
