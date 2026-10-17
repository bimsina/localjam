import 'dart:math' as math;

import 'package:localjam_core/src/clock/clock_sync.dart';
import 'package:test/test.dart';

/// Builds a symmetric-path sample with an exact true [offsetUs] and [rttUs]
/// (use even [rttUs] so both one-way delays are integral and the computed
/// offset is exact).
ClockSample sampleAt({
  required int t0,
  required int offsetUs,
  required int rttUs,
  int procUs = 0,
}) {
  final oneWay = rttUs ~/ 2;
  final t1 = t0 + oneWay + offsetUs;
  final t2 = t1 + procUs;
  final t3 = t0 + rttUs + procUs;
  return ClockSample(t0: t0, t1: t1, t2: t2, t3: t3);
}

/// Deterministic sample feeder: consecutive samples' t3 values are exactly
/// [spacingUs] apart, which is what ClockSync derives elapsed time from.
class Feeder {
  Feeder(this.sync, {this.spacingUs = 1000000});

  final ClockSync sync;
  final int spacingUs;
  int _t3 = 10000000;

  /// The local time (µs) the next sample's pong will arrive at.
  int get nextT3 => _t3;

  void feed({required int offsetUs, required int rttUs, int procUs = 0}) {
    sync.addSample(
      sampleAt(
        t0: _t3 - rttUs - procUs,
        offsetUs: offsetUs,
        rttUs: rttUs,
        procUs: procUs,
      ),
    );
    _t3 += spacingUs;
  }

  /// Feeds a full default-size join burst of identical clean samples.
  void feedBurst({int offsetUs = 0, int rttUs = 2000, int count = 8}) {
    for (var i = 0; i < count; i++) {
      feed(offsetUs: offsetUs, rttUs: rttUs);
    }
  }

  /// Advances local time without a sample (a gap in the ping stream).
  void skip(int us) => _t3 += us;
}

/// True offset of a host clock that runs [ppm] fast relative to the local
/// clock: `offset(t) = base + ppm × 1e-6 × t`.
int rampOffset(int localUs, {required double ppm, int base = 5000000}) =>
    base + (localUs * ppm * 1e-6).round();

/// The applied offset at local time [localUs]: what the mapping adds to it.
int appliedAt(ClockSync sync, int localUs) =>
    sync.localToHostUs(localUs) - localUs;

