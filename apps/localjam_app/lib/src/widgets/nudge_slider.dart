import 'package:flutter/material.dart';

import '../sync/audio_sync_controller.dart';
import '../sync/latency_prefs.dart';

/// The §7 manual latency nudge: ±500 ms in 10 ms steps, persisted per output
/// route via [LatencyPrefs]. Positive values play audio earlier (compensating
/// extra output latency, e.g. Bluetooth headphones).
class NudgeSlider extends StatefulWidget {
  const NudgeSlider({super.key, required this.controller});

  final AudioSyncController controller;

  @override
  State<NudgeSlider> createState() => _NudgeSliderState();
}

class _NudgeSliderState extends State<NudgeSlider> {
  static const _maxMs = 500;
  static const _stepMs = 10;

  int _ms = 0;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    final us = await LatencyPrefs.load(widget.controller.player);
    if (!mounted) return;
    setState(() => _ms = (us ~/ 1000).clamp(-_maxMs, _maxMs));
    await widget.controller.setManualOffsetUs(_ms * 1000);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Nudge sync', style: theme.textTheme.labelLarge),
            const Spacer(),
            Text(
              _ms == 0 ? '0 ms' : '${_ms > 0 ? '+' : ''}$_ms ms',
              style: theme.textTheme.bodyMedium?.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
                color: theme.colorScheme.primary,
              ),
            ),
          ],
        ),
        Slider(
          value: _ms.toDouble(),
          min: -_maxMs.toDouble(),
          max: _maxMs.toDouble(),
          divisions: (2 * _maxMs) ~/ _stepMs,
          label: '$_ms ms',
          onChanged: (v) {
            final ms = (v / _stepMs).round() * _stepMs;
            if (ms == _ms) return;
            setState(() => _ms = ms);
            widget.controller.setManualOffsetUs(ms * 1000);
          },
          onChangeEnd: (_) =>
              LatencyPrefs.save(widget.controller.player, _ms * 1000),
        ),
        Text(
          'Positive = play earlier (for high-latency outputs like Bluetooth).',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }
}
