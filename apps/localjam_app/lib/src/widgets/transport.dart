/// The transport and the scrubber, as plain widgets.
///
/// Extracted from `now_playing.dart` and restyled: no [JamEngine] here at
/// all, only values and callbacks, so a host, a guest and a widget test all
/// drive the same controls. Position arrives as microseconds — the screen
/// still owns the `JamPositionTicker` — and [JamScrubber] keeps its own drag
/// value so the ticker cannot fight the thumb mid-gesture.
///
/// The controls are *gated, never hidden*: a guest without playback control
/// sees the same bar at 38% opacity with a line saying whose call it is, so
/// the room's rules are legible rather than mysterious.
library;

import 'package:flutter/material.dart';

import '../design/tokens.dart';
import '../design/typography.dart';

/// What the transport should be showing. Map `PlaybackStatus` onto this at
/// the call site — this file knows nothing about the engine.
enum JamPlaybackState {
  /// Stopped or paused: the button offers "Play".
  paused,

  /// Running: the button offers "Pause".
  playing,

  /// Preparing (loading media, fetching from the host). The glyph becomes an
  /// indeterminate ring and the button swallows taps.
  loading,
}

/// Everything the transport says out loud. Most of it is spoken rather than
/// drawn — a glyph needs a name before a screen reader can offer it.
abstract final class JamTransportStrings {
  static const String previous = 'Previous';
  static const String next = 'Next';
  static const String play = 'Play';
  static const String pause = 'Pause';
  static const String loading = 'Loading';
  static const String position = 'Playback position';
}

/// The line shown beneath the bar when the room does not grant you playback
/// control.
const String jamHostControlsPlayback = 'The host controls playback';

/// The painted 4 dp track inside a [JamScrubber]. Exposed so a test can
/// assert that the paint and the touch area share a centre line — an iOS
/// build once shipped a slider whose taps landed 24 pt above the track.
const Key jamScrubberTrackKey = Key('jam.scrubber.track');

/// The transparent 44 dp touch area over a [JamScrubber]'s track.
const Key jamScrubberHitKey = Key('jam.scrubber.hit');

/// Previous · play/pause · next.
class JamTransport extends StatelessWidget {
  const JamTransport({
    super.key,
    required this.state,
    required this.onPlayPause,
    this.onPrevious,
    this.onNext,
    this.enabled = true,
    this.gatedMessage = jamHostControlsPlayback,
    this.playLabel,
  });

  final JamPlaybackState state;

  /// What the play button is called when it does something other than play
  /// the room — "Resume audio" while this phone's own sound is suspended.
  /// Null: "Play".
  final String? playLabel;

  /// Toggles playback. Fires [JamHaptics.transport] before the callback.
  final VoidCallback onPlayPause;

  /// Null renders the glyph disabled rather than removing it.
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  /// The capability gate. False dims the whole bar to 38%, makes it inert,
  /// and shows [gatedMessage] beneath.
  final bool enabled;

  /// The explanation shown under a gated bar.
  final String gatedMessage;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;

    final bar = Row(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        _SkipButton(
          icon: Icons.skip_previous_rounded,
          label: JamTransportStrings.previous,
          onPressed: enabled ? onPrevious : null,
        ),
        const SizedBox(width: JamSpace.section),
        _PlayButton(
          state: state,
          enabled: enabled,
          playLabel: playLabel,
          onPressed: () {
            JamHaptics.transport();
            onPlayPause();
          },
        ),
        const SizedBox(width: JamSpace.section),
        _SkipButton(
          icon: Icons.skip_next_rounded,
          label: JamTransportStrings.next,
          onPressed: enabled ? onNext : null,
        ),
      ],
    );

    if (enabled) return bar;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Dimmed and inert, but still on screen: the controls you will get
        // when the host promotes you.
        Opacity(
          opacity: 0.38,
          child: IgnorePointer(child: ExcludeSemantics(child: bar)),
        ),
        const SizedBox(height: JamSpace.sm),
        Text(
          gatedMessage,
          textAlign: TextAlign.center,
          style: context.jamCaption2.copyWith(color: colors.secondaryLabel),
        ),
      ],
    );
  }
}

