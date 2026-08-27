import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' hide MessageCodec;
import 'package:localjam_audio/localjam_audio.dart';
import 'package:localjam_net/localjam_net.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../sync/audio_sync_controller.dart';
import '../util/format.dart';
import '../util/media_mime.dart';
import '../widgets/nudge_slider.dart';
import '../widgets/sync_telemetry_strip.dart';

/// Host flow: pick files, start a [JamHostServer], share the join URI (QR +
/// text), watch peers' readiness, drive the transport — and play along.
///
/// The host is a listener too: its own [AudioSyncController] follows the
/// server's authoritative snapshots exactly like a guest would, except the
/// host's session clock IS `monotonicNowUs()` (identity mapping, no
/// ClockSync).
class HostScreen extends StatefulWidget {
  const HostScreen({super.key});

  @override
  State<HostScreen> createState() => _HostScreenState();
}

class _HostScreenState extends State<HostScreen> {
  final TextEditingController _nameController =
      TextEditingController(text: 'LocalJam');

  /// Setup phase: absolute paths picked (or found in Documents), in order.
  final List<String> _pickedPaths = [];

  JamHostServer? _server;
  bool _starting = false;
  String? _setupError;

  /// Live phase state.
  final Map<String, String> _mediaPaths = {}; // mediaId -> local path
  Uri? _combinedJoinUri;
  LocaljamAudio? _player;
  AudioSyncController? _sync;
  StreamSubscription<JamHostEvent>? _events;
  Timer? _uiTicker;

  /// Latest fetch progress per peer (readiness itself comes from
  /// [JamHostServer.peerMediaStates]).
  final Map<String, ({String mediaId, double progress})> _fetchProgress = {};

  /// Local slider state while the user is dragging.
  double? _dragPositionUs;

  bool get _live => _server != null;

  @override
  void initState() {
    super.initState();
    _scanDocumentsDirectory();
  }

  @override
  void dispose() {
    _uiTicker?.cancel();
    _events?.cancel();
    final sync = _sync;
    final player = _player;
    final server = _server;
    // Fire-and-forget teardown; the screen is going away.
    unawaited(() async {
      await sync?.dispose();
      try {
        await player?.dispose();
      } catch (_) {}
      await server?.close();
    }());
    _nameController.dispose();
    super.dispose();
  }

  // --- Setup phase -----------------------------------------------------------

