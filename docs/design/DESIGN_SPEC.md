# LocalJam — Design Spec v2

Target: `apps/localjam_app`. Everything below is buildable as written. Numbers are logical pixels (dp) unless stated.

---

## 1. Principles

1. **The room is the subject.** People, attribution and the shared queue are first-class; playback is how the room expresses itself. Never a library app.
2. **Artwork is the only source of colour in the content area.** Chrome stays cream/plum neutral; the cover tints the ambience, never the text.
3. **Quiet when correct.** Sync, network and readiness are invisible while fine, apricot while recovering, red only when broken. No telemetry on a primary screen.
4. **One tap to sound.** Home → Start a Jam → playing, with no required decisions. Every setup field has a working default.
5. **Warm, not cute.** Big confident type, generous negative space, one raspberry accent. No skeuomorphism, no gradients on text, no more than one accent per screen region.

**Emotional target:** opening LocalJam on a bus should feel like putting a record on for the people next to you — warm, immediate, slightly ceremonial when the jam starts. Never like configuring a network service.

---

## 2. Tokens

### 2.1 Colour — `design/tokens.dart`, `JamColors`

Keep every existing field name. **Five new fields:** `accentDeep`, `highlight`, `highlightSoft`, `surfaceElevated`, `shadowTint`.

| Field | Light | Dark | Use |
|---|---|---|---|
| `canvas` | `#FFF7F2` | `#150A19` | Page ground (Cream / below-Plum) |
| `surface` | `#FFFFFF` | `#221029` | Cards, list groups, sidebar, room bar |
| `surfaceElevated` | `#FFFFFF` | `#2B1332` | Sheets, dialogs, popup menus (Plum on dark) |
| `surfaceMuted` | `#F5E9E2` | `#32183A` | Inset fills, chips, artwork placeholder ground, text fields |
| `separator` | `#EBDDD4` | `#3D2145` | Hairlines (0.5dp) |
| `textPrimary` | `#2B1332` | `#FBF2F6` | Titles, values |
| `textSecondary` | `#7A6478` | `#B9A5BD` | Bylines, "in sync" |
| `textTertiary` | `#A99AA6` | `#7E6C84` | Placeholder, disabled, durations |
| `accent` | `#D92C64` | `#FF6E96` | Solid fills, selection, active state |
| `accentPressed` | `#B31F51` | `#E63B6F` | Pressed |
| `accentDeep` | `#C71F5E` | `#C71F5E` | Gradient end, app icon, brand marks |
| `accentSoft` | `#FCE7EE` | `#3A1329` | Selected-row fill, accent chips |
| `onAccent` | `#FFFFFF` | `#2B1332` | On `accent` (4.8:1 light, 6.4:1 dark) |
| `highlight` | `#FFB25C` | `#FFB25C` | Apricot: live dot, "you" ring, warm glow, placeholder gradient |
| `highlightSoft` | `#FFF0DC` | `#3A2415` | Apricot tinted fill (catching-up banner) |
| `warning` | `#A85B12` | `#FFC078` | Warm-state **text/icon** (apricot fails AA as text on cream) |
| `danger` | `#B3261E` | `#FF7A6E` | Failure |
| `scrim` | `0x662B1332` | `0xA6100616` | Behind modals |
| `shadowTint` | `0x1A2B1332` | `0x00000000` | Base shadow colour; dark uses no shadows |

Brand Raspberry `#E63B6F` stays the **gradient/brand** colour (app icon, primary-button gradient, jam-started moment). `accent` is a half-step deeper so white labels clear 4.5:1.

**Semantic aliases** (add as getters on `JamColors`, no new storage): `liveDot => highlight`, `youRing => highlight`, `hostRing => accent`.

### 2.2 Artwork-derived dynamic colour

New file `design/artwork_tint.dart`.

```
JamTint tintFor(Uint8List artworkBytes, Brightness b)
```

- Derive with the stock `ColorScheme.fromImageProvider(provider: MemoryImage(bytes), brightness: b)`; take `.primary`. No new dependency.
- Clamp in HSL: saturation to `[0.28, 0.60]`; lightness to `0.46` (light theme) / `0.58` (dark).
- **Reject and fall back** when source saturation < 0.12 (grey/black-and-white covers) → fall back to `Raspberry #E63B6F → accentDeep #C71F5E`.
- Cache per `artworkId` in a `Map<String, JamTint>` on the engine-adjacent widget; never recompute per frame.
- Cross-fade tint changes over **480 ms, `Curves.easeInOutCubic`** when the track changes.

