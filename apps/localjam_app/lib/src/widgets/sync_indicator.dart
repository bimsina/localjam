/// Sync, said only when something is wrong (DESIGN_SPEC v3 §1.2, §6.3).
///
/// The engine's accuracy (±5 ms) should be *felt*, not read. Nothing on Now
/// Playing says "In sync": when everything works there is no line at all,
/// and when it does not, one footnote under the room's name says so in
/// plain words — "Reconnecting…", "Catching up…". No dot, no pulse. The
/// numbers live in Diagnostics.
///
/// Two widgets live here: [JamSyncIndicator], which is pure (a state, an
/// optional fallback line, no engine — testable in one pump), and
/// [SyncIndicator], the thin adapter that derives that state from a live
/// [JamEngine] and its connection. Both keep the one thing sync still does
/// out loud: a throttled buzz when playback falls out of sync.
library;

import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:localjam_client/localjam_client.dart';

import '../design/tokens.dart';
import '../design/typography.dart';
import 'progress.dart';

/// Everything this line says out loud.
abstract final class JamSyncStrings {
  static const String syncing = 'Syncing…';
  static const String catchingUp = 'Catching up…';
  static const String reconnecting = 'Reconnecting…';

  /// The host said it is going to sleep (§3.5). Calm, not a warning:
  /// nothing is broken, and "Reconnecting…" beside it would be a lie.
  static const String hostAsleep = 'The host’s phone is asleep';
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

/// Derives the state from the engine and its connection.
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
    // A paused room that is connected and clock-synced is still in sync.
    // Only an empty room is truly idle.
    return engine.currentItem == null ? JamSyncState.idle : JamSyncState.inSync;
  }
  final sample = engine.lastDriftSample;
  if (sample == null) return JamSyncState.inSync;
  final error = sample.errorUs.abs();
  if (error > _resyncThresholdUs) return JamSyncState.offSync;
  if (error >= _slewThresholdUs) return JamSyncState.catchingUp;
  return JamSyncState.inSync;
}

/// How loudly a status line speaks — through its glyph. The words are always
/// white: orange or red 13 pt text over an arbitrary cover is unreadable on
/// half of them (spec §10.7).
enum JamStatusTone {
  /// A wait that needs nothing from anyone: words alone, no glyph — a calm
  /// glyph at this size reads as a status dot (SY-14).
  calm,

  /// Recoverable trouble: the glyph in the backdrop's amber.
  warning,

  /// Broken: the glyph in the backdrop's red.
  danger,
}

/// One footnote line under the room's name: white words, led by a glyph
/// when the line is trouble, or by a filling ring when it is a download.
@immutable
class JamStatusLine {
  const JamStatusLine(
    this.text, {
    this.tone = JamStatusTone.calm,
    this.icon,
    this.progress,
  });

  final String text;
  final JamStatusTone tone;

  /// A warning or danger line's glyph. Null takes [tone]'s default
  /// ([jamStatusToneIcon]); a calm line draws none.
  final IconData? icon;

  /// Something on its way, 0–1: the line leads with the same filling ring a
  /// queue row shows for its download.
  final double? progress;

  @override
  bool operator ==(Object other) =>
      other is JamStatusLine &&
      other.text == text &&
      other.tone == tone &&
      other.icon == icon &&
      other.progress == progress;

  @override
  int get hashCode => Object.hash(text, tone, icon, progress);
}

/// The line [state] puts on screen, or null when sync has nothing to say.
JamStatusLine? jamSyncStatusLine(JamSyncState state) => switch (state) {
  JamSyncState.idle || JamSyncState.inSync => null,
  JamSyncState.syncing => const JamStatusLine(JamSyncStrings.syncing),
  JamSyncState.hostAway => const JamStatusLine(JamSyncStrings.hostAsleep),
  JamSyncState.reconnecting => const JamStatusLine(
    JamSyncStrings.reconnecting,
    tone: JamStatusTone.warning,
    icon: CupertinoIcons.wifi_exclamationmark,
  ),
  JamSyncState.catchingUp => const JamStatusLine(
    JamSyncStrings.catchingUp,
    tone: JamStatusTone.warning,
  ),
  JamSyncState.offSync => const JamStatusLine(
    JamSyncStrings.offSync,
    tone: JamStatusTone.danger,
  ),
};