  /// Auto-include audio files from the app's Documents directory, so files
  /// pushed via `xcrun simctl` (or saved by other apps) show up.
  Future<void> _scanDocumentsDirectory() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final found = <String>[];
      await for (final entity in docs.list()) {
        if (entity is File && isSupportedAudioPath(entity.path)) {
          found.add(entity.path);
        }
      }
      found.sort();
      if (!mounted) return;
      setState(() {
        for (final path in found) {
          if (!_pickedPaths.contains(path)) _pickedPaths.add(path);
        }
      });
    } catch (_) {
      // No Documents dir (or unreadable): picking still works.
    }
  }

  Future<void> _pickFiles() async {
    const typeGroup = XTypeGroup(
      label: 'Audio',
      extensions: supportedAudioExtensions,
      // UTIs make the picker work on iOS/macOS where extensions alone don't.
      uniformTypeIdentifiers: ['public.audio'],
    );
    try {
      final files = await openFiles(acceptedTypeGroups: const [typeGroup]);
      if (!mounted || files.isEmpty) return;
      setState(() {
        _setupError = null;
        for (final file in files) {
          if (!_pickedPaths.contains(file.path)) _pickedPaths.add(file.path);
        }
      });
    } catch (e) {
      if (mounted) setState(() => _setupError = 'File picker failed: $e');
    }
  }

  Future<void> _startSession() async {
    if (_pickedPaths.isEmpty || _starting) return;
    setState(() {
      _starting = true;
      _setupError = null;
    });
    final name = _nameController.text.trim().isEmpty
        ? 'LocalJam'
        : _nameController.text.trim();
    final server = JamHostServer(sessionName: name);
    try {
      await server.start(address: InternetAddress.anyIPv4, port: 0);
      for (final path in _pickedPaths) {
        final file = File(path);
        final item = await JamHostServer.describeFile(
          file,
          kind: MediaKind.audio,
          mime: mimeForPath(path),
        );
        server.addMedia(item, file);
        _mediaPaths[item.mediaId] = path;
      }
      server.setMedia(server.playlist.first.mediaId);

      _combinedJoinUri = await _buildCombinedJoinUri(server);

      // The host plays audio too — same sync engine as a guest, with the
      // identity session→local mapping (the host's clock IS the session
      // clock).
      final player = LocaljamAudio();
      final sync = AudioSyncController(
        player: player,
        sessionNowUs: monotonicNowUs,
        localNowUs: monotonicNowUs,
        sessionToLocalUs: (sessionUs) => sessionUs,
        resolveMediaPath: (mediaId) async => _mediaPaths[mediaId],
      );
      _player = player;
      _sync = sync;

      _events = server.events.listen(_onHostEvent);
      _uiTicker = Timer.periodic(
        const Duration(milliseconds: 250),
        (_) => setState(() {}),
      );

      setState(() {
        _server = server;
        _starting = false;
      });
      // Preload the selected track (snapshot is paused at this point).
      unawaited(sync.onSnapshot(server.snapshot));
    } catch (e) {
      await server.close();
      if (mounted) {
        setState(() {
          _starting = false;
          _setupError = 'Could not start session: $e';
        });
      }
    }
  }

  /// One URI carrying every non-loopback IPv4 candidate, comma-joined,
  /// exactly like the CLI's combined join line (§1: guests try in order).
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

  // --- Live phase ------------------------------------------------------------

  void _onHostEvent(JamHostEvent event) {
    switch (event.kind) {
      case JamHostEventKind.stateBroadcast:
        unawaited(_sync?.onSnapshot(event.snapshot!));
      case JamHostEventKind.peerMediaStatus:
        final progress = event.progress;
        if (event.mediaState == MediaFetchState.fetching && progress != null) {
          _fetchProgress[event.peerId!] =
              (mediaId: event.mediaId!, progress: progress);
        } else {
          _fetchProgress.remove(event.peerId);
        }
      case JamHostEventKind.peerLeft:
        _fetchProgress.remove(event.peerId);
      case JamHostEventKind.peerJoined:
      case JamHostEventKind.playlistBroadcast:
        break;
    }
    if (mounted) setState(() {});
  }

  void _guarded(void Function() mutate) {
    try {
      mutate();
    } on StateError catch (e) {
      _showSnack(e.message);
    } on ArgumentError catch (e) {
      _showSnack('$e');
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _togglePlay() {
    final server = _server!;
    _guarded(() {
      server.snapshot.status == PlaybackStatus.playing
          ? server.pause()
          : server.play();
    });
  }

  void _skip(int delta) {
    final server = _server!;
    final playlist = server.playlist;
    if (playlist.isEmpty) return;
    final index =
        playlist.indexWhere((i) => i.mediaId == server.snapshot.mediaId);
    final next = (index + delta) % playlist.length;
    _guarded(
      () => server.setMedia(playlist[next < 0 ? next + playlist.length : next]
          .mediaId),
    );
  }

  // --- Build -------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_live ? _server!.sessionName : 'Host a Jam'),
      ),
      body: SafeArea(
        child: _live ? _buildLive(context) : _buildSetup(context),
      ),
    );
  }

  Widget _buildSetup(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        TextField(
          controller: _nameController,
          decoration: const InputDecoration(
            labelText: 'Session name',
            prefixIcon: Icon(Icons.badge_outlined),
          ),
        ),
        const SizedBox(height: 24),
        Row(
          children: [
            Text('Playlist', style: theme.textTheme.titleMedium),
            const Spacer(),
            TextButton.icon(
              icon: const Icon(Icons.add),
              label: const Text('Add files'),
              onPressed: _pickFiles,
            ),
          ],
        ),
        if (_pickedPaths.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Text(
              'No audio yet. Add mp3 / m4a / aac / wav files — anything in '
              'the app\'s Documents folder is included automatically.',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          )
        else
          Card(
            child: Column(
              children: [
                for (final path in _pickedPaths)
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.audio_file_outlined),
                    title: Text(
                      path.split(Platform.pathSeparator).last,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () =>
                          setState(() => _pickedPaths.remove(path)),
                    ),
                  ),
              ],
            ),
          ),
        if (_setupError != null) ...[
          const SizedBox(height: 12),
          Text(
            _setupError!,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.error),
          ),
        ],
        const SizedBox(height: 24),
        FilledButton.icon(
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 18),
          ),
          icon: _starting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.wifi_tethering),
          label: Text(_starting ? 'Starting…' : 'Start session'),
          onPressed:
              _pickedPaths.isEmpty || _starting ? null : _startSession,
        ),
      ],
    );
  }

  Widget _buildLive(BuildContext context) {
    final theme = Theme.of(context);
    final server = _server!;
    final sync = _sync!;
    final snapshot = server.snapshot;
    final joinUri = _combinedJoinUri.toString();
    final currentItem = server.playlist
        .where((i) => i.mediaId == snapshot.mediaId)
        .firstOrNull;

    final positionUs = snapshot.positionAt(monotonicNowUs());
    final durationUs = sync.loadedDurationUs.value ?? currentItem?.durationUs;
    final playing = snapshot.status == PlaybackStatus.playing;

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        // --- Invite card: QR + copyable URI --------------------------------
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Text('Scan to join', style: theme.textTheme.labelLarge),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: QrImageView(
                    data: joinUri,
                    version: QrVersions.auto,
                    size: 180,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: TextEditingController(text: joinUri),
                  readOnly: true,
                  style: theme.textTheme.bodySmall,
                  maxLines: 1,
                  decoration: InputDecoration(
                    isDense: true,
                    labelText: 'Join URI',
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.copy, size: 18),
                      tooltip: 'Copy',
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: joinUri));
                        _showSnack('Join URI copied');
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),

        // --- Now playing + transport ----------------------------------------
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Text(
                  currentItem?.name ?? 'Nothing selected',
                  style: theme.textTheme.titleMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Text(
                  snapshot.status.name,
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Text(
                      formatPositionUs(
                        (_dragPositionUs ?? positionUs.toDouble()).round(),
                      ),
                      style: theme.textTheme.bodySmall,
                    ),
                    Expanded(
                      child: Slider(
                        value: durationUs == null || durationUs <= 0
                            ? 0
                            : math.min(
                                _dragPositionUs ?? positionUs.toDouble(),
                                durationUs.toDouble(),
                              ),
                        max: durationUs == null || durationUs <= 0
                            ? 1
                            : durationUs.toDouble(),
                        onChanged: durationUs == null
                            ? null
                            : (v) => setState(() => _dragPositionUs = v),
                        onChangeEnd: durationUs == null
                            ? null
                            : (v) {
                                setState(() => _dragPositionUs = null);
                                _guarded(() => server.seek(v.round()));
                              },
                      ),
                    ),
                    Text(
                      durationUs == null ? '--:--' : formatPositionUs(durationUs),
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      iconSize: 32,
                      icon: const Icon(Icons.skip_previous),
                      onPressed: () => _skip(-1),
                    ),
                    const SizedBox(width: 16),
                    IconButton.filled(
                      iconSize: 40,
                      icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                      onPressed: _togglePlay,
                    ),
                    const SizedBox(width: 16),
                    IconButton(
                      iconSize: 32,
                      icon: const Icon(Icons.skip_next),
                      onPressed: () => _skip(1),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),

        // --- Telemetry + nudge ----------------------------------------------
        SyncTelemetryStrip(controller: sync),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: NudgeSlider(controller: sync),
          ),
        ),
        const SizedBox(height: 16),

        // --- Peers -----------------------------------------------------------
        Text('Peers (${server.peers.length})',
            style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        if (server.peers.isEmpty)
          Text(
            'No one has joined yet — share the QR or the URI above.',
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          )
        else
          Card(
            child: Column(
              children: [
                for (final peer in server.peers)
                  _buildPeerTile(theme, server, snapshot, peer),
              ],
            ),
          ),
        const SizedBox(height: 16),

        // --- Playlist ----------------------------------------------------------
        Text('Playlist', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        Card(
          child: Column(
            children: [
              for (final item in server.playlist)
                ListTile(
                  dense: true,
                  selected: item.mediaId == snapshot.mediaId,
                  leading: Icon(
                    item.mediaId == snapshot.mediaId
                        ? Icons.graphic_eq
                        : Icons.audio_file_outlined,
                  ),
                  title: Text(item.name, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    '${(item.sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB'
                    ' · ${item.mime}',
                  ),
                  onTap: () => _guarded(() => server.setMedia(item.mediaId)),
                ),
            ],
          ),
        ),
        const SizedBox(height: 32),
      ],
    );
  }

  Widget _buildPeerTile(
    ThemeData theme,
    JamHostServer server,
    PlaybackSnapshot snapshot,
    PeerInfo peer,
  ) {
    final mediaId = snapshot.mediaId;
    final readiness = mediaId == null
        ? MediaReadiness.none
        : server.peerMediaStates(mediaId)[peer.peerId] ?? MediaReadiness.none;
    final progress = _fetchProgress[peer.peerId];

    final (label, color) = switch (readiness) {
      MediaReadiness.ready => ('ready', theme.colorScheme.primary),
      MediaReadiness.fetching => (
          progress != null && progress.mediaId == mediaId
              ? 'fetching ${(progress.progress * 100).round()}%'
              : 'fetching',
          theme.colorScheme.tertiary,
        ),
      MediaReadiness.none => ('no media', theme.colorScheme.onSurfaceVariant),
    };

    return ListTile(
      dense: true,
      leading: const Icon(Icons.person_outline),
      title: Text(peer.clientName),
      subtitle: Text('${peer.peerId} · ${peer.clientKind}'),
      trailing: Chip(
        visualDensity: VisualDensity.compact,
        label: Text(label, style: TextStyle(color: color, fontSize: 12)),
        side: BorderSide(color: color.withValues(alpha: 0.4)),
      ),
    );
  }
}
