# LocalJam

Synchronized local-network media playback — one host shares the files, everyone
nearby joins over LAN/hotspot and listens in their own headphones, in sync,
fully offline. No internet, no accounts. Spotify Jam, but local.

Measured on two iOS simulators over a real LAN socket: **±5 ms drift**,
corrected silently with ±0.5 % pitch-corrected rate slews.

What v1 does (PROTOCOL.md v0.2):

- **Rooms** — host a named jam, join by nearby-room discovery (mDNS), QR
  scan, or link. Every device gets a persistent quirky identity
  ("Silky Puffin").
- **Permissions** — Open / Jam / Listen-only presets over per-capability
  policy, co-host promotion, per-peer overrides, kick. Host validates every
  guest request; there is exactly one state writer.
- **A real queue** — anyone allowed can add (file pickers everywhere,
  MediaStore library on Android), reorder, and remove; items carry
  host-extracted tags + content-addressed artwork and "added by" attribution.
- **Background playback** — lock-screen/notification media card with
  capability-gated transport on iOS/Android/macOS; an Android foreground
  service keeps a backgrounded host's server alive.
- **Jam history** — every session leaves a local record (queue, attribution,
  who was there); tracks still in the cache are one tap from being hosted
  again.

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

## Development

```sh
# engine tests
cd packages/localjam_core && dart test
cd packages/localjam_net && dart test
cd packages/localjam_client && flutter test

# two-terminal demo without audio
cd apps/localjam_cli
dart run bin/localjam.dart host <files...>
dart run bin/localjam.dart join "<join-uri>" --skew-ppm 5000

# the real thing
cd apps/localjam_app && flutter run
```
