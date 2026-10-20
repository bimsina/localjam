/// The transport and the scrubber of the Now Playing screen (DESIGN_SPEC v3
/// §6.3), as plain widgets.
///
/// No [JamEngine] here at all, only values and callbacks, so a host, a guest
/// and a widget test all drive the same controls. Position arrives as
/// microseconds — the screen still owns the `JamPositionTicker` — and
/// [JamScrubber] keeps its own drag value so the ticker cannot fight the
/// finger mid-gesture.
///
/// Both live on the immersive backdrop (D4) and paint in the fixed
/// [JamNowPlayingColors]: white skip glyphs, no circles, no thumb, no tint —
/// and one signature control, the ivory play square (76 pt, continuous
/// corners, warm-ink glyph) that squeezes under a finger.
///
/// The controls are *gated, never hidden*: a guest without playback control
/// sees the same bar drawn quiet — the square as a hairline outline with no
/// fill, every glyph in the backdrop's tertiary white — with a line saying
/// whose call it is, so the room's rules are legible rather than
/// mysterious, and the heaviest object in the lower half is not a button
/// that does nothing (CR-25).
library;

import 'package:flutter/cupertino.dart';

import '../design/tokens.dart';
import '../design/typography.dart';
import 'pressable.dart';

/// What the transport should be showing. Map `PlaybackStatus` onto this at
/// the call site — this file knows nothing about the engine.
enum JamPlaybackState {
  /// Stopped or paused: the button offers "Play".
  paused,

  /// Running: the button offers "Pause".
  playing,

  /// Preparing (loading media, fetching from the host). The glyph becomes an
  /// activity indicator and the button swallows taps.
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

  /// The minus in front of the remaining time: a real minus sign, not a
  /// hyphen.
  static const String minus = '−';
}

/// The line shown beneath the bar when the room does not grant you playback
/// control.
const String jamHostControlsPlayback = 'The host controls playback.';

/// The painted track inside a [JamScrubber]. Exposed so a test can assert
/// that the paint and the touch area share a centre line — an iOS build once
/// shipped a slider whose taps landed 24 pt above the track.
const Key jamScrubberTrackKey = Key('jam.scrubber.track');

/// The transparent 44 pt touch area over a [JamScrubber]'s track.
const Key jamScrubberHitKey = Key('jam.scrubber.hit');

/// The skip glyphs are "previous / next song" (a bar and a triangle), never
/// the double chevrons of a seek: these buttons change the song. Their
/// touch boxes are generous, the way the Music app's are.
const double _kSkipHit = 64;

/// How far the play triangle sits right of the square's centre: its visual
/// mass is left of its box, so geometric centring reads as off-centre.
const double _kPlayOpticalShift = 1.5;

/// How far the ivory deepens toward its glyph's ink while held, under
/// reduced motion (where it does not squeeze).
const double _kPressedDeepen = 0.12;

/// Previous · play/pause · next, evenly spaced across the width it is given.
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
  /// the room — "Resume Audio" while this phone's own sound is suspended.
  /// Null: "Play".
  final String? playLabel;

  /// Toggles playback. Fires [JamHaptics.transport] before the callback.
  final VoidCallback onPlayPause;

  /// Null renders the glyph disabled rather than removing it.
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  /// The capability gate. False dims the whole bar, makes it inert, and
  /// shows [gatedMessage] beneath.
  final bool enabled;

  /// The explanation shown under a gated bar. Null when the screen already
  /// says why (an empty room's "Nothing Playing" and its Add Songs): one
  /// prompt per action, not three.
  final String? gatedMessage;

  @override
  Widget build(BuildContext context) {
    final playing = state == JamPlaybackState.playing;
    final loading = state == JamPlaybackState.loading;

    final bar = Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _TransportButton(
          icon: CupertinoIcons.backward_end_fill,
          hit: _kSkipHit,
          label: JamTransportStrings.previous,
          onPressed: enabled && onPrevious != null
              ? () {
                  JamHaptics.skip();
                  onPrevious!();
                }
              : null,
        ),
        _TransportButton(
          icon: playing ? CupertinoIcons.pause_fill : CupertinoIcons.play_fill,
          hit: JamMetrics.playSquare,
          loading: loading,
          primary: true,
          label: loading
              ? JamTransportStrings.loading
              : playing
              ? JamTransportStrings.pause
              : (playLabel ?? JamTransportStrings.play),
          // A loading button eats the tap rather than queueing a command
          // against media that has not landed yet.
          onPressed: enabled && !loading
              ? () {
                  JamHaptics.transport();
                  onPlayPause();
                }
              : null,
        ),
        _TransportButton(
          icon: CupertinoIcons.forward_end_fill,
          hit: _kSkipHit,
          label: JamTransportStrings.next,
          onPressed: enabled && onNext != null
              ? () {
                  JamHaptics.skip();
                  onNext!();
                }
              : null,
        ),
      ],
    );

    if (enabled) return bar;

    // Quiet and inert, but still on screen: the controls you will get when
    // the host promotes you.
    final inert = IgnorePointer(child: ExcludeSemantics(child: bar));
    final message = gatedMessage;
    if (message == null) return inert;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        inert,
        const SizedBox(height: JamSpace.md),
        Text(
          message,
          textAlign: TextAlign.center,
          maxLines: 2,
          style: context.jamFootnote.copyWith(
            color: JamNowPlayingColors.secondary,
          ),
        ),
      ],
    );
  }
}

