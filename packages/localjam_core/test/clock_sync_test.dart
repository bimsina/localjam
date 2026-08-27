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
}

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
    test('initial estimate is the offset of the minimum-RTT burst sample',
        () {
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

    test('estimate keeps refining (stepping) through the rest of the burst',
        () {
      final sync = ClockSync();
      final feeder = Feeder(sync);
      for (var i = 0; i < 4; i++) {
        feeder.feed(offsetUs: 1000, rttUs: 4000);
      }
      expect(sync.offsetUs, 1000);
      // A later burst sample with lower RTT replaces the initial estimate
      // outright — no slewing during the join burst.
      feeder.feed(offsetUs: -9000, rttUs: 2000);
      expect(sync.offsetUs, -9000);
      expect(sync.needsHardResync, isFalse);
    });

    test('bestRttUs is null before any sample', () {
      expect(ClockSync().bestRttUs, isNull);
    });
  });

  group('steady-state RTT gate', () {
    test('rejects samples with rtt > 1.5x best, accepts at the boundary', () {
      // alpha 1 + effectively unlimited slew make the applied offset mirror
      // the estimate, so acceptance is directly observable.
      final sync = ClockSync(ewmaAlpha: 1.0, maxSlewUsPerSecond: 1 << 40);
      final feeder = Feeder(sync);
      feeder.feedBurst(offsetUs: 0, rttUs: 2000); // best rtt = 2000

      feeder.feed(offsetUs: 30000, rttUs: 4000); // 4000 > 3000: rejected
      expect(sync.debugEstimateUs, 0.0);
      expect(sync.offsetUs, 0);

      feeder.feed(offsetUs: 30000, rttUs: 3000); // exactly 1.5x: accepted
      expect(sync.debugEstimateUs, 30000.0);
      expect(sync.offsetUs, 30000);
    });

    test('a new lower rtt tightens the gate reference', () {
      final sync = ClockSync(ewmaAlpha: 1.0, maxSlewUsPerSecond: 1 << 40);
      final feeder = Feeder(sync);
      feeder.feedBurst(offsetUs: 0, rttUs: 2000);
      feeder.feed(offsetUs: 0, rttUs: 1000); // new best
      expect(sync.bestRttUs, 1000);
      feeder.feed(offsetUs: 30000, rttUs: 2000); // 2000 > 1500: now rejected
      expect(sync.debugEstimateUs, 0.0);
    });
  });

  group('EWMA blending', () {
    test('converges toward a shifted true offset with alpha 0.1', () {
      final sync = ClockSync(maxSlewUsPerSecond: 1 << 40);
      final feeder = Feeder(sync);
      feeder.feedBurst(offsetUs: 0, rttUs: 2000);

      // True offset shifts to +10 000 µs; each accepted sample closes 10 %
      // of the remaining gap: estimate_n = 10000 * (1 - 0.9^n).
      var expected = 0.0;
      for (var n = 1; n <= 30; n++) {
        feeder.feed(offsetUs: 10000, rttUs: 2000);
        expected += 0.1 * (10000 - expected);
        expect(sync.debugEstimateUs, closeTo(expected, 1e-6));
      }
      // After 30 samples the estimate is within ~5 % of the true offset.
      expect(sync.debugEstimateUs, closeTo(10000, 500));
    });

    test('alpha is configurable', () {
      final sync = ClockSync(ewmaAlpha: 0.5, maxSlewUsPerSecond: 1 << 40);
      final feeder = Feeder(sync);
      feeder.feedBurst(offsetUs: 0, rttUs: 2000);
      feeder.feed(offsetUs: 8000, rttUs: 2000);
      expect(sync.debugEstimateUs, 4000.0);
    });
  });

  group('slewing', () {
    test('applied offset moves at most maxSlewUsPerSecond', () {
      // alpha 1 makes the raw estimate jump to 10 000 immediately (below the
      // 50 ms hard-resync threshold); samples are 1 s apart in t3, so the
      // applied offset may move at most 1000 µs per sample.
      final sync = ClockSync(ewmaAlpha: 1.0);
      final feeder = Feeder(sync, spacingUs: 1000000);
      feeder.feedBurst(offsetUs: 0, rttUs: 2000);

      for (var k = 1; k <= 10; k++) {
        feeder.feed(offsetUs: 10000, rttUs: 2000);
        expect(sync.offsetUs, 1000 * k, reason: 'after steady sample $k');
        expect(sync.needsHardResync, isFalse);
      }
      // Fully converged; further samples do not overshoot.
      feeder.feed(offsetUs: 10000, rttUs: 2000);
      expect(sync.offsetUs, 10000);
    });

    test('slew rate is configurable and works downward (negative error)', () {
      final sync = ClockSync(ewmaAlpha: 1.0, maxSlewUsPerSecond: 250);
      final feeder = Feeder(sync, spacingUs: 1000000);
      feeder.feedBurst(offsetUs: 0, rttUs: 2000);
      feeder.feed(offsetUs: -10000, rttUs: 2000);
      expect(sync.offsetUs, -250);
      feeder.feed(offsetUs: -10000, rttUs: 2000);
      expect(sync.offsetUs, -500);
    });

    test('elapsed time comes from consecutive t3 values', () {
      final sync = ClockSync(ewmaAlpha: 1.0);
      // 2 s between samples => up to 2000 µs of slew per sample.
      final feeder = Feeder(sync, spacingUs: 2000000);
      feeder.feedBurst(offsetUs: 0, rttUs: 2000);
      feeder.feed(offsetUs: 10000, rttUs: 2000);
      expect(sync.offsetUs, 2000);
    });

    test('gate-rejected samples still advance slewing', () {
      final sync = ClockSync(ewmaAlpha: 1.0);
      final feeder = Feeder(sync, spacingUs: 1000000);
      feeder.feedBurst(offsetUs: 0, rttUs: 2000);
      feeder.feed(offsetUs: 10000, rttUs: 2000); // accepted: est 10000
      expect(sync.offsetUs, 1000);
      feeder.feed(offsetUs: 0, rttUs: 100000); // rejected, but 1 s passed
      expect(sync.debugEstimateUs, 10000.0);
      expect(sync.offsetUs, 2000);
    });
  });

  group('hard resync', () {
    test('error above threshold steps immediately and sets the flag', () {
      final sync = ClockSync(ewmaAlpha: 1.0);
      final feeder = Feeder(sync, spacingUs: 1000000);
      feeder.feedBurst(offsetUs: 0, rttUs: 2000);
      expect(sync.needsHardResync, isFalse);

      feeder.feed(offsetUs: 100000, rttUs: 2000); // error 100 ms > 50 ms
      expect(sync.needsHardResync, isTrue);
      expect(sync.offsetUs, 100000); // stepped, not slewed
    });

    test('flag is consumable and does not re-fire without a new large error',
        () {
      final sync = ClockSync(ewmaAlpha: 1.0);
      final feeder = Feeder(sync, spacingUs: 1000000);
      feeder.feedBurst(offsetUs: 0, rttUs: 2000);
      feeder.feed(offsetUs: 100000, rttUs: 2000);
      expect(sync.needsHardResync, isTrue);

      sync.acknowledgeHardResync();
      expect(sync.needsHardResync, isFalse);

      feeder.feed(offsetUs: 100000, rttUs: 2000); // error now 0
      expect(sync.needsHardResync, isFalse);
      expect(sync.offsetUs, 100000);
    });

    test('threshold is configurable and fires on negative jumps too', () {
      final sync = ClockSync(ewmaAlpha: 1.0, hardResyncThresholdUs: 5000);
      final feeder = Feeder(sync, spacingUs: 1000000);
      feeder.feedBurst(offsetUs: 0, rttUs: 2000);
      feeder.feed(offsetUs: -6000, rttUs: 2000);
      expect(sync.needsHardResync, isTrue);
      expect(sync.offsetUs, -6000);
    });

    test('errors at or below threshold slew instead of stepping', () {
      final sync = ClockSync(ewmaAlpha: 1.0);
      final feeder = Feeder(sync, spacingUs: 1000000);
      feeder.feedBurst(offsetUs: 0, rttUs: 2000);
      feeder.feed(offsetUs: 50000, rttUs: 2000); // exactly the threshold
      expect(sync.needsHardResync, isFalse);
      expect(sync.offsetUs, 1000); // slewed
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
}