**Where the tint may be used — and nowhere else:**
1. Room screen ambient: a radial gradient behind the hero artwork, `tint` at **alpha 0.28 light / 0.40 dark**, radius `1.6 × artSize`, blurred by a `ImageFiltered(blur 60)`, centred 8% above the artwork centre.
2. The room screen's top-to-bottom background gradient: `tint @ alpha 0.10` → `canvas` over the top 45% of the screen.
3. The docked room bar's left 40% wash, `tint @ alpha 0.08`.

**Never** the tint: text, icons, transport, buttons, dividers, the sync indicator. Text always reads against `canvas`/`surface`, so no cover can break contrast.

### 2.3 Radii — `JamRadius`

`xs 8 · sm 10 · md 14 · lg 18 · xl 24 · xxl 32 · pill 999`
`artwork(size) => (size / 9).clamp(10, 28)` — hero at 340 gives 28, thumb at 48 gives 10.

### 2.4 Spacing — `JamSpace` (unchanged scale, one addition)

`xxs 2 · xs 4 · sm 8 · md 12 · lg 16 · xl 20 · xxl 24 · xxxl 32 · huge 40 · giant 56`
`page 20 · card 16 · section 28` (section grows from 24).

### 2.5 Elevation & shadow — new `JamShadow`

Light theme only. Dark separates by lightness step, as today.

| Level | Use | Spec |
|---|---|---|
| `flat` | list groups, rows | none; 0.5dp `separator` hairline |
| `raised` | cards, artwork thumb, chips-with-action | `0 1 2 0 rgba(43,19,50,.06)` + `0 4 12 -2 rgba(43,19,50,.08)` |
| `floating` | hero artwork, room bar, FAB-like play button | `0 8 24 -4 rgba(43,19,50,.14)` + `0 2 6 0 rgba(43,19,50,.06)` |
| `overlay` | sheets, dialogs, menus | `0 -8 40 0 rgba(43,19,50,.16)` |

### 2.6 Blur

- Bottom room bar and bottom action bars: `BackdropFilter(blur 24)` over `surface @ 0.82` (light) / `surface @ 0.86` (dark) with a 0.5dp top hairline.
- Modal sheets: opaque `surfaceElevated`. No blur — they cover the page.
- The artwork ambient glow (2.2) uses `blur 60`.
- App bar over the room: transparent, no blur; the room's own gradient supplies the ground.

### 2.7 Motion — `JamDuration` + new `JamCurve`

| Token | ms | Curve | Use |
|---|---|---|---|
| `instant` | 90 | `easeOut` | Press/hover state, icon swap |
| `fast` | 140 | `easeOutCubic` | Chips, switches, ripple settle |
| `base` | 220 | `easeOutCubic` | Sheet open, row insert, colour lerp |
| `slow` | 360 | `easeOutQuint` | Room slide up, panel dock |
| `ambient` | 480 | `easeInOutCubic` | Artwork tint cross-fade, glow shift |
| `celebration` | 900 | `easeOutBack` (scale) + `easeOut` (fade) | Jam-started moment |

Reverse transitions use `base` with `easeInCubic`. Everything respects `MediaQuery.disableAnimations`: fall back to a 90 ms fade, and the avatar bob and glow pulse stop entirely.

### 2.8 Haptics

| Moment | Feedback |
|---|---|
| Play / pause tap | `HapticFeedback.lightImpact` |
| Next / previous | `selectionClick` |
| Scrubber drag start / release | `selectionClick` / `lightImpact` |
| Track added to queue (local confirm) | `lightImpact` |
| Jam started (host) / joined (guest) | `mediumImpact` |
| A person joins the room | `selectionClick` |
| Kick, end jam, remove track confirmed | `mediumImpact` |
| Sync degrades to `offSync` (first entry only, max 1/30 s) | `heavyImpact` |
| Reorder drag pick-up / drop | `selectionClick` |

---

## 3. Typography

**Font: Plus Jakarta Sans** (Tokotype, OFL 1.1). Chosen over Manrope and Outfit: its open apertures stay warm at 15 dp bylines while ExtraBold holds Apple-Music-scale titles without reading as a tech logotype, and it ships 200–800 statics with real tabular figures for the timeline.

