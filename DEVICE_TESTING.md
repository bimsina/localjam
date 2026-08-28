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

## Reading the telemetry

- **Drift** = player position vs where the session clock says it should be —
  network + engine only, not headphone latency.
- **Slews** = inaudible ±0.5 % corrections (normal to see a few).
- **Resyncs** = audible corrections. More than one after settling = file a bug
  with the numbers on screen.
