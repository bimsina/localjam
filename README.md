# LocalJam

<p align="center">
  <em>Listen together, in sync, over local Wi-Fi — no internet, no accounts.</em>
</p>

One person hosts a jam and shares the files; everyone nearby joins over the LAN
or the host's hotspot and hears the same thing at the same instant, in their own
headphones, fully offline. No servers, no sign-in, nothing leaves the room.
Spotify Jam, but local — in the spirit of LocalSend.

Measured between devices on a real LAN socket: **±5 ms drift**, corrected
silently with pitch-corrected **±0.5 %** rate slews — inaudible nudges, never
audible seeks. On macOS a joining device settled at **−0.4 ms**.

## What it does

- **Rooms.** Host a named jam; guests join three ways — nearby-room discovery
  (mDNS), a QR scan, or a `localjam://join?…` link shared from anywhere. Every
  device carries a persistent, quirky identity ("Silky Puffin") so the room
  knows who is who across sessions.
- **Permissions that read like a decision, not a form.** Three presets —
  **Open**, **Jam**, **Listen-only** — over a per-capability policy, plus
  co-host promotion, per-peer overrides, and kick. The host validates every
  guest request; there is exactly one state writer.
- **A shared queue.** Anyone allowed can add (file picker on every platform, the
  MediaStore library on Android), reorder, and remove. Items carry
  host-extracted tags, content-addressed artwork, and **"added by"**
  attribution — including the host, under their own name.
- **Background playback with a real media card.** Lock-screen / notification
  metadata and transport on iOS, Android and macOS, gated by the same
  capabilities as the in-app controls: a listen-only guest gets a card with no
  transport, and grows one live the moment the host promotes them. An Android
  foreground service keeps a backgrounded host's server alive.
- **Ending a jam is a thing you do, not a thing that happens.** The host's
  "End jam" broadcasts a goodbye and guests land on *"The host ended the jam"*
  immediately, instead of waiting out a 90-second timeout. An unannounced death
  still degrades gracefully.
- **Jam history.** Every session leaves a local record — the queue, the
  attribution, who was in the room. Tracks still in the cache are one tap from
  being hosted again.
- **Onboarding and permission rationale.** A three-card first run explains what
  the app is, and every OS permission (local network, camera, media library,
  notifications) is asked for behind a sheet that says why — before the system
  prompt, never after it.

## Platforms

| Platform | Status |
| --- | --- |
| **iOS** | Live-verified on simulators (host + guest, mDNS join, background audio, media card pushes). Physical-device checks are the open list in [`DEVICE_TESTING.md`](DEVICE_TESTING.md). |
| **Android** | Live-verified on a Pixel 9 Pro emulator (API 36): MediaStore library, foreground-service media card with a working pause round-trip, background playback, process-death recovery. |
| **macOS** | Live-verified — the app joined a session at −0.4 ms drift. Full format support via `AVAudioEngine`. |
| **Linux** | **Build-verified** in an Ubuntu 24.04 (arm64) container; plugin glue compiles clean under `-Wall -Werror`. Runtime audio (PulseAudio/ALSA) has not been exercised on real hardware. |
| **Windows** | **Build-unverified.** Shares the miniaudio core measured at ≤0.01 ms start error on CoreAudio; the Windows plugin glue has never been compiled. First task on a Windows machine is `flutter build windows`. |

Desktop v1 decodes mp3 / flac / wav / ogg. `m4a`/AAC returns
`unsupported_format` on Windows and Linux (OS-codec decode is a later add);
iOS, Android and macOS handle it natively.

## Screenshots

> Not captured yet — these paths are the shot list.

| | |
| --- | --- |
| `docs/screenshots/home.png` — home with nearby jams | `docs/screenshots/room-light.png` — the room, light |
| `docs/screenshots/room-dark.png` — the room, dark | `docs/screenshots/queue.png` — shared queue with attribution |
| `docs/screenshots/people-invite.png` — people, roles and the invite QR | `docs/screenshots/onboarding.png` — first run |

## Architecture

```
PROTOCOL.md            the wire protocol (start here)
packages/
  localjam_core        pure Dart: messages + codec, NTP-style clock sync,
                       anchor playback state machine, drift policy (no I/O)
  localjam_net         transport: JamHostServer (WS control + HTTP media
                       planes), JamGuestClient, JamGuestSession (auto-
                       reconnect), end-of-media policies
  localjam_audio       Flutter plugin: sample-accurate scheduled playback on
                       the native clock (AVAudioEngine on iOS/macOS, Android,
                       miniaudio on Windows/Linux), interruption/route
                       events, plus the OS media session — lock-screen /
                       notification metadata + transport controls, and the
                       Android foreground-service keep-alive
  localjam_client      the embeddable engine: JamHostEngine + JamGuestEngine —
                       transport + prefetch + clock calibration + drift
                       correction + OS media session + room discovery +
                       device identity + jam history behind one API. UI apps
                       depend on this only.
  third_party/
    bonsoir_darwin     vendored fork of bonsoir_darwin 7.1.1 (MIT, Skyost)
apps/
  localjam_cli         headless demo client (simulated playback, telemetry)
  localjam_app         Flutter app (iOS/Android/macOS/Windows/Linux) — thin
                       UI over localjam_client
```