**Bundle:** Regular 400, Medium 500, SemiBold 600, Bold 700, ExtraBold 800 (roman only — no italics in the UI).
**Source:** `https://github.com/tokotype/PlusJakartaSans/releases/latest` → `fonts/ttf/PlusJakartaSans-{Regular,Medium,SemiBold,Bold,ExtraBold}.ttf`. Copy `OFL.txt` to `assets/fonts/OFL.txt`. Declare in `pubspec.yaml` under `flutter: fonts:` as family `Plus Jakarta Sans`, set `fontFamily` once in `_build()` in `theme.dart`.

### Scale — `design/typography.dart`

| Slot / alias | Size | Weight | Tracking | Height | Used on |
|---|---|---|---|---|---|
| `displayLarge` / `jamDisplay` | 40 | 800 | -1.2 | 1.05 | Onboarding headlines, jam-started overlay, empty-home hero |
| `headlineLarge` / `jamLargeTitle` | 32 | 800 | -0.8 | 1.12 | Screen titles: "Nearby", "Past jams", "Start a jam" |
| `headlineMedium` / `jamTrackTitle` | 26 | 700 | -0.6 | 1.15 | Now-playing track title |
| `headlineSmall` / `jamSheetTitle` | 22 | 700 | -0.4 | 1.20 | Sheet titles, terminal-state titles |
| `titleLarge` / `jamTitle` | 19 | 700 | -0.3 | 1.25 | Section headings, panel headers |
| `titleMedium` / `jamRowTitle` | 17 | 600 | -0.2 | 1.30 | Track/peer row titles, room bar title |
| `titleSmall` | 15 | 600 | -0.1 | 1.30 | Segmented buttons, inline labels |
| `bodyLarge` / `jamBody` | 16 | 400 | 0 | 1.45 | Running text, dialog bodies |
| `bodyMedium` / `jamByline` | 15 | 400 | 0 | 1.40 | Row bylines (`textSecondary`) |
| `bodySmall` / `jamFootnote` | 13 | 400 | 0 | 1.35 | Footnotes, counts, sync label |
| `labelLarge` | 16 | 700 | 0.1 | 1.20 | Button labels |
| `labelMedium` | 13 | 600 | 0.1 | 1.20 | Chip labels |
| `labelSmall` / `jamCaption` | 11 | 700 | 0.6 | 1.20 | Micro labels, **rendered uppercase** ("ADDED BY", "LIVE") |
| — / `jamNumeric` | 13 | 500 | 0 | 1.20 | Timers, drift, byte counts — `FontFeature.tabularFigures()` |

Verify `tnum` resolves in the bundled statics on first build; if it does not, wrap each digit in a 8.5 dp-wide `SizedBox` in `format.dart` rather than letting the timer jitter.

---

## 4. Component library

New file per component under `widgets/`; sizes are minimums and all interactive targets are ≥ 44×44.

**`JamButton`** (`widgets/buttons.dart`) — one widget, three variants.
- *Primary*: height 52, radius `md 14`, horizontal padding 20, label `labelLarge` in `onAccent`. Fill is a 135° gradient `#E63B6F → accentDeep` in light, flat `accent` in dark. Pressed: scale 0.97 over `instant`, fill → `accentPressed`. Disabled: `surfaceMuted` fill, `textTertiary` label, no gradient. Loading: label replaced by a 20 dp 2 dp-stroke spinner in `onAccent`, width held.
- *Secondary*: height 52, radius 14, 1 dp `separator` border, transparent fill, `textPrimary` label. Pressed: fill `surfaceMuted`.
- *Tertiary*: height 44, no border, `accent` label, radius `pill`. Pressed: `accentSoft` fill.
- Optional 20 dp leading icon, gap 8.

**`JamChip`** — height 32, radius `pill`, padding 12/6, `labelMedium`. Idle `surfaceMuted` + `textSecondary`; selected `accentSoft` + `accent`; live `highlightSoft` + `warning` with a 6 dp `highlight` dot leading. Optional trailing 16 dp close icon.

