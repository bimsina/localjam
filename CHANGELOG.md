# Changelog

Notable changes to LocalJam. Dates are the day the work landed on `main`;
a release heading carries the day it shipped.

## Unreleased

- Lifecycle hardening: disposing the app's session controller now closes the
  live jam (server, playback, foreground service) and drops any host start or
  join still in flight instead of attaching it; and a host add that is still
  probing, reading tags or hashing when the room ends registers nothing and
  leaves no cover behind.

## 1.0.0 (Android): not yet released

The first public release, on Google Play, Android first (iOS and desktop run
from source). Everything below, down to the end of this file, is in it.

- Listen together over local Wi-Fi or a hotspot: host a jam, guests join from
  Nearby, a QR code or a link, and every phone plays in sync. No internet, no
  accounts, no data collected.
- A shared queue with "added by", room presets (Open, Jam, Listen-only),
  co-hosts and per-person permissions, background playback with a media
  card, jam history, and a browser listener page for guests without the app.

### Release readiness (Android, open source)

- A release build without `android/key.properties` now **fails** instead of
  silently signing with the debug key. `LOCALJAM_ALLOW_DEBUG_SIGNING=1` (or
  `--android-project-arg=localjam.allowDebugSigning=true`) opts in to a
  local, non-distributable debug-signed release build.
