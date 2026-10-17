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

import 'dart:collection';
import 'dart:math' as math;

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
  /// irrelevant at the millisecond sync target).
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

/// How the jump detector reads one steady-state sample.
enum _Verdict {
  /// Ordinary sample: in the join burst, or consistent with the estimate
  /// (within [ClockSync.hardResyncThresholdUs]). Handled by the gate/EWMA.
  normal,

  /// Provably far from the estimate but not yet confirmed: held out of the
  /// estimate until it is either confirmed by the next sample or cleared.
  candidate,

  /// Confirmed offset step inside the hard-resync band (the local clock
  /// stopped for less than [ClockSync.discontinuityThresholdUs]): re-seed
  /// the estimate and hard-resync, staying synchronized.
  step,

  /// Confirmed clock discontinuity: the estimator resets before handling
  /// the sample.
  discontinuity,
}

/// One accepted reading in the skew fit: offset [yUs] observed at guest
/// local time [xUs] (the round trip's midpoint) over a round trip of
/// [rttUs].
@immutable
class _FitPoint {
  const _FitPoint(this.xUs, this.yUs, this.rttUs);

  final int xUs;
  final int yUs;
  final int rttUs;
}

/// One `(time, µs)` entry of the RTT floor window, or of the floor's own
/// recent history.
@immutable
class _RttEntry {
  const _RttEntry(this.t3, this.rttUs);

  final int t3;
  final int rttUs;
}

