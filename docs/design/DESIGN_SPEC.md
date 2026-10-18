# LocalJam — Design Spec v3 ("as if Apple designed it")

Target: `apps/localjam_app`. Supersedes v2 and its addendum (both in git
history, commit `0559612`). Numbers are logical pixels. Reference board:
https://claude.ai/artifact/FK4Ca6qqnR9wm5gNSWynwX

Decisions settled with Bibek on 2026-10-18:

| # | Decision |
|---|---|
| Type | System font. SF Pro on iOS/macOS, Roboto on Android, Segoe UI on Windows, the platform default on Linux. Plus Jakarta Sans is removed (pubspec + `assets/fonts`). |
| Colour | Apple system neutrals (white / grouped grey, true black in dark). Raspberry is the **tint**: only on things you can tap, plus selection. Cover art carries every other colour. |
| Scope | Layouts and flows may change. Every feature and engine behaviour stays. |
| D1 | Translucent chrome: blurred bars, floating capsule mini player, round glass icon buttons over artwork. |
| D2 | Same Apple-style design on every platform (no Material look on Android). |
| D3 | Home: one filled **Start a Jam** button pinned at the bottom; scan icon in the nav bar; "Enter Link" lives in the scan screen. |
| D4 | Now Playing is immersive in both themes: blurred cover colours behind everything, white text. |
| D5 | Queue opens **in place** on Now Playing (Apple Music), not as a separate sheet. |
| D6 | Avatars: flat solid colour per person, white initials, no ring. |
| D7 | Wide layouts keep the sidebar + docked room panel architecture, restyled. |

---

## 1. Principles

1. **The room is the subject.** People, attribution and the shared queue are first-class. Never a library app.
2. **Quiet when correct.** Nothing on screen says "connected", "in sync", "online" or "listening". When something is wrong, one line of plain text says so where a subtitle would be ("Reconnecting…", "Catching up…"). Red only when it's broken.
3. **One tap to sound.** Home → Start a Jam → Start → playing, no required decisions.
4. **Structure must be true.** No eyebrows, no uppercase labels, no decorative dividers, no badges/pills for things that are just text ("Host" is secondary text, not a pill). Section headers only where they help scanning.
5. **No decoration.** No gradients (exception: the Now Playing backdrop, D4), no glows, no shadows on buttons, no coloured rings, no tinted cards, no accent stripes, no idle animation (avatar bob, glow breathe, live-dot pulse — all removed).
6. **Platform-native feel everywhere** (D2): iOS spacing, controls, sheets, alerts, menus, switches and press highlights on all platforms. No Material ink ripples — use a press highlight (row fills with `fillPressed`, buttons dim to 0.6–0.7 opacity).

## 2. Tokens (`lib/src/design/tokens.dart`)

Keep `JamColors` as the ThemeExtension and `context.jamColors` as the access path. Field set may change; the foundation pass updates every call site. Values (Apple system colours):

