import 'package:localjam_core/src/session/drift_policy.dart';
import 'package:test/test.dart';

void main() {
  const policy = DriftPolicy(); // 15 ms / 50 ms / 0.5 %

  DriftAction decide(int errorUs) =>
      policy.decide(expectedPositionUs: 10_000_000, actualPositionUs: 10_000_000 + errorUs);

  group('DriftPolicy boundaries', () {
    test('zero error -> DriftNone', () {
      expect(decide(0), const DriftNone());
    });

    test('just below the ignore threshold -> DriftNone', () {
      expect(decide(14_999), const DriftNone());
      expect(decide(-14_999), const DriftNone());
    });

    test('exactly 15 ms falls on the slew side (spec: "< 15 ms: ignore")', () {
      // 15_000 / 0.005 = 3_000_000 us of slewing.
      expect(
        decide(15_000),
        const DriftSlew(rateMultiplier: 0.995, durationUs: 3_000_000),
      );
      expect(
        decide(-15_000),
        const DriftSlew(rateMultiplier: 1.005, durationUs: 3_000_000),
      );
    });

    test('exactly 50 ms falls on the slew side (spec: "> 50 ms: resync")', () {
      // 50_000 / 0.005 = 10_000_000 us of slewing.
      expect(
        decide(50_000),
        const DriftSlew(rateMultiplier: 0.995, durationUs: 10_000_000),
      );
      expect(
        decide(-50_000),
        const DriftSlew(rateMultiplier: 1.005, durationUs: 10_000_000),
      );
    });

    test('just above 50 ms -> hard resync with the signed error', () {
      expect(decide(50_001), const DriftHardResync(errorUs: 50_001));
      expect(decide(-50_001), const DriftHardResync(errorUs: -50_001));
    });

    test('large error -> hard resync', () {
      expect(decide(2_000_000), const DriftHardResync(errorUs: 2_000_000));
    });
  });

  group('DriftPolicy slew direction and duration', () {
    test('client ahead (actual > expected) slows down', () {
      final action = decide(30_000) as DriftSlew;
      expect(action.rateMultiplier, 1 - policy.correctionRate); // 0.995
      expect(action.rateMultiplier, lessThan(1));
    });

    test('client behind (actual < expected) speeds up', () {
      final action = decide(-30_000) as DriftSlew;
      expect(action.rateMultiplier, 1 + policy.correctionRate); // 1.005
      expect(action.rateMultiplier, greaterThan(1));
    });

    test('durationUs = |error| / correctionRate', () {
      // 20 ms at 0.5% -> 4 s (worked example from the docs).
      expect((decide(20_000) as DriftSlew).durationUs, 4_000_000);
      expect((decide(-20_000) as DriftSlew).durationUs, 4_000_000);
      // 33_333 / 0.005 = 6_666_600.
      expect((decide(33_333) as DriftSlew).durationUs, 6_666_600);
    });

    test('slewing for durationUs at the multiplier closes the gap', () {
      final action = decide(40_000) as DriftSlew;
      // Position gained relative to nominal over the slew window:
      final closedUs = (action.durationUs * (action.rateMultiplier - 1)).round();
      expect(closedUs, -40_000); // exactly cancels a +40 ms (ahead) error
    });
  });

  group('DriftPolicy custom tunables', () {
    test('custom thresholds and rate are honored', () {
      const custom = DriftPolicy(
        ignoreBelowUs: 5_000,
        hardResyncAboveUs: 100_000,
        correctionRate: 0.01,
      );
      expect(
        custom.decide(expectedPositionUs: 0, actualPositionUs: 4_999),
        const DriftNone(),
      );
      expect(
        custom.decide(expectedPositionUs: 0, actualPositionUs: 5_000),
        const DriftSlew(rateMultiplier: 0.99, durationUs: 500_000),
      );
      expect(
        custom.decide(expectedPositionUs: 0, actualPositionUs: 100_001),
        const DriftHardResync(errorUs: 100_001),
      );
    });
  });
}
