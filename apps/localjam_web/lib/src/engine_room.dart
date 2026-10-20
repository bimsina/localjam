/// The live [ListenerRoom]: a `JamGuestEngine` joined from the page
/// (PROTOCOL.md §3.1 `clientKind: "web"`), its media in memory
/// (`JamMemoryMediaStore`, WEB_GUEST.md D7), `ready` only after a decode
/// (§3.1), and its many streams and listenables folded into one
/// [ChangeNotifier] for the page.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:localjam_client/localjam_client.dart';

import 'room.dart';

/// Joins a jam and hands back the room, or throws: `JamRejectedException`
/// for a refusal (§3.1), a transport error or `TimeoutException` when the
/// host cannot be reached. The page injects this so tests can fake it.
typedef RoomJoiner = Future<ListenerRoom> Function(Uri joinUri, String name);

/// The audio plugin's channel, for the web-only `setMuted` method.
const MethodChannel _audioChannel = MethodChannel('localjam_audio');

/// Wakes the page's audio inside a user gesture: the `AudioContext` is
/// created and `resume()`d (and on iOS the `<audio>` route started) by the
/// first plugin call that needs it, synchronously, so this must run in the
/// tap handler itself, before any `await` (localjam_audio README, "Web").
void unlockAudioInGesture() {
  unawaited(
    LocaljamAudio().outputLatencyUs().then((_) {}, onError: (Object _) {}),
  );
}

/// Joins [joinUri] as a browser guest named [name].
Future<ListenerRoom> joinEngineRoom(Uri joinUri, String name) async {
  final engine = await JamGuestEngine.join(
    joinUri,
    clientName: name,
    clientKind: 'web',
    // D7: the current track and the next, in memory; the store's budget
    // never evicts either.
    prefetchPolicy: const JamPrefetchPolicy(aheadCount: 1),
  );
  return EngineRoom(engine, name);
}

/// A [ListenerRoom] over a live [JamGuestEngine].
class EngineRoom extends ChangeNotifier implements ListenerRoom {
  EngineRoom(this.engine, this.myName) {
    _subs = [
      engine.states.listen((_) => _changed()),
      engine.playlistUpdates.listen((_) => _changed()),
      engine.connectionStates.listen((_) => _changed()),
      engine.permissionUpdates.listen((_) => _changed()),
      engine.peerEvents.listen((_) => _changed()),
      engine.outputSuspensionChanges.listen((_) => _changed()),
    ];
    for (final listenable in _listenables) {
      listenable.addListener(_changed);
    }
    // The clock has no stream: look until it has synchronized.
    _clockWatch = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (engine.clockSynced != _clockSynced) {
        _clockSynced = engine.clockSynced;
        _changed();
      }
    });
  }

  /// The engine behind this room.
  final JamGuestEngine engine;

  @override
  final String myName;

  late final List<StreamSubscription<Object?>> _subs;
  late final Timer _clockWatch;
  bool _clockSynced = false;
  bool _muted = false;
  bool _left = false;

  List<Listenable> get _listenables => [
    engine.prefetchStates,
    engine.hostAway,
    engine.sessionEnded,
    engine.nudgeUs,
    engine.loadedDurationUs,
  ];

  void _changed() {
    if (!_left) notifyListeners();
  }

  @override
  String get jamName => engine.sessionName;

  @override
  String get selfPeerId => engine.selfPeerId;

  @override
  PeerInfo? get hostPeer => engine.hostPeer;

  @override
  List<PeerInfo> get peers => engine.peers;

  @override
  PlaybackSnapshot get snapshot => engine.snapshot;

  @override
  List<MediaItem> get queue => engine.playlist;

  @override
  Map<String, JamPrefetchState> get prefetch => engine.prefetchStates.value;

  @override
  JamConnectionState get connection => engine.connectionState;

  @override
  bool get hostAway => engine.hostAway.value;

  @override
  bool get clockSynced => engine.clockSynced;

  @override
  bool get canControl => engine.can(JamCapability.controlPlayback);

  @override
  JamOutputSuspension? get outputSuspension => engine.outputSuspension.value;

  @override
  JamSessionEndReason? get endReason => engine.sessionEnded.value;

  @override
  RejectReason? get rejectReason => engine.lastRejectReason;

  @override
  int get nudgeUs => engine.nudgeUs.value;

  @override
  Future<void> setNudgeUs(int offsetUs, {bool persist = true}) =>
      engine.setNudgeUs(offsetUs, persist: persist);

  @override
  bool get muted => _muted;

  @override
  Future<void> setMuted(bool muted) async {
    _muted = muted;
    _changed();
    try {
      await _audioChannel.invokeMethod<void>('setMuted', {'muted': muted});
    } on MissingPluginException {
      // Not a browser: there is no page-level mute.
    } on PlatformException {
      // Best effort.
    }
  }

  @override
  int? positionUsNow() => engine.positionUsNow();

  @override
  int? get durationUs =>
      engine.loadedDurationUs.value ?? engine.currentItem?.durationUs;

  @override
  Future<Uint8List?> artworkFor(MediaItem item) => engine.artworkFor(item);

  @override
  String? addedByLabel(MediaItem item) =>
      engine.addedByLabel(item, engine.peers);

  @override
  Future<void> play() => engine.transportPlay();

  @override
  Future<void> pause() => engine.transportPause();

  @override
  Future<void> next() => engine.transportNext();

  @override
  Future<void> previous() => engine.transportPrevious();

  @override
  Future<void> select(String mediaId) => engine.transportSetMedia(mediaId);

  @override
  Future<void> resumeAudio() {
    unlockAudioInGesture();
    return engine.resumeLocalOutput();
  }

  @override
  bool retryFetch(String mediaId) => engine.retryFetch(mediaId);

  @override
  Future<void> leave() async {
    if (_left) return;
    _left = true;
    _clockWatch.cancel();
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    for (final listenable in _listenables) {
      listenable.removeListener(_changed);
    }
    // The page's gain outlives the room: a rejoin starts audible.
    if (_muted) await setMuted(false);
    await engine.close();
  }

  @override
  void dispose() {
    unawaited(leave());
    super.dispose();
  }
}
