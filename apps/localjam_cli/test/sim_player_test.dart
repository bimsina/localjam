import 'package:localjam_cli/src/sim_player.dart';
import 'package:localjam_cli/src/tui.dart';
import 'package:localjam_core/localjam_core.dart';
import 'package:test/test.dart';

PlaybackSnapshot _playing({
  int rev = 1,
  int anchorHostTimeUs = 0,
  int anchorPositionUs = 0,
  double rate = 1.0,
}) =>
    PlaybackSnapshot(
      rev: rev,
      status: PlaybackStatus.playing,
      mediaId: 'm_test',
      anchor: PlaybackAnchor(
        hostTimeUs: anchorHostTimeUs,
        positionUs: anchorPositionUs,
      ),
      positionUs: anchorPositionUs,
      rate: rate,
    );

void main() {
  group('SimPlayer playhead', () {
    test('advances at the skewed rate while playing', () {
      final sim = SimPlayer(skewPpm: 10000); // +1%
      final snap = _playing();

      // First tick adopts the snapshot (rev change): playhead -> positionAt.
      sim.tick(snapshot: snap, sessionNowUs: 0, elapsedUs: 0);
      expect(sim.positionUs, 0);

      // 1 s of wall time -> 1.01 s of playhead.
      final action =
          sim.tick(snapshot: snap, sessionNowUs: 1_000_000, elapsedUs: 1_000_000);
      expect(sim.positionUs, 1_010_000);
      // 10 ms of drift is below the 15 ms ignore floor.
      expect(action, const DriftNone());
      expect(sim.lastDriftUs, 10_000);
    });

    test('stays pinned at the anchor position during the scheduled lead-in',
        () {
      final sim = SimPlayer();
      final snap = _playing(anchorHostTimeUs: 750_000, anchorPositionUs: 5000);
      sim.tick(snapshot: snap, sessionNowUs: 0, elapsedUs: 0);
      sim.tick(snapshot: snap, sessionNowUs: 500_000, elapsedUs: 500_000);
      expect(sim.positionUs, 5000); // Still waiting for the start.
      // Crossing the anchor: only time past it counts as playback.
      sim.tick(snapshot: snap, sessionNowUs: 1_000_000, elapsedUs: 500_000);
      expect(sim.positionUs, 5000 + 250_000);
      expect(sim.lastDriftUs, 0);
    });

    test('a new rev adopts the snapshot (snap + cancel slew)', () {
      final sim = SimPlayer();
      sim.tick(snapshot: _playing(), sessionNowUs: 0, elapsedUs: 0);
      sim.debugSetPositionUs(20_000); // Force a slew to start.
      final action = sim.tick(snapshot: _playing(), sessionNowUs: 0, elapsedUs: 0);
      expect(action, isA<DriftSlew>());
      expect(sim.isSlewing, isTrue);

      final paused = PlaybackSnapshot(
        rev: 2,
        status: PlaybackStatus.paused,
        mediaId: 'm_test',
        positionUs: 123_456,
      );
      sim.tick(snapshot: paused, sessionNowUs: 1_000_000, elapsedUs: 1_000_000);
      expect(sim.positionUs, 123_456);
      expect(sim.isSlewing, isFalse);
      expect(sim.lastAction, const DriftNone());
    });
  });

  group('SimPlayer drift correction', () {
    test('slew closes an injected 20 ms gap within the expected duration', () {
      final sim = SimPlayer(); // No skew: the slew does all the work.
      final snap = _playing();
      sim.tick(snapshot: snap, sessionNowUs: 0, elapsedUs: 0);

      // Advance 1 s in sync, then push the playhead 20 ms ahead.
      sim.tick(snapshot: snap, sessionNowUs: 1_000_000, elapsedUs: 1_000_000);
      sim.debugSetPositionUs(sim.positionUs + 20_000);

      final action =
          sim.tick(snapshot: snap, sessionNowUs: 1_000_000, elapsedUs: 0);
      expect(
        action,
        const DriftSlew(rateMultiplier: 0.995, durationUs: 4_000_000),
      );
      expect(sim.slews, 1);

      // 20 ms at 0.5% takes 4 s to close (plus re-decides on the way down);
      // tick 250 ms at a time for 5 s and require full convergence.
      var now = 1_000_000;
      for (var i = 0; i < 20; i++) {
        now += 250_000;
        sim.tick(snapshot: snap, sessionNowUs: now, elapsedUs: 250_000);
      }
      expect(sim.lastDriftUs.abs(), lessThan(500));
      expect(sim.hardResyncs, 0);
      expect(sim.isSlewing, isFalse);
      // Re-issued slews while one was in progress extend the same episode.
      expect(sim.slews, 1);
    });

    test('slew speeds up when the playhead is behind', () {
      final sim = SimPlayer();
      final snap = _playing();
      sim.tick(snapshot: snap, sessionNowUs: 0, elapsedUs: 0);
      sim.tick(snapshot: snap, sessionNowUs: 1_000_000, elapsedUs: 1_000_000);
      sim.debugSetPositionUs(sim.positionUs - 30_000);

      final action =
          sim.tick(snapshot: snap, sessionNowUs: 1_000_000, elapsedUs: 0);
      expect(
        action,
        const DriftSlew(rateMultiplier: 1.005, durationUs: 6_000_000),
      );

      var now = 1_000_000;
      for (var i = 0; i < 28; i++) {
        now += 250_000;
        sim.tick(snapshot: snap, sessionNowUs: now, elapsedUs: 250_000);
      }
      expect(sim.lastDriftUs.abs(), lessThan(500));
      expect(sim.hardResyncs, 0);
    });

    test('hard resync snaps the playhead to the expected position', () {
      final sim = SimPlayer();
      final snap = _playing();
      sim.tick(snapshot: snap, sessionNowUs: 0, elapsedUs: 0);
      sim.tick(snapshot: snap, sessionNowUs: 1_000_000, elapsedUs: 1_000_000);
      sim.debugSetPositionUs(sim.positionUs + 100_000); // 100 ms: way out.

      final action =
          sim.tick(snapshot: snap, sessionNowUs: 1_000_000, elapsedUs: 0);
      expect(action, const DriftHardResync(errorUs: 100_000));
      expect(sim.hardResyncs, 1);
      expect(sim.positionUs, 1_000_000); // Snapped back to expected.
      expect(sim.isSlewing, isFalse);

      // Next tick is clean again.
      final next =
          sim.tick(snapshot: snap, sessionNowUs: 1_250_000, elapsedUs: 250_000);
      expect(next, const DriftNone());
      expect(sim.lastDriftUs, 0);
    });

    test('does not correct while paused', () {
      final sim = SimPlayer();
      final paused = PlaybackSnapshot(
        rev: 1,
        status: PlaybackStatus.paused,
        mediaId: 'm_test',
        positionUs: 500_000,
      );
      sim.tick(snapshot: paused, sessionNowUs: 0, elapsedUs: 0);
      sim.debugSetPositionUs(999_000);
      final action =
          sim.tick(snapshot: paused, sessionNowUs: 250_000, elapsedUs: 250_000);
      expect(action, const DriftNone());
      expect(sim.positionUs, 999_000); // Frozen: no advance, no correction.
    });
  });

  group('position formatting', () {
    test('formats mm:ss.mmm', () {
      expect(formatPositionUs(0), '00:00.000');
      expect(formatPositionUs(65_432_100), '01:05.432');
      expect(formatPositionUs(999), '00:00.000'); // Sub-ms truncates.
      expect(formatPositionUs(3_600_000_000), '60:00.000'); // No hours field.
    });

    test('handles null and negative values', () {
      expect(formatPositionUs(null), '--:--.---');
      expect(formatPositionUs(-5000), '00:00.000');
    });

    test('formatSignedUs is explicitly signed', () {
      expect(formatSignedUs(0), '+0us');
      expect(formatSignedUs(1234), '+1234us');
      expect(formatSignedUs(-87), '-87us');
    });
  });
}