/// One transport control. A skip is a bare white glyph that dims under a
/// finger; the primary is the play square, ivory with a warm-ink glyph,
/// that squeezes instead ([JamPressStyle.scale]) — half-transparent ivory
/// over a cover goes muddy. Under reduced motion it does not squeeze: the
/// ivory deepens while held, so the press still shows (RB-18). Disabled, a
/// skip glyph and the square's glyph go to the backdrop's tertiary white
/// and the square to an outline: quiet, never a dimmed slab.
///
/// The glyph swap (play ↔ pause) cross-fades with a small scale so a tap
/// reads as one control changing state.
class _TransportButton extends StatefulWidget {
  const _TransportButton({
    required this.icon,
    required this.hit,
    required this.label,
    required this.onPressed,
    this.loading = false,
    this.primary = false,
  });

  final IconData icon;
  final double hit;
  final String label;
  final VoidCallback? onPressed;
  final bool loading;
  final bool primary;

  @override
  State<_TransportButton> createState() => _TransportButtonState();
}

class _TransportButtonState extends State<_TransportButton> {
  /// Held down, for the reduced-motion press.
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final icon = widget.icon;
    final hit = widget.hit;
    final label = widget.label;
    final onPressed = widget.onPressed;
    final loading = widget.loading;
    final primary = widget.primary;
    final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final enabled = onPressed != null;
    // A loading button is busy, not forbidden: it keeps its full colours.
    final live = enabled || loading;
    final glyphColor = !live
        ? JamNowPlayingColors.tertiary
        : primary
        ? JamNowPlayingColors.playGlyph
        : JamNowPlayingColors.text;
    final Widget face = loading
        ? CupertinoActivityIndicator(
            key: const ValueKey<String>('loading'),
            radius: 14,
            color: glyphColor,
          )
        : Transform.translate(
            key: ValueKey<IconData>(icon),
            offset: Offset(
              primary && icon == CupertinoIcons.play_fill
                  ? _kPlayOpticalShift
                  : 0,
              0,
            ),
            // Skips at the play glyph's size, so neither side outweighs the
            // square between them.
            child: Icon(icon, size: JamIconSize.play, color: glyphColor),
          );

    final glyph = AnimatedSwitcher(
      duration: reduced ? Duration.zero : JamDuration.fast,
      switchInCurve: JamCurve.standard,
      switchOutCurve: JamCurve.standard,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.7, end: 1).animate(animation),
          child: child,
        ),
      ),
      child: face,
    );

    final Widget control = primary
        ? JamPressable(
            onTap: onPressed,
            style: reduced ? JamPressStyle.none : JamPressStyle.scale,
            onPressedChanged: (pressed) => setState(() => _pressed = pressed),
            child: AnimatedContainer(
              duration: reduced ? Duration.zero : JamDuration.fast,
              curve: JamCurve.standard,
              width: hit,
              height: hit,
              decoration: ShapeDecoration(
                color: !live
                    ? JamNowPlayingColors.clear
                    : reduced && _pressed && enabled
                    ? Color.lerp(
                        JamNowPlayingColors.playSurface,
                        JamNowPlayingColors.playGlyph,
                        _kPressedDeepen,
                      )
                    : JamNowPlayingColors.playSurface,
                shape: RoundedSuperellipseBorder(
                  // Not yours to press: its shape in a hairline, so the
                  // controls keep their places and the eye is not drawn to a
                  // slab that does nothing.
                  side: live
                      ? BorderSide.none
                      : const BorderSide(color: JamNowPlayingColors.separator),
                  borderRadius: const BorderRadius.all(
                    Radius.circular(JamRadius.playSquare),
                  ),
                ),
              ),
              child: Center(child: glyph),
            ),
          )
        : JamPressable(
            onTap: onPressed,
            pressedOpacity: 0.5,
            child: SizedBox(
              width: hit,
              height: hit,
              child: Center(child: glyph),
            ),
          );

    return Semantics(
      container: true,
      button: true,
      enabled: enabled,
      label: label,
      onTap: onPressed,
      excludeSemantics: true,
      child: control,
    );
  }
}

