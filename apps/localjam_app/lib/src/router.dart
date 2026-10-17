/// Routes, and the shell that keeps the docked room bar under everything you
/// can reach while a jam is running.
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'dart:async';

import 'package:localjam_client/localjam_client.dart';

import 'design/breakpoints.dart';
import 'design/tokens.dart';
import 'screens/history_screen.dart';
import 'screens/home_screen.dart';
import 'screens/host_setup_screen.dart';
import 'screens/onboarding_screen.dart';
import 'screens/room_screen.dart';
import 'screens/scan_screen.dart';
import 'screens/settings_screen.dart';
import 'state/onboarding_prefs.dart';
import 'state/session_controller.dart';
import 'widgets/app_sidebar.dart';
import 'widgets/notice.dart';
import 'widgets/rename_dialog.dart';
import 'widgets/room_bar.dart';

/// Arguments for re-hosting a past jam ("Host it again").
class HostSetupArgs {
  const HostSetupArgs({required this.paths, required this.name});

  final List<String> paths;
  final String name;
}

/// Where the intro lives. Its own route, so the gate is a redirect rather
/// than a branch inside the home screen.
const String kOnboardingPath = '/welcome';

/// The room's route, named so the shell can tell when it is on top.
const String kRoomPath = '/room';

/// How much of the room screen's bottom edge the people strip occupies — a
/// 44 dp row over a 12 dp inset. Notices clear it rather than land on it.
const double kJamRoomPeopleStrip = 56;

/// Builds the app's router.
///
/// [onboarding] gates the first launch: while the flag says the intro has
/// not been seen, every route redirects to [kOnboardingPath]. Omit it — as
/// a widget test that is not exercising the gate does — and there is no
/// gate at all.
GoRouter buildRouter(
  JamSessionController session, {
  JamOnboardingPrefs? onboarding,
}) {
  final router = _buildRouter(session, onboarding);
  // Held by the router, which lives as long as the app does.
  _TerminalModalDismisser(session, router.routerDelegate.navigatorKey);
  return router;
}

/// Unwinds sheets, dialogs and menus when the jam under them ends.
///
/// A guest kicked while the queue sheet was open kept the sheet: a live-
/// looking queue sitting on top of a session that no longer exists, with the
/// screen explaining what happened hidden behind it. Centralised here rather
/// than fixed per sheet — the room can raise any number of modals and none of
/// them should have to know about session lifecycle.
class _TerminalModalDismisser {
  _TerminalModalDismisser(this._session, this._navigatorKey)
    : _hadEngine = _session.engine != null,
      _wasEnded = _session.phase == JamSessionPhase.ended {
    _session.addListener(_onSession);
  }

  final JamSessionController _session;
  final GlobalKey<NavigatorState> _navigatorKey;
  bool _hadEngine;
  bool _wasEnded;

  void _onSession() {
    final hasEngine = _session.engine != null;
    final ended = _session.phase == JamSessionPhase.ended;
    // Either half of a session going away: the phase turning terminal, or the
    // engine being torn down under a screen that never saw the phase change.
    final terminal = (ended && !_wasEnded) || (_hadEngine && !hasEngine);
    _hadEngine = hasEngine;
    _wasEnded = ended;
    if (!terminal) return;
    // Next frame: this notification can arrive mid-build (a sheet rebuilding
    // on the same change), and a route cannot be popped from inside one.
    WidgetsBinding.instance.addPostFrameCallback((_) => _popModals());
  }

  void _popModals() {
    // GoRouter's routes are Page-backed; everything above them was pushed
    // imperatively by a `show*` call, which is exactly the set to unwind.
    _navigatorKey.currentState?.popUntil((route) => route.settings is Page);
  }
}

