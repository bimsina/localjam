import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:localjam_client/localjam_client.dart';

import '../util/format.dart';
import '../util/permissions.dart';
import '../widgets/artwork.dart';
import '../widgets/nudge_slider.dart';
import '../widgets/sync_telemetry_strip.dart';
import 'scan_screen.dart';

/// Guest flow: pick a nearby room (§1 mDNS), scan the host's QR, or paste a
/// `localjam://join?...` URI, then hand everything else — connection, clock
/// sync, prefetching, synchronized playback — to a [JamGuestEngine]. This
/// screen only renders the engine's state.
class JoinScreen extends StatefulWidget {
  const JoinScreen({super.key});

  @override
  State<JoinScreen> createState() => _JoinScreenState();
}

class _JoinScreenState extends State<JoinScreen> {
  final TextEditingController _uriController = TextEditingController();

  JamGuestEngine? _engine;
  bool _connecting = false;
  bool _uploading = false;
  String? _connectError;

  final List<StreamSubscription<Object?>> _subs = [];
  Timer? _uiTicker;

  /// Nearby-room discovery (§1): running while the connect form is shown.
  final JamRoomBrowser _browser = JamRoomBrowser();

  bool get _joined => _engine != null;

  @override
  void initState() {
    super.initState();
    _browser.rooms.addListener(_onNearbyRooms);
    unawaited(_browser.start());
  }

