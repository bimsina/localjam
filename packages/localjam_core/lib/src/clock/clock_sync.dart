/// Clock synchronization for LocalJam guests.
///
/// Implements the client-side algorithm of PROTOCOL.md §4 (Clock
/// synchronization) as pure, I/O-free logic. The transport performs the
/// NTP-style `clock_ping` / `clock_pong` exchange and feeds the resulting
/// timestamp quadruples into [ClockSync] as [ClockSample]s; this module never
/// touches the network or any real clock.
///
/// All timestamps are integer **microseconds** on monotonic clocks:
/// the guest's local monotonic clock (t0, t3) and the host's session clock
/// (t1, t2). See PROTOCOL.md §4.
library;

import 'package:meta/meta.dart';

/// One NTP-style measurement, built from the four timestamps of a single
/// `clock_ping` / `clock_pong` round trip (PROTOCOL.md §4):
///
/// * [t0] — guest monotonic µs when the ping was sent.
/// * [t1] — host session-clock µs when the ping was received.
/// * [t2] — host session-clock µs when the pong was sent.
/// * [t3] — guest monotonic µs when the pong was received.
@immutable
class ClockSample {
  /// Creates a sample from the raw timestamp quadruple.
  const ClockSample({
    required this.t0,
    required this.t1,
    required this.t2,
    required this.t3,
  });

  /// Guest monotonic time (µs) at ping send.
  final int t0;

  /// Host session-clock time (µs) at ping receive.
  final int t1;

  /// Host session-clock time (µs) at pong send.
  final int t2;

  /// Guest monotonic time (µs) at pong receive.
  final int t3;

  /// Estimated clock offset in µs, per PROTOCOL.md §4:
  /// `offset = ((t1 - t0) + (t2 - t3)) / 2`.
  ///
  /// The offset is defined so that `hostTime ≈ localTime + offsetUs`.
  /// Integer division truncates toward zero (sub-µs precision is
  /// irrelevant at the ±40 ms sync target).
  int get offsetUs => ((t1 - t0) + (t2 - t3)) ~/ 2;

  /// Round-trip time in µs excluding host processing, per PROTOCOL.md §4:
  /// `rtt = (t3 - t0) - (t2 - t1)`.
  int get rttUs => (t3 - t0) - (t2 - t1);

  @override
  bool operator ==(Object other) =>
      other is ClockSample &&
      other.t0 == t0 &&
      other.t1 == t1 &&
      other.t2 == t2 &&
      other.t3 == t3;

  @override
  int get hashCode => Object.hash(t0, t1, t2, t3);

  @override
  String toString() =>
      'ClockSample(t0: $t0, t1: $t1, t2: $t2, t3: $t3, '
      'offsetUs: $offsetUs, rttUs: $rttUs)';
}

/// How the discontinuity detector reads one steady-state sample.
enum _Verdict {
  /// Ordinary sample: gate-rejected, in the join burst, or within
  /// `discontinuityThresholdUs` of the estimate. Handled exactly as before.
  normal,

  /// Beyond the threshold but not yet confirmed: held out of the EWMA until
  /// it is either confirmed by the next sample or cleared as an outlier.
  candidate,

  /// Confirmed clock jump: the estimator resets before handling the sample.
  discontinuity,
}

