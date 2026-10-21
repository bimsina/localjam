/// What the room view reads and does, behind one interface: [EngineRoom]
/// wraps a live `JamGuestEngine`, and widget tests drive a fake. Plus the
/// one place the page decides what to say about sync (PROTOCOL.md §3–§6):
/// [RoomStatus.of].
library;

import 'package:flutter/foundation.dart';
import 'package:localjam_client/localjam_client.dart';

/// A joined jam, as the page sees it. Notifies on every change worth a
/// rebuild (state, playlist, people, permissions, prefetch, connection,
/// nudge, mute, end); the playback position is read on demand.
abstract class ListenerRoom implements Listenable {
  /// The jam's name (§3.1 `welcome.sessionName`).
  String get jamName;

  /// This guest's peer id (§3.1).
  String get selfPeerId;

  /// The name this guest joined with.
  String get myName;

  /// The host as a person (§3.1 `welcome.host`); null when it shares none.
  PeerInfo? get hostPeer;

  /// The other guests (never this one, never the host).
  List<PeerInfo> get peers;

  /// The authoritative playback state (§5.1).
  PlaybackSnapshot get snapshot;

  /// The playlist, which is the queue (§6.1, §5.6).
  List<MediaItem> get queue;

  /// Prefetch state per media id (§6.2): ready, fetching, unplayable here.
  Map<String, JamPrefetchState> get prefetch;

  /// The control connection (§3.3).
  JamConnectionState get connection;

  /// The host said its phone may be asleep (§3.5).
  bool get hostAway;

  /// The session clock has synchronized (§4).
  bool get clockSynced;

  /// The room's permission document grants this guest `control_playback`
  /// (§5.6): play, pause, skip and select.
  bool get canControl;

  /// Non-null while this page's own output is held (the browser suspended
  /// audio, or refused to start it).
  JamOutputSuspension? get outputSuspension;

  /// Set once the jam is over for this page (§3.4, §3.1, §5.6).
  JamSessionEndReason? get endReason;

  /// For an end by refusal (§3.1): which reject.
  RejectReason? get rejectReason;

  /// The manual sync nudge in µs (§7): positive plays earlier.
  int get nudgeUs;

  /// Sets the nudge; [persist] stores it for this page (§7).
  Future<void> setNudgeUs(int offsetUs, {bool persist = true});

  /// Whether this page's sound is muted (locally; the room plays on).
  bool get muted;

  /// Mutes or unmutes this page's sound.
  Future<void> setMuted(bool muted);

  /// Where playback should be now (µs), clamped to the duration (§5.5).
  int? positionUsNow();

  /// The current item's duration (µs), once known.
  int? get durationUs;

  /// Cover bytes for [item] (§6.5), fetched once.
  Future<Uint8List?> artworkFor(MediaItem item);

  /// "Added by" text for [item] (§6.1, `welcome.host` naming), or null.
  String? addedByLabel(MediaItem item);

  /// §5.2 requests (answered by the next state broadcast).
  Future<void> play();
  Future<void> pause();
  Future<void> next();
  Future<void> previous();
  Future<void> select(String mediaId);

  /// Restarts this page's sound after the browser held it, re-joining the
  /// room's timeline. Call from a tap: it is a user gesture.
  Future<void> resumeAudio();

  /// Fetches [mediaId] again after its automatic retries ran out (§6.2);
  /// false when there is nothing to retry.
  bool retryFetch(String mediaId);

  /// Leaves the jam and releases everything.
  Future<void> leave();
}

/// The display name for the host (§3.1: `welcome.host`, else the role).
String hostDisplayName(PeerInfo? host) {
  final name = host?.clientName.trim() ?? '';
  return name.isEmpty ? 'Host' : name;
}

/// What the sync line says, from most to least urgent.
enum RoomStatusKind {
  /// Playing, on the room's timeline.
  synced,

  /// The room is idle, paused or cued: nothing to hear yet.
  waitingForHost,

  /// The current song is still on its way (§6.2), or being decoded.
  fetching,

  /// The current song's download (or decode check) failed. While it is
  /// retried on its own the line says so; once the retries ran out it
  /// offers a retry instead ([RoomStatus.retryable]).
  fetchFailed,

