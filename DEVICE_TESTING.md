# Physical-device test checklist

## Latest design verification — 2026-10-19

The current UI built and ran on two iOS 27 simulators and an Android API 36.1
emulator. Nearby discovery, joining, the shared queue, iOS guest upload,
host pause, live guest-policy updates and deliberate session ending were
exercised. Its capture report and 26 screenshots
(`docs/screenshots/native-2026-10-19/`) are not committed: native galleries
are git-ignored and come only from a fresh pass on simulators or devices.

**This run does not confirm audio synchronization:** Android showed Out of sync,
with −862.6 ms drift and Resync recorded. GPU acceleration was disabled in the
AVD, which also showed System UI unresponsiveness. An accelerated-emulator and
physical-device timing rerun remains required. Earlier drift figures below are
historical results, not results for this design pass.

## Hardware coverage

What simulators could not verify — run these on real hardware. Everything
else (sync math, transport, lifecycle, end-of-media, reconnect) is covered by
the automated test suites and live simulator runs (drift ≤ 10 ms across three
devices, iOS + Android).

## Setup

- iOS: `cd apps/localjam_app && flutter run --release -d <iphone>` (needs your
  dev cert; add your team in Xcode Runner signing once).
- Android: `LOCALJAM_ALLOW_DEBUG_SIGNING=1 flutter build apk --release` and
  install the APK, or `LOCALJAM_ALLOW_DEBUG_SIGNING=1 flutter run --release -d
  <device>` (without a release key, release builds otherwise refuse to build).
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
   resume in sync without touching the app. During the call, press play in
   the app twice: nothing may play either time (each refused `playAt`
   re-reports the interruption, iOS and Android alike).
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
    every OS prompt (local network on iOS, camera, media library,
    notifications on Android 13+) must be preceded by the app's own sheet
    explaining why. Android shows no local-network sheet while the app
    targets API 36 (it neither declares nor asks for `ACCESS_LOCAL_NETWORK`;
    the older results below predate that). Deny
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
18. **QR scan with a real camera** — guest scans the host's Invite QR on iOS
    and Android, in bright light and on a dimmed host screen. The join confirm
    must appear and the guest land in the room. Simulators have no camera; the
    2026-10-17 run only decoded the QR from a screenshot.
19. **Nearby on Android over real Wi-Fi** — the 2026-10-19 emulator run
    discovered and joined an iOS host through Nearby. Repeat on a real phone:
    the host must appear and join in one tap (and must not see its own room).
20. **Host asleep (§3.5) on a real iPhone** — host pauses, locks for 1–2 min,
    unlocks. Guests must say "The host's phone is asleep" (controls dimmed,
    "You can add music when it wakes" in the queue), not "Reconnecting…", and
    recover to "In sync" on unlock. Then leave it locked > 10 min: guests
    should end on the room-closed screen. (Simulators never suspend the app.)
21. **Guest uploads heard on the host** — after the fix for the 2026-10-17
    finding, a guest adds a track: it must be *audible on the host phone* and
    the host's timer must show that track's own length. Then kill and relaunch
    the guest app, rejoin, and remove that track from the guest's queue.
22. **Low-end Android smoothness** — on a budget Android phone, leave Home
    and the room open for 10 min: no "isn't responding" dialog, no audible
    restarts. (The emulator on software rendering pegged the raster thread
    and hit ANRs plus a hard resync every 1–5 s.) Also scrub by tapping the
    track on an iPhone — XCUITest taps did not seek there.

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
  (arm64) container — plugin glue compiles clean under -Wall -Werror — and
  the localjam_audio example's integration tests pass there.
  Runtime audio (PulseAudio/ALSA) still needs a real machine with a sound
  device: run the app, join a session, check the same telemetry as mobile.
- **Windows**: shared miniaudio core (measured ≤0.01 ms start error on
  CoreAudio); plugin glue compiles with MinGW-w64 against the Flutter
  Windows headers, **MSVC unverified** — first task on a Windows machine is
  `flutter build windows`, then the mobile checks. Desktop v1 formats: mp3/flac/wav/ogg
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


## Simulator/emulator run — 2026-10-17 (after the protocol 1.0 hardening)

