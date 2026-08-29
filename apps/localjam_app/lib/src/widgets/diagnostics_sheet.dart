/// The sync numbers, demoted.
///
/// Drift, clock offset, slew and hard-resync counts used to sit on both main
/// screens. They are debug output: nobody in a van acts on "+3.2 ms". They
/// live here now, behind a long-press on the ambient sync indicator, together
/// with the one control that *is* actionable — the manual nudge for Bluetooth
/// headphone latency, which the engine cannot see past the OS.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:localjam_client/localjam_client.dart';

import '../design/tokens.dart';
import '../design/typography.dart';
import '../util/format.dart';
import 'nudge_slider.dart';

/// Opens the diagnostics sheet.
Future<void> showDiagnosticsSheet(
  BuildContext context,
  JamEngine engine, {
  int? Function()? clockOffsetUs,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) =>
        DiagnosticsSheet(engine: engine, clockOffsetUs: clockOffsetUs),
  );
}

class DiagnosticsSheet extends StatefulWidget {
  const DiagnosticsSheet({super.key, required this.engine, this.clockOffsetUs});

  final JamEngine engine;

  /// Guest only: the current guest→host clock offset. Omitted on a host,
  /// whose clock *is* the session clock.
  final int? Function()? clockOffsetUs;

  @override
  State<DiagnosticsSheet> createState() => _DiagnosticsSheetState();
}

class _DiagnosticsSheetState extends State<DiagnosticsSheet> {
  StreamSubscription<DriftSample>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = widget.engine.driftSamples.listen((_) {
      if (mounted) setState(() {});
    });
    widget.engine.lastPlayerError.addListener(_onError);
  }

  void _onError() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    widget.engine.lastPlayerError.removeListener(_onError);
    super.dispose();
  }

  String _describe(DriftAction? action) => switch (action) {
    null => '—',
    DriftNone() => 'none',
    DriftSlew(:final rateMultiplier) =>
      'slew ×${rateMultiplier.toStringAsFixed(3)}',
    DriftHardResync() => 'hard resync',
  };

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final engine = widget.engine;
    final sample = engine.lastDriftSample;
    final offsetUs = widget.clockOffsetUs?.call();
    final error = engine.lastPlayerError.value;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          JamSpace.page,
          JamSpace.sm,
          JamSpace.page,
          JamSpace.xl,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Sync', style: context.jamTitle),
            const SizedBox(height: JamSpace.lg),
            Wrap(
              spacing: JamSpace.section,
              runSpacing: JamSpace.md,
              children: [
                if (widget.clockOffsetUs != null)
                  _Cell(
                    label: 'Clock offset',
                    value: offsetUs == null
                        ? 'syncing…'
                        : formatSignedMs(offsetUs),
                  ),
                _Cell(
                  label: 'Drift',
                  value: sample == null ? '—' : formatSignedMs(sample.errorUs),
                ),
                _Cell(
                  label: 'Last correction',
                  value: _describe(sample?.action),
                ),
                _Cell(label: 'Slews', value: '${engine.sync.slewCount}'),
                _Cell(label: 'Resyncs', value: '${engine.sync.resyncCount}'),
              ],
            ),
            if (error != null) ...[
              const SizedBox(height: JamSpace.lg),
              Text(
                'Player: $error',
                style: context.jamFootnote.copyWith(color: colors.danger),
              ),
            ],
            const SizedBox(height: JamSpace.section),
            Divider(height: 0.5, color: colors.separator),
            const SizedBox(height: JamSpace.lg),
            Text('Headphone delay', style: context.jamTitle),
            const SizedBox(height: JamSpace.xs),
            Text(
              'Bluetooth adds delay the engine cannot measure. Nudge until '
              'you line up with the room.',
              style: context.jamByline,
            ),
            NudgeSlider(engine: engine),
          ],
        ),
      ),
    );
  }
}

class _Cell extends StatelessWidget {
  const _Cell({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: context.jamCaption),
        const SizedBox(height: JamSpace.xxs),
        Text(value, style: context.jamNumeric),
      ],
    );
  }
}