/// The colour of [tone]'s glyph on the Now Playing backdrop, which is the
/// same in both themes (D4): the backdrop's own amber and red, which hold
/// 4.5:1 on its brightest ground.
Color jamStatusToneColor(JamStatusTone tone) => switch (tone) {
  JamStatusTone.calm => JamNowPlayingColors.text,
  JamStatusTone.warning => JamNowPlayingColors.warning,
  JamStatusTone.danger => JamNowPlayingColors.destructive,
};

/// The glyph a line of [tone] gets when it names none of its own; null for
/// a calm line, which has none.
IconData? jamStatusToneIcon(JamStatusTone tone) => switch (tone) {
  JamStatusTone.calm => null,
  JamStatusTone.warning => CupertinoIcons.exclamationmark_triangle_fill,
  JamStatusTone.danger => CupertinoIcons.exclamationmark_octagon_fill,
};

/// A fade-*through* for one-line labels: the old line is gone before the new
/// one appears, so two strings are never legible on top of each other
/// mid-swap. Use as both curves of an [AnimatedSwitcher] (the outgoing
/// child runs it in reverse).
const Curve jamFadeThroughCurve = Interval(0.5, 1, curve: Curves.easeOut);

/// The footnote under the room's name: sync's problem when it has one,
/// otherwise [fallback] (the room's other news — a download, a hold), and
/// nothing at all when everything is fine.
///
/// Long-press opens the numbers ([onShowDetails]).
class JamSyncIndicator extends StatefulWidget {
  const JamSyncIndicator({
    super.key,
    required this.state,
    this.fallback,
    this.onShowDetails,
    this.textAlign = TextAlign.center,
  });

  final JamSyncState state;

  /// Shown when sync itself has nothing to say.
  final JamStatusLine? fallback;

  /// Opens the full drift telemetry. Long-press, so it never invites a tap.
  final VoidCallback? onShowDetails;

  final TextAlign textAlign;

  @override
  State<JamSyncIndicator> createState() => _JamSyncIndicatorState();
}

class _JamSyncIndicatorState extends State<JamSyncIndicator> {
  @override
  void didUpdateWidget(JamSyncIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.state == JamSyncState.offSync &&
        oldWidget.state != JamSyncState.offSync) {
      _buzzOffSync();
    }
  }

  /// §2.8: falling out of sync is the one playback event worth feeling —
  /// an audible correction is about to happen and it is not your doing.
  ///
  /// Throttled globally rather than per widget: the room screen and the
  /// docked panel can both be showing a line, and a flapping link should not
  /// turn the phone into a pager.
  void _buzzOffSync() {
    final now = DateTime.now();
    final last = _lastOffSyncBuzz;
    if (last != null && now.difference(last) < JamHaptics.offSyncThrottle) {
      return;
    }
    _lastOffSyncBuzz = now;
    JamHaptics.offSync();
  }

  @override
  Widget build(BuildContext context) {
    // "Syncing…" is the mildest thing sync says, and the room's own news
    // (a song still on its way) explains more; every other sync problem
    // outranks it.
    final fallback = widget.fallback;
    final line = widget.state == JamSyncState.syncing && fallback != null
        ? fallback
        : jamSyncStatusLine(widget.state) ?? fallback;
    final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final alignment = switch (widget.textAlign) {
      TextAlign.left || TextAlign.start => AlignmentDirectional.topStart,
      TextAlign.right || TextAlign.end => AlignmentDirectional.topEnd,
      _ => AlignmentDirectional.topCenter,
    };
    return AnimatedSwitcher(
      // Long enough for each half of the fade-through to read.
      duration: reduced ? Duration.zero : JamDuration.slow,
      switchInCurve: jamFadeThroughCurve,
      switchOutCurve: jamFadeThroughCurve,
      layoutBuilder: (current, previous) =>
          Stack(alignment: alignment, children: [...previous, ?current]),
      child: line == null
          ? const SizedBox.shrink(key: ValueKey<String>('quiet'))
          : Semantics(
              // Keyed by what the line *is*, not its numbers: "Getting this
              // song… 14%" counting up updates in place rather than fading
              // through on every percent.
              key: ValueKey<String>(
                '${line.tone.name}:'
                '${line.text.replaceAll(RegExp(r'\d+'), '#')}',
              ),
              liveRegion: true,
              onLongPress: widget.onShowDetails,
              child: GestureDetector(
                onLongPress: widget.onShowDetails,
                behavior: HitTestBehavior.opaque,
                child: _StatusLineText(line: line, alignment: alignment),
              ),
            ),
    );
  }
}