/// Estimates the guest→host clock offset from a stream of [ClockSample]s,
/// implementing the guest algorithm of PROTOCOL.md §4:
///
/// * **Join burst**: the first [burstSize] samples form the join burst; the
///   initial offset estimate is the offset of the sample with **minimum RTT**
///   (least queued, most symmetric). [isSynchronized] becomes true once
///   [minSamplesForSync] burst samples have arrived, so a lossy join still
///   converges before the full burst completes.
/// * **Steady state**: a sample is accepted only if its RTT is within
///   [rttGateFactor] (1.5× per spec) of the best RTT seen; accepted samples
///   blend into the estimate with an EWMA of [ewmaAlpha] (α = 0.1 per spec).
/// * **Slewing**: the raw EWMA estimate is internal. The *applied* offset —
///   what [offsetUs], [hostToLocalUs], and [localToHostUs] expose — moves
///   toward the estimate at most [maxSlewUsPerSecond] (≤ 1 ms/s per spec) so
///   the audible timeline never jumps. Elapsed local time is derived from the
///   `t3` values of consecutive samples passed to [addSample] — callers do
///   not supply a clock; feed samples with monotonically increasing `t3`.
/// * **Hard resync**: if the applied-vs-estimate error exceeds
///   [hardResyncThresholdUs] (> 50 ms per spec), the applied offset steps to
///   the estimate immediately and [needsHardResync] is set; the player layer
///   should pause, step, rejoin playback position, then call
///   [acknowledgeHardResync].
/// * **Clock discontinuities**: samples that disagree with the estimate by
///   more than [discontinuityThresholdUs] are treated as a broken clock, not
///   as drift, and reset the estimator — see below.
///
/// The offset convention follows [ClockSample.offsetUs]:
/// `hostTime ≈ localTime + offsetUs`.
///
/// ## Clock discontinuities (device sleep)
///
/// Every monotonic clock this stack can reach — Dart's `Stopwatch`,
/// `mach_absolute_time` on iOS, `System.nanoTime` on Android — **stops
/// counting while the device is in deep sleep**. A guest that sleeps for two
/// minutes mid-session wakes with a local clock two minutes behind where the
/// host's session clock expects it, so every subsequent sample reports an
/// offset that is minutes away from the converged estimate.
///
/// That is not drift and must not be smoothed: crystal error is ~50 ppm
/// (tens of µs per second, i.e. well under 50 ms across a plausible session),
/// and network asymmetry moves an accepted sample's offset by at most a few
/// ms. An offset error beyond [discontinuityThresholdUs] (default 500 ms —
/// three orders of magnitude above jitter and drift, ten times the 50 ms
/// hard-resync band) can only mean the local clock itself jumped. Feeding
/// such samples through the EWMA would crawl toward the truth at 10 % of the
/// gap per ping while hard-resync fired repeatedly against a stale estimate.
///
/// So the estimator detects the jump instead of averaging it:
///
/// * A sample that passes the steady-state RTT gate and whose offset differs
///   from the *raw* estimate by more than [discontinuityThresholdUs] is a
///   **discontinuity candidate**.
/// * [discontinuityConfirmations] consecutive mutually-consistent candidates
///   (each within [discontinuityThresholdUs] of the first one's offset) are
///   required before resetting — default 2, so a single wild outlier that
///   slipped past the RTT gate cannot destroy a good estimate. Any accepted
///   sample that agrees with the estimate clears the pending state; a
///   candidate that disagrees with the pending one *replaces* it and restarts
///   the count, since two unrelated outliers are not evidence of a jump.
/// * An unconfirmed candidate is **quarantined**: it is held out of the EWMA
///   (it would otherwise drag the estimate a tenth of the way to nonsense and
///   make the *next*, good samples look like candidates), though like a
///   gate-rejected sample it still advances slewing.
/// * On confirmation the estimator re-enters its initial state (see
///   [needsHardResync] and [isSynchronized] below) and the confirming sample
///   becomes the first sample of a fresh join burst. The guest's existing
///   ping schedule (§4: one every 2 s) then re-converges with no transport
///   involvement: min-RTT re-selection over the new burst, a new EWMA seeded
///   from it, and [isSynchronized] back to true after [minSamplesForSync]
///   post-reset samples.
///
/// Both the best-RTT reference and the slewing state are cleared by the
/// reset: the pre-sleep min RTT is not a valid gate reference if the radio
/// re-associated (or moved networks) while asleep, and the applied offset
/// must not slew from a stale value toward a target minutes away.
///
/// **Consumer contract.** The reset is deliberately indistinguishable from a
/// pre-first-sync estimator: [isSynchronized] goes back to false, [offsetUs]
/// to null, and [hostToLocalUs]/[localToHostUs] throw [StateError] again
/// until the fresh burst lands. [needsHardResync] is set at the same moment
/// (and is consumable via [acknowledgeHardResync] as always), so a player
/// layer that pauses on the flag and gates scheduling on [isSynchronized] —
/// as `localjam_client`'s guest engine does — pauses at the jump, waits out
/// the re-burst, and rejoins at the corrected position. Note that
/// [needsHardResync] can therefore be true while [isSynchronized] is false;
/// conversions must not be attempted until the latter turns true again.
///
/// Detection only considers samples that pass the RTT gate, so a
/// discontinuity is only visible once at least one post-wake ping is of
/// accepted quality. If the post-wake network is so much worse that *no*
/// sample passes the gate, the estimator holds its stale estimate — the same
/// behaviour it has always had for a network that degrades without a jump —
/// until one good sample arrives. During the initial join burst detection is
/// disabled entirely: burst min-RTT selection already handles arbitrary
/// offsets, so a jump before the first sync is a non-event.
class ClockSync {
  /// Creates an estimator. All tunables default to the PROTOCOL.md §4 values.
  ClockSync({
    this.burstSize = 8,
    this.minSamplesForSync = 4,
    this.rttGateFactor = 1.5,
    this.ewmaAlpha = 0.1,
    this.maxSlewUsPerSecond = 1000,
    this.hardResyncThresholdUs = 50000,
    this.discontinuityThresholdUs = 500000,
    this.discontinuityConfirmations = 2,
  }) : assert(burstSize >= 1, 'burstSize must be >= 1'),
       assert(
         minSamplesForSync >= 1 && minSamplesForSync <= burstSize,
         'minSamplesForSync must be in [1, burstSize]',
       ),
       assert(rttGateFactor >= 1.0, 'rttGateFactor must be >= 1.0'),
       assert(
         ewmaAlpha > 0.0 && ewmaAlpha <= 1.0,
         'ewmaAlpha must be in (0, 1]',
       ),
       assert(maxSlewUsPerSecond > 0, 'maxSlewUsPerSecond must be > 0'),
       assert(hardResyncThresholdUs > 0, 'hardResyncThresholdUs must be > 0'),
       assert(
         discontinuityThresholdUs > hardResyncThresholdUs,
         'discontinuityThresholdUs must exceed hardResyncThresholdUs: '
         'errors inside the hard-resync band are drift, not jumps',
       ),
       assert(
         discontinuityConfirmations >= 1,
         'discontinuityConfirmations must be >= 1',
       );

