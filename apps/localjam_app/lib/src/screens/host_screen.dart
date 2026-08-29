import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' hide MessageCodec;
import 'package:localjam_client/localjam_client.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../util/format.dart';
import '../util/permissions.dart';
import '../widgets/artwork.dart';
import '../widgets/nudge_slider.dart';
import '../widgets/sync_telemetry_strip.dart';

/// Host flow: pick files, start a [JamHostEngine], share the join URI (QR +
/// text), watch peers' readiness, and drive the transport. All server, clock,
/// and audio wiring lives in the engine — this screen only renders it.
class HostScreen extends StatefulWidget {
  const HostScreen({super.key, this.initialPaths = const [], this.initialName});

  /// Pre-seeded playlist paths — the "host it again" flow from jam history.
  final List<String> initialPaths;

  /// Pre-filled session name (defaults to the quirky identity otherwise).
  final String? initialName;

  @override
  State<HostScreen> createState() => _HostScreenState();
}

class _HostScreenState extends State<HostScreen> {
  final TextEditingController _nameController = TextEditingController(
    text: 'LocalJam',
  );

  /// Setup phase: absolute paths picked (or found in Documents), in order.
  final List<String> _pickedPaths = [];

  /// Room preset chosen at setup (§5.6); live edits go through
  /// [JamHostEngine.setPolicy].
  JamPolicy _policy = JamPolicy.jam;

  /// Whether the room is advertised over mDNS for nearby one-tap join (§1).
  bool _discoverable = true;

