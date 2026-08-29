/// The ambient sync state — one glance, not a readout.
///
/// The engine's accuracy (±5 ms) should be *felt*, not read. The pre-overhaul
/// UI put clock offset, drift in milliseconds, slew counts and resync counts
/// on both screens; none of that is actionable to someone in a van. This
/// reduces it to a single line that stays quiet when things are fine and only
/// takes colour when they are not. The numbers still exist — long-press.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:localjam_client/localjam_client.dart';

import '../design/tokens.dart';
import '../design/typography.dart';

/// Drift thresholds mirroring the engine's own policy (§5.4).
const int _slewThresholdUs = 15000;
const int _resyncThresholdUs = 50000;

/// What the room should be told about sync right now.
enum JamSyncState {
  /// Nothing is playing — there is nothing to be in sync with.
  idle,

  /// A guest whose session clock has not converged yet.
  syncing,

  /// The transport dropped and is retrying.
  reconnecting,

  /// Within the engine's do-nothing band.
  inSync,

  /// Being corrected with inaudible rate slews.
  catchingUp,

  /// Beyond the slew band — an audible correction is coming.
  offSync,
}

/// Derives the ambient state from the engine and its connection.
JamSyncState jamSyncState({
  required JamEngine engine,
  required JamConnectionState connection,
  required bool clockSynced,
}) {
  if (connection != JamConnectionState.connected) {
    return JamSyncState.reconnecting;
  }
  if (!clockSynced) return JamSyncState.syncing;
  if (engine.snapshot.status != PlaybackStatus.playing) {
    return JamSyncState.idle;
  }
  final sample = engine.lastDriftSample;
  if (sample == null) return JamSyncState.inSync;
  final error = sample.errorUs.abs();
  if (error > _resyncThresholdUs) return JamSyncState.offSync;
  if (error >= _slewThresholdUs) return JamSyncState.catchingUp;
  return JamSyncState.inSync;
}

/// A dot and a word. Long-press for the numbers.
class SyncIndicator extends StatefulWidget {
  const SyncIndicator({
    super.key,
    required this.engine,
    required this.connection,
    required this.clockSynced,
    this.onShowDetails,
  });

  final JamEngine engine;
  final JamConnectionState connection;

  /// False only for a guest whose §4 clock burst has not landed.
  final bool clockSynced;

  /// Opens the full drift telemetry. Long-press, so it never invites a tap.
  final VoidCallback? onShowDetails;

  @override
  State<SyncIndicator> createState() => _SyncIndicatorState();
}

class _SyncIndicatorState extends State<SyncIndicator> {
  StreamSubscription<DriftSample>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = widget.engine.driftSamples.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final state = jamSyncState(
      engine: widget.engine,
      connection: widget.connection,
      clockSynced: widget.clockSynced,
    );
    if (state == JamSyncState.idle) return const SizedBox.shrink();

    final (label, color) = switch (state) {
      JamSyncState.inSync => ('In sync', colors.textSecondary),
      JamSyncState.syncing => ('Syncing…', colors.textSecondary),
      JamSyncState.catchingUp => ('Catching up', colors.warning),
      JamSyncState.reconnecting => ('Reconnecting…', colors.warning),
      JamSyncState.offSync => ('Out of sync', colors.danger),
      JamSyncState.idle => ('', colors.textSecondary),
    };

    return GestureDetector(
      onLongPress: widget.onShowDetails,
      behavior: HitTestBehavior.opaque,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: JamSpace.sm),
          Text(label, style: context.jamFootnote.copyWith(color: color)),
        ],
      ),
    );
  }
}
