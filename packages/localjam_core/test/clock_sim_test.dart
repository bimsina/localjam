/// 60-minute virtual sessions between a host and a guest whose clocks run
/// at different rates, over modelled phone Wi-Fi (see
/// `lib/src/clock/clock_simulation.dart` and `clock_sim_scenarios.dart`).
///
/// Asserts the applied-offset error bounds the 2026-10 estimator achieves —
/// including the harsher scenarios of the 2026-10-17 adversarial review —
/// that its applied mapping never runs backwards or jumps when a sample
/// lands (outside flagged hard resyncs), that a past anchor mapped relative
/// to now is as good as the mapping at now, and — against a frozen copy of
/// the previous algorithm — that the original scenarios broke it. Fully
/// deterministic: virtual time, seeded RNG.
library;

import 'dart:math' as math;

import 'package:localjam_core/src/clock/clock_simulation.dart';
import 'package:localjam_core/src/clock/clock_sync.dart';
import 'package:test/test.dart';

import 'clock_sim_scenarios.dart';
import 'clock_sync_legacy.dart';

const _ppms = [0.0, 20.0, -20.0, 100.0, -100.0, 200.0, -200.0];
const _seeds = [1, 2];

/// Good-network scenarios: the error budget is the estimator's own.
const _goodNetwork = {
  'clean',
  'luckyEarlySample',
  'powerSaveSpikes',
  'congestion20s',
  'sleepMidRun',
};

ClockSimResult _runNew(ClockSimScenario scenario, int seed) =>
    runClockSimulation(scenario, ClockSyncSimAdapter(ClockSync()), seed: seed);

ClockSimResult _runOld(ClockSimScenario scenario, int seed) =>
    runClockSimulation(scenario, LegacyClockSync(), seed: seed);

const int _ms = 1000;

/// The mapping contract every scenario must keep: no sample moves the
/// session time reported for its own arrival, and the reported session time
/// advances between measurements (both outside flagged hard resyncs).
void _expectMonotonic(ClockSimResult r, String why) {
  expect(r.maxUpdateJumpUs, 0, reason: why);
  expect(r.backwardUpdates, 0, reason: why);
  expect(r.nonMonotonicMeasurements, 0, reason: why);
}

/// Largest per-minute |error| from minute [from] on (µs).
int _maxFromMinute(ClockSimResult r, int from) =>
    r.maxAbsErrorPerMinuteUs.skip(from).fold(0, math.max);

