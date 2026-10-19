# Changelog

Notable changes to LocalJam. Dates are the day the work landed on `main`.

## Unreleased

### Design

- Full visual overhaul: a raspberry / plum / cream brand, Plus Jakarta Sans
  throughout (roman weights, real tabular figures so the room timer stops
  jittering), and a light-first palette with a matching dark theme.
- New app icon, adaptive and monochrome Android layers, and launch screens on
  every platform — no white flash between the splash and the first frame.
- Artwork now tints the room: a clamped, contrast-safe accent derived from the
  cover art, used only for ambience (glow, background wash, room-bar wash) and
  never for text, icons or controls.
- The room is the subject: people, roles and attribution are first-class, the
  sync indicator is quiet while correct, and the queue and people sheets share
  one visual language.
- Responsive layout — sidebar navigation and a docked room panel on wide
  screens, a drag-to-dismiss player on phones.
- Three-panel onboarding on first run.

### App

- Nearby jams, QR and `localjam://` links all land in the same join flow;
  discovery restarts when you return to the home screen.
- Permission rationale sheets before every OS prompt (local network, camera,
  media library, notifications), with a route into Settings after a denial.
- Room now shows "The host ended the jam" as its own terminal state, distinct
  from a host that vanished, and does not offer "Try again" for it.
- Attribution uses the host's real identity name instead of a generic "Host".
- Jam history: accurate "Host it again" labels, and replaying a record loads
  that record's tracks only.
- Diagnostics, nudge sync and the appearance setting reworked to match the new
  design; dead widgets removed.
- ~250 widget and state tests added for the app layer.

### Engine / protocol

- **PROTOCOL v0.2** (additive; v0.1 clients interoperate unchanged):
  - `session_ended` (§3.4) — a host that ends a jam deliberately says so, and
    guests reach the terminal state at once instead of burning the 90 s
    host-gone timeout. An unannounced death still falls back to the timeout.
  - `hello.clientId` (§3.1/§3.3) — a stable per-device id, so a reconnecting
    guest reconciles onto its existing peer entry rather than appearing twice.
  - `welcome.host` (§3.1) — the host arrives as a named peer, not an anonymous
    one.
- Hardened the host server against an unfriendly LAN neighbour: caps on peers
  (32), half-open connections awaiting `hello` (16), control-frame size
  (256 KB), queue length (500) and single-upload size (512 MB), plus a hello
  timeout that drops sockets that never authenticate.
- Discovery, keep-alive, identity, history and media-cache paths reworked and
  covered by new tests.
- `JamHostEngine.setDiscoverable` turns a room's mDNS advertisement off and
  on mid-jam (§1): off sends goodbyes, on starts it like `start()` does, both
  inside the advertising budget; changes are queued behind the network
  re-scan's responder restarts, and a re-scan never re-shows a room the host
  hid. `discoveryEnabled` / `discoveryEnabledListenable` carry the host's
  choice for the UI.
- Nearby lists one row per jam. A room is its token: two mDNS instances with
  one token (a DNS-SD "(2)" rename, a re-advertise under a new name) are one
  row, the newest advertisement, and when that one says goodbye the
  instances it replaced stay hidden until they prove they are still there.
  The built-in fallback responder now announces its own instance name
  (`… 6537b`): sharing the daemon's name let the registration the host had
  given up on rename itself into a second row, and its goodbye removed the
  live room from every browser a few seconds after it appeared.

### Android

- Foreground-service and audio fixes: the media card is the foreground-service
  notification (one notification, not two), it carries the LocalJam mark, the
  room name and the track's artwork, and transport from the card round-trips
  into the engine at the right position.
- Application id and namespace are now `np.com.bibektimsina.localjam`.
- `allowBackup="false"` with matching data-extraction and backup rules: the
  media cache, artwork, jam history and device identity never leave the
  install.

### iOS / macOS

- `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace`: the LocalJam
  folder appears in the Files app, which is the only way to get audio onto a
  fresh phone.
- Proper display name, `localjam://` URL scheme registration, and rewritten
  permission usage strings.
- Vendored a patched `bonsoir_darwin` under `packages/third_party/`: upstream
  7.1.1 waits for the DNS-SD daemon synchronously on the platform main thread,
  which on Flutter's merged UI thread kills the whole app when the daemon never
  answers (always on the Simulator, sometimes on hardware). The fork moves the
  registration to a background queue and changes nothing else. See
  `packages/third_party/bonsoir_darwin/PATCHES.md`.

### Security

- Session tokens are compared in constant time on both planes.
- The host refuses non-LAN remote addresses with a 403 on both the control and
  media planes — the enforcement half of PROTOCOL §9's "LAN interfaces only".
- Resource caps as above, so an honest-guest threat model does not mean an
  unbounded one.

### Tooling

- GitHub Actions CI: analyzer and tests for every package, plus Android, iOS
  simulator and Linux build jobs.
- Android release signing scaffold — `android/key.properties` (git-ignored)
  with a checked-in example, R8 minify and resource shrinking, and ProGuard
  keeps for the Flutter embedding, the `localjam_audio` plugin and ML Kit.
- `CONTRIBUTING.md`, issue and pull-request templates, and a rewritten public
  `README.md`.
- `dart format` across every first-party package and app.