**`JamTrackRow`** — height 68. Anatomy L→R: 48 dp `JamArtworkTile` (radius 10) · 12 gap · column {title `jamRowTitle`, 2 gap, byline `jamFootnote` in `textSecondary`} · 8 gap · 20 dp attribution `JamAvatar` (omitted when the adder is you) · 12 gap · trailing status (duration `jamNumeric` / prefetch ring / error glyph) · optional 40 dp drag handle when reorder is allowed. Current row: title in `accent`, and a 3 dp × 20 dp `accent` bar flush to the left edge, radius 2. Pressed: `surfaceMuted` fill over `fast`. Dragging: `raised` shadow, scale 1.02, `surfaceElevated` fill.

**`JamPeerRow`** — height 64. 44 dp avatar (host: 2 dp `accent` ring; you: 2 dp `highlight` ring) · 12 · column {name `jamRowTitle`; detail `jamFootnote`} · role badge chip ("HOST" / "CO-HOST" from `permissions.roleOf`, `jamCaption`, `accentSoft`/`accent`) · trailing 44 dp overflow button (host only, gated on `manageMembers`). Readiness replaces the detail line: `MediaReadiness.fetching` → "Getting the track" in `warning` with a 16 dp determinate ring driven by `hostEngine.peerFetchProgress[peerId]?.progress`; `MediaReadiness.none` → "Missing the track" in `danger`; `ready` → "Listening".

**`JamAvatar`** — circle, initials from `identityInitials`, deterministic hue from the existing FNV-1a `identityColor`. Keep the 12-hue wheel but restate S/L against the new palette: light `HSL(h, 0.52, 0.44)`, dark `HSL(h, 0.50, 0.66)`; initials always white (light) / `#150A19` (dark), weight 700, size `0.36 × d`. Sizes: 20 (attribution), 24 (strip), 28 (identity button), 36 (list), 44 (people sheet), 56 (profile).
**`JamAvatarStack`** — overlapping at `-0.32 × d` with a 2 dp `canvas` ring per avatar; max 4 then a `+N` chip in `surfaceMuted`/`textSecondary`. Replaces `PeerAvatarRow` everywhere except the People sheet.

**`JamArtworkTile`** — square, radius `JamRadius.artwork(size)`, `Clip.antiAlias`, 0.5 dp `separator` border in light only. Placeholder: a 135° gradient `highlight #FFB25C → accent #D92C64` at 0.85 alpha with the white `logo.svg` centred at `0.42 × size` and 22% opacity. Loading: same gradient with a 1200 ms shimmer sweep. Error: gradient + a 0.3-alpha white `music_note_rounded`. `gaplessPlayback: true`; new artwork cross-fades over `base`.

**`JamSyncIndicator`** — 6 dp dot + label `jamFootnote`, gap 8, tap target 44 high, long-press opens diagnostics.
`inSync` → `textSecondary` dot, no label. `syncing` → `textSecondary`, "Syncing…", dot pulses 0.4↔1.0 alpha over 1200 ms. `catchingUp` → `highlight` dot, `warning` label "Catching up". `reconnecting` → `warning`, "Reconnecting…", dot pulses. `offSync` → `danger`, "Out of sync". Colour changes lerp over `base` so it never flashes.

**Transport (`widgets/transport.dart`)** — play button 72 dp circle, `accent` gradient fill, 34 dp glyph in `onAccent`, `floating` shadow (light only); pressed scale 0.94 over `instant`; play↔pause is an `AnimatedIcon`-style 140 ms cross-fade+scale, not a swap. Prev/next 48 dp targets, 32 dp glyph, `textPrimary`, disabled `textTertiary`. Gaps 28. **Capability-gated:** when `!engine.can(controlPlayback)`, render the bar at 38% opacity, non-interactive, with a `jamCaption` beneath: "The host controls playback". Never hide it. `PlaybackStatus.loading` swaps the glyph for an indeterminate 3 dp `onAccent` ring and swallows taps.
**Scrubber** — track height 4, radius pill, inactive `surfaceMuted` (light) / `#3D2145` (dark), active `accent`; thumb 7 dp radius, growing to 11 while dragging with a 24 dp `accent @ 0.14` halo. Elapsed left / `-remaining` right in `jamNumeric` `textSecondary`, 13 dp, 6 gap below the track.

**Sheets** — `showModalBottomSheet`, `surfaceElevated`, top radius `xl 24`, `overlay` shadow, 36×4 drag handle in `textTertiary @ 0.4` at 8 top. Header: title `jamSheetTitle` left, action right, 20/12/16/12 padding, then a 0.5 dp `separator`. Queue and People open at `initialChildSize 0.82`, `max 0.96`; Diagnostics is `min`-height, no drag scroll.

