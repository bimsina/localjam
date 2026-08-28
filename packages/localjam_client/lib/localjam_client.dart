/// The embeddable LocalJam client engine.
///
/// One dependency for UI apps (a music player, a game, ...):
///
/// * [JamHostEngine] — host a session and play along locally.
/// * [JamGuestEngine] — join a session, prefetch media, play in sync.
/// * [AudioSyncController] / [DriftSample] — the shared sync engine and its
///   telemetry, for apps that want to wire the pieces themselves.
///
/// The public surfaces of `localjam_net` (which re-exports `localjam_core`)
/// and `localjam_audio` are re-exported so consumers need only this package.
library;

export 'package:localjam_audio/localjam_audio.dart';
export 'package:localjam_net/localjam_net.dart';

export 'src/audio_sync_controller.dart';
export 'src/guest_engine.dart';
export 'src/host_engine.dart';
export 'src/jam_engine.dart';
export 'src/latency_prefs.dart';
export 'src/media_mime.dart';
export 'src/media_scan.dart';
