/// The surface [JamHostEngine] and [JamGuestEngine] share, so UI code (a
/// telemetry strip, a nudge slider, a progress bar) can be written once
/// against either side of a jam.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:localjam_audio/localjam_audio.dart';
import 'package:localjam_net/localjam_net.dart';

import 'audio_sync_controller.dart';
import 'engine_notifier.dart';
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

/// Why a jam ended for this side — published once on
/// [JamEngine.sessionEnded], so a player UI never hangs on a
/// "reconnecting…" banner forever. Guests see the first four (and
/// [closedLocally]); a host sees [listenerFailed] or [closedLocally].
enum JamSessionEndReason {
  /// Guest: the connection dropped and stayed in
  /// [JamConnectionState.reconnecting] for longer than
  /// `JamGuestEngine.hostGoneTimeout` — or `hostAwayTimeout` when the host
  /// had said it was away (§3.5); the engine stopped the retries. The host
  /// is gone without having said so — a crash, a dead battery, a walk out of
  /// range (host death ends the room, PROTOCOL.md §10). A host that shuts
  /// down deliberately announces it and lands on [hostEnded] instead, in
  /// milliseconds; this timeout is the contract for silence, which is all a
  /// crash leaves behind. Copy: "The host disappeared" + Rejoin.
  hostGone,

  /// Guest: the host answered a (re)join with `reject` (§3.1) — e.g.
  /// `bad_token` after a host restart, or `full`/`version`/a reason from a
  /// later version. Immediate and final: no reject is ever retried.
  /// [JamGuestEngine.lastRejectReason] says which — the copy, and whether a
  /// manual rejoin could ever work, depend on it.
  rejected,

  /// Guest: the host removed this guest from the session (§5.6): a fatal
  /// `kicked` error, or a reconnect answered `reject { reason: kicked }`
  /// because this device was kicked while it was away. Immediate and final;
  /// the engine never auto-rejoins, and the UI must not offer to.
  kicked,

  /// Guest: the host ended the room on purpose and said so (§3.4
  /// `session_ended`): "End jam", not a crash. Immediate and final — the
  /// engine never waits out a host-gone timeout for a host that already
  /// said goodbye. Local playback ends exactly as on [hostGone]: output
  /// stops and the session's guards are released (see [JamEngine.sessionEnded]);
  /// cached audio is not touched.
  hostEnded,

  /// Host: the room's listening socket died — the OS reclaimed it while the
  /// app was suspended, or the network stack dropped it — and could not be
  /// reopened on the same port, so nobody new could join and no dropped
  /// guest could reconnect. The engine ended the room (guests still on
  /// their sockets got `session_ended`) rather than keep showing a QR
  /// nobody can use. Copy: "The room stopped accepting connections — start
  /// a new one". The app still calls [JamEngine.close].
  listenerFailed,

  /// Either side: [JamEngine.close] was called locally (on a host: the host
  /// ended the jam, and guests got `session_ended`, §3.4). Usually the
  /// app's own doing — nothing to show.
  closedLocally,
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

  // --- Intents: transport and queue -----------------------------------------
  //
  // The side-appropriate route for what the user asked: hosts mutate the
  // authoritative state directly, guests send §5.2/§5.6 requests the host
  // validates. Written against [JamEngine] so shared surfaces (the OS media
  // session, one queue UI, shared player widgets) drive either side
  // identically.
  //
  // Each answers whether it took effect (host) or reached the host (guest):
  // false while a guest cannot send ([JamGuestEngine.canSendCommands] —
  // reconnecting, or the host's phone asleep), after the session ended, or
  // for a media id that is not in the queue. None ever throws. A guest's
  // request may still be refused by the host (§5.6 `not_allowed`, on
  // [JamGuestEngine.errors]); the next state broadcast is the authoritative
  // answer either way.

  /// Starts (or resumes) playback — and, since "play" is the user asking to
  /// hear the room, ends a local output suspension too
  /// ([resumeLocalOutput]) and plays on whatever route this device is on
  /// now, even one its headphones were unplugged from while paused
  /// ([AudioSyncController.acceptCurrentRoute]). Sends nothing when the
  /// room already plays (a play while playing would re-anchor everyone);
  /// true then.
  Future<bool> transportPlay();

