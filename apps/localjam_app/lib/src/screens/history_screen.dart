/// Past jams: every session leaves a record (queue + who added what + who
/// was there); tracks still in the local cache can seed a new session
/// ("Host it again").
library;

import 'package:flutter/material.dart';
import 'package:localjam_client/localjam_client.dart';

import 'host_screen.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  JamHistoryStore? _store;
  List<JamHistoryRecord>? _records;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final store = _store ??= await JamHistoryStore.open();
    final records = store == null ? const <JamHistoryRecord>[] : await store.list();
    if (mounted) setState(() => _records = records);
  }

  Future<void> _delete(JamHistoryRecord record) async {
    await _store?.delete(record.sessionId);
    await _load();
  }

  void _hostAgain(JamHistoryRecord record) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => HostScreen(
          initialPaths: [
            for (final track in record.replayableTracks) track.localPath!,
          ],
          initialName: record.sessionName,
        ),
      ),
    );
  }

  String _when(DateTime time) {
    final now = DateTime.now();
    final difference = now.difference(time);
    if (difference.inMinutes < 1) return 'just now';
    if (difference.inHours < 1) return '${difference.inMinutes} min ago';
    if (difference.inDays < 1) return '${difference.inHours} h ago';
    if (difference.inDays < 30) return '${difference.inDays} d ago';
    return '${time.year}-${time.month.toString().padLeft(2, '0')}-'
        '${time.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final records = _records;
    return Scaffold(
      appBar: AppBar(title: const Text('Past jams')),
      body: records == null
          ? const Center(child: CircularProgressIndicator())
          : records.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  'No jams yet — every session you host or join will show '
                  'up here, queue and all.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                for (final record in records) _buildRecord(theme, record),
              ],
            ),
    );
  }

  Widget _buildRecord(ThemeData theme, JamHistoryRecord record) {
    final replayable = record.replayableTracks.length;
    return Card(
      child: ExpansionTile(
        leading: Icon(
          record.wasHost ? Icons.wifi_tethering : Icons.headphones,
        ),
        title: Text(record.sessionName, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          [
            _when(record.updatedAt),
            '${record.tracks.length} track${record.tracks.length == 1 ? '' : 's'}',
            if (record.peerNames.isNotEmpty)
              'with ${record.peerNames.join(', ')}',
          ].join(' · '),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        children: [
          for (final track in record.tracks)
            ListTile(
              dense: true,
              leading: Icon(
                track.existsLocally
                    ? Icons.audio_file
                    : Icons.audio_file_outlined,
                color: track.existsLocally
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant,
              ),
              title: Text(
                track.item.displayTitle,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                [
                  if (track.item.artist != null) track.item.artist!,
                  if (track.addedByName != null)
                    'added by ${track.addedByName}',
                  if (!track.existsLocally) 'no longer on this device',
                ].join(' · '),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton.icon(
                  icon: const Icon(Icons.delete_outline, size: 18),
                  label: const Text('Forget'),
                  onPressed: () => _delete(record),
                ),
                const SizedBox(width: 8),
                FilledButton.tonalIcon(
                  icon: const Icon(Icons.replay, size: 18),
                  label: Text(
                    replayable == record.tracks.length
                        ? 'Host it again'
                        : 'Host again ($replayable playable)',
                  ),
                  onPressed: replayable == 0 ? null : () => _hostAgain(record),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