/// The timeline: a 6 pt capsule (white 25%, elapsed white 85%) with no thumb
/// that thickens to 10 pt while you hold it, and the elapsed / remaining pair
/// beneath in tabular figures.
///
/// The painted track and the touch area share a centre line — the hit box is
/// 44 pt tall with the track at its middle — so a touch lands where the
/// finger is. Like the Music app, the whole track is the target: touch
/// anywhere and drag, and the position follows the finger.
class JamScrubber extends StatefulWidget {
  const JamScrubber({
    super.key,
    required this.positionUs,
    required this.durationUs,
    this.onSeek,
    this.enabled = true,
  });

  /// Where playback is now, in microseconds. Ignored while a drag is in
  /// flight — the bar follows the finger.
  final int positionUs;

  /// Total media length in microseconds; null or 0 renders an inert track.
  final int? durationUs;

  /// Called once, on release, with the seek target in microseconds.
  final ValueChanged<int>? onSeek;

  /// False renders the same timeline without gestures (no
  /// `controlPlayback`).
  final bool enabled;

  @override
  State<JamScrubber> createState() => _JamScrubberState();
}

class _JamScrubberState extends State<JamScrubber> {
  /// The touch area around the track.
  static const double _hitHeight = 44;

  /// The track at rest and while held (§6.3).
  static const double _track = 6;
  static const double _trackActive = 10;

  /// Track centre to the top of the times.
  static const double _timesGap = 4;

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
    if (width <= 0) return 0;
    return (dx / width).clamp(0.0, 1.0);
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

  void _cancel() => setState(() => _dragFraction = null);

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
    final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final dragging = _dragFraction != null;
    final remaining = _duration <= 0 ? null : _duration - _shownUs;
    // Under a tablet's poster-sized cover, the times step up with the title.
    final large = MediaQuery.sizeOf(context).shortestSide >= 600;
    final times = jamTabular(large ? context.jamFootnote : context.jamCaption1)
        .copyWith(
          color: dragging
              ? JamNowPlayingColors.text
              : JamNowPlayingColors.secondary,
        );

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
            clipBehavior: Clip.none,
            children: [
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // The track's slot: centred on the hit box's middle line
                  // whatever its thickness, so growing it never moves the
                  // times.
                  SizedBox(
                    height: _hitHeight / 2 + _trackActive / 2,
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: SizedBox(
                        height: _trackActive,
                        child: Center(
                          child: AnimatedContainer(
                            key: jamScrubberTrackKey,
                            duration: reduced
                                ? Duration.zero
                                : JamDuration.fast,
                            curve: JamCurve.standard,
                            width: double.infinity,
                            height: dragging ? _trackActive : _track,
                            child: CustomPaint(
                              painter: _ScrubberPainter(fraction: _fraction),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: _timesGap),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(jamClock(_shownUs), style: times),
                      Text(
                        remaining == null
                            ? '--:--'
                            : '${JamTransportStrings.minus}'
                                  '${jamClock(remaining)}',
                        style: times,
                      ),
                    ],
                  ),
                ],
              ),
              // Laid over the track and centred on it. Positioned last so it
              // takes the touch before anything beneath.
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
                  onTapCancel: _interactive ? _cancel : null,
                  onHorizontalDragStart: _interactive
                      ? (d) => _begin(d.localPosition.dx, width)
                      : null,
                  onHorizontalDragUpdate: _interactive
                      ? (d) => _update(d.localPosition.dx, width)
                      : null,
                  onHorizontalDragEnd: _interactive ? (_) => _end() : null,
                  onHorizontalDragCancel: _interactive ? _cancel : null,
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
  const _ScrubberPainter({required this.fraction});

  final double fraction;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0) return;
    final rrect = RRect.fromLTRBR(
      0,
      0,
      size.width,
      size.height,
      Radius.circular(size.height / 2),
    );
    canvas
      ..drawRRect(rrect, Paint()..color = JamNowPlayingColors.track)
      ..save()
      // The elapsed part is the same capsule clipped at the playhead, so its
      // left end is round and its right edge is straight — the Music look.
      ..clipRect(Rect.fromLTWH(0, 0, size.width * fraction, size.height))
      ..drawRRect(rrect, Paint()..color = JamNowPlayingColors.fill)
      ..restore();
  }

  @override
  bool shouldRepaint(_ScrubberPainter old) => old.fraction != fraction;
}

/// `m:ss` (or `h:mm:ss`) from microseconds — no leading zero on the minutes,
/// the way the Music app writes a time.
///
/// Deliberately local: `util/format.dart` reaches for the engine package to
/// name tracks, and these widgets stay engine-free.
String jamClock(int us) {
  final totalSeconds = (us < 0 ? 0 : us) ~/ 1000000;
  final seconds = totalSeconds % 60;
  final minutes = (totalSeconds ~/ 60) % 60;
  final hours = totalSeconds ~/ 3600;
  final ss = seconds.toString().padLeft(2, '0');
  if (hours > 0) return '$hours:${minutes.toString().padLeft(2, '0')}:$ss';
  return '$minutes:$ss';
}