GoRouter _buildRouter(
  JamSessionController session,
  JamOnboardingPrefs? onboarding,
) => GoRouter(
  // Rebuild routes when the session starts or ends — and when the intro is
  // finished — so the redirects below and the room bar all react without a
  // screen having to push anything.
  refreshListenable: onboarding == null
      ? session
      : Listenable.merge([session, onboarding]),
  initialLocation: '/',
  redirect: (context, state) {
    final atOnboarding = state.matchedLocation == kOnboardingPath;
    if (onboarding != null) {
      // Not loaded yet: hold whatever is showing rather than flashing the
      // intro at somebody who has already seen it.
      if (!onboarding.loaded) return atOnboarding ? '/' : null;
      if (!onboarding.seen) return atOnboarding ? null : kOnboardingPath;
      // Seen, and standing on the intro: the deep link or the nearby room
      // that was aimed at home still gets there.
      if (atOnboarding) return '/';
    } else if (atOnboarding) {
      return '/';
    }
    final goingToRoom = state.matchedLocation == '/room';
    if (goingToRoom && !session.hasRoom) return '/';
    return null;
  },
  routes: [
    // Outside the shell: the intro is full-bleed and has no room bar under
    // it — there cannot be a jam running before the first launch finishes.
    GoRoute(
      path: kOnboardingPath,
      builder: (context, state) =>
          OnboardingScreen(prefs: onboarding, onDone: () => context.go('/')),
    ),
    ShellRoute(
      // pageBuilder, not builder: the shell owns a page of its own in the
      // ROOT navigator, and that is the page that animates when the room is
      // dismissed. Left to the default it fades-and-shifts horizontally,
      // which is what made minimising the player slide sideways — a
      // NoTransitionPage on the inner '/' route cannot reach it, because
      // that one lives in the shell's nested navigator.
      // The ground floor: pushed routes animate over it, it never moves.
      pageBuilder: (context, state, child) => NoTransitionPage<void>(
        key: state.pageKey,
        child: _RoomBarShell(child: child),
      ),
      routes: [
        GoRoute(path: '/', builder: (context, state) => const HomeScreen()),
        GoRoute(
          path: '/history',
          builder: (context, state) => const HistoryScreen(),
        ),
        GoRoute(
          path: '/settings',
          builder: (context, state) => const SettingsScreen(),
        ),
      ],
    ),
    GoRoute(
      path: '/room',
      // The room rises from the bottom and dismisses back down — the
      // now-playing gesture from Apple Music and Spotify.
      //
      // It must be PUSHED and POPPED, never `go`-ed to and from: `go`
      // replaces the whole stack, and a replacement removes the outgoing
      // route without running its reverse transition, so the room would
      // vanish instantly while the incoming page slid in horizontally.
      pageBuilder: (context, state) => CustomTransitionPage<void>(
        key: state.pageKey,
        child: const RoomScreen(),
        // Not opaque: Flutter stops building the routes behind an opaque
        // route once its entrance transition finishes, so dragging the
        // player down revealed bare black instead of home. The cost is that
        // home keeps rendering underneath — cheap, and required for both the
        // slide and the dismiss gesture to show anything.
        opaque: false,
        transitionDuration: JamDuration.slow,
        reverseTransitionDuration: JamDuration.base,
        transitionsBuilder: (context, animation, secondary, child) =>
            SlideTransition(
              // Driven off the animation rather than a CurvedAnimation, which
              // would be rebuilt (and leak its listener) every frame here.
              position: animation.drive(
                Tween<Offset>(
                  begin: const Offset(0, 1),
                  end: Offset.zero,
                ).chain(CurveTween(curve: Curves.easeOutCubic)),
              ),
              child: child,
            ),
      ),
    ),
    GoRoute(
      path: '/host',
      builder: (context, state) {
        final args = state.extra as HostSetupArgs?;
        return HostSetupScreen(
          initialPaths: args?.paths,
          initialName: args?.name,
        );
      },
    ),
    GoRoute(path: '/scan', builder: (context, state) => const ScanScreen()),
  ],
);

/// Navigation chrome, per breakpoint.
///
/// Wide windows get a sidebar holding identity, destinations and the live
/// jam; compact ones keep the docked room bar along the bottom. Both are the
/// same information — a 1400px window just has somewhere better to put it.
class _RoomBarShell extends StatefulWidget {
  const _RoomBarShell({required this.child});

  final Widget child;

  @override
  State<_RoomBarShell> createState() => _RoomBarShellState();
}

