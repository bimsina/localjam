# Changelog

## 0.2.0

- OS media session: lock-screen / notification metadata + transport commands
  (`localjam_audio/media_session`) — MPNowPlayingInfoCenter +
  MPRemoteCommandCenter on iOS/macOS, framework MediaSession + MediaStyle
  notification on Android.
- Android session keep-alive moved into the plugin (`JamSessionService`,
  `localjam/keepalive` channel): mediaPlayback foreground service whose
  notification doubles as the media card, plus wake/Wi-Fi locks.
- Android device music library (`localjam_audio/library`): MediaStore query
  and scoped-storage-safe resolve-to-file.

## 0.1.0

- Sample-accurate scheduled playback on the native clock: AVAudioEngine on
  iOS/macOS, Android backend, shared miniaudio core on Windows/Linux.
- Native↔Dart clock calibration, precise position readback, pitch-preserving
  micro rate adjustment for drift slews.
- Route-change / interruption / engine-restart / end-of-file events.