/// The 72 dp gradient play button.
class _PlayButton extends StatefulWidget {
  const _PlayButton({
    required this.state,
    required this.enabled,
    required this.onPressed,
    this.playLabel,
  });

  final JamPlaybackState state;
  final bool enabled;
  final VoidCallback onPressed;
  final String? playLabel;

  @override
  State<_PlayButton> createState() => _PlayButtonState();
}

class _PlayButtonState extends State<_PlayButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final light = Theme.of(context).brightness == Brightness.light;
    final loading = widget.state == JamPlaybackState.loading;
    final playing = widget.state == JamPlaybackState.playing;
    final reduced = _reducedMotion(context);
    final pressed = _pressed && widget.enabled && !loading;

    final glyph = loading
        ? SizedBox(
            key: const ValueKey('loading'),
            width: 34,
            height: 34,
            child: CircularProgressIndicator(
              strokeWidth: 3,
              color: colors.onTint,
            ),
          )
        : Icon(
            playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
            key: ValueKey(playing),
            size: 34,
            color: colors.onTint,
          );

    final circle = Container(
      width: 72,
      height: 72,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: light && !pressed
            ? null
            : (pressed ? colors.tintPressed : colors.tint),
        gradient: light && !pressed
            ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [colors.tint, colors.tintPressed],
              )
            : null,
      ),
      child: AnimatedSwitcher(
        duration: reduced ? Duration.zero : JamDuration.fast,
        switchInCurve: JamCurve.standard,
        switchOutCurve: JamCurve.standard,
        // Not a swap: the old glyph shrinks out while the new one grows in.
        transitionBuilder: (child, animation) => FadeTransition(
          opacity: animation,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.7, end: 1).animate(animation),
            child: child,
          ),
        ),
        child: glyph,
      ),
    );

    return Semantics(
      button: true,
      enabled: widget.enabled && !loading,
      label: loading
          ? JamTransportStrings.loading
          : (playing
                ? JamTransportStrings.pause
                : (widget.playLabel ?? JamTransportStrings.play)),
      onTap: widget.enabled && !loading ? widget.onPressed : null,
      excludeSemantics: true,
      child: AnimatedScale(
        scale: pressed && !reduced ? 0.94 : 1,
        duration: reduced ? Duration.zero : JamDuration.instant,
        curve: JamCurve.standard,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          // A loading button eats the tap rather than queueing a command
          // against media that has not landed yet.
          onTap: widget.enabled && !loading ? widget.onPressed : null,
          onTapDown: (_) => setState(() => _pressed = true),
          onTapCancel: () => setState(() => _pressed = false),
          onTapUp: (_) => setState(() => _pressed = false),
          child: circle,
        ),
      ),
    );
  }
}

/// A 48 dp previous/next target with a 32 dp glyph.
class _SkipButton extends StatelessWidget {
  const _SkipButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final enabled = onPressed != null;
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      onTap: enabled ? onPressed : null,
      excludeSemantics: true,
      child: Material(
        type: MaterialType.transparency,
        child: InkResponse(
          radius: 32,
          onTap: enabled
              ? () {
                  JamHaptics.skip();
                  onPressed!();
                }
              : null,
          child: SizedBox(
            width: 48,
            height: 48,
            child: Icon(
              icon,
              size: 32,
              color: enabled ? colors.label : colors.tertiaryLabel,
            ),
          ),
        ),
      ),
    );
  }
}

/// The timeline: a 4 dp track, a thumb that grows while you hold it, and the
/// elapsed / remaining pair beneath in tabular figures.
///
/// The painted track and the touch area share a centre line — the hit box is
/// 44 dp tall with the 4 dp track at its middle — so a tap lands where the
/// finger is, not where a `Slider`'s internal padding would have put it.
class JamScrubber extends StatefulWidget {
  const JamScrubber({
    super.key,
    required this.positionUs,
    required this.durationUs,
    this.onSeek,
    this.enabled = true,
  });

  /// Where playback is now, in microseconds. Ignored while a drag is in
  /// flight — the thumb follows the finger.
  final int positionUs;

