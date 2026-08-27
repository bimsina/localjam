import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:localjam_audio/localjam_audio.dart';
import 'package:localjam_net/localjam_net.dart';
import 'package:path_provider/path_provider.dart';

import '../sync/audio_sync_controller.dart';
import '../util/format.dart';
import '../util/media_mime.dart';
import '../widgets/nudge_slider.dart';
import '../widgets/sync_telemetry_strip.dart';

/// Guest flow: paste a `localjam://join?...` URI, connect, prefetch every
/// playlist item to temp files, and play along by mirroring the host's
/// authoritative snapshots through the shared [AudioSyncController].
// TODO(localjam): QR scanning — pointless in simulators, add camera-based
// scanning (e.g. mobile_scanner) for physical devices later.
class JoinScreen extends StatefulWidget {
  const JoinScreen({super.key});

  @override
  State<JoinScreen> createState() => _JoinScreenState();
}

/// Per-media prefetch bookkeeping.
class _FetchState {
  double progress = 0;
  String? path; // Set once fully fetched + verified.
  String? error;
}

class _JoinScreenState extends State<JoinScreen> {
  final TextEditingController _uriController = TextEditingController();

  JamGuestClient? _client;
  bool _connecting = false;
  bool _disconnected = false;
  String? _connectError;

  LocaljamAudio? _player;
  AudioSyncController? _sync;
  final List<StreamSubscription<Object?>> _subs = [];
  Timer? _uiTicker;

  final Map<String, _FetchState> _fetches = {};
  Directory? _cacheDir;
  bool _clockReady = false;

  bool get _joined => _client != null;

  @override
  void dispose() {
    _uiTicker?.cancel();
    for (final sub in _subs) {
      sub.cancel();
    }
    final sync = _sync;
    final player = _player;
    final client = _client;
    unawaited(() async {
      await sync?.dispose();
      try {
        await player?.dispose();
      } catch (_) {}
      await client?.close();
    }());
    _uriController.dispose();
    super.dispose();
  }

  // --- Connect -----------------------------------------------------------------

