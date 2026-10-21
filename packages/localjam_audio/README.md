# localjam_audio

Sample-accurate scheduled audio playback for LocalJam clients: start a local file
at an exact instant of the platform's monotonic clock (PROTOCOL.md §5.3), read
back precise positions, and micro-adjust rate for drift correction (§5.4).

The Dart API is in `lib/localjam_audio.dart`; it is one method channel
(`localjam_audio`) plus one event channel (`localjam_audio/events`), implemented
identically on every platform, the web included (see [Web](#web)).

## API at a glance

| Dart (`LocaljamAudio`) | Channel method | Notes |
| --- | --- | --- |
| `nativeNowUs()` / `calibrate()` | `nowUs` | native monotonic clock, µs |
| `load(path)` → `int` µs | `load {path}` | replaces the loaded file; a failed load leaves none. Refuses (`load_failed`) sample rates outside 4–384 kHz, empty files and more than 2^37 frames |
| `probeDurationUs(path)` → `int?` µs | `probeDuration {path}` | what `load` would report; null if `load` would refuse the file. Touches no engine, file, play state or session — safe while playing and concurrently; answered off the UI thread |
| `playAt(nativeTimeUs, positionUs, rate)` | `playAt {…}` | rate ∈ [1/32, 32]; anchor ≤ 1 h ahead. If the OS refuses audio (call in progress) it completes without playing and emits `interruptionBegan` — on every refused call. See [Platform differences](#platform-differences) |
| `pause()` / `stop()` / `positionUs()` / `setRate(rate)` | same names | `positionUs` is null unless playing/scheduled |
| `outputLatencyUs()` | `outputLatencyUs` | 0 when unknown |
| `currentRouteId()` → `String?` | `currentRouteId` | opaque, stable per output device (key per-route calibration with it); answered off the UI thread |
| `dispose()` | `dispose` | |

Error codes (`PlatformException.code`): `bad_args`, `no_file`, `load_failed`,
`unsupported_format` (desktop), `bad_position`, `engine_start_failed` (the
engine / output device would not start), `engine_not_running` (Apple: no render
cycle within 1 s, or the engine stopped mid-schedule), `engine_error` (Apple:
AVFoundation raised; the engine is rebuilt on the next call), `internal`
(desktop: out of memory or threads), `disposed`. A failed `playAt` leaves
nothing scheduled; the next one starts from scratch.

### Untrusted files

Hosts serve files that peers upload, so every header value is treated as
hostile. `load` and `probeDuration` refuse a sample rate outside
[4000, 384000] Hz, a stream without frames and one declaring more than 2^37
frames (99 h even at 384 kHz) — the same limits on iOS/macOS, Android and
desktop, so a file plays everywhere or nowhere. A ~1 KB CAF can declare 2^62 frames; it used
to make `playAt` queue 2^32 segments (hang, then out of memory). On desktop no
buffer is ever sized from a header alone (ring ≤ 4 MB, decode chunk ≤ half the
ring), and no allocation or thread failure can `std::terminate` the app.

## Events

`LocaljamAudio.events` decodes maps `{type, …}`; unknown types and keys are
ignored, missing keys take defaults, so either side may be newer.

| `type` | Payload | Meaning |
| --- | --- | --- |
| `routeChanged` | `outputLatencyUs?`, `routeId?`, `oldDeviceUnavailable` (default false) | Output route changed. If `oldDeviceUnavailable`, the old output went away (unplugged, Bluetooth gone, Android "becoming noisy", a desktop device removed or dead): native **already stopped** its output and will not restart it — audio never jumps to the speaker. Otherwise playback continues on the new route |
| `interruptionBegan` | `shouldResume?` | Call / Siri / audio focus lost: native stopped its output. Also sent by **every** `playAt` the OS refuses (iOS, Android) — per call, not per interruption — which may never get an `interruptionEnded`. `shouldResume: false` (Android) = **permanent** focus loss (the user started another player): no `interruptionEnded` will follow, only a `playAt` ends it; it may arrive mid-interruption (a transient loss or call turned permanent), and every refused `playAt` repeats it while that loss stands. Absent otherwise |
| `interruptionEnded` | `shouldResume?` | Native **never** auto-resumes (the room moved on); re-anchor with `playAt` if wanted. `shouldResume` is the OS hint |
| `engineRestarted` | — | A playing/paused schedule was dropped by an engine reconfiguration; re-schedule. Not sent when nothing was scheduled, nor for a schedule lost to an unplug (that is `routeChanged{oldDeviceUnavailable}` only — iOS/macOS hold this event 200 ms because the OS does not order the two notifications). Never sent by the desktop core |
| `playbackFinished` | — | The schedule reached end of file |
| `playbackError` | `code`, `message` | Unrecoverable failure off the method-call path; output stopped, next `playAt` starts over. Codes: `engine_start_failed` (Apple), `decode_failed` (Android, desktop), `writer_failed` (Android); treat unknown codes generically. A lost output device is a `routeChanged`, not an error: no platform sends `device_lost` |

### Platform differences

| | iOS | macOS | Android | Windows / Linux |
| --- | --- | --- | --- | --- |
| `playAt` refused by the OS (completes, no sound, `interruptionBegan` on every refused call) | session activation refused (call, higher-priority session) | never | audio focus refused, or a call owns the audio path | never |
| `playAt` within ~2 s of an unplug | — | — | held the same way, re-emitting `routeChanged{oldDeviceUnavailable: true}` (the reroute to the speaker is still pending) | — |
| In-range rate refused (`bad_args`) | never | never | when the output cannot time-stretch it (API 36 emulator: 0.1–4 plays, ≤ 1/16 and ≥ 8 do not); `setRate` then keeps the old rate — silently on a low-latency track — and `positionUs` stays true | never |
| Rate change | time-stretch, pitch kept | same | `PlaybackParams` speed, pitch kept | resample, pitch shifts (~9 cents at ±0.5 %) |
| `engineRestarted` | engine reconfigured; held 200 ms, dropped for an unplug | same | AudioTrack died | never |
| `playbackError` codes | `engine_start_failed` | `engine_start_failed` | `decode_failed`, `writer_failed` | `decode_failed` |
| File limits (4–384 kHz, ≤ 2^37 frames) | yes | yes | yes | yes |

Route ids: iOS `<portType>:<hash(uid)>` per output port, macOS
`<transport>[/<dataSource>]:<hash(uid)>` of the default output device, desktop
`<backend>:<hash(device id)>` of the default output device, Android
`<typeTag>:<hash(type|name|address)>`. Hashes are FNV-1a 64 (16 hex digits);
UIDs/addresses are hashed because Bluetooth ones embed a MAC address. Treat the
id as opaque: only equality is meaningful.

Output-loss coverage: iOS route reasons; macOS default-device removal and the
headphone-jack data source of a built-in device (Intel Macs); Android "becoming
noisy" + device callbacks; desktop whatever miniaudio reports — a WASAPI
endpoint unplug (with or without a fallback device), a PulseAudio stream moved
off a removed sink, a device that stops and does not come back within 200 ms.
Not visible on desktop: PulseAudio/PipeWire *port* switches inside one sink
(headphone jack vs speaker on the same card), where the stream never moves.

Apple specifics: AVFoundation calls that raise `NSException` run inside a small
Objective-C catcher (`localjam_audio_objc` target), and an engine that raised is
rebuilt on the next `playAt`, so a bad file or an unlucky route change surfaces
as an error, never a crash. The plugin's `PrivacyInfo.xcprivacy` declares
`mach_absolute_time` (System boot time, reason `35F9.1`).

## Platforms

| Platform | Engine | Formats |
| --- | --- | --- |
| iOS / macOS | AVAudioEngine + AVAudioUnitTimePitch | everything AVFoundation reads (incl. m4a/aac/alac) |
| Android | AudioTrack + MediaCodec | everything MediaCodec reads (incl. m4a/aac) |
| Windows | shared C++ core on miniaudio (WASAPI) | **wav, flac, mp3, ogg-vorbis only** |
| Linux | shared C++ core on miniaudio (PulseAudio/ALSA/JACK) | **wav, flac, mp3, ogg-vorbis only** |
| Web | Web Audio, `lib/localjam_audio_web.dart` (see [Web](#web)) | whatever the browser's `decodeAudioData` takes (Safari: no Ogg/Opus) |

## Web

An inline web platform (`flutter.plugin.platforms.web`, `LocaljamAudioWeb`)
answers the same two channels, so `LocaljamAudio` runs unchanged in the
browser listener page (docs/design/WEB_GUEST.md D6/D7). Web Audio only: one
decoded `AudioBuffer` at a time, played by an `AudioBufferSourceNode` started
with `start(when, offset)`; graph source → `GainNode` → destination.

- **Clock**: `nowUs` is `performance.now()` in µs, so `calibrate` measures
  ~0 offset against a Dart clock on the same base.
- **`load(path)` / `probeDurationUs(path)`**: `path` is a URL the page can
  `fetch` — a `blob:` URL (`URL.createObjectURL` of media bytes the page
  already prefetched) or a same-origin `http(s):` URL. Fetch failure or a
  non-2xx answer → `load_failed`; bytes the browser cannot decode →
  `unsupported_format`; a decode that failed for any other reason (context
  closed under it, allocation failure) → `engine_error`, worth retrying.
  `load` replaces the buffer (D7: a 5-min track is ~100 MB of PCM).
  `probeDuration` has no header-only path in a browser: it fetches and
  decodes the whole file (CPU and transient memory), touching neither the
  buffer nor playback. It answers null only for bytes `load` would refuse
  and throws (`load_failed`, `engine_error`) when it could not tell, so a
  caller can retry. `probeDurationUs(path, keepForLoad: true)` keeps that
  decode for a `load` of the same URL (one kept at most): the current track
  decodes once. Durations are of the decoded buffer (resampled to the
  context rate; within a frame).
- **`playAt`**: performance time is mapped to context time with
  `getOutputTimestamp()` (the context time heard at a given instant) shifted by
  the reported latency, so the frame is heard `outputLatencyUs()` after
  `nativeTimeUs`, as on native; the latency the Dart side subtracts cancels
  out whenever the timestamp is accurate. Without that API (or before it
  yields a stable value) `currentTime` is sampled against `performance.now()`
  instead (one render callback coarse, 23 ms steps in Chrome). A past anchor
  starts 50 ms (or 2 × `baseLatency`, if longer) ahead of the render clock
  with the position advanced (late join). Same `bad_args` bounds and
  `no_file`/`bad_position` as native. After the context was suspended or
  interrupted, the next `playAt` waits (≤ 1 s) for a fresh output timestamp:
  the context clock stood still while performance time ran on.
- **`setRate`** sets the live node's `playbackRate` 50 ms ahead (resample:
  pitch shifts ~9 cents at ±0.5 %, as on desktop); positions stay continuous.
  **`pause`** stops the node (`playAt` re-anchors anyway); `positionUs` is
  null unless playing/scheduled, and before a scheduled start reads the
  timeline extrapolated back to now, clamped at 0. **`outputLatencyUs`** is `outputLatency +
  baseLatency` where reported, else 0. **`currentRouteId`** is always null.
- **Autoplay**: the `AudioContext` is created by the first call that needs it
  and `resume()`d synchronously at the start of `load`, `playAt`,
  `outputLatencyUs` and `setMuted`, so the page's "Tap to listen" handler must
  call one of them (e.g. `outputLatencyUs()`) inside the gesture. If the
  context cannot run within 1 s, `playAt` completes without playing and emits
  `interruptionBegan` (native's refused-audio contract); `interruptionEnded`
  follows once it runs. The plugin never suspends the context afterwards,
  and `dispose` keeps it (and the iOS element): it releases the buffer and
  the node only, so the page's next engine plays without another gesture.
- **iOS / iPadOS** (user agent `iPhone|iPad|iPod`, or `Macintosh` with touch
  points): the gain feeds a `MediaStreamAudioDestinationNode` played by a
  hidden `<audio autoplay playsinline>` element, `play()`ed in the same
  gesture and never paused, meant to keep audio alive through screen lock.
  `navigator.mediaSession.playbackState` follows playback.
- **Events**: `playbackFinished`; `interruptionBegan`/`interruptionEnded`
  when the context goes `suspended`/`interrupted` and back (and, on iOS, when
  the system pauses the element and it plays again) — output stays stopped
  until the next `playAt`; `playbackError{code: context_closed}` if the
  browser closes the context under a schedule. No `routeChanged` or
  `engineRestarted`.
- **Web-only `setMuted {muted: bool}`** (channel method, not in the Dart API
  yet): ramps the gain to 0/1 in ~10 ms. Native sides do not implement it;
  call it as `MethodChannel('localjam_audio').invokeMethod('setMuted', …)`
  and catch `MissingPluginException`.

Tests: `test/localjam_audio_web_test.dart` drives real Web Audio in headless
Chrome. Chrome's autoplay policy keeps a context suspended without a gesture
and `flutter test` cannot pass browser flags, so the playback tests need a
wrapper that adds `--autoplay-policy=no-user-gesture-required`:

```sh
CHROME_EXECUTABLE=tool/chrome_autoplay.sh flutter test --platform chrome
```

Plain `flutter test --platform chrome` skips them (visibly) and runs the
no-gesture refusal test instead. Screen lock, the silent switch and the
`<audio>` element route can only be verified on a real iPhone.

### Desktop format limitation

Windows and Linux share one engine, `src/localjam_audio_core.{h,cpp}`, which
decodes with vendored public-domain libraries (dr_wav, dr_flac, dr_mp3,
stb_vorbis) rather than a system codec. That is deliberate — it means the same
decoder, and therefore the same frame indexing, on both desktops — but there is
no public-domain single-file AAC decoder to vendor, so:

**`load` on an m4a / aac / alac / wma / opus file fails with the error code
`unsupported_format`** and a message naming the detected container. Transcode
desktop session media to flac, ogg or wav.

Format is chosen by magic-byte sniffing, with the file extension as a fallback,
so a mislabelled file is still routed to the right decoder — and an m4a still
reports `unsupported_format` rather than `load_failed`.

## The shared desktop core

`src/localjam_audio_core.h` carries the full design write-up. In brief:

- **Clock**: `std::chrono::steady_clock` in µs is the scheduling timebase
  (CLOCK_MONOTONIC on Linux, QueryPerformanceCounter on Windows).
- **Scheduling**: silence priming against the device-callback clock. The device
  is started, silence is streamed, each callback is timestamped, and once that
  mapping is *mature* the engine computes how many silence frames land the first
  real PCM frame exactly on the anchor. Deliberately never an "ASAP" start.
- **Maturity gate**: the first callbacks are the backend's buffer prefill and are
  excluded, because anchoring on them puts every client at a constant offset that
  drift correction can never remove. Same lesson as the Android backend.
- **Late anchors**: re-anchored forward with the position advanced at ×rate; if
  the target passes during priming the media is trimmed instead, so the session
  anchor stays the truth either way.
- **Streaming decode**: `load` only probes. Each schedule runs a decoder thread
  feeding a bounded ring (~8 s / 4 MB cap), so memory is independent of file
  length.
- **Rate**: plain resample, so pitch shifts with the ratio. At the ±0.5 % §5.4
  slews that is ~9 cents — inaudible. It is not a time-stretcher.
- **Output latency**: miniaudio's visible buffer depth. Hardware latency below
  that is invisible to any portable API and is what §7 calibration and the manual
  nudge exist for. Re-read after every reroute.
- **Routes**: backends reroute by stopping the stream, re-opening it on the new
  device and starting it again, so a "stopped" notification alone is not a dead
  device. A pure state machine (`src/localjam_audio_internal.h`, `RouteWatch`)
  turns the notification sequence into one verdict: an output switch keeps
  playing (clock and latency re-measured, `routeChanged`); a reroute whose
  previous device the system no longer lists, or a stop with no restart within
  200 ms, stops playback (`routeChanged{oldDeviceUnavailable: true}`). Output is
  muted from the first unexpected notification until that verdict, so nothing
  is heard on a device about to be abandoned.
- **Threads**: `probeDuration` and `currentRouteId` touch no engine and run on a
  worker thread in both shells (GLib task pool / Windows thread pool), answered
  on the platform thread.

## Verifying the core

The Windows and Linux plugin sources are thin channel translators that cannot
be compiled on a macOS development machine (Linux: verified with
`flutter build linux` and the example's integration tests in an Ubuntu 24.04
container; Windows: compiled with MinGW-w64 against the Flutter Windows
headers, not yet with MSVC). The engine they delegate to can be built and run
anywhere:

```sh
./src/test/build.sh          # unit checks, then the device test
./src/test/build.sh --unit   # device-free unit checks only
```

`src/test/core_unit_test.cpp` needs no audio device: it replays the
notification orderings backends produce (WASAPI default switch, unplug with and
without a fallback, PulseAudio suspend and stream move, silent device death)
through the route state machine, checks stream sizing at every rate, and feeds
crafted files (absurd sample rates and lengths) to `load`/`probeDuration`.

`src/test/core_test.cpp` runs against the machine's real default output device
(CoreAudio on macOS, PulseAudio/ALSA on Linux). It measures start error,
position error against the §5.4 anchor formula, rate slope, the overshoot-trim
path, and — using a fixture whose channel 0 is a linear ramp encoding its own
frame index — audits the audio actually being emitted against what the position
formula claims, which is a check the clock model cannot fake. It also replays
route-change notification sequences into the live engine
(`lj_test_signal_device`): an output switch must keep playing on the anchor
line, an unplug must stop with `routeChanged{oldDeviceUnavailable}` and no
audible output in between, and nothing may be a `playbackError`.

Measured on macOS 15 / CoreAudio (44.1 kHz, 441-frame periods): start error
≤ 0.01 ms, position error ≤ 0.01 ms, rate slope within 0.0001 % of target,
source-frame audit within 0.9 ms.