The sync model in one line: the host broadcasts an **anchor**
(`position P at session-clock time T`); every client computes
`position(t) = P + (t − T) × rate` against an NTP-synced clock and schedules
audio natively at the exact instant — drift is corrected with inaudible
±0.5 % slews, never audible seeks.

**Why `third_party/bonsoir_darwin`:** upstream 7.1.1 confirms a DNS-SD
registration with a synchronous `DNSServiceProcessResult` on the platform main
thread. Since Flutter merged the UI thread onto the platform thread on iOS, a
daemon that never answers — which is *always* on the Simulator, and possible on
hardware while the Local Network prompt is unanswered — wedges the Dart isolate
and takes the whole app down. The vendored copy moves the registration to a
background queue and changes nothing else; see
[`packages/third_party/bonsoir_darwin/PATCHES.md`](packages/third_party/bonsoir_darwin/PATCHES.md).
It is wired in through `dependency_overrides` (which do not propagate, so every
consumer that builds for Apple platforms repeats the entry).

## Security model

LocalJam v1 is *honest-guest, hostile-network-lite* — the threat model of a
living room, not a coffee shop. In full: [`PROTOCOL.md` §9](PROTOCOL.md).

- **A token gates everything.** A 128-bit random session token, carried in the
  QR / join link, guards both the WebSocket control plane and the HTTP media
  plane. It is compared in constant time, so a wrong guess leaks nothing about
  how wrong it was.
- **Discoverable means invited.** A host that opts into mDNS is deliberately
  broadcasting that token to its network segment — "everyone on this Wi-Fi is
  welcome, for this session". Turning discovery off makes the QR or the link
  the only way in.
- **LAN only.** The host refuses requests from non-LAN remote addresses with a
  403 on both planes — loopback, RFC1918 v4, link-local and v6 ULA pass,
  everything else does not. Binding a LAN interface is only half of §9's rule;
  this is the other half.
- **Honest should not mean unbounded.** The host caps peers (32), half-open
  sockets awaiting `hello` (16), control frames (256 KB), queue length (500)
  and a single upload (512 MB), and drops sockets that never authenticate.
- **Nothing leaves the device.** No accounts, no telemetry, no network calls off
  the LAN. On Android, `allowBackup="false"` plus backup rules keep the media
  cache, artwork, history and identity out of cloud backup and device transfer.

Traffic is plaintext in v1. TLS with a self-signed cert pinned via the QR is the
documented upgrade path, required before any future browser guest.

## Development

Flutter **3.44.5** / Dart **3.12.2** (see `.github/workflows/ci.yml` for the
pinned CI toolchain).

```sh
cd packages/localjam_core   && dart test      # 141 tests — protocol, clock, anchors, permissions
cd packages/localjam_net    && dart test      #  99 tests — transport, robustness, integration
cd packages/localjam_client && flutter test   #  91 tests — engines, discovery, history, lifecycle
cd packages/localjam_audio  && flutter test   #  13 tests — plugin surface
cd apps/localjam_cli        && dart test      #  12 tests — headless sync smoke
cd apps/localjam_app        && flutter test   # 251 tests — screens, widgets, state
```

607 tests in total, all green, no network required.

```sh
# two-terminal demo without audio
cd apps/localjam_cli
dart run bin/localjam.dart host <files...>
dart run bin/localjam.dart join "<join-uri>" --skew-ppm 5000

# the real thing
cd apps/localjam_app
flutter run              # whatever device is attached
flutter run -d macos
flutter run -d windows
flutter run -d linux
```

Two devices on the same network are the point: host on one, join on the other.

Regenerating the app icon and launch screen after touching `assets/brand/`:

```sh
cd apps/localjam_app
dart run flutter_launcher_icons
dart run flutter_native_splash:create
```

Both generators are configured from `pubspec.yaml`, and
`flutter_native_splash:create` stomps two hand-made edits every time — see
[`apps/localjam_app/README.md`](apps/localjam_app/README.md), which also covers
Android release signing (`android/key.properties`), R8 rules, and the
per-platform notes.

Before pushing hardware changes, work through
[`DEVICE_TESTING.md`](DEVICE_TESTING.md) — the checklist of everything
simulators cannot prove.

## Contributing

Bug reports, device-test results (especially on Windows and Linux hardware) and
patches are all welcome. Start with [`CONTRIBUTING.md`](CONTRIBUTING.md) and
[`PROTOCOL.md`](PROTOCOL.md); recent changes are in
[`CHANGELOG.md`](CHANGELOG.md).

## License

[MIT](LICENSE) © Bibek Timsina. Vendored third-party code keeps its own
licenses — `packages/third_party/bonsoir_darwin/LICENSE` (MIT, Skyost),
`packages/localjam_audio/src/third_party/LICENSES.md` (miniaudio, dr_libs,
stb_vorbis), and Plus Jakarta Sans under the OFL 1.1
(`apps/localjam_app/assets/fonts/OFL.txt`).