| Token | Light | Dark | Use |
|---|---|---|---|
| `background` | `#FFFFFF` | `#000000` | Plain screens (Home, History, Scan fallbacks) |
| `groupedBackground` | `#F2F2F7` | `#000000` | Grouped screens (Settings, Host setup, People sheet) |
| `groupedSurface` | `#FFFFFF` | `#1C1C1E` | Rows/cells inside grouped sections |
| `elevated` | `#FFFFFF` | `#1C1C1E` | Sheets, alerts, menus (dark sheets that host grouped rows use `#1C1C1E` bg + `#2C2C2E` rows) |
| `elevatedGroupedSurface` | `#FFFFFF` | `#2C2C2E` | Rows inside a grouped sheet |
| `fill` | `#787880` @ 20% | `#787880` @ 36% | Tinted-grey buttons, search fields, track backgrounds |
| `fillSecondary` | `#787880` @ 12% | `#787880` @ 24% | Placeholder art ground, text fields |
| `fillPressed` | `#000000` @ 6% | `#FFFFFF` @ 10% | Row press highlight |
| `separator` | `#3C3C43` @ 29% | `#545458` @ 60% | 0.5 px hairlines, inset to the text start |
| `label` | `#000000` | `#FFFFFF` | Primary text |
| `secondaryLabel` | `#3C3C43` @ 60% | `#EBEBF5` @ 60% | Subtitles, values, footers |
| `tertiaryLabel` | `#3C3C43` @ 30% | `#EBEBF5` @ 30% | Placeholders, disabled, grabbers, chevrons |
| `tint` | `#D92C64` | `#FF4F82` | Tappable text/icons, filled buttons, selection, checkmarks |
| `tintPressed` | `#B31F51` | `#E63B6F` | |
| `tintFill` | tint @ 12% | tint @ 20% | "Tinted" buttons (Join), selected sidebar item |
| `onTint` | `#FFFFFF` | `#FFFFFF` | Text on filled tint |
| `success` / switch on | `#34C759` | `#30D158` | Switch track (Apple default green — do not tint switches raspberry) |
| `warning` | `#C93400` | `#FF9F0A` | "Catching up…", "Still loading songs" text/icons |
| `danger` | `#FF3B30` | `#FF453A` | Destructive buttons/rows, failures |
| `scrim` | `#000000` @ 40% | `#000000` @ 60% | Behind sheets/alerts |
| `material` (chrome) | `#FFFFFF` @ 72% + blur 30 | `#1C1C1E` @ 72% + blur 30 | Nav bars on scroll, mini player, tab/side chrome |
| `glass` (over art) | `#FFFFFF` @ 18% + blur 20 | same | Round icon buttons on the Now Playing backdrop |

Now Playing (D4) uses its own fixed set regardless of theme: text `#FFFFFF`, secondary `#FFFFFF` @ 60%, tertiary `#FFFFFF` @ 35%, track/scrubber background `#FFFFFF` @ 25%, fill `#FFFFFF` @ 85%.

Remove: cream/plum/apricot values, `accentDeep`, `highlight*`, `liveDot`, `youRing`, `hostRing`, `brandRaspberry` as a UI colour, `shadowTint` (keep a single `JamShadow.artwork` = black 25%, blur 30, y 12, used only under large artwork).

**Radii** (`JamRadius`): artwork xs (≤44) 6, s (≤64) 8, m 12, now-playing 12; grouped section 12 (iOS 26 inset grouped look: use 26 only if it reads right on device — foundation agent decides, one value app-wide); sheet top 16 on phones (iOS 26 large sheets follow the device corner — approximate with 38 when the sheet is inset/floating, 16 when edge-attached); buttons: capsule (stadium) everywhere; alerts 14; menus 14.

**Spacing**: 4-pt grid. Screen side margin 16 (20 on ≥ 400 wide is fine). Row min height 44, with subtitle 60. Section gap 32 (header→rows 6). Large title: 34 bold, 52 tall area, left inset 16.

**Motion** (`JamDuration`, `JamCurve`): 250–350 ms, iOS ease (`Cubic(0.25, 0.1, 0.25, 1)`) or springs for size changes; respect `MediaQuery.disableAnimations`. Haptics: selection click on toggles/segmented/reorder; light impact on play/pause; success notification when a jam starts (replaces the jam-started overlay, which is removed).

## 3. Typography (`lib/src/design/typography.dart`)

No `fontFamily` — let the platform default resolve (on iOS/macOS Flutter resolves to SF; verify on device). Text styles follow iOS sizes; map onto `TextTheme` and expose named getters so screens never hand-roll sizes:

| Style | Size / line | Weight | Tracking |
|---|---|---|---|
| largeTitle | 34 / 41 | bold | +0.4 |
| title1 | 28 / 34 | bold | +0.38 |
| title2 | 22 / 28 | bold | −0.26 |
| title3 | 20 / 25 | semibold | −0.45 |
| headline | 17 / 22 | semibold | −0.43 |
| body | 17 / 22 | regular | −0.43 |
| callout | 16 / 21 | regular | −0.31 |
| subheadline | 15 / 20 | regular | −0.23 |
| footnote | 13 / 18 | regular | −0.08 |
| caption1 | 12 / 16 | regular | 0 |
| caption2 | 11 / 13 | regular | +0.06 |

