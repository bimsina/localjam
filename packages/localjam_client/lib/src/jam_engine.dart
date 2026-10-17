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
import 'jam_history.dart';
import 'latency_prefs.dart';
import 'media_session_controller.dart';
import 'session_keepalive.dart';

/// What adding a file to the queue actually did.
enum JamAddOutcome {
  /// The file was new to this jam and is now in the queue.
  added,

  /// The exact same bytes were already in the queue, so nothing changed.
  ///
  /// Media ids are content-derived, so "add" is idempotent by construction
  /// (§6.4) — the host answers 200 with the item it already had instead of
  /// 201 with a new one, and broadcasts no playlist. That is correct, and it
  /// is also indistinguishable from a silent failure to whoever just picked a
  /// file: nothing happened, and nothing said why. This is what lets the app
  /// say "already in the queue".
  alreadyQueued,
}

/// The outcome of one queue add, plus the item it resolved to.
@immutable
class JamAddResult {
  const JamAddResult(this.item, this.outcome);

  /// The authoritative item — the newly added one, or the one that was
  /// already there.
  final MediaItem item;

  /// What the add did.
  final JamAddOutcome outcome;

  /// Shorthand for the case the UI has to say something about.
  bool get alreadyQueued => outcome == JamAddOutcome.alreadyQueued;

  @override
  String toString() => 'JamAddResult(${item.mediaId}, ${outcome.name})';
}

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

  /// This side's peer id: the guest's assigned id, or the reserved
  /// [JamPermissions.hostPeerId] on a host.
  String get selfPeerId;

  /// The session id (§3.1).
  String get sessionId;

  /// The session's human-readable name (§3.1).
  String get sessionName;

  /// The OTHER peers currently in the room (never includes this side, and
  /// never the host — the host is not a joined peer, §5.6; see [hostPeer]).
  List<PeerInfo> get peers;

  /// The host as a person: the reserved [JamPermissions.hostPeerId] plus its
  /// display identity ("Silky Puffin"). A host engine describes itself; a
  /// guest reports what `welcome.host` carried (§3.1), which is null against
  /// a host that shares no identity. Rosters and bylines should prefer this
  /// name over the role word "Host".
  PeerInfo? get hostPeer;

  /// Where [item]'s bytes live locally right now, if anywhere: a host's
  /// source path, a guest's cache path once fetched. Null while not local.
  String? localPathFor(MediaItem item);

  /// The room's permission document (§5.6).
  JamPermissions get permissions;

  /// Permission-document changes (§5.6).
  Stream<JamPermissions> get permissionUpdates;

  /// This side's effective capabilities — what UI controls should enable.
  /// Always everything on a host.
  Set<JamCapability> get myCapabilities =>
      permissions.capabilitiesOf(selfPeerId);

  /// Whether this side may exercise [capability] right now (§5.6). The host
  /// re-validates guest requests regardless — this is for enabling UI.
  bool can(JamCapability capability) => myCapabilities.contains(capability);

  // --- Transport intents ----------------------------------------------------
  //
  // The side-appropriate route for "the user hit play": hosts mutate the
  // authoritative state directly, guests send §5.2 requests the host
  // validates. Written against [JamEngine] so shared surfaces (the OS media
  // session, shared player widgets) drive either side identically.

  /// Starts (or resumes) playback.
  Future<void> transportPlay();

  /// Pauses playback.
  Future<void> transportPause();

  /// Skips to the next queue item (wrapping).
  Future<void> transportNext();

  /// Skips to the previous queue item (wrapping).
  Future<void> transportPrevious();

  /// Seeks to [positionUs].
  Future<void> transportSeek(int positionUs);

  /// A short display label for the peer who added [item], for "added by"
  /// bylines: "You", the host's name (falling back to "Host" when it has no
  /// identity to share), a peer's clientName, or null when unattributed.
  /// [peers] is the caller's current peer list (engines expose their own).
  ///
  /// The host gets a name like everyone else: "added by Silky Puffin", not
  /// "added by Host". Host is what they DO in the room, not who they are,
  /// and every room has exactly one — a byline that says it names nobody.
  String? addedByLabel(MediaItem item, List<PeerInfo> peers) {
    final addedBy = item.addedBy;
    if (addedBy == null) return null;
    if (addedBy == selfPeerId) return 'You';
    if (addedBy == JamPermissions.hostPeerId) {
      final name = hostPeer?.clientName.trim() ?? '';
      return name.isEmpty ? 'Host' : name;
    }
    for (final peer in peers) {
      if (peer.peerId == addedBy) {
        return peer.clientName.isEmpty ? peer.peerId : peer.clientName;
      }
    }
    return null; // The contributor already left.
  }

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
  JamMediaSessionController? _mediaSessionController;
  JamHistoryRecorder? _historyRecorder;
  bool _historyWanted = false;

  /// The live OS media-session controller, while the session guards are up.
  @visibleForTesting
  JamMediaSessionController? get mediaSessionController =>
      _mediaSessionController;

  /// Provides the history store the session guards record into. The default
  /// opens the persistent platform store; tests and embedders can inject
  /// their own (or `() async => null` to disable recording).
  static Future<JamHistoryStore?> Function() historyStoreProvider =
      JamHistoryStore.open;

  /// The live history recorder, once the store opened.
  @visibleForTesting
  JamHistoryRecorder? get historyRecorder => _historyRecorder;

  /// Whether the engine's app-lifecycle observer is currently registered.
  @visibleForTesting
  bool get lifecycleObserverAttached => _lifecycleObserver != null;

  /// Whether the OS-level keep-alive is actually held ([JamKeepAlive.active],
  /// which is also listenable). False on platforms that have none, and on an
  /// Android that refused the foreground service — a host in that state loses
  /// its server the moment the app is backgrounded, which is worth telling
  /// the user about.
  bool get keepAliveActive => JamKeepAlive.active.value;

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
      // The OS may refuse (Android 12+ blocks background foreground-service
      // starts): the session runs on regardless — see [keepAliveActive].
      await JamKeepAlive.acquire();
    }
    // OS media session: lock-screen/notification metadata + transport.
    _mediaSessionController ??= JamMediaSessionController(this)..start();
    // Jam history: record the session as it unfolds (store opens async —
    // the flag closes the race against a fast stopSessionGuards).
    if (!_historyWanted) {
      _historyWanted = true;
      unawaited(() async {
        final store = await historyStoreProvider();
        if (store == null || !_historyWanted || _historyRecorder != null) {
          return;
        }
        _historyRecorder = JamHistoryRecorder(this, store)..start();
      }());
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
    final mediaSession = _mediaSessionController;
    _mediaSessionController = null;
    await mediaSession?.dispose();
    _historyWanted = false;
    final history = _historyRecorder;
    _historyRecorder = null;
    await history?.dispose();
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
  /// re-verifies sync and re-pushes the OS media card (the OS may have
  /// dropped it during a long background stay); subclasses may extend it
  /// (and must call super).
  @protected
  @mustCallSuper
  Future<void> onAppResumed() async {
    await sync.reverifySync();
    _mediaSessionController?.refresh();
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
