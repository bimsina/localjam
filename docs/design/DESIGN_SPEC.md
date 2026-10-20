# LocalJam — Design Spec v4.1

Updated 2026-10-20. Target: `apps/localjam_app`. Describes what is built on
`identity-v4`. `tokens.dart` and `typography.dart` hold the exact values, and
the widget files' headers hold the details.

This spec replaces the visual direction of [v3](DESIGN_SPEC_V3.md). v3 is
still the baseline for behaviour: navigation, permissions, sync, recovery
flows, platform integration, and any metric that v4 does not change.

**Copy is in sentence case.** Titles, buttons, menu items, rows, segments,
section headers, alerts and notices capitalise only their first word, like
the sentences and counts around them: "Start a jam", "Invite people", "Up
next", "The host ended the jam", "12 songs", "Just you". Proper nouns keep
their capitals: LocalJam, Wi‑Fi, Bluetooth, GitHub, and the names of
people, songs, artists and jams. So does a page named as a place to go
("Back to Nearby", "Open Settings", "You'll find it in Past jams"). "jam" is
a common noun. This replaces v3's Title Case rule.

## Direction

LocalJam should feel warm and intimate, with precise, understated
refinement: a well-made place to listen together. It takes Apple's ease but
has its own identity, and it isn't a music player. The song comes first. The
hierarchy follows Spotify Jam:

- **Now Playing** stays focused on the song.
- **The queue** is where people collaborate.
- **People** show up compactly and open on demand.

Every expressive detail has to earn its place. Motion should say that
something happened. The app has no decorative gradients, no eyebrow labels,
no status dots or connection badges, no emoji and no filler copy.

## Identity

- **Surfaces.** Light mode uses warm paper (`FAF8F5`) and grouped paper
  (`F2EFEB`) with near-white cells. Dark mode uses warm charcoal: background
  `1A1715`, cells `262220`, sheets `221E1B`, with R > G > B throughout.
  - Inks are warm in both themes. Light: label `2A2420`, secondary `6F6761`,
    tertiary `82786F`. Dark: label `F7F2EE`, secondary `BEB5AE`, tertiary
    `8E847D`.
  - Every text pair is checked in `test/design_test.dart`. Both Increase
    Contrast palettes are a step firmer than the normal ones.
- **Raspberry is only for things you can tap or that are selected.** Text
  tint is `B82F59` on light and `F28AA7` on dark.
  - Fills use `tintFilled` `B82F59` in both themes: filled buttons, switches,
    the selection check.
  - Hero, onboarding and permission glyphs never use it, and neither does the
    wordmark, which is in ink.
  - Red text is `danger`. A red fill is `dangerFilled`.
- **Type.** Manrope is for headings and named things: large title, title1–3,
  a song's title, a jam's name, the wordmark, monograms and initials. The
  system face covers everything from 17 pt headline down: chrome, rows,
  buttons and running text. Don't animate between the two families.
  - A jam's name in a list row is `context.jamNameRow`: Manrope 17/22 bold.
    Larger Manrope is only for page and sheet titles.
- **Soft rectangles, never capsules.** Radii come from `JamRadius`:

  | Element | Radius |
  |---|---|
  | Button, large / small | 16 / 10 |
  | Alert button | 14 |
  | Toast and player banner | 16 |
  | Mini player | 20 |
  | Section | 20 |
  | Lone row or one-row menu | 12 |
  | Menu | 22 |
  | Alert | 34 |
  | Sheet | 38 |
  | Text field | 10 |
  | Play square | 28, continuous |
  | Artwork | 6 / 8 / 12 / 18 by size |

  Only faces, glass icon buttons and the scrubber are round.
- **Matte, not glassy.** Bars, the mini player and toasts use the nearly
  opaque `material`. Menus are opaque. There is one shadow, under large
  artwork.
- **The backdrop (D1).** Behind Now Playing is a flat wash of the cover's
  dominant hue that fades into charcoal.
  - Saturation and lightness are clamped so that secondary white text stays
    at 4.5:1 or better.
  - Pinks near raspberry turn dusty. Reds turn brick and yellows turn amber.
  - Black, white and grey covers get a warm grey wash.
  - No image is painted behind the page.

## People and jams

