# LocalJam

Synchronized local-network media playback — one host shares the files, everyone
nearby joins over LAN/hotspot and listens in their own headphones, in sync,
fully offline.

## Layout

- [PROTOCOL.md](PROTOCOL.md) — the wire protocol spec (start here)
- [packages/localjam_core](packages/localjam_core) — pure-Dart engine: protocol
  messages + codec, NTP-style clock sync, anchor-based playback state machine,
  drift-correction policy. No I/O; transports and audio engines live in the
  clients.
- `app/` (planned) — Flutter client for iOS/Android/macOS/Windows, with native
  audio-scheduling channels.

## Development

```sh
cd packages/localjam_core
dart pub get
dart test
```