Tracking values are SF's; apply them on Apple platforms only (Roboto/Segoe use 0). Timers/durations use `FontFeature.tabularFigures()`. Never uppercase text for styling. Dynamic Type: honour `MediaQuery.textScaler`; layouts must scroll rather than clip at 1.3×.

**Copy rules**: Title Case for buttons, nav titles, menu items and row titles ("Start a Jam", "Invite People", "End Jam", "Host Again"). Sentence case for subtitles, footers, messages. Use "…" not "...". "Jam" is capitalised as a noun. No exclamation marks. Strings stay as constants (one strings block per screen/widget file), no inline literals in build methods.

## 4. Iconography

`CupertinoIcons` (already a dependency) everywhere, one weight. Filled variants only for selected/active state and transport (play.fill etc.). Icon sizes: nav bar 22, row leading 22 in a 30 box, transport 34/44/34, mini player 22. No coloured icon tiles in lists.

## 5. Components

The foundation pass owns these; screens consume them and never restyle locally.

- **JamScaffold / large-title scroll view** — large title that collapses into an inline 17-semibold title in a blurred (`material`) nav bar on scroll; hairline appears only once content scrolls under it. Leading back chevron ("‹ Nearby"-style back label optional) and trailing icon/text buttons. `CupertinoSliverNavigationBar` themed from `JamColors` is acceptable if it renders correctly on all platforms; otherwise build it.
- **Grouped list** — `JamSection` (optional header: footnote, secondaryLabel, sentence case, 16 + 16 inset; optional footer: footnote secondaryLabel) wrapping `JamRow`s in a rounded `groupedSurface` block, 16 side margin. `JamRow`: optional leading (icon 22 in tint or secondaryLabel / avatar / artwork), title (body), optional subtitle (subheadline secondaryLabel), trailing one of: value text (secondaryLabel) + chevron, chevron, checkmark (tint), `JamSwitch`, small button, menu. Separator inset to the title's leading edge. Press highlight, no ripple. Destructive variant: title in `danger`, centred when it's the only row.
- **Plain list rows** — same `JamRow` on `background` with separators inset to text (Apple Music lists).
- **Buttons** — `JamButton.filled` (tint bg, onTint 17 semibold, capsule, 50 tall, full-width option), `.tinted` (tintFill bg, tint text), `.gray` (fill bg, tint text — Apple Music "Play/Shuffle" style), `.plain` (tint text, no bg), `.destructive` variants; `.small` size (30 tall, 15 semibold, 12 h-padding) for in-row actions like Join. Pressed: opacity 0.7. Disabled: opacity 0.35. Loading: spinner replaces label, width fixed.
- **Glass icon button** — 44 hit area, 34–36 visual circle, `material` blur on normal backgrounds or `glass` on artwork, icon 17–20.
- **Switch** — Cupertino switch look, `success` track.
- **Segmented control** — Cupertino sliding segmented control look.
- **Sheets** — grabber 36×5 `tertiaryLabel`; header row: title (headline, centred) with optional leading Cancel / trailing Done (plain buttons) or a glass xmark; detents medium (~50%) and large; drag-to-dismiss. Background `elevated` (grouped sheets: `groupedBackground` light / `#1C1C1E` dark).
- **Alerts** — centred iOS alert on every platform: title headline, message footnote, buttons 17 (preferred action semibold, destructive in `danger`), side-by-side for two, stacked for more; optional text field (join-with-link, rename). Width 270.
- **Menus** — iOS pull-down menu look: `material` blur, radius 14, rows 44 with title left and icon right, destructive rows red, separators between groups. Used for every "•••".
- **Toast / HUD** — the single notice channel (`widgets/notice.dart`) renders as a capsule (`material` blur, icon + footnote/subheadline text, optional tint action) near the bottom, above the mini player, auto-dismiss. No full-width snackbars.
- **Avatar** (D6) — circle, flat colour from an 8-colour muted palette keyed by stable id (Apple system blue, indigo, purple, pink, red, orange, green, teal at ~85% saturation / slightly darkened so white initials pass 3:1), white initials semibold at 0.4× size. No rings. Face pile: overlap 30%, each avatar gets a 2 px cutout in the background colour (separator, not decoration), max 3 + "+N" in secondaryLabel.
- **Artwork** — real covers with radius per size; placeholder = `fillSecondary` ground + `CupertinoIcons.music_note` in `tertiaryLabel` at 40% of the tile. On the Now Playing backdrop the placeholder is `#FFFFFF` @ 12% with a white @ 50% note. Remove the headphones-logo placeholder and all gradient placeholders.
- **Empty state** — centred: 48 icon in `tertiaryLabel`, title2-ish (22 bold), one subheadline secondaryLabel sentence, optional `.filled` or `.plain` action. No illustrations.
- **Progress** — `CupertinoActivityIndicator` look everywhere (no Material circular indicators).

