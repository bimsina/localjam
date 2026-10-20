/// A scriptable [ListenerRoom] for widget tests: every field is mutable,
/// [changed] notifies, and every action is recorded in [calls].
library;

import 'package:flutter/foundation.dart';
import 'package:localjam_client/localjam_client.dart';
import 'package:localjam_web/src/room.dart';

MediaItem track(
  String id, {
  String? title,
  String? artist,
  int durationUs = 180000000,
}) => MediaItem(
  mediaId: id,
  kind: MediaKind.audio,
  name: '$id.mp3',
  mime: 'audio/mpeg',
  sizeBytes: 1000,
  durationUs: durationUs,
  sha256: 'a' * 64,
  title: title,
  artist: artist,
);

const JamPrefetchState readyState = JamPrefetchState(
  phase: JamPrefetchPhase.ready,
  progress: 1,
  path: 'memory:x',
);

class FakeRoom extends ChangeNotifier implements ListenerRoom {
  FakeRoom({
    this.jamName = 'Road Trip',
    List<MediaItem>? queue,
    PlaybackSnapshot? snapshot,
    Map<String, JamPrefetchState>? prefetch,
    this.canControl = false,
  }) : queue = queue ?? [track('m_a', title: 'Night Drive', artist: 'Kai')],
       snapshot =
           snapshot ??
           const PlaybackSnapshot(
             rev: 3,
             status: PlaybackStatus.playing,
             mediaId: 'm_a',
             anchor: PlaybackAnchor(hostTimeUs: 0, positionUs: 0),
           ),
       prefetch = prefetch ?? {'m_a': readyState};

  final List<String> calls = [];

  @override
  String jamName;
  @override
  String selfPeerId = 'p_me';
  @override
  String myName = 'Neon Walrus';
  @override
  PeerInfo? hostPeer = const PeerInfo(
    peerId: 'host',
    clientName: 'Silky Puffin',
    clientKind: 'flutter',
  );
  @override
  List<PeerInfo> peers = const [
    PeerInfo(peerId: 'p_2', clientName: 'Mia', clientKind: 'flutter'),
  ];
  @override
  PlaybackSnapshot snapshot;
  @override
  List<MediaItem> queue;
  @override
  Map<String, JamPrefetchState> prefetch;
  @override
  JamConnectionState connection = JamConnectionState.connected;
  @override
  bool hostAway = false;
  @override
  bool clockSynced = true;
  @override
  bool canControl;
  @override
  JamOutputSuspension? outputSuspension;
  @override
  JamSessionEndReason? endReason;
  @override
  RejectReason? rejectReason;
  @override
  int nudgeUs = 0;
  @override
  bool muted = false;
  @override
  int? durationUs = 180000000;

  void changed() => notifyListeners();

  @override
  Future<void> setNudgeUs(int offsetUs, {bool persist = true}) async {
    calls.add('nudge $offsetUs${persist ? '' : ' (live)'}');
    nudgeUs = offsetUs;
    notifyListeners();
  }

  @override
  Future<void> setMuted(bool muted) async {
    calls.add('muted $muted');
    this.muted = muted;
    notifyListeners();
  }

  @override
  int? positionUsNow() => 42000000;

  @override
  Future<Uint8List?> artworkFor(MediaItem item) async => null;

  @override
  String? addedByLabel(MediaItem item) => null;

  @override
  Future<void> play() async => calls.add('play');

  @override
  Future<void> pause() async => calls.add('pause');

  @override
  Future<void> next() async => calls.add('next');

  @override
  Future<void> previous() async => calls.add('previous');

  @override
  Future<void> select(String mediaId) async => calls.add('select $mediaId');

  @override
  Future<void> resumeAudio() async => calls.add('resume');

  @override
  Future<void> leave() async => calls.add('leave');
}