Ran live on two iOS 27.0 simulators (iPhone 18 Pro = host "Nimble Toucan",
iPhone 18 Pro Max = guest 1 "Electric Mongoose") and the Pixel_9_Pro_2
emulator (API 36, guest 2 "Silky Narwhal"), all fresh-installed from debug
builds (Flutter 3.47.5, Xcode 27.1). Driven by Maestro 1.36 (iOS, XCUITest)
and adb/uiautomator (Android); test tracks were 30–300 s tagged MP3/M4A plus
14 large WAVs (1.2 GB) for the import check. Numbers are from the in-app
Sync sheet. The Mac was heavily loaded (load average 25–40, other agents
running test suites) — that matters for the Android rows, see the caveats.

| # | Check | iOS host | iOS guest | Android guest | Notes |
|---|-------|----------|-----------|---------------|-------|
| 1 | Sync quality | ✅ | ✅ | ✅ | Guest 1 +0.1…+0.3 ms, "none", steady. Guest 2 −12…+12.7 ms, all "none", 0 resyncs in 82 s (emulator on `-gpu host`). Shared-machine clock: weak proxy. See caveat on software rendering |
| 2 | Bluetooth latency | ⬜ | ⬜ | ⬜ | needs hardware |
| 3 | Route change | ⬜ | ⬜ | ⬜ | needs hardware |
| 4 | Interruption (call) | ⬜ | ⬜ | ⬜ | needs hardware |
| 5 | Screen lock / background | ✅ | ✅ | ✅ | All three backgrounded 43 s mid-play; two end-of-media advances happened while away; on return all on the same track, iOS "In sync", Android "Catching up" → "In sync" |
| 6 | Wi-Fi blip | ⬜ | ⬜ | ⬜ | needs hardware. (An emulator crash and an emulator restart acted as hard drops: the host roster lost the guest, the rejoin was clean, no phantom) |
| 7 | Host walks away | ✅ | ✅ | ✅ | `simctl terminate` → both guests "Reconnecting… · Lost the host — still playing what you have" within 8 s, cached playback continued; still reconnecting at t+85 s; "The room closed" with Try again + Back to nearby at t+100 s. Try again against the relaunched host's new room stays on the ended screen with "Could not reach that room…" |
| 8 | Battery/thermal | ⬜ | ⬜ | ⬜ | needs hardware |
| 9 | Lock-screen media card | ⚠️ | ⚠️ | ✅ | Android shade card: LocalJam mark, title, artist, placeholder art, live progress, **no transport** for a playback-gated guest. iOS simulator still has no Now Playing UI |
| 10 | Headset/watch/car transport | ⬜ | ⬜ | ⬜ | needs hardware |
| 11 | iOS host paused + locked | ⬜ | — | — | needs hardware; the §3.5 "host asleep" path itself was exercised by backgrounding (row H below) |
| 12 | Deliberate end of jam | ✅ | ✅ | ✅ | iOS guest on "The host ended the jam" at once, Back to nearby only. Android was backgrounded at the time and showed the same screen on return. Host on home with "Jam ended · 7 tracks, 3 people" |
| 13 | Kick, then rejoin | ✅ | ✅ | ✅ | "You were removed" with Back to nearby only. Rejoin from Nearby was refused with "The host removed you from this room. They can let you back in." (no Try again). Host's people sheet listed them under Removed with **Let back in**; after it the rejoin worked and both rosters settled at exactly 3 real names. Android kill/relaunch/rejoin also left no phantom |
| 14 | Permission rationale sheets | ✅ | ✅ | ✅ | iOS local-network sheet before the first host and the first join, not repeated on the second host. Android local network → notifications → system prompt. Android media library sheet → Don't allow twice → "LocalJam cannot see your music… Open settings"; re-granted outside the app → Library worked **without a restart** |
| 15 | iOS Files app | — | ✅ | — | Guest "Add" → document picker → On My iPhone → LocalJam → the seeded file uploaded. The picker opened on Recents/Browse, not straight in the LocalJam folder |
| 16 | Android media card branding | — | — | ✅ | Mark, title and placeholder art in the shade; the compact Quick Settings player shows the artist tag on line 2 and the room name as sub-text — by design in `JamSession.kt` (the checklist's "room name as the subtitle" predates that). Lock screen / theme switch not exercised |
| 17 | Landscape | ⬜ | ⬜ | ✅ (after fix) | Android phone landscape: the run found the bottom people/queue strip **clipped**; fixed the same day (strip pinned to the foot, player scales to fit) and re-verified on Pixel_9_Pro_2 incl. a playback-gated guest. iOS has no rotation control in the harness |

New behaviours from the hardening:

| # | Behaviour | Result | Notes |
|---|-----------|--------|-------|
| A | Room opens while files import | ✅ | 18 files (1.2 GB): the room was up and playing at 00:00 right after the jam-started overlay, showing "Adding your music · 3 of 18 → 6 → 12" with the queue count climbing |
| B | QR / link / Nearby join | ✅ | Deep link joined both guests (confirm dialog each time). The QR decoded from a host screenshot is byte-for-byte the same link. **mDNS browsing now works in the iOS 27 Simulator** — guest 1 joined from Nearby; the Android emulator still sees nothing (NAT) |
| C | All in sync, advance together | ✅ | All three switched tracks together on every auto-advance, ~0.75 s of silence between tracks (host engine restarts every 35.75 s for 35.0 s files). "Starting the queue over" on the wrap |
| D | Guest upload plays everywhere | ❌ | Android (Library) and iOS (Files) uploads landed in every queue with the right "added by" and played on the *other* guests — **but the host never plays a guest upload** (no engine start for them in the host log, "AVAudioEngine: left running idle for 120 s"), and the host's timer shows the previous track's length (00:35 for a 30 s file) |
| E | Remove own track after kill/relaunch | ❌ | The relaunched guest rejoins with a new peer id: its upload shows no owner on any device and cannot be swiped away. The co-host *role* did follow the device across a fresh rejoin |
| F | Kick → refused → Let back in → rejoin | ✅ | See row 13 |
| G | Host transport propagates | ✅ | Pause / play / drag-seek / next / previous reached both guests at the same position. A co-host Android finger tap on the scrubber seeks for everyone. XCUITest taps on the iOS scrubber did not seek (dragging did) |
| H | Host backgrounded while paused | ✅ | Guest: "Host asleep" + "The host's phone is asleep" banner (not "lost the host"); queue says "You can add music when it wakes" with Add disabled. Foregrounding the host → "In sync" within 4 s |
| I | Host ends the jam | ✅ | See row 12 |
| J | Failed track → Retry | ✅ | Host file deleted + guest cache evicted: "Getting this track — 0%" for ~37 s (five backoff retries), then "Couldn't get this track · Retry"; the queue row shows a ⚠ "Could not be loaded". The host showed "Playback error · Resume audio" and "Waiting for 1 person to get this track". File restored → Retry fetched it → Play recovered all three |
| K | Upload refusal copy | ✅ | Guest picked a file, host switched "Add music" off, guest confirmed: "Could not add hotel_guest.mp3. This room is listen-only, or the host hasn't let you add tracks." Add then disabled with "The host is running this queue" |

Bugs this run turned up (details in the run report):

- **Host is silent for every guest-uploaded track.** The host's player
  resolves media only through paths it registered itself; uploads never get
  one, so the load is skipped and the room plays on without the host.
- **Track ownership does not survive a guest relaunch.** Ownership is by peer
  id, and a fresh rejoin gets a new one (the co-host role, keyed by client
  id, does survive).
- **Tapping a queue row while playing stops the room** (selects the track
  paused at 00:00 on every device) instead of playing it.
- **Landscape clips the room's bottom strip** on an Android phone.
- Smaller: the remove-guest confirm still says "They can come back with the
  room code"; ending the jam with the room sheet open trips a debug
  "ValueNotifier used after being disposed"; a track that cannot load shows
  the previous track's length; "Next up" lists playlist order, not play
  order, after a wrap; "Let back in" is not its own accessibility element.

**All of the above were fixed the same day** (with regression tests) and the
host-plays-guest-upload, landscape and play-order fixes re-verified on an
iPhone 18 Pro simulator host + Pixel_9_Pro_2 guest: the host's engine starts
for a guest's 5:00 upload, its timer runs against 05:00, drift +0.4 ms.
Tapping a queue row while playing now plays it; re-picking the current track
does nothing (restart = seek to 0). Ownership follows the device across a
relaunch or a kick → let back in. Repeated drift-triggered hard resyncs now
back off (2 → 4 → 8 → 10 s) instead of restarting audio every second.
Checklist item 21 is still needed on real phones.

Caveats specific to this rig: with the emulator on software rendering
(`lavapipe`) and the Mac at load 25–40, the Android guest drifted −20…−190 ms
and hard-resynced every 1–5 s (thousands of "device stall time corrected" /
`pcm_writei failed` lines), and Home hit two "isn't responding" dialogs with
the raster thread at 118 % CPU. Relaunched on `-gpu host -no-window`, the
same guest held ±13 ms with no resyncs. The emulator also crashed once under the
load ("hanging thread"), which is how row 6 got its unplanned drop.