  /// Number of samples in the join burst (PROTOCOL.md §4: "burst of 8 pings
  /// at join"). While fewer than this many samples have been added, the
  /// estimate is the min-RTT burst sample and the applied offset steps
  /// freely (nothing is playing yet).
  final int burstSize;

  /// Minimum burst samples before [isSynchronized] turns true (default 4).
  /// The spec's burst is 8; accepting readiness earlier lets a lossy join
  /// converge instead of stalling. The min-RTT selection keeps refining
  /// until the full burst has arrived.
  final int minSamplesForSync;

  /// Steady-state RTT gate (PROTOCOL.md §4: "accept a sample only if its RTT
  /// is within 1.5× of the best RTT seen").
  final double rttGateFactor;

  /// EWMA blend factor for accepted steady-state samples
  /// (PROTOCOL.md §4: α ≈ 0.1).
  final double ewmaAlpha;

  /// Maximum rate at which the applied offset slews toward the raw estimate,
  /// in µs of offset change per second of local time
  /// (PROTOCOL.md §4: "slew it (≤ 1 ms per second)").
  final int maxSlewUsPerSecond;

  /// Applied-vs-estimate error above which the estimator steps immediately
  /// and flags [needsHardResync]
  /// (PROTOCOL.md §4: "large error (> 50 ms) ⇒ hard resync").
  final int hardResyncThresholdUs;

  /// Offset disagreement (µs) above which an accepted sample is read as a
  /// **clock discontinuity** (device sleep stopping the monotonic clock)
  /// rather than drift or jitter, triggering a full reset once confirmed.
  ///
  /// Default 500 000 µs = 0.5 s: orders of magnitude beyond LAN jitter on a
  /// gate-accepted sample and beyond ~50 ppm crystal drift over any plausible
  /// session, and 10× the 50 ms [hardResyncThresholdUs] band that ordinary
  /// large errors are meant to occupy. Must be greater than
  /// [hardResyncThresholdUs].
  final int discontinuityThresholdUs;

  /// How many consecutive, mutually consistent discontinuity candidates are
  /// required before the estimator resets (default 2). One wild outlier that
  /// slipped through the RTT gate is never enough to discard a converged
  /// estimate; a real clock jump makes *every* subsequent sample a candidate,
  /// so the cost of confirmation is a single extra ping (2 s at the §4 steady
  /// rate). Set to 1 to reset on the first candidate.
  final int discontinuityConfirmations;

  int _sampleCount = 0;
  int? _bestRttUs;

  /// Offset of the min-RTT sample seen so far during the join burst.
  int? _burstBestOffsetUs;
  int? _burstBestRttUs;

  /// Raw (unslewed) EWMA estimate, µs. Non-null once synchronized.
  double? _estimateUs;

  /// Applied (slewed) offset, µs. Non-null once synchronized.
  double? _appliedUs;

  /// `t3` of the most recent sample, used to derive elapsed local time
  /// between samples for slewing.
  int? _lastT3;

  bool _needsHardResync = false;

  /// Offset of the first candidate in the current run of discontinuity
  /// candidates, and how many consistent candidates have arrived. Cleared by
  /// any accepted sample that agrees with the estimate, and by the reset.
  int? _pendingDiscontinuityOffsetUs;
  int _pendingDiscontinuityCount = 0;