  /// The current song cannot play in this browser (§3.1): a format it
  /// cannot decode, or too big or too long to hold in a tab.
  cantPlay,

  /// The session clock is not synchronized yet (§4).
  syncing,

  /// The browser is holding this page's audio (suspended, or refused).
  audioHeld,

  /// The control connection dropped; reconnecting (§3.3).
  reconnecting,

  /// The host said its phone may be asleep (§3.5).
  hostAsleep,
}

/// One line of plain language about how listening is going.
@immutable
class RoomStatus {
  const RoomStatus(
    this.kind,
    this.text, {
    this.progress,
    this.retryable = false,
  });

  final RoomStatusKind kind;
  final String text;

  /// Download progress in [0, 1] for [RoomStatusKind.fetching].
  final double? progress;

  /// A [RoomStatusKind.fetchFailed] that nothing will retry on its own: the
  /// page offers "Try Again" ([ListenerRoom.retryFetch]).
  final bool retryable;

  /// Whether this is trouble worth a glyph (anything but synced/waiting).
  bool get isProblem =>
      kind != RoomStatusKind.synced && kind != RoomStatusKind.waitingForHost;

  static const String _synced = 'Playing in sync';
  static const String _waiting = 'Waiting for the host to play';
  static const String _paused = 'Paused by the host';
  static const String _nothing = 'Waiting for the host to add music';
  static const String _fetching = 'Getting this song…';
  static const String _fetchFailed = "Couldn't get this song. Trying again…";
  static const String _fetchGaveUp = "Couldn't get this song";
  static const String _cantPlay = "Can't play this song in this browser";
  static const String _tooLong = 'This song is too long to play in a browser';
  static const String _tooBig = 'This song is too big to play in a browser';
  static const String _syncing = 'Syncing with the room…';
  static const String _audioHeld = 'Sound paused on this page';
  static const String _reconnecting = 'Reconnecting…';
  static const String _hostAsleep = "The host's phone is asleep";

  /// The status line for [room] right now.
  static RoomStatus of(ListenerRoom room) {
    if (room.hostAway) {
      return const RoomStatus(RoomStatusKind.hostAsleep, _hostAsleep);
    }
    if (room.connection != JamConnectionState.connected) {
      return const RoomStatus(RoomStatusKind.reconnecting, _reconnecting);
    }
    final snapshot = room.snapshot;
    final current = snapshot.mediaId;
    if (current == null || snapshot.status == PlaybackStatus.idle) {
      return RoomStatus(
        RoomStatusKind.waitingForHost,
        room.queue.isEmpty ? _nothing : _waiting,
      );
    }
    final state = room.prefetch[current];
    if (state?.phase == JamPrefetchPhase.unplayable) {
      return RoomStatus(RoomStatusKind.cantPlay, switch (state!.error) {
        JamMediaStore.tooLong => _tooLong,
        JamMediaStore.tooLarge => _tooBig,
        _ => _cantPlay,
      });
    }
    if (snapshot.status != PlaybackStatus.playing) {
      return RoomStatus(
        RoomStatusKind.waitingForHost,
        snapshot.status == PlaybackStatus.paused ? _paused : _waiting,
      );
    }
    if (state == null || !state.ready) {
      if (state?.phase == JamPrefetchPhase.failed) {
        // Say "trying again" only while something will.
        return state!.willRetry
            ? const RoomStatus(RoomStatusKind.fetchFailed, _fetchFailed)
            : const RoomStatus(
                RoomStatusKind.fetchFailed,
                _fetchGaveUp,
                retryable: true,
              );
      }
      return RoomStatus(
        RoomStatusKind.fetching,
        _fetching,
        progress: state?.phase == JamPrefetchPhase.fetching
            ? state!.progress
            : null,
      );
    }
    if (room.outputSuspension != null) {
      return const RoomStatus(RoomStatusKind.audioHeld, _audioHeld);
    }
    if (!room.clockSynced) {
      return const RoomStatus(RoomStatusKind.syncing, _syncing);
    }
    return const RoomStatus(RoomStatusKind.synced, _synced);
  }
}
