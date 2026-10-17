/// Deterministic host/guest clock and network simulator for exercising the
/// PROTOCOL.md §4 clock-sync estimator without devices.
///
/// Two independent monotonic clocks — the host's session clock and a guest's
/// local clock that runs fast or slow by some parts per million, drifts as
/// it warms up, and can stop (device deep sleep) — exchange `clock_ping` /
/// `clock_pong` over a modelled Wi-Fi path: per-direction delay floors,
/// lognormal queueing (optionally correlated from packet to packet), bursty
/// congestion, power-save spikes, loss, FIFO (TCP) ordering, and
/// time-varying conditions. The guest pings exactly like `JamGuestClient`
/// (an 8-ping join burst, then one ping every 2 s, none while backgrounded)
/// and feeds every completed round trip into an estimator, while the
/// simulator measures the estimator's **applied** error,
/// `localToHostUs(guestNow) - hostNow`, on a fine time grid — and checks that
/// the applied mapping never runs backwards or jumps when a sample lands.
///
/// Everything is virtual time and a seeded [math.Random]: a 60-minute session
/// runs in milliseconds and reproduces exactly for a given seed. Used by the
/// clock tests and by the CLI's `clock-sim` command; it touches no real clock
/// or socket.
library;

import 'dart:math' as math;

import 'package:meta/meta.dart';

import 'clock_sync.dart';

/// Delay model for the guest↔host path during one stretch of a simulated
/// session. All times are µs; "uplink" is guest→host (`clock_ping`),
/// "downlink" host→guest (`clock_pong`).
@immutable
class SimNetwork {
  /// Creates a delay model. Defaults describe a decent home Wi-Fi link
  /// between two phones: ~3 ms RTT floor, sub-ms queueing, no spikes.
  const SimNetwork({
    this.uplinkFloorUs = 1500,
    this.downlinkFloorUs = 1500,
    this.uplinkJitterMedianUs = 400,
    this.downlinkJitterMedianUs = 400,
    this.jitterSigma = 0.9,
    this.spikeProbability = 0,
    this.spikeMinUs = 50000,
    this.spikeMaxUs = 300000,
    this.downlinkSpikeShare = 0.7,
    this.lossProbability = 0,
    this.jitterCorrelation = 0,
    this.congestionGoodMeanUs = 0,
    this.congestionBadMeanUs = 0,
    this.congestionUplinkJitterMedianUs = 1500,
    this.congestionDownlinkJitterMedianUs = 8000,
  }) : assert(
         jitterCorrelation >= 0 && jitterCorrelation < 1,
         'jitterCorrelation must be in [0, 1)',
       );

  /// Minimum one-way delay guest→host. A difference between the two floors
  /// is a fixed path asymmetry, which no NTP-style estimator can observe: it
  /// biases every offset reading by half the difference.
  final int uplinkFloorUs;

  /// Minimum one-way delay host→guest.
  final int downlinkFloorUs;

  /// Median of the lognormal queueing delay added on top of the uplink floor.
  final int uplinkJitterMedianUs;

  /// Median of the lognormal queueing delay added on top of the downlink
  /// floor. Unequal medians model asymmetric congestion (e.g. the host's
  /// radio busy serving a media download), which biases offset readings.
  final int downlinkJitterMedianUs;

  /// Shape (σ of the underlying normal) of both lognormal queueing delays;
  /// ~1 gives the heavy right tail measured on real Wi-Fi.
  final double jitterSigma;

  /// Per-packet probability of a power-save / retransmission spike: an extra
  /// uniform [spikeMinUs, spikeMaxUs] delay on one direction (a phone in
  /// 802.11 power save only hears buffered frames at the next beacon).
  final double spikeProbability;

  /// Lower bound of a spike's extra delay.
  final int spikeMinUs;

  /// Upper bound of a spike's extra delay.
  final int spikeMaxUs;

  /// Fraction of spikes that hit the downlink (AP→phone buffering is the
  /// usual power-save culprit); the rest hit the uplink.
  final double downlinkSpikeShare;

  /// Per-round-trip probability that the ping or the pong is lost (on TCP
  /// this is really "delayed past usefulness"; the sample never arrives).
  final double lossProbability;