- **Faces (D3).** A face is a flat colour with white Manrope initials.
  - There are 8 earthy hues of equal luminance (terracotta, sea, ochre,
    slate, olive, indigo, pine, plum). None is near raspberry, and white
    initials reach 4.7:1 or better on every one.
  - A face is keyed by display name, so a person is the same colour
    everywhere. Within a jam, `jamPeopleColors` assigns colours host first,
    then by name, so nobody shares a colour and every phone agrees.
  - Initials come from letters and digits only. Two people with the same name
    become "Sam" and "Sam 2".
- **The jam mark (D4, R4, R5).** `JamMark` is a continuous-corner square.
  - It shows **one cover** (the jam's first song with art), or a Manrope
    monogram on `fill`. It is never a mosaic, a person's colour or raspberry.
  - The host's face appears as a badge, knocked out of the tile, only where
    it adds something: a guest's Invite sheet and the page a jam ends on. It
    never appears on list rows (Nearby, Recent, Past jams), never shows your
    own face, and is never guessed from a name.
  - Sizes: Nearby 44, rows and Invite 56, ended and past-jam pages 88. On the
    Now Playing backdrop it is the empty room's quiet see-through tile.
- **People phrasing (R9).** One function produces every summary: "Just
  you", "With Mia", "With Mia and Theo", "With Mia, Theo and 3 others".
  - It never says "and 1 other"; a single extra person is named instead.
  - `JamPeopleLine` cuts long names before it ever cuts the count. A screen
    reader hears what the line shows.
  - The same phrasing is used in the Now Playing footer, the Invite sheet and
    Past jams.
- **Credits mean someone else (R3).**
  - Song rows show a 20 pt face at the trailing edge only for songs someone
    else added, and every face in a list shares one column. Your own songs
    carry no credit.
  - When a song has no artist, the row says "Added by Mia" in words.
  - Now Playing shows one quiet "Added by Mia" line with an 18 pt face. It
    appears only when the adder isn't you and the jam has at least two other
    people.
  - Credit faces grow with the text beside them, up to 1.5×.

## Hierarchy and layout

- **Now Playing** is immersive in both themes. From top to bottom:
  - A header with a chevron, the jam's name and Invite.
  - The cover, 18 radius. When paused it settles to 96%; under reduced motion
    it dims instead.
  - The title in Manrope 28. When the title is too long it stays on one line
    and marquees (R1), so the transport never moves.
  - The artist, then the credit line if there is one.
  - The scrubber.
  - The transport: skip glyphs and a 76 pt ivory play square. On a guest's
    phone without playback rights, the play square is a hairline outline.
  - The footer: a pile of up to three other people's 24 pt faces (your own
    face only when you're alone) with "Just you" or "With Mia and Theo" and
    a chevron to People, then the Up next toggle (selected, it is glass,
    never ivory).

  The queue opens in place. The cover shrinks to a 56 pt thumbnail beside the
  title, and the scrubber and transport stay pinned. Problems are one footnote
  under the jam's name. A state that needs action is a banner above the cover
  with one action. With nothing playing, the room shows its mark, "Nothing
  playing", and Add songs where the play square will be.
- **The room's palette (R2).** Everything opened from inside the room
  (sheets, alerts, menus, People, Invite, Sound offset, Diagnostics) uses the
  room's dark palette in both themes.
- **Shape by window.** A short window (under 560 pt tall) or a wide pane
  turns the player side-on, with the cover on the left. Wide layouts keep the
  sidebar, and the room's people dock as a 360 pt panel.
- **Song rows** have two lines: the title, then "Artist · 4:10" in tabular
  figures. The artist is cut before the length is. At large text sizes the
  rows grow and wrap.
- **Nearby.** Each jam is a quiet bordered card holding the mark, the name at
  row scale, and a small tinted Join. Join moves under the name when the
  name would otherwise get too narrow. Scan code and Join with link sit under
  the list, and Start a jam is pinned at the bottom. While you're in a jam,
  Home shows that jam (its mark with the playing cover) rather than "No
  jams yet".
- **Past jams and Recent** use one row: the mark, the name, a face pile with
  the people line, "You hosted · 12 songs · Yesterday", and a chevron. A past
  jam's page shows the 88 mark, Host again (filled), and its songs credited
  the same way the queue credits them.
- **Start a jam.** The jam's name is a large inline Manrope field. Below it
  come the Songs (under the one Add songs row), Guests can, and Show to
  people nearby.

## Components

- **Buttons.** Filled, tinted, gray and plain. Heights are minimums, so a
  button grows with its label.
  - Disabled (R8): one rule for every kind. Grounded buttons go to a neutral
    `fill` with `tertiaryLabel` text; plain buttons go to `tertiaryLabel`.
    Never a faded raspberry.
  - Loading: a turning ring, either in place of the label or beside the
    words ("Trying…").
- **Progress.** `JamProgressRing` is the only progress indicator. It fills
  to show an amount (a download) and turns while waiting. It is never the
  tint and never Cupertino spokes.
- **Fields and checks.**
  - `JamTextField` is a filled `fillSecondary` field with radius 10, a
    `secondaryLabel` placeholder and an optional magnifier.
  - `JamFieldClearButton` is the only clear button. It sits on the trailing
    inset.
  - `JamSelectionCheck` is a 22 pt `tintFilled` circle with LocalJam's own
    check mark; unselected, it is a 1.5 pt `tertiaryLabel` ring.
  - The segmented control is LocalJam's own: a soft track with a concentric
    thumb, 44 pt tall, with the chosen word in semibold.
- **Lists.**
  - Inset-grouped sections have radius 20. A lone row gets 12.
  - Hairlines are inset to the text. Inside a block they run to the block's
    edge; in plain lists they stop where the content stops.
  - Chevrons and values end on the same trailing edge.
  - `JamAddSongsRow` is the only Add songs.
- **Sheets.**
  - A sheet that commits something has Cancel and a verb (Start, Join, Add).
  - Every other sheet closes with a trailing semibold **Done**, never an
    xmark.
  - Sheets float at the medium detent, attach to the edge at the large
    detent, and become a centred form sheet on wide windows.
- **Menus, alerts, notices.**
  - Every pull-down and the queue's context menu use one `JamMenuPanel`.
  - Alerts have a Manrope title, a leading-aligned message and
    soft-rectangle buttons. A destructive action uses `dangerFilled`.
  - Toasts and the player's banner share one soft-rectangle surface and are
    never shown over a control.
- **Empty and terminal pages.** Every empty, ended, error and denied state
  uses `JamEmptyState`: a hero glyph or a jam mark, a Manrope title, one
  balanced sentence, and at most one action plus a plain second action.
  - The block is anchored so its glyph stays at the same height whatever the
    text says.
  - Network pages use the outline Wi‑Fi glyph.
- **One label per action.** An action has the same words everywhere it
  appears: Scan code, Join with link, Invite people, Add songs, Leave jam,
  End jam, Done.

## Large text and motion

- **Large text is a first-class layout (R10).** Above about 2.2× text, or
  when the cover would shrink below 120 pt, Now Playing switches to its
  accessibility layout:
  - There is no cover. The song's title, artist and credit wrap and scroll.
  - The scrubber, transport and footer are pinned at the bottom and never
    overlap.
  - The room's chrome stops growing at 2×.

  Elsewhere, rows, buttons and Nearby cards grow and wrap rather than clip.
- **Motion is restrained and means something.** Durations run 100–350 ms
  for controls, 400 ms for sheets, 550 ms for the pause spring and 600 ms for
  the backdrop cross-fade.
  - Motion marks events: a face growing into the pile when someone joins, a
    song entering the queue, the cover morphing into the queue thumbnail.
  - Under reduced motion:
    - Titles don't marquee; they end in an ellipsis.
    - The cover dims instead of scaling.
    - The play square deepens instead of squeezing.
    - Notices fade in place.
    - The cover doesn't fly between the mini player and Now Playing.

## Accessibility and behaviour

Keep the existing semantics, capability gates, keyboard handling, 44 pt hit
targets, contrast variants and reduced-motion support.

- Screen readers hear the whole title, and hear people phrases exactly as
  they are shown.
- Failures are explained where the person can act on them.
- "Back to Nearby" works at any time, including while a retry runs. A retry
  that is given up on doesn't leave anything behind.
- Audio and session behaviour stay in the engine (`packages/`).

## Review artifacts

The [screen gallery](../screenshots/identity-v4/index.html) holds light and
dark captures of pages, sheets, dialogs, host and guest states, errors,
responsive layouts, and stress cases: long names, seven people, large text,
and extreme covers.

The captures are production Flutter widgets rendered by a deterministic
harness, using fixture songs and mocked native services. They don't
validate hardware audio, camera feeds, native pickers or OS permission
dialogs.

To regenerate on macOS, run from `apps/localjam_app`:

```sh
flutter test tool/capture_design.dart --no-pub
python3 tool/build_gallery.py
```

The harness loads SF from the local OS and doesn't redistribute it. Manrope
is bundled under OFL 1.1 and listed in the app's licenses.