  /// Pauses playback.
  Future<bool> transportPause();

  /// Skips to the next queue item (wrapping).
  Future<bool> transportNext();

  /// Skips to the previous queue item (wrapping).
  Future<bool> transportPrevious();

  /// Seeks to [positionUs] (clamped to the item's duration, §5.5).
  Future<bool> transportSeek(int positionUs);

  /// Selects [mediaId] as the current track (§5.1, §5.2 `set_media`),
  /// keeping the room doing what it was doing: a playing room (or one
  /// holding a start) plays it from its start — through the §6.3 readiness
  /// gate, so the start may be held — and a paused or idle room cues it.
  /// Selecting the current track changes nothing; starting it over is
  /// [transportSeek] to 0.
  Future<bool> transportSetMedia(String mediaId);

  /// Moves [mediaId] to queue position [toIndex] (clamped, §5.6).
  Future<bool> queueMove(String mediaId, int toIndex);

  /// Removes [mediaId] from the queue (§5.6). Your own contributions are
  /// always removable; others' need [JamCapability.editQueue] (see
  /// [canRemove]). Removing the current item advances.
  Future<bool> queueRemove(String mediaId);

  /// Whether this side may remove [item]: [JamCapability.editQueue], or it
  /// being this side's own contribution (§5.6).
  bool canRemove(MediaItem item) =>
      can(JamCapability.editQueue) || item.addedBy == selfPeerId;

  /// Adds [file] to the queue and says what that did ([JamAddResult]: media
  /// ids are content hashes, so re-adding the same bytes is answered with
  /// the item already there — [JamAddOutcome.alreadyQueued], worth saying
  /// "already in the queue" about). A host registers the file in place
  /// (§6.1); a guest uploads it (§6.4, progress on
  /// [JamGuestEngine.uploadProgress]).
  ///
  /// Unlike the intents above this throws: [FileSystemException] for a file
  /// that cannot be read, and on a guest [JamNotConnectedException] while
  /// it cannot send, [HttpException] for an upload the host refused
  /// (401/413/...), [TimeoutException] when the host stops answering.
  Future<JamAddResult> addMedia(File file, {String? name});

