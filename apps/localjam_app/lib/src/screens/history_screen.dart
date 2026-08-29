/// Past jams: every session leaves a record (queue + who added what + who was
/// there); tracks still on this device can seed a new room in one tap.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:localjam_client/localjam_client.dart';

import '../design/tokens.dart';
import '../design/typography.dart';
import '../router.dart';
import '../widgets/peer_avatar.dart';
import '../widgets/section.dart';

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
    unawaited(_load());
  }

  Future<void> _load() async {
    final store = _store ??= await JamHistoryStore.open();
    final records = store == null
        ? const <JamHistoryRecord>[]
        : await store.list();
    if (mounted) setState(() => _records = records);
  }

  Future<void> _delete(JamHistoryRecord record) async {
    await _store?.delete(record.sessionId);
    await _load();
  }

  void _hostAgain(JamHistoryRecord record) {
    context.push(
      '/host',
      extra: HostSetupArgs(
        paths: [for (final track in record.replayableTracks) track.localPath!],
        name: record.sessionName,
      ),
    );
  }

  static String _when(DateTime time) {
    final difference = DateTime.now().difference(time);
    if (difference.inMinutes < 1) return 'Just now';
    if (difference.inHours < 1) return '${difference.inMinutes} min ago';
    if (difference.inDays < 1) return '${difference.inHours} h ago';
    if (difference.inDays < 30) return '${difference.inDays} d ago';
    return '${time.year}-${time.month.toString().padLeft(2, '0')}-'
        '${time.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final records = _records;
    return Scaffold(
      appBar: AppBar(title: const Text('Past jams')),
      body: switch (records) {
        null => const Center(child: CircularProgressIndicator()),
        [] => const _NoHistory(),
        _ => ListView.separated(
          padding: const EdgeInsets.fromLTRB(
            JamSpace.page,
            JamSpace.sm,
            JamSpace.page,
            JamSpace.huge,
          ),
          itemCount: records.length,
          separatorBuilder: (_, _) => const SizedBox(height: JamSpace.section),
          itemBuilder: (context, index) => _RecordCard(
            record: records[index],
            onForget: () => unawaited(_delete(records[index])),
            onHostAgain: () => _hostAgain(records[index]),
          ),
        ),
      },
    );
  }
}

class _RecordCard extends StatelessWidget {
  const _RecordCard({
    required this.record,
    required this.onForget,
    required this.onHostAgain,
  });

  final JamHistoryRecord record;
  final VoidCallback onForget;
  final VoidCallback onHostAgain;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final replayable = record.replayableTracks.length;
    final trackCount = record.tracks.length;

    return JamSection(
      title: record.sessionName,
      trailing: Text(
        _HistoryScreenState._when(record.updatedAt),
        style: context.jamFootnote,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(JamSpace.card),
            child: Row(
              children: [
                Icon(
                  record.wasHost
                      ? Icons.wifi_tethering_rounded
                      : Icons.headphones_rounded,
                  size: 18,
                  color: colors.textSecondary,
                ),
                const SizedBox(width: JamSpace.sm),
                Expanded(
                  child: Text(
                    '${record.wasHost ? 'You hosted' : 'You joined'} · '
                    '$trackCount ${trackCount == 1 ? 'track' : 'tracks'}',
                    style: context.jamByline,
                  ),
                ),
                if (record.peerNames.isNotEmpty)
                  PeerAvatarRow(
                    names: record.peerNames,
                    size: 26,
                    maxVisible: 4,
                  ),
              ],
            ),
          ),
          Divider(height: 0.5, color: colors.separator),
          for (final track in record.tracks.take(4))
            ListTile(
              dense: true,
              title: Text(
                track.item.displayTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.jamBody.copyWith(
                  color: track.existsLocally
                      ? colors.textPrimary
                      : colors.textTertiary,
                ),
              ),
              subtitle: Text(
                [
                  ?track.item.artist,
                  if (track.addedByName != null)
                    'added by ${track.addedByName}',
                  if (!track.existsLocally) 'gone from this device',
                ].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          if (trackCount > 4)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                JamSpace.page,
                0,
                JamSpace.page,
                JamSpace.sm,
              ),
              child: Text(
                '+ ${trackCount - 4} more',
                style: context.jamFootnote,
              ),
            ),
          Divider(height: 0.5, color: colors.separator),
          Padding(
            padding: const EdgeInsets.all(JamSpace.md),
            child: Row(
              children: [
                TextButton(onPressed: onForget, child: const Text('Forget')),
                const Spacer(),
                FilledButton(
                  onPressed: replayable == 0 ? null : onHostAgain,
                  child: Text(
                    replayable == trackCount
                        ? 'Host it again'
                        : 'Host $replayable again',
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _NoHistory extends StatelessWidget {
  const _NoHistory();

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(JamSpace.xxxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.history_rounded, size: 40, color: colors.textTertiary),
            const SizedBox(height: JamSpace.lg),
            Text('No jams yet', style: context.jamTitle),
            const SizedBox(height: JamSpace.sm),
            Text(
              'Every room you host or join shows up here, queue and all.',
              textAlign: TextAlign.center,
              style: context.jamByline,
            ),
          ],
        ),
      ),
    );
  }
}