- `targetSdk` is pinned to 36 (Play's requirement from 2026-08-31) instead of
  following the Flutter tool, so a Flutter upgrade cannot move it silently.
- A network-security config keeps cleartext HTTP off for the platform
  (Java/Kotlin) networking stack. The jam's own LAN traffic goes through
  `dart:io` and is unaffected.
- ML Kit's usage-statistics upload (pulled in by the QR scanner) is disabled
  by removing the `datatransport` backend from the merged manifest, so the
  app sends nothing to Google.
- Verified 16 KB page-size compatibility of every bundled native library.
- New `PRIVACY.md`, `SECURITY.md`, `docs/release/` (Android release and
  signing guide, Play Data safety answers, store listing draft), feature
  request and device-test issue templates, and a rewritten `README.md`.

### Join from a browser

Best-effort, and built but not yet tested on real phones (Android host,
iPhone Safari guest): see `docs/design/WEB_GUEST.md`.

- Someone without the app joins from the browser. The host phone serves a
  small listener page (`apps/localjam_web`) from the port it already uses, so
  it works with no internet and no install: one person hosts, everyone else
  scans the QR or opens the link.
- One join link: the http form (protocol 1.2, below) is what the QR, Share
  Link, Copy Link and Nearby carry. A phone camera opens it in the browser;
  the app, `localjam join` and deep links read the same link, and
  `localjam://` keeps working for "Open in app".
- A browser guest can join, listen in sync with everyone else (Web Audio,
  started at the room's shared time, nudged by hand like the app's sync
  nudge), see who's there and the queue, and play, pause, skip and pick songs
  when the room's permissions let guests control playback. It cannot add
  songs and cannot host. Keep the page open: a backgrounded or locked tab may
  stop.
- Safari cannot play Ogg Vorbis or Opus: those songs show "Can't play in this
  browser" for that guest and never hold up the room. Safari also reports no
  output latency, so Bluetooth listeners there nudge sync by hand.
- The host's Invite says "No app needed: the link opens in the browser." only
  while its room is actually serving the page. A build without the page
  answers the link with a short "install the app" page.
- The page loads nothing from the internet: fonts and CanvasKit come from the
  host. `tool/build_web_guest.sh` builds it (through
  `apps/localjam_web/tool/build.sh`, about 17 MB) into the app's assets; the
  build output is never committed.
- A listener whose tab is in the background stays in the room. Chrome
  coalesces a hidden, silent page's timers to one wake-up a minute after
  five minutes, so a paused room's browser guest pinged once a minute and
  the host dropped and re-admitted it every 12–40 s. The guest's pings,
  liveness watchdog, reconnect backoff and drift self-check now tick from a
  dedicated Web Worker (`JamTicker` in `localjam_net`, started from a
  same-origin `blob:` URL; plain timers natively and wherever a worker
  cannot start). PROTOCOL.md §3.3 now says a browser guest must schedule
  its pings that way. `packages/localjam_client/tool/web_engine_test.sh
  --throttling` reproduces the drop on page timers and shows the worker
  keeping the guest joined.
- The page tells "this browser cannot play this" from "the check did not
  work this time": a decode check answers `unsupported_format` only for
  bytes the browser cannot decode; a failed fetch or a decode that failed
  for another reason (`load_failed`, `engine_error`), or a check that
  outlives the engine's `decodeProbeTimeout` (60 s), is retried and never
  marks the song unplayable.
- The current song decodes once, not twice: `probeDurationUs(keepForLoad:)`
  keeps the decoded buffer for the `load` that follows (one buffer at most;
  native ignores it).
- Songs too big or too long for a tab are refused before any byte is
  fetched: `JamMediaStore.refuses` answers `too_large` (bigger than the
  in-memory budget) or `too_long` (past 20 minutes of decoded audio), and the
  song shows as unplayable for that listener instead of taking the page
  down mid-decode. Natively nothing is refused.
- Leaving a jam on the page keeps its audio context (web `dispose` releases
  the buffer and the node only), so "Try Again" or the next jam plays
  without a second tap — iOS Safari refuses a context made outside one.
- The invitation is kept in the tab's `sessionStorage` and the token is
  dropped from the address bar with `history.replaceState`; a reload reads
  it back.

### Host's library as a catalog (engine)

Protocol 1.3 (additive, `v` stays 1; PROTOCOL.md §6.6, brief in
`docs/design/LIBRARY_CATALOG.md`). Engine and protocol only so far: the
app's "Share my music library" switch and the browse sheet are still to
come.

- A host can offer a catalog — a list of songs (on Android, its music
  library) the room can browse and add from. Off by default and switchable
  live; each switch broadcasts `catalog { rev, count }`, and
  `welcome.catalog` tells a joiner. Guests fetch the list from
  `GET /catalog` only when `rev` changes, and covers from
  `GET /catalog/{id}/artwork` only for the rows they show; the host reads a
  cover from the file when first asked — at most 3 at once, `503` past a
  short wait line — and keeps a small cache. A refresh that changes nothing
  broadcasts nothing.
- `request { action: "catalog_add", catalogIds }` adds songs to the queue,
  one at a time in the background, the way the host adds its own files
  (sha256, probe, tags, cover), credited to the guest who asked. Needs
  "Add songs"; at most 50 ids a request, 128 adds pending in the room and 50
  per guest (one full request), past which the host answers the new `busy` error. Re-adding a
  song already queued, or already on its way, changes nothing and is not
  read or hashed again; an add the room no longer wants (catalog off, the
  guest kicked or without "Add songs") stops midway and leaves nothing
  behind. A catalog-added playlist item carries the new optional
  `catalogId` (§6.1), so a guest can mark that row as queued; uploads and
  the host's own files carry none.
- Listing is not serving: a song's bytes can be fetched only once it is in
  the queue, so nobody can download a library by its ids.
- `localjam_core`: `MediaItem.catalogId`, `CatalogSummary`, `CatalogEntry`,
  `CatalogListing`, `CatalogMessage`, `WelcomeMessage.catalog`,
  `RequestAction.catalogAdd`, `RequestMessage.catalogIds`, `ErrorCode.busy`. `localjam_net`:
  `JamCatalogProvider` (with `openForArtwork`), `JamHostServer.setCatalog`
  / `addFromCatalog` / `mediaFile` / `maxPendingCatalogAddsPerPeer`, `JamHostEventKind.catalogAdded`, and on `JamGuestSession`
  `catalog`, `catalogChanges`, `fetchCatalog`, `requestCatalogAdd`,
  `fetchCatalogArtwork`.
- `localjam_client`: `JamCatalogSource` and `JamMediaLibraryCatalogSource`
  (the Android library: `c_<MediaStore id>`, copied out of scoped storage
  only when a song is added; covers are read in place or not at all,
  `openForArtwork`); `JamHostEngine.shareCatalog`,
  `catalog`, `catalogEntries`, `addFromCatalog` and `catalogAdds` ("Mia
  added Night Drive from your library"); `JamGuestEngine.catalog`,
  `fetchCatalog`, `requestCatalogAdd` (big selections sent 50 ids a
  request) and `catalogArtworkFor` (memoised, bounded, dropped on a new
  rev); `busy` arrives on `errors` like `not_allowed`. The host plays a
  catalog-added song from the library file itself. The CLI host logs
  catalog adds.

### Design

- **Identity v4.1** — LocalJam's own look: Apple-inspired ease without
  reading as Apple Music. Warm paper and warm-charcoal palettes, Manrope for
  names and headings with the system font for body text, raspberry only on
  what you can tap, soft rectangles instead of capsules. Spec:
  `docs/design/DESIGN_SPEC.md`.
- Song-first room: a matte wash sampled from the cover's main colour, an
  ivory play square, skip buttons with end bars, one-line titles that scroll
  when they're too long (and stay still under Reduce Motion), and a footer
  that names who's there ("With Mia and Theo").
- People and jams: each person keeps one colour on every screen; a jam has
  one tile and one cover across Nearby, Invite, Past jams and the ended page;
  queue credits show a friend's face only on songs someone else added.
- Sheets, alerts and menus opened inside the room stay dark in both themes.
  Dark-mode destructive buttons and the other contrast failures are fixed.
- Large text is a real layout: Now Playing, Nearby and every button hold from
  320 pt phones up to the largest accessibility sizes; tablet, desktop and
  landscape layouts line up.
- Sentence case for all UI copy.
- New app icon, adaptive and monochrome Android layers, and launch screens on
  every platform — no white flash between the splash and the first frame.

### App

- Nearby shows who hosts a jam when the host advertises it.
- Past jams keep their cover and find their songs after the app is updated or
  reinstalled, and list the host first, as the room does.
- Ended and failed-rejoin pages name the jam; a restarted jam offers
  "Scan code"; "Back to Nearby" works while a rejoin is still trying.
- Fix: songs picked through the iOS Files app no longer vanish about a minute
  after import — they're copied into the app's own storage.
- Fix: iOS Reduce Motion is honoured everywhere (it was ignored).
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
- People sheet: "Show to People Nearby" is a switch the host can flip
  mid-jam (it was a sentence saying it was fixed at the start), and Remove
  says "They can’t rejoin until you let them back in." only when the engine
  can actually hold that device.

### Engine / protocol

- **PROTOCOL 1.2** (additive; no frame changes): the groundwork for joining
  from a browser.
  - The join URL has an http form, `http://host:port/join#v=1&token=…&name=…&host=…`
    — the `localjam://` query's keys in the fragment, so the token never
    travels in a request (§1). The host's QR, Share Link and Copy Link carry
    it, and so do nearby rooms; scanning, pasting and deep links accept both
    forms through one parser (`JoinLink` in `localjam_core`), and every
    candidate of either form passes the same on-LAN check (§9). The token
    in the fragment is kept out of requests and `Referer`s, not secret: it
    is in browser history, and on the LAN in `hello` as always (§9).
    Caveat: a 1.0/1.1 app cannot read an http QR. The `localjam://` form
    stays valid for deep links and the page's "Open in app", but the host
    app's QR, Share and Copy carry only the http form, so such an app joins
    from Nearby (no 1.0/1.1 app was released).
  - The host serves a browser guest's page without a token (§1.1): `GET /`
    and `/join` answer with the page (`no-store`), `GET /web/<path>` with its
    bundle from memory (`no-cache`, sha256 `ETag`, `304`; `index.html`
    there is `no-store` too), under the same LAN-only rule and §9.1 limits
    as everything else, plus a send deadline — the longer of 10 s and the
    response's size at 32 KB/s — so a client that reads nothing cannot keep
    a connection slot. With no bundle, a small
    built-in page says to install the app. `localjam host --web-dir <path>`
    serves a directory.
  - Plaintext is the decision for every client, browsers included: listening
    needs no secure context, and a self-signed certificate on a LAN IP buys
    a browser warning and nothing to pin. TLS is no longer described as a
    prerequisite for a web guest — only as a possible hardening option for
    hostile networks (§9, §11).
- **PROTOCOL 1.1** (additive; 1.0 joiners ignore it): an optional `hname`
  TXT key carries the host's display name — trimmed, at most 63 bytes,
  display-only and unauthenticated (§1, §9).
- Jam history records store the host's name, a portable reference for each
  song's path (re-based when the app's container moves), and a small cover
  picture beside the record.
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
- A kick holds a device out only when its `hello` carried a `clientId`;
  `JamHostServer.kickKeepsOut` / `JamHostEngine.kickKeepsOut` say so before
  the kick. PROTOCOL §3.1/§5.6 now state that id-less clients cannot be held
  (an address is shared by a NAT or a hotspot, so it is not used).
- A sync nudge no longer reads as drift: the drift check expects the heard
  position the nudge moves (`nudge × rate` ahead of the room), so a nudge
  past 15 ms stops slewing and one past 50 ms stops re-anchoring every few
  seconds, and the sync indicator shows the nudged device in sync.

### Android

- Foreground-service and audio fixes: the media card is the foreground-service
  notification (one notification, not two), it carries the LocalJam mark, the
  room name and the track's artwork, and transport from the card round-trips
  into the engine at the right position.
- Sync fixes: a drift slew the low-latency track cannot play is reported
  (`rate_needs_reanchor`) and re-anchored at once instead of being waited out;
  `outputLatencyUs` is 0 (its schedules already target presented frames), so a
  device that reports a latency no longer plays that much early; drift checks
  compare the position at the instant it was sampled; Kotlin unit tests in CI.
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
- Joining no longer lifts the memory bounds (anyone near a discoverable room
  can get its token): a joined guest's control message is cut off at 256 KB
  as it arrives, not after the host has buffered it whole; its bytes,
  frames and requests are rate-limited (requests past a 30-request burst
  are answered `busy`, a flood is disconnected); and a guest that stops
  reading is dropped once 4 MB is waiting for it (PROTOCOL §9.1).

### Tooling

- `apps/localjam_app/tool/capture_design.dart` renders every page and state
  in light and dark for design review; the generated galleries are
  git-ignored.
- GitHub Actions CI: analyzer and tests for every package, plus Android, iOS
  simulator and Linux build jobs.
- Android release signing scaffold — `android/key.properties` (git-ignored)
  with a checked-in example, R8 minify and resource shrinking, and ProGuard
  keeps for the Flutter embedding, the `localjam_audio` plugin and ML Kit.
- `CONTRIBUTING.md`, issue and pull-request templates, and a rewritten public
  `README.md`.
- `dart format` across every first-party package and app.
- `localjam join` sends a `hello.clientId` — a fresh random one per run, or
  `--client-id` to be recognised across runs — so a host that removes a CLI
  guest can keep it out. It is not persisted: two terminals on one machine
  would share it, and one id is one device.