/// Estimates the guest→host clock offset — and the clocks' relative rate —
/// from a stream of [ClockSample]s, implementing the guest algorithm of
/// PROTOCOL.md §4:
///
/// * **Input check**: a sample with a negative RTT, or whose clocks run
///   backwards within it (`t3 < t0`, `t2 < t1`), cannot come from a real
///   round trip; it is dropped and counted in [malformedSampleCount].
/// * **Join burst**: the first [burstSize] samples form the join burst; the
///   initial offset estimate is the offset of the sample with **minimum RTT**
///   (least queued, most symmetric). [isSynchronized] becomes true once
///   [minSamplesForSync] burst samples have arrived, so a lossy join still
///   converges before the full burst completes.
/// * **RTT gate against an aging floor**: a steady-state sample is accepted
///   only if its RTT is within [rttGateFactor] (1.5×) of the *RTT floor*: the
///   [rttFloorRank]-th lowest RTT among the samples of the last
///   [rttFloorWindowUs], allowed to rise only once it has stayed higher for
///   [rttFloorHoldUs] (see "Why the floor ages" below).
/// * **Offset and skew**: two monotonic clocks never tick at exactly the same
///   rate — phone crystals are each off by tens of ppm — so the true offset
///   is a slow ramp, not a constant. The estimate is a line,
///   `offset(t) = level + skew × (t − t_level)`. [skewPpm] is the slope of a
///   weighted least-squares fit over the accepted samples of the last
///   [skewWindowUs] (5 min), shrunk toward the previously known rate while
///   it is uncertain (see "Skew" below). The level is an EWMA ([ewmaAlpha],
///   α = 0.1) whose every update moves the line's value *at the reading's
///   own time* — as predicted along the skew — a fraction α toward the
///   reading, so the EWMA has no lag behind a drifting clock (a plain EWMA
///   lags a 100 ppm ramp by ~2 ms at the §4 ping rate). Where the line
///   pivots when the skew is revised depends on how settled the skew is:
///   while the fit is young the line is anchored at the EWMA centroid of
///   the readings' times (a converging skew's revisions then re-extrapolate
///   the averaged readings from where they were); once the fit spans half
///   its window it is anchored at the newest reading (**predict-correct**),
///   so the noise in a mature skew — or a centroid left half an hour behind
///   by a ping gap — cannot swing the line.
/// * **Quality weighting**: an accepted sample's error is bounded by half
///   its RTT excess over the floor, so both the EWMA gain and the fit weight
///   scale down with that excess (an inverse-variance weight that is 1 at
///   the floor and halves once half the excess reaches a tenth of the
///   floor); a sample at the floor blends at the full α. Until the samples
///   since the last seed (join burst or step) add up to 1/α − 1
///   floor-quality ones, the level is instead the fit's weighted centroid —
///   a growing-memory average that re-judges the seed against today's
///   floor rather than letting one burst reading dominate an EWMA for a
///   minute. During that warm-up, min-RTT selection also carries on past
///   the burst: a reading with under half the seed's RTT that proves the
///   estimate more than 1 ms off re-seeds it (a join burst that queued
///   behind one power-save delay reads tens of ms off; the first clean pong
///   says so).
/// * **Slewing — a continuous, monotonic mapping**: the raw estimate is
///   internal. The *applied* mapping — what [offsetUs], [hostToLocalUs] and
///   [localToHostUs] expose — never jumps when a sample lands: each sample
///   re-anchors it at the sample's `t3`, *at the value it already had
///   there*, sets its slope to the estimate's skew, and closes the remaining
///   gap to the estimate gradually, at [maxSlewUsPerSecond] (≤ 1 ms/s per
///   spec) on top of the skew, after which it follows the estimate exactly.
///   [localToHostUs] is therefore continuous and strictly increasing in
///   local time across sample updates, warm-up and ping gaps; the only
///   discontinuities are hard resyncs, which are flagged. While the estimate
///   is still settling — the rest of the join burst after
///   [isSynchronized] and the warm-up after a seed — the gap closes at the
///   faster [warmUpSlewUsPerSecond]: a queued burst can seed the estimate
///   tens of ms off, and 1 ms/s would leave the guest audibly off for as
///   many seconds. Conversions extrapolate along the mapping, so they stay
///   exact between pings and through long stretches of rejected samples.
///   Callers do not supply a clock: the anchor is the sample's own `t3`, so
///   feed samples as their pongs arrive, in order.
/// * **Hard resync**: if the applied-vs-estimate error exceeds
///   [hardResyncThresholdUs] (> 50 ms per spec), the applied offset steps to
///   the estimate immediately and [needsHardResync] is set; the player layer
///   should pause, step, rejoin playback position, then call
///   [acknowledgeHardResync].
/// * **Clock jumps**: samples that provably disagree with the estimate by
///   more than [hardResyncThresholdUs] are a jumped clock, not drift — see
///   below.
///
/// The offset convention follows [ClockSample.offsetUs]:
/// `hostTime ≈ localTime + offsetUs`. Like every NTP-style estimator this
/// one assumes the path is symmetric on average: a *fixed* difference
/// between the two one-way delays is invisible to it and biases every
/// reading — and so the estimate — by half that difference.
///
/// ## Why the floor ages
///
/// The gate's job is to keep queued (and therefore asymmetric) samples out
/// of the estimate: a sample's offset error is at most half its RTT excess
/// over the path's true minimum. Earlier versions gated on the all-time
/// minimum RTT, which never recovers from one lucky early sample or from the
/// network getting worse (Wi-Fi power save, a busy channel): every later
/// sample was rejected and the offset froze while the clocks kept skewing
/// apart. The floor therefore describes the *recent* path:
///
/// * it is the [rttFloorRank]-th lowest RTT (default 3rd), so one or two
///   lucky samples cannot pin it below what the path normally achieves;
/// * it only considers the last [rttFloorWindowUs] (default 60 s) of
///   samples — accepted *and* rejected — so when the network degrades for
///   good the floor rises to the new normal, while a 10–30 s congestion
///   burst is simply waited out (its samples are biased and are better
///   rejected);
/// * it falls at once but rises only after the higher value has held for
///   [rttFloorHoldUs] (default 120 s; the floor is the lowest value the
///   window produced over that time). Under aggressive power save only one
///   round trip in ten is clean, so whether a 30-sample window holds three
///   clean ones is a coin toss; a floor that rose whenever it held fewer let
///   readings delayed 10–20 ms through the gate at full weight. A network
///   that really got worse is accepted again after window + hold (3 min),
///   at a holdover cost of skew error × 3 min — tens of µs once the skew is
///   known;
/// * both windows age on *pinging* time — local time between consecutive
///   samples counts for at most 10 s — so a ping gap (an app backgrounded
///   for half an hour) ages neither: silence is no evidence that the path
///   got worse, and a new sample is always ranked against the pre-gap ones.
///
/// Rejected stretches are cheap because the applied offset keeps following
/// the fitted skew: holding over 60 s with a 1 ppm skew error costs 60 µs.
///
/// ## Skew
///
/// The slope of a few nearly collinear readings is not evidence of a rate:
/// three readings 1.8 ms apart on a 4 ms-RTT path fit a 160 ppm line as
/// well as noise. So the fitted slope is shrunk toward a reference rate in
/// proportion to its uncertainty (a Gaussian prior of ±100 ppm), and the
/// reading noise behind that uncertainty does not come from the residuals
/// alone: a pessimistic a-priori scatter of RTT/4 per reading (half the
/// ±RTT/2 bound on a reading's error) counts as one reading's worth of
/// evidence, so a handful of readings that happen to line up cannot claim
/// to be noise-free — including the three-reading fit — while a minute of
/// them speaks for itself. (A stronger prior shrinks such a fit further but
/// slows learning a real skew at join, which costs more in practice.) The
/// reference is 0 at join and the rate known before the fit last restarted
/// (a step, a warm-up re-seed or a discontinuity — the crystals did not
/// change). The fit also keeps its
/// [minFitPoints] newest readings however old they are, so after a long ping
/// gap (the app backgrounded for half an hour) the known rate is refined
/// across the gap instead of being replaced by a few seconds of fresh,
/// noisy readings.
///
/// ## Clock jumps (device sleep)
///
/// Every monotonic clock this stack can reach — Dart's `Stopwatch`,
/// `mach_absolute_time` on iOS, `System.nanoTime` on Android — **stops
/// counting while the device is in deep sleep**. A guest that sleeps for two
/// minutes mid-session wakes with a local clock two minutes behind where the
/// host's session clock expects it, so every subsequent sample reports an
/// offset that is minutes away from the converged estimate. A short suspend
/// does the same on a smaller scale.
///
/// That is not drift and must not be smoothed: crystal error is tens of ppm
/// and is tracked by the skew fit, and network asymmetry moves an accepted
/// sample's offset by at most a few ms. Feeding a jump through the EWMA
/// would crawl toward the truth at 10 % of the gap per ping while hard
/// resyncs fired repeatedly against a stale estimate. So the estimator
/// detects jumps instead of averaging them:
///
/// * A steady-state sample whose offset **provably** differs from the
///   estimate by more than [hardResyncThresholdUs] is a **jump candidate**.
///   With non-negative one-way delays the §4 arithmetic puts the true offset
///   within ±RTT/2 of a reading, so a gate-accepted sample proves its
///   disagreement minus RTT/2. A gate-rejected one still counts, by its
///   disagreement minus its whole RTT — twice that bound, which also
///   guarantees its reading is closer to the truth than the estimate it
///   contradicts. The gate therefore cannot starve detection: a guest that
///   wakes onto a much worse network still notices the jump on its first
///   two pings.
/// * [discontinuityConfirmations] consecutive mutually-consistent candidates
///   (readings that agree within [hardResyncThresholdUs] plus their RTTs)
///   are required before acting — default 2, so a single wild outlier
///   cannot destroy a good estimate. A reading that contradicts the pending
///   candidate (they cannot both be readings of one clock) clears the run;
///   one whose RTT is too large to tell either way leaves it open (for up
///   to a minute) — under heavy power save most pongs are like that, and
///   letting them clear runs kept a poisoned join from ever being fixed. A
///   candidate that disagrees with the pending one restarts the run, since
///   two unrelated outliers are not evidence of a jump.
/// * An unconfirmed candidate is **quarantined**: it is held out of the
///   estimate (the applied mapping simply carries on).
/// * A confirmed jump of at most [discontinuityThresholdUs] (default 0.5 s)
///   is a **step**: the estimate is re-seeded from the lowest-RTT reading of
///   the confirming run (the skew is kept — the crystals did not change),
///   which pushes the applied offset past the hard-resync threshold: it
///   steps once and [needsHardResync] is raised, instead of the several
///   resyncs an EWMA crawl would cause.
/// * A confirmed jump beyond [discontinuityThresholdUs] is a
///   **discontinuity**: the estimator re-enters its initial state (see
///   [needsHardResync] and [isSynchronized] below) and the confirming sample
///   becomes the first sample of a fresh join burst. The guest's existing
///   ping schedule (§4: one every 2 s) then re-converges with no transport
///   involvement: min-RTT re-selection over the new burst, a new estimate
///   seeded from it, and [isSynchronized] back to true after
///   [minSamplesForSync] post-reset samples.
///
/// The discontinuity reset clears the RTT floor, the skew fit's samples and
/// the applied mapping: the pre-sleep RTTs are not a valid gate reference if
/// the radio re-associated (or moved networks) while asleep, and the applied
/// offset must not slew from a stale value toward a target minutes away.
/// Only the skew *value* is carried over, as the starting point (and the
/// fit's reference rate) until the new fit spans [minSkewSpanUs]: the two
/// crystals are the same ones as before the sleep.
///
/// **Consumer contract.** The reset is deliberately indistinguishable from a
/// pre-first-sync estimator: [isSynchronized] goes back to false, [offsetUs]
/// to null, and [hostToLocalUs]/[localToHostUs] throw [StateError] again
/// until the fresh burst lands. [needsHardResync] is set at the same moment
/// (and is consumable via [acknowledgeHardResync] as always), so a player
/// layer that pauses on the flag and gates scheduling on [isSynchronized]
/// pauses at the jump, waits out the re-burst, and rejoins at the corrected
/// position. Note that [needsHardResync] can therefore be true while
/// [isSynchronized] is false; conversions must not be attempted until the
/// latter turns true again.
///
/// Before the first sync detection is disabled entirely: burst min-RTT
/// selection already handles arbitrary offsets, so a jump then is a
/// non-event. Once [isSynchronized] is true, a later burst sample that
/// moves the estimate by more than [hardResyncThresholdUs] steps the
/// mapping and raises [needsHardResync] like any other step: a player may
/// already have scheduled against the earlier value.
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
    this.rttFloorWindowUs = 60000000,
    this.rttFloorRank = 3,
    this.skewWindowUs = 300000000,
    this.minSkewSpanUs = 10000000,
    this.maxSkewPpm = 1000,
    this.warmUpSlewUsPerSecond = 20000,
    this.rttFloorHoldUs = 120000000,
    this.minFitPoints = 30,
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
       assert(warmUpSlewUsPerSecond > 0, 'warmUpSlewUsPerSecond must be > 0'),
       assert(hardResyncThresholdUs > 0, 'hardResyncThresholdUs must be > 0'),
       assert(
         discontinuityThresholdUs > hardResyncThresholdUs,
         'discontinuityThresholdUs must exceed hardResyncThresholdUs: '
         'jumps up to it are re-seeded in place, larger ones reset',
       ),
       assert(
         discontinuityConfirmations >= 1,
         'discontinuityConfirmations must be >= 1',
       ),
       assert(rttFloorWindowUs > 0, 'rttFloorWindowUs must be > 0'),
       assert(rttFloorHoldUs >= 0, 'rttFloorHoldUs must be >= 0'),
       assert(rttFloorRank >= 1, 'rttFloorRank must be >= 1'),
       assert(
         skewWindowUs >= minSkewSpanUs && minSkewSpanUs > 0,
         'need 0 < minSkewSpanUs <= skewWindowUs',
       ),
       assert(minFitPoints >= 0, 'minFitPoints must be >= 0'),
       assert(
         maxSkewPpm >= 0 && maxSkewPpm < 1e5,
         'maxSkewPpm must be in [0, 100000)',
       );

  /// Number of samples in the join burst (PROTOCOL.md §4: "burst of 8 pings
  /// at join"). While fewer than this many samples have been added, the
  /// estimate is the min-RTT burst sample.
  final int burstSize;

  /// Minimum burst samples before [isSynchronized] turns true (default 4).
  /// The spec's burst is 8; accepting readiness earlier lets a lossy join
  /// converge instead of stalling. The min-RTT selection keeps refining
  /// until the full burst has arrived.
  final int minSamplesForSync;

  /// Steady-state RTT gate (PROTOCOL.md §4: "accept a sample only if its RTT
  /// is within 1.5× of the RTT floor").
  final double rttGateFactor;

  /// EWMA blend factor for accepted steady-state samples (PROTOCOL.md §4:
  /// α ≈ 0.1): a floor-quality sample moves the level this fraction of the
  /// way from the line's prediction toward itself; a queued sample moves it
  /// less. Also sets the warm-up length (1/α − 1 floor-quality samples
  /// after a seed).
  final double ewmaAlpha;

  /// Maximum rate at which the applied offset slews toward the raw estimate,
  /// in µs of offset change per second of local time, on top of the skew
  /// slope (PROTOCOL.md §4: "slew it (≤ 1 ms per second)"). A rate of
  /// 1 000 000 µs/s or more cannot be continuous (the mapping would stand
  /// still or run backwards) and means "no limit": gaps then close as
  /// unflagged steps.
  final int maxSlewUsPerSecond;

  /// Slew rate (µs/s) while the estimate is still settling: the rest of
  /// the join burst once [isSynchronized] is true, and the warm-up after
  /// each seed (default 20 ms/s: a 40 ms burst error closes in 2 s rather
  /// than 40). Still continuous and monotonic; same "no limit" rule as
  /// [maxSlewUsPerSecond].
  final int warmUpSlewUsPerSecond;

  /// Applied-vs-estimate error above which the estimator steps immediately
  /// and flags [needsHardResync]
  /// (PROTOCOL.md §4: "large error (> 50 ms) ⇒ hard resync"). Also the
  /// disagreement beyond which a sample is a jump candidate.
  final int hardResyncThresholdUs;

  /// Confirmed jump size (µs) above which the estimator treats the jump as a
  /// **clock discontinuity** (device sleep stopping the monotonic clock)
  /// and resets completely, rather than re-seeding in place.
  ///
  /// Default 500 000 µs = 0.5 s: orders of magnitude beyond LAN jitter on a
  /// gate-accepted sample and beyond crystal drift, and 10× the 50 ms
  /// [hardResyncThresholdUs] band. Must be greater than
  /// [hardResyncThresholdUs].
  final int discontinuityThresholdUs;

  /// How many consecutive, mutually consistent jump candidates are required
  /// before the estimator acts (default 2). One wild outlier is never
  /// enough to discard a converged estimate; a real clock jump makes
  /// *every* subsequent sample a candidate, so the cost of confirmation is a
  /// single extra ping (2 s at the §4 steady rate). Set to 1 to act on the
  /// first candidate.
  final int discontinuityConfirmations;

  /// How far back (µs of pinging time — local time, but a ping gap counts
  /// for at most 10 s) the RTT floor's window looks (default 60 s ≈ 30
  /// steady-state pings). Longer windows ride out longer
  /// congestion episodes on skew holdover; shorter ones re-open the gate
  /// sooner after the network degrades for good.
  final int rttFloorWindowUs;

  /// Which order statistic of the window's RTTs is the floor (default 3:
  /// the third-lowest), so up to `rttFloorRank − 1` lucky samples cannot
  /// tighten the gate below what the path normally achieves. 1 = plain
  /// windowed minimum.
  final int rttFloorRank;

  /// How long (µs of pinging time) a higher floor must persist before the
  /// gate uses it (default 120 s): the floor is the lowest value the window
  /// produced over this long. Lower floors apply at once. 0 = the window's
  /// value as is.
  final int rttFloorHoldUs;

  /// How far back (µs of local time) the skew fit looks (default 5 min ≈
  /// 150 pings): long enough to average Wi-Fi asymmetry down to ~0.1 ppm,
  /// short enough to follow a crystal warming up.
  final int skewWindowUs;

  /// The skew fit keeps at least this many of its newest readings even when
  /// they are older than [skewWindowUs] (default 30 = one minute of pings),
  /// so a ping gap longer than the window refines the known rate instead of
  /// discarding it. 0 = a pure time window.
  final int minFitPoints;

  /// Minimum time span of the skew fit's samples before its slope is used
  /// (default 10 s = 5 steady-state pings); until then the skew stays at
  /// its previous value (0 before the first fit). Beyond it the slope is
  /// still shrunk toward the reference rate in proportion to its own
  /// uncertainty (class doc, "Skew"), so an early, noisy fit cannot invent
  /// a skew.
  final int minSkewSpanUs;

  /// Bound on the estimated skew magnitude, ppm (default 1000). Two phones'
  /// crystals differ by well under 100 ppm, but a Linux host's
  /// `CLOCK_MONOTONIC` is frequency-slewed by NTP — up to the kernel's
  /// ±500 ppm limit while it corrects a large offset — on top of its
  /// crystal error, so the bound sits above that rather than clipping a
  /// real rate (which would leave the estimate chasing it, ms off). Only a
  /// corrupted fit is clipped. 0 disables skew tracking: the estimate is
  /// then a level only, as before 2026-10.
  final double maxSkewPpm;

  int _sampleCount = 0;
  int _malformedSamples = 0;

  /// Steady-state samples accepted since the level was last seeded (see
  /// [acceptedSampleCount]).
  int _acceptedSinceSeed = 0;

  /// Recent `(aging time, rtt)` pairs for the aging RTT floor, oldest
  /// first (see [_recordRtt] for the aging clock).
  final ListQueue<_RttEntry> _rtts = ListQueue<_RttEntry>();

  /// Recent `(aging time, window floor)` pairs: the floor rises only once
  /// every value of the last [rttFloorHoldUs] is higher.
  final ListQueue<_RttEntry> _floors = ListQueue<_RttEntry>();

  /// Pinging time for the floor's windows, and the `t3` it last advanced
  /// at (see [_recordRtt]).
  int _agingClockUs = 0;
  int? _agingLastT3;

  /// The gate's floor as of the most recent sample.
  int? _floorUs;

  /// Offset, RTT and midpoint of the min-RTT sample of the join burst.
  int? _burstBestOffsetUs;
  int? _burstBestRttUs;
  int? _burstBestMidUs;

  /// Estimate line: `_levelUs + _skew × (t − _levelAtUs)`. During warm-up
  /// it passes through the fit's weighted centroid; afterwards it is
  /// anchored at the EWMA centroid of the readings' times while the fit is
  /// young, and at the newest accepted reading's time once it is mature.
  /// Non-null once synchronized.
  double? _levelUs;
  double _levelAtUs = 0;

  /// Accumulated [_quality] of the readings accepted since the level was
  /// last seeded; below `1 / ewmaAlpha − 1` the level is still warming up.
  double _warmWeight = 0;

  /// RTT of the reading the level was last seeded from.
  int _seedRttUs = 0;

  /// How far a much lower-RTT warm-up reading must prove the estimate off
  /// before it re-seeds it (µs): the millisecond sync target.
  static const int _reseedMarginUs = 1000;

  /// Relative rate (µs of offset per µs of local time) from the skew fit.
  double _skew = 0;

  /// The rate a young fit is shrunk toward: 0 at join, the rate known when
  /// the fit last restarted (step, warm-up re-seed, discontinuity).
  double _skewPrior = 0;

  /// Accepted readings for the skew fit, oldest first.
  final ListQueue<_FitPoint> _fit = ListQueue<_FitPoint>();

  /// Applied mapping, re-anchored at every sample: from `_appliedAtUs` the
  /// offset is `_appliedUs + _appliedSkew × (t − _appliedAtUs)` plus the
  /// part of `_slewUs` closed so far at `_slewRate` (µs per µs) — all of it
  /// once `|_slewUs| / _slewRate` has elapsed. `_appliedUs` is non-null once
  /// synchronized.
  double? _appliedUs;
  int _appliedAtUs = 0;
  double _appliedSkew = 0;
  double _slewUs = 0;
  double _slewRate = 0;

  /// `t3` of the most recent sample.
  int? _lastT3;

  bool _needsHardResync = false;

  /// The current run of jump candidates: the first one's offset, RTT and
  /// midpoint (the consistency reference), the lowest-RTT one's offset and
  /// midpoint (the re-seed value for a step), and the run length. Cleared
  /// by a sample that contradicts the first candidate, after
  /// [_pendingLifetimeUs], and by the reset.
  int? _pendingOffsetUs;
  int _pendingRttUs = 0;
  int _pendingMidUs = 0;
  int _pendingBestOffsetUs = 0;
  int _pendingBestRttUs = 0;
  int _pendingBestMidUs = 0;
  int _pendingCount = 0;

  /// True once enough join-burst samples ([minSamplesForSync], or the full
  /// [burstSize]) have produced an offset estimate.
  ///
  /// Returns to false if a clock discontinuity is detected (device sleep —
  /// see the class doc), until the post-reset join burst re-converges.
  bool get isSynchronized => _appliedUs != null;

  /// The **applied** offset in µs, such that `hostTime ≈ localTime +
  /// offsetUs`, at the most recent sample's `t3` — the instant the mapping
  /// was last re-anchored, so this is the value it already had there; any
  /// remaining gap to the estimate closes after it. Null before
  /// [isSynchronized]. [localToHostUs] and [hostToLocalUs] give the mapping
  /// at any other instant.
  int? get offsetUs => _appliedUs?.round();

  /// The lowest RTT (µs) among the samples in the RTT floor window
  /// ([rttFloorWindowUs]), or null before the first sample. Diagnostic; the
  /// gate itself uses [rttFloorUs].
  int? get bestRttUs =>
      _rtts.isEmpty ? null : _rtts.map((e) => e.rttUs).reduce(math.min);

  /// The steady-state gate's reference as of the most recent sample: the
  /// [rttFloorRank]-th lowest RTT (µs) in the floor window (the lowest while
  /// the window holds fewer samples), held at its lowest value of the last
  /// [rttFloorHoldUs]; null before the first sample. A sample is accepted
  /// when its RTT is at most [rttGateFactor] × this.
  int? get rttFloorUs => _floorUs;

  /// Estimated rate of the host's session clock relative to this device's
  /// monotonic clock, in parts per million (positive = the host clock runs
  /// fast). 0 until the skew fit spans [minSkewSpanUs], and always 0 when
  /// [maxSkewPpm] is 0. Diagnostic: two phones typically read within
  /// ±100 ppm.
  double get skewPpm => _skew * 1e6;

  /// How many samples [addSample] dropped as malformed (negative RTT, or
  /// `t3 < t0` / `t2 < t1`). Diagnostic: nonzero means a transport or
  /// clock bug, not a bad network.
  int get malformedSampleCount => _malformedSamples;

  /// How many steady-state samples the estimate has **accepted** since it
  /// was last seeded: each one passed the RTT gate, was not a jump candidate,
  /// and was blended into the estimate. It is the evidence that the current
  /// estimate agrees with the clock as it runs *now* — a guest that suspects
  /// its mapping (it just woke from a device sleep) can trust it again once
  /// a few readings taken after the suspicion have been accepted, since a
  /// real jump would have made them candidates instead.
  ///
  /// Reset to 0 whenever the estimate is re-seeded from scratch: by a clock
  /// discontinuity (the estimator resets), by a confirmed step under
  /// [discontinuityThresholdUs] (the estimate restarts from the step's
  /// reading — earlier readings no longer lie on it), by a warm-up re-seed
  /// from a much lower-RTT reading, and by each join-burst sample from
  /// [minSamplesForSync] on. Join-burst samples are never counted (they are
  /// min-RTT-selected, not gated), nor is the reading a seed came from.
  /// Gate-rejected, quarantined and malformed samples are not counted and
  /// do not reset it.
  int get acceptedSampleCount => _acceptedSinceSeed;

  /// True after the applied offset had to step by more than
  /// [hardResyncThresholdUs], **or** after a clock discontinuity reset the
  /// estimator. The player layer should pause, seek to the anchor-correct
  /// position, resume, and then call [acknowledgeHardResync].
  ///
  /// After a discontinuity this is set while [isSynchronized] is false: the
  /// player must pause and wait for the fresh join burst before it can map
  /// session time to local time again.
  bool get needsHardResync => _needsHardResync;

  /// The raw (unslewed) estimate at the most recent sample's `t3`, exposed
  /// for tests/diagnostics only.
  @visibleForTesting
  double? get debugEstimateUs {
    final last = _lastT3;
    return _levelUs == null || last == null ? _levelUs : _estimateAt(last);
  }

  /// How many consistent jump candidates are currently pending
  /// confirmation, for tests/diagnostics only. Reaches
  /// [discontinuityConfirmations] only transiently — acting on the jump
  /// clears it.
  @visibleForTesting
  int get debugPendingDiscontinuityCount => _pendingCount;

  /// Clears the [needsHardResync] flag after the player layer has handled it.
  void acknowledgeHardResync() {
    _needsHardResync = false;
  }

  /// Feeds one measurement into the estimator.
  ///
  /// Samples must be added in the order they were taken, as their pongs
  /// arrive: the applied mapping is re-anchored at each sample's
  /// [ClockSample.t3] (a `t3` earlier than the previous one is treated as
  /// the previous one). Malformed samples are dropped (see
  /// [malformedSampleCount]).
  ///
  /// If this sample confirms a clock discontinuity (see the class doc) the
  /// estimator resets first and this sample opens the new join burst, so the
  /// call can leave [isSynchronized] false and [needsHardResync] true.
  void addSample(ClockSample sample) {
    final rtt = sample.rttUs;
    if (rtt < 0 || sample.t3 < sample.t0 || sample.t2 < sample.t1) {
      // Not a round trip any pair of running clocks can produce: trusting
      // it would let a negative RTT win the burst and pin the floor.
      _malformedSamples++;
      return;
    }
    // The reading's offset describes the round trip's midpoint.
    final midUs = sample.t0 + (sample.t3 - sample.t0) ~/ 2;

    var floor = _recordRtt(sample.t3, rtt);
    final passesGate = rtt <= rttGateFactor * floor;

    final verdict = _classify(sample, rtt, midUs, passesGate: passesGate);
    var reseeded = false;
    switch (verdict) {
      case _Verdict.discontinuity:
        // A confirmed clock jump (device sleep) invalidates every piece of
        // accumulated state, including the RTT floor and the applied
        // mapping; the triggering sample then becomes burst sample #1 of
        // the recovery.
        _resetForDiscontinuity();
        floor = _recordRtt(sample.t3, rtt);
      case _Verdict.step:
        _reseed(_pendingBestOffsetUs, _pendingBestMidUs, _pendingBestRttUs);
      case _Verdict.normal || _Verdict.candidate:
        if (_isBetterSeed(sample, rtt, midUs)) {
          _reseed(sample.offsetUs, midUs, rtt);
          reseeded = true;
        }
    }

    _sampleCount++;
    if (_sampleCount <= burstSize) {
      _addBurstSample(sample, rtt, midUs);
    } else if (reseeded) {
      _reanchorApplied(sample.t3, settling: true);
    } else {
      _addSteadySample(
        sample,
        rtt,
        midUs,
        accepted: verdict == _Verdict.normal && passesGate,
        floorUs: floor,
      );
    }

    _lastT3 = sample.t3;
  }

  /// Whether a steady-state reading should replace the seed: the level is
  /// still warming up, the reading's RTT is under half the seed's, and it
  /// proves the estimate more than [_reseedMarginUs] off. The seed was then
  /// a queued reading (a join burst that waited behind one power-save delay
  /// reads tens of ms off) and this one bounds the truth far more tightly:
  /// min-RTT selection carries on past the burst. A merely lucky reading
  /// that agrees with the estimate leaves the warm-up — and the young skew
  /// fit — alone.
  bool _isBetterSeed(ClockSample sample, int rtt, int midUs) =>
      _sampleCount >= burstSize &&
      _warmingUp &&
      rtt * 2 < _seedRttUs &&
      (sample.offsetUs - _estimateAt(midUs)).abs() - rtt / 2 > _reseedMarginUs;

  /// Drops floor-window entries older than [rttFloorWindowUs] — but never
  /// below the [rttFloorRank] most recent, so the new sample is always
  /// ranked against that many predecessors — adds `(t3, rtt)`, and returns
  /// the gate's floor: the lowest window floor of the last [rttFloorHoldUs].
  ///
  /// Both windows age on *pinging* time: the local time between consecutive
  /// samples counts up to [_maxAgingStepUs], so a ping gap (an app in the
  /// background for half an hour) ages neither. Silence is not evidence
  /// that the path got worse; after it the pre-gap floor stands until the
  /// post-gap samples have shown otherwise for window + hold.
  int _recordRtt(int t3, int rtt) {
    final last = _agingLastT3;
    if (last != null) {
      _agingClockUs += (t3 - last).clamp(0, _maxAgingStepUs);
    }
    _agingLastT3 = t3;
    final now = _agingClockUs;

    while (_rtts.length > rttFloorRank &&
        _rtts.first.t3 < now - rttFloorWindowUs) {
      _rtts.removeFirst();
    }
    _rtts.addLast(_RttEntry(now, rtt));
    final sorted = [for (final e in _rtts) e.rttUs]..sort();
    final windowFloor = sorted[math.min(rttFloorRank, sorted.length) - 1];

    // Only a full window's floor is held: while the window is still filling
    // (join, reset) its "floor" is just its lowest RTT — one lucky sample —
    // and holding that would shut the gate for a minute.
    if (_rtts.length < rttFloorRank) return _floorUs = windowFloor;
    while (_floors.isNotEmpty && _floors.first.t3 < now - rttFloorHoldUs) {
      _floors.removeFirst();
    }
    _floors.addLast(_RttEntry(now, windowFloor));
    return _floorUs = _floors.map((e) => e.rttUs).reduce(math.min);
  }

  /// Longest stretch of local time between two samples that counts toward
  /// the RTT floor's aging (a few missed pings' worth).
  static const int _maxAgingStepUs = 10000000;

  /// The raw estimate line evaluated at local time [tUs].
  double _estimateAt(int tUs) => _levelUs! + _skew * (tUs - _levelAtUs);

  /// The applied mapping's offset at local time [tUs].
  double _appliedAt(int tUs) {
    final dt = tUs - _appliedAtUs;
    var offset = _appliedUs! + _appliedSkew * dt;
    if (dt > 0 && _slewUs != 0) {
      final closed = _slewRate * dt;
      offset += closed >= _slewUs.abs()
          ? _slewUs
          : (_slewUs < 0 ? -closed : closed);
    }
    return offset;
  }

  /// Classifies [sample] for jump detection, updating the pending candidate
  /// run as a side effect. See "Clock jumps" in the class doc.
  ///
  /// During the join burst arbitrary offsets are expected (min-RTT selection
  /// handles them). Disagreement is measured against the *raw* estimate
  /// rather than the slewed applied offset, so a jump cannot be triggered by
  /// slew lag.
  _Verdict _classify(
    ClockSample sample,
    int rtt,
    int midUs, {
    required bool passesGate,
  }) {
    // `_sampleCount` samples have been added already, so this one is
    // steady-state only if it lands past the burst.
    if (_levelUs == null || _sampleCount < burstSize) return _Verdict.normal;

    final offset = sample.offsetUs;
    final disagreement = (offset - _estimateAt(midUs)).abs();
    // §4 arithmetic with non-negative one-way delays bounds a reading's
    // error by RTT/2: that much of the disagreement may be the reading's
    // own. A gate-rejected sample must prove twice that, which also
    // guarantees its reading is closer to the truth than the estimate it
    // contradicts.
    final proven = passesGate ? disagreement - rtt / 2 : disagreement - rtt;

    final pending = _pendingOffsetUs;
    // Evidence a minute apart is not a run.
    final stale = pending != null && midUs - _pendingMidUs > _pendingLifetimeUs;
    // The pending reading carried forward along the skew to this one.
    final expected = pending == null
        ? 0.0
        : pending + _skew * (midUs - _pendingMidUs);

    if (proven <= hardResyncThresholdUs) {
      // Ordinary error: drift, jitter, or a queued reading. It ends a
      // pending run only if it contradicts the candidate — the two cannot
      // both be readings of one clock. A reading whose RTT allows either is
      // no evidence either way: under heavy power save most pongs are
      // delayed so much that they "agree" with any estimate, and letting
      // them clear the run kept a good reading from ever confirming that a
      // poisoned join burst was 50+ ms off.
      if (pending != null &&
          (stale || (offset - expected).abs() > (rtt + _pendingRttUs) / 2)) {
        _clearPending();
      }
      return _Verdict.normal;
    }

    if (pending == null ||
        stale ||
        (offset - expected).abs() >
            hardResyncThresholdUs + (rtt + _pendingRttUs) / 2) {
      // First candidate, or one that cannot describe the same clock as the
      // pending one — unrelated outliers, not a jump. Start a new run.
      _pendingOffsetUs = offset;
      _pendingRttUs = rtt;
      _pendingMidUs = midUs;
      _pendingBestOffsetUs = offset;
      _pendingBestRttUs = rtt;
      _pendingBestMidUs = midUs;
      _pendingCount = 1;
    } else {
      _pendingCount++;
      if (rtt < _pendingBestRttUs) {
        _pendingBestOffsetUs = offset;
        _pendingBestRttUs = rtt;
        _pendingBestMidUs = midUs;
      }
    }
    if (_pendingCount < discontinuityConfirmations) return _Verdict.candidate;
    final jump = (_pendingBestOffsetUs - _estimateAt(_pendingBestMidUs)).abs();
    return jump > discontinuityThresholdUs
        ? _Verdict.discontinuity
        : _Verdict.step;
  }

  /// How long (µs of local time) a pending candidate run stays open while
  /// only inconclusive readings arrive.
  static const int _pendingLifetimeUs = 60000000;

  void _clearPending() {
    _pendingOffsetUs = null;
    _pendingCount = 0;
  }

  /// Re-enters the pre-first-sync state after a confirmed clock jump, and
  /// raises [needsHardResync] so the player layer pauses until the fresh
  /// join burst has re-converged. The skew value survives (class doc).
  void _resetForDiscontinuity() {
    _sampleCount = 0;
    _acceptedSinceSeed = 0;
    _rtts.clear();
    _floors.clear();
    _agingLastT3 = null;
    _floorUs = null;
    _burstBestOffsetUs = null;
    _burstBestRttUs = null;
    _burstBestMidUs = null;
    _levelUs = null;
    _fit.clear();
    _skewPrior = _skew;
    _appliedUs = null;
    _slewUs = 0;
    _lastT3 = null;
    _clearPending();
    _needsHardResync = true;
  }

  /// Moves the estimate onto one reading: the confirmed post-step offset,
  /// or a warm-up reading far better than the seed. The earlier readings no
  /// longer lie on the new line (a step) or are worth nothing beside it, so
  /// the skew fit restarts (the skew value itself is kept, and is what the
  /// new fit is shrunk toward). The applied mapping then follows via
  /// [_reanchorApplied] — stepping, flagged, if it is off by more than
  /// [hardResyncThresholdUs].
  void _reseed(int offsetUs, int midUs, int rttUs) {
    _seedLevel(offsetUs, midUs, rttUs);
    _skewPrior = _skew;
    _fit
      ..clear()
      ..addLast(_FitPoint(midUs, offsetUs, rttUs));
    _clearPending();
  }

  void _addBurstSample(ClockSample sample, int rtt, int midUs) {
    // PROTOCOL.md §4: keep the burst sample with minimum RTT as the initial
    // offset.
    if (_burstBestRttUs == null || rtt < _burstBestRttUs!) {
      _burstBestRttUs = rtt;
      _burstBestOffsetUs = sample.offsetUs;
      _burstBestMidUs = midUs;
      // Only the burst's best reading seeds the fit: back-to-back burst
      // pings queue behind each other, so the rest carry no independent
      // information (and one spike can delay them all equally, making
      // them look like a floor).
      _fit
        ..clear()
        ..addLast(_FitPoint(midUs, sample.offsetUs, rtt));
    }
    if (_sampleCount < minSamplesForSync) return;
    _seedLevel(_burstBestOffsetUs!, _burstBestMidUs!, _burstBestRttUs!);
    if (_appliedUs == null) {
      // First sync: nothing has been mapped yet, so start on the estimate.
      _appliedUs = _estimateAt(sample.t3);
      _appliedAtUs = sample.t3;
      _appliedSkew = _skew;
      _slewUs = 0;
    } else {
      // A player may already have scheduled against the mapping: refine it
      // continuously (a large refinement steps, flagged).
      _reanchorApplied(sample.t3, settling: true);
    }
  }

  /// Restarts the level from a single reading (join burst, re-seed).
  void _seedLevel(int offsetUs, int midUs, int rttUs) {
    _levelUs = offsetUs.toDouble();
    _levelAtUs = midUs.toDouble();
    _seedRttUs = rttUs;
    _warmWeight = 0;
    _acceptedSinceSeed = 0;
  }

  /// Whether the level is still warming up after its last seed.
  bool get _warmingUp => _warmWeight < 1 / ewmaAlpha - 1;

  /// Handles a steady-state sample. Only [accepted] samples (gate passed,
  /// not a jump candidate) touch the estimate; every sample re-anchors the
  /// applied mapping onto it.
  void _addSteadySample(
    ClockSample sample,
    int rtt,
    int midUs, {
    required bool accepted,
    required int floorUs,
  }) {
    final warmingUp = _warmingUp;
    if (accepted) {
      _fit.addLast(_FitPoint(midUs, sample.offsetUs, rtt));
      while (_fit.length > minFitPoints &&
          _fit.first.xUs < midUs - skewWindowUs) {
        _fit.removeFirst();
      }
      final centroid = _refit(floorUs);
      final quality = _quality(rtt, floorUs);
      if (warmingUp && centroid != null) {
        // Warm-up: until the readings since the seed are worth 1/α − 1
        // floor-quality ones (the seed being the first of the EWMA's 1/α),
        // an EWMA would still be dominated by its seed — a single burst
        // reading whose quality was judged against a floor the burst itself
        // set. The fit's weighted centroid re-judges every reading against
        // today's floor instead. (α = 1 has no warm-up.)
        _levelAtUs = centroid.$1;
        _levelUs = centroid.$2;
      } else if (_fit.last.xUs - _fit.first.xUs < skewWindowUs ~/ 2) {
        // PROTOCOL.md §4 steady state: blend with EWMA, at a gain scaled by
        // the reading's quality. While the skew is still being learned,
        // average the readings' times alongside their offsets: the line
        // then pivots around the centroid of what was averaged, so each
        // (systematic) revision of a converging skew re-extrapolates the
        // readings from where they were and the level carries no lag.
        final gain = ewmaAlpha * quality;
        _levelUs = _levelUs! + gain * (sample.offsetUs - _levelUs!);
        _levelAtUs += gain * (midUs - _levelAtUs);
      } else {
        // Once the fit spans half its window the skew's revisions are
        // noise: predict-correct at the reading's own time instead, so the
        // line is anchored at the newest reading and such revisions — or a
        // centroid left half an hour behind by a ping gap — cannot swing
        // it. (Both updates give the line the same value at the reading.)
        final predicted = _estimateAt(midUs);
        final gain = ewmaAlpha * quality;
        _levelUs = predicted + gain * (sample.offsetUs - predicted);
        _levelAtUs = midUs.toDouble();
      }
      _warmWeight += quality;
      _acceptedSinceSeed++;
    }
    _reanchorApplied(sample.t3, settling: warmingUp);
  }

  /// Re-anchors the applied mapping at local time [t3] (or the previous
  /// anchor, if later) at the value it has there, aims it at the estimate
  /// and closes the gap at the slew rate — [warmUpSlewUsPerSecond] while
  /// [settling], else [maxSlewUsPerSecond]. A gap beyond
  /// [hardResyncThresholdUs] steps instead and flags [needsHardResync]
  /// (PROTOCOL.md §4: "large error (> 50 ms) ⇒ hard resync").
  void _reanchorApplied(int t3, {required bool settling}) {
    final at = math.max(t3, _appliedAtUs);
    final current = _appliedAt(at);
    final target = _estimateAt(at);
    final error = target - current;
    final rate = (settling ? warmUpSlewUsPerSecond : maxSlewUsPerSecond) / 1e6;
    _appliedAtUs = at;
    _appliedSkew = _skew;
    if (error.abs() > hardResyncThresholdUs || rate >= 1) {
      // The player layer must pause/step/rejoin, signalled via
      // [needsHardResync]; an unlimited slew rate is a plain step.
      _appliedUs = target;
      _slewUs = 0;
      if (error.abs() > hardResyncThresholdUs) _needsHardResync = true;
      return;
    }
    _appliedUs = current;
    _slewUs = error;
    _slewRate = rate;
  }

  /// Relative quality in (0, 1] of a reading with round trip [rtt] against
  /// the gate's [floorUs]: 1 at the floor, falling off as the RTT excess —
  /// whose half bounds the reading's error — grows past a tenth of the
  /// floor (at least 200 µs). An inverse-variance weight, normalized so
  /// that floor-quality readings blend at the full [ewmaAlpha].
  static double _quality(int rtt, int floorUs) {
    final excess = math.max(0, rtt - floorUs) / 2;
    final scale = math.max(200, floorUs / 10);
    return 1 / (1 + (excess / scale) * (excess / scale));
  }

  /// A-priori scatter (µs, one standard deviation) of a reading with round
  /// trip [rttUs]: a quarter of the RTT, i.e. half the ±RTT/2 bound the §4
  /// arithmetic puts on its error — a pessimistic value (gate-accepted
  /// Wi-Fi readings scatter by 5–10 % of their RTT).
  static double _readingSigmaUs(int rttUs) => rttUs / 4;

  /// How many readings' worth of evidence the a-priori scatter carries in
  /// the fit's noise estimate: it dominates a three- or four-reading fit
  /// and is negligible against a minute of readings.
  static const double _noisePriorReadings = 1;

  /// Weighted least-squares fit of offset over local time across the fit
  /// window. Each reading is weighted by its [_quality] against the
  /// *current* [floorUs], so readings taken while the path was worse count
  /// for less once it improves. Updates [_skew] once the window spans
  /// [minSkewSpanUs] with at least three readings, and returns the weighted
  /// centroid `(time, offset)` the fitted line passes through (null for an
  /// empty fit).
  (double, double)? _refit(int floorUs) {
    if (_fit.isEmpty) return null;
    double weight(_FitPoint p) => _quality(p.rttUs, floorUs);

    // Centre on the first point: raw µs values are ~1e12 and would lose
    // precision in the sums of squares.
    final x0 = _fit.first.xUs;
    final y0 = _fit.first.yUs;
    var sw = 0.0, sx = 0.0, sy = 0.0;
    for (final p in _fit) {
      final w = weight(p);
      sw += w;
      sx += w * (p.xUs - x0);
      sy += w * (p.yUs - y0);
    }
    final mx = sx / sw, my = sy / sw;
    final centroid = (x0 + mx, y0 + my);
    if (maxSkewPpm == 0 ||
        _fit.length < 3 ||
        _fit.last.xUs - _fit.first.xUs < minSkewSpanUs) {
      return centroid;
    }
    var sxx = 0.0, sxy = 0.0, sigma2 = 0.0;
    for (final p in _fit) {
      final w = weight(p);
      final dx = (p.xUs - x0) - mx;
      final sigma = _readingSigmaUs(p.rttUs);
      sxx += w * dx * dx;
      sxy += w * dx * ((p.yUs - y0) - my);
      sigma2 += w * sigma * sigma;
    }
    if (sxx <= 0) return centroid;
    final fitted = sxy / sxx;
    // Shrink a poorly determined slope toward the reference rate (a
    // Gaussian prior of ±_skewPriorPpm around it): a short or noisy fit —
    // the first seconds after join, after a step, or a join on a bad
    // network — must not invent a skew that then extrapolates. The
    // readings' noise is estimated from the residuals *and* an a-priori
    // value worth _noisePriorReadings readings, so that three or four
    // readings that happen to line up cannot claim to be noise-free (class
    // doc, "Skew"). Once the window spans minutes the residuals dominate,
    // the slope's variance is tiny and the factor is ~1.
    var srr = 0.0;
    for (final p in _fit) {
      final r = ((p.yUs - y0) - my) - fitted * ((p.xUs - x0) - mx);
      srr += weight(p) * r * r;
    }
    final noiseVariance =
        (_noisePriorReadings * sigma2 / sw + srr) /
        (_noisePriorReadings + _fit.length - 2);
    final slopeVariance = noiseVariance / sxx;
    const prior = _skewPriorPpm * 1e-6 * _skewPriorPpm * 1e-6;
    final slope =
        _skewPrior + (fitted - _skewPrior) * (prior / (prior + slopeVariance));
    final limit = maxSkewPpm * 1e-6;
    _skew = slope.clamp(-limit, limit);
    return centroid;
  }

  /// Scale of the skew prior, ppm: two phones' crystals typically differ by
  /// well under this, so a fitted slope is only trusted to the extent its
  /// own uncertainty is smaller.
  static const double _skewPriorPpm = 100;

  /// Converts a host session-clock time (µs) to guest-local monotonic µs
  /// using the applied mapping: the `local` with
  /// `local + offset(local) = host`. Exactly inverts [localToHostUs] up to
  /// rounding (±1 µs).
  ///
  /// Throws [StateError] while [isSynchronized] is false — before the join
  /// burst lands, and again after a clock discontinuity reset the estimator.
  int hostToLocalUs(int hostTimeUs) {
    _requireSynchronized();
    // host(t) = t + applied(t) is piecewise linear: slope 1 + skew before
    // the anchor and once the slew has closed the gap, 1 + skew ± slew rate
    // in between — positive whenever |skew| + slew rate < 1 (by default
    // 0.1 % + 2 %), so the inverse is unique.
    final anchorHost = _appliedAtUs + _appliedUs!;
    final excess = hostTimeUs - anchorHost;
    final unslewed = 1 + _appliedSkew;
    if (_slewUs == 0 || excess <= 0) {
      return (_appliedAtUs + excess / unslewed).round();
    }
    final slewSpanUs = _slewUs.abs() / _slewRate;
    final slewing = unslewed + (_slewUs < 0 ? -_slewRate : _slewRate);
    final slewSpanHost = slewSpanUs * slewing;
    if (excess <= slewSpanHost) {
      return (_appliedAtUs + excess / slewing).round();
    }
    return (_appliedAtUs + slewSpanUs + (excess - slewSpanHost) / unslewed)
        .round();
  }

  /// Converts a guest-local monotonic time (µs) to host session-clock µs
  /// using the applied mapping: `host = local + offset(local)`. Continuous
  /// and non-decreasing in [localTimeUs], including across [addSample]
  /// calls (only a flagged hard resync or a reset moves it otherwise), so
  /// `localToHostUs(now)` — the session time *now* — never runs backwards.
  ///
  /// Throws [StateError] while [isSynchronized] is false — before the join
  /// burst lands, and again after a clock discontinuity reset the estimator.
  int localToHostUs(int localTimeUs) {
    _requireSynchronized();
    return (localTimeUs + _appliedAt(localTimeUs)).round();
  }

  void _requireSynchronized() {
    if (_appliedUs == null) {
      throw StateError(
        'ClockSync is not synchronized: need at least $minSamplesForSync '
        'samples of a join burst before converting timestamps (a detected '
        'clock discontinuity restarts that burst).',
      );
    }
  }
}