  /// Packet-to-packet correlation (AR(1) coefficient, in [0, 1)) of each
  /// direction's queueing: 0 draws every packet's queueing independently;
  /// 0.9 makes a slow queue stay slow for ~10 packets, so consecutive
  /// readings share their bias instead of averaging it away.
  final double jitterCorrelation;

  /// Bursty congestion (a two-state Gilbert–Elliott process): mean length
  /// of the uncongested stretches, µs. 0 disables it. Stretch lengths are
  /// exponentially distributed.
  final int congestionGoodMeanUs;

  /// Mean length of a congested stretch, µs.
  final int congestionBadMeanUs;

  /// Median uplink queueing while congested (replaces
  /// [uplinkJitterMedianUs]).
  final int congestionUplinkJitterMedianUs;

  /// Median downlink queueing while congested (replaces
  /// [downlinkJitterMedianUs]); larger than the uplink's by default — the
  /// access point's queue toward the phone is the one that backs up.
  final int congestionDownlinkJitterMedianUs;

  /// Good home Wi-Fi: 3 ms RTT floor, light queueing, rare power-save spikes.
  static const SimNetwork wifiGood = SimNetwork(
    spikeProbability: 0.02,
    lossProbability: 0.002,
  );

  /// A congested or power-saving link: 10 ms RTT floor, heavy queueing,
  /// frequent 50–300 ms spikes, a little loss.
  static const SimNetwork wifiBad = SimNetwork(
    uplinkFloorUs: 5000,
    downlinkFloorUs: 5000,
    uplinkJitterMedianUs: 3000,
    downlinkJitterMedianUs: 3000,
    jitterSigma: 1.0,
    spikeProbability: 0.12,
    lossProbability: 0.02,
  );

  /// A congestion episode with **asymmetric** queueing: the host→guest
  /// direction backs up (e.g. the host serving a media transfer), so nearly
  /// every reading is biased by several ms in the same direction.
  static const SimNetwork congestedDownlink = SimNetwork(
    uplinkJitterMedianUs: 1500,
    downlinkJitterMedianUs: 15000,
    jitterSigma: 0.7,
    spikeProbability: 0.1,
    lossProbability: 0.02,
  );

  /// Wired / very quiet LAN: sub-ms floor, tiny jitter.
  static const SimNetwork lan = SimNetwork(
    uplinkFloorUs: 250,
    downlinkFloorUs: 250,
    uplinkJitterMedianUs: 60,
    downlinkJitterMedianUs: 60,
    jitterSigma: 0.6,
  );

  /// Aggressive 802.11 power save on the guest: 90 % of pongs wait for the
  /// next DTIM beacon, 0–300 ms (uniform), on the downlink only. Only one
  /// round trip in ten is clean, so an RTT floor computed over too few of
  /// them flaps.
  static const SimNetwork powerSaveHeavy = SimNetwork(
    spikeProbability: 0.9,
    spikeMinUs: 0,
    spikeMaxUs: 300000,
    downlinkSpikeShare: 1,
    lossProbability: 0.01,
  );

  /// Good Wi-Fi with a fixed path asymmetry: 1 ms up, 3 ms down. No
  /// NTP-style estimator can see it; it biases every reading by half the
  /// difference (−1 ms here).
  static const SimNetwork asymmetricPath = SimNetwork(
    uplinkFloorUs: 1000,
    downlinkFloorUs: 3000,
    spikeProbability: 0.02,
    lossProbability: 0.002,
  );

  /// Good Wi-Fi whose queueing is strongly correlated from packet to packet
  /// (a slow queue stays slow for ~10 round trips).
  static const SimNetwork correlatedJitter = SimNetwork(
    jitterCorrelation: 0.9,
    spikeProbability: 0.02,
    lossProbability: 0.002,
  );

  /// Good Wi-Fi with bursty, downlink-heavy congestion: ~8 s congested
  /// stretches every ~40 s (8 ms median downlink queueing while congested).
  static const SimNetwork burstyCongestion = SimNetwork(
    spikeProbability: 0.02,
    lossProbability: 0.002,
    congestionGoodMeanUs: 40000000,
    congestionBadMeanUs: 8000000,
  );
}

/// A [SimNetwork] that applies from [fromUs] (inclusive) to [toUs]
/// (exclusive) of session time, overriding the scenario's base network.
@immutable
class SimNetworkPhase {
  /// Creates a phase. Later phases in a scenario's list win on overlap.
  const SimNetworkPhase(this.fromUs, this.toUs, this.network);

