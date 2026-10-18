/// Sound Offset: the §7 manual latency nudge, ±500 ms in 10 ms steps,
/// persisted per output route by the engine. Positive values play audio
/// earlier (compensating extra output latency, e.g. Bluetooth headphones).
/// Works against either engine through the shared [JamEngine] surface.
///
/// The one number in the app a person can act on, so it gets a control
/// rather than a readout: a two-way slider in the Balance pattern — a tick
/// at zero, the ends labelled Later and Earlier — with a step button at
/// each end (fine adjustment without a steady thumb), the value in tabular
/// figures, and Reset under it while there is something to reset. The
/// sheet's header holds only Done (§10.2).
library;

import 'package:flutter/cupertino.dart';
import 'package:localjam_client/localjam_client.dart';

import '../design/tokens.dart';
import '../design/typography.dart';
import 'buttons.dart';
import 'sheet.dart';

/// Every user-facing string this control can show.
abstract final class JamNudgeStrings {
  static const String title = 'Sound Offset';

  /// Kept for older call sites; the control's name is [title].
  static const String label = title;

  static const String reset = 'Reset';
  static const String done = 'Done';
  static const String earlier = 'Earlier';
  static const String later = 'Later';

  /// Under the big number on the Sound Offset sheet.
  static const String playsEarlier = 'Your audio plays earlier';
  static const String playsLater = 'Your audio plays later';
  static const String noOffset = 'No offset';

  /// The one footnote: when to reach for this.
  static const String footnote =
      'If your headphones sound behind or ahead of everyone else, move the '
      'slider until you line up. Bluetooth adds a delay LocalJam can’t '
      'measure. Saved separately for each speaker or pair of headphones.';

  static String value(int ms) =>
      ms == 0 ? '0 ms' : '${ms > 0 ? '+' : '−'}${ms.abs()} ms';
}

/// How [NudgeSlider] presents its value.
enum NudgeSliderStyle {
  /// A row: "Sound Offset" and the value, the slider under it — for a
  /// grouped section (Diagnostics).
  row,

  /// The value large and centred above the slider — the Sound Offset sheet.
  hero,
}

const int _maxMs = 500;
const int _stepMs = 10;

/// The zero mark behind the track: 1.5 × 14, centred.
const double _zeroTickWidth = 1.5;
const double _zeroTickHeight = 14;

/// The nudge control. Follows the engine's per-route value; writes it live
/// while dragging and persists it when the drag ends.
class NudgeSlider extends StatefulWidget {
  const NudgeSlider({
    super.key,
    required this.engine,
    this.style = NudgeSliderStyle.row,
  });

  final JamEngine engine;
  final NudgeSliderStyle style;

  @override
  State<NudgeSlider> createState() => _NudgeSliderState();
}

class _NudgeSliderState extends State<NudgeSlider> {
  int _ms = 0;

  @override
  void initState() {
    super.initState();
    _ms = _clampMs(widget.engine.nudgeUs.value);
    // The engine restores the persisted nudge asynchronously at startup and
    // on every output-route change; follow whatever value it lands on.
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

  void _drag(double v) {
    final ms = (v / _stepMs).round() * _stepMs;
    if (ms == _ms) return;
    setState(() => _ms = ms);
    widget.engine.setNudgeUs(ms * 1000, persist: false);
  }

  void _step(int delta) {
    final ms = (_ms + delta).clamp(-_maxMs, _maxMs);
    if (ms == _ms) return;
    JamHaptics.selection();
    setState(() => _ms = ms);
    widget.engine.setNudgeUs(ms * 1000);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final value = JamNudgeStrings.value(_ms);

    final track = Semantics(
      slider: true,
      label: JamNudgeStrings.title,
      value: value,
      increasedValue: JamNudgeStrings.value(
        (_ms + _stepMs).clamp(-_maxMs, _maxMs),
      ),
      decreasedValue: JamNudgeStrings.value(
        (_ms - _stepMs).clamp(-_maxMs, _maxMs),
      ),
      onIncrease: () => _step(_stepMs),
      onDecrease: () => _step(-_stepMs),
      excludeSemantics: true,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Zero, marked: the track is symmetric, so its centre is 0 ms.
          // The thumb covers the mark while there is no offset.
          Container(
            width: _zeroTickWidth,
            height: _zeroTickHeight,
            decoration: BoxDecoration(
              color: colors.tertiaryLabel,
              borderRadius: BorderRadius.circular(_zeroTickWidth),
            ),
          ),
          CupertinoSlider(
            value: _ms.toDouble(),
            min: -_maxMs.toDouble(),
            max: _maxMs.toDouble(),
            divisions: (2 * _maxMs) ~/ _stepMs,
            // Zero sits in the middle: a fill from the left end would
            // read as an amount, so the track stays neutral.
            activeColor: colors.fill,
            onChanged: _drag,
            onChangeEnd: (_) => widget.engine.setNudgeUs(_ms * 1000),
          ),
        ],
      ),
    );

