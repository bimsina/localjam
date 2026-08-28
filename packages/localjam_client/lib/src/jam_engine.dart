/// The surface [JamHostEngine] and [JamGuestEngine] share, so UI code (a
/// telemetry strip, a nudge slider, a progress bar) can be written once
/// against either side of a jam.
library;

import 'package:flutter/foundation.dart';
import 'package:localjam_audio/localjam_audio.dart';
import 'package:localjam_net/localjam_net.dart';

import 'audio_sync_controller.dart';
import 'latency_prefs.dart';

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
