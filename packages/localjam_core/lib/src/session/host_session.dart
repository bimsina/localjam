import 'playback_state.dart';

/// A guest's fetch state for a given media item (PROTOCOL.md §6.3
/// `media_status.state`).
enum MediaReadiness { none, fetching, ready }

/// The host's authoritative playback state machine (PROTOCOL.md §5).
///
/// Pure logic: no timers, no I/O, no clock reads. The caller supplies the
/// current session-clock time `nowUs` (host monotonic microseconds) to every
/// mutating call. Each mutation returns the new [PlaybackSnapshot] — which is
/// also retained as [snapshot] — so the caller can broadcast it verbatim.
///
/// Every mutation that changes state increments [PlaybackSnapshot.rev] by
/// exactly 1. A call documented as a no-op returns the current snapshot
/// unchanged (same rev), so callers can suppress redundant broadcasts by
/// comparing revs.
class HostSession {
  /// [leadTimeUs] is the scheduled-start lead applied by [play] and by
  /// [seek]-while-playing (PROTOCOL.md §5.3, default 750 ms): anchors are
  /// placed that far in the future so every guest can schedule the same
  /// sample-accurate start.
  HostSession({this.leadTimeUs = 750_000});

  /// Scheduled-start lead in microseconds (§5.3).
  final int leadTimeUs;

  PlaybackSnapshot _snapshot = PlaybackSnapshot.initial;

  /// The current authoritative snapshot. Starts at [PlaybackSnapshot.initial].
  PlaybackSnapshot get snapshot => _snapshot;

  /// Last reported `media_status` per peer: peerId -> (mediaId, readiness).
  /// Only the most recent report per peer is kept — readiness for a media
  /// item a peer reported earlier is superseded by any later report.
  final Map<String, ({String mediaId, MediaReadiness state})> _peerMedia = {};

  /// Peers currently in the session (present even before any media_status).
  final Set<String> _peers = {};

  // --- Playback mutations (§5.1–§5.3) ---------------------------------------

  /// Select a new media item: status becomes [PlaybackStatus.loading],
  /// position resets to 0, and any anchor is cleared. The host app should
  /// then wait for readiness (see [allPeersReady]) before calling [play].
  PlaybackSnapshot setMedia(String mediaId, {required int nowUs}) {
    return _snapshot = _snapshot.copyWith(
      rev: _snapshot.rev + 1,
      status: PlaybackStatus.loading,
      mediaId: mediaId,
      clearAnchor: true,
      positionUs: 0,
    );
  }

  /// Start (or resume) playback with a scheduled start: the new anchor is
  /// `(nowUs + leadTimeUs, currentPosition)` per §5.3.
  ///
  /// Valid from `loading`, `paused`, or `idle`-with-media, where the current
  /// position is the frozen [PlaybackSnapshot.positionUs]. If already
  /// `playing`, this re-anchors at the position the media will have reached
  /// at `nowUs` (a harmless re-schedule; still increments rev).
  ///
  /// Throws [StateError] if no media is selected.
  PlaybackSnapshot play({required int nowUs}) {
    if (_snapshot.mediaId == null) {
      throw StateError('play() with no media selected');
    }
    final position = _snapshot.positionAt(nowUs);
    return _snapshot = _snapshot.copyWith(
      rev: _snapshot.rev + 1,
      status: PlaybackStatus.playing,
      anchor: PlaybackAnchor(
        hostTimeUs: nowUs + leadTimeUs,
        positionUs: position,
      ),
      positionUs: position,
    );
  }

  /// Pause: freeze the position at `positionAt(nowUs)`, clear the anchor,
  /// status becomes [PlaybackStatus.paused].
  ///
  /// No-op if not currently playing (returns the current snapshot with the
  /// same rev): pausing while idle/loading/paused has nothing to freeze, and
  /// treating it as a mutation would broadcast a meaningless rev bump.
  PlaybackSnapshot pause({required int nowUs}) {
    if (_snapshot.status != PlaybackStatus.playing) return _snapshot;
    return _snapshot = _snapshot.copyWith(
      rev: _snapshot.rev + 1,
      status: PlaybackStatus.paused,
      clearAnchor: true,
      positionUs: _snapshot.positionAt(nowUs),
    );
  }

