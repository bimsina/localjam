# Lead review addendum to DESIGN_SPEC.md — these override the spec where they conflict

1. No listener count anywhere (§6 item 6 contradicts §5 Home). mDNS only carries name + join URI. Room card byline is "Tap to join" or the preset when known; nothing invented.
2. Terminal states (§5): hostGone/rejected get PRIMARY "Try again" (rejoin via retained joinUri — already wired in the controller by the functional-fix pass as a "retry" action) and SECONDARY "Back to nearby"; kicked gets only "Back to nearby". No "Scan a new code" tertiary.
3. The functional-fix pass added controller-level features that every screen MUST keep working: joining state (spinner on the tapped nearby row), a single notice/snackbar channel surfaced from the router shell, failed-add summaries, join-with-link dialog, scanner denied/invalid states, deep-link confirm dialog, permission rationale constants, ended-phase visibility outside /room. Re-skin them; never remove them. Read lib/src/state/session_controller.dart before touching any screen.
4. Jam-started overlay (§5 Room): keep it, but max 700 ms total, skippable on tap, and never on desktop widths ≥ 1000.
5. Onboarding: gate with shared_preferences key `onboarding_seen`. Skippable. Also show on desktop. Do NOT chain the permission sheets after onboarding — they appear contextually as the spec says.
6. Avatar bob + glow breathe: implement, but a single AnimationController per screen (not per avatar), and disabled under MediaQuery.disableAnimations or when the app is backgrounded.
7. Fonts: Plus Jakarta Sans as specified. Bundle only the 5 roman weights. Verify tabular figures on the timer; if tnum fails, use the fixed-width digit fallback.
8. Keep the existing responsive/wide-layout architecture (breakpoints.dart, app_sidebar.dart, docked panel). Restyle, don't rebuild.
9. Nothing may regress `flutter analyze` (zero issues) or `flutter test`. Existing tests that assert old widget types/strings may be updated, not deleted, unless the tested widget is removed by the spec.
10. All user-facing strings live as constants in one file per screen or a shared strings file — no i18n framework yet, but no inline literals scattered in build methods.