  void _onNearbyRooms() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _browser.rooms.removeListener(_onNearbyRooms);
    unawaited(_browser.stop());
    _uiTicker?.cancel();
    for (final sub in _subs) {
      sub.cancel();
    }
    _engine?.prefetchStates.removeListener(_onPrefetch);
    _engine?.sessionEnded.removeListener(_onSessionEnded);
    // Fire-and-forget teardown; the screen is going away.
    unawaited(_engine?.close());
    _uriController.dispose();
    super.dispose();
  }

  void _onPrefetch() {
    if (mounted) setState(() {});
  }

  void _onSessionEnded() {
    if (mounted) setState(() {});
  }

  // --- Connect -----------------------------------------------------------------

  Future<void> _connect({String? uriOverride}) async {
    final raw = uriOverride ?? _uriController.text.trim();
    if (raw.isEmpty || _connecting) return;
    if (uriOverride != null) _uriController.text = uriOverride;
    setState(() {
      _connecting = true;
      _connectError = null;
    });
    // Android 17 gates LAN sockets behind a runtime permission.
    await ensureLocalNetworkPermission();

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
      // clientName defaults to the device's persistent quirky JamIdentity.
      final engine = await JamGuestEngine.join(joinUri);
      _engine = engine;
      void refresh(Object? _) {
        if (mounted) setState(() {});
      }

      _subs.add(engine.states.listen(refresh));
      _subs.add(engine.playlistUpdates.listen(refresh));
      _subs.add(engine.peerEvents.listen(refresh));
      _subs.add(engine.connectionStates.listen(refresh));
      _subs.add(engine.permissionUpdates.listen(refresh));
      _subs.add(
        engine.errors.listen((error) {
          // Transient denials surface as snackbars; fatal ones end the
          // session and are handled by sessionEnded.
          if (!error.fatal && mounted) {
            ScaffoldMessenger.of(context)
              ..hideCurrentSnackBar()
              ..showSnackBar(
                SnackBar(
                  content: Text(
                    error.code == ErrorCode.notAllowed
                        ? 'The host has not allowed that.'
                        : error.message,
                  ),
                ),
              );
          }
        }),
      );
      engine.prefetchStates.addListener(_onPrefetch);
      engine.sessionEnded.addListener(_onSessionEnded);

      _uiTicker = Timer.periodic(
        const Duration(milliseconds: 250),
        (_) => setState(() {}),
      );
      setState(() => _connecting = false);
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _connecting = false;
          _connectError = 'Could not connect: $e';
        });
      }
    }
  }

  // --- Contribute files (§6.4) ---------------------------------------------

  /// Picks audio files and uploads them to the host via the engine; the
  /// playlist broadcast brings them back through the normal plumbing.
  Future<void> _addFiles() async {
    final engine = _engine;
    if (engine == null || _uploading) return;
    const typeGroup = XTypeGroup(
      label: 'Audio',
      extensions: supportedAudioExtensions,
      // UTIs make the picker work on iOS/macOS where extensions alone don't.
      uniformTypeIdentifiers: ['public.audio'],
    );
    final List<XFile> files;
    try {
      files = await openFiles(acceptedTypeGroups: const [typeGroup]);
    } catch (e) {
      _showSnack('File picker failed: $e');
      return;
    }
    if (!mounted || files.isEmpty) return;
    setState(() => _uploading = true);
    try {
      for (final file in files) {
        await engine.addMediaFile(File(file.path));
      }
    } catch (e) {
      _showSnack('Upload failed: $e');
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  // --- Build ----------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_joined ? _engine!.sessionName : 'Join a Jam'),
      ),
      body: SafeArea(
        child: _joined ? _buildSession(context) : _buildConnect(context),
      ),
    );
  }

  Future<void> _scanQr() async {
    final scanned = await Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => const ScanScreen()));
    if (scanned == null || !mounted) return;
    await _connect(uriOverride: scanned);
  }

  Widget _buildConnect(BuildContext context) {
    final theme = Theme.of(context);
    final nearby = _browser.rooms.value;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        // --- Nearby rooms (§1 mDNS discovery) -------------------------------
        Text('Nearby jams', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        if (nearby.isEmpty)
          Text(
            'No rooms found on this network yet — scan the host\'s QR or '
            'paste their join link below.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          )
        else
          Card(
            child: Column(
              children: [
                for (final room in nearby)
                  ListTile(
                    leading: const Icon(Icons.speaker_group_outlined),
                    title: Text(
                      room.sessionName,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      room.joinUri.queryParameters['host'] ?? '',
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: const Icon(Icons.login),
                    onTap: _connecting
                        ? null
                        : () => _connect(uriOverride: '${room.joinUri}'),
                  ),
              ],
            ),
          ),
        const SizedBox(height: 16),
        // mobile_scanner has no Windows/Linux implementation.
        if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) ...[
          OutlinedButton.icon(
            icon: const Icon(Icons.qr_code_scanner),
            label: const Text('Scan QR code'),
            onPressed: _connecting ? null : _scanQr,
          ),
          const SizedBox(height: 24),
        ],
        Text(
          'Or paste the join URI from the host\'s screen.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
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

  /// Terminal screen for an ended session — distinct from the transient
  /// "reconnecting…" banner: nothing here will recover, so offer the way out.
  Widget _buildEnded(BuildContext context, JamSessionEndReason reason) {
    final theme = Theme.of(context);
    final (icon, title, message) = switch (reason) {
      JamSessionEndReason.rejected => (
        Icons.block,
        'Join rejected',
        'The host declined this connection — the session may have '
            'restarted, be full, or the invite is no longer valid.',
      ),
      JamSessionEndReason.hostGone => (
        Icons.portable_wifi_off,
        'Session ended',
        'The host could not be reached again. The jam is over.',
      ),
      JamSessionEndReason.kicked => (
        Icons.person_remove_outlined,
        'Removed from the jam',
        'The host removed you from this session.',
      ),
      JamSessionEndReason.closedLocally => (
        Icons.check_circle_outline,
        'Left the session',
        'You left this jam.',
      ),
    };
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text(title, style: theme.textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              icon: const Icon(Icons.home_outlined),
              label: const Text('Back to Home'),
              onPressed: () =>
                  Navigator.of(context).popUntil((route) => route.isFirst),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSession(BuildContext context) {
    final theme = Theme.of(context);
    final engine = _engine!;
    final endReason = engine.sessionEnded.value;
    if (endReason != null) return _buildEnded(context, endReason);
    final snapshot = engine.snapshot;
    final currentItem = engine.currentItem;

    final positionUs = engine.positionUsNow() ?? snapshot.positionUs;
    final durationUs = engine.loadedDurationUs.value ?? currentItem?.durationUs;
    final connection = engine.connectionState;

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        if (connection != JamConnectionState.connected) ...[
          Card(
            color: theme.colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(
                    connection == JamConnectionState.reconnecting
                        ? Icons.sync_problem
                        : Icons.link_off,
                    color: theme.colorScheme.onErrorContainer,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      connection == JamConnectionState.reconnecting
                          ? 'Connection lost — reconnecting…'
                          : 'Connection closed by host.',
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
                JamArtwork(
                  engine: engine,
                  item: currentItem,
                  size: 96,
                  icon: Icons.music_note_outlined,
                ),
                const SizedBox(height: 12),
                Text(
                  currentItem?.displayTitle ?? 'Nothing playing',
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
                  engine.clockSynced
                      ? snapshot.status.name
                      : '${snapshot.status.name} · syncing clock…',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
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
                    Text(
                      formatPositionUs(positionUs),
                      style: theme.textTheme.bodySmall,
                    ),
                    Text(
                      durationUs == null
                          ? '--:--'
                          : formatPositionUs(durationUs),
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
                // §5.6: transport appears only when the host allows guests
                // to control playback (requests are re-validated host-side
                // anyway; the snackbar handles the race).
                if (engine.can(JamCapability.controlPlayback)) ...[
                  const SizedBox(height: 4),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.skip_previous),
                        onPressed: () => engine.requestPrevious(),
                      ),
                      IconButton.filled(
                        icon: Icon(
                          snapshot.status == PlaybackStatus.playing
                              ? Icons.pause
                              : Icons.play_arrow,
                        ),
                        onPressed: () =>
                            snapshot.status == PlaybackStatus.playing
                            ? engine.requestPause()
                            : engine.requestPlay(),
                      ),
                      IconButton(
                        icon: const Icon(Icons.skip_next),
                        onPressed: () => engine.requestNext(),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),

        // --- Telemetry + nudge -----------------------------------------------
        SyncTelemetryStrip(
          controller: engine.sync,
          clockOffsetUs: () => engine.clockOffsetUs,
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: NudgeSlider(engine: engine),
          ),
        ),
        const SizedBox(height: 16),

        // --- Peers --------------------------------------------------------------
        Text(
          'Peers (${engine.peers.length + 1})',
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Card(
          child: Column(
            children: [
              ListTile(
                dense: true,
                leading: const Icon(Icons.person),
                title: Text('You (${engine.selfPeerId})'),
                trailing:
                    engine.permissions.roleOf(engine.selfPeerId) ==
                        JamRole.cohost
                    ? const Chip(
                        label: Text('Co-host'),
                        visualDensity: VisualDensity.compact,
                      )
                    : null,
              ),
              for (final peer in engine.peers)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.person_outline),
                  title: Text(peer.clientName),
                  subtitle: Text('${peer.peerId} · ${peer.clientKind}'),
                  trailing:
                      engine.permissions.roleOf(peer.peerId) == JamRole.cohost
                      ? const Chip(
                          label: Text('Co-host'),
                          visualDensity: VisualDensity.compact,
                        )
                      : null,
                ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // --- Playlist + prefetch progress -----------------------------------------
        Row(
          children: [
            Text('Playlist', style: theme.textTheme.titleMedium),
            const Spacer(),
            if (engine.can(JamCapability.addTracks))
              TextButton.icon(
                icon: _uploading
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.add),
                label: Text(_uploading ? 'Uploading…' : 'Add files'),
                onPressed: _uploading ? null : _addFiles,
              ),
          ],
        ),
        ValueListenableBuilder<double?>(
          valueListenable: engine.uploadProgress,
          builder: (context, progress, _) => progress == null
              ? const SizedBox.shrink()
              : Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: LinearProgressIndicator(value: progress),
                ),
        ),
        const SizedBox(height: 8),
        Card(
          child: Column(
            children: [
              for (final item in engine.playlist)
                _buildPlaylistTile(theme, engine, snapshot, item),
            ],
          ),
        ),
        const SizedBox(height: 32),
      ],
    );
  }

  Widget _buildPlaylistTile(
    ThemeData theme,
    JamGuestEngine engine,
    PlaybackSnapshot snapshot,
    MediaItem item,
  ) {
    final fetch = engine.prefetchStates.value[item.mediaId];
    final ready = fetch?.ready ?? false;
    final byline = engine.addedByLabel(item, engine.peers);
    // §5.6: reorder needs editQueue; removing your own track never does.
    final canEdit = engine.can(JamCapability.editQueue);
    final canRemove = canEdit || item.addedBy == engine.selfPeerId;
    final canSelect = engine.can(JamCapability.controlPlayback);
    return ListTile(
      dense: true,
      selected: item.mediaId == snapshot.mediaId,
      leading: JamArtwork(
        engine: engine,
        item: item,
        icon: item.mediaId == snapshot.mediaId
            ? Icons.graphic_eq
            : Icons.audio_file_outlined,
      ),
      title: Text(item.displayTitle, overflow: TextOverflow.ellipsis),
      onTap: canSelect ? () => engine.requestSetMedia(item.mediaId) : null,
      subtitle: switch (fetch?.phase) {
        null => const Text('waiting'),
        JamPrefetchPhase.ready => Text(
          byline == null ? 'ready' : 'ready · added by $byline',
          overflow: TextOverflow.ellipsis,
        ),
        JamPrefetchPhase.notQueued => const Text('not queued'),
        JamPrefetchPhase.queued when fetch!.error != null => Text(
          'retrying: ${fetch.error}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: theme.colorScheme.error),
        ),
        JamPrefetchPhase.queued => const Text('queued'),
        JamPrefetchPhase.failed => Text(
          'failed: ${fetch!.error}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: theme.colorScheme.error),
        ),
        JamPrefetchPhase.fetching => Padding(
          padding: const EdgeInsets.only(top: 4),
          child: LinearProgressIndicator(value: fetch!.progress),
        ),
      },
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (ready)
            Icon(
              Icons.check_circle_outline,
              size: 18,
              color: theme.colorScheme.primary,
            ),
          if (canEdit || canRemove)
            PopupMenuButton<String>(
              iconSize: 18,
              onSelected: (choice) {
                final index = engine.playlist.indexWhere(
                  (i) => i.mediaId == item.mediaId,
                );
                switch (choice) {
                  case 'up':
                    engine.requestQueueMove(item.mediaId, index - 1);
                  case 'down':
                    engine.requestQueueMove(item.mediaId, index + 1);
                  case 'remove':
                    engine.requestQueueRemove(item.mediaId);
                }
              },
              itemBuilder: (context) => [
                if (canEdit)
                  const PopupMenuItem(value: 'up', child: Text('Move up')),
                if (canEdit)
                  const PopupMenuItem(value: 'down', child: Text('Move down')),
                if (canRemove)
                  const PopupMenuItem(value: 'remove', child: Text('Remove')),
              ],
            ),
        ],
      ),
    );
  }
}
