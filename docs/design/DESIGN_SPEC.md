# LocalJam — Design Spec v4

Updated 2026-10-19. Target: `apps/localjam_app`.

## Direction

Apple-inspired ease, with LocalJam's own warmth and identity. The song is the
primary focus. Spotify Jam informs the shared-listening hierarchy: music first,
a compact presence of people, and collaboration in the queue.

This specification supersedes the visual direction in [v3](DESIGN_SPEC_V3.md).
The existing navigation, permissions, synchronization, recovery flows, and
platform integrations remain the behavioral baseline.

## Identity

- Warm paper backgrounds in light mode; warm charcoal in dark mode.
- Raspberry for actions and selections. Switches use the brand fill.
- Manrope for headings; system fonts for body text and controls.
- Existing LocalJam symbol paired with a wordmark on Nearby and onboarding.
- Soft rectangles: primary buttons 16, small buttons 10, grouped surfaces 20,
  mini player 20, large cover 18. Avoid making every control a capsule.
- Matte surfaces and restrained translucency. Artwork supplies the atmosphere;
  its contrast-safe sampled color fades into charcoal behind Now Playing.

`tokens.dart` and `typography.dart` are the source of truth for exact values.
The bundled Manrope font is licensed under OFL 1.1 and listed in app licenses.

## Hierarchy and layout

Now Playing leads with cover art, a 28-point Manrope song title, then the artist.
Contributor credit belongs in the queue. The primary play control is a 76-point
ivory rounded square. Pausing gently scales artwork to 96%; reduced-motion
preferences still apply.

The footer has a compact avatar group / Your jam entry and a Queue action.
Inviting remains in the header. Sound Offset moves into the overflow menu with
diagnostics and leaving/ending the jam. The queue still opens in place.

Song rows preserve title and artist. When a contributor is available, credit and
duration occupy a smaller third line. Rows expand with larger accessibility text.

Nearby uses quiet bordered cards for available jams and a clear Start a Jam
action. Onboarding opens with “Your music. Better together.” Supporting screens
and sheets share the same color, type, and control system. Wide layouts retain
the sidebar and docked room architecture.

## Accessibility and behavior

Keep existing semantics, capability gates, keyboard handling, hit areas, contrast
variants, and reduced-motion support. Failures explain what happened where the
person can act; do not add decorative connection badges or persistent status
noise. Audio/session behavior stays in the existing engine.

## Review artifacts

[Screen gallery](../screenshots/identity-v4/index.html) contains light and dark
captures of pages, sheets, dialogs, host/guest states, errors, and responsive
layouts. These are production Flutter widgets rendered by a deterministic
capture harness with fixture songs and mocked native services. They do not
validate hardware audio, camera feeds, native pickers, or OS permission dialogs.

Regenerate on macOS from `apps/localjam_app`:

```sh
flutter test tool/capture_design.dart --no-pub --reporter expanded
```

The capture harness loads SF from the local OS without redistributing it.
