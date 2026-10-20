# Web guest ("join from a browser") — design brief

Status: decided 2026-10-20. Protocol 1.2 (additive). Built, pending device testing.

## Why

Android ships first; iOS later. Until then an iPhone (or any laptop) at the
party must still be able to join and listen. The host phone serves a web
build of a small listener app from the same port it already serves the
protocol on, so **one person with the app installed can host, and everyone
else joins from a browser with no internet and no install**.

Browsers are guests only, never hosts (PROTOCOL.md goal 5).

## Decisions

| # | Decision | Reason |
|---|---|---|
| D1 | Listener page is a **Flutter web** app, `apps/localjam_web`. | Shares `localjam_core` (ClockSync, protocol) and the audio sync controller; one stack for the team. Payload (~2 MB) loads over LAN in well under a second. |
| D2 | The host **bundles the web build in the APK** and serves it. No hosted site. | Must work offline. An https page could not open `ws://` or fetch `http://` from a LAN IP anyway. |
| D3 | **Plain http, no TLS.** PROTOCOL.md §9/§11 are rewritten: TLS is not a prerequisite for a web guest. | Web Audio, WebSocket, fetch and `performance.now()` all work on a plain `http://` LAN origin. Only service workers, PWA install and wake lock need a secure context, and listening needs none of them. A self-signed cert on a LAN IP gives every browser an interstitial and nothing to pin. |
| D4 | **One join URL, http form, token in the fragment.** The QR, the share sheet and the Nearby list all carry it. `localjam://` stays valid (deep links, "Open in app"). | Phone cameras open http URLs with no app installed. The fragment is never in an HTTP request or a `Referer` — which keeps the token out of the page's request and its logs, not off the network: it stays in browser history, and crosses the LAN in `hello` and the media bearer like every guest's (§9). |
| D5 | Phase 1 = **listen + control requests** when the room's permissions allow; no browser uploads. Phase 2 = uploads via a file input over the existing `POST /media`. | Control is one `request` frame; uploads need UI and testing we do not need for launch. |
| D6 | Web Audio with `AudioBufferSourceNode.start(when)` (PROTOCOL.md §5.3), **not** an `<audio>` element driving playback. On iOS the graph is routed through a `MediaStreamAudioDestinationNode` into a playing `<audio>` element so the context survives screen lock and gets lock-screen controls. | Sample-accurate start; `<audio>.currentTime` is tens of ms coarse. |
| D7 | **Decode only the current track** (one `AudioBuffer` at a time; `load` replaces). Raw bytes of prefetched items stay as `Uint8List` under a budget. | A 5-min track decodes to ~100 MB of PCM; mobile tabs die past ~1 GB. |
| D8 | The page makes **zero off-origin requests**. Fonts and CanvasKit are bundled; no Google Fonts, no CDN, no service worker. | Offline is the whole point. |

## Join URL (protocol 1.2, §1 addition)

```
http://192.168.1.7:44100/join#v=1&token=<sessionToken>&name=RoadTrip&host=192.168.1.7,192.168.43.1
```

- Path is `/join`. The **fragment is a query string with exactly the keys of
  the `localjam://join` query** (`v`, `token`, `name`, `host`), same encoding.
- `host` in the fragment is optional. Absent ⇒ the URL's own `host:port` is the
  sole candidate. Present ⇒ it lists every candidate (comma-separated, as
  today); the URL's own host SHOULD be first. Port is the URL's port for all.
- A native joiner accepts both forms and builds the same join parameters. The
  same on-LAN checks (§9) apply to every candidate.
- The web page reads its own fragment; its host is its origin.
- Share text and QR carry the http form. The host picks the URL's host the
  way it picks the first `host=` candidate today.

## Host routes (protocol 1.2, §1/§6 addition)

