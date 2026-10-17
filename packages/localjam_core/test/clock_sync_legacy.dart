/// A frozen copy of the pre-2026-10-17 `ClockSync` algorithm, kept only so
/// the clock simulation tests can show, side by side, the scenarios the old
/// estimator failed. Not a test file itself (no `_test` suffix).
///
/// Behaviour is identical to the old implementation: an **all-time** minimum
/// RTT anchors a 1.5× acceptance gate, accepted samples blend into a plain
/// EWMA (α = 0.1) with no frequency term, the applied offset is constant
/// between samples, and discontinuity detection only looks at gate-accepted
/// samples.
library;

import 'package:localjam_core/src/clock/clock_simulation.dart';
import 'package:localjam_core/src/clock/clock_sync.dart';

class LegacyClockSync implements ClockSimEstimator {
  final int burstSize = 8;
  final int minSamplesForSync = 4;
  final double rttGateFactor = 1.5;
  final double ewmaAlpha = 0.1;
  final int maxSlewUsPerSecond = 1000;
  final int hardResyncThresholdUs = 50000;
  final int discontinuityThresholdUs = 500000;
  final int discontinuityConfirmations = 2;

  int _sampleCount = 0;
  int? _bestRttUs;
  int? _burstBestOffsetUs;
  int? _burstBestRttUs;
  double? _estimateUs;
  double? _appliedUs;
  int? _lastT3;
  bool _needsHardResync = false;
  int? _pendingOffsetUs;
  int _pendingCount = 0;

  @override
  bool get isSynchronized => _appliedUs != null;

  @override
  bool get needsHardResync => _needsHardResync;

  @override
  void acknowledgeHardResync() => _needsHardResync = false;

  @override
  int localToHostUs(int localTimeUs) => localTimeUs + _appliedUs!.round();

  @override
  void addSample(ClockSample sample) {
    final rtt = sample.rttUs;
    final verdict = _classify(sample, rtt);
    if (verdict == 2) _reset();
    _sampleCount++;
    if (_bestRttUs == null || rtt < _bestRttUs!) _bestRttUs = rtt;
    if (_sampleCount <= burstSize) {
      if (_burstBestRttUs == null || rtt < _burstBestRttUs!) {
        _burstBestRttUs = rtt;
        _burstBestOffsetUs = sample.offsetUs;
      }
      if (_sampleCount >= minSamplesForSync) {
        _estimateUs = _burstBestOffsetUs!.toDouble();
        _appliedUs = _estimateUs;
      }
    } else {
      _steady(sample, rtt, quarantined: verdict == 1);
    }
    _lastT3 = sample.t3;
  }

  /// 0 = normal, 1 = candidate, 2 = confirmed discontinuity.
  int _classify(ClockSample sample, int rtt) {
    final estimate = _estimateUs;
    if (estimate == null || _sampleCount < burstSize) return 0;
    if (rtt > rttGateFactor * _bestRttUs!) return 0;
    final offset = sample.offsetUs;
    if ((offset - estimate).abs() <= discontinuityThresholdUs) {
      _pendingOffsetUs = null;
      _pendingCount = 0;
      return 0;
    }
    final pending = _pendingOffsetUs;
    if (pending == null ||
        (offset - pending).abs() > discontinuityThresholdUs) {
      _pendingOffsetUs = offset;
      _pendingCount = 1;
    } else {
      _pendingCount++;
    }
    return _pendingCount >= discontinuityConfirmations ? 2 : 1;
  }

  void _reset() {
    _sampleCount = 0;
    _bestRttUs = null;
    _burstBestOffsetUs = null;
    _burstBestRttUs = null;
    _estimateUs = null;
    _appliedUs = null;
    _lastT3 = null;
    _pendingOffsetUs = null;
    _pendingCount = 0;
    _needsHardResync = true;
  }

  void _steady(ClockSample sample, int rtt, {required bool quarantined}) {
    if (!quarantined && rtt <= rttGateFactor * _bestRttUs!) {
      _estimateUs = _estimateUs! + ewmaAlpha * (sample.offsetUs - _estimateUs!);
    }
    final error = _estimateUs! - _appliedUs!;
    if (error.abs() > hardResyncThresholdUs) {
      _appliedUs = _estimateUs;
      _needsHardResync = true;
      return;
    }
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
}