  /// True once enough join-burst samples ([minSamplesForSync], or the full
  /// [burstSize]) have produced an offset estimate.
  ///
  /// Returns to false if a clock discontinuity is detected (device sleep —
  /// see the class doc), until the post-reset join burst re-converges.
  bool get isSynchronized => _appliedUs != null;

  /// The current **applied** (slew-limited) offset estimate in µs, such that
  /// `hostTime ≈ localTime + offsetUs`. Null before [isSynchronized].
  int? get offsetUs => _appliedUs?.round();

  /// The lowest RTT (µs) seen across all samples, or null before the first
  /// sample. This is the reference for the steady-state RTT gate.
  int? get bestRttUs => _bestRttUs;

  /// True after the applied offset had to step by more than
  /// [hardResyncThresholdUs], **or** after a clock discontinuity reset the
  /// estimator. The player layer should pause, seek to the anchor-correct
  /// position, resume, and then call [acknowledgeHardResync].
  ///
  /// After a discontinuity this is set while [isSynchronized] is false: the
  /// player must pause and wait for the fresh join burst before it can map
  /// session time to local time again.
  bool get needsHardResync => _needsHardResync;

  /// The raw (unslewed) EWMA estimate, exposed for tests/diagnostics only.
  @visibleForTesting
  double? get debugEstimateUs => _estimateUs;

  /// How many consistent discontinuity candidates are currently pending
  /// confirmation, for tests/diagnostics only. Reaches
  /// [discontinuityConfirmations] only transiently — the reset clears it.
  @visibleForTesting
  int get debugPendingDiscontinuityCount => _pendingDiscontinuityCount;

  /// Clears the [needsHardResync] flag after the player layer has handled it.
  void acknowledgeHardResync() {
    _needsHardResync = false;
  }

  /// Feeds one measurement into the estimator.
  ///
  /// Samples must be added in the order they were taken: elapsed local time
  /// for slew limiting is derived from the difference between consecutive
  /// samples' [ClockSample.t3] values (a non-increasing `t3` contributes
  /// zero elapsed time).
  ///
  /// If this sample confirms a clock discontinuity (see the class doc) the
  /// estimator resets first and this sample opens the new join burst, so the
  /// call can leave [isSynchronized] false and [needsHardResync] true.
  void addSample(ClockSample sample) {
    final rtt = sample.rttUs;
    final verdict = _classify(sample, rtt);

    // A confirmed clock jump (device sleep) invalidates every piece of
    // accumulated state, including the min RTT and the slew position; the
    // triggering sample then becomes burst sample #1 of the recovery.
    if (verdict == _Verdict.discontinuity) {
      _resetForDiscontinuity();
    }

    _sampleCount++;

    // Track the best (lowest) RTT ever seen; it anchors the steady-state
    // RTT acceptance gate.
    if (_bestRttUs == null || rtt < _bestRttUs!) {
      _bestRttUs = rtt;
    }

    if (_sampleCount <= burstSize) {
      _addBurstSample(sample, rtt);
    } else {
      _addSteadySample(sample, rtt, quarantined: verdict == _Verdict.candidate);
    }

    _lastT3 = sample.t3;
  }

  /// Classifies [sample] for discontinuity purposes, updating the pending
  /// candidate run as a side effect.
  ///
  /// Only steady-state samples that pass the RTT gate are considered: during
  /// the join burst arbitrary offsets are expected (min-RTT selection handles
  /// them), and a gate-rejected sample carries no trustworthy offset.
  /// Disagreement is measured against the *raw* estimate rather than the
  /// slewed applied offset, so a reset cannot be triggered by slew lag.
  _Verdict _classify(ClockSample sample, int rtt) {
    final estimate = _estimateUs;
    // `_sampleCount` samples have been added already, so this one is
    // steady-state only if it lands past the burst.
    if (estimate == null || _sampleCount < burstSize) return _Verdict.normal;
    if (rtt > rttGateFactor * _bestRttUs!) return _Verdict.normal;

    final offset = sample.offsetUs;
    if ((offset - estimate).abs() <= discontinuityThresholdUs) {
      // Ordinary error: drift, jitter, or a hard-resync-sized excursion. Any
      // partial candidate run was noise.
      _pendingDiscontinuityOffsetUs = null;
      _pendingDiscontinuityCount = 0;
      return _Verdict.normal;
    }

    final pending = _pendingDiscontinuityOffsetUs;
    if (pending == null ||
        (offset - pending).abs() > discontinuityThresholdUs) {
      // First candidate, or one that disagrees with the pending candidate as
      // much as it does with the estimate — unrelated outliers, not a jump.
      // Start a new run from this sample.
      _pendingDiscontinuityOffsetUs = offset;
      _pendingDiscontinuityCount = 1;
    } else {
      _pendingDiscontinuityCount++;
    }
    return _pendingDiscontinuityCount >= discontinuityConfirmations
        ? _Verdict.discontinuity
        : _Verdict.candidate;
  }