Unauthenticated, `GET` only, same per-connection limits and `Connection: close`
as everything else (§9.1), plus a send deadline (the longer of 10 s and the
response's size at 32 KB/s) so that a client reading nothing cannot hold a
connection slot. No token is needed to fetch the page; the token is needed
to do anything with it.

| Route | Serves |
|---|---|
| `GET /` and `GET /join` | the page's `index.html` — `text/html; charset=utf-8`, `Cache-Control: no-store` |
| `GET /web/<path>` | a bundle file by exact path (after the HTTP stack's dot-segment removal) — its MIME, `Cache-Control: no-cache` (`no-store` for `index.html`), `ETag` (sha256 prefix), `304` on `If-None-Match` with no `Content-Type` and no body framing |
| anything else | unchanged (`/ws`, `/media`, `/media/{id}`, `/artwork/{id}`); unknown paths `404` |

- The host server (`localjam_net`, pure Dart) takes an optional **static
  site**: an immutable map `path → (bytes, mime)` the embedder loads once (the
  app from its asset bundle; the CLI from a `--web-dir`). Served from memory.
- When no site is configured, `/` and `/join` return a small built-in HTML
  page: room name is unknown to it, so just "This LocalJam room has no
  browser player. Install the app." No external resources.
- The bundle is built with `--base-href /web/` so `index.html` at `/join`
  resolves its assets under `/web/`. Nothing in the bundle may collide with
  `/ws`, `/media`, `/artwork`.

## Web page behaviour

Reads `Uri.base.fragment` at startup (path URL strategy — Flutter's default
hash routing would eat the fragment; use no router).

1. **Landing**: brand, room name, a name field (generated default like the
   app's identity names, persisted in `localStorage`), one primary button
   "Tap to listen". The tap is the user gesture that creates the
   `AudioContext` (and on iOS starts the `<audio>` element).
2. **Join**: `ws://<origin>/ws`, `hello { clientKind: "web", clientId }`
   (`clientId` persisted in `localStorage`). Clock pings use
   `performance.now()` as the monotonic clock. Everything in §3–§5 applies
   unchanged: reconnect with `resumePeerId`, host away copy, `session_ended`
   is terminal, every reject is final.
3. **Media**: `fetch('/media/{id}', Authorization: Bearer)` with the whole
   body kept as bytes (§6.2 full prefetch), bounded connections (≤ 6), 10 s
   stall timeout, `media_status` reports. **`ready` is reported only after the
   item decodes.** A `decodeAudioData` failure (Ogg/Opus on Safari) marks the
   item "Can't play in this browser", reports `none`, and never blocks the
   room (§6.3 waits only for `fetching`).
4. **Playback**: `startAt` maps performance time → context time via
   `AudioContext.getOutputTimestamp()` (fallback: sample `currentTime` against
   `performance.now()`). Drift (§5.4): 15–50 ms → `playbackRate` ±0.5 %;
   > 50 ms → stop the source node and start a new one at the computed offset.
   Output latency: `outputLatency + baseLatency` where reported (Chrome,
   Firefox); Safari reports none, so the manual nudge is prominent.
5. **Room view**: cover (fetched with bearer → blob URL), title/artist, sync
   state (synced / fetching / waiting for host / host's phone is asleep /
   reconnecting), who's here, the queue with the current item marked,
   play/pause/previous/next and tap-to-select **only when the permission
   document grants `control_playback`**, mute, sync nudge ±500 ms in 10 ms
   steps persisted per page, "Open in app" (`localjam://join?...`), "Keep this
   page open" hint. Rejected/ended states have copy, never a spinner.
6. Visual language follows `docs/design/DESIGN_SPEC_V3.md` tokens, but the
   page is deliberately small: a phone-width column that also looks fine on a
   laptop.

## Packaging

- `tool/build_web_guest.sh`: runs `apps/localjam_web/tool/build.sh`
  (`flutter build web --release --base-href /web/ --no-web-resources-cdn
  --pwa-strategy none`, then scrubs Flutter's unused CDN defaults to
  same-origin paths, prunes what a dart2js build never loads, and fails if
  `gstatic`/`googleapis` remain; about 17 MB), then copies `build/web` into
  `apps/localjam_app/assets/web/` (committed build output is **not** wanted;
  the directory is gitignored apart from one `.gitkeep` per directory the
  app's pubspec declares, and CI/release builds run the script first). The
  script warns when the build's directories and the pubspec's list differ. The app's host engine loads that directory from the
  asset bundle into the static site at host start; a missing bundle degrades
  to the built-in page.
- `localjam_cli host --web-dir <path>` serves a directory the same way.

## Code boundaries (who owns what)

| Area | Change |
|---|---|
| `localjam_core` | `JoinLink`: parse/format both URL forms (pure Dart, tested). |
| `localjam_net` guest | `dart:io` behind a transport interface with `io` and `web` (`package:web`) implementations via conditional imports; `package:localjam_net/guest.dart` barrel that compiles for web. Host server stays io-only. |
| `localjam_net` host | static site routes + `StaticSite` type; built-in fallback page. |
| `localjam_audio` | inline web platform (`web:` in pubspec, `registerWith`) answering the **same method channel**: `nowUs` = `performance.now()` µs; `load(url)` fetches a `blob:`/same-origin URL and decodes; `startAt`, `pause`, `stop`, `positionUs`, `setRate`, `outputLatencyUs`, `currentRouteId` (null), events `playbackFinished`, `playbackError`, `interruptionBegan` (context suspended). |
| `localjam_client` | guest engine, media cache and audio sync controller compile for web (conditional imports: in-memory media cache with budget, no `path_provider`, discovery stubbed); host engine passes the static site. |
| `apps/localjam_web` | the page. |
| `apps/localjam_app` | `parseJoinUri` accepts the http form; QR and share carry it; host engine wiring for the bundle. |
| `apps/localjam_cli` | `--web-dir`. |
| `PROTOCOL.md` | 1.2: join URL http form, static routes, `clientKind: "web"` notes, §9/§11 TLS rewrite. `CHANGELOG.md`. |

## Test plan

- Unit: JoinLink both forms; static routes (200/304/404, headers, limits);
  web transport and web audio under `flutter test --platform chrome`.
- E2E on the Mac: `localjam_cli host --web-dir` with `test-media/`, open the
  join URL in Chrome and Safari, verify zero off-origin requests, sync within
  target against a CLI guest.
- **Manual, Bibek**: Android host + iPhone Safari guest. Screen lock while
  playing, tab in background, Bluetooth headphones + nudge, reconnect after
  Wi-Fi blip, Ogg item marked unplayable, host ends jam.

## Known limits (say them in the UI where it matters)

- Browser listening is best-effort: keep the page open; iOS needs the
  `<audio>` route to survive screen lock and that is what the iPhone test is
  for.
- Ogg Vorbis/Opus do not play in Safari.
- Safari reports no output latency; Bluetooth users nudge by hand.
- No uploads from the browser in phase 1.