  /// Phase start, µs since the guest joined.
  final int fromUs;

  /// Phase end (exclusive), µs since the guest joined.
  final int toUs;

  /// Conditions during the phase.
  final SimNetwork network;
}

/// A deep-sleep interval of the guest: its monotonic clock stops at [atUs]
/// for [durationUs] (session time since join), and it sends nothing.
@immutable
class SimSleep {
  /// Creates a sleep interval.
  const SimSleep(this.atUs, this.durationUs);

  /// Sleep start, µs since the guest joined.
  final int atUs;

  /// How long the guest's clock is stopped.
  final int durationUs;
}

/// A stretch during which the guest sends no pings — the app was
/// backgrounded and its socket timers suspended, or the radio was off — while
/// its clock keeps running and playback (if any) continues. Starts at [atUs]
/// (session time since join) and lasts [durationUs].
@immutable
class SimPingGap {
  /// Creates a ping gap.
  const SimPingGap(this.atUs, this.durationUs);

  /// Gap start, µs since the guest joined.
  final int atUs;

  /// How long no pings are sent.
  final int durationUs;
}

/// A change of the guest clock's rate error at [atUs]: from then on it runs
/// [ppm] parts per million fast (negative = slow) relative to the host.
/// Models temperature drift or an OS slewing its monotonic clock. With a
/// [rampUs], the rate moves linearly from its previous value to [ppm] over
/// that long (a crystal warming up) instead of stepping.
@immutable
class SimSkewChange {
  /// Creates a rate change.
  const SimSkewChange(this.atUs, this.ppm, {this.rampUs = 0});

  /// When the new rate starts to take effect, µs since the guest joined.
  final int atUs;

  /// The guest clock's new rate error, ppm (positive = guest clock fast).
  final double ppm;

  /// How long the rate takes to get from its previous value to [ppm]
  /// (0 = a step). Changes must not overlap: the next one starts at or
  /// after `atUs + rampUs`.
  final int rampUs;
}

/// Everything that defines one simulated session.
@immutable
class ClockSimScenario {
  /// Creates a scenario; defaults are a 60-minute session on
  /// [SimNetwork.wifiGood] with perfectly matched clocks.
  const ClockSimScenario({
    this.durationUs = 3600 * 1000000,
    this.clockSkewPpm = 0,
    this.skewChanges = const [],
    this.network = SimNetwork.wifiGood,
    this.phases = const [],
    this.luckyJoinSample = false,
    this.joinSpikeUs = 0,
    this.sleeps = const [],
    this.pingGaps = const [],
    this.pingIntervalUs = 2000000,
    this.burstSize = 8,
    this.burstSpacingUs = 300,
    this.measureIntervalUs = 100000,
    this.settleAfterWakeUs = 30000000,
    this.anchorAgesUs = const [60000000, 300000000, 600000000],
  });

  /// Session length after the join burst starts.
  final int durationUs;

  /// The guest clock's initial rate error relative to the host, ppm
  /// (positive = guest clock runs fast). Two phones' crystals are each
  /// within ±20–50 ppm, so ±100 ppm relative is a realistic worst case.
  final double clockSkewPpm;

  /// Later changes of [clockSkewPpm], in time order, not overlapping.
  final List<SimSkewChange> skewChanges;

  /// Base network conditions.
  final SimNetwork network;

  /// Time-bounded overrides of [network] (bad stretches, congestion).
  final List<SimNetworkPhase> phases;

  /// Whether the first join-burst ping gets an extraordinarily fast round
  /// trip (both directions well under the path's normal floor) — the
  /// "one lucky early sample" that froze the pre-2026-10 estimator's gate.
  final bool luckyJoinSample;

  /// Extra downlink delay on the first join-burst pong (e.g. 200 ms: the
  /// guest's radio was dozing in power save when the join started). The
  /// burst's pings leave back-to-back, so on an ordered (TCP) path every
  /// later pong queues behind it and the *whole* burst reads the same
  /// biased offset.
  final int joinSpikeUs;

  /// Guest deep-sleep intervals (monotonic clock stopped).
  final List<SimSleep> sleeps;

  /// Stretches without pings while the guest's clock keeps running (app
  /// backgrounded). Their measurements count as ordinary ones: the guest is
  /// assumed to keep playing on its extrapolated offset.
  final List<SimPingGap> pingGaps;

