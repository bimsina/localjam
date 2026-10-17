# Physical-device test checklist

What simulators could not verify — run these on real hardware. Everything
else (sync math, transport, lifecycle, end-of-media, reconnect) is covered by
the 600-test suite and live simulator runs (drift ≤ 10 ms across three
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
12. **Deliberate end of jam** — host taps "End jam". Every guest must land on
    the terminal "The host ended the jam" screen *at once* (the §3.4
    `session_ended` goodbye), not after a "reconnecting…" spell and the 90 s
    hostGone timeout, and must not be offered "Try again". Do this with a
    guest backgrounded too: it should be on the ended screen when it comes
    back, not reconnecting.
13. **Kick, then rejoin** — host kicks a guest; the guest rejoins from the
    same device. Both peer lists must settle at exactly one entry for that
    person, with their real identity name — no phantom left over from the
    previous connection, and no ghost carried into either device's jam
    history.
14. **Permission rationale sheets** — on a phone that has never run LocalJam,
    every OS prompt (local network, camera, media library, notifications on
    Android 13+) must be preceded by the app's own sheet explaining why. Deny
    one: the sheet must come back with the "open Settings" path, and the app
    must stay usable. Re-grant from Settings and confirm the feature works
    without a restart.
15. **iOS Files app** — with the app installed, open Files → On My iPhone. A
    **LocalJam** folder must be there, and files dropped into it must appear
    in "Add files" (`UIFileSharingEnabled` +
    `LSSupportsOpeningDocumentsInPlace`). This is the only way onto a fresh
    phone that has no music of its own.
16. **Android media card branding** — the foreground-service notification
    must carry the LocalJam mark as its small icon, the room name as the
    subtitle, and the track's own artwork as the large icon (the placeholder,
    not a blank square, for untagged files). Check it on both the shade and
    the lock screen, in light and dark system themes.
17. **Landscape** — rotate the room screen on both a phone and a tablet, mid
    playback and with the queue and people sheets open. Nothing may clip or
    overflow; the transport stays reachable; rotating back restores the same
    scroll position.

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


## Simulator/emulator run — 2026-09-07 (post-overhaul)

Everything on the v1 checklist that a simulator can reach passed; nothing on
this rig regressed against the 2026-08-29 baseline, and the four end-of-session
paths (kick, host force-quit, deliberate end, rejoin) all landed on their
intended screens. What is still open is exactly what needs real radios and a
real speaker: rows 2, 3, 4, 8, 10, 11, plus landscape.

Ran live on two iOS simulators (iPhone 17 Pro = host, iPhone 17 Pro Max =
guest 1) and a Pixel 9 Pro emulator (API 36, guest 2), all three
fresh-installed from a debug build. Numbers are from the in-app telemetry.

| # | Check | Result |
|---|-------|--------|
| 1 | Sync quality | ✅ guest 1 −3.6 ms, guest 2 −6.1 ms, both "In sync", 0 slews, 0 resyncs; held through pause / play / seek / next / prev, three end-of-media advances and one unplanned reconnect (shared-machine clock, so still a weak proxy for real Wi-Fi) |
| 2 | Bluetooth latency | ⬜ needs hardware |
| 3 | Route change | ⬜ needs hardware |
| 4 | Interruption (call) | ⬜ needs hardware (no calls on simulator) |
| 5 | Screen lock / background | ✅ host + both guests home-buttoned for 35 s mid-playback: audio kept running and the queue advanced a track on every device while backgrounded (iOS AAC decoder restart + `LocaljamAudio start error … errorUs=15` on Android); on return all three were on the same track and "In sync" |
| 6 | Wi-Fi blip | ⬜ needs hardware — but an unplanned emulator NAT drop exercised the same path: "Connection lost — reconnecting…" with cached playback continuing, then automatic resume with the same peer id and no phantom in either peer list |
| 7 | Host walks away | ✅ `simctl terminate` → both guests "Reconnecting…" within 12 s (cached playback continues) → "The room closed — The host left or went out of range" with Try again + Back to nearby at ~115 s. Relaunching the host and hosting again worked; a fresh link join succeeded |
| 8 | Battery/thermal | ⬜ needs hardware |
| 9 | Lock-screen media card | ✅ **Android**: LocalJam mark, track title, room name, placeholder artwork and live progress — and correctly **no transport controls** for a playback-gated guest. ⚠️ **iOS**: MPNowPlayingInfo pushes run (MediaRemote NowPlayingItem changes in the log), but the simulator has no Now Playing module — verify visually on a real iPhone |
| 10 | Headset/watch/car transport | ⬜ needs hardware |
| 11 | iOS host paused + locked | ⬜ needs hardware (the simulator never suspends apps) |
| 12 | Deliberate end of jam | ✅ host "End jam" → both guests on "The host ended the jam · The room is closed. Everyone heard the same last song." inside ~1 s, **Back to nearby only**, no Try again, no reconnect spell. Host landed on home; the "Jam ended · N tracks, N person" home notice was captured on the Android host |
| 13 | Kick, then rejoin | ✅ kicked guest got "You were removed" with Back to nearby only, could **Start a jam immediately** afterwards (soft-lock fix), and on rejoining both peer lists settled at exactly three entries with the same identity — no phantom, no ghost in either device's history |
| 14 | Permission rationale sheets | ✅ iOS local-network sheet before the first host and not repeated on the second; Android local-network, notification and media-library sheets each preceded their system prompt. Deny → Settings → re-grant path not exercised |
| 15 | iOS Files app | ✅ "Add files" opened straight into **On My iPhone → LocalJam** holding the seeded tracks, and picking from it added them to the queue. Files.app itself was not opened |
| 16 | Android media card branding | ✅ LocalJam mark as the small icon, room name as the subtitle, placeholder artwork behind an untagged track, in the notification shade. Lock screen and light/dark system themes not exercised |
| 17 | Landscape | ⬜ not exercised — no rotation control from the harness. An iPad Pro 11-inch booted, installed and rendered onboarding correctly at tablet size; the sidebar + docked-panel layout needs a driven session |

Also verified along the way: fresh-install splash with no white flash and the
three-card onboarding with Skip on all three devices (not shown again after a
reinstall); host setup auto-scanning the seeded tracks and the room coming up
**playing**; the host's own room absent from its Nearby; join by deep link
(with a confirm dialog) and by pasted link; transport gating ("The host
controls playback"), co-host promotion enabling a guest's transport and that
guest's skip following on every device; queue add from the Android MediaStore
library with an "added by" avatar on all three, duplicate rejection ("Already
in the queue"), drag reorder with the sheet staying open, and swipe-to-remove
with the "Removed <track>" notice; block-adding disabling a guest's Add with a
footnote; jam history with per-track attribution, "Host it again" restoring the
exact tracks and "Forget"; settings rename (propagating to guests in the next
session), appearance switching and a themed Licenses page. A log sweep of all
three devices found no Unhandled/Exception/FATAL/ANR/RenderFlex; the only
AudioTrack lines were benign emulator "device stall time corrected" notices.

Two caveats specific to this rig, not to the app: mDNS **browsing** never
returns a result inside the iOS Simulator (NWBrowser reports ready and finds
nothing, while the host's registration is visible to `dns-sd` on the Mac), so
guest 1 joined by link; and the Android emulator lost its default route
mid-run, so guest 2 joined through `adb reverse` + `127.0.0.1` after an
earlier direct `10.0.2.2` join had worked.
