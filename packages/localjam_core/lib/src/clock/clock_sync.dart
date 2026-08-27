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
///
/// The offset convention follows [ClockSample.offsetUs]:
/// `hostTime ≈ localTime + offsetUs`.
class ClockSync {
  /// Creates an estimator. All tunables default to the PROTOCOL.md §4 values.
  ClockSync({
    this.burstSize = 8,
    this.minSamplesForSync = 4,
    this.rttGateFactor = 1.5,
    this.ewmaAlpha = 0.1,
    this.maxSlewUsPerSecond = 1000,
    this.hardResyncThresholdUs = 50000,
  })  : assert(burstSize >= 1, 'burstSize must be >= 1'),
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
        assert(
          hardResyncThresholdUs > 0,
          'hardResyncThresholdUs must be > 0',
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

  /// True once enough join-burst samples ([minSamplesForSync], or the full
  /// [burstSize]) have produced an offset estimate.
  bool get isSynchronized => _appliedUs != null;

  /// The current **applied** (slew-limited) offset estimate in µs, such that
  /// `hostTime ≈ localTime + offsetUs`. Null before [isSynchronized].
  int? get offsetUs => _appliedUs?.round();

  /// The lowest RTT (µs) seen across all samples, or null before the first
  /// sample. This is the reference for the steady-state RTT gate.
  int? get bestRttUs => _bestRttUs;

  /// True after the applied offset had to step by more than
  /// [hardResyncThresholdUs]. The player layer should pause, seek to the
  /// anchor-correct position, resume, and then call [acknowledgeHardResync].
  bool get needsHardResync => _needsHardResync;

  /// The raw (unslewed) EWMA estimate, exposed for tests/diagnostics only.
  @visibleForTesting
  double? get debugEstimateUs => _estimateUs;

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
  void addSample(ClockSample sample) {
    _sampleCount++;
    final rtt = sample.rttUs;

    // Track the best (lowest) RTT ever seen; it anchors the steady-state
    // RTT acceptance gate.
    if (_bestRttUs == null || rtt < _bestRttUs!) {
      _bestRttUs = rtt;
    }

    if (_sampleCount <= burstSize) {
      _addBurstSample(sample, rtt);
    } else {
      _addSteadySample(sample, rtt);
    }

    _lastT3 = sample.t3;
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

  void _addSteadySample(ClockSample sample, int rtt) {
    // PROTOCOL.md §4 steady state: accept only if RTT ≤ gate × best RTT seen,
    // then blend with EWMA. Rejected samples still advance slewing below —
    // local time passed regardless of sample quality.
    final accepted = rtt <= rttGateFactor * _bestRttUs!;
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
    final elapsedUs =
        _lastT3 == null ? 0 : (sample.t3 - _lastT3!).clamp(0, 1 << 62);
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
  /// Throws [StateError] before [isSynchronized].
  int hostToLocalUs(int hostTimeUs) => hostTimeUs - _requireOffset();

  /// Converts a guest-local monotonic time (µs) to host session-clock µs
  /// using the applied offset: `host = local + offsetUs`.
  ///
  /// Throws [StateError] before [isSynchronized].
  int localToHostUs(int localTimeUs) => localTimeUs + _requireOffset();

  int _requireOffset() {
    final applied = _appliedUs;
    if (applied == null) {
      throw StateError(
        'ClockSync is not synchronized yet: need at least '
        '$minSamplesForSync samples before converting timestamps.',
      );
    }
    return applied.round();
  }
}
