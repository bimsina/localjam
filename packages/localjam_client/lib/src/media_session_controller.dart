/// Feeds the OS media session (lock screen / notification / now playing)
/// from a [JamEngine] and routes remote transport commands back into it.
///
/// One controller per live engine, owned by the engine's session guards:
/// created in `startSessionGuards`, disposed in `stopSessionGuards`. All
/// platform calls are best-effort ([JamMediaSession] swallows missing
/// implementations), so CLI embeddings and tests cost nothing.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
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

  /// The cache key that goes to the platform with [_artworkBytes]: the item's
  /// content-addressed [MediaItem.artworkId], or [placeholderArtworkId] when
  /// the fallback cover is being shown.
  String? _artworkId;
  bool _artworkLoading = false;

  bool _disposed = false;

  /// A cover for tracks that have none of their own.
  ///
  /// Most files people actually add to a jam — a voice memo, a bootleg, a
  /// stem someone exported — carry no embedded art, and a media card with an
  /// empty square is the OS's generic music glyph or nothing at all. The
  /// engine cannot draw the brand placeholder itself: rendering is a Flutter
  /// concern and nothing here has a widget tree, a `BuildContext` or a
  /// `ui.Image` pipeline it may touch from a background isolate. So the app
  /// supplies the bytes and the engine does the plumbing.
  ///
  /// Set it once, at startup, before the first session goes live:
  ///
  /// ```dart
  /// JamMediaSessionController.placeholderArtworkProvider =
  ///     () => JamArtworkPlaceholder.pngBytes();  // app-side
  /// ```
  ///
  /// Called at most once per process (the result is cached, `null` included),
  /// off any hot path, and never awaited by anything a user is waiting on. It
  /// must not throw; one that does is treated as "no placeholder".
  static Future<Uint8List?> Function()? placeholderArtworkProvider;

  /// The cache key published with the placeholder. Stable by design: the
  /// platform decodes one bitmap for it and reuses that for every artless
  /// track in the queue.
  static const String placeholderArtworkId = 'localjam.placeholder';

  static Uint8List? _placeholder;
  static Future<Uint8List?>? _placeholderPending;

  /// Forgets the resolved placeholder (and the provider); for tests.
  @visibleForTesting
  static void resetPlaceholderForTesting() {
    placeholderArtworkProvider = null;
    _placeholder = null;
    _placeholderPending = null;
  }

  /// The placeholder bytes, resolved once and then handed out from memory.
  static Future<Uint8List?> _resolvePlaceholder() {
    final cached = _placeholder;
    if (cached != null) return Future<Uint8List?>.value(cached);
    final provider = placeholderArtworkProvider;
    if (provider == null) return Future<Uint8List?>.value(null);
    return _placeholderPending ??= () async {
      try {
        return _placeholder = await provider();
      } catch (_) {
        // A placeholder that cannot be rendered is not worth an incident;
        // the card just goes back to having no art.
        return null;
      }
    }();
  }

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
          // The room names the card when the tags do not (and sits under the
          // artist when they do), so the OS never shows a generic product line.
          sessionName: _engine.sessionName,
          artworkBytes: _artworkMediaId == item.mediaId ? _artworkBytes : null,
          // Lets the platform cache one decoded bitmap per cover rather than
          // re-decoding it on every position/permission push.
          artworkId: _artworkMediaId == item.mediaId ? _artworkId : null,
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
    // The fast path for an artless track with no placeholder configured: no
    // fetch to make, so settle it now rather than through a microtask.
    if (item.artworkId == null &&
        placeholderArtworkProvider == null &&
        _placeholder == null) {
      _artworkMediaId = item.mediaId;
      _artworkBytes = null;
      _artworkId = null;
      return;
    }
    _artworkLoading = true;
    unawaited(() async {
      var bytes = item.artworkId == null
          ? null
          : await _engine.artworkFor(item);
      var id = bytes == null ? null : item.artworkId;
      // No embedded cover, or its bytes went away: fall back to the brand
      // placeholder the app supplied, so the card is never a blank square.
      if (bytes == null) {
        bytes = await _resolvePlaceholder();
        if (bytes != null) id = placeholderArtworkId;
      }
      _artworkLoading = false;
      if (_disposed) return;
      _artworkMediaId = item.mediaId;
      _artworkBytes = bytes;
      _artworkId = id;
      // Only re-push if this track is still the current one.
      if (_engine.currentItem?.mediaId == item.mediaId) _push();
    }());
  }
}