  /// Steady-state ping period (PROTOCOL.md §4: 2 s).
  final int pingIntervalUs;

  /// Join-burst size (PROTOCOL.md §4: 8 pings).
  final int burstSize;

  /// Gap between consecutive burst pings leaving the guest (default
  /// 300 µs: `JamGuestClient` sends its burst back-to-back).
  final int burstSpacingUs;

  /// How often the applied error is measured.
  final int measureIntervalUs;

  /// Measurements from a sleep's start until this long after the wake are
  /// reported separately ([ClockSimResult.resyncWindowErrorsUs]): that is
  /// the post-discontinuity resync window, where the estimator is expected
  /// to be unsynchronized or re-converging.
  final int settleAfterWakeUs;

  /// Ages of the past host anchors the player-semantics check maps at every
  /// measurement (see [ClockSimResult.maxPastAnchorErrorUs]).
  final List<int> anchorAgesUs;
}

/// The estimator surface the simulator drives. [ClockSync] satisfies it via
/// [ClockSyncSimAdapter]; tests can plug in alternative estimators.
abstract interface class ClockSimEstimator {
  /// Feeds one completed round trip.
  void addSample(ClockSample sample);

  /// Whether [localToHostUs] may be called.
  bool get isSynchronized;

  /// Maps guest-local µs to host session-clock µs with the applied offset.
  int localToHostUs(int localTimeUs);

  /// Whether the estimator stepped its applied offset (or reset).
  bool get needsHardResync;

  /// Consumes [needsHardResync].
  void acknowledgeHardResync();
}

/// Adapts a [ClockSync] to [ClockSimEstimator].
class ClockSyncSimAdapter implements ClockSimEstimator {
  /// Wraps [sync].
  ClockSyncSimAdapter(this.sync);

  /// The wrapped estimator.
  final ClockSync sync;

  @override
  void addSample(ClockSample sample) => sync.addSample(sample);

  @override
  bool get isSynchronized => sync.isSynchronized;

  @override
  int localToHostUs(int localTimeUs) => sync.localToHostUs(localTimeUs);

  @override
  bool get needsHardResync => sync.needsHardResync;

  @override
  void acknowledgeHardResync() => sync.acknowledgeHardResync();
}

/// Outcome of one simulated session.
class ClockSimResult {
  ClockSimResult._({
    required this.errorsUs,
    required this.resyncWindowErrorsUs,
    required this.maxAbsErrorPerMinuteUs,
    required this.samplesDelivered,
    required this.samplesLost,
    required this.hardResyncs,
    required this.unsyncedMeasurements,
    required this.unsyncedOutsideResyncWindow,
    required this.recoveryAfterWakeUs,
    required this.maxUpdateJumpUs,
    required this.backwardUpdates,
    required this.nonMonotonicMeasurements,
    required this.maxPastAnchorErrorUs,
  });

  /// Signed applied errors (`localToHostUs(guestNow) - hostNow`, µs) at
  /// every measurement instant where the estimator was synchronized,
  /// excluding the post-discontinuity resync windows.
  final List<int> errorsUs;

  /// Signed applied errors measured inside post-discontinuity resync windows.
  final List<int> resyncWindowErrorsUs;

  /// Largest |error| per simulated minute (µs), resync windows included
  /// (0 for a minute with no synchronized measurement).
  final List<int> maxAbsErrorPerMinuteUs;

  /// Round trips that completed and were fed to the estimator.
  final int samplesDelivered;

  /// Round trips lost on the way.
  final int samplesLost;

  /// How many times the estimator raised [ClockSimEstimator.needsHardResync].
  final int hardResyncs;

  /// Measurement instants at which the estimator was not synchronized.
  final int unsyncedMeasurements;

  /// Of [unsyncedMeasurements], those outside the join burst and the
  /// resync windows — time the player would have been unable to play.
  final int unsyncedOutsideResyncWindow;

  /// For each [ClockSimScenario.sleeps] entry: how long after the wake the
  /// estimator became synchronized with |error| < 1 ms and stayed so for
  /// the rest of the resync window. A value of
  /// [ClockSimScenario.settleAfterWakeUs] means it never got there.
  final List<int> recoveryAfterWakeUs;

