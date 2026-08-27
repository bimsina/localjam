/// The simulated player: a fake local playhead plus the application of
/// [DriftPolicy] actions to it (PROTOCOL.md §5.4).
///
/// Pure logic — no timers, no I/O, no clock reads. The caller (the `join`
/// command's tick loop, or a test) supplies the authoritative
/// [PlaybackSnapshot], the current session-clock time, and the elapsed local
/// wall-clock time since the previous tick.
///
/// The playhead models a real audio engine whose playback clock runs at a
/// slightly wrong rate: while playing it advances at
/// `(1 + skewPpm / 1e6) * rate` media-µs per elapsed local µs, so with a
/// non-zero [skewPpm] drift accumulates and the §5.4 corrections become
/// observable.
library;

import 'dart:math' as math;

import 'package:localjam_core/localjam_core.dart';

/// A simulated playhead that follows [PlaybackSnapshot]s and corrects drift
/// per [DriftPolicy].
class SimPlayer {
  /// Creates a simulated player.
  ///
  /// [skewPpm] is an artificial constant playback-clock skew in parts per
  /// million: the playhead advances at `(1 + skewPpm / 1e6) ×` real time
  /// while playing (e.g. 5000 ⇒ +0.5 %).
  SimPlayer({this.policy = const DriftPolicy(), this.skewPpm = 0});

  /// The §5.4 drift-correction policy consulted on every [tick].
  final DriftPolicy policy;

  /// Artificial playback-clock skew, parts per million.
  final double skewPpm;

  int? _lastRev;
  double _playheadUs = 0;

  double _slewMultiplier = 1.0;
  double _slewRemainingUs = 0;

  /// Number of slew *episodes* started (a re-issued slew while one is already
  /// in progress extends the episode, it does not count again).
  int slews = 0;

  /// Number of hard resyncs performed.
  int hardResyncs = 0;

  /// The action returned by the most recent [tick].
  DriftAction lastAction = const DriftNone();

  /// `actual - expected` (µs) measured by the most recent [tick];
  /// positive = playhead is ahead of the anchor trajectory.
  int lastDriftUs = 0;

  /// The fake local playhead position, media microseconds.
  int get positionUs => _playheadUs.round();

  /// Whether a slew is currently in progress.
  bool get isSlewing => _slewRemainingUs > 0;

  /// Remaining slew duration in µs of playback time (0 when not slewing).
  int get slewRemainingUs => _slewRemainingUs.round();

  /// Forces the playhead to [positionUs] without touching counters or slew
  /// state. Exists so tests (and demos) can inject a drift gap.
  void debugSetPositionUs(int positionUs) {
    _playheadUs = positionUs.toDouble();
  }

  /// Advances the simulation by one tick and applies drift correction.
  ///
  /// * [snapshot] — the latest authoritative state (§5.1).
  /// * [sessionNowUs] — "now" on the session clock (host monotonic µs),
  ///   i.e. `clock.localToHostUs(localNowUs)`.
  /// * [elapsedUs] — local wall-clock µs elapsed since the previous tick.
  ///
  /// Behavior:
  /// * A new `rev` (play/pause/seek/set_media all bump it) makes the player
  ///   adopt the snapshot: the playhead snaps to
  ///   `snapshot.positionAt(sessionNowUs)` and any slew is cancelled —
  ///   modeling a real player rescheduling against a new anchor.
  /// * While playing past the anchor time, the playhead advances at the
  ///   skewed rate ([skewPpm]), times the snapshot rate, times the slew
  ///   multiplier while a slew is active. Lead-in time before a scheduled
  ///   start (§5.3) does not advance the playhead.
  /// * The measured drift (`playhead - positionAt`) is fed to [policy] and
  ///   the returned action is applied: [DriftNone] keeps going (an active
  ///   slew keeps running), [DriftSlew] (re)starts a slew at the returned
  ///   multiplier for its duration, [DriftHardResync] snaps the playhead to
  ///   the expected position.
  DriftAction tick({
    required PlaybackSnapshot snapshot,
    required int sessionNowUs,
    required int elapsedUs,
  }) {
    if (snapshot.rev != _lastRev) {
      // New authoritative state: adopt it (a real player would reschedule).
      _lastRev = snapshot.rev;
      _playheadUs = snapshot.positionAt(sessionNowUs).toDouble();
      _cancelSlew();
    } else if (snapshot.status == PlaybackStatus.playing) {
      final anchor = snapshot.anchor;
      // Only time past the scheduled anchor start counts as playback (§5.3);
      // during the lead-in the playhead stays pinned at the anchor position.
      final sinceAnchorUs = anchor == null
          ? elapsedUs
          : sessionNowUs - anchor.hostTimeUs;
      if (sinceAnchorUs > 0) {
        _advance(math.min(elapsedUs, sinceAnchorUs), snapshot.rate);
      }
    }

    final expectedUs = snapshot.positionAt(sessionNowUs);
    lastDriftUs = positionUs - expectedUs;

    // Nothing to correct unless we are actually playing.
    final DriftAction action = snapshot.status == PlaybackStatus.playing
        ? policy.decide(
            expectedPositionUs: expectedUs,
            actualPositionUs: positionUs,
          )
        : const DriftNone();

    switch (action) {
      case DriftNone():
        break; // Keep going; an in-progress slew keeps running.
      case DriftSlew(:final rateMultiplier, :final durationUs):
        if (!isSlewing) slews++;
        _slewMultiplier = rateMultiplier;
        _slewRemainingUs = durationUs.toDouble();
      case DriftHardResync():
        hardResyncs++;
        _playheadUs = expectedUs.toDouble();
        _cancelSlew();
    }
    lastAction = action;
    return action;
  }

  void _cancelSlew() {
    _slewMultiplier = 1.0;
    _slewRemainingUs = 0;
  }

  /// Advances the playhead by [playUs] µs of playback time at the (skewed)
  /// local playback-clock rate, honoring an active slew for at most its
  /// remaining duration.
  void _advance(int playUs, double rate) {
    var remaining = playUs.toDouble();
    final skewFactor = 1 + skewPpm / 1e6;
    if (_slewRemainingUs > 0) {
      final chunk = math.min(remaining, _slewRemainingUs);
      _playheadUs += chunk * rate * skewFactor * _slewMultiplier;
      _slewRemainingUs -= chunk;
      remaining -= chunk;
      if (_slewRemainingUs <= 0) _cancelSlew();
    }
    _playheadUs += remaining * rate * skewFactor;
  }
}
