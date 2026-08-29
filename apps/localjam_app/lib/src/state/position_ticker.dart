/// A frame-synced playback position, so a scrubber can move smoothly without
/// any screen rebuilding itself four times a second.
///
/// [JamEngine] has no position stream — `positionUsNow()` is a pull-based
/// computation off the playback anchor. The pre-overhaul screens handled that
/// with `Timer.periodic(250ms)` + `setState`, repainting the entire tree.
/// This publishes the same value as a [ValueListenable] instead, so only the
/// widgets that actually show time rebuild.
///
/// The ticker runs only while playback is running. That is both cheaper and
/// correct for a host on battery in a vehicle: a [Ticker] is driven by the
/// scheduler, so it stops on its own when the app is backgrounded and the OS
/// stops pumping frames.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:localjam_client/localjam_client.dart';

/// Publishes [JamEngine.positionUsNow] every frame while playing.
///
/// The value is null when no media is selected — the same contract as
/// [JamEngine.positionUsNow].
class JamPositionTicker extends ValueNotifier<int?> {
  JamPositionTicker(this._engine) : super(_engine.positionUsNow()) {
    _ticker = Ticker(_onTick);
    _statesSub = _engine.states.listen(_onSnapshot);
    _engine.loadedDurationUs.addListener(_refresh);
    _syncRunning();
  }

  final JamEngine _engine;
  late final Ticker _ticker;
  StreamSubscription<PlaybackSnapshot>? _statesSub;
  bool _disposed = false;

  void _onTick(Duration _) => _refresh();

  void _onSnapshot(PlaybackSnapshot snapshot) {
    // Publish the new anchor immediately rather than waiting for a frame:
    // a pause lands on the exact position the host stopped at.
    _refresh();
    _syncRunning();
  }

  void _refresh() {
    if (_disposed) return;
    value = _engine.positionUsNow();
  }

  /// Runs the ticker only while the session is actually advancing.
  void _syncRunning() {
    if (_disposed) return;
    final shouldRun = _engine.snapshot.status == PlaybackStatus.playing;
    if (shouldRun && !_ticker.isActive) {
      _ticker.start();
    } else if (!shouldRun && _ticker.isActive) {
      _ticker.stop();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_statesSub?.cancel());
    _statesSub = null;
    _engine.loadedDurationUs.removeListener(_refresh);
    _ticker
      ..stop()
      ..dispose();
    super.dispose();
  }
}
