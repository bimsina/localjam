/// Feeds the OS media session (lock screen / notification / now playing)
/// from a [JamEngine] and routes remote transport commands back into it.
///
/// One controller per live engine, owned by the engine's session guards:
/// created in `startSessionGuards`, disposed in `stopSessionGuards`. All
/// platform calls are best-effort ([JamMediaSession] swallows missing
/// implementations), so CLI embeddings and tests cost nothing.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:localjam_audio/localjam_audio.dart';
import 'package:localjam_net/localjam_net.dart';

import 'jam_engine.dart';

class JamMediaSessionController {
  JamMediaSessionController(this._engine);

  final JamEngine _engine;

  final List<StreamSubscription<Object?>> _subs = [];

  /// Artwork already resolved for the media card, keyed by mediaId — one
  /// async fetch per track, re-pushing the card when it lands.
  String? _artworkMediaId;
  Uint8List? _artworkBytes;
  bool _artworkLoading = false;

  bool _disposed = false;

  /// Starts publishing: installs the command handler and pushes the current
  /// state, then follows every state/playlist/permissions change.
  void start() {
    JamMediaSession.onCommand = _onCommand;
    _subs.addAll([
      _engine.states.listen((_) => _push()),
      _engine.playlistUpdates.listen((_) => _push()),
      _engine.permissionUpdates.listen((_) => _push()),
    ]);
    _push();
  }

  /// Re-pushes the current state (e.g. after app resume, when the OS may
  /// have dropped the card).
  void refresh() => _push();

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    _subs.clear();
    // Only tear down the global handler if it is still ours (another engine
    // may have attached since).
    if (JamMediaSession.onCommand == _onCommand) {
      JamMediaSession.onCommand = null;
      await JamMediaSession.clear();
    }
  }

  // --- OS → engine -----------------------------------------------------------

  void _onCommand(JamRemoteCommandEvent event) {
    // §5.6: the media card's buttons are capability-gated on push, but the
    // OS can race a permissions change — re-check and drop silently (the
    // host would refuse anyway; a lock screen has nowhere to show a denial).
    if (!_engine.can(JamCapability.controlPlayback)) return;
    unawaited(() async {
      try {
        switch (event.command) {
          case JamRemoteCommand.play:
            await _engine.transportPlay();
          case JamRemoteCommand.pause:
            await _engine.transportPause();
          case JamRemoteCommand.next:
            await _engine.transportNext();
          case JamRemoteCommand.previous:
            await _engine.transportPrevious();
          case JamRemoteCommand.seek:
            final positionUs = event.positionUs;
            if (positionUs != null) await _engine.transportSeek(positionUs);
        }
      } catch (_) {
        // Disconnected / no media selected: the card just stays stale until
        // the next authoritative broadcast.
      }
    }());
  }

  // --- Engine → OS -----------------------------------------------------------

  void _push() {
    if (_disposed) return;
    final item = _engine.currentItem;
    if (item == null) {
      unawaited(JamMediaSession.clear());
      return;
    }
    _ensureArtwork(item);
    final snapshot = _engine.snapshot;
    final canControl = _engine.can(JamCapability.controlPlayback);
    unawaited(
      JamMediaSession.update(
        JamNowPlaying(
          title: item.displayTitle,
          artist: item.artist,
          album: item.album,
          artworkBytes: _artworkMediaId == item.mediaId ? _artworkBytes : null,
          durationUs: item.durationUs,
          positionUs: _engine.positionUsNow() ?? snapshot.positionUs,
          rate: snapshot.rate,
          playing: snapshot.status == PlaybackStatus.playing,
          canPlayPause: canControl,
          canNext: canControl,
          canPrevious: canControl,
          canSeek: canControl,
        ),
      ),
    );
  }

  void _ensureArtwork(MediaItem item) {
    if (_artworkMediaId == item.mediaId || _artworkLoading) return;
    if (item.artworkId == null) {
      _artworkMediaId = item.mediaId;
      _artworkBytes = null;
      return;
    }
    _artworkLoading = true;
    unawaited(() async {
      final bytes = await _engine.artworkFor(item);
      _artworkLoading = false;
      if (_disposed) return;
      _artworkMediaId = item.mediaId;
      _artworkBytes = bytes;
      // Only re-push if this track is still the current one.
      if (_engine.currentItem?.mediaId == item.mediaId) _push();
    }());
  }
}
