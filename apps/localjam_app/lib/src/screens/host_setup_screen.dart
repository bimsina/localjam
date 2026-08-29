/// Starting a room, in one tap.
///
/// The name is already filled in and music is optional — a host can start
/// empty and add tracks once live (`JamHostEngine.addMediaFile` has always
/// worked mid-session; only the old UI hid the button after setup). What this
/// screen adds over the old one is the network: on a trip there is usually no
/// Wi-Fi, so somebody has to run a hotspot, and the screen says which network
/// guests must be on before anyone taps Start.
library;

import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:localjam_client/localjam_client.dart';

import '../design/tokens.dart';
import '../design/typography.dart';
import '../state/session_controller.dart';
import '../util/network.dart';
import '../util/permissions.dart';
import '../widgets/section.dart';

class HostSetupScreen extends StatefulWidget {
  const HostSetupScreen({super.key, this.initialPaths, this.initialName});

  /// Tracks to preload — the "host it again" seam from jam history.
  final List<String>? initialPaths;

  /// Room name to preload, also from history.
  final String? initialName;

  @override
  State<HostSetupScreen> createState() => _HostSetupScreenState();
}

class _HostSetupScreenState extends State<HostSetupScreen> {
  final TextEditingController _name = TextEditingController();
  final List<String> _paths = [];
  JamPolicy _policy = JamPolicy.open;
  bool _discoverable = true;
  bool _starting = false;
  JamNetworkStatus _network = JamNetworkStatus.offline;
  Timer? _networkPoll;

  @override
  void initState() {
    super.initState();
    _paths.addAll(widget.initialPaths ?? const []);
    unawaited(_prefillName());
    unawaited(_scanDocuments());
    unawaited(_refreshNetwork());
    _networkPoll = Timer.periodic(
      const Duration(seconds: 3),
      (_) => unawaited(_refreshNetwork()),
    );
  }

  @override
  void dispose() {
    _networkPoll?.cancel();
    _name.dispose();
    super.dispose();
  }

  Future<void> _prefillName() async {
    final preset = widget.initialName;
    if (preset != null && preset.isNotEmpty) {
      _name.text = preset;
      return;
    }
    final identity = await JamIdentity.displayName();
    if (mounted && _name.text.isEmpty) _name.text = "$identity's Jam";
  }

  /// Files pushed into the app's Documents folder (iOS Files, `simctl push`)
  /// show up without a trip through the picker.
  Future<void> _scanDocuments() async {
    final found = await findAudioFilesInDocuments();
    if (!mounted || found.isEmpty) return;
    setState(() {
      for (final path in found) {
        if (!_paths.contains(path)) _paths.add(path);
      }
    });
  }

  Future<void> _refreshNetwork() async {
    final status = await currentNetwork();
    if (mounted && status.addresses.join() != _network.addresses.join()) {
      setState(() => _network = status);
    }
  }

  Future<void> _pickFiles() async {
    final typeGroup = XTypeGroup(
      label: 'Audio',
      extensions: supportedAudioExtensions,
      // UTIs make the picker work on iOS/macOS where extensions alone don't.
      uniformTypeIdentifiers: const ['public.audio'],
    );
    try {
      final files = await openFiles(acceptedTypeGroups: [typeGroup]);
      if (!mounted || files.isEmpty) return;
      setState(() {
        for (final file in files) {
          if (!_paths.contains(file.path)) _paths.add(file.path);
        }
      });
    } catch (e) {
      _showError('Could not open the file picker: $e');
    }
  }