  /// Total media length in microseconds; null or 0 renders an inert track.
  final int? durationUs;

  /// Called once, on release, with the seek target in microseconds.
  final ValueChanged<int>? onSeek;

  /// False renders the same timeline without a thumb and without gestures.
  final bool enabled;

  @override
  State<JamScrubber> createState() => _JamScrubberState();
}

class _JamScrubberState extends State<JamScrubber> {
  /// The vertical slack around the 4 dp track that makes the target 44 dp.
  static const double _hitHeight = 44;
  static const double _trackHeight = 4;

  /// Horizontal inset of the *thumb's travel* inside the track.
  ///
  /// The track itself is painted edge to edge and the thumb runs between
  /// [_edge] and `width - _edge`, so at 0:00 the thumb sits inside the
  /// track's left cap instead of hanging off it — the review caught the
  /// fattest thumb overhanging by its own radius at either extreme.
  static const double _edge = 11;

  static const int _nudgeUs = 5000000;

  double? _dragFraction;

  bool get _interactive =>
      widget.enabled && widget.onSeek != null && (widget.durationUs ?? 0) > 0;

  int get _duration => widget.durationUs ?? 0;

  double get _fraction {
    if (_dragFraction != null) return _dragFraction!;
    if (_duration <= 0) return 0;
    return (widget.positionUs / _duration).clamp(0.0, 1.0);
  }

  int get _shownUs {
    final raw = _dragFraction != null
        ? (_dragFraction! * _duration).round()
        : widget.positionUs;
    if (raw < 0) return 0;
    if (_duration > 0 && raw > _duration) return _duration;
    return raw;
  }

  double _fractionFor(double dx, double width) {
    final span = width - _edge * 2;
    if (span <= 0) return 0;
    return ((dx - _edge) / span).clamp(0.0, 1.0);
  }

  void _begin(double dx, double width) {
    JamHaptics.scrubStart();
    setState(() => _dragFraction = _fractionFor(dx, width));
  }

  void _update(double dx, double width) {
    setState(() => _dragFraction = _fractionFor(dx, width));
  }

  void _end() {
    final fraction = _dragFraction;
    setState(() => _dragFraction = null);
    if (fraction == null) return;
    JamHaptics.scrubEnd();
    widget.onSeek?.call((fraction * _duration).round());
  }

  /// How VoiceOver reads the position.
  String _spoken(int us) => _duration <= 0
      ? jamClock(us)
      : '${jamClock(us)} of ${jamClock(_duration)}';

