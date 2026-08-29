# Physical-device test checklist

What simulators could not verify — run these on real hardware. Everything
else (sync math, transport, lifecycle, end-of-media, reconnect) is covered by
the 200+ test suite and live simulator runs (drift ≤ 10 ms across three
devices, iOS + Android).

## Setup

- iOS: `cd apps/localjam_app && flutter run --release -d <iphone>` (needs your
  dev cert; add your team in Xcode Runner signing once).
- Android: `flutter build apk --release` and install the APK, or `flutter run
  --release -d <device>`.
- Put a few real songs in the host phone's app Documents (iOS: Files app →
  LocalJam) or use "Add files".
- Both phones on the same Wi-Fi, or host runs a hotspot and the guest joins it.

## The checks

1. **Wired / speaker sanity** — host + guest on phone speakers, stand them
   next to each other, play. Expect a tight flam or none (≤ ~20 ms). This
   validates real-Wi-Fi clock sync (simulators shared one machine clock —
   this is the first genuinely independent-clock test!).
2. **Bluetooth latency** — guest switches to BT headphones, one earbud out,
   compare against the host's speaker. Expect the BT ear to lag 100–300 ms.
   Note what the telemetry says (drift will read ~0 — the engine can't see
   past the OS) and how many ms of "Nudge sync" it takes to line up. Record
   per headphone model; if platform-reported latency (visible in
   route-change logs) is close, §7 is working.
3. **Route change** — unplug/replug headphones and connect BT mid-playback.
   Playback should recover and re-anchor by itself (audio events →
   recalibrate). A brief gap is fine; staying desynced is a bug.
4. **Interruption** — call the guest phone mid-jam, hang up. Playback should
   resume in sync without touching the app.
5. **Screen lock / background** — lock both phones mid-playback. Audio must
   continue on both (iOS background audio mode; Android foreground service
   notification should appear). Unlock: still in sync (resume re-verify).
   Known limit: an iOS host that is *paused* when locked may be suspended.
6. **Wi-Fi blip** — toggle the guest's Wi-Fi off/on for ~10 s. Expect
   "reconnecting…" then automatic resume with the same peer id. Off for
   > 90 s → "Session ended" screen (hostGone).
7. **Host walks away** — force-quit the host app. Guests should show
   "reconnecting…" then "Session ended" after ~90 s, never hang forever.
8. **Battery/thermal spot-check** — 30 min of continuous playback; note
   battery drain on the host (it runs a server + audio).
9. **Lock-screen media card** — while playing, check the lock screen /
   notification shade on both phones: title/artist/album + artwork should
   show, position should advance, and previous/play-pause/next (and the
   iOS seekbar) should work. On a guest without playback control (Jam or
   Listen preset) the card must appear WITHOUT transport controls — and
   grow them live when the host promotes the guest or flips the policy.
   Android: the media card IS the foreground-service notification (one
   notification total). Android 13+: accept the notification permission
   prompt, or the card won't show (playback still runs).
10. **Headset / watch / car transport** — pause and skip from Bluetooth
    headset buttons or a watch. Same §5.6 gating as the lock screen.
11. **iOS host paused + locked** — pause the jam, lock the host, wait
    ~5 min, unlock. Expect the OS suspended the app: guests show
    "reconnecting…" then "Session ended" (~90 s). Reopening the host app
    revives the room for guests who rejoin (their cache re-fetches
    nothing). This is the documented graceful-death path, not a bug.

## Reading the telemetry

- **Drift** = player position vs where the session clock says it should be —
  network + engine only, not headphone latency.
- **Slews** = inaudible ±0.5 % corrections (normal to see a few).
- **Resyncs** = audible corrections. More than one after settling = file a bug
  with the numbers on screen.

## Desktop platforms

- **macOS**: live-verified (app joined a session at −0.4 ms drift). Full
  format support via AVAudioEngine.
- **Linux**: `flutter build linux --debug` verified in an Ubuntu 24.04
  (arm64) container — plugin glue compiles clean under -Wall -Werror.
  Runtime audio (PulseAudio/ALSA) still needs a real machine with a sound
  device: run the app, join a session, check the same telemetry as mobile.
- **Windows**: shared miniaudio core (measured ≤0.01 ms start error on
  CoreAudio); plugin glue **build-unverified** — first task on a Windows
  machine is `flutter build windows`, then the mobile checks. Desktop v1 formats: mp3/flac/wav/ogg
  (m4a/AAC returns unsupported_format; OS-codec decode is a later add).

## Simulator/emulator run — 2026-08-29 (pre-device baseline)

Everything below ran live on two iOS simulators (iPhone 17 Pro + Pro Max)
and a Pixel 9 Pro emulator (API 36). Numbers are from the in-app telemetry.

| # | Check | Result |
|---|-------|--------|
| 1 | Sync quality | ✅ guest drift −0.2…−5.9 ms, "in sync", 0 slews, 0 resyncs (shared-machine clock, so a weak proxy for real Wi-Fi) |
| 2 | Bluetooth latency | ⬜ needs hardware |
| 3 | Route change | ⬜ needs hardware |
| 4 | Interruption (call) | ⬜ needs hardware (no calls on simulator) |
| 5 | Screen lock / background | ✅ both devices locked mid-playback: host kept serving, end-of-media ADVANCE fired twice while locked, resume re-verify landed −0.2 ms in sync |
| 6 | Wi-Fi blip | ⬜ needs hardware (reconnect machinery covered by the automated suite) |
| 7 | Host walks away | ✅ force-quit host → "Connection lost — reconnecting…" within seconds (cached playback continues) → "Session ended" terminal screen after the 90 s hostGone window |
| 8 | Battery/thermal | ⬜ needs hardware |
| 9 | Lock-screen media card | ✅ **Android**: full MediaStyle card (title, live progress, prev/pause/next; pause round-trips into the engine, app paused at the right position). ⚠️ **iOS**: MPNowPlayingInfo pushes run, but the simulator's lock screen / Control Center has no Now Playing module — verify visually on a real iPhone |
| 10 | Headset/watch/car transport | ⬜ needs hardware |
| 11 | iOS host paused + locked | ⬜ needs hardware (the simulator never suspends apps, so graceful-death can't reproduce there) |

Also verified along the way: mDNS discovery (host appeared in the other
simulator's "Nearby jams", one-tap join), per-device quirky identities
("Silky Puffin" / "Golden Pangolin"), Android READ_MEDIA_AUDIO prompt +
MediaStore library picker → scoped-storage resolve → hosted session, and
jam history (session recorded with attribution, "Host it again" enabled).
