/// The ambient sync state — one glance, not a readout.
///
/// The engine's accuracy (±5 ms) should be *felt*, not read. The pre-overhaul
/// UI put clock offset, drift in milliseconds, slew counts and resync counts
/// on both screens; none of that is actionable to someone in a van. This
/// reduces it to a dot and, only when something is off, a word. The numbers
/// still exist — long-press.
///
/// Two widgets live here: [JamSyncIndicator], which is pure (a state and a
/// callback, no engine, testable in one pump), and [SyncIndicator], the thin
/// adapter that derives that state from a live [JamEngine] and its
/// connection. Screens keep using the adapter; anything that already knows
/// its state should use the pure one.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:localjam_client/localjam_client.dart';

import '../design/tokens.dart';
import '../design/typography.dart';

/// Everything this indicator says out loud.
abstract final class JamSyncStrings {
  /// The quiet reward for everything working. A lone 6 dp dot read as a
  /// speck of dust on a review build, so the calm state gets a word too —
  /// in `textSecondary`, with no colour of its own.
  static const String inSync = 'In sync';
  static const String syncing = 'Syncing…';
  static const String catchingUp = 'Catching up';
  static const String reconnecting = 'Reconnecting…';

  /// The host said it is going to sleep (§3.5). Calm, not a warning: nothing
  /// is broken, and "Reconnecting…" pulsing beside it would be a lie.
  static const String hostAsleep = 'Host asleep';
  static const String offSync = 'Out of sync';

  /// The long-press affordance, announced rather than drawn.
  static const String details = 'Sync details';
}

/// Drift thresholds mirroring the engine's own policy (§5.4).
const int _slewThresholdUs = 15000;
const int _resyncThresholdUs = 50000;

/// When the last out-of-sync buzz fired, app-wide. See [JamHaptics.offSync].
DateTime? _lastOffSyncBuzz;

/// Forgets the throttle, so a test can assert the buzz twice.
@visibleForTesting
void resetOffSyncHapticThrottle() => _lastOffSyncBuzz = null;

/// The dot's diameter.
const double _dotSize = 6;

/// The default row height — a real long-press target.
const double _kTapTarget = 44;

/// The packed height used inside the room's app bar.
const double kJamSyncIndicatorCompactHeight = 28;

/// How long a pulse takes, out and back.
const Duration _pulsePeriod = Duration(milliseconds: 1200);

/// What the room should be told about sync right now.
enum JamSyncState {
  /// Nothing is playing — there is nothing to be in sync with.
  idle,

  /// A guest whose session clock has not converged yet.
  syncing,

  /// The transport dropped and is retrying.
  reconnecting,

  /// The host announced it is going to sleep (§3.5) — whether or not the
  /// link has dropped yet, the wait is the host's, not the network's.
  hostAway,

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
  bool hostAway = false,
}) {
  if (hostAway) return JamSyncState.hostAway;
  if (connection != JamConnectionState.connected) {
    return JamSyncState.reconnecting;
  }
  if (!clockSynced) return JamSyncState.syncing;
  if (engine.snapshot.status != PlaybackStatus.playing) {
    // A paused room that is connected and clock-synced is still in sync, and
    // keeps saying so as long as there is a track to be in sync on. Reporting
    // `idle` here made the line vanish the moment anyone hit pause, which
    // reads as sync having dropped. Only an empty room is truly idle.
    return engine.currentItem == null ? JamSyncState.idle : JamSyncState.inSync;
  }
  final sample = engine.lastDriftSample;
  if (sample == null) return JamSyncState.inSync;
  final error = sample.errorUs.abs();
  if (error > _resyncThresholdUs) return JamSyncState.offSync;
  if (error >= _slewThresholdUs) return JamSyncState.catchingUp;
  return JamSyncState.inSync;
}

/// A dot and — when something needs saying — a word. Long-press for the
/// numbers.
///
/// Colour lerps over [JamDuration.base] rather than cutting, so a moment of
/// drift never flashes red at the corner of your eye; `syncing` and
/// `reconnecting` pulse the dot instead of animating anything larger.
class JamSyncIndicator extends StatefulWidget {
  const JamSyncIndicator({
    super.key,
    required this.state,
    this.onShowDetails,
    this.height = _kTapTarget,
  });

  final JamSyncState state;

  /// Opens the full drift telemetry. Long-press, so it never invites a tap.
  final VoidCallback? onShowDetails;

  /// The row's height. 44 by default — a real target for the long-press.
  /// The room's app bar packs it to [_kCompactHeight] so the chevron beside
  /// the two-line title has a fixed slot to align against.
  final double height;

  @override
  State<JamSyncIndicator> createState() => _JamSyncIndicatorState();
}

