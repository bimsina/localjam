/// The whole host side of a jam behind one object: a [JamHostServer] plus
/// local synchronized playback, so the host hears its own jam through the
/// same [AudioSyncController] a guest uses — with the identity session→local
/// clock mapping, because the host's monotonic clock IS the session clock
/// (PROTOCOL.md §4).
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:localjam_audio/localjam_audio.dart';
import 'package:localjam_net/localjam_net.dart';

import 'audio_sync_controller.dart';
import 'jam_discovery.dart';
import 'jam_engine.dart';
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
  /// Binds [address] (default: every IPv4 interface, so guests on any LAN the
  /// device sits on can reach it) on [port] (default: ephemeral). [endPolicy]
  /// is applied when the current item reaches its end (§5.5); the engine
  /// defaults to advancing through the playlist.
  ///
  /// With [discoverable] (the default) the room is advertised over mDNS so
  /// nearby devices list it for one-tap join — which means ANYONE on the
  /// network can join without the QR (the advertisement carries the token,
  /// §1/§9). Pass false for invite-only rooms. Best-effort: platforms
  /// without mDNS just stay QR-only.
  static Future<JamHostEngine> start({
    required String sessionName,
    JamEndPolicy endPolicy = JamEndPolicy.advance,
    JamPolicy policy = JamPolicy.jam,
    bool discoverable = true,
    int port = 0,
    InternetAddress? address,
  }) async {
    final server = JamHostServer(
      sessionName: sessionName,
      endPolicy: endPolicy,
      policy: policy,
    );
    try {
      await server.start(
        address: address ?? InternetAddress.anyIPv4,
        port: port,
      );
      final joinUri = await _buildCombinedJoinUri(server);
      final engine = JamHostEngine._(server, joinUri);
      await engine.restorePersistedNudge();
      await engine.startSessionGuards();
      if (discoverable) {
        engine._advertiser = await JamRoomAdvertiser.start(
          sessionName: sessionName,
          port: server.port,
          token: server.token,
        );
      }
      // Preload whatever the (idle) snapshot says — a no-op until setMedia.
      unawaited(engine.sync.onSnapshot(server.snapshot));
      return engine;
    } catch (_) {
      await server.close();
      rethrow;
    }
  }

  /// One `localjam://join?...` URI carrying every non-loopback IPv4 candidate,
  /// comma-joined (§1: guests try them in order).
  static Future<Uri> _buildCombinedJoinUri(JamHostServer server) async {
    final addresses = <InternetAddress>[];
    try {
      for (final iface in await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      )) {
        addresses.addAll(iface.addresses);
      }
    } catch (_) {
      // NetworkInterface.list can fail on locked-down systems.
    }
    if (addresses.isEmpty) addresses.add(InternetAddress.loopbackIPv4);
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

  /// Currently joined peers.
  @override
  List<PeerInfo> get peers => _server.peers;

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
  Future<MediaItem> addMediaFile(File file, {String? name}) async {
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
    _mediaPaths[item.mediaId] = file.path;
    _server.addMedia(item, file);
    return item;
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
  }) =>
      _server.setCapabilityOverride(peerId, capability, allowed: allowed);

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
  /// Session-end contract for guests: the server closes every guest socket
  /// with WebSocket status `goingAway`, and no protocol-level
  /// `error {code: session_closed}` is broadcast first (that message would
  /// have to be sent by `localjam_net`, which owns the sockets). Guests
  /// therefore detect host shutdown via the socket close: their sessions
  /// enter `reconnecting`, and `JamGuestEngine` publishes
  /// [JamSessionEndReason.hostGone] once its `hostGoneTimeout` elapses (or
  /// [JamSessionEndReason.rejected] immediately, if another host answers
  /// with `reject` in the meantime). That guest-side timeout IS the
  /// contract — PROTOCOL.md §10: host death ends the room.
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