  /// Largest change (µs) that a sample's arrival made to the session time
  /// the estimator reports for that sample's own `t3` — i.e. how far the
  /// guest's idea of "now" jumped at an update. Updates that raised
  /// [ClockSimEstimator.needsHardResync] are excluded: those are the
  /// sanctioned steps the player pauses for.
  final int maxUpdateJumpUs;

  /// Updates (outside hard resyncs) after which the session time reported
  /// for the sample's `t3` was *earlier* than before it.
  final int backwardUpdates;

  /// Consecutive measurement pairs (100 ms of guest time apart, no hard
  /// resync between them) whose reported session time did not advance.
  final int nonMonotonicMeasurements;

  /// The player-semantics check: the largest error (µs, outside resync
  /// windows) of mapping a past host anchor
  /// ([ClockSimScenario.anchorAgesUs] old) to local time *relative to now*,
  /// as `AudioSyncController` does — `localNow − (localToHostUs(localNow) −
  /// anchor)` — measured as how far the native player's local-clock advance
  /// since that instant differs from the anchor's true session age. It
  /// equals the applied error at now by construction, which is the point:
  /// a past anchor is exactly as good as `localToHostUs(now)`, whatever its
  /// age (extrapolating the skew back to the anchor would be off by
  /// skew × age).
  final int maxPastAnchorErrorUs;

  late final List<int> _sortedAbs = errorsUs.map((e) => e.abs()).toList()
    ..sort();

  /// Percentile [p] in [0, 100] of |error| over [errorsUs] (nearest rank).
  int percentileAbsUs(double p) {
    if (_sortedAbs.isEmpty) return 0;
    final rank = (p / 100 * _sortedAbs.length).ceil().clamp(
      1,
      _sortedAbs.length,
    );
    return _sortedAbs[rank - 1];
  }

  /// Median |error|, µs.
  int get p50AbsUs => percentileAbsUs(50);

  /// 99th-percentile |error|, µs.
  int get p99AbsUs => percentileAbsUs(99);

  /// Largest |error| outside the resync windows, µs.
  int get maxAbsUs => _sortedAbs.isEmpty ? 0 : _sortedAbs.last;

  /// Largest |error| inside the resync windows, µs.
  int get maxAbsInResyncWindowUs =>
      resyncWindowErrorsUs.fold(0, (m, e) => math.max(m, e.abs()));

  /// One-line human summary.
  String summary() {
    final recovery = [
      for (final r in recoveryAfterWakeUs) '${(r / 1e6).toStringAsFixed(1)}s',
    ];
    return 'p50=${_ms(p50AbsUs)} p99=${_ms(p99AbsUs)} max=${_ms(maxAbsUs)} '
        '(n=${errorsUs.length}) resyncs=$hardResyncs '
        'unsynced=$unsyncedOutsideResyncWindow '
        'samples=$samplesDelivered lost=$samplesLost '
        'jump=${_ms(maxUpdateJumpUs)} back=$backwardUpdates '
        'nonMono=$nonMonotonicMeasurements'
        '${recovery.isEmpty ? '' : ' wakeRecovery=${recovery.join(',')}'}';
  }

  static String _ms(int us) => '${(us / 1000).toStringAsFixed(3)}ms';
}

/// Runs [scenario] against [estimator] with a [seed]ed random source. Pure
/// and deterministic.
///
/// [onMinute], if given, is called as each simulated minute completes with
/// the minute's index and its largest |error| (µs; 0 if the estimator was
/// never synchronized during it) — e.g. to print a live trace while the
/// caller inspects its own estimator's state.
ClockSimResult runClockSimulation(
  ClockSimScenario scenario,
  ClockSimEstimator estimator, {
  int seed = 1,
  void Function(int minute, int maxAbsErrorUs)? onMinute,
}) => _ClockSimulation(scenario, estimator, math.Random(seed), onMinute).run();

/// One stretch of the guest clock's rate error: from [fromUs] (inclusive)
/// to [toUs] (exclusive; null = forever), moving linearly from [fromPpm] to
/// [toPpm] (equal for a constant rate).
class _RatePiece {
  const _RatePiece(this.fromUs, this.toUs, this.fromPpm, this.toPpm);

  final int fromUs;
  final int? toUs;
  final double fromPpm;
  final double toPpm;

