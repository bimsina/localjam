# localjam_audio

Sample-accurate scheduled audio playback for LocalJam clients: start a local file
at an exact instant of the platform's monotonic clock (PROTOCOL.md §5.3), read
back precise positions, and micro-adjust rate for drift correction (§5.4).

The Dart API is in `lib/localjam_audio.dart`; it is one method channel
(`localjam_audio`) plus one event channel (`localjam_audio/events`), implemented
identically on every platform.

## Platforms

| Platform | Engine | Formats |
| --- | --- | --- |
| iOS / macOS | AVAudioEngine + AVAudioUnitTimePitch | everything AVFoundation reads (incl. m4a/aac/alac) |
| Android | AudioTrack + MediaCodec | everything MediaCodec reads (incl. m4a/aac) |
| Windows | shared C++ core on miniaudio (WASAPI) | **wav, flac, mp3, ogg-vorbis only** |
| Linux | shared C++ core on miniaudio (PulseAudio/ALSA/JACK) | **wav, flac, mp3, ogg-vorbis only** |

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
  nudge exist for.

## Verifying the core

The Windows and Linux plugin sources are thin channel translators and cannot be
compiled on a macOS development machine. The engine they delegate to can:

```sh
./src/test/build.sh
```

builds and runs `src/test/core_test.cpp` against the machine's real default
output device (CoreAudio on macOS, PulseAudio/ALSA on Linux). It measures start
error, position error against the §5.4 anchor formula, rate slope, the
overshoot-trim path, and — using a fixture whose channel 0 is a linear ramp
encoding its own frame index — audits the audio actually being emitted against
what the position formula claims, which is a check the clock model cannot fake.

Measured on macOS 15 / CoreAudio (44.1 kHz, 441-frame periods): start error
≤ 0.01 ms, position error ≤ 0.01 ms, rate slope within 0.0001 % of target,
source-frame audit within 0.9 ms.
