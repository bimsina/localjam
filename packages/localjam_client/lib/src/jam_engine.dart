/// The surface [JamHostEngine] and [JamGuestEngine] share, so UI code (a
/// telemetry strip, a nudge slider, a progress bar) can be written once
/// against either side of a jam.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:localjam_audio/localjam_audio.dart';
import 'package:localjam_net/localjam_net.dart';

import 'audio_sync_controller.dart';
import 'latency_prefs.dart';
import 'session_keepalive.dart';

/// Common playback surface of a LocalJam engine (host or guest): the shared
/// [AudioSyncController], the authoritative snapshot/playlist, drift
/// telemetry, and the persisted manual sync nudge (PROTOCOL.md §7).
abstract class JamEngine {
  /// The scheduled-audio player. Owned (created and disposed) by the engine.
  LocaljamAudio get player;

  /// The sync controller following the authoritative snapshots.
  AudioSyncController get sync;

  /// The most recent authoritative playback snapshot (§5.1).
  PlaybackSnapshot get snapshot;

  /// Every authoritative state broadcast (§5.1).
  Stream<PlaybackSnapshot> get states;

  /// The current playlist (§6.1).
  List<MediaItem> get playlist;

  /// Playlist broadcasts (§6.1).
  Stream<List<MediaItem>> get playlistUpdates;

  /// Artwork bytes for [item] (§6.5), or null when the item has none or the
  /// bytes are unavailable (fetch failure, disconnected). Hosts read their
  /// own registry; guests fetch once and cache. Never throws.
  Future<Uint8List?> artworkFor(MediaItem item);

  /// The playlist entry for [snapshot]'s current media, if any.
  MediaItem? get currentItem {
    final mediaId = snapshot.mediaId;
    if (mediaId == null) return null;
    for (final item in playlist) {
      if (item.mediaId == mediaId) return item;
    }
    return null;
  }

  /// Drift self-checks while playing (§5.4), ~1 Hz, for telemetry UIs.
  Stream<DriftSample> get driftSamples => sync.driftSamples;

  /// The most recent drift self-check, if any.
  DriftSample? get lastDriftSample => sync.lastSample;

  /// True when the current track ran to its end locally (§5.5).
  ValueListenable<bool> get trackFinished => sync.trackFinished;

  /// Duration (µs) of the currently loaded media, once known.
  ValueListenable<int?> get loadedDurationUs => sync.loadedDurationUs;

  /// Last player/platform error, for surfacing in the UI.
  ValueListenable<String?> get lastPlayerError => sync.lastError;

  /// The manual sync nudge (µs, §7): positive plays audio earlier. Updated by
  /// [setNudgeUs] and by the persisted-value restore at engine startup, so UI
  /// controls should listen rather than read once.
  final ValueNotifier<int> nudgeUs = ValueNotifier<int>(0);

  /// Applies a manual nudge (µs, §7) and, with [persist] (the default),
  /// stores it for the current output route via [LatencyPrefs]. Pass
  /// `persist: false` for high-rate updates (e.g. while a slider drags) and
  /// persist once at the end.
  Future<void> setNudgeUs(int offsetUs, {bool persist = true}) async {
    await sync.setManualOffsetUs(offsetUs);
    nudgeUs.value = offsetUs;
    if (!persist) return;
    try {
      await LatencyPrefs.save(player, offsetUs);
    } catch (_) {
      // Prefs unavailable (tests, headless): the nudge still applies live.
    }
  }

  /// Restores the persisted nudge for the current output route. Called once
  /// by engine factories after the controller exists.
  @protected
  Future<void> restorePersistedNudge() async {
    try {
      final offsetUs = await LatencyPrefs.load(player);
      if (offsetUs == 0) return;
      await sync.setManualOffsetUs(offsetUs);
      nudgeUs.value = offsetUs;
    } catch (_) {
      // Prefs unavailable: start from 0.
    }
  }

  // --- App lifecycle guards ------------------------------------------------

  _EngineLifecycleObserver? _lifecycleObserver;
  bool _keepAliveHeld = false;

