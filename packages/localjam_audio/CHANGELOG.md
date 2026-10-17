# Changelog

## 0.3.0

- `probeDurationUs(path)` (`probeDuration`): a file's duration without loading
  it — engine, play state and session untouched.
- `currentRouteId()` (`currentRouteId`) and `routeChanged{routeId}`: a stable
  id per output device.
- `routeChanged{oldDeviceUnavailable: true}`: the old output went away; native
  stops its output first and does not restart it (iOS `.oldDeviceUnavailable`,
  macOS default-device removal).
- `interruptionEnded{shouldResume}`; interruptions stop output and are never
  auto-resumed. On iOS and Android every `playAt` refused by the OS emits
  `interruptionBegan` (per call, not per interruption) and completes without
  playing.
- New event `playbackError{code, message}` for failures off the method-call
  path. Desktop decoder failures now report it instead of `engineRestarted`
  (which made clients re-schedule into the same failure). No platform sends
  `device_lost`: a lost output is `routeChanged{oldDeviceUnavailable}`.
- `engineRestarted` is only sent when a playing/paused schedule was dropped.
- iOS/macOS crash fixes: files ≥ 2^32 frames (scheduled as consecutive
  segments), files ≤ 32 Hz and empty files (refused at load), extreme
  `playAt`/`setRate` arguments (validated; rate ∈ [1/32, 32], anchor ≤ 1 h
  ahead), NSExceptions from AVFAudio (caught; the engine is rebuilt), media
  services reset (engine rebuilt on the next `playAt`).
- `load` no longer fails just because the engine cannot start yet (e.g. during
  a call); a failed `load` now leaves no file loaded.
- Privacy manifest declares `mach_absolute_time` (35F9.1) and is bundled by
  both SwiftPM and CocoaPods.
- Untrusted headers: `load`/`probeDuration` refuse sample rates outside
  4–384 kHz and more than 2^37 frames on every platform (a ~1 KB
  CAF declaring 2^62 frames hung `playAt`; a 2^31 Hz desktop header sized a
  1.7 GB buffer). Desktop decode chunks always fit the ring; allocation or
  thread failures in the desktop core are errors, never `std::terminate`.
- Desktop output switches (every WASAPI default-device change) keep playing
  and report `routeChanged` with the new latency instead of
  `playbackError{device_lost}`; an unplug — with or without a fallback
  device — stops output and reports `routeChanged{oldDeviceUnavailable}`.
  Output is muted while a change is undecided. Desktop route ids are now
  hashed (`<backend>:<hash>`); `probeDuration`/`currentRouteId` run off the UI
  thread and no longer need the engine.
- iOS/macOS: an unplug no longer yields `engineRestarted` when the engine's
  configuration change arrives before the route change (the event waits
  200 ms and is dropped for a lost output; macOS also checks the device still
  exists). `AVAudioEngine.start()`, `pause()` and teardown run inside the
  exception catcher. macOS reports the Intel headphone jack (a data source of
  the built-in device) being unplugged.
- Android: audio focus is requested on `playAt` (refused → `interruptionBegan`
  as above); a `playAt` within ~2 s of an unplug is held and re-emits
  `routeChanged{oldDeviceUnavailable: true}`; an in-range rate the output
  cannot time-stretch is `bad_args`; writer/decoder failures report
  `playbackError{writer_failed|decode_failed}`.

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