  double ppmAt(int t) => toUs == null || fromPpm == toPpm
      ? fromPpm
      : fromPpm + (toPpm - fromPpm) * (t - fromUs) / (toUs! - fromUs);
}

class _ClockSimulation {
  _ClockSimulation(this.s, this.est, this.rng, this.onMinute);

  final ClockSimScenario s;
  final ClockSimEstimator est;
  final math.Random rng;
  final void Function(int minute, int maxAbsErrorUs)? onMinute;

  // Arbitrary, different epochs: both clocks are "monotonic since boot".
  static const int _hostEpochUs = 7340000000; // host booted ~2 h ago
  static const int _guestEpochUs = 912345678901; // guest booted ~10 days ago

  /// The guest clock's rate error as a function of session time: constant
  /// pieces between [ClockSimScenario.skewChanges], linear ones over their
  /// ramps.
  late final List<_RatePiece> _rate = () {
    final pieces = <_RatePiece>[];
    var cursor = 0;
    var ppm = s.clockSkewPpm;
    for (final c in s.skewChanges) {
      if (c.atUs > cursor) pieces.add(_RatePiece(cursor, c.atUs, ppm, ppm));
      cursor = math.max(cursor, c.atUs);
      if (c.rampUs > 0) {
        pieces.add(_RatePiece(cursor, cursor + c.rampUs, ppm, c.ppm));
        cursor += c.rampUs;
      }
      ppm = c.ppm;
    }
    return pieces..add(_RatePiece(cursor, null, ppm, ppm));
  }();

  late final List<SimSleep> _sleeps = [...s.sleeps]
    ..sort((a, b) => a.atUs.compareTo(b.atUs));

  /// Guest local clock at session time [t] (µs since join), integrating the
  /// piecewise-linear rate error and stopping during sleeps.
  int guestClockAt(int t) {
    var acc = 0.0;
    for (final r in _rate) {
      if (r.fromUs >= t) break;
      final end = r.toUs == null ? t : math.min(r.toUs!, t);
      // The awake parts of [r.fromUs, end).
      var a = r.fromUs;
      for (final z in _sleeps) {
        final zEnd = z.atUs + z.durationUs;
        if (zEnd <= a) continue;
        if (z.atUs >= end) break;
        if (z.atUs > a) acc += _integrate(r, a, z.atUs);
        a = zEnd;
        if (a >= end) break;
      }
      if (a < end) acc += _integrate(r, a, end);
    }
    return _guestEpochUs + acc.round();
  }

  /// Guest µs elapsed over session interval [a, b) at rate piece [r].
  static double _integrate(_RatePiece r, int a, int b) =>
      (b - a) * (1 + 0.5 * (r.ppmAt(a) + r.ppmAt(b)) * 1e-6);

  bool asleepAt(int t) =>
      s.sleeps.any((z) => t >= z.atUs && t < z.atUs + z.durationUs);

  bool inPingGap(int t) =>
      s.pingGaps.any((g) => t >= g.atUs && t < g.atUs + g.durationUs);

  bool inResyncWindow(int t) => s.sleeps.any(
    (z) => t >= z.atUs && t < z.atUs + z.durationUs + s.settleAfterWakeUs,
  );

  SimNetwork networkAt(int t) {
    var n = s.network;
    for (final p in s.phases) {
      if (t >= p.fromUs && t < p.toUs) n = p.network;
    }
    return n;
  }