  void _seekBy(int deltaUs) {
    if (!_interactive) return;
    final target = (widget.positionUs + deltaUs).clamp(0, _duration);
    JamHaptics.scrubEnd();
    widget.onSeek?.call(target);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final light = Theme.of(context).brightness == Brightness.light;
    final reduced = _reducedMotion(context);
    final dragging = _dragFraction != null;
    final remaining = _duration <= 0 ? null : _duration - _shownUs;

    final numeric = context.jamNumeric.copyWith(color: colors.secondaryLabel);

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return Semantics(
          slider: true,
          enabled: _interactive,
          label: JamTransportStrings.position,
          value: _spoken(_shownUs),
          increasedValue: _spoken(
            (_shownUs + _nudgeUs).clamp(0, _duration <= 0 ? 0 : _duration),
          ),
          decreasedValue: _spoken((_shownUs - _nudgeUs).clamp(0, _shownUs)),
          onIncrease: _interactive ? () => _seekBy(_nudgeUs) : null,
          onDecrease: _interactive ? () => _seekBy(-_nudgeUs) : null,
          excludeSemantics: true,
          child: Stack(
            children: [
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // The top half of the 44 dp target, so the painted track
                  // sits exactly on the touch area's centre line.
                  const SizedBox(height: (_hitHeight - _trackHeight) / 2),
                  TweenAnimationBuilder<double>(
                    tween: Tween<double>(
                      begin: 7,
                      end: dragging && _interactive
                          ? 11
                          : (_interactive ? 7 : 0),
                    ),
                    duration: reduced ? Duration.zero : JamDuration.fast,
                    curve: JamCurve.standard,
                    builder: (context, thumbRadius, _) => SizedBox(
                      key: jamScrubberTrackKey,
                      width: double.infinity,
                      height: _trackHeight,
                      child: CustomPaint(
                        painter: _ScrubberPainter(
                          fraction: _fraction,
                          thumbRadius: thumbRadius,
                          showHalo: dragging,
                          edge: _edge,
                          active: colors.tint,
                          inactive: light
                              ? colors.fillSecondary
                              : colors.separator,
                          halo: colors.tint.withValues(alpha: 0.14),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: JamSpace.sm - 2),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(jamClock(_shownUs), style: numeric),
                      Text(
                        remaining == null ? '--:--' : '-${jamClock(remaining)}',
                        style: numeric,
                      ),
                    ],
                  ),
                ],
              ),
              // Laid over the track and centred on it. Positioned last so it
              // takes the hit before anything beneath.
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                height: _hitHeight,
                child: GestureDetector(
                  key: jamScrubberHitKey,
                  behavior: HitTestBehavior.opaque,
                  onTapDown: _interactive
                      ? (d) => _begin(d.localPosition.dx, width)
                      : null,
                  onTapUp: _interactive ? (_) => _end() : null,
                  onTapCancel: _interactive
                      ? () => setState(() => _dragFraction = null)
                      : null,
                  onHorizontalDragStart: _interactive
                      ? (d) => _begin(d.localPosition.dx, width)
                      : null,
                  onHorizontalDragUpdate: _interactive
                      ? (d) => _update(d.localPosition.dx, width)
                      : null,
                  onHorizontalDragEnd: _interactive ? (_) => _end() : null,
                  onHorizontalDragCancel: _interactive
                      ? () => setState(() => _dragFraction = null)
                      : null,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ScrubberPainter extends CustomPainter {
  const _ScrubberPainter({
    required this.fraction,
    required this.thumbRadius,
    required this.showHalo,
    required this.edge,
    required this.active,
    required this.inactive,
    required this.halo,
  });

  final double fraction;
  final double thumbRadius;
  final bool showHalo;
  final double edge;
  final Color active;
  final Color inactive;
  final Color halo;

  @override
  void paint(Canvas canvas, Size size) {
    // The track spans the full width; only the thumb's travel is inset, so
    // the thumb is always *inside* the rail it rides.
    final left = edge;
    final right = size.width - edge;
    if (right <= left) return;
    final y = size.height / 2;
    final radius = Radius.circular(size.height / 2);
    final x = left + (right - left) * fraction;

    canvas.drawRRect(
      RRect.fromLTRBR(0, 0, size.width, size.height, radius),
      Paint()..color = inactive,
    );
    canvas.drawRRect(
      RRect.fromLTRBR(0, 0, x.clamp(0, size.width), size.height, radius),
      Paint()..color = active,
    );
    if (showHalo) {
      canvas.drawCircle(Offset(x, y), 24, Paint()..color = halo);
    }
    if (thumbRadius > 0) {
      canvas.drawCircle(Offset(x, y), thumbRadius, Paint()..color = active);
    }
  }

  @override
  bool shouldRepaint(_ScrubberPainter old) =>
      old.fraction != fraction ||
      old.thumbRadius != thumbRadius ||
      old.showHalo != showHalo ||
      old.active != active ||
      old.inactive != inactive;
}

/// `mm:ss` (or `h:mm:ss`) from microseconds.
///
/// Deliberately local: `util/format.dart` reaches for the engine package to
/// name tracks, and these widgets stay engine-free.
String jamClock(int us) {
  final totalSeconds = (us < 0 ? 0 : us) ~/ 1000000;
  final seconds = totalSeconds % 60;
  final minutes = (totalSeconds ~/ 60) % 60;
  final hours = totalSeconds ~/ 3600;
  final mmss =
      '${minutes.toString().padLeft(2, '0')}:'
      '${seconds.toString().padLeft(2, '0')}';
  return hours > 0 ? '$hours:$mmss' : mmss;
}

bool _reducedMotion(BuildContext context) =>
    MediaQuery.maybeDisableAnimationsOf(context) ?? false;
