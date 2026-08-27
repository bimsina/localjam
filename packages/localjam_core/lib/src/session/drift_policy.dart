import 'package:meta/meta.dart';

/// What a client should do about a measured playback drift (PROTOCOL.md §5.4).
@immutable
sealed class DriftAction {
  const DriftAction();
}

/// Error is below the audibility floor — leave playback alone.
@immutable
final class DriftNone extends DriftAction {
  const DriftNone();

  @override
  bool operator ==(Object other) => other is DriftNone;

  @override
  int get hashCode => (DriftNone).hashCode;
}

/// Correct by a bounded micro rate adjustment (inaudible).
///
/// Play at `nominalRate * rateMultiplier` for [durationUs] of session time,
/// then return to the nominal rate; the drift is then closed.
@immutable
final class DriftSlew extends DriftAction {
  const DriftSlew({required this.rateMultiplier, required this.durationUs});

  /// `1 - correctionRate` when the client is ahead (slow down),
  /// `1 + correctionRate` when behind (speed up).
  final double rateMultiplier;

  /// How long to hold the adjusted rate, in microseconds.
  final int durationUs;

  @override
  bool operator ==(Object other) =>
      other is DriftSlew &&
      other.rateMultiplier == rateMultiplier &&
      other.durationUs == durationUs;

  @override
  int get hashCode => Object.hash(rateMultiplier, durationUs);
}

/// Error too large to slew inaudibly — hard resync: pause locally, seek to
/// the anchor-derived position, rejoin playback (§5.4).
@immutable
final class DriftHardResync extends DriftAction {
  const DriftHardResync({required this.errorUs});

  /// Signed error, `actual - expected`, in microseconds
  /// (positive = client is ahead of the anchor).
  final int errorUs;

  @override
  bool operator ==(Object other) =>
      other is DriftHardResync && other.errorUs == errorUs;

  @override
  int get hashCode => errorUs.hashCode;
}

/// Client-side drift-correction policy (PROTOCOL.md §5.4):
///
/// * `|error| < 15 ms` — ignore.
/// * `15 ms <= |error| <= 50 ms` — micro rate adjustment of ±0.5 % for a
///   bounded interval (both boundaries fall on the slew side: the spec says
///   "< 15 ms: ignore" and "> 50 ms: hard resync", so exactly 15 ms and
///   exactly 50 ms are corrected by slewing).
/// * `|error| > 50 ms` — hard resync.
///
/// Pure and deterministic; call it from the client's ~1 Hz self-check with
/// the anchor-derived expected position and the player's actual position.
@immutable
class DriftPolicy {
  const DriftPolicy({
    this.ignoreBelowUs = 15_000,
    this.hardResyncAboveUs = 50_000,
    this.correctionRate = 0.005,
  });

  /// Errors strictly below this magnitude are ignored (default 15 ms).
  final int ignoreBelowUs;

  /// Errors strictly above this magnitude trigger a hard resync
  /// (default 50 ms).
  final int hardResyncAboveUs;

  /// Fractional rate adjustment used to slew (default 0.005 = ±0.5 %).
  final double correctionRate;

  /// Decide what to do given the anchor-derived [expectedPositionUs] and the
  /// player's measured [actualPositionUs] (both in media microseconds).
  ///
  /// Slew math: playing at `nominal * (1 ± r)` changes the position relative
  /// to the expected trajectory by `r` microseconds per microsecond of
  /// session time, so closing an error of magnitude `|e|` takes
  /// `durationUs = |e| / r` (rounded to the nearest integer µs). E.g. a
  /// 20 ms error at r = 0.005 slews for 20 000 / 0.005 = 4 000 000 µs = 4 s.
  /// The multiplier is `1 - r` when the client is ahead
  /// (actual > expected, so it must fall back) and `1 + r` when behind.
  DriftAction decide({
    required int expectedPositionUs,
    required int actualPositionUs,
  }) {
    final errorUs = actualPositionUs - expectedPositionUs;
    final magnitude = errorUs.abs();
    if (magnitude < ignoreBelowUs) return const DriftNone();
    if (magnitude > hardResyncAboveUs) return DriftHardResync(errorUs: errorUs);
    return DriftSlew(
      rateMultiplier: errorUs > 0 ? 1 - correctionRate : 1 + correctionRate,
      durationUs: (magnitude / correctionRate).round(),
    );
  }
}