  /// Whether the engine's app-lifecycle observer is currently registered.
  @visibleForTesting
  bool get lifecycleObserverAttached => _lifecycleObserver != null;

  /// Starts the guards an active session needs to survive app lifecycle
  /// events:
  ///
  /// * registers a [WidgetsBindingObserver] so the engine re-verifies sync
  ///   (an immediate drift check, re-applying the snapshot when the player
  ///   state is stale) every time the app returns to the foreground — see
  ///   [AudioSyncController.reverifySync];
  /// * acquires the platform keep-alive ([JamKeepAlive]: on Android a
  ///   `mediaPlayback` foreground service + wake/Wi-Fi locks, elsewhere a
  ///   no-op) so playback — and, on a host, the server — keeps running while
  ///   backgrounded.
  ///
  /// Called once by engine factories when the session goes live; undone by
  /// [stopSessionGuards], which engines call from [close]. Both are
  /// idempotent, and both degrade to no-ops in bindings without a widgets
  /// layer (pure Dart embeddings, some tests).
  @protected
  Future<void> startSessionGuards() async {
    if (_lifecycleObserver == null) {
      final observer = _EngineLifecycleObserver(this);
      try {
        WidgetsBinding.instance.addObserver(observer);
        _lifecycleObserver = observer;
      } catch (_) {
        // No widgets binding: there are no lifecycle events to observe.
      }
    }
    if (!_keepAliveHeld) {
      _keepAliveHeld = true;
      await JamKeepAlive.acquire();
    }
  }

  /// Removes the lifecycle observer and releases the platform keep-alive.
  /// The counterpart of [startSessionGuards]; idempotent.
  @protected
  Future<void> stopSessionGuards() async {
    final observer = _lifecycleObserver;
    _lifecycleObserver = null;
    if (observer != null) {
      try {
        WidgetsBinding.instance.removeObserver(observer);
      } catch (_) {
        // Binding gone (test teardown): nothing left to unregister from.
      }
    }
    if (_keepAliveHeld) {
      _keepAliveHeld = false;
      await JamKeepAlive.release();
    }
  }

  /// Handles one app-lifecycle transition; the engine's own observer feeds
  /// this, and tests can call it directly. On [AppLifecycleState.resumed]
  /// the sync controller re-verifies playback against the authoritative
  /// snapshot ([AudioSyncController.reverifySync]): the OS may have
  /// suspended or killed audio while the app was backgrounded, so the
  /// snapshot is re-applied when the player state is stale.
  @visibleForTesting
  Future<void> handleLifecycleState(AppLifecycleState state) async {
    if (state != AppLifecycleState.resumed) return;
    await onAppResumed();
  }

  /// Called when the app returns to the foreground. The base implementation
  /// re-verifies sync; subclasses may extend it (and must call super).
  @protected
  @mustCallSuper
  Future<void> onAppResumed() => sync.reverifySync();

  /// The current session-clock time (µs), or null while it is unknown (a
  /// guest whose clock has not synchronized yet). Identity on the host.
  int? get sessionNowUsOrNull;

  /// Where playback is *expected* to be right now, clamped to the known
  /// duration (§5.5) — the value a progress bar wants. Null when no media is
  /// selected. Falls back to the snapshot's frozen position while the session
  /// clock is unknown.
  int? positionUsNow() {
    final current = snapshot;
    if (current.mediaId == null) return null;
    final now = sessionNowUsOrNull;
    if (now == null) return current.positionUs;
    return current.clampedPositionAt(
      now,
      durationUs: sync.loadedDurationUs.value ?? currentItem?.durationUs,
    );
  }

  /// Tears the engine down: controller, player, and transport. Idempotent.
  Future<void> close();
}

/// Forwards app-lifecycle transitions into a [JamEngine]. A separate object
/// (rather than mixing [WidgetsBindingObserver] into the engine) so the
/// observer surface never leaks into the engine's public API.
class _EngineLifecycleObserver with WidgetsBindingObserver {
  _EngineLifecycleObserver(this._engine);

  final JamEngine _engine;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    unawaited(_engine.handleLifecycleState(state));
  }
}
