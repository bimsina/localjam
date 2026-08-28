import 'package:flutter/material.dart';
import 'package:localjam_client/localjam_client.dart';

/// The §7 manual latency nudge: ±500 ms in 10 ms steps, persisted per output
/// route by the engine. Positive values play audio earlier (compensating
/// extra output latency, e.g. Bluetooth headphones). Works against either
/// [JamHostEngine] or [JamGuestEngine] through the shared [JamEngine] surface.
class NudgeSlider extends StatefulWidget {
  const NudgeSlider({super.key, required this.engine});

  final JamEngine engine;

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
    _ms = _clampMs(widget.engine.nudgeUs.value);
    // The engine restores the persisted nudge asynchronously at startup;
    // follow whatever value it lands on.
    widget.engine.nudgeUs.addListener(_onEngineNudge);
  }

  @override
  void dispose() {
    widget.engine.nudgeUs.removeListener(_onEngineNudge);
    super.dispose();
  }

  static int _clampMs(int us) => (us ~/ 1000).clamp(-_maxMs, _maxMs);

  void _onEngineNudge() {
    final ms = _clampMs(widget.engine.nudgeUs.value);
    if (!mounted || ms == _ms) return;
    setState(() => _ms = ms);
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
            widget.engine.setNudgeUs(ms * 1000, persist: false);
          },
          onChangeEnd: (_) => widget.engine.setNudgeUs(_ms * 1000),
        ),
        Text(
          'Positive = play earlier (for high-latency outputs like Bluetooth).',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