**`JamRoomBar`** (bottom mini player) — height 64 + bottom safe area. Blurred translucent `surface`, 0.5 dp top hairline, and a 2 dp `accent` progress line pinned to its top edge. Content: 44 dp artwork (radius 10) · 12 · {title `jamRowTitle`, session name `jamFootnote`} · avatar stack (max 3, 20 dp) · 44 dp play/pause. Left 40% carries the artwork tint wash. Tap opens the room; swipe up opens the room; swipe down does nothing.

**Empty state** — centred column, max width 320: 56 dp icon or 72 dp logo mark in `textTertiary` (or the placeholder gradient for music-shaped empties) · 20 · title `jamTitle` · 8 · body `jamByline` centred · 24 · one action button. Never two competing actions.

**Permission-rationale sheet** — 64 dp icon in `accentSoft` rounded square (radius `lg`), title `jamSheetTitle`, body `jamBody`, a 2-item bulleted "what we do / what we never do" list in `jamByline`, primary "Continue" and tertiary "Not now". Shown *before* the OS prompt, never after a denial.

**Notice / snackbar** — floating, radius `md`, `textPrimary` ground with `canvas` text (keep), 16 dp margin, 20 dp leading status glyph tinted `highlight`/`danger`, 4 s default. Errors get a tertiary "Retry" action in `highlight`.

**Dialog** — `surfaceElevated`, radius `lg 18`, 24 padding, title `jamSheetTitle`, body `jamBody` `textSecondary`, actions right-aligned with tertiary (dismiss) then primary; destructive primary uses `danger` fill with white label.

---

## 5. Screens

Every screen: page margin 20, bottom action bars blurred, `SafeArea(top: false)` under an app bar.

### Home — `screens/home_screen.dart`
56 identity bar (28 avatar + name `jamRowTitle`; right: history + settings icons) · 8 · **"Nearby"** `jamLargeTitle` · 4 · `jamFootnote` "Listening for rooms on *Wi-Fi name*" with a 6 dp `highlight` dot pulsing while browsing · 24 · room cards · 28 · recents rail · blurred bottom bar (`Scan code` secondary + `Start a jam` primary, both `Expanded`, gap 12).
**Room card** 88 high, `surface`, radius `lg`, `raised`, padding 16: 48 avatar (room-name hue) · title `jamRowTitle` · byline `jamFootnote` "Open · tap to join" · tertiary "Join". Cards, not `ListTile`s. **`JamNearbyRoom` carries only `key`, `sessionName`, `joinUri` — no listener count or host name over mDNS, so never design a byline implying one.**
**Recents rail** `jamCaption` "RECENTLY" + horizontal 152×184 cards (2×2 artwork mosaic, name, relative time), max 5, ending in "See all" → `/history`. Hidden when history is empty.
**States** loading: 3 shimmer cards for 1200 ms. Empty: keep today's three network-aware variants, restyled as the empty-state component with the logo-gradient mark. Errors are snackbars only.
**Dark** cards read by lightness, no shadow; dot stays apricot.
**Delight** (a) a newly discovered room slides in 12 dp from below over `base` with a `selectionClick`; (b) the "Start a jam" gradient drifts its angle over 6 s while home is idle.

### Host setup — `screens/host_setup_screen.dart`
"Start a jam" `jamLargeTitle` · borderless name field at `headlineMedium` with a `textTertiary` placeholder — an editable heading, not a form field · 28 · network notice (only when off-network or hotspot) · **preset cards**: three 100×88 cards in a row, radius `lg` — Everything (`JamPolicy.open`) / Add music (`JamPolicy.jam`) / Listen (`JamPolicy.listenOnly`); selected = `accentSoft` fill + 1.5 dp `accent` border + 20 dp `accent` icon; a one-line `jamFootnote` beneath describes the selection. **Default to `JamPolicy.jam`** — the engine's own default; today's screen wrongly defaults to `open` · `Discoverable` switch row · **Music**: two secondary buttons (Add files / Library) then chosen tracks as `JamTrackRow`s with a trailing remove · blurred bottom bar with a full-width primary "Start the jam".
**States** starting: spinner in the button, form dims to 50% and goes non-interactive. Failure: snackbar with Retry.
**Delight** preset icons cross-fade (`groups` → `queue_music` → `headphones`) over 140 ms on selection; on Start the button expands to fill the bar and the gradient sweeps left→right over 320 ms before the room rises.