  /// Seek to [positionUs].
  ///
  /// While playing this is a scheduled re-anchor per §5.3:
  /// `(nowUs + leadTimeUs, positionUs)`. While paused/loading (or idle with
  /// media) it just updates the frozen position. Throws [StateError] if no
  /// media is selected.
  PlaybackSnapshot seek(int positionUs, {required int nowUs}) {
    if (_snapshot.mediaId == null) {
      throw StateError('seek() with no media selected');
    }
    if (_snapshot.status == PlaybackStatus.playing) {
      return _snapshot = _snapshot.copyWith(
        rev: _snapshot.rev + 1,
        anchor: PlaybackAnchor(
          hostTimeUs: nowUs + leadTimeUs,
          positionUs: positionUs,
        ),
        positionUs: positionUs,
      );
    }
    return _snapshot = _snapshot.copyWith(
      rev: _snapshot.rev + 1,
      positionUs: positionUs,
    );
  }

  /// Change the playback rate, preserving position continuity.
  ///
  /// While playing, the state is re-anchored *immediately* at
  /// `(nowUs, positionAt(nowUs))` with the new rate — not scheduled with
  /// [leadTimeUs]. A scheduled rate change cannot be represented losslessly
  /// by a single anchor (positionAt clamps to the anchor position before the
  /// anchor time, which would misreport the lead-in window), so we anchor at
  /// "now": guests apply the new rate on receipt, a few ms apart, and §5.4
  /// drift correction absorbs the tiny residual. While not playing, only the
  /// stored rate changes; the frozen position is untouched.
  ///
  /// Throws [ArgumentError] if [rate] is not a positive finite number.
  PlaybackSnapshot setRate(double rate, {required int nowUs}) {
    if (!rate.isFinite || rate <= 0) {
      throw ArgumentError.value(rate, 'rate', 'must be a positive number');
    }
    if (_snapshot.status == PlaybackStatus.playing) {
      final position = _snapshot.positionAt(nowUs);
      return _snapshot = _snapshot.copyWith(
        rev: _snapshot.rev + 1,
        anchor: PlaybackAnchor(hostTimeUs: nowUs, positionUs: position),
        positionUs: position,
        rate: rate,
      );
    }
    return _snapshot = _snapshot.copyWith(
      rev: _snapshot.rev + 1,
      rate: rate,
    );
  }

  // --- Peer readiness bookkeeping (§6.3) -------------------------------------

  /// Register a peer (idempotent: an existing peer keeps its reported state).
  void upsertPeer(String peerId) => _peers.add(peerId);

  /// Remove a peer and forget its readiness reports.
  void removePeer(String peerId) {
    _peers.remove(peerId);
    _peerMedia.remove(peerId);
  }

  /// Record a peer's `media_status` report (§6.3). Implicitly registers the
  /// peer if it was unknown. Only the latest report per peer is retained.
  void setPeerMediaState(String peerId, String mediaId, MediaReadiness state) {
    _peers.add(peerId);
    _peerMedia[peerId] = (mediaId: mediaId, state: state);
  }

  /// Whether every current peer has reported `ready` for [mediaId].
  ///
  /// Vacuously true when there are no peers (a solo host never waits).
  /// A peer whose latest report is for a *different* (stale) mediaId, or who
  /// has reported nothing, counts as not ready. The wait-vs-timeout policy
  /// (§6.3 "all ready or 10 s") is the host app's job; this only answers the
  /// instantaneous question.
  bool allPeersReady(String mediaId) {
    for (final peerId in _peers) {
      final report = _peerMedia[peerId];
      if (report == null ||
          report.mediaId != mediaId ||
          report.state != MediaReadiness.ready) {
        return false;
      }
    }
    return true;
  }
}