## 6. Screens

All existing functionality must keep working: joining spinner on the tapped nearby row, the single notice channel from the router shell, failed-add summaries, join-with-link, scanner denied/invalid states, deep-link confirm alert, permission rationale texts, ended-phase visibility outside `/room`, engine states (resume audio, retry, host asleep, kicked, no-LAN), per-guest permission overrides, latency nudge, diagnostics, history replay. Read `lib/src/state/session_controller.dart` before touching a screen.

### 6.1 Home — `screens/home_screen.dart`
- `background`. Large title **Nearby**. Trailing nav items: scan (`qrcode_viewfinder`; on platforms without a camera it opens the Join with Link alert) and your avatar (30) → Settings.
- Rooms: plain `JamRow`s — host avatar 44, title = room name (body), subtitle only when known and true (the preset, e.g. "Everyone can add music"; nothing invented — mDNS carries only name + join URI), trailing `JamButton.tinted.small` **Join** (spinner while joining). Whole row is tappable.
- Empty: empty state "No Jams Nearby" / "Jams on this Wi‑Fi show up here." with `.plain` "Scan a Code". No "Listening for rooms" line, no dot. No-LAN: "Not on Wi‑Fi" / one sentence on hotspots, same component.
- **Recent** section below (title3 header "Recent" with trailing `.plain` "See All" → History) with up to 3 past jams (art 48, name, "You hosted · 12 songs · Yesterday"). Hidden when there is no history.
- Bottom: `JamButton.filled` **Start a Jam**, full width with 16 margins, above the home indicator, on a `material` blur strip only once content scrolls under it. Hidden while a jam is running (the mini player shows instead) if that's current behaviour.
- History's nav-bar clock icon goes.

### 6.2 Start a Jam — `screens/host_setup_screen.dart`, `widgets/library_sheet.dart`
- Large sheet/page on `groupedBackground`; nav: **Cancel** (leading) and **Start** (trailing, semibold tint, enabled with defaults).
- Top: room name as a large inline text field (title2 bold, placeholder = default name, clear button).
- Section "Songs": first row **Add Songs** (tint, plus icon) → picker/library; then the chosen songs as rows (art 44, title, duration), swipe to remove, count in the section header ("12 Songs").
- Section: **Guests Can** row → value (preset name) → menu or pushed checkmark list (Add Music / Control Playback / Listen Only).
- Section: **Show to People Nearby** switch; footer "People on this Wi‑Fi can see and join this jam."
- Library sheet (Android media library): large sheet, search field, plain rows with art + title + artist, trailing checkmark circle when selected, **Done** with count.