  Future<void> _pickFromLibrary() async {
    if (!await ensureAudioLibraryPermission()) return;
    final tracks = await JamMediaLibrary.queryAudio();
    if (!mounted || tracks.isEmpty) return;
    final chosen = await showModalBottomSheet<List<JamLibraryTrack>>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _LibrarySheet(tracks: tracks),
    );
    if (chosen == null || chosen.isEmpty) return;
    for (final track in chosen) {
      final path = await JamMediaLibrary.resolve(track);
      if (!mounted) return;
      if (path != null && !_paths.contains(path)) {
        setState(() => _paths.add(path));
      }
    }
  }

  Future<void> _start() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      _showError('Give the room a name.');
      return;
    }
    setState(() => _starting = true);
    final session = JamSession.read(context);
    await ensureLocalNetworkPermission();
    final started = await session.startHost(
      sessionName: name,
      policy: _policy,
      discoverable: _discoverable,
      paths: List.of(_paths),
    );
    if (!mounted) return;
    setState(() => _starting = false);
    if (started) {
      // Replace setup rather than stack on it, so dismissing the room lands
      // on home instead of back in the form that created it.
      context.pushReplacement('/room');
    } else {
      _showError(session.error ?? 'Could not start the room.');
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    return Scaffold(
      appBar: AppBar(title: const Text('Start a jam')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          JamSpace.page,
          JamSpace.sm,
          JamSpace.page,
          JamSpace.huge,
        ),
        children: [
          TextField(
            controller: _name,
            textCapitalization: TextCapitalization.words,
            textInputAction: TextInputAction.done,
            style: context.jamTitle,
            decoration: const InputDecoration(hintText: 'Room name'),
          ),
          const SizedBox(height: JamSpace.section),

          _NetworkNotice(network: _network),

          JamSection(
            title: 'Guests',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.all(JamSpace.card),
                  child: SegmentedButton<JamPolicy>(
                    segments: const [
                      ButtonSegment(
                        value: JamPolicy.open,
                        label: Text('Everything'),
                      ),
                      ButtonSegment(
                        value: JamPolicy.jam,
                        label: Text('Add music'),
                      ),
                      ButtonSegment(
                        value: JamPolicy.listenOnly,
                        label: Text('Listen'),
                      ),
                    ],
                    selected: {_policy},
                    showSelectedIcon: false,
                    onSelectionChanged: (selection) =>
                        setState(() => _policy = selection.first),
                  ),
                ),
                Divider(height: 0.5, color: colors.separator),
                SwitchListTile(
                  value: _discoverable,
                  onChanged: (value) => setState(() => _discoverable = value),
                  title: const Text('Show the room to this network'),
                  subtitle: Text(
                    'Anyone here can join without the code.',
                    style: context.jamFootnote,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: JamSpace.section),

          JamSection(
            title: 'Music',
            trailing: Text(
              _paths.isEmpty ? 'Optional' : '${_paths.length}',
              style: context.jamFootnote,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.all(JamSpace.card),
                  child: Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => unawaited(_pickFiles()),
                          icon: const Icon(Icons.folder_open_rounded, size: 20),
                          label: const Text('Add files'),
                        ),
                      ),
                      if (JamMediaLibrary.isSupported) ...[
                        const SizedBox(width: JamSpace.md),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () => unawaited(_pickFromLibrary()),
                            icon: const Icon(
                              Icons.library_music_outlined,
                              size: 20,
                            ),
                            label: const Text('Library'),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (_paths.isNotEmpty) ...[
                  Divider(height: 0.5, color: colors.separator),
                  for (final path in _paths)
                    ListTile(
                      dense: true,
                      title: Text(
                        _basename(path),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.jamByline,
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.close_rounded, size: 18),
                        onPressed: () => setState(() => _paths.remove(path)),
                      ),
                    ),
                ] else
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      JamSpace.card,
                      0,
                      JamSpace.card,
                      JamSpace.card,
                    ),
                    child: Text(
                      'You can add music once the room is up — and so can '
                      'everyone else.',
                      style: context.jamFootnote,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: colors.canvas,
          border: Border(top: BorderSide(color: colors.separator, width: 0.5)),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(JamSpace.md),
            child: FilledButton(
              onPressed: _starting ? null : () => unawaited(_start()),
              child: _starting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Start'),
            ),
          ),
        ),
      ),
    );
  }
}

String _basename(String path) => path.split(Platform.pathSeparator).last;

/// What guests have to be on. Silent when everything is normal; the point is
/// the off-network case, where nobody can join no matter how the room is set
/// up.
class _NetworkNotice extends StatelessWidget {
  const _NetworkNotice({required this.network});

  final JamNetworkStatus network;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    if (!network.connected) {
      return Padding(
        padding: const EdgeInsets.only(bottom: JamSpace.section),
        child: _Notice(
          icon: Icons.wifi_off_rounded,
          color: colors.warning,
          title: 'No network',
          detail:
              'Turn on your hotspot and have everyone connect to it, '
              'then start the room.',
        ),
      );
    }
    if (network.isHotspotHost) {
      return Padding(
        padding: const EdgeInsets.only(bottom: JamSpace.section),
        child: _Notice(
          icon: Icons.wifi_tethering_rounded,
          color: colors.textSecondary,
          title: 'Sharing your hotspot',
          detail:
              'Rooms do not announce themselves across a hotspot — show '
              'guests the code once you start.',
        ),
      );
    }
    return const SizedBox.shrink();
  }
}

class _Notice extends StatelessWidget {
  const _Notice({
    required this.icon,
    required this.color,
    required this.title,
    required this.detail,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    return Container(
      padding: const EdgeInsets.all(JamSpace.card),
      decoration: BoxDecoration(
        color: colors.surfaceMuted,
        borderRadius: BorderRadius.circular(JamRadius.md),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: JamSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: context.jamRowTitle.copyWith(color: color)),
                const SizedBox(height: JamSpace.xxs),
                Text(detail, style: context.jamFootnote),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The Android MediaStore picker.
class _LibrarySheet extends StatefulWidget {
  const _LibrarySheet({required this.tracks});

  final List<JamLibraryTrack> tracks;

  @override
  State<_LibrarySheet> createState() => _LibrarySheetState();
}

class _LibrarySheetState extends State<_LibrarySheet> {
  final Set<int> _selected = {};

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      maxChildSize: 0.95,
      builder: (context, scrollController) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              JamSpace.page,
              JamSpace.sm,
              JamSpace.md,
              JamSpace.sm,
            ),
            child: Row(
              children: [
                Expanded(child: Text('Your music', style: context.jamTitle)),
                FilledButton(
                  onPressed: _selected.isEmpty
                      ? null
                      : () => Navigator.of(context).pop(
                          widget.tracks
                              .where((t) => _selected.contains(t.id))
                              .toList(),
                        ),
                  child: Text('Add ${_selected.length}'),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              controller: scrollController,
              itemCount: widget.tracks.length,
              itemBuilder: (context, index) {
                final track = widget.tracks[index];
                return CheckboxListTile(
                  value: _selected.contains(track.id),
                  onChanged: (checked) => setState(() {
                    if (checked ?? false) {
                      _selected.add(track.id);
                    } else {
                      _selected.remove(track.id);
                    }
                  }),
                  title: Text(
                    track.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    track.artist ?? 'Unknown artist',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