class _JamSyncIndicatorState extends State<JamSyncIndicator>
    with SingleTickerProviderStateMixin {
  /// One controller for the whole widget, started only while a pulsing state
  /// is showing and never at all when animations are off.
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: _pulsePeriod,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncPulse();
  }

  @override
  void didUpdateWidget(JamSyncIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncPulse();
    if (widget.state == JamSyncState.offSync &&
        oldWidget.state != JamSyncState.offSync) {
      _buzzOffSync();
    }
  }

  /// §2.8: falling out of sync is the one playback event worth feeling —
  /// an audible correction is about to happen and it is not your doing.
  ///
  /// Throttled globally rather than per widget: the room screen and the
  /// docked panel can both be showing an indicator, and a flapping link
  /// should not turn the phone into a pager.
  void _buzzOffSync() {
    final now = DateTime.now();
    final last = _lastOffSyncBuzz;
    if (last != null && now.difference(last) < JamHaptics.offSyncThrottle) {
      return;
    }
    _lastOffSyncBuzz = now;
    JamHaptics.offSync();
  }

  bool get _shouldPulse =>
      widget.state == JamSyncState.syncing ||
      widget.state == JamSyncState.reconnecting;

  void _syncPulse() {
    final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (_shouldPulse && !reduced) {
      if (!_pulse.isAnimating) _pulse.repeat(reverse: true);
    } else {
      if (_pulse.isAnimating) _pulse.stop();
      _pulse.value = 1;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    if (widget.state == JamSyncState.idle) return const SizedBox.shrink();

    // `inSync` is deliberately wordless: a quiet dot is the reward for
    // everything working.
    final (String? label, Color color) = switch (widget.state) {
      JamSyncState.inSync => (JamSyncStrings.inSync, colors.textSecondary),
      JamSyncState.syncing => (JamSyncStrings.syncing, colors.textSecondary),
      JamSyncState.catchingUp => (JamSyncStrings.catchingUp, colors.warning),
      JamSyncState.reconnecting => (
        JamSyncStrings.reconnecting,
        colors.warning,
      ),
      JamSyncState.offSync => (JamSyncStrings.offSync, colors.danger),
      JamSyncState.hostAway => (
        JamSyncStrings.hostAsleep,
        colors.textSecondary,
      ),
      JamSyncState.idle => (null, colors.textSecondary),
    };

    // `catchingUp` is the one state whose dot is not its label's colour: an
    // apricot dot with a readable warning-brown word beside it.
    final dotColor = widget.state == JamSyncState.catchingUp
        ? colors.highlight
        : color;

    final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final lerp = reduced ? Duration.zero : JamDuration.base;

    final dot = TweenAnimationBuilder<Color?>(
      tween: ColorTween(end: dotColor),
      duration: lerp,
      curve: JamCurve.base,
      builder: (context, value, child) => DecoratedBox(
        decoration: BoxDecoration(
          color: value ?? dotColor,
          shape: BoxShape.circle,
        ),
        child: child,
      ),
      child: const SizedBox(width: _dotSize, height: _dotSize),
    );

    return Semantics(
      label: label == null ? JamSyncStrings.inSync : 'Sync: $label',
      button: widget.onShowDetails != null,
      onLongPress: widget.onShowDetails,
      excludeSemantics: true,
      child: GestureDetector(
        onLongPress: widget.onShowDetails,
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          height: widget.height,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _shouldPulse
                  ? FadeTransition(
                      // 0.4 ↔ 1.0, so the dot breathes rather than blinks.
                      opacity: _pulse.drive(Tween<double>(begin: 0.4, end: 1)),
                      child: dot,
                    )
                  : dot,
              if (label != null) ...[
                const SizedBox(width: JamSpace.sm),
                TweenAnimationBuilder<Color?>(
                  tween: ColorTween(end: color),
                  duration: lerp,
                  curve: JamCurve.base,
                  builder: (context, value, _) => Text(
                    label,
                    style: context.jamFootnote.copyWith(color: value ?? color),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The engine-bound adapter. Same constructor it has always had, so the room
/// screen keeps compiling while Phase 2 moves over.
class SyncIndicator extends StatefulWidget {
  const SyncIndicator({
    super.key,
    required this.engine,
    required this.connection,
    required this.clockSynced,
    this.hostAway = false,
    this.onShowDetails,
    this.height = _kTapTarget,
  });

  final JamEngine engine;
  final JamConnectionState connection;

  /// Whether the host said it is going to sleep — see [JamSyncState.hostAway].
  final bool hostAway;

  /// False only for a guest whose §4 clock burst has not landed.
  final bool clockSynced;

  /// Opens the full drift telemetry. Long-press, so it never invites a tap.
  final VoidCallback? onShowDetails;

  /// Passed straight through to [JamSyncIndicator.height].
  final double height;

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
  Widget build(BuildContext context) => JamSyncIndicator(
    state: jamSyncState(
      engine: widget.engine,
      connection: widget.connection,
      clockSynced: widget.clockSynced,
      hostAway: widget.hostAway,
    ),
    onShowDetails: widget.onShowDetails,
    height: widget.height,
  );
}
