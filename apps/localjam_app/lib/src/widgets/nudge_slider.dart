/// The §7 manual latency nudge: ±500 ms in 10 ms steps, persisted per output
/// route by the engine. Positive values play audio earlier (compensating
/// extra output latency, e.g. Bluetooth headphones). Works against either
/// [JamHostEngine] or [JamGuestEngine] through the shared [JamEngine] surface.
///
/// The one number in the app a person can actually act on, so it is the one
/// number that gets a control instead of a readout.
library;

import 'package:flutter/material.dart';
import 'package:localjam_client/localjam_client.dart';

import '../design/tokens.dart';
import '../design/typography.dart';

/// Every user-facing string this control can show.
abstract final class JamNudgeStrings {
  static const String label = 'Nudge sync';
  static const String help =
      'Positive plays earlier, for high-latency outputs like Bluetooth.';
  static String value(int ms) =>
      ms == 0 ? '0 ms' : '${ms > 0 ? '+' : ''}$ms ms';
}

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
    final colors = context.jamColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              JamNudgeStrings.label,
              style: context.jamHeadline.copyWith(color: colors.label),
            ),
            const Spacer(),
            Text(
              JamNudgeStrings.value(_ms),
              style: context.jamNumeric.copyWith(color: colors.tint),
            ),
          ],
        ),
        Semantics(
          slider: true,
          label: JamNudgeStrings.label,
          value: JamNudgeStrings.value(_ms),
          child: Slider(
            value: _ms.toDouble(),
            min: -_maxMs.toDouble(),
            max: _maxMs.toDouble(),
            divisions: (2 * _maxMs) ~/ _stepMs,
            label: JamNudgeStrings.value(_ms),
            onChanged: (v) {
              final ms = (v / _stepMs).round() * _stepMs;
              if (ms == _ms) return;
              setState(() => _ms = ms);
              widget.engine.setNudgeUs(ms * 1000, persist: false);
            },
            onChangeEnd: (_) => widget.engine.setNudgeUs(_ms * 1000),
          ),
        ),
        Text(
          JamNudgeStrings.help,
          style: context.jamFootnote.copyWith(color: colors.tertiaryLabel),
        ),
      ],
    );
  }
}