  /// Re-enters the pre-first-sync state after a confirmed clock jump, and
  /// raises [needsHardResync] so the player layer pauses until the fresh
  /// join burst has re-converged.
  void _resetForDiscontinuity() {
    _sampleCount = 0;
    _bestRttUs = null;
    _burstBestOffsetUs = null;
    _burstBestRttUs = null;
    _estimateUs = null;
    _appliedUs = null;
    _lastT3 = null;
    _pendingDiscontinuityOffsetUs = null;
    _pendingDiscontinuityCount = 0;
    _needsHardResync = true;
  }

  void _addBurstSample(ClockSample sample, int rtt) {
    // PROTOCOL.md §4: keep the burst sample with minimum RTT as the initial
    // offset. Nothing is playing during the join burst, so the applied
    // offset steps directly to the estimate (no slewing, no resync flag).
    if (_burstBestRttUs == null || rtt < _burstBestRttUs!) {
      _burstBestRttUs = rtt;
      _burstBestOffsetUs = sample.offsetUs;
    }
    if (_sampleCount >= minSamplesForSync) {
      _estimateUs = _burstBestOffsetUs!.toDouble();
      _appliedUs = _estimateUs;
    }
  }

  /// Handles a steady-state sample. [quarantined] marks an unconfirmed
  /// discontinuity candidate: it is held out of the EWMA (so one wild outlier
  /// cannot drag the estimate) but, like a gate-rejected sample, still
  /// advances slewing — local time passed regardless of sample quality.
  void _addSteadySample(
    ClockSample sample,
    int rtt, {
    bool quarantined = false,
  }) {
    // PROTOCOL.md §4 steady state: accept only if RTT ≤ gate × best RTT seen,
    // then blend with EWMA. Rejected samples still advance slewing below —
    // local time passed regardless of sample quality.
    final accepted = !quarantined && rtt <= rttGateFactor * _bestRttUs!;
    if (accepted) {
      _estimateUs = _estimateUs! + ewmaAlpha * (sample.offsetUs - _estimateUs!);
    }

    final error = _estimateUs! - _appliedUs!;
    if (error.abs() > hardResyncThresholdUs) {
      // PROTOCOL.md §4: large error ⇒ step immediately; the player layer
      // must pause/step/rejoin, signalled via [needsHardResync].
      _appliedUs = _estimateUs;
      _needsHardResync = true;
      return;
    }

    // Slew: move the applied offset toward the estimate by at most
    // maxSlewUsPerSecond × (elapsed local seconds since the previous sample),
    // elapsed time being derived from consecutive t3 values.
    final elapsedUs = _lastT3 == null
        ? 0
        : (sample.t3 - _lastT3!).clamp(0, 1 << 62);
    final maxStep = maxSlewUsPerSecond * (elapsedUs / 1e6);
    if (error.abs() <= maxStep) {
      _appliedUs = _estimateUs;
    } else {
      _appliedUs = _appliedUs! + (error.isNegative ? -maxStep : maxStep);
    }
  }

  /// Converts a host session-clock time (µs) to guest-local monotonic µs
  /// using the applied offset: `local = host - offsetUs`.
  ///
  /// Throws [StateError] while [isSynchronized] is false — before the join
  /// burst lands, and again after a clock discontinuity reset the estimator.
  int hostToLocalUs(int hostTimeUs) => hostTimeUs - _requireOffset();

  /// Converts a guest-local monotonic time (µs) to host session-clock µs
  /// using the applied offset: `host = local + offsetUs`.
  ///
  /// Throws [StateError] while [isSynchronized] is false — before the join
  /// burst lands, and again after a clock discontinuity reset the estimator.
  int localToHostUs(int localTimeUs) => localTimeUs + _requireOffset();

  int _requireOffset() {
    final applied = _appliedUs;
    if (applied == null) {
      throw StateError(
        'ClockSync is not synchronized: need at least $minSamplesForSync '
        'samples of a join burst before converting timestamps (a detected '
        'clock discontinuity restarts that burst).',
      );
    }
    return applied.round();
  }
}