  /// A short display label for the peer who added [item], for "added by"
  /// bylines: "You", the host's name (falling back to "Host" when it has no
  /// identity to share), a peer's clientName — [unnamedLabel] for a peer in
  /// the room that shared none — or null when unattributed or the
  /// contributor already left. [peers] is the caller's current peer list
  /// (engines expose their own).
  ///
  /// The host gets a name like everyone else: "added by Silky Puffin", not
  /// "added by Host". Host is what they DO in the room, not who they are,
  /// and every room has exactly one — a byline that says it names nobody.
  ///
  /// Never a peer id: that is a wire token ("p_7f3a…"), and a byline that
  /// prints one is machine text on a screen about people. Apps pass their
  /// own copy as [unnamedLabel]; null leaves an unnamed contributor
  /// unlabelled, like one who left.
  String? addedByLabel(
    MediaItem item,
    List<PeerInfo> peers, {
    String? unnamedLabel = 'Guest',
  }) {
    final addedBy = item.addedBy;
    if (addedBy == null) return null;
    if (addedBy == selfPeerId) return 'You';
    if (addedBy == JamPermissions.hostPeerId) {
      final name = hostPeer?.clientName.trim() ?? '';
      return name.isEmpty ? 'Host' : name;
    }
    for (final peer in peers) {
      if (peer.peerId == addedBy) {
        final name = peer.clientName.trim();
        return name.isEmpty ? unnamedLabel : name;
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

  /// Non-null while THIS device's output is suspended — a call or another
  /// app took the audio, the headphones went away, the native engine failed
  /// ([JamOutputSuspendReason]) — while the room plays on. Nothing schedules
  /// audio in that state; it ends when the OS ends an interruption with its
  /// resume hint ([JamOutputSuspension.mayAutoResume]) or on
  /// [resumeLocalOutput]. UI should offer "Resume audio" whenever this is
  /// non-null.
  ValueListenable<JamOutputSuspension?> get outputSuspension =>
      sync.outputSuspension;

  /// Every change of [outputSuspension] (null = output follows the room
  /// again).
  Stream<JamOutputSuspension?> get outputSuspensionChanges =>
      sync.outputSuspensionChanges;

  /// Ends a local output suspension and re-anchors this device to wherever
  /// the room is now (§5.3 late-join path). A no-op when not suspended. Never
  /// touches the room: on a guest it sends nothing to the host.
  Future<void> resumeLocalOutput() => sync.resumeLocalOutput();

  // --- Session end ----------------------------------------------------------

  final ValueNotifier<JamSessionEndReason?> _sessionEnded =
      EngineValueNotifier<JamSessionEndReason?>(null);
  bool _engineStateDisposed = false;

  /// The session's terminal state: null while it is (or may come back)
  /// alive, then set exactly once ([JamSessionEndReason]). Render a terminal
  /// screen on anything but [JamSessionEndReason.closedLocally] — distinct
  /// from a guest's transient [JamConnectionState.reconnecting] banner,
  /// which its host-gone timeout guarantees cannot last forever. After an
  /// end the engine has stopped by itself: this device's output is silent
  /// and stays so (no snapshot, player event, nudge or [resumeLocalOutput]
  /// schedules audio again), and the session guards are released — the
  /// keep-alive (Android's foreground service and wake/Wi-Fi locks), the OS
  /// media card, the lifecycle observer. What a terminal screen reads
  /// (snapshot, playlist, peers) stays readable; the app still calls
  /// [close].
  ValueListenable<JamSessionEndReason?> get sessionEnded => _sessionEnded;

  /// Publishes the terminal [reason] — first writer wins.
  @protected
  void publishSessionEnd(JamSessionEndReason reason) {
    if (_engineStateDisposed || _sessionEnded.value != null) return;
    _sessionEnded.value = reason;
  }

  /// Releases the listenables this base class owns ([sessionEnded],
  /// [nudgeUs]). Engines call it last thing in [close].
  @protected
  void disposeEngineState() {
    if (_engineStateDisposed) return;
    _engineStateDisposed = true;
    _nudgeLoadSeq++; // Nothing still in flight may write to them.
    _nudgeUs.dispose();
    _sessionEnded.dispose();
  }

  // --- Manual nudge (§7) ----------------------------------------------------

  final ValueNotifier<int> _nudgeUs = EngineValueNotifier<int>(0);

  /// The manual sync nudge (µs, §7): positive plays audio earlier. Updated by
  /// [setNudgeUs], by the persisted-value restore at engine startup and by
  /// every output-route change (each device has its own), so UI controls
  /// should listen rather than read once.
  ValueListenable<int> get nudgeUs => _nudgeUs;

  /// Applies a manual nudge (µs, §7) and, with [persist] (the default),
  /// stores it for the output route it was set on via [LatencyPrefs]. Pass
  /// `persist: false` for high-rate updates (e.g. while a slider drags) and
  /// persist once at the end.
  Future<void> setNudgeUs(int offsetUs, {bool persist = true}) async {
    // The user's value beats a per-route reload still in flight.
    _nudgeLoadSeq++;
    // The route the user is listening on as they set it: a route change
    // during the awaits below must not file this value under the new device.
    final routeId = _nudgeRouteKnown
        ? _nudgeRouteId
        : await LatencyPrefs.currentRouteId(player);
    await sync.setManualOffsetUs(offsetUs);
    if (_engineStateDisposed) return;
    _nudgeUs.value = offsetUs;
    if (!persist) return;
    try {
      await LatencyPrefs.save(routeId, offsetUs);
    } catch (_) {
      // Prefs unavailable (tests, headless): the nudge still applies live.
    }
  }

  StreamSubscription<String?>? _routeSub;
  int _nudgeLoadSeq = 0;

  /// The output route [nudgeUs] belongs to, once known: what [setNudgeUs]
  /// persists under.
  String? _nudgeRouteId;
  bool _nudgeRouteKnown = false;
  int _nudgeRouteEvents = 0;

  /// Restores the persisted nudge for the current output route, and from
  /// then on re-loads it whenever the route changes (§7: the nudge belongs
  /// to the output device — Bluetooth headphones need theirs, the speaker
  /// its own). Called once by engine factories after the controller exists;
  /// [stopSessionGuards] stops the following.
  @protected
  Future<void> restorePersistedNudge() async {
    _routeSub ??= sync.routeChanges.listen(_onRouteChanged);
    final seq = ++_nudgeLoadSeq;
    final events = _nudgeRouteEvents;
    final routeId = await LatencyPrefs.currentRouteId(player);
    // A route event meanwhile knows better than this answer.
    if (_nudgeRouteEvents != events) return;
    _nudgeRouteId = routeId;
    _nudgeRouteKnown = true;
    // The user's own nudge meanwhile beats the saved one.
    if (seq != _nudgeLoadSeq) return;
    await _applySavedNudge(routeId, seq);
  }

  void _onRouteChanged(String? routeId) {
    if (_engineStateDisposed) return;
    _nudgeRouteEvents++;
    _nudgeRouteId = routeId;
    _nudgeRouteKnown = true;
    // Coalesced: the route change already has its own re-apply pending in
    // the controller, which carries this value — one re-anchor, not two.
    unawaited(_applySavedNudge(routeId, ++_nudgeLoadSeq, coalesce: true));
  }

  /// Applies the nudge saved for [routeId], 0 for a route that has none. A
  /// newer load or a [setNudgeUs] (a newer [seq]) supersedes it.
  Future<void> _applySavedNudge(
    String? routeId,
    int seq, {
    bool coalesce = false,
  }) async {
    try {
      final offsetUs = await LatencyPrefs.load(routeId);
      if (seq != _nudgeLoadSeq) return;
      await sync.setManualOffsetUs(offsetUs, coalesce: coalesce);
      if (seq != _nudgeLoadSeq) return;
      _nudgeUs.value = offsetUs;
    } catch (_) {
      // Prefs unavailable: keep whatever applies now.
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
    // the flag closes the race against a fast stopSessionGuards). Not in a
    // browser: a listener page keeps no history, and the store is files.
    if (!_historyWanted && !kIsWeb) {
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
    _nudgeLoadSeq++; // Drop any per-route reload still in flight.
    final routeSub = _routeSub;
    _routeSub = null;
    await routeSub?.cancel();
  }

  /// Handles one app-lifecycle transition; the engine's own observer feeds
  /// this, and tests can call it directly. On [AppLifecycleState.resumed]
  /// the sync controller re-verifies playback against the authoritative
  /// snapshot ([AudioSyncController.reverifySync]): the OS may have
  /// suspended or killed audio while the app was backgrounded, so the
  /// snapshot is re-applied when the player state is stale.
  /// [AppLifecycleState.hidden]/[AppLifecycleState.paused] — the app left
  /// the screen, and the OS may suspend it — reach [onAppBackgrounded].
  @visibleForTesting
  Future<void> handleLifecycleState(AppLifecycleState state) async {
    switch (state) {
      case AppLifecycleState.resumed:
        await onAppResumed();
      case AppLifecycleState.hidden || AppLifecycleState.paused:
        await onAppBackgrounded();
      case AppLifecycleState.inactive || AppLifecycleState.detached:
        break;
    }
  }

  /// Called when the app leaves the screen (hidden, then paused — so twice
  /// per trip to the background; implementations must be idempotent). The
  /// base implementation does nothing; a host announces it may be away
  /// (§3.5). Subclasses must call super.
  @protected
  @mustCallSuper
  Future<void> onAppBackgrounded() async {}

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
  ///
  /// The engine's listenables are released too, but stay safe to hold: each
  /// keeps its last value readable, and a listener added after close (a
  /// widget that mounts while a sheet animates out) is simply never called.
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