### Room / Now Playing — `screens/room_screen.dart`
Ground: `canvas` + the artwork-tint gradient (§2.2). App bar: 44 chevron-down left, centre column {`JamSyncIndicator`, room name `jamRowTitle`}, right overflow.
`Spacer` · **hero artwork** `min(width − 64, height × 0.42, 340)` with the ambient glow behind and `floating` shadow · `Spacer(2)` · left-aligned {title `jamTrackTitle`, 1 line; artist `jamBody` `textSecondary`; **added-by** 20 dp avatar + "ADDED BY *NAME*" `jamCaption` `textTertiary`, omitted when `addedByLabel` returns `'You'`} · 20 · scrubber · 12 · transport · 16 · readiness note (`warning`) · 20 · **people strip**: `JamAvatarStack` (24 dp, max 4) + count on the left → People sheet; queue count + `queue_music` on the right → Queue sheet; host-only tertiary "Invite" centred between them · 12 bottom inset.
**States** nothing queued: logo-gradient placeholder, title "Nothing queued", artist line becomes a tertiary "Add music". `JamConnectionState.reconnecting`: 40 dp `highlightSoft` banner under the app bar with a 14 dp spinner (keep today's copy); `closed`/`failed` are terminal and hand off below. Guest whose current track is unfetched: the play glyph becomes a determinate ring on `prefetchStates[mediaId].progress`, caption "Getting this track — *N*%" (no byte counters exist guest-side; `progress × sizeBytes` is the only MB source, so prefer the percentage). A non-fatal `ErrorCode.notAllowed` off `guest.errors` is a snackbar ("The host doesn't allow that"), never a banner.
**Dark** glow alpha 0.40, artwork loses its border, all shadows drop.
**Delight** (a) while playing, each strip avatar bobs 2 dp on a 2.4 s sine, phase-offset by index; (b) the glow breathes ±4% radius on the same cycle; (c) **jam-started moment** — on first entry to `live`, a 900 ms overlay: the white logo mark scales 0.8→1 on `easeOutBack` over the raspberry gradient with the room name in `jamDisplay` beneath, then fades to the player. `mediumImpact`, once per session, tap to skip.

### Queue sheet — `widgets/queue_sheet.dart`
Header "Queue" + count `jamFootnote` + tertiary "Add" (only with `addTracks`). Body: `JamTrackRow` list, reorderable with `editQueue`. The current track is pinned first under a `jamCaption` "NOW PLAYING" rule; the rest sit under "NEXT UP". Guest upload progress is a 3 dp `accent` line pinned under the header, not a bar in the flow.
**States** empty: empty-state component, copy split on `canAdd` (keep today's). Adding: the row inserts with a 200 ms height+fade and the adder's avatar pops 0.6→1.
**Delight** the playing row carries a 12×12 three-bar equaliser badge on its artwork corner, bars animating 4–12 dp on staggered 700/900/1100 ms loops, frozen when paused.

### People / Room sheet — `widgets/room_sheet.dart`
Header "*N* in the room". **People**: `JamPeerRow`s — you first (apricot ring), host second (raspberry ring), then peers; host overflow → Make co-host / Block adding music / Remove. **Invite** (host only): a 264 dp white plate, radius `xl`, QR at 200 dp with the white logo knocked into a 44 dp raspberry rounded square at its centre, room name `jamRowTitle` below, then a copy-link row and a "Share link" tertiary. **Everyone can** (host only): three switch rows over `permissions.policy`, plus a `jamFootnote` naming the active preset, or "Custom" once a switch diverges. **Leave / End jam** lives here as the last row, in `danger`.
**States** guests see no Invite and no switches — a read-only `jamFootnote` summary of what the room allows instead.
**Delight** a soft `accent @ 0.18` glow, blur 40, behind the QR plate so it reads as the thing to point a camera at; a joining peer's row slides in over 200 ms with a `selectionClick`.

### Scan — `screens/scan_screen.dart`
Full-bleed camera under a 60% `scrim` mask with a 260×260 cut-out; corners are four 32 dp raspberry L-brackets, 3 dp thick, radius 14. "Scan to join" `jamSheetTitle` white above, hint `jamByline` white@0.8 below, 44 dp close button top-left on `0x66000000`. Bottom: tertiary white "Enter link instead" → join dialog.
**States** permission denied: full-screen empty state with an "Open Settings" primary. Detected: brackets snap to `highlight` and pulse once, `mediumImpact`, then dismiss.

### Join-with-link dialog (new)
Title "Join with a link", one field prefilled when the clipboard holds a `localjam://` URI (with `jamFootnote` "Pasted from your clipboard"), tertiary "Cancel" + primary "Join". Invalid input gets inline `danger` helper text, not a snackbar.

### Jam history — `screens/history_screen.dart`
"Past jams" `jamLargeTitle`, then one card per record (radius `lg`, `raised`): a 96 dp header strip with a 2×2 artwork mosaic left and, right, name `jamRowTitle`, "You hosted · 12 tracks" `jamByline`, and the avatar stack from `peerNames`; up to 3 track rows at 52 dp with attribution; a footer with tertiary "Forget" and primary "Host it again", disabled with `jamFootnote` "No tracks left on this device" when `replayableTracks` is empty.
**States** loading: 2 shimmer cards. Empty: empty-state component.
**Delight** mosaic tiles for tracks no longer on disk (`existsLocally == false`) drop to 35% opacity, so a record visibly ages.

### Settings — `screens/settings_screen.dart`
**You** (56 avatar, name, "How you appear in rooms", chevron → `promptForName`) · **Appearance** (three rows) · **About** (version, "Open source" → repo, licences). Nothing else; room behaviour stays in the room.
**Delight** each appearance row shows a 44×28 live mini-preview swatch, not only a radio.

### First-run onboarding (new — `screens/onboarding_screen.dart`)
Three full-bleed panels on a raspberry→plum gradient, white type, 3-dot pager, "Skip" top-right, primary "Next" / "Get started".
1. 96 dp logo + `jamDisplay` "Everyone hears the same song." / "One phone plays. Everyone else listens on their own headphones, in sync."
2. Avatar cluster + "No internet. No accounts." / "It all happens over your Wi-Fi or hotspot."
3. Queue mock with attribution + "It's their queue too." / "Anyone you allow can add a track. Everyone sees who added what."
Then the **permission-rationale sheet** — one per permission, at the moment it is needed (local network before hosting or joining, camera before the first scan, audio library before the first Android browse). Never all at launch, never after a denial.
**Delight** the gradient angle shifts 12° per panel.

### Terminal states — `room_screen.dart`
One layout for all four: 72 dp glyph in a `surfaceMuted` circle · title `jamSheetTitle` · body `jamByline` centred (keep today's copy for `hostGone`, `kicked`, `rejected`, default) · primary "Back to nearby" · tertiary "Scan a new code" for `hostGone` and `rejected` only. Reconnecting is not terminal: it stays a banner and the player keeps running.

### Wide layouts
Sidebar and docked panel already exist; the changes are:
- **Sidebar (260):** add the white logo + "LocalJam" wordmark 20 above the identity row; the selected nav item keeps `accentSoft` and gains a 3×20 `accent` bar on its left edge.
- **Room, expanded (≥1000):** the hero caps at 340 and left-aligns in the player column with the title block beneath it; the glow anchors to the artwork, not the window.
- **Panel (340):** replace the `SegmentedButton` with two flat tabs under a 2 dp `accent` underline; `surface`, no blur.
- **Medium (600–999):** phone chrome, content clamped to 640 and centred; the room bar becomes a 720-wide floating pill (radius `pill`, `floating`, 16 above the edge) instead of a full-width bar.

## 6. Remove or simplify

1. `screens/room_screen.dart` — the `PopupMenuButton` overflow holding People / Sync details / Leave. Three unrelated things behind an ellipsis is a tool. People moves to the tappable avatar strip, sync details to a long-press on the indicator (already wired), Leave to a single labelled row at the bottom of the People sheet.
2. `screens/room_screen.dart` `_UtilityRow` — the bare numeric counts ("3", "12") flanking the player. Replace with the avatar stack + a labelled queue count.
3. `widgets/diagnostics_sheet.dart` — drop `Slews` and `Resyncs` cells entirely. Nobody acts on them; keep clock offset, drift, last correction, and the nudge.
4. `widgets/peer_avatar.dart` `PeerAvatarRow` — the non-overlapping spaced row reads as a data grid. Use `JamAvatarStack` everywhere except inside the People sheet.
5. `screens/host_setup_screen.dart` — the `SegmentedButton` policy picker and the raw file-path `ListTile`s (`_basename(path)`). Presets become cards; tracks become `JamTrackRow`s with real tags.
6. `screens/home_screen.dart` `_RoomRow` — a `ListTile` with "Tap to join" and a chevron is a settings row. Make it a card with a real Join action and a listener count.
7. `screens/settings_screen.dart` — the duplicated inline rename dialog (`_rename`) shadowing `widgets/rename_dialog.dart`. Delete it and call `promptForName`.
8. `widgets/room_sheet.dart` — the raw `localjam://…` URI printed as a truncated string. Show "Room code" + a copy affordance; the URI itself is machine text.
9. `design/theme.dart` — `InkSparkle.splashFactory`. Its Material-you sparkle fights the palette; use `InkRipple` with `accent @ 0.08`.
10. `widgets/queue_sheet.dart` — the full-width `LinearProgressIndicator` for guest uploads dropped into the column; it shifts the whole list. Make it a 3 dp line pinned under the header.
11. Every `CircularProgressIndicator` used as a page-level loader (`history_screen.dart`, `host_setup_screen.dart`) — replace with shimmer placeholders of the real layout.

---

## 7. Implementation order and ownership

**Phase 0 — foundation (1 engineer, blocks everything, ~half a day).**
`design/tokens.dart` (palette + new fields + `JamShadow` + `JamCurve`), `design/typography.dart`, `design/theme.dart`, `design/artwork_tint.dart`, `pubspec.yaml` fonts, `assets/fonts/`. Merge before Phase 1 starts.

**Phase 1 — shared widgets (3 engineers in parallel, no shared files).**

| Engineer | Files owned |
|---|---|
| **A — identity & media** | `widgets/avatar.dart` (new, replaces `peer_avatar.dart`), `widgets/artwork.dart`, `widgets/track_row.dart` (new), `widgets/peer_row.dart` (new) |
| **B — controls & feedback** | `widgets/buttons.dart` (new), `widgets/chip.dart` (new), `widgets/transport.dart` (new, from `now_playing.dart`), `widgets/sync_indicator.dart`, `widgets/empty_state.dart` (new) |
| **C — containers** | `widgets/sheet.dart` (new), `widgets/section.dart`, `widgets/room_bar.dart`, `widgets/notice.dart` (new), `widgets/dialogs.dart` (new, absorbs `rename_dialog.dart`), `widgets/permission_sheet.dart` (new) |

**Phase 2 — screens (same 3 engineers, one screen file each at a time).**

| Screen | Owner | Depends on |
|---|---|---|
| Home | A | avatar stack, artwork tile, buttons, empty state, chip |
| Jam history | A | artwork tile, avatar stack, track row, buttons, empty state |
| Room / Now Playing | B | artwork tile (+tint), transport, sync indicator, avatar stack, notice |
| Scan + join dialog | B | buttons, dialogs, permission sheet |
| Queue sheet | C | sheet, track row, empty state, buttons |
| People sheet + invite | C | sheet, peer row, avatar, buttons, chip |
| Host setup | C | buttons, chip, track row, notice |
| Settings + onboarding | A | sheet, buttons, permission sheet, avatar |

**Phase 3 — integration (1 engineer):** `router.dart` (onboarding gate + join dialog route), `app.dart`, wide-layout passes in `app_sidebar.dart` and the room's `_SidePanel`, `diagnostics_sheet.dart` trim, haptics wiring.

No file appears in two rows. The only cross-cutting edit is Phase 0, and it lands first.

---

## 8. What a reviewer should check on a real screenshot

1. **Does the cover art own the colour?** The room's background should carry an unmistakable wash from the current artwork while every glyph and label stays cream/plum neutral. If the screen is grey, the tint is not wired; if the text is tinted, the contrast rule was broken.
2. **Are there people on screen?** Overlapping avatars and an "added by" credit should be visible without opening anything. A player with no faces means the jam-first framing did not survive.
3. **Is any raw machine text visible?** No `localjam://` URIs, no file paths, no "±3.2 ms", no bare integers standing in for labels.
4. **Does the type look set rather than defaulted?** One family, tight negative tracking on the big titles, a clear jump from 26 to 17 to 13, and timers whose digits do not shift width as they tick.
5. **Is there exactly one primary action per screen?** One raspberry-filled control in view, everything else outlined or plain — and it should be the thing you actually want to tap next.
