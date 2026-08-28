/// The whole host side of a jam behind one object: a [JamHostServer] plus
/// local synchronized playback, so the host hears its own jam through the
/// same [AudioSyncController] a guest uses — with the identity session→local
/// clock mapping, because the host's monotonic clock IS the session clock
/// (PROTOCOL.md §4).
library;

import 'dart:async';
import 'dart:io';

import 'package:localjam_audio/localjam_audio.dart';
import 'package:localjam_net/localjam_net.dart';

import 'audio_sync_controller.dart';
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
  static Future<JamHostEngine> start({
    required String sessionName,
    JamEndPolicy endPolicy = JamEndPolicy.advance,
    int port = 0,
    InternetAddress? address,
  }) async {
    final server = JamHostServer(
      sessionName: sessionName,
      endPolicy: endPolicy,
    );
    try {
      await server.start(
        address: address ?? InternetAddress.anyIPv4,
        port: port,
      );
      final joinUri = await _buildCombinedJoinUri(server);
      final engine = JamHostEngine._(server, joinUri);
      await engine.restorePersistedNudge();
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
  bool _closed = false;

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

  // --- Server mirror -----------------------------------------------------------

  /// Human-readable session name (also in [joinUri]).
  String get sessionName => _server.sessionName;

  /// Random session id sent in `welcome` (§3.1).
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
  List<PeerInfo> get peers => _server.peers;

  /// Raw host observability events (peer joins/leaves, media status,
  /// broadcasts) — everything a host UI needs to repaint on.
  Stream<JamHostEvent> get events => _server.events;

  /// The ended item's mediaId each time the current track reaches its end
  /// (§5.5), before the [JamEndPolicy]'s resulting state broadcast.
  Stream<String?> get mediaEnded => _mediaEnded.stream;

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
  /// unavailable the item is registered without a duration; end of media is
  /// then undetectable for it (§5.5).
  Future<MediaItem> addMediaFile(File file, {String? name}) async {
    final durationUs = await _probeDurationUs(file.path);
    final item = await JamHostServer.describeFile(
      file,
      kind: MediaKind.audio,
      name: name,
      mime: mimeForPath(file.path),
      durationUs: durationUs,
    );
    _mediaPaths[item.mediaId] = file.path;
    _server.addMedia(item, file);
    return item;
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
  void next() => _skip(1);

  /// Selects the previous playlist item, wrapping at the start.
  void previous() => _skip(-1);

  void _skip(int delta) {
    final items = _server.playlist;
    if (items.isEmpty) return;
    final index = items.indexWhere(
      (i) => i.mediaId == _server.snapshot.mediaId,
    );
    final target = (index + delta) % items.length;
    setMedia(items[target < 0 ? target + items.length : target].mediaId);
  }

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
      case JamHostEventKind.peerJoined:
        break;
    }
  }

  // --- Teardown ------------------------------------------------------------------

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
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
    nudgeUs.dispose();
  }
}