  Future<void> _connect() async {
    final raw = _uriController.text.trim();
    if (raw.isEmpty || _connecting) return;
    setState(() {
      _connecting = true;
      _connectError = null;
    });

    final Uri joinUri;
    try {
      joinUri = Uri.parse(raw);
    } on FormatException catch (e) {
      setState(() {
        _connecting = false;
        _connectError = 'Invalid URI: ${e.message}';
      });
      return;
    }

    try {
      final client = await JamGuestClient.connect(
        joinUri,
        clientName: Platform.localHostname,
        clientKind: 'flutter',
      );
      _cacheDir = await getTemporaryDirectory();

      final player = LocaljamAudio();
      final sync = AudioSyncController(
        player: player,
        sessionNowUs: () => client.sessionNowUs,
        localNowUs: () => client.localNowUs,
        sessionToLocalUs: client.clock.hostToLocalUs,
        resolveMediaPath: (mediaId) async => _fetches[mediaId]?.path,
      );
      _client = client;
      _player = player;
      _sync = sync;

      _subs.add(client.states.listen((snapshot) {
        if (_clockReady) unawaited(sync.onSnapshot(snapshot));
        if (mounted) setState(() {});
      }));
      _subs.add(client.playlistUpdates.listen((items) {
        for (final item in items) {
          unawaited(_prefetch(item));
        }
        if (mounted) setState(() {});
      }));
      _subs.add(client.peerEvents.listen((_) {
        if (mounted) setState(() {});
      }));
      unawaited(client.done.then((_) {
        if (mounted) setState(() => _disconnected = true);
      }));

      _uiTicker = Timer.periodic(
        const Duration(milliseconds: 250),
        (_) => setState(() {}),
      );
      setState(() => _connecting = false);

      // §6.2 v1 policy: fully prefetch everything before playing.
      for (final item in client.playlist) {
        unawaited(_prefetch(item));
      }

      // Wait for the §4 join burst before converting session time; then
      // converge on whatever the host is doing right now (late join, §5.3).
      unawaited(_waitForClock(client, sync));
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _connecting = false;
          _connectError = 'Could not connect: $e';
        });
      }
    }
  }

  Future<void> _waitForClock(JamGuestClient client, AudioSyncController sync) async {
    while (!client.clock.isSynchronized) {
      if (_disconnected || !mounted || _client != client) return;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    if (!mounted || _client != client) return;
    setState(() => _clockReady = true);
    await sync.onSnapshot(client.snapshot);
  }

  // --- Prefetch (§6.2) -----------------------------------------------------------

  Future<void> _prefetch(MediaItem item) async {
    final client = _client;
    final cacheDir = _cacheDir;
    if (client == null || cacheDir == null) return;
    if (_fetches.containsKey(item.mediaId)) return;
    final state = _FetchState();
    _fetches[item.mediaId] = state;
    if (mounted) setState(() {});

    try {
      // fetchMedia reports media_status upstream (§6.3) and verifies sha256.
      final bytes = await client.fetchMedia(
        item.mediaId,
        onProgress: (p) {
          state.progress = p;
          if (mounted) setState(() {});
        },
      );
      final path =
          '${cacheDir.path}/localjam_${item.mediaId}.${extensionForMime(item.mime)}';
      await File(path).writeAsBytes(bytes, flush: true);
      state.path = path;
      if (mounted) setState(() {});
      await _sync?.notifyMediaAvailable(item.mediaId);
    } on Object catch (e) {
      state.error = '$e';
      _fetches.remove(item.mediaId); // Allow retry on next playlist update.
      if (mounted) setState(() {});
    }
  }

  // --- Build ----------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_joined ? _client!.sessionName : 'Join a Jam'),
      ),
      body: SafeArea(
        child: _joined ? _buildSession(context) : _buildConnect(context),
      ),
    );
  }

  Widget _buildConnect(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(
          'Paste the join URI from the host\'s screen.',
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _uriController,
          autocorrect: false,
          enableSuggestions: false,
          maxLines: 3,
          minLines: 1,
          decoration: const InputDecoration(
            labelText: 'localjam://join?…',
            prefixIcon: Icon(Icons.link),
          ),
          onSubmitted: (_) => _connect(),
        ),
        if (_connectError != null) ...[
          const SizedBox(height: 12),
          Text(
            _connectError!,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.error),
          ),
        ],
        const SizedBox(height: 24),
        FilledButton.icon(
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 18),
          ),
          icon: _connecting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.login),
          label: Text(_connecting ? 'Connecting…' : 'Connect'),
          onPressed: _connecting ? null : _connect,
        ),
      ],
    );
  }

  Widget _buildSession(BuildContext context) {
    final theme = Theme.of(context);
    final client = _client!;
    final sync = _sync!;
    final snapshot = client.snapshot;
    final currentItem = client.playlist
        .where((i) => i.mediaId == snapshot.mediaId)
        .firstOrNull;

    final positionUs = _clockReady && client.clock.isSynchronized
        ? snapshot.positionAt(client.sessionNowUs)
        : snapshot.positionUs;
    final durationUs =
        sync.loadedDurationUs.value ?? currentItem?.durationUs;

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        if (_disconnected) ...[
          Card(
            color: theme.colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(Icons.link_off, color: theme.colorScheme.onErrorContainer),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Connection closed by host.',
                      style: TextStyle(
                        color: theme.colorScheme.onErrorContainer,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],

        // --- Now playing ------------------------------------------------------
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Text(
                  currentItem?.name ?? 'Nothing playing',
                  style: theme.textTheme.titleMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Text(
                  _clockReady
                      ? snapshot.status.name
                      : '${snapshot.status.name} · syncing clock…',
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 12),
                LinearProgressIndicator(
                  value: durationUs == null || durationUs <= 0
                      ? null
                      : (positionUs / durationUs).clamp(0.0, 1.0),
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(formatPositionUs(positionUs),
                        style: theme.textTheme.bodySmall),
                    Text(
                      durationUs == null
                          ? '--:--'
                          : formatPositionUs(durationUs),
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),

        // --- Telemetry + nudge -----------------------------------------------
        SyncTelemetryStrip(
          controller: sync,
          clockOffsetUs: () => client.clock.offsetUs,
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: NudgeSlider(controller: sync),
          ),
        ),
        const SizedBox(height: 16),

        // --- Peers --------------------------------------------------------------
        Text(
          'Peers (${client.peers.length + 1})',
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Card(
          child: Column(
            children: [
              ListTile(
                dense: true,
                leading: const Icon(Icons.person),
                title: Text('You (${client.selfPeerId})'),
              ),
              for (final peer in client.peers)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.person_outline),
                  title: Text(peer.clientName),
                  subtitle: Text('${peer.peerId} · ${peer.clientKind}'),
                ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // --- Playlist + prefetch progress -----------------------------------------
        Text('Playlist', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        Card(
          child: Column(
            children: [
              for (final item in client.playlist)
                _buildPlaylistTile(theme, snapshot, item),
            ],
          ),
        ),
        const SizedBox(height: 32),
      ],
    );
  }

  Widget _buildPlaylistTile(
    ThemeData theme,
    PlaybackSnapshot snapshot,
    MediaItem item,
  ) {
    final fetch = _fetches[item.mediaId];
    final ready = fetch?.path != null;
    return ListTile(
      dense: true,
      selected: item.mediaId == snapshot.mediaId,
      leading: Icon(
        item.mediaId == snapshot.mediaId
            ? Icons.graphic_eq
            : Icons.audio_file_outlined,
      ),
      title: Text(item.name, overflow: TextOverflow.ellipsis),
      subtitle: ready || fetch == null
          ? Text(ready ? 'ready' : 'waiting')
          : Padding(
              padding: const EdgeInsets.only(top: 4),
              child: LinearProgressIndicator(value: fetch.progress),
            ),
      trailing: ready
          ? Icon(Icons.check_circle_outline,
              size: 18, color: theme.colorScheme.primary)
          : null,
    );
  }
}
