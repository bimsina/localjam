import 'dart:async';

import 'package:flutter/material.dart';
import 'package:localjam_net/localjam_net.dart';

import '../sync/audio_sync_controller.dart';
import '../util/format.dart';

/// The small sync-telemetry strip shown on both host and join screens:
/// clock offset (guest only), current drift, last corrective action, and
/// slew / hard-resync counts — fed by [AudioSyncController.driftSamples].
class SyncTelemetryStrip extends StatefulWidget {
  const SyncTelemetryStrip({
    super.key,
    required this.controller,
    this.clockOffsetUs,
  });

  final AudioSyncController controller;

  /// Guest only: returns the current guest→host clock offset (µs), or null
  /// while unsynchronized. Omitted on the host (its clock IS the session
  /// clock).
  final int? Function()? clockOffsetUs;

  @override
  State<SyncTelemetryStrip> createState() => _SyncTelemetryStripState();
}

class _SyncTelemetryStripState extends State<SyncTelemetryStrip> {
  StreamSubscription<DriftSample>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = widget.controller.driftSamples.listen((_) {
      if (mounted) setState(() {});
    });
    widget.controller.lastError.addListener(_onError);
  }

  void _onError() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _sub?.cancel();
    widget.controller.lastError.removeListener(_onError);
    super.dispose();
  }

  String _describeAction(DriftAction? action) => switch (action) {
        null => '—',
        DriftNone() => 'in sync',
        DriftSlew(:final rateMultiplier) =>
          'slew ×${rateMultiplier.toStringAsFixed(3)}',
        DriftHardResync() => 'hard resync',
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = widget.controller;
    final sample = controller.lastSample;
    final offsetUs = widget.clockOffsetUs?.call();
    final error = controller.lastError.value;

    Widget cell(String label, String value, {Color? color}) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label,
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 2),
            Text(
              value,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
                color: color,
              ),
            ),
          ],
        );

    final driftColor = sample == null
        ? null
        : sample.errorUs.abs() > 50000
            ? theme.colorScheme.error
            : sample.errorUs.abs() >= 15000
                ? theme.colorScheme.tertiary
                : theme.colorScheme.primary;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.multitrack_audio,
                    size: 16, color: theme.colorScheme.primary),
                const SizedBox(width: 6),
                Text('SYNC', style: theme.textTheme.labelSmall?.copyWith(
                      letterSpacing: 1.2,
                      color: theme.colorScheme.onSurfaceVariant,
                    )),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 24,
              runSpacing: 8,
              children: [
                if (widget.clockOffsetUs != null)
                  cell(
                    'Clock offset',
                    offsetUs == null ? 'syncing…' : formatSignedMs(offsetUs),
                  ),
                cell(
                  'Drift',
                  sample == null ? '—' : formatSignedMs(sample.errorUs),
                  color: driftColor,
                ),
                cell('Last action', _describeAction(sample?.action)),
                cell('Slews', '${controller.slewCount}'),
                cell('Resyncs', '${controller.resyncCount}'),
              ],
            ),
            if (error != null) ...[
              const SizedBox(height: 8),
              Text(
                'Player: $error',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