/// The words in white, led by a glyph in the tone's colour (trouble only)
/// or a filling ring (a download).
class _StatusLineText extends StatelessWidget {
  const _StatusLineText({required this.line, required this.alignment});

  final JamStatusLine line;
  final AlignmentGeometry alignment;

  @override
  Widget build(BuildContext context) {
    final calm = line.tone == JamStatusTone.calm;
    final style = context.jamFootnote.copyWith(
      color: JamNowPlayingColors.text,
      fontWeight: calm ? FontWeight.w400 : FontWeight.w600,
    );
    final scaler = MediaQuery.textScalerOf(context);
    final progress = line.progress;
    final icon = calm ? null : (line.icon ?? jamStatusToneIcon(line.tone));
    final Widget? lead = progress != null
        ? JamProgressRing(
            size: scaler.scale(JamProgressRing.inlineSize),
            value: progress.clamp(0.0, 1.0),
            color: JamNowPlayingColors.text,
          )
        : icon == null
        ? null
        : Icon(
            icon,
            size: scaler.scale(JamIconSize.inline),
            color: jamStatusToneColor(line.tone),
          );
    return Align(
      alignment: alignment,
      widthFactor: 1,
      heightFactor: 1,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (lead != null) ...[
            ExcludeSemantics(child: lead),
            const SizedBox(width: JamSpace.xs + JamSpace.xxs),
          ],
          Flexible(
            child: Text(
              line.text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          ),
        ],
      ),
    );
  }
}

/// The engine-bound adapter: watches drift samples and the connection, and
/// renders [JamSyncIndicator].
class SyncIndicator extends StatefulWidget {
  const SyncIndicator({
    super.key,
    required this.engine,
    required this.connection,
    required this.clockSynced,
    this.hostAway = false,
    this.fallback,
    this.onShowDetails,
    this.textAlign = TextAlign.center,
  });

  final JamEngine engine;
  final JamConnectionState connection;

  /// Whether the host said it is going to sleep — see [JamSyncState.hostAway].
  final bool hostAway;

  /// False only for a guest whose §4 clock burst has not landed.
  final bool clockSynced;

  /// Passed through to [JamSyncIndicator.fallback].
  final JamStatusLine? fallback;

  /// Opens the full drift telemetry. Long-press, so it never invites a tap.
  final VoidCallback? onShowDetails;

  final TextAlign textAlign;

  @override
  State<SyncIndicator> createState() => _SyncIndicatorState();
}

class _SyncIndicatorState extends State<SyncIndicator> {
  StreamSubscription<DriftSample>? _sub;
  JamSyncState? _last;

  @override
  void initState() {
    super.initState();
    _listen();
  }

  @override
  void didUpdateWidget(SyncIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.engine, widget.engine)) {
      unawaited(_sub?.cancel());
      _listen();
    }
  }

  /// Rebuilds only when a sample changes what the line would say: drift
  /// arrives several times a second and almost never matters.
  void _listen() {
    _sub = widget.engine.driftSamples.listen((_) {
      if (!mounted) return;
      if (_state() != _last) setState(() {});
    });
  }

  JamSyncState _state() => jamSyncState(
    engine: widget.engine,
    connection: widget.connection,
    clockSynced: widget.clockSynced,
    hostAway: widget.hostAway,
  );

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = _last = _state();
    return JamSyncIndicator(
      state: state,
      fallback: widget.fallback,
      onShowDetails: widget.onShowDetails,
      textAlign: widget.textAlign,
    );
  }
}