void main() {
  group('simulator', () {
    test('is deterministic for a seed', () {
      final scenario = clockScenarios(100)['combined']!;
      final a = _runNew(scenario, 7);
      final b = _runNew(scenario, 7);
      expect(a.errorsUs, b.errorsUs);
      expect(a.samplesDelivered, b.samplesDelivered);
    });

    test('a frozen offset drifts exactly by the configured skew', () {
      // An estimator that never updates after the burst measures the
      // simulator's clock model: 100 ppm over an hour is 360 ms.
      final r = _runNew(
        const ClockSimScenario(clockSkewPpm: 100, network: SimNetwork.lan),
        1,
      );
      expect(r.maxAbsUs, lessThan(1 * _ms), reason: r.summary());

      final frozen = runClockSimulation(
        const ClockSimScenario(clockSkewPpm: 100, network: SimNetwork.lan),
        _FrozenAfterBurst(),
      );
      expect(frozen.maxAbsUs, closeTo(360 * _ms, 2 * _ms));
    });
  });

  group('2026-10 estimator, 60-minute sessions', () {
    for (final ppm in _ppms) {
      final label = '${ppm >= 0 ? '+' : ''}${ppm.toStringAsFixed(0)} ppm';
      clockScenarios(ppm).forEach((name, scenario) {
        test('$name at $label', () {
          for (final seed in _seeds) {
            final r = _runNew(scenario, seed);
            final why = 'seed $seed: ${r.summary()}';
            expect(r.unsyncedOutsideResyncWindow, 0, reason: why);
            _expectMonotonic(r, why);
            // Player semantics: a past anchor mapped relative to now is off
            // by no more than the mapping at now.
            expect(
              r.maxPastAnchorErrorUs,
              lessThan(name == 'badJoin' ? 1.5 * _ms : 1 * _ms),
              reason: why,
            );

            if (_goodNetwork.contains(name)) {
              expect(r.p99AbsUs, lessThan(0.5 * _ms), reason: why);
              // The max is the first seconds after join, before the skew is
              // known: up to ~|ppm| × 8 s.
              final maxBound = ppm.abs() > 100 ? 2 * _ms : 1 * _ms;
              expect(r.maxAbsUs, lessThan(maxBound), reason: why);
            } else if (name == 'poisonedBurst') {
              // The whole join burst queued behind one 200 ms pong, reading
              // up to 100 ms off. A ≥ 50 ms error is re-seeded by the step
              // detector on the first two steady pings (one hard resync); a
              // smaller one is stepped away during warm-up.
              expect(r.p99AbsUs, lessThan(0.5 * _ms), reason: why);
              expect(r.hardResyncs, lessThanOrEqualTo(1), reason: why);
              expect(
                r.maxAbsErrorPerMinuteUs.skip(1).every((e) => e < 1 * _ms),
                isTrue,
                reason: why,
              );
            } else if (name == 'badJoin') {
              // A join burst on a congested, power-saving link reads a few
              // ms off; the error budget after the first minute is < 1 ms.
              expect(r.p99AbsUs, lessThan(1.5 * _ms), reason: why);
              expect(r.maxAbsUs, lessThan(6 * _ms), reason: why);
              expect(
                r.maxAbsErrorPerMinuteUs.skip(1).every((e) => e < 1.5 * _ms),
                isTrue,
                reason: why,
              );
            } else {
              // goodBadGood, combined: 20 minutes of a 10 ms-floor network
              // with heavy queueing (plus congestion and a sleep).
              expect(r.p99AbsUs, lessThan(1 * _ms), reason: why);
              expect(r.maxAbsUs, lessThan(2.5 * _ms), reason: why);
            }

            if (scenario.sleeps.isNotEmpty) {
              // Detected on the second post-wake ping, re-burst complete
              // ~6 s later: one reset, nothing else.
              expect(r.hardResyncs, 1, reason: why);
              expect(r.recoveryAfterWakeUs.single, lessThan(12000000));
            } else if (name != 'poisonedBurst') {
              expect(r.hardResyncs, 0, reason: why);
            }
          }
        });
      });
    }
  });

  group('2026-10-17 adversarial review scenarios, 60-minute sessions', () {
    for (final ppm in const [0.0, 100.0, -200.0]) {
      final label = '${ppm >= 0 ? '+' : ''}${ppm.toStringAsFixed(0)} ppm';
      adversarialScenarios(ppm).forEach((name, scenario) {
        test('$name at $label', () {
          for (final seed in _seeds) {
            final r = _runNew(scenario, seed);
            final why = 'seed $seed: ${r.summary()}';
            expect(r.unsyncedOutsideResyncWindow, 0, reason: why);
            _expectMonotonic(r, why);
            switch (name) {
              case 'heavyPowerSave' || 'pingGapHeavyPowerSave':
                // The join burst queues behind one beacon wait (up to
                // 150 ms off) and is repaired within the first minute —
                // by at most one flagged step. Steady state used to flap
                // the floor and run 15–24 ms off; now well under 2 ms.
                expect(r.hardResyncs, lessThanOrEqualTo(1), reason: why);
                expect(r.p99AbsUs, lessThan(7 * _ms), reason: why);
                expect(_maxFromMinute(r, 2), lessThan(2 * _ms), reason: why);
                expect(r.maxPastAnchorErrorUs, lessThan(2.5 * _ms));
              case 'asymmetricPath':
                // 1 ms up, 3 ms down: an NTP-style estimator cannot see it
                // and is biased by half the difference — documented in §4.
                final sorted = [...r.errorsUs]..sort();
                final median = sorted[sorted.length ~/ 2];
                expect(median, closeTo(-1000, 100), reason: why);
                expect(r.p99AbsUs, lessThan(1.5 * _ms), reason: why);
                expect(r.hardResyncs, 0, reason: why);
              case 'temperatureSwings':
                // ±20 ppm every 10 minutes, on a 10 ms-floor network.
                expect(r.p99AbsUs, lessThan(1.75 * _ms), reason: why);
                expect(_maxFromMinute(r, 2), lessThan(2 * _ms), reason: why);
                expect(r.hardResyncs, 0, reason: why);
              case 'pingGap30min' || 'pingGapsPowerSave':
                // Half an hour on the extrapolated skew, then the known
                // rate is refined rather than replaced (it used to be
                // replaced by a few noisy seconds and run up to 12 ms off).
                expect(r.p99AbsUs, lessThan(1 * _ms), reason: why);
                expect(_maxFromMinute(r, 1), lessThan(1 * _ms), reason: why);
                expect(r.maxPastAnchorErrorUs, lessThan(1 * _ms));
                expect(r.hardResyncs, 0, reason: why);
              default: // correlatedJitter, burstyCongestion, temperatureRamp
                expect(r.p99AbsUs, lessThan(1 * _ms), reason: why);
                expect(_maxFromMinute(r, 2), lessThan(1 * _ms), reason: why);
                expect(r.maxPastAnchorErrorUs, lessThan(1 * _ms));
                expect(r.hardResyncs, 0, reason: why);
            }
          }
        });
      });

      test('a 40 ppm rate change during a 30-minute ping gap at $label', () {
        for (final seed in _seeds) {
          final r = _runNew(gapWithSkewChange(ppm), seed);
          final why = 'seed $seed: ${r.summary()}';
          // ~70 ms of drift nobody could see: the first pings after the gap
          // repair it with exactly one flagged step, and the new rate is
          // learned within a minute.
          expect(r.hardResyncs, 1, reason: why);
          expect(_maxFromMinute(r, 41), lessThan(0.5 * _ms), reason: why);
          _expectMonotonic(r, why);
        }
      });
    }
  });

  group('the pre-2026-10 estimator fails the same scenarios', () {
    test('one lucky early sample froze it for the whole session', () {
      final scenario = clockScenarios(100)['luckyEarlySample']!;
      final old = _runOld(scenario, 1);
      final now = _runNew(scenario, 1);
      // 100 ppm × 60 min of frozen offset ≈ 360 ms.
      expect(old.maxAbsUs, greaterThan(300 * _ms), reason: old.summary());
      expect(now.maxAbsUs, lessThan(1 * _ms), reason: now.summary());
    });

    test('a network that got worse froze it until it recovered', () {
      final scenario = clockScenarios(20)['goodBadGood']!;
      final old = _runOld(scenario, 1);
      final now = _runNew(scenario, 1);
      // 20 ppm × 20 min of rejected samples ≈ 24 ms.
      expect(old.maxAbsUs, greaterThan(20 * _ms), reason: old.summary());
      expect(now.maxAbsUs, lessThan(1 * _ms), reason: now.summary());
    });

    test('its EWMA lagged a skewed clock by milliseconds', () {
      final scenario = clockScenarios(100)['clean']!;
      final old = _runOld(scenario, 1);
      final now = _runNew(scenario, 1);
      expect(old.p50AbsUs, greaterThan(2 * _ms), reason: old.summary());
      expect(now.p99AbsUs, lessThan(0.25 * _ms), reason: now.summary());
    });

    test('a frozen gate starved its sleep detector', () {
      // The lucky sample pins the old gate, so no post-wake sample is ever
      // accepted and the two-minute jump is never noticed.
      final scenario = clockScenarios(0)['combined']!;
      final old = _runOld(scenario, 1);
      final now = _runNew(scenario, 1);
      expect(old.maxAbsUs, greaterThan(100000 * _ms), reason: old.summary());
      expect(old.recoveryAfterWakeUs.single, scenario.settleAfterWakeUs);
      expect(now.recoveryAfterWakeUs.single, lessThan(12000000));
      expect(now.maxAbsUs, lessThan(2.5 * _ms), reason: now.summary());
    });

    test('a poisoned join burst took it over a minute of crawling', () {
      final scenario = clockScenarios(0)['poisonedBurst']!;
      final old = _runOld(scenario, 1);
      final now = _runNew(scenario, 1);
      expect(old.p99AbsUs, greaterThan(50 * _ms), reason: old.summary());
      expect(now.p99AbsUs, lessThan(0.5 * _ms), reason: now.summary());
    });
  });
}

/// Takes the join burst's min-RTT offset and never updates again.
class _FrozenAfterBurst implements ClockSimEstimator {
  final ClockSync _sync = ClockSync();
  int _samples = 0;
  int? _frozen;

  @override
  void addSample(ClockSample sample) {
    if (++_samples <= 8) _sync.addSample(sample);
    if (_samples == 8) _frozen = _sync.offsetUs;
  }

  @override
  bool get isSynchronized => _frozen != null;

  @override
  int localToHostUs(int localTimeUs) => localTimeUs + _frozen!;

  @override
  bool get needsHardResync => false;

  @override
  void acknowledgeHardResync() {}
}
