/// Sample-accurate scheduled audio playback for LocalJam clients.
///
/// The whole point of this plugin is ONE capability ordinary audio players
/// lack: **start playback of a local file at an exact future instant of the
/// platform's monotonic clock** (PROTOCOL.md §5.3), plus precise position
/// readback and micro rate adjustment for drift correction (§5.4).
///
/// Clock domains: the native side runs on its own monotonic clock
/// ("native time", µs). [calibrate] measures the offset between Dart's
/// monotonic clock (the one `localjam_net` uses for session-clock mapping)
/// and native time with a min-RTT burst over the method channel, so callers
/// can convert session time → Dart-local time → native time.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';

/// Offset between Dart's monotonic clock and the native audio clock:
/// `nativeUs = dartLocalUs + offsetUs`.
class NativeClockCalibration {
  const NativeClockCalibration({required this.offsetUs, required this.rttUs});

  final int offsetUs;

  /// Round-trip of the winning (minimum-RTT) sample; a quality indicator.
  final int rttUs;
}

/// Scheduled audio player backed by the platform's audio engine
/// (AVAudioEngine on iOS/macOS, ExoPlayer/Oboe on Android).
///
/// One instance = one loaded file at a time. All times are int microseconds.
class LocaljamAudio {
  LocaljamAudio({@visibleForTesting MethodChannel? channel})
      : _ch = channel ?? const MethodChannel('localjam_audio');

  final MethodChannel _ch;

  /// Current native monotonic time (µs). Cheap; used by [calibrate].
  Future<int> nativeNowUs() async => (await _ch.invokeMethod<int>('nowUs'))!;

  /// Measures Dart-monotonic ↔ native-clock offset with [samples] round trips,
  /// keeping the minimum-RTT sample: offset = nativeNow - (t0+t3)/2.
  /// Callers supply [dartNowUs] (e.g. `monotonicNowUs` from localjam_net) so
  /// the Dart side of the measurement shares the caller's timebase.
  Future<NativeClockCalibration> calibrate(
    int Function() dartNowUs, {
    int samples = 10,
  }) async {
    var bestRtt = 1 << 62;
    var bestOffset = 0;
    for (var i = 0; i < samples; i++) {
      final t0 = dartNowUs();
      final native = await nativeNowUs();
      final t3 = dartNowUs();
      final rtt = t3 - t0;
      if (rtt < bestRtt) {
        bestRtt = rtt;
        bestOffset = native - (t0 + (rtt ~/ 2));
      }
    }
    return NativeClockCalibration(offsetUs: bestOffset, rttUs: bestRtt);
  }

  /// Loads a local audio file; returns its duration in µs.
  /// Replaces any previously loaded file (stops playback first).
  Future<int> load(String filePath) async =>
      (await _ch.invokeMethod<int>('load', {'path': filePath}))!;

  /// Schedules playback of the loaded file to be at media position
  /// [positionUs] exactly when the native clock reads [nativeTimeUs],
  /// playing at [rate].
  ///
  /// If [nativeTimeUs] is already in the past, starts immediately at the
  /// correspondingly advanced position (late join, §5.3).
  Future<void> playAt({
    required int nativeTimeUs,
    required int positionUs,
    double rate = 1.0,
  }) =>
      _ch.invokeMethod<void>('playAt', {
        'nativeTimeUs': nativeTimeUs,
        'positionUs': positionUs,
        'rate': rate,
      });

  /// Pauses playback, keeping the loaded file.
  Future<void> pause() => _ch.invokeMethod<void>('pause');

  /// Stops and discards playback state (file stays loaded).
  Future<void> stop() => _ch.invokeMethod<void>('stop');

  /// Current playback position (µs), derived from the engine's sample time —
  /// NOT a cached value. Null when nothing is playing or scheduled.
  Future<int?> positionUs() => _ch.invokeMethod<int>('positionUs');

  /// Adjusts playback rate without re-anchoring (drift slew, §5.4).
  /// Implementations must keep pitch unaffected for small changes
  /// (|rate - 1| <= 0.01) if the platform allows.
  Future<void> setRate(double rate) =>
      _ch.invokeMethod<void>('setRate', {'rate': rate});

  /// The platform-reported output latency (µs) of the current route
  /// (§7 calibration starting point). 0 when unknown.
  Future<int> outputLatencyUs() async =>
      (await _ch.invokeMethod<int>('outputLatencyUs')) ?? 0;

  /// Releases the native engine.
  Future<void> dispose() => _ch.invokeMethod<void>('dispose');
}