  double _gaussian() {
    // Box–Muller.
    final u1 = 1.0 - rng.nextDouble();
    final u2 = rng.nextDouble();
    return math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2);
  }

  /// AR(1) state of each direction's log-queueing ([SimNetwork
  /// .jitterCorrelation]).
  double _zUp = 0;
  double _zDown = 0;

  /// Gilbert–Elliott congestion state and when it next flips (null until
  /// the first congestion-enabled network is seen).
  bool _congested = false;
  int? _congestionFlipUs;

  /// Advances the congestion process to session time [t] under [n]. Draws
  /// random numbers only when [n] enables congestion, so scenarios without
  /// it reproduce exactly.
  void _advanceCongestion(int t, SimNetwork n) {
    if (n.congestionGoodMeanUs <= 0) {
      _congested = false;
      _congestionFlipUs = null;
      return;
    }
    int draw(int meanUs) =>
        1 + (-meanUs * math.log(1 - rng.nextDouble())).round();
    var flip = _congestionFlipUs ??= t + draw(n.congestionGoodMeanUs);
    while (t >= flip) {
      _congested = !_congested;
      flip += draw(_congested ? n.congestionBadMeanUs : n.congestionGoodMeanUs);
    }
    _congestionFlipUs = flip;
  }

  /// Lognormal queueing with median [medianUs], AR(1)-correlated per
  /// direction. With no correlation this is one independent draw (and none
  /// at all for a zero median), as before correlation was modelled.
  int _queueing(int medianUs, SimNetwork n, {required bool downlink}) {
    if (medianUs <= 0) return 0;
    final rho = n.jitterCorrelation;
    final eps = _gaussian();
    final double z;
    if (rho == 0) {
      z = eps;
    } else if (downlink) {
      z = _zDown = rho * _zDown + math.sqrt(1 - rho * rho) * eps;
    } else {
      z = _zUp = rho * _zUp + math.sqrt(1 - rho * rho) * eps;
    }
    return (medianUs * math.exp(n.jitterSigma * z)).round();
  }

  /// One-way delay for a packet sent at [t]; [downlink] selects direction.
  int delay(int t, {required bool downlink}) {
    final n = networkAt(t);
    _advanceCongestion(t, n);
    var d = downlink ? n.downlinkFloorUs : n.uplinkFloorUs;
    final median = _congested
        ? (downlink
              ? n.congestionDownlinkJitterMedianUs
              : n.congestionUplinkJitterMedianUs)
        : (downlink ? n.downlinkJitterMedianUs : n.uplinkJitterMedianUs);
    d += _queueing(median, n, downlink: downlink);
    if (n.spikeProbability > 0 && rng.nextDouble() < n.spikeProbability) {
      final onDownlink = rng.nextDouble() < n.downlinkSpikeShare;
      if (onDownlink == downlink) {
        d += n.spikeMinUs + rng.nextInt(n.spikeMaxUs - n.spikeMinUs + 1);
      }
    }
    return d;
  }

  ClockSimResult run() {
    // Ping send times (session µs since join): burst, then the steady
    // schedule, skipping sleeps and ping gaps (a sleeping or backgrounded
    // guest sends nothing; its timer fires again afterwards).
    final pings = <int>[
      for (var i = 0; i < s.burstSize; i++) i * s.burstSpacingUs,
    ];
    for (var t = s.pingIntervalUs; t < s.durationUs; t += s.pingIntervalUs) {
      if (!asleepAt(t) && !inPingGap(t)) pings.add(t);
    }

    // Compute every round trip with FIFO (TCP) ordering per direction.
    final deliveries = <(int arriveUs, ClockSample sample)>[];
    var lastHostArrive = -1;
    var lastGuestArrive = -1;
    var lost = 0;
    for (var i = 0; i < pings.length; i++) {
      final sendUs = pings[i];
      final n = networkAt(sendUs);
      final lucky = s.luckyJoinSample && i == 0;
      // The scripted first ping (lucky or spiked) is never lost.
      final scripted = i == 0 && (s.luckyJoinSample || s.joinSpikeUs > 0);
      if (!scripted &&
          n.lossProbability > 0 &&
          rng.nextDouble() < n.lossProbability) {
        lost++;
        continue;
      }
      final up = lucky ? n.uplinkFloorUs ~/ 4 : delay(sendUs, downlink: false);
      final hostArrive = math.max(sendUs + up, lastHostArrive + 20);
      lastHostArrive = hostArrive;
      final hostSend = hostArrive + 30 + rng.nextInt(200); // host processing
      final down = lucky
          ? n.downlinkFloorUs ~/ 4
          : delay(hostSend, downlink: true) + (i == 0 ? s.joinSpikeUs : 0);
      final guestArrive = math.max(hostSend + down, lastGuestArrive + 20);
      lastGuestArrive = guestArrive;
      deliveries.add((
        guestArrive,
        ClockSample(
          t0: guestClockAt(sendUs),
          t1: _hostEpochUs + hostArrive,
          t2: _hostEpochUs + hostSend,
          t3: guestClockAt(guestArrive),
        ),
      ));
    }

    final errors = <int>[];
    final windowErrors = <int>[];
    final perMinute = List<int>.filled((s.durationUs / 60000000).ceil(), 0);
    var resyncs = 0;
    var unsynced = 0;
    var unsyncedOutside = 0;
    var maxJump = 0;
    var backward = 0;
    var nonMonotonic = 0;
    var maxPastAnchor = 0;
    // Session time reported at the previous measurement; null after a hard
    // resync or while unsynchronized (no continuity is owed across those).
    int? previousHost;
    // Per sleep: the last post-wake instant (inside the resync window) at
    // which the estimator was unsynchronized or ≥ 1 ms off.
    final wakes = [for (final z in s.sleeps) z.atUs + z.durationUs];
    final lastBad = [for (final w in wakes) w - s.measureIntervalUs];
    void noteRecovery(int t, {required bool bad}) {
      if (!bad) return;
      for (var k = 0; k < wakes.length; k++) {
        if (t >= wakes[k] && t < wakes[k] + s.settleAfterWakeUs) {
          lastBad[k] = t;
        }
      }
    }

    // Interleave deliveries and measurements in session-time order.
    var di = 0;
    var reportedMinutes = 0;
    for (var t = 0; t < s.durationUs; t += s.measureIntervalUs) {
      while (onMinute != null && t >= (reportedMinutes + 1) * 60000000) {
        onMinute!(reportedMinutes, perMinute[reportedMinutes]);
        reportedMinutes++;
      }
      while (di < deliveries.length && deliveries[di].$1 <= t) {
        final sample = deliveries[di].$2;
        // The pong is handled the moment it lands, at its own t3: the
        // session time reported for that instant must not move.
        final before = est.isSynchronized ? est.localToHostUs(sample.t3) : null;
        est.addSample(sample);
        if (est.needsHardResync) {
          resyncs++;
          est.acknowledgeHardResync();
          previousHost = null;
        } else if (before != null && est.isSynchronized) {
          final jump = est.localToHostUs(sample.t3) - before;
          maxJump = math.max(maxJump, jump.abs());
          if (jump < 0) backward++;
        }
        di++;
      }
      if (asleepAt(t)) continue;
      if (!est.isSynchronized) {
        previousHost = null;
        noteRecovery(t, bad: true);
        unsynced++;
        final inBurst = t < s.burstSize * s.burstSpacingUs + 2000000;
        if (!inBurst && !inResyncWindow(t)) unsyncedOutside++;
        continue;
      }
      final localNow = guestClockAt(t);
      final hostNow = _hostEpochUs + t;
      final reported = est.localToHostUs(localNow);
      if (previousHost != null && reported <= previousHost) nonMonotonic++;
      previousHost = reported;
      final err = reported - hostNow;
      noteRecovery(t, bad: err.abs() >= 1000);
      final minute = t ~/ 60000000;
      perMinute[minute] = math.max(perMinute[minute], err.abs());
      if (inResyncWindow(t)) {
        windowErrors.add(err);
        continue;
      }
      errors.add(err);
      for (final age in s.anchorAgesUs) {
        if (age > t) continue;
        // AudioSyncController maps a past anchor relative to now; the native
        // player then advances by local µs from that local instant.
        final anchorHost = hostNow - age;
        final localAnchor = localNow - (reported - anchorHost);
        final anchorError = (localNow - localAnchor) - age;
        maxPastAnchor = math.max(maxPastAnchor, anchorError.abs());
      }
    }

    while (onMinute != null && reportedMinutes < perMinute.length) {
      onMinute!(reportedMinutes, perMinute[reportedMinutes]);
      reportedMinutes++;
    }

    return ClockSimResult._(
      errorsUs: errors,
      resyncWindowErrorsUs: windowErrors,
      maxAbsErrorPerMinuteUs: perMinute,
      samplesDelivered: deliveries.length,
      samplesLost: lost,
      hardResyncs: resyncs,
      unsyncedMeasurements: unsynced,
      unsyncedOutsideResyncWindow: unsyncedOutside,
      recoveryAfterWakeUs: [
        for (var k = 0; k < wakes.length; k++)
          math.min(
            lastBad[k] + s.measureIntervalUs - wakes[k],
            s.settleAfterWakeUs,
          ),
      ],
      maxUpdateJumpUs: maxJump,
      backwardUpdates: backward,
      nonMonotonicMeasurements: nonMonotonic,
      maxPastAnchorErrorUs: maxPastAnchor,
    );
  }
}