  /// Library tracks picked (Android), resolved lazily at session start:
  /// MediaStore id → track.
  final Map<int, JamLibraryTrack> _pickedLibraryTracks = {};

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
    for (final path in widget.initialPaths) {
      if (!_pickedPaths.contains(path) && File(path).existsSync()) {
        _pickedPaths.add(path);
      }
    }
    _scanDocumentsDirectory();
    final initialName = widget.initialName?.trim();
    if (initialName != null && initialName.isNotEmpty) {
      _nameController.text = initialName;
    } else {
      _defaultSessionName();
    }
  }

  /// Default the room name to the device's quirky identity ("Neon Walrus's
  /// Jam") unless the user already typed something.
  Future<void> _defaultSessionName() async {
    final name = await JamIdentity.displayName();
    if (!mounted) return;
    final current = _nameController.text.trim();
    if (current.isEmpty || current == 'LocalJam') {
      _nameController.text = "$name's Jam";
    }
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

  /// Android library picker: request permission, query, multi-select sheet.
  Future<void> _pickFromLibrary() async {
    if (!await ensureAudioLibraryPermission()) {
      if (mounted) {
        setState(() => _setupError = 'Music library permission was denied.');
      }
      return;
    }
    final List<JamLibraryTrack> tracks;
    try {
      tracks = await JamMediaLibrary.queryAudio();
    } on JamLibraryPermissionException {
      if (mounted) {
        setState(() => _setupError = 'Music library permission was denied.');
      }
      return;
    }
    if (!mounted) return;
    if (tracks.isEmpty) {
      setState(() => _setupError = 'No music found in the device library.');
      return;
    }
    final selected = Set<int>.of(_pickedLibraryTracks.keys);
    final confirmed = await showModalBottomSheet<Set<int>>(
      context: context,
      isScrollControlled: true,
      builder: (context) =>
          _LibraryPickerSheet(tracks: tracks, initiallySelected: selected),
    );
    if (confirmed == null || !mounted) return;
    setState(() {
      _setupError = null;
      _pickedLibraryTracks
        ..clear()
        ..addEntries([
          for (final track in tracks)
            if (confirmed.contains(track.id)) MapEntry(track.id, track),
        ]);
    });
  }

  Future<void> _startSession() async {
    if ((_pickedPaths.isEmpty && _pickedLibraryTracks.isEmpty) || _starting) {
      return;
    }
    setState(() {
      _starting = true;
      _setupError = null;
    });
    // Android 17 gates LAN sockets behind a runtime permission.
    await ensureLocalNetworkPermission();
    final name = _nameController.text.trim().isEmpty
        ? 'LocalJam'
        : _nameController.text.trim();
    JamHostEngine? engine;
    try {
      engine = await JamHostEngine.start(
        sessionName: name,
        policy: _policy,
        discoverable: _discoverable,
      );
      for (final path in _pickedPaths) {
        await engine.addMediaFile(File(path));
      }
      // Library picks resolve to readable paths (cache copies under scoped
      // storage) as they are added.
      for (final track in _pickedLibraryTracks.values) {
        final path = await JamMediaLibrary.resolve(track);
        if (path != null) {
          await engine.addMediaFile(File(path), name: track.title);
        }
      }
      if (engine.playlist.isEmpty) {
        throw StateError('none of the selected tracks could be read');
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
        trackName = item.displayTitle;
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
        const SizedBox(height: 16),
        Text('Guests can…', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        SegmentedButton<JamPolicy>(
          segments: const [
            ButtonSegment(
              value: JamPolicy.open,
              label: Text('Open'),
              icon: Icon(Icons.lock_open),
            ),
            ButtonSegment(
              value: JamPolicy.jam,
              label: Text('Jam'),
              icon: Icon(Icons.queue_music),
            ),
            ButtonSegment(
              value: JamPolicy.listenOnly,
              label: Text('Listen'),
              icon: Icon(Icons.headphones),
            ),
          ],
          selected: {_policy},
          onSelectionChanged: (selection) =>
              setState(() => _policy = selection.single),
        ),
        const SizedBox(height: 4),
        Text(
          switch (_policy) {
            JamPolicy.open =>
              'Everyone can add songs, control playback, and edit the queue.',
            JamPolicy.jam =>
              'Guests add songs and shape the queue; you control playback.',
            _ => 'Guests just listen; you run the room.',
          },
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 16),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Discoverable on this network'),
          subtitle: const Text(
            'Nearby devices see the room and can join with one tap — no QR '
            'needed. Anyone on the Wi-Fi counts as invited.',
          ),
          value: _discoverable,
          onChanged: (v) => setState(() => _discoverable = v),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Text('Playlist', style: theme.textTheme.titleMedium),
            const Spacer(),
            if (JamMediaLibrary.isSupported)
              TextButton.icon(
                icon: const Icon(Icons.library_music_outlined),
                label: const Text('Library'),
                onPressed: _pickFromLibrary,
              ),
            TextButton.icon(
              icon: const Icon(Icons.add),
              label: const Text('Add files'),
              onPressed: _pickFiles,
            ),
          ],
        ),
        if (_pickedLibraryTracks.isNotEmpty)
          Card(
            child: Column(
              children: [
                for (final track in _pickedLibraryTracks.values)
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.library_music_outlined),
                    title: Text(track.title, overflow: TextOverflow.ellipsis),
                    subtitle: track.artist == null
                        ? null
                        : Text(track.artist!, overflow: TextOverflow.ellipsis),
                    trailing: IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () =>
                          setState(() => _pickedLibraryTracks.remove(track.id)),
                    ),
                  ),
              ],
            ),
          ),
        if (_pickedPaths.isEmpty && _pickedLibraryTracks.isEmpty)
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
          onPressed:
              (_pickedPaths.isEmpty && _pickedLibraryTracks.isEmpty) ||
                  _starting
              ? null
              : _startSession,
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
                JamArtwork(
                  engine: engine,
                  item: currentItem,
                  size: 96,
                  icon: Icons.music_note_outlined,
                ),
                const SizedBox(height: 12),
                Text(
                  currentItem?.displayTitle ?? 'Nothing selected',
                  style: theme.textTheme.titleMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (currentItem != null &&
                    artworkByline(currentItem) != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    artworkByline(currentItem)!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
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

        // --- Guest permissions (§5.6) ---------------------------------------
        Text('Guests can…', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        Card(
          child: Column(
            children: [
              SwitchListTile(
                dense: true,
                title: const Text('Add songs'),
                value: engine.permissions.policy.addTracks,
                onChanged: (v) => engine.setPolicy(
                  engine.permissions.policy.copyWith(addTracks: v),
                ),
              ),
              SwitchListTile(
                dense: true,
                title: const Text('Control playback'),
                value: engine.permissions.policy.controlPlayback,
                onChanged: (v) => engine.setPolicy(
                  engine.permissions.policy.copyWith(controlPlayback: v),
                ),
              ),
              SwitchListTile(
                dense: true,
                title: const Text('Edit the queue'),
                value: engine.permissions.policy.editQueue,
                onChanged: (v) => engine.setPolicy(
                  engine.permissions.policy.copyWith(editQueue: v),
                ),
              ),
            ],
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
                  leading: JamArtwork(
                    engine: engine,
                    item: item,
                    icon: item.mediaId == snapshot.mediaId
                        ? Icons.graphic_eq
                        : Icons.audio_file_outlined,
                  ),
                  title: Text(
                    item.displayTitle,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    [
                      artworkByline(item) ??
                          '${(item.sizeBytes / (1024 * 1024)).toStringAsFixed(1)}'
                              ' MB · ${item.mime}',
                      if (engine.addedByLabel(item, engine.peers)
                          case final byline?)
                        'added by $byline',
                    ].join(' · '),
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () => _guarded(() => engine.setMedia(item.mediaId)),
                  trailing: PopupMenuButton<String>(
                    iconSize: 18,
                    onSelected: (choice) => _guarded(() {
                      final index = engine.playlist.indexWhere(
                        (i) => i.mediaId == item.mediaId,
                      );
                      switch (choice) {
                        case 'up':
                          engine.moveMediaItem(item.mediaId, index - 1);
                        case 'down':
                          engine.moveMediaItem(item.mediaId, index + 1);
                        case 'remove':
                          engine.removeMediaItem(item.mediaId);
                      }
                    }),
                    itemBuilder: (context) => const [
                      PopupMenuItem(value: 'up', child: Text('Move up')),
                      PopupMenuItem(value: 'down', child: Text('Move down')),
                      PopupMenuItem(value: 'remove', child: Text('Remove')),
                    ],
                  ),
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

    final isCohost = engine.permissions.roleOf(peer.peerId) == JamRole.cohost;
    final addsBlocked =
        engine.permissions.overrides[peer.peerId]?[JamCapability.addTracks] ==
        false;
    return ListTile(
      dense: true,
      leading: Icon(isCohost ? Icons.person : Icons.person_outline),
      title: Text(isCohost ? '${peer.clientName} · Co-host' : peer.clientName),
      subtitle: Text('${peer.peerId} · ${peer.clientKind}'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Chip(
            visualDensity: VisualDensity.compact,
            label: Text(label, style: TextStyle(color: color, fontSize: 12)),
            side: BorderSide(color: color.withValues(alpha: 0.4)),
          ),
          PopupMenuButton<String>(
            iconSize: 18,
            onSelected: (choice) => _guarded(() {
              switch (choice) {
                case 'promote':
                  engine.promotePeer(peer.peerId);
                case 'demote':
                  engine.demotePeer(peer.peerId);
                case 'blockAdds':
                  engine.setCapabilityOverride(
                    peer.peerId,
                    JamCapability.addTracks,
                    allowed: false,
                  );
                case 'unblockAdds':
                  engine.setCapabilityOverride(
                    peer.peerId,
                    JamCapability.addTracks,
                    allowed: null,
                  );
                case 'kick':
                  engine.kickPeer(peer.peerId);
              }
            }),
            itemBuilder: (context) => [
              PopupMenuItem(
                value: isCohost ? 'demote' : 'promote',
                child: Text(
                  isCohost ? 'Demote to guest' : 'Promote to co-host',
                ),
              ),
              PopupMenuItem(
                value: addsBlocked ? 'unblockAdds' : 'blockAdds',
                child: Text(
                  addsBlocked ? 'Allow adding songs' : 'Block adding songs',
                ),
              ),
              const PopupMenuItem(
                value: 'kick',
                child: Text('Remove from jam'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Multi-select sheet over the device music library (Android). Pops with
/// the selected MediaStore ids, or null when dismissed.
class _LibraryPickerSheet extends StatefulWidget {
  const _LibraryPickerSheet({
    required this.tracks,
    required this.initiallySelected,
  });

  final List<JamLibraryTrack> tracks;
  final Set<int> initiallySelected;

  @override
  State<_LibraryPickerSheet> createState() => _LibraryPickerSheetState();
}

class _LibraryPickerSheetState extends State<_LibraryPickerSheet> {
  late final Set<int> _selected = Set.of(widget.initiallySelected);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.75,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 16, 8),
              child: Row(
                children: [
                  Text('Your music', style: theme.textTheme.titleMedium),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(_selected),
                    child: Text('Add (${_selected.length})'),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                itemCount: widget.tracks.length,
                itemBuilder: (context, index) {
                  final track = widget.tracks[index];
                  return CheckboxListTile(
                    dense: true,
                    value: _selected.contains(track.id),
                    title: Text(track.title, overflow: TextOverflow.ellipsis),
                    subtitle: track.artist == null
                        ? null
                        : Text(track.artist!, overflow: TextOverflow.ellipsis),
                    onChanged: (checked) => setState(() {
                      if (checked ?? false) {
                        _selected.add(track.id);
                      } else {
                        _selected.remove(track.id);
                      }
                    }),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