class _RoomBarShellState extends State<_RoomBarShell> {
  String _identity = '';
  StreamSubscription<JamNotice>? _noticeSub;
  JamSessionController? _boundSession;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  /// The single place notices become SnackBars.
  ///
  /// The shell sits under `MaterialApp`'s root ScaffoldMessenger and above
  /// every screen, so one subscription here covers the whole app and no
  /// screen has to grow error plumbing of its own.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final session = JamSession.of(context);
    if (identical(session, _boundSession)) return;
    unawaited(_noticeSub?.cancel());
    _boundSession = session;
    _noticeSub = session.notices.listen(_show);
  }

  void _show(JamNotice notice) {
    if (!mounted) return;
    // The designed look — glyph, one action, four seconds — rather than a
    // stock SnackBar. Everything the app says out loud comes through here.
    showJamNotice(
      context,
      notice,
      // A notice carrying an action is one the user has to do something
      // about; the rest are the room narrating itself.
      kind: notice.actionLabel == null
          ? JamNoticeKind.info
          : JamNoticeKind.warning,
      margin: _noticeMargin(),
    );
  }

  /// Where a floating notice sits, so it never lands on the thing it is
  /// talking about.
  ///
  /// The notice host is the app's root overlay, so it floats at the bottom of
  /// the *window* regardless of which route is on top — which is how "Ana
  /// joined" ended up covering the room's people strip and the docked bar's
  /// transport. Everything it has to clear is known here, in the one place
  /// that knows both the breakpoint and the current route.
  ///
  /// The safe area is *not* added here: the host applies it, so what these
  /// numbers describe is the chrome sitting above the home indicator.
  EdgeInsets _noticeMargin() {
    const base = JamSpace.lg;
    final onRoom = GoRouter.of(context).state.matchedLocation == kRoomPath;
    if (onRoom) {
      // The room owns the full window; its people strip is the last 12 dp +
      // a 44 dp row above the safe area.
      return const EdgeInsets.all(
        base,
      ).copyWith(bottom: base + kJamRoomPeopleStrip);
    }
    final breakpoint = context.jamBreakpoint;
    final hasBar = !breakpoint.hasSidebar && JamSession.of(context).hasRoom;
    if (!hasBar) return kJamNoticeMargin;
    // The docked bar already sits over the safe area, so only its own height
    // (plus the pill's float, on medium) is added here.
    final float = breakpoint == JamBreakpoint.medium
        ? _FloatingRoomBar._inset
        : 0.0;
    return const EdgeInsets.all(
      base,
    ).copyWith(bottom: base + kJamRoomBarHeight + float);
  }

  @override
  void dispose() {
    unawaited(_noticeSub?.cancel());
    super.dispose();
  }

  Future<void> _load() async {
    final name = await JamIdentity.displayName();
    if (mounted) setState(() => _identity = name);
  }

  Future<void> _rename() async {
    final name = await promptForName(context, current: _identity);
    if (name == null) return;
    await JamIdentity.setDisplayName(name);
    if (mounted) setState(() => _identity = name);
  }

  @override
  Widget build(BuildContext context) {
    if (context.jamBreakpoint.hasSidebar) {
      return Scaffold(
        body: Row(
          children: [
            AppSidebar(
              identity: _identity,
              onRename: () => unawaited(_rename()),
            ),
            Expanded(child: widget.child),
          ],
        ),
      );
    }

    // The bar stays up through the terminal `ended` phase too. Hiding it
    // there was the whole soft lock: an end that arrived while the user was
    // on home left a session nothing on screen could reach or dismiss.
    if (!JamSession.of(context).hasRoom) return widget.child;

    // Medium windows (§5): a full-bleed bar there stretches a 44 dp
    // thumbnail across a tablet, so the bar becomes a floating pill clear of
    // the edge and the content keeps its own bottom inset.
    if (context.jamBreakpoint == JamBreakpoint.medium) {
      return Stack(
        children: [
          widget.child,
          const Align(
            alignment: Alignment.bottomCenter,
            child: _FloatingRoomBar(),
          ),
        ],
      );
    }

    // The bar owns the bottom inset while it is visible, so the screen above
    // it must not also pad for the home indicator.
    return Column(
      children: [
        Expanded(
          child: MediaQuery.removePadding(
            context: context,
            removeBottom: true,
            child: widget.child,
          ),
        ),
        // The ground the bar's translucent surface sits on. In a Column
        // there is nothing painted behind the bar at all, so the blur had
        // the window's black to work with and `surface @ 0.82` over it came
        // out a flat #D1D1D1 — the neutral grey the review caught. With the
        // canvas underneath it reads as the near-white the palette intends.
        ColoredBox(color: context.jamColors.canvas, child: const RoomBar()),
      ],
    );
  }
}

/// The medium-width room bar: a 720-wide pill, `floating` shadow, 16 above
/// the window's bottom edge.
class _FloatingRoomBar extends StatelessWidget {
  const _FloatingRoomBar();

  /// The gap between the pill and the edges it floats over.
  static const double _inset = JamSpace.lg;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final radius = BorderRadius.circular(JamRadius.pill);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        _inset,
        0,
        _inset,
        _inset + MediaQuery.paddingOf(context).bottom,
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: JamContentWidth.floatingRoomBar,
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: radius,
            boxShadow: JamShadow.floating(colors),
          ),
          // The radius goes *into* the bar as well as around it: the 2 dp
          // progress line is pinned to its top edge, and an outer clip alone
          // left it running straight across the corner it had just rounded.
          child: RoomBar(floating: true, borderRadius: radius),
        ),
      ),
    );
  }
}