    // The ends say which way is which, as Balance's L and R do.
    final ends = ExcludeSemantics(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: JamSpace.xs),
        child: Row(
          children: [
            Text(
              JamNudgeStrings.later,
              style: context.jamFootnote.copyWith(color: colors.secondaryLabel),
            ),
            const Spacer(),
            Text(
              JamNudgeStrings.earlier,
              style: context.jamFootnote.copyWith(color: colors.secondaryLabel),
            ),
          ],
        ),
      ),
    );

    final slider = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        JamIconButton(
          icon: CupertinoIcons.minus,
          semanticLabel: JamNudgeStrings.later,
          size: 17,
          color: colors.secondaryLabel,
          onPressed: _ms > -_maxMs ? () => _step(-_stepMs) : null,
        ),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(height: JamMetrics.hitTarget, child: track),
              ends,
            ],
          ),
        ),
        JamIconButton(
          icon: CupertinoIcons.plus,
          semanticLabel: JamNudgeStrings.earlier,
          size: 17,
          color: colors.secondaryLabel,
          onPressed: _ms < _maxMs ? () => _step(_stepMs) : null,
        ),
      ],
    );

    switch (widget.style) {
      case NudgeSliderStyle.row:
        return Padding(
          padding: const EdgeInsets.only(top: JamSpace.md, bottom: JamSpace.xs),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              ExcludeSemantics(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: JamSpace.lg),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          JamNudgeStrings.title,
                          style: context.jamBody,
                        ),
                      ),
                      Text(
                        value,
                        style: jamTabular(
                          context.jamBody,
                        ).copyWith(color: colors.secondaryLabel),
                      ),
                    ],
                  ),
                ),
              ),
              // The step buttons' 44 hit areas reach into the row inset, so
              // their glyphs line up with the text above.
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: JamSpace.xxs),
                child: slider,
              ),
            ],
          ),
        );
      case NudgeSliderStyle.hero:
        final caption = _ms == 0
            ? JamNudgeStrings.noOffset
            : _ms > 0
            ? JamNudgeStrings.playsEarlier
            : JamNudgeStrings.playsLater;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ExcludeSemantics(
              child: Text(
                value,
                textAlign: TextAlign.center,
                style: jamTabular(context.jamLargeTitle),
              ),
            ),
            const SizedBox(height: JamSpace.xxs),
            Text(
              caption,
              textAlign: TextAlign.center,
              style: context.jamSubheadline.copyWith(
                color: colors.secondaryLabel,
              ),
            ),
            const SizedBox(height: JamSpace.lg),
            slider,
            const SizedBox(height: JamSpace.sm),
            _ResetButton(ms: _ms, onReset: () => _step(-_ms)),
          ],
        );
    }
  }
}

/// Opens the Sound Offset sheet: the value, the slider, Reset under it, one
/// footnote on when to use it, and Done.
Future<void> showSoundOffsetSheet(BuildContext context, JamEngine engine) =>
    showJamSheet<void>(
      context,
      title: JamNudgeStrings.title,
      // The offset applies as it is dragged; Done just closes.
      actions: const JamSheetActions.done(),
      grouped: true,
      scrollable: false,
      builder: (_) =>
          SingleChildScrollView(child: SoundOffsetPanel(engine: engine)),
    );

/// The Sound Offset sheet's body.
class SoundOffsetPanel extends StatelessWidget {
  const SoundOffsetPanel({super.key, required this.engine});

  final JamEngine engine;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final side = JamSpace.pageFor(MediaQuery.sizeOf(context).width);
    return Padding(
      padding: EdgeInsets.fromLTRB(side, JamSpace.xl, side, JamSpace.xxl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              color: colors.elevatedGroupedSurface,
              borderRadius: BorderRadius.circular(JamRadius.section),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                JamSpace.xs,
                JamSpace.xxl,
                JamSpace.xs,
                JamSpace.md,
              ),
              child: NudgeSlider(engine: engine, style: NudgeSliderStyle.hero),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              JamSpace.lg,
              JamSpace.sectionHeader,
              JamSpace.lg,
              0,
            ),
            child: Text(
              JamNudgeStrings.footnote,
              style: context.jamFootnote.copyWith(color: colors.secondaryLabel),
            ),
          ),
        ],
      ),
    );
  }
}

/// Reset, under the slider: there only while there is an offset to reset.
/// Its space stays, so the sheet doesn't jump when it comes and goes.
class _ResetButton extends StatelessWidget {
  const _ResetButton({required this.ms, required this.onReset});

  final int ms;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final shown = ms != 0;
    return ExcludeSemantics(
      excluding: !shown,
      child: IgnorePointer(
        ignoring: !shown,
        child: AnimatedOpacity(
          opacity: shown ? 1 : 0,
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : JamDuration.fast,
          child: Center(
            child: JamButton.plain(
              label: JamNudgeStrings.reset,
              size: JamButtonSize.small,
              onPressed: onReset,
            ),
          ),
        ),
      ),
    );
  }
}
