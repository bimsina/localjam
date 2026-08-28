import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' hide MessageCodec;
import 'package:localjam_client/localjam_client.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../util/format.dart';
import '../widgets/nudge_slider.dart';
import '../widgets/sync_telemetry_strip.dart';

/// Host flow: pick files, start a [JamHostEngine], share the join URI (QR +
/// text), watch peers' readiness, and drive the transport. All server, clock,
/// and audio wiring lives in the engine — this screen only renders it.
class HostScreen extends StatefulWidget {
  const HostScreen({super.key});

  @override
  State<HostScreen> createState() => _HostScreenState();
}

class _HostScreenState extends State<HostScreen> {
  final TextEditingController _nameController = TextEditingController(
    text: 'LocalJam',
  );

  /// Setup phase: absolute paths picked (or found in Documents), in order.
  final List<String> _pickedPaths = [];

  JamHostEngine? _engine;
  bool _starting = false;
  String? _setupError;

  StreamSubscription<JamHostEvent>? _events;
  StreamSubscription<({String mediaId, String? peerId})>? _uploads;
  Timer? _uiTicker;

  /// Local slider state while the user is dragging.
  double? _dragPositionUs;

  bool get _live => _engine != null;

  @override
  void initState() {
    super.initState();
    _scanDocumentsDirectory();
  }

  @override
  void dispose() {
    _uiTicker?.cancel();
    _events?.cancel();
    _uploads?.cancel();
    // Fire-and-forget teardown; the screen is going away.
    unawaited(_engine?.close());
    _nameController.dispose();
    super.dispose();
  }

  // --- Setup phase -----------------------------------------------------------

  /// Auto-include audio files from the app's Documents directory, so files
  /// pushed via `xcrun simctl` (or saved by other apps) show up.
  Future<void> _scanDocumentsDirectory() async {
    final found = await findAudioFilesInDocuments();
    if (!mounted) return;
    setState(() {
      for (final path in found) {
        if (!_pickedPaths.contains(path)) _pickedPaths.add(path);
      }
    });
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
    JamHostEngine? engine;
    try {
      engine = await JamHostEngine.start(sessionName: name);
      for (final path in _pickedPaths) {
        await engine.addMediaFile(File(path));
      }
      engine.setMedia(engine.playlist.first.mediaId);

      _events = engine.events.listen((_) {
        if (mounted) setState(() {});
      });
      _uploads = engine.mediaUploads.listen(_onGuestUpload);
      _uiTicker = Timer.periodic(
        const Duration(milliseconds: 250),
        (_) => setState(() {}),
      );
      setState(() {
        _engine = engine;
        _starting = false;
      });
    } catch (e) {
      await engine?.close();
      if (mounted) {
        setState(() {
          _starting = false;
          _setupError = 'Could not start session: $e';
        });
      }
    }
  }

  // --- Live phase ------------------------------------------------------------

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

  /// Announces a guest upload (§6.4): who added what. By the time the event
  /// arrives the item is already in the engine's playlist.
  void _onGuestUpload(({String mediaId, String? peerId}) upload) {
    final engine = _engine;
    if (engine == null) return;
    String? trackName;
    for (final item in engine.playlist) {
      if (item.mediaId == upload.mediaId) {
        trackName = item.name;
        break;
      }
    }
    String? peerName;
    for (final peer in engine.peers) {
      if (peer.peerId == upload.peerId) {
        peerName = peer.clientName;
        break;
      }
    }
    _showSnack(
      '${peerName ?? upload.peerId ?? 'A guest'} added '
      '"${trackName ?? upload.mediaId}"',
    );
  }

  void _togglePlay() {
    final engine = _engine!;
    _guarded(() {
      engine.snapshot.status == PlaybackStatus.playing
          ? engine.pause()
          : engine.play();
    });
  }

  // --- Build -------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_live ? _engine!.sessionName : 'Host a Jam')),
      body: SafeArea(child: _live ? _buildLive(context) : _buildSetup(context)),
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
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
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
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
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
          onPressed: _pickedPaths.isEmpty || _starting ? null : _startSession,
        ),
      ],
    );
  }

  Widget _buildLive(BuildContext context) {
    final theme = Theme.of(context);
    final engine = _engine!;
    final snapshot = engine.snapshot;
    final joinUri = engine.joinUri.toString();
    final currentItem = engine.currentItem;

    final positionUs = engine.positionUsNow() ?? 0;
    final durationUs = engine.loadedDurationUs.value ?? currentItem?.durationUs;
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
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
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
                                _guarded(() => engine.seek(v.round()));
                              },
                      ),
                    ),
                    Text(
                      durationUs == null
                          ? '--:--'
                          : formatPositionUs(durationUs),
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
                      onPressed: () => _guarded(engine.previous),
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
                      onPressed: () => _guarded(engine.next),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),

        // --- Telemetry + nudge ----------------------------------------------
        SyncTelemetryStrip(controller: engine.sync),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: NudgeSlider(engine: engine),
          ),
        ),
        const SizedBox(height: 16),

        // --- Peers -----------------------------------------------------------
        Text(
          'Peers (${engine.peers.length})',
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        if (engine.peers.isEmpty)
          Text(
            'No one has joined yet — share the QR or the URI above.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          )
        else
          Card(
            child: Column(
              children: [
                for (final peer in engine.peers)
                  _buildPeerTile(theme, engine, snapshot, peer),
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
              for (final item in engine.playlist)
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
                  onTap: () => _guarded(() => engine.setMedia(item.mediaId)),
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
    JamHostEngine engine,
    PlaybackSnapshot snapshot,
    PeerInfo peer,
  ) {
    final mediaId = snapshot.mediaId;
    final readiness = mediaId == null
        ? MediaReadiness.none
        : engine.peerMediaStates(mediaId)[peer.peerId] ?? MediaReadiness.none;
    final progress = engine.peerFetchProgress[peer.peerId];

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