void main() {
  group('ClockSample', () {
    test('computes offset and rtt per the spec formulas', () {
      // Asymmetric case, checked against the raw §4 formulas.
      const s = ClockSample(t0: 1000, t1: 6000, t2: 6500, t3: 4000);
      expect(s.offsetUs, ((6000 - 1000) + (6500 - 4000)) ~/ 2); // 3750
      expect(s.rttUs, (4000 - 1000) - (6500 - 6000)); // 2500
    });

    test('handles negative offsets (host clock behind guest clock)', () {
      final s = sampleAt(t0: 10000, offsetUs: -7000, rttUs: 2000);
      expect(s.offsetUs, -7000);
      expect(s.rttUs, 2000);
    });

    test('host processing time does not inflate rtt', () {
      final s = sampleAt(t0: 0, offsetUs: 500, rttUs: 3000, procUs: 40000);
      expect(s.rttUs, 3000);
      expect(s.offsetUs, 500);
    });

    test('value equality', () {
      const a = ClockSample(t0: 1, t1: 2, t2: 3, t3: 4);
      const b = ClockSample(t0: 1, t1: 2, t2: 3, t3: 4);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });
  });

  group('join burst', () {
    test('initial estimate is the offset of the minimum-RTT burst sample', () {
      final sync = ClockSync();
      final feeder = Feeder(sync);
      final rtts = [4000, 3000, 6000, 2000, 5000, 8000, 7000, 9000];
      final offsets = [111, 222, 333, 444, 555, 666, 777, 888];
      for (var i = 0; i < 8; i++) {
        feeder.feed(offsetUs: offsets[i], rttUs: rtts[i]);
      }
      expect(sync.isSynchronized, isTrue);
      expect(sync.offsetUs, 444); // rtt 2000 sample wins
      expect(sync.bestRttUs, 2000);
      expect(sync.rttFloorUs, 4000, reason: '3rd-lowest RTT is the floor');
    });

    test('not synchronized before minSamplesForSync (default 4)', () {
      final sync = ClockSync();
      final feeder = Feeder(sync);
      for (var i = 0; i < 3; i++) {
        feeder.feed(offsetUs: 100, rttUs: 2000);
        expect(sync.isSynchronized, isFalse);
        expect(sync.offsetUs, isNull);
      }
      feeder.feed(offsetUs: 100, rttUs: 2000);
      expect(sync.isSynchronized, isTrue);
      expect(sync.offsetUs, 100);
    });

    test('minSamplesForSync is configurable', () {
      final sync = ClockSync(minSamplesForSync: 2);
      final feeder = Feeder(sync);
      feeder.feed(offsetUs: 100, rttUs: 2000);
      expect(sync.isSynchronized, isFalse);
      feeder.feed(offsetUs: 100, rttUs: 2000);
      expect(sync.isSynchronized, isTrue);
    });

    test('the estimate keeps refining through the rest of the burst; the '
        'mapping follows continuously, at the warm-up slew rate', () {
      final sync = ClockSync();
      final feeder = Feeder(sync);
      for (var i = 0; i < 4; i++) {
        feeder.feed(offsetUs: 1000, rttUs: 4000);
      }
      expect(sync.offsetUs, 1000);
      // A later burst sample with lower RTT replaces the initial estimate
      // outright, but a player may already have scheduled against the
      // mapping: it moves 10 ms at 20 ms/s instead of jumping.
      final t3 = feeder.nextT3;
      feeder.feed(offsetUs: -9000, rttUs: 2000);
      expect(sync.debugEstimateUs, -9000.0);
      expect(sync.offsetUs, 1000, reason: 'unchanged at the sample itself');
      expect(appliedAt(sync, t3 + 250000), 1000 - 5000);
      expect(appliedAt(sync, t3 + 500000), -9000);
      expect(appliedAt(sync, t3 + 900000), -9000);
      expect(sync.needsHardResync, isFalse);
    });

    test('a burst refinement beyond the hard-resync threshold steps, '
        'flagged', () {
      final sync = ClockSync();
      final feeder = Feeder(sync);
      for (var i = 0; i < 4; i++) {
        feeder.feed(offsetUs: 0, rttUs: 4000);
      }
      feeder.feed(offsetUs: 80000, rttUs: 2000);
      expect(sync.offsetUs, 80000);
      expect(sync.needsHardResync, isTrue);
      expect(sync.isSynchronized, isTrue);
    });

    test('bestRttUs, rttFloorUs and skewPpm before any sample', () {
      final sync = ClockSync();
      expect(sync.bestRttUs, isNull);
      expect(sync.rttFloorUs, isNull);
      expect(sync.skewPpm, 0);
    });
  });

  group('steady-state RTT gate (aging floor)', () {
    test('rejects samples with rtt > 1.5x the floor, accepts at it', () {
      final sync = ClockSync(maxSlewUsPerSecond: 1 << 40);
      final feeder = Feeder(sync);
      feeder.feedBurst(offsetUs: 0, rttUs: 2000); // floor = 2000

      feeder.feed(offsetUs: 30000, rttUs: 3002); // > 3000: rejected
      expect(sync.debugEstimateUs, 0.0);
      expect(sync.offsetUs, 0);

      feeder.feed(offsetUs: 30000, rttUs: 3000); // exactly 1.5x: accepted
      // Accepted at the gate's edge, so at reduced quality: it moves the
      // estimate, but by less than a floor-quality sample would.
      expect(sync.debugEstimateUs, greaterThan(0));
      expect(sync.debugEstimateUs, lessThan(15000));
    });

    test('one or two lucky low-RTT samples do not tighten the gate', () {
      // The pre-2026-10 estimator gated on the all-time minimum RTT, so a
      // single lucky sample rejected everything after it, forever.
      final sync = ClockSync();
      final feeder = Feeder(sync);
      feeder.feedBurst(offsetUs: 0, rttUs: 2000);
      feeder.feed(offsetUs: 0, rttUs: 500); // lucky
      feeder.feed(offsetUs: 0, rttUs: 500); // lucky again
      expect(sync.bestRttUs, 500);
      expect(sync.rttFloorUs, 2000, reason: 'floor is the 3rd-lowest RTT');

      final before = sync.debugEstimateUs!;
      feeder.feed(offsetUs: 2000, rttUs: 2000); // normal: still accepted
      expect(sync.debugEstimateUs, greaterThan(before));

      // A third fast sample means the path really is faster now.
      feeder.feed(offsetUs: 0, rttUs: 500);
      expect(sync.rttFloorUs, 500);
      final settled = sync.debugEstimateUs!;
      final skew = sync.skewPpm;
      feeder.feed(offsetUs: 30000, rttUs: 2000); // > 750: rejected now
      // The line did not move: one second further along its slope.
      expect(sync.skewPpm, skew);
      expect(sync.debugEstimateUs, closeTo(settled + skew, 1e-6));
    });

    test('the floor ages out, so a network that gets worse is accepted '
        'again after rttFloorWindowUs + rttFloorHoldUs', () {
      final sync = ClockSync();
      final feeder = Feeder(sync); // 1 sample per second
      feeder.feedBurst(offsetUs: 0, rttUs: 2000);

      // The path degrades for good: RTT 10 ms, and (to make acceptance
      // visible) readings 1 ms higher.
      var firstAcceptedAfterS = -1;
      for (var s = 1; s <= 240; s++) {
        feeder.feed(offsetUs: 1000, rttUs: 10000);
        if (firstAcceptedAfterS < 0 && sync.debugEstimateUs! > 0) {
          firstAcceptedAfterS = s;
        }
      }
      // Burst entries leave the 60 s window once three newer entries
      // remain; the window's 10 ms floor then has to hold for 120 s.
      expect(firstAcceptedAfterS, inInclusiveRange(175, 185));
      expect(sync.rttFloorUs, 10000);
      expect(sync.debugEstimateUs, closeTo(1000, 50));
      expect(sync.skewPpm.abs(), lessThan(5), reason: 'a level step only');
    });

    test('the floor falls at once but rises only after holding: one clean '
        'round trip in ten keeps the gate on the clean RTT', () {
      // Aggressive power save: 90 % of pongs wait 30–300 ms for a beacon
      // (reading low by half the wait), one in ten is clean. A 60 s window
      // holds three clean ones only some of the time; letting the floor
      // rise whenever it did not admitted readings 15 ms off at full weight.
      final sync = ClockSync();
      final feeder = Feeder(sync, spacingUs: 2000000);
      feeder.feedBurst(offsetUs: 0, rttUs: 3000);
      var worst = 0.0;
      var maxFloor = 0;
      for (var i = 0; i < 900; i++) {
        // A deterministic, irregular pattern with long clean droughts: clean
        // at i % 10 == 0 except every fourth time.
        final clean = i % 10 == 0 && (i ~/ 10) % 4 != 3;
        final delayUs = clean ? 0 : 30000 + (i * 7919) % 270000;
        feeder.feed(offsetUs: -delayUs ~/ 2, rttUs: 3000 + delayUs);
        if (i > 60) {
          worst = math.max(worst, sync.debugEstimateUs!.abs());
          maxFloor = math.max(maxFloor, sync.rttFloorUs!);
        }
      }
      expect(maxFloor, 3000);
      expect(worst, lessThan(100));
    });

    test('silence does not age the floor: after a 10-minute ping gap the '
        'pre-gap floor stands until the post-gap path proves worse', () {
      final sync = ClockSync();
      final feeder = Feeder(sync, spacingUs: 2000000);
      feeder.feedBurst(offsetUs: 0, rttUs: 3000);
      for (var i = 0; i < 100; i++) {
        final delayUs = i % 10 == 0 ? 0 : 30000 + (i * 7919) % 270000;
        feeder.feed(offsetUs: -delayUs ~/ 2, rttUs: 3000 + delayUs);
      }
      expect(sync.rttFloorUs, 3000);
      feeder.skip(10 * 60 * 1000000); // backgrounded
      // A clean-free minute after the gap: still gated on 3 ms.
      for (var i = 0; i < 30; i++) {
        final delayUs = 30000 + (i * 7919) % 270000;
        feeder.feed(offsetUs: -delayUs ~/ 2, rttUs: 3000 + delayUs);
        expect(sync.rttFloorUs, 3000, reason: 'post-gap sample $i');
      }
      expect(sync.debugEstimateUs!.abs(), lessThan(100));
    });

    test('a gap in the ping stream keeps the most recent floor samples', () {
      final sync = ClockSync();
      final feeder = Feeder(sync);
      feeder.feedBurst(offsetUs: 0, rttUs: 2000);
      feeder.skip(5 * 60 * 1000000); // 5 minutes without a single pong

      // A spike right after the gap must not become its own reference.
      feeder.feed(offsetUs: -40000, rttUs: 120000);
      expect(sync.rttFloorUs, 2000);
      expect(sync.debugEstimateUs, 0.0);
    });

    test('rttFloorRank, rttFloorWindowUs and rttFloorHoldUs are '
        'configurable', () {
      final sync = ClockSync(
        rttFloorRank: 1,
        rttFloorWindowUs: 10000000,
        rttFloorHoldUs: 0,
      );
      final feeder = Feeder(sync);
      feeder.feedBurst(offsetUs: 0, rttUs: 2000);
      feeder.feed(offsetUs: 0, rttUs: 1000); // rank 1: tightens at once
      expect(sync.rttFloorUs, 1000);
      for (var i = 0; i < 12; i++) {
        feeder.feed(offsetUs: 0, rttUs: 4000);
      }
      expect(sync.rttFloorUs, 4000, reason: '10 s window aged out');
    });
  });

  // These pin the level's arithmetic, so they switch skew tracking off: a
  // step in the readings would otherwise also (correctly) nudge the fitted
  // slope once the fit spans 10 s, and the expected values would no longer
  // be closed-form.
  group('level (EWMA) blending', () {
    test('after warm-up, floor-quality samples blend with exactly alpha', () {
      final sync = ClockSync(maxSkewPpm: 0, maxSlewUsPerSecond: 1 << 40);
      final feeder = Feeder(sync);
      feeder.feedBurst(offsetUs: 0, rttUs: 2000);
      // Warm-up: 1/α − 1 = 9 floor-quality samples after the seed.
      for (var i = 0; i < 9; i++) {
        feeder.feed(offsetUs: 0, rttUs: 2000);
      }

      // True offset shifts to +10 000 µs; each accepted sample closes 10 %
      // of the remaining gap: estimate_n = 10000 * (1 - 0.9^n).
      var expected = 0.0;
      for (var n = 1; n <= 30; n++) {
        feeder.feed(offsetUs: 10000, rttUs: 2000);
        expected += 0.1 * (10000 - expected);
        expect(sync.debugEstimateUs, closeTo(expected, 1e-6));
      }
      expect(sync.debugEstimateUs, closeTo(10000, 500));
    });

    test('warm-up averages the seed with what follows instead of letting '
        'it dominate', () {
      final sync = ClockSync(maxSkewPpm: 0, maxSlewUsPerSecond: 1 << 40);
      final feeder = Feeder(sync);
      feeder.feedBurst(offsetUs: 0, rttUs: 2000);
      feeder.feed(offsetUs: 3000, rttUs: 2000);
      expect(sync.debugEstimateUs, closeTo(1500, 1e-6)); // EWMA would be 300
      feeder.feed(offsetUs: 3000, rttUs: 2000);
      expect(sync.debugEstimateUs, closeTo(2000, 1e-6));
    });

    test('a burst seed judged against a later, lower floor loses its say', () {
      // The whole burst queued (6 ms RTTs) and read 0; the path's real
      // floor is 2 ms and the true offset 1 ms.
      final sync = ClockSync(maxSlewUsPerSecond: 1 << 40);
      final feeder = Feeder(sync);
      feeder.feedBurst(offsetUs: 0, rttUs: 6000);
      for (var i = 0; i < 3; i++) {
        feeder.feed(offsetUs: 1000, rttUs: 2000);
      }
      expect(sync.rttFloorUs, 2000);
      expect(sync.debugEstimateUs, closeTo(1000, 20));
    });

    test('a queued burst is re-seeded from the first much better reading '
        'and corrected within seconds, not slewed off at 1 ms/s', () {
      // The whole burst queued behind one power-save delay: 80 ms RTTs
      // reading 30 ms low. The true offset is 0 (2 ms RTT path).
      final sync = ClockSync();
      final feeder = Feeder(sync, spacingUs: 2000000);
      feeder.feedBurst(offsetUs: -30000, rttUs: 80000);
      expect(sync.offsetUs, -30000);
      final t3 = feeder.nextT3;
      feeder.feed(offsetUs: 0, rttUs: 2000);
      // Under half the seed's RTT during warm-up: min-RTT selection carries
      // on, so the estimate moves onto it at once...
      expect(sync.debugEstimateUs, 0.0);
      // ...and the mapping follows at the warm-up rate (20 ms/s), never
      // jumping. Slewing at 1 ms/s would still be ~28 ms off after 2 s.
      expect(appliedAt(sync, t3), -30000);
      expect(appliedAt(sync, t3 + 1000000), -10000);
      expect(appliedAt(sync, t3 + 1500000), 0);
      for (var i = 0; i < 2; i++) {
        feeder.feed(offsetUs: 0, rttUs: 2000);
      }
      expect(sync.offsetUs!.abs(), lessThan(1000));
      expect(sync.needsHardResync, isFalse, reason: 'below 50 ms: no resync');
    });

    test('a queued (high-RTT) accepted sample moves the level less', () {
      double stepFor(int rttUs) {
        final sync = ClockSync(maxSkewPpm: 0, maxSlewUsPerSecond: 1 << 40);
        final feeder = Feeder(sync);
        feeder.feedBurst(offsetUs: 0, rttUs: 2000);
        for (var i = 0; i < 9; i++) {
          feeder.feed(offsetUs: 0, rttUs: 2000);
        }
        feeder.feed(offsetUs: 1000, rttUs: rttUs);
        return sync.debugEstimateUs!;
      }

      expect(stepFor(2000), closeTo(100, 1e-6)); // full α
      expect(stepFor(2400), closeTo(50, 1e-6)); // half the excess = 200 µs
      expect(stepFor(3000), lessThan(15)); // at the gate's edge
    });

    test('alpha is configurable', () {
      final sync = ClockSync(
        ewmaAlpha: 0.5,
        maxSkewPpm: 0,
        maxSlewUsPerSecond: 1 << 40,
      );
      final feeder = Feeder(sync);
      feeder.feedBurst(offsetUs: 0, rttUs: 2000);
      feeder.feed(offsetUs: 0, rttUs: 2000); // warm-up: 1/α − 1 = 1 sample
      feeder.feed(offsetUs: 8000, rttUs: 2000);
      expect(sync.debugEstimateUs, 4000.0);
    });
  });

  group('skew tracking', () {
    /// Feeds a clean burst and [count] steady samples 2 s apart from a host
    /// clock running [ppm] fast; returns the feeder.
    Feeder feedRamp(ClockSync sync, double ppm, {int count = 60}) {
      final feeder = Feeder(sync, spacingUs: 2000000);
      for (var i = 0; i < 8 + count; i++) {
        final mid = feeder.nextT3 - 1000;
        feeder.feed(offsetUs: rampOffset(mid, ppm: ppm), rttUs: 2000);
      }
      return feeder;
    }

    for (final ppm in [100.0, -200.0]) {
      test('learns a ${ppm.toStringAsFixed(0)} ppm skew and converts '
          'exactly between pings', () {
        final sync = ClockSync();
        final feeder = feedRamp(sync, ppm);
        expect(sync.skewPpm, closeTo(ppm, 1));

        // Anywhere between pings — and well past the last one — conversions
        // follow the ramp instead of holding a stale constant offset.
        for (final ahead in [0, 1000000, 1900000, 30000000]) {
          final local = feeder.nextT3 - 2000000 + ahead;
          final trueHost = local + rampOffset(local, ppm: ppm);
          expect(
            (sync.localToHostUs(local) - trueHost).abs(),
            lessThan(30),
            reason: '$ahead µs after the last sample',
          );
          expect((sync.hostToLocalUs(trueHost) - local).abs(), lessThan(30));
        }
      });
    }

    test('removes the lag a plain EWMA has behind a drifting clock', () {
      int errorAfterRamp(ClockSync sync) {
        final feeder = feedRamp(sync, 100);
        final local = feeder.nextT3 - 2000000;
        return sync.localToHostUs(local) -
            (local + rampOffset(local, ppm: 100));
      }

      // Skew off (pre-2026-10 behaviour): the EWMA trails a 100 ppm ramp
      // by ~(1 − α)/α × 2 s × 100 ppm ≈ 1.8 ms.
      expect(errorAfterRamp(ClockSync(maxSkewPpm: 0)).abs(), greaterThan(1500));
      expect(errorAfterRamp(ClockSync()).abs(), lessThan(30));
    });

    test('rides out a long stretch of rejected samples on the skew', () {
      final sync = ClockSync();
      final feeder = feedRamp(sync, 100, count: 150); // 5 min to learn
      // 50 s of congestion: every reading queued (and biased by -20 ms).
      for (var i = 0; i < 25; i++) {
        final mid = feeder.nextT3 - 15000;
        feeder.feed(offsetUs: rampOffset(mid, ppm: 100) - 20000, rttUs: 30000);
      }
      final local = feeder.nextT3;
      final trueHost = local + rampOffset(local, ppm: 100);
      // A frozen offset would now be 50 s × 100 ppm = 5 ms off.
      expect((sync.localToHostUs(local) - trueHost).abs(), lessThan(50));
    });

    test('hostToLocalUs maps true host times to true local times under '
        'skew, and the two conversions invert each other to 1 µs', () {
      final sync = ClockSync();
      final feeder = feedRamp(sync, -150);
      // Against the ground truth, not against localToHostUs: around now and
      // a minute ahead.
      for (final ahead in [0, 700000, 60000000]) {
        final local = feeder.nextT3 + ahead;
        final trueHost = local + rampOffset(local, ppm: -150);
        expect((sync.hostToLocalUs(trueHost) - local).abs(), lessThan(30));
      }
      // And as a property, anywhere on the mapping.
      for (final local in [123456789, 987654321012, 5, feeder.nextT3]) {
        final host = sync.localToHostUs(local);
        expect((sync.hostToLocalUs(host) - local).abs(), lessThanOrEqualTo(1));
        expect(
          (sync.localToHostUs(sync.hostToLocalUs(local)) - local).abs(),
          lessThanOrEqualTo(1),
        );
      }
    });

    test('learns a 600 ppm skew — a Linux host whose CLOCK_MONOTONIC NTP is '
        'slewing — instead of clipping it (maxSkewPpm defaults to 1000)', () {
      final sync = ClockSync();
      final feeder = feedRamp(sync, 600, count: 150);
      expect(sync.skewPpm, closeTo(600, 2));
      final local = feeder.nextT3;
      final trueHost = local + rampOffset(local, ppm: 600);
      expect((sync.localToHostUs(local) - trueHost).abs(), lessThan(100));
    });

    test('a three-reading fit is shrunk too: collinear readings within '
        '±RTT/2 of a constant offset do not make a 160 ppm skew', () {
      // Review repro R3. The burst reads 0 and the next readings +1.8 ms,
      // all at a 4 ms RTT — each within ±RTT/2 of a true offset of 0. The
      // unshrunk slope through seed + 2 readings is 160 ppm; three nearly
      // collinear points made the residual variance (and so the shrinkage)
      // vanish, and n == 3 skipped shrinkage altogether.
      final sync = ClockSync();
      var t0 = 1000000000;
      for (var i = 0; i < 8; i++) {
        sync.addSample(sampleAt(t0: t0, offsetUs: 0, rttUs: 4000));
        t0 += 1000;
      }
      t0 += 10000000;
      final skews = <double>[];
      for (var i = 0; i < 6; i++) {
        sync.addSample(sampleAt(t0: t0, offsetUs: 1800, rttUs: 4000));
        skews.add(sync.skewPpm);
        t0 += 2000000;
      }
      expect(skews.first, 0, reason: 'two points: no slope yet');
      expect(skews[1], lessThan(110), reason: 'three points: shrunk');
      for (final skew in skews.skip(2)) {
        expect(skew, lessThan(110));
      }
    });

    test('a ping gap longer than the skew window keeps the learned rate', () {
      // Review repro R2: 5 minutes at 100 ppm, 30 minutes without a ping
      // (backgrounded), then readings with ±0.7 ms of symmetric noise. The
      // fit used to drop every pre-gap reading, replace the known rate by a
      // few seconds of noisy ones (57–108 ppm) and pivot the line around a
      // half-hour-old EWMA centroid: 4.1 ms off.
      final sync = ClockSync();
      final feeder = Feeder(sync, spacingUs: 2000000);
      for (var i = 0; i < 8 + 150; i++) {
        final mid = feeder.nextT3 - 1500;
        feeder.feed(offsetUs: rampOffset(mid, ppm: 100), rttUs: 3000);
      }
      feeder.skip(30 * 60 * 1000000);
      const noise = [700, -700, 600, 700, -600, 700, 650, 700, -500, 600];
      var worst = 0;
      for (var i = 0; i < 40; i++) {
        final mid = feeder.nextT3 - 1500;
        final t3 = feeder.nextT3;
        feeder.feed(
          offsetUs: rampOffset(mid, ppm: 100) + noise[i % noise.length],
          rttUs: 3000,
        );
        expect(sync.skewPpm, closeTo(100, 5));
        expect(sync.needsHardResync, isFalse);
        for (var dt = 0; dt < 2000000; dt += 100000) {
          final local = t3 + dt;
          final err =
              sync.localToHostUs(local) - (local + rampOffset(local, ppm: 100));
          worst = math.max(worst, err.abs());
        }
      }
      expect(worst, lessThan(1000));
    });

    test('follows a crystal warming from 20 to 60 ppm over half an hour', () {
      final sync = ClockSync();
      final feeder = Feeder(sync, spacingUs: 2000000);
      final start = feeder.nextT3;
      const rampUs = 30 * 60 * 1000000;
      // Rate 20 → 60 ppm linearly over rampUs: the offset is quadratic.
      double ppmAt(int t) => 20 + 40 * ((t - start) / rampUs).clamp(0, 1);
      int offsetAt(int t) {
        final dt = (t - start).toDouble();
        final inRamp = math.min(dt, rampUs.toDouble());
        final ramp = 20 * inRamp + 20 * inRamp * inRamp / rampUs;
        return 5000000 + ((ramp + 60 * (dt - inRamp)) * 1e-6).round();
      }

      var worst = 0;
      for (var i = 0; i < 8 + 1200; i++) {
        final mid = feeder.nextT3 - 1000;
        final t3 = feeder.nextT3;
        feeder.feed(offsetUs: offsetAt(mid), rttUs: 2000);
        if (i < 8 + 150) continue; // the first 5 minutes learn the rate
        // A 5-minute fit lags a 1.3 ppm/min ramp by half its window.
        expect(sync.skewPpm, closeTo(ppmAt(t3), 5));
        final ahead = t3 + 1000000;
        final err = sync.localToHostUs(ahead) - (ahead + offsetAt(ahead));
        worst = math.max(worst, err.abs());
      }
      expect(worst, lessThan(300));
    });

    test('maxSkewPpm clamps the estimate; 0 disables tracking', () {
      final clamped = ClockSync(maxSkewPpm: 50);
      feedRamp(clamped, 300);
      expect(clamped.skewPpm, closeTo(50, 1e-9));

      final off = ClockSync(maxSkewPpm: 0);
      feedRamp(off, 300);
      expect(off.skewPpm, 0);
    });

    test('a short noisy fit does not invent a skew', () {
      final sync = ClockSync();
      final feeder = Feeder(sync, spacingUs: 2000000);
      feeder.feedBurst(offsetUs: 0, rttUs: 2000);
      // 12 s of ±1.5 ms alternating noise around a constant offset, all at
      // floor quality.
      for (var i = 0; i < 6; i++) {
        feeder.feed(offsetUs: i.isEven ? 1500 : -1500, rttUs: 2000);
      }
      expect(sync.skewPpm.abs(), lessThan(25));
    });
  });

  // Like the EWMA group, these pin closed-form values, so a step in the
  // readings must not also register as a skew: tracking is off.
  group('slewing (continuous mapping)', () {
    test('the gap to the estimate closes at maxSlewUsPerSecond, starting '
        'at the sample, between samples too', () {
      // alpha 1 makes the raw estimate jump to 10 000 immediately (below the
      // 50 ms hard-resync threshold).
      final sync = ClockSync(ewmaAlpha: 1.0, maxSkewPpm: 0);
      final feeder = Feeder(sync, spacingUs: 1000000);
      feeder.feedBurst(offsetUs: 0, rttUs: 2000);

      for (var k = 1; k <= 12; k++) {
        final t3 = feeder.nextT3;
        feeder.feed(offsetUs: 10000, rttUs: 2000);
        expect(sync.needsHardResync, isFalse);
        // At each sample the mapping still has the value it had there —
        // 1 ms per second since the first one — and keeps closing the gap
        // until the next.
        expect(sync.offsetUs, math.min(10000, 1000 * (k - 1)));
        for (final ms in [250, 500, 999]) {
          expect(
            appliedAt(sync, t3 + ms * 1000),
            math.min(10000, 1000 * (k - 1) + ms),
            reason: '$ms ms after sample $k',
          );
        }
      }
    });

    test('slew rate is configurable and works downward (negative error)', () {
      final sync = ClockSync(
        ewmaAlpha: 1.0,
        maxSkewPpm: 0,
        maxSlewUsPerSecond: 250,
      );
      final feeder = Feeder(sync, spacingUs: 1000000);
      feeder.feedBurst(offsetUs: 0, rttUs: 2000);
      final t3 = feeder.nextT3;
      feeder.feed(offsetUs: -10000, rttUs: 2000);
      expect(appliedAt(sync, t3 + 1000000), -250);
      feeder.feed(offsetUs: -10000, rttUs: 2000);
      expect(sync.offsetUs, -250);
      expect(appliedAt(sync, t3 + 2000000), -500);
    });

    test('a correction completes without further samples (a ping gap)', () {
      final sync = ClockSync(ewmaAlpha: 1.0, maxSkewPpm: 0);
      final feeder = Feeder(sync, spacingUs: 2000000);
      feeder.feedBurst(offsetUs: 0, rttUs: 2000);
      final t3 = feeder.nextT3;
      feeder.feed(offsetUs: 10000, rttUs: 2000);
      expect(appliedAt(sync, t3 + 2000000), 2000);
      // Nothing for a minute: the mapping reaches the estimate and then
      // follows it, instead of stopping where the last sample left it.
      expect(appliedAt(sync, t3 + 60000000), 10000);
      expect(sync.hostToLocalUs(t3 + 60000000 + 10000), t3 + 60000000);
    });

    test('gate-rejected samples do not disturb the slew', () {
      final sync = ClockSync(ewmaAlpha: 1.0, maxSkewPpm: 0);
      final feeder = Feeder(sync, spacingUs: 1000000);
      feeder.feedBurst(offsetUs: 0, rttUs: 2000);
      final t3 = feeder.nextT3;
      feeder.feed(offsetUs: 10000, rttUs: 2000); // accepted: est 10000
      feeder.feed(offsetUs: 0, rttUs: 100000); // rejected, 1 s later
      expect(sync.debugEstimateUs, 10000.0);
      expect(appliedAt(sync, t3 + 1500000), 1500);
    });

    test('an unlimited slew rate steps (unflagged below the threshold)', () {
      final sync = ClockSync(ewmaAlpha: 1.0, maxSlewUsPerSecond: 1000000);
      final feeder = Feeder(sync);
      feeder.feedBurst(offsetUs: 0, rttUs: 2000);
      feeder.feed(offsetUs: 10000, rttUs: 2000);
      expect(sync.offsetUs, 10000);
      expect(sync.needsHardResync, isFalse);
    });
  });

  group('hard resync (offset steps)', () {
    test('a single sample 100 ms off is quarantined, not acted on', () {
      final sync = ClockSync(ewmaAlpha: 1.0);
      final feeder = Feeder(sync);
      feeder.feedBurst(offsetUs: 0, rttUs: 2000);
      feeder.feed(offsetUs: 100000, rttUs: 2000);
      expect(sync.debugPendingDiscontinuityCount, 1);
      expect(sync.needsHardResync, isFalse);
      expect(sync.debugEstimateUs, 0.0);
      feeder.feed(offsetUs: 0, rttUs: 2000); // back to normal: cleared
      expect(sync.debugPendingDiscontinuityCount, 0);
      expect(sync.needsHardResync, isFalse);
    });

    test('a confirmed step re-seeds, steps once and sets the flag', () {
      // A short suspend (the local clock stopped for 100 ms): the default
      // α = 0.1 would crawl toward it and hard-resync several times.
      final sync = ClockSync();
      final feeder = Feeder(sync);
      feeder.feedBurst(offsetUs: 0, rttUs: 2000);
      feeder.feed(offsetUs: 100000, rttUs: 2000); // candidate
      expect(sync.needsHardResync, isFalse);
      feeder.feed(offsetUs: 100000, rttUs: 2000); // confirms the step
      expect(sync.isSynchronized, isTrue, reason: 'a step is not a reset');
      expect(sync.needsHardResync, isTrue);
      expect(sync.offsetUs, 100000); // stepped, not slewed
      expect(sync.debugPendingDiscontinuityCount, 0);

      sync.acknowledgeHardResync();
      for (var i = 0; i < 20; i++) {
        feeder.feed(offsetUs: 100000, rttUs: 2000);
      }
      expect(sync.needsHardResync, isFalse, reason: 'no further resyncs');
      expect(sync.offsetUs, 100000);
    });

    test('the step re-seeds from the lowest-RTT confirming reading', () {
      final sync = ClockSync();
      final feeder = Feeder(sync);
      feeder.feedBurst(offsetUs: 0, rttUs: 2000);
      feeder.feed(offsetUs: 81000, rttUs: 2600);
      feeder.feed(offsetUs: 80000, rttUs: 2000);
      expect(sync.needsHardResync, isTrue);
      expect(sync.offsetUs, 80000);
    });

    test('flag is consumable and does not re-fire without a new step', () {
      final sync = ClockSync(ewmaAlpha: 1.0);
      final feeder = Feeder(sync, spacingUs: 1000000);
      feeder.feedBurst(offsetUs: 0, rttUs: 2000);
      feeder.feed(offsetUs: 100000, rttUs: 2000);
      feeder.feed(offsetUs: 100000, rttUs: 2000);
      expect(sync.needsHardResync, isTrue);

      sync.acknowledgeHardResync();
      expect(sync.needsHardResync, isFalse);

      feeder.feed(offsetUs: 100000, rttUs: 2000); // error now 0
      expect(sync.needsHardResync, isFalse);
      expect(sync.offsetUs, 100000);
    });

    test('threshold is configurable and fires on negative steps too', () {
      final sync = ClockSync(ewmaAlpha: 1.0, hardResyncThresholdUs: 5000);
      final feeder = Feeder(sync, spacingUs: 1000000);
      feeder.feedBurst(offsetUs: 0, rttUs: 2000);
      feeder.feed(offsetUs: -6000, rttUs: 2000);
      feeder.feed(offsetUs: -6000, rttUs: 2000);
      expect(sync.needsHardResync, isTrue);
      expect(sync.offsetUs, -6000);
    });

    test('errors at or below threshold slew instead of stepping', () {
      final sync = ClockSync(ewmaAlpha: 1.0);
      final feeder = Feeder(sync, spacingUs: 1000000);
      feeder.feedBurst(offsetUs: 0, rttUs: 2000);
      final t3 = feeder.nextT3;
      feeder.feed(offsetUs: 50000, rttUs: 2000); // exactly the threshold
      expect(sync.debugPendingDiscontinuityCount, 0);
      expect(sync.needsHardResync, isFalse);
      expect(sync.offsetUs, 0); // no step at the sample...
      expect(appliedAt(sync, t3 + 1000000), 1000); // ...slewed after it
    });

    test('a step keeps the learned skew', () {
      final sync = ClockSync();
      final feeder = Feeder(sync, spacingUs: 2000000);
      for (var i = 0; i < 68; i++) {
        final mid = feeder.nextT3 - 1000;
        feeder.feed(offsetUs: rampOffset(mid, ppm: 80), rttUs: 2000);
      }
      expect(sync.skewPpm, closeTo(80, 1));
      for (var i = 0; i < 2; i++) {
        final mid = feeder.nextT3 - 1000;
        feeder.feed(offsetUs: rampOffset(mid, ppm: 80) + 200000, rttUs: 2000);
      }
      expect(sync.needsHardResync, isTrue);
      expect(sync.skewPpm, closeTo(80, 1));
      final local = feeder.nextT3 + 20000000;
      final trueHost = local + rampOffset(local, ppm: 80) + 200000;
      expect((sync.localToHostUs(local) - trueHost).abs(), lessThan(50));
    });
  });

  group('conversions', () {
    test('hostToLocalUs / localToHostUs use the applied offset', () {
      final sync = ClockSync();
      final feeder = Feeder(sync);
      feeder.feedBurst(offsetUs: 12345, rttUs: 2000);
      expect(sync.offsetUs, 12345);
      expect(sync.localToHostUs(1000000), 1000000 + 12345);
      expect(sync.hostToLocalUs(1000000), 1000000 - 12345);
    });

    test('round-trip in both directions, including negative offsets', () {
      final sync = ClockSync();
      final feeder = Feeder(sync);
      feeder.feedBurst(offsetUs: -5000, rttUs: 2000);
      expect(sync.offsetUs, -5000);
      const local = 987654321;
      const host = 123456789;
      expect(sync.hostToLocalUs(sync.localToHostUs(local)), local);
      expect(sync.localToHostUs(sync.hostToLocalUs(host)), host);
    });

    test('throw StateError before synchronized', () {
      final sync = ClockSync();
      expect(() => sync.hostToLocalUs(0), throwsStateError);
      expect(() => sync.localToHostUs(0), throwsStateError);

      // Still throws while below minSamplesForSync.
      final feeder = Feeder(sync);
      feeder.feed(offsetUs: 0, rttUs: 2000);
      expect(() => sync.hostToLocalUs(0), throwsStateError);
      expect(sync.offsetUs, isNull);
    });
  });

  group('clock discontinuity (device sleep)', () {
    // A deep-sleep gap pauses the guest's monotonic clock, so after waking
    // every sample reports an offset minutes away from the estimate.
    const sleepUs = 120000000; // 2 minutes

    test(
      'sleep is detected on the second sample, resets, and re-converges',
      () {
        final sync = ClockSync();
        final feeder = Feeder(sync);
        feeder.feedBurst(offsetUs: 1000, rttUs: 2000); // floor 2000
        for (var i = 0; i < 3; i++) {
          feeder.feed(offsetUs: 1000, rttUs: 2000);
        }
        expect(sync.isSynchronized, isTrue);
        expect(sync.offsetUs, 1000);
        expect(sync.needsHardResync, isFalse);

        const woke = 1000 + sleepUs;

        // First post-wake sample: a candidate, quarantined but not acted on.
        feeder.feed(offsetUs: woke, rttUs: 3000); // 3000 == 1.5x floor
        expect(sync.debugPendingDiscontinuityCount, 1);
        expect(sync.isSynchronized, isTrue, reason: 'one sample cannot reset');
        expect(
          sync.debugEstimateUs,
          1000.0,
          reason: 'quarantined, not blended',
        );

        // Second consistent candidate confirms the jump: full reset.
        feeder.feed(offsetUs: woke, rttUs: 3000);
        expect(sync.isSynchronized, isFalse);
        expect(sync.offsetUs, isNull);
        expect(sync.debugEstimateUs, isNull);
        expect(sync.needsHardResync, isTrue);
        expect(sync.debugPendingDiscontinuityCount, 0);
        expect(() => sync.hostToLocalUs(0), throwsStateError);
        expect(() => sync.localToHostUs(0), throwsStateError);
        // RTT floor tracking restarted from the confirming sample; the
        // pre-sleep 2000 µs references are gone.
        expect(sync.bestRttUs, 3000);

        // The confirming sample opened a fresh join burst; three more samples
        // reach minSamplesForSync, with min-RTT selection over the new burst.
        feeder.feed(offsetUs: woke + 400, rttUs: 5000);
        expect(sync.isSynchronized, isFalse);
        feeder.feed(offsetUs: woke - 700, rttUs: 2500); // new min rtt: wins
        expect(sync.isSynchronized, isFalse);
        feeder.feed(offsetUs: woke + 900, rttUs: 6000);

        expect(sync.isSynchronized, isTrue);
        expect(sync.bestRttUs, 2500);
        expect(sync.offsetUs, woke - 700);
        expect(sync.localToHostUs(5), 5 + woke - 700);
        expect(sync.hostToLocalUs(woke - 700 + 5), 5);

        // The resync flag stays consumable exactly as after a hard resync.
        expect(sync.needsHardResync, isTrue);
        sync.acknowledgeHardResync();
        expect(sync.needsHardResync, isFalse);
      },
    );

    test('slew state does not leak across the reset', () {
      // Default 1000 µs/s slew: reaching a 90 s offset by slewing would take
      // a day, so an immediately-correct applied offset proves the reset.
      final sync = ClockSync();
      final feeder = Feeder(sync, spacingUs: 1000000);
      feeder.feedBurst(offsetUs: 0, rttUs: 2000);
      expect(sync.offsetUs, 0);

      const woke = 90000000;
      feeder.feed(offsetUs: woke, rttUs: 2000); // candidate
      feeder.feed(offsetUs: woke, rttUs: 2000); // confirms: reset + burst #1
      for (var i = 0; i < 3; i++) {
        feeder.feed(offsetUs: woke, rttUs: 2000);
      }
      expect(sync.isSynchronized, isTrue);
      expect(
        sync.offsetUs,
        woke,
        reason: 'stepped to the new offset, not slewed',
      );
      expect(sync.debugEstimateUs, woke.toDouble());

      // Steady state resumes cleanly around the new offset.
      sync.acknowledgeHardResync();
      for (var i = 0; i < 5; i++) {
        feeder.feed(offsetUs: woke, rttUs: 2000);
      }
      expect(sync.offsetUs, woke);
      expect(sync.needsHardResync, isFalse);
    });

    test('the skew value survives the reset', () {
      final sync = ClockSync();
      final feeder = Feeder(sync, spacingUs: 2000000);
      for (var i = 0; i < 68; i++) {
        final mid = feeder.nextT3 - 1000;
        feeder.feed(offsetUs: rampOffset(mid, ppm: -60), rttUs: 2000);
      }
      expect(sync.skewPpm, closeTo(-60, 1));
      for (var i = 0; i < 5; i++) {
        final mid = feeder.nextT3 - 1000;
        feeder.feed(offsetUs: rampOffset(mid, ppm: -60) + sleepUs, rttUs: 2000);
      }
      expect(sync.isSynchronized, isTrue, reason: 're-burst complete');
      expect(sync.skewPpm, closeTo(-60, 1));
    });

    test('a single wild outlier neither resets nor poisons the estimate', () {
      final sync = ClockSync(maxSlewUsPerSecond: 1 << 40);
      final feeder = Feeder(sync);
      feeder.feedBurst(offsetUs: 0, rttUs: 2000);

      feeder.feed(offsetUs: 60000000, rttUs: 2000); // 60 s, passes the gate
      expect(sync.isSynchronized, isTrue);
      expect(sync.needsHardResync, isFalse);
      expect(sync.debugPendingDiscontinuityCount, 1);
      expect(sync.debugEstimateUs, 0.0, reason: 'quarantined, not blended');
      expect(sync.offsetUs, 0);

      // A good sample clears the pending run; the estimate never moved, so
      // nothing about the outlier survives.
      feeder.feed(offsetUs: 0, rttUs: 2000);
      expect(sync.debugPendingDiscontinuityCount, 0);
      expect(sync.debugEstimateUs, 0.0);
      expect(sync.isSynchronized, isTrue);
      expect(sync.needsHardResync, isFalse);
    });

    test('two mutually inconsistent outliers do not confirm a jump', () {
      final sync = ClockSync();
      final feeder = Feeder(sync);
      feeder.feedBurst(offsetUs: 0, rttUs: 2000);

      feeder.feed(offsetUs: 60000000, rttUs: 2000);
      expect(sync.debugPendingDiscontinuityCount, 1);
      // Disagrees with the pending candidate as much as with the estimate:
      // the run restarts at 1 instead of confirming.
      feeder.feed(offsetUs: -60000000, rttUs: 2000);
      expect(sync.debugPendingDiscontinuityCount, 1);
      expect(sync.isSynchronized, isTrue);
      expect(sync.debugEstimateUs, 0.0);
    });

    test('the gate cannot starve detection: a sleep is caught even when '
        'every post-wake sample is gate-rejected', () {
      // Pre-2026-10, only gate-accepted samples could reveal a jump, so a
      // guest waking onto a worse network kept its pre-sleep offset — two
      // minutes wrong — for as long as the network stayed worse.
      final sync = ClockSync();
      final feeder = Feeder(sync);
      feeder.feedBurst(offsetUs: 0, rttUs: 2000);
      feeder.feed(offsetUs: sleepUs, rttUs: 100000); // way past the gate
      expect(sync.debugPendingDiscontinuityCount, 1);
      feeder.feed(offsetUs: sleepUs + 3000, rttUs: 90000);
      expect(sync.isSynchronized, isFalse);
      expect(sync.needsHardResync, isTrue);
    });

    test('a gate-rejected reading only counts beyond its own RTT', () {
      // 120 ms off but with a 100 ms RTT: its true offset could be anywhere
      // within ±50 ms of the reading, so it proves only 20 ms (< 50 ms).
      final sync = ClockSync();
      final feeder = Feeder(sync);
      feeder.feedBurst(offsetUs: 0, rttUs: 2000);
      for (var i = 0; i < 4; i++) {
        feeder.feed(offsetUs: 120000, rttUs: 100000);
      }
      expect(sync.debugPendingDiscontinuityCount, 0);
      expect(sync.isSynchronized, isTrue);
      expect(sync.needsHardResync, isFalse);
      expect(sync.debugEstimateUs, 0.0);
    });

    test('a confirmed jump of exactly the threshold is a step; one µs more '
        'is a discontinuity', () {
      final atThreshold = ClockSync();
      Feeder(atThreshold)
        ..feedBurst(offsetUs: 0, rttUs: 2000)
        ..feed(offsetUs: 500000, rttUs: 2000)
        ..feed(offsetUs: 500000, rttUs: 2000);
      expect(atThreshold.isSynchronized, isTrue);
      expect(atThreshold.needsHardResync, isTrue);
      expect(atThreshold.offsetUs, 500000);

      final beyond = ClockSync();
      Feeder(beyond)
        ..feedBurst(offsetUs: 0, rttUs: 2000)
        ..feed(offsetUs: 500001, rttUs: 2000)
        ..feed(offsetUs: 500001, rttUs: 2000);
      expect(beyond.isSynchronized, isFalse);
      expect(beyond.needsHardResync, isTrue);
    });

    test('threshold and confirmation count are configurable', () {
      final sync = ClockSync(
        discontinuityThresholdUs: 200000,
        discontinuityConfirmations: 1,
      );
      final feeder = Feeder(sync);
      feeder.feedBurst(offsetUs: 0, rttUs: 2000);

      feeder.feed(offsetUs: 200000, rttUs: 2000); // at threshold: a step
      expect(sync.isSynchronized, isTrue);
      expect(sync.needsHardResync, isTrue);
      expect(sync.offsetUs, 200000);
      sync.acknowledgeHardResync();

      feeder.feed(offsetUs: 500000, rttUs: 2000); // 300 ms beyond: resets
      expect(sync.isSynchronized, isFalse);
      expect(sync.needsHardResync, isTrue);
    });

    test('needs three confirmations when configured, not two', () {
      final sync = ClockSync(discontinuityConfirmations: 3);
      final feeder = Feeder(sync);
      feeder.feedBurst(offsetUs: 0, rttUs: 2000);
      feeder.feed(offsetUs: sleepUs, rttUs: 2000);
      feeder.feed(offsetUs: sleepUs, rttUs: 2000);
      expect(sync.isSynchronized, isTrue);
      expect(sync.debugPendingDiscontinuityCount, 2);
      feeder.feed(offsetUs: sleepUs, rttUs: 2000);
      expect(sync.isSynchronized, isFalse);
    });

    test('a jump before the first sync is a non-event', () {
      final sync = ClockSync();
      final feeder = Feeder(sync);
      for (var i = 0; i < 2; i++) {
        feeder.feed(offsetUs: 0, rttUs: 4000);
      }
      // Burst samples 3–4 report an offset minutes away. Min-RTT selection
      // simply adopts them: no candidates, no reset, no resync flag.
      for (var i = 0; i < 2; i++) {
        feeder.feed(offsetUs: sleepUs, rttUs: 3000 - 2 * i);
      }
      expect(sync.debugPendingDiscontinuityCount, 0);
      expect(sync.isSynchronized, isTrue);
      expect(sync.needsHardResync, isFalse);
      expect(sync.offsetUs, sleepUs);
    });

    test('a jump during the rest of the join burst is adopted by min-RTT '
        'selection: a flagged step, never a reset', () {
      final sync = ClockSync();
      final feeder = Feeder(sync);
      for (var i = 0; i < 4; i++) {
        feeder.feed(offsetUs: 0, rttUs: 4000);
      }
      expect(sync.offsetUs, 0);

      // Burst samples 5–8 report an offset minutes away. Min-RTT selection
      // adopts them; a player may already be scheduled on the old value, so
      // the mapping steps and says so.
      for (var i = 0; i < 4; i++) {
        feeder.feed(offsetUs: sleepUs, rttUs: 3000 - 2 * i);
      }
      expect(sync.debugPendingDiscontinuityCount, 0);
      expect(sync.isSynchronized, isTrue);
      expect(sync.needsHardResync, isTrue);
      expect(sync.offsetUs, sleepUs);
      expect(sync.bestRttUs, 2994);
      sync.acknowledgeHardResync();

      // The burst is over: steady samples at the adopted offset are normal.
      feeder.feed(offsetUs: sleepUs, rttUs: 3000);
      expect(sync.isSynchronized, isTrue);
      expect(sync.debugPendingDiscontinuityCount, 0);
    });

    test('a second jump after recovery is detected the same way', () {
      final sync = ClockSync();
      final feeder = Feeder(sync);
      feeder.feedBurst(offsetUs: 0, rttUs: 2000);

      for (final jump in [sleepUs, 2 * sleepUs]) {
        feeder.feed(offsetUs: jump, rttUs: 2000);
        feeder.feed(offsetUs: jump, rttUs: 2000); // confirms + burst #1
        expect(sync.isSynchronized, isFalse);
        sync.acknowledgeHardResync();
        for (var i = 0; i < 7; i++) {
          feeder.feed(offsetUs: jump, rttUs: 2000);
        }
        expect(sync.isSynchronized, isTrue);
        expect(sync.offsetUs, jump);
        expect(sync.needsHardResync, isFalse);
      }
    });
  });

  group('input validation', () {
    test('negative-RTT, t3 < t0 and t2 < t1 samples are dropped and '
        'counted', () {
      // Review repro R4: a pong whose host-side span exceeds the round trip
      // (rtt = -5000) read 40 ms off and, with the lowest "RTT", won the
      // join burst and pinned the floor at -5000.
      final sync = ClockSync();
      var t = 1000000000;
      for (var i = 0; i < 7; i++) {
        sync.addSample(sampleAt(t0: t, offsetUs: 0, rttUs: 3000));
        t += 1000;
      }
      sync.addSample(
        ClockSample(t0: t, t1: t + 40000, t2: t + 50000, t3: t + 5000),
      );
      expect(sync.malformedSampleCount, 1);
      expect(sync.offsetUs, 0);
      expect(sync.bestRttUs, 3000);
      expect(sync.rttFloorUs, 3000);

      // The local clock running backwards within a round trip, or the
      // host's: no real pair of clocks produces either.
      sync
        ..addSample(ClockSample(t0: t + 9000, t1: t, t2: t + 10, t3: t + 8000))
        ..addSample(ClockSample(t0: t, t1: t + 600, t2: t + 500, t3: t + 900));
      expect(sync.malformedSampleCount, 3);
      expect(sync.offsetUs, 0);
      expect(sync.bestRttUs, 3000);
    });

    test('a zero RTT (loopback, coarse clocks) is still a sample', () {
      final sync = ClockSync();
      Feeder(sync).feedBurst(offsetUs: 77, rttUs: 0);
      expect(sync.malformedSampleCount, 0);
      expect(sync.offsetUs, 77);
    });
  });

  group('jump detection evidence', () {
    test('a gate-accepted reading proves its disagreement minus half its '
        'RTT, not its face value', () {
      int pendingAfter(int offsetUs) {
        final sync = ClockSync();
        Feeder(sync)
          ..feedBurst(offsetUs: 0, rttUs: 2000)
          ..feed(offsetUs: offsetUs, rttUs: 3000);
        return sync.debugPendingDiscontinuityCount;
      }

      // 51 ms off, accepted at the gate's edge (3 ms RTT): the truth may be
      // 1.5 ms closer, so this proves 49.5 ms — not a jump candidate.
      expect(pendingAfter(51000), 0);
      // 52 ms off proves 50.5 ms: a candidate.
      expect(pendingAfter(52000), 1);
    });

    test(
      'a reading that cannot tell either way does not end a pending run',
      () {
        // Under heavy power save most pongs are delayed so much that they are
        // consistent with any estimate. Letting them clear a pending run kept
        // a poisoned join burst's 50+ ms error from ever being confirmed.
        final sync = ClockSync();
        final feeder = Feeder(sync, spacingUs: 2000000);
        feeder.feedBurst(offsetUs: 0, rttUs: 2000);
        feeder.feed(offsetUs: 100000, rttUs: 2000); // candidate
        expect(sync.debugPendingDiscontinuityCount, 1);
        // 120 ms RTT reading 50 ms: within reach of both 0 and 100 ms.
        feeder.feed(offsetUs: 50000, rttUs: 120000);
        expect(sync.debugPendingDiscontinuityCount, 1);
        feeder.feed(offsetUs: 100000, rttUs: 2000); // confirms
        expect(sync.needsHardResync, isTrue);
        expect(sync.offsetUs, 100000);
      },
    );

    test('a pending run expires after a minute without a verdict', () {
      final sync = ClockSync();
      final feeder = Feeder(sync, spacingUs: 2000000);
      feeder.feedBurst(offsetUs: 0, rttUs: 2000);
      feeder.feed(offsetUs: 100000, rttUs: 2000); // candidate
      for (var i = 0; i < 31; i++) {
        feeder.feed(offsetUs: 50000, rttUs: 120000); // inconclusive
      }
      feeder.feed(offsetUs: 100000, rttUs: 2000); // a new run, not a second
      expect(sync.debugPendingDiscontinuityCount, 1);
      expect(sync.needsHardResync, isFalse);
    });
  });

  group('applied mapping is continuous and monotonic', () {
    /// A deterministic, unkind stream: 150 ppm skew, a join burst queued
    /// 40 ms behind a power-save delay, ±0.5 ms noise, queued and spiked
    /// readings, a lucky one, and a 10-minute ping gap. Calls [check] after
    /// every sample with the sample's t3 and whether it was a hard resync.
    void runStream(
      ClockSync sync,
      void Function(int t3, int? before, bool resync) check,
    ) {
      var t3 = 900000000000;
      int truth(int local) => rampOffset(local, ppm: 150);
      for (var i = 0; i < 900; i++) {
        if (i == 400) t3 += 10 * 60 * 1000000; // ping gap
        final spike = i % 13 == 5 ? 80000 + (i * 37) % 200000 : 0;
        final queued = i % 7 == 3 ? 3000 + (i * 11) % 9000 : 0;
        final lucky = i == 300;
        final burstDelay = i < 8 ? 80000 : 0;
        final noise = ((i * 7919) % 1001) - 500;
        final rtt = lucky ? 600 : 3000 + spike + queued + burstDelay;
        // Extra delay sits on the downlink: the reading is low by half.
        final extra = rtt - 3000;
        final t0 = t3 - rtt;
        final mid = t0 + rtt ~/ 2;
        final offset = truth(mid) - extra ~/ 2 + (lucky ? 0 : noise);
        final oneWay = (rtt - extra) ~/ 2;
        final t1 = t0 + oneWay + offset;
        final before = sync.isSynchronized ? sync.localToHostUs(t3) : null;
        sync.addSample(
          ClockSample(t0: t0, t1: t1, t2: t1, t3: t0 + oneWay * 2 + extra),
        );
        final resync = sync.needsHardResync;
        sync.acknowledgeHardResync();
        check(t3, before, resync);
        t3 += i < 8 ? 300 : 2000000;
      }
    }

    test('a sample never moves the session time reported for its own t3, '
        'and localToHostUs never runs backwards between samples', () {
      final sync = ClockSync();
      var updates = 0;
      var resyncs = 0;
      int? previous;
      runStream(sync, (t3, before, resync) {
        if (resync) {
          resyncs++;
          previous = null;
          return;
        }
        if (before == null) return;
        updates++;
        expect(sync.localToHostUs(t3), before, reason: 'update at $t3');
        // Dense walk to (beyond) the next sample: strictly increasing.
        var last = sync.localToHostUs(t3);
        if (previous != null) expect(last, greaterThan(previous!));
        for (var dt = 50000; dt <= 2100000; dt += 50000) {
          final host = sync.localToHostUs(t3 + dt);
          expect(host, greaterThan(last), reason: '$dt µs after $t3');
          last = host;
        }
        previous = sync.localToHostUs(t3 + 1);
      });
      expect(updates, greaterThan(850));
      expect(resyncs, lessThanOrEqualTo(1), reason: 'the queued join burst');
    });

    test('the stream keeps the mapping busy correcting', () {
      // Counter-check that the stream above exercises corrections at all:
      // the estimate and the applied offset at t3 differ after most
      // samples, i.e. the mapping is mid-slew most of the time.
      final sync = ClockSync();
      var midSlew = 0;
      runStream(sync, (t3, before, resync) {
        if (!sync.isSynchronized) return;
        if ((sync.debugEstimateUs! - sync.offsetUs!).abs() > 1) midSlew++;
      });
      expect(midSlew, greaterThan(300));
    });

    test('the conversions invert each other to 1 µs before, during and '
        'after a slew', () {
      final sync = ClockSync(ewmaAlpha: 1.0, maxSkewPpm: 0);
      final feeder = Feeder(sync);
      feeder.feedBurst(offsetUs: 0, rttUs: 2000);
      final t3 = feeder.nextT3;
      feeder.feed(offsetUs: -8000, rttUs: 2000); // 8 s of slew at 1 ms/s
      // Closed form: offset(t) = -min(8000, (t - t3) / 1000) after t3.
      int expectedLocal(int host) {
        // host = t + offset(t), slope 0.999 during the slew.
        if (host <= t3) return host;
        final slewEndHost = t3 + 8000000 - 8000;
        if (host <= slewEndHost) return t3 + ((host - t3) / 0.999).round();
        return host + 8000;
      }

      for (var dt = -3000000; dt <= 12000000; dt += 250000) {
        final local = t3 + dt;
        final host = sync.localToHostUs(local);
        expect(
          host,
          local - math.min(8000, math.max(0, dt) ~/ 1000),
          reason: '$dt',
        );
        expect((sync.hostToLocalUs(host) - local).abs(), lessThanOrEqualTo(1));
        final h = t3 + dt;
        expect((sync.hostToLocalUs(h) - expectedLocal(h)).abs(), lessThan(2));
        expect(
          (sync.localToHostUs(sync.hostToLocalUs(h)) - h).abs(),
          lessThanOrEqualTo(1),
        );
      }
    });
  });

  group('acceptedSampleCount', () {
    // The evidence a guest that distrusts its mapping (it just woke from a
    // device sleep) waits for: readings blended into the estimate since it
    // was last seeded.
    const sleepUs = 120000000;

    test('burst samples are not counted; gate-passing steady samples are, '
        'rejected and quarantined ones are not', () {
      final sync = ClockSync();
      final feeder = Feeder(sync);
      expect(sync.acceptedSampleCount, 0);
      feeder.feedBurst(offsetUs: 1000, rttUs: 2000); // floor 2000
      expect(sync.isSynchronized, isTrue);
      expect(sync.acceptedSampleCount, 0, reason: 'min-RTT, not gated');

      for (var i = 1; i <= 3; i++) {
        feeder.feed(offsetUs: 1000, rttUs: 2000);
        expect(sync.acceptedSampleCount, i);
      }
      feeder.feed(offsetUs: 1000, rttUs: 3002); // > 1.5x floor: rejected
      expect(sync.acceptedSampleCount, 3);
      feeder.feed(offsetUs: 1000 + sleepUs, rttUs: 2000); // jump candidate
      expect(sync.debugPendingDiscontinuityCount, 1);
      expect(sync.acceptedSampleCount, 3, reason: 'quarantined, not blended');
      feeder.feed(offsetUs: 1000, rttUs: 2000); // clears the run, accepted
      expect(sync.debugPendingDiscontinuityCount, 0);
      expect(sync.acceptedSampleCount, 4);
      // Malformed: dropped before anything else.
      sync.addSample(
        ClockSample(t0: feeder.nextT3, t1: 0, t2: 10, t3: feeder.nextT3 - 1),
      );
      expect(sync.malformedSampleCount, 1);
      expect(sync.acceptedSampleCount, 4);
    });

    test('a discontinuity resets it to 0; it counts again only after the '
        'fresh burst', () {
      final sync = ClockSync();
      final feeder = Feeder(sync);
      feeder.feedBurst(offsetUs: 1000, rttUs: 2000);
      for (var i = 0; i < 5; i++) {
        feeder.feed(offsetUs: 1000, rttUs: 2000);
      }
      expect(sync.acceptedSampleCount, 5);

      const woke = 1000 + sleepUs;
      feeder.feed(offsetUs: woke, rttUs: 2000); // candidate
      expect(sync.acceptedSampleCount, 5);
      feeder.feed(offsetUs: woke, rttUs: 2000); // confirms: reset + burst #1
      expect(sync.isSynchronized, isFalse);
      expect(sync.acceptedSampleCount, 0);
      for (var i = 0; i < 7; i++) {
        feeder.feed(offsetUs: woke, rttUs: 2000); // the rest of the burst
      }
      expect(sync.isSynchronized, isTrue);
      expect(sync.acceptedSampleCount, 0);
      feeder.feed(offsetUs: woke, rttUs: 2000);
      expect(sync.acceptedSampleCount, 1);
    });

    test('a confirmed step (under the discontinuity threshold) re-seeds and '
        'resets it to 0', () {
      final sync = ClockSync();
      final feeder = Feeder(sync);
      feeder.feedBurst(offsetUs: 0, rttUs: 2000);
      for (var i = 0; i < 4; i++) {
        feeder.feed(offsetUs: 0, rttUs: 2000);
      }
      expect(sync.acceptedSampleCount, 4);

      feeder.feed(offsetUs: 200000, rttUs: 2000); // candidate
      expect(sync.acceptedSampleCount, 4);
      feeder.feed(offsetUs: 200000, rttUs: 2000); // confirms: a step
      expect(sync.isSynchronized, isTrue);
      expect(sync.needsHardResync, isTrue);
      expect(
        sync.acceptedSampleCount,
        0,
        reason:
            'the estimate restarted from the step; pre-step readings no '
            'longer back it',
      );
      feeder.feed(offsetUs: 200000, rttUs: 2000);
      expect(sync.acceptedSampleCount, 1);
    });

    test('a warm-up re-seed from a much better reading resets it to 0', () {
      final sync = ClockSync();
      final feeder = Feeder(sync, spacingUs: 2000000);
      feeder.feedBurst(offsetUs: -30000, rttUs: 80000); // queued burst
      // Readings at the burst's own quality are accepted and counted...
      feeder.feed(offsetUs: -30000, rttUs: 80000);
      expect(sync.acceptedSampleCount, 1);
      // ...until one with under half the seed's RTT proves it off: the
      // estimate is re-seeded from it, and only what follows counts.
      feeder.feed(offsetUs: 0, rttUs: 2000);
      expect(sync.debugEstimateUs, 0.0);
      expect(sync.acceptedSampleCount, 0);
      feeder.feed(offsetUs: 0, rttUs: 2000);
      expect(sync.acceptedSampleCount, 1);
    });
  });
}