### 6.3 Now Playing — `screens/room_screen.dart`, `widgets/transport.dart`, `widgets/nudge_slider.dart`, `widgets/room_banner.dart`, `widgets/sync_indicator.dart`, `widgets/drag_to_dismiss.dart`, `design/artwork_tint.dart`
- **Backdrop (D4)**: the cover scaled to fill, blur σ ≈ 60–80, plus a 25–35% black overlay so white text holds AA; a slow cross-fade (600 ms) on track change. Placeholder covers → flat `#1C1C1E`. Light status bar icons. This is the only gradient-like surface in the app.
- **Top**: grabber (36×5, white @ 35%) — drag down dismisses. Below it a row: glass `chevron_down` (left), room name centred (headline, white) with a footnote line under it **only** when there is a problem (warning text, no dot), glass invite button `person_badge_plus` (right).
- **Artwork**: square, side margin 28–32, radius 12, `JamShadow.artwork`. While paused it springs to 0.86 scale.
- **Title block**: left-aligned title (title3, white) and "Added by Mia" / "Added by you" (title3 regular, white 60%), single-line with fade/marquee-free ellipsis. Right: glass `•••` (30) → menu: Invite People, People, Sound Offset…, Diagnostics, then a destructive group: End Jam (host) / Leave Jam (guest).
- **Scrubber**: 6 px capsule track (white 25%, elapsed white 85%), no thumb; grows to 10 px while dragging. Times below in caption1 tabular white 60% (elapsed left, "−remaining" right). Not draggable without `controlPlayback`.
- **Transport**: `backward_fill` 34, `play_fill`/`pause_fill` 44, `forward_fill` 34, white, no circles, evenly spaced; disabled at 30%.
- **Footer row** (Apple Music's three icons): People (face pile of up to 3 avatars 24 + count) → People sheet; Sound Offset (`speaker_2`) → offset/nudge sheet; Queue (`list_bullet`) → toggles the in-place queue, selected state = white circle behind a dark glyph.
- **Queue in place (D5)**: artwork animates into a 56 thumbnail at top-left beside title/added-by and the `•••`; the list fills the middle: header "Up Next" (headline white) with trailing count; first row **Add Songs** (only with `addTracks`); rows = art 44, title (white), "Added by Mia · 3:42" (white 60%), drag handle (white 35%) when allowed; swipe-to-remove and long-press menu (Play Next, Remove) per permissions; failed/unsupported rows show the reason in `danger`. Empty: "Nothing up next" + Add Songs. Scrubber + transport stay pinned. Tapping the queue icon again or the thumbnail restores the big artwork.
- **Engine states**: a glass capsule under the header row with one sentence and an inline action ("Tap to Resume Audio", "Try Again"). Never a coloured full-width banner.
- **Terminal states** (ended / kicked / host gone / rejected): leave the immersive look; `background`, centred empty state with an icon, title2 title, one-line reason, **Try Again** (filled) + **Back to Nearby** (plain) for hostGone/rejected; only **Back to Nearby** for kicked/ended.
- **Jam-started overlay**: removed. Success haptic instead.
- **Wide (D7)**: the docked room panel uses the same immersive layout scaled to its width; queue in place still works.

### 6.4 Mini player — `widgets/room_bar.dart`
Floating capsule 64 tall, 12 side margin, 8 above the home indicator, `material` blur, radius = height/2, subtle 0.5 px separator stroke. Art 40 (radius 8), title (subheadline semibold) + room name (footnote secondaryLabel; replaced by the problem line when there is one), `play_fill/pause_fill` 22 and `forward_fill` 22 (when permitted). No progress line, no top border, no avatar. Tap → Now Playing (hero the artwork if cheap). On desktop widths the docked variant uses the same row content.

### 6.5 People — `widgets/room_sheet.dart`, `widgets/peer_row.dart`
Split the current long sheet into **People** and **Invite**.
- People: grouped sheet (medium → large), title "People", **Done**. Row **Invite People** (tint, `person_badge_plus`) → Invite. Section of people: avatar 40, name (body), subtitle "Host" / "You" / "Host · You" / warning "Still loading songs…"; host sees a trailing `•••` menu per guest (permissions overrides, Remove from Jam — destructive). Section **Guests Can** → preset value + per-capability switches (host only; guests see a read-only line). Section **Show to People Nearby** switch (host). Last section: centred destructive **End Jam** (host) / **Leave Jam** (guest), with a confirmation alert.
- Invite: medium sheet, title "Invite People", xmark. QR 220 on a white rounded (20) plate with 16 padding — always white, no logo badge, no glow. Room name (headline) under it and "Anyone on this Wi‑Fi can scan to join." (subheadline secondary). `JamButton.filled` **Share Link** and `.plain` **Copy Link** (toast "Link Copied"). The "Room code" card is removed.

### 6.6 Supporting sheets — `widgets/diagnostics_sheet.dart`, `widgets/permission_sheet.dart`, `widgets/queue_sheet.dart`
- Diagnostics: grouped list of label/value rows (values tabular secondaryLabel), Copy action in the nav.
- Permission primers: sheet with a 48 tint icon, title2 title, body text, **Continue** (filled) and **Not Now** (plain). Contextual only, never chained after onboarding.
- `queue_sheet.dart` becomes the in-place queue list widget used by Now Playing (6.3) and the wide docked panel.

### 6.7 History — `screens/history_screen.dart`
`background`, large title **Past Jams**. Plain rows: art 56 (2×2 mosaic only when ≥ 4 distinct real covers; otherwise first cover/placeholder), name (body), "You hosted · 12 songs · Yesterday" (subheadline secondary), chevron. Swipe → **Forget** (destructive). Tap → detail page: art 200 centred, name title2, subtitle, `JamButton.gray` **Host Again** (and the replay path that exists today), track list with "Added by …", `•••` in nav with Forget. Empty: "No Past Jams" / "Jams you host or join show up here."

### 6.8 Settings — `screens/settings_screen.dart`
`groupedBackground`, large title **Settings**, inset grouped, no icon tiles. Keep every current setting; typical grouping: **Name** (value + chevron → rename alert); **Appearance** (System / Light / Dark checkmark rows or a segmented control); **Playback** (Sound Offset); **Help** (Diagnostics, error log if present); **About** (Version, Licenses). Footers explain anything non-obvious in one sentence.

### 6.9 Onboarding — `screens/onboarding_screen.dart`
One page (no carousel, no page dots): title "Welcome to LocalJam" (largeTitle, left-aligned, top inset ~ 60), three feature rows (tint icon 30, headline + one subheadline secondary sentence each), filled **Continue** pinned at the bottom. Gate (`onboarding_seen`) and skippability unchanged.

### 6.10 Scan — `screens/scan_screen.dart`, `widgets/join_link_dialog.dart`
Full-bleed camera on black. Glass xmark top-left. Centred rounded-rect viewfinder outline (white 2 px, radius 24, ~ 70% width) with a dim outside. Caption under it: "Point at a LocalJam code" (subheadline white). Bottom: `.plain` (white) **Enter Link** → Join with Link alert (title "Join with Link", message, text field, Cancel / Join). Denied/invalid states: same black screen, centred message + **Open Settings** tinted.

### 6.11 Shell, sidebar, dialogs — `router.dart`, `widgets/app_sidebar.dart`, `widgets/dialogs.dart`, `widgets/rename_dialog.dart`, `widgets/notice.dart`, `widgets/session_gate.dart`
- Sidebar (wide): `material` translucent column like Music on macOS; rows 32–36, icon + title, selected = `tintFill` rounded highlight with tint icon/text.
- All dialogs become iOS alerts (5). Deep-link confirm: "Join Mia's Jam?" / Cancel / Join.

## 7. Removed outright

Plus Jakarta Sans + `assets/fonts`; all gradients except the D4 backdrop; jam-started overlay; avatar bob / glow breathe / live-dot animations; status dots and "In sync"/"Listening for rooms" lines; uppercase section labels; HOST/YOU pills; room-code card; headphone placeholder art; button shadows; Material ripples; cream/plum/apricot palette. App icon and splash artwork stay; splash background colour becomes `#FFFFFF` / `#000000`.

## 8. Engineering rules

- `flutter analyze` zero issues; `flutter test` green. Tests asserting old widgets/strings are updated, not deleted, unless the widget itself is removed. New shared components get widget tests.
- Partition by file ownership; never edit a file another agent owns. Shared components only change in the foundation pass (or via a request to the lead).
- Semantics labels on every icon-only button; 44 minimum hit target; contrast AA for text on every surface (check white on the D4 backdrop with the overlay).

## 9. Review checklist (real screenshots, light + dark, iPhone + Android + one wide)

1. Any gradient, glow, coloured ring, status dot, uppercase label or pill left?
2. Is raspberry only on tappable things / selection?
3. Do sizes match the type table? Any hand-rolled font sizes?
4. Row heights, insets, separators inset to text, section spacing — does it look like iOS Settings / Apple Music side by side?
5. Does every engine state and terminal state still render and read as plain language?
6. At 1.3× text, does anything clip?
7. Does the screen still do everything it did before (compare with the feature list in §6)?
