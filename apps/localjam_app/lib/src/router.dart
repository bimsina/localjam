/// Routes, and the shell that keeps the docked room bar under everything you
/// can reach while a jam is running.
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'design/tokens.dart';
import 'screens/history_screen.dart';
import 'screens/home_screen.dart';
import 'screens/host_setup_screen.dart';
import 'screens/room_screen.dart';
import 'screens/scan_screen.dart';
import 'screens/settings_screen.dart';
import 'state/session_controller.dart';
import 'widgets/room_bar.dart';

/// Arguments for re-hosting a past jam ("Host it again").
class HostSetupArgs {
  const HostSetupArgs({required this.paths, required this.name});

  final List<String> paths;
  final String name;
}

GoRouter buildRouter(JamSessionController session) => GoRouter(
  // Rebuild routes when the session starts or ends, so the redirect below
  // and the room bar both react without a screen having to push anything.
  refreshListenable: session,
  initialLocation: '/',
  redirect: (context, state) {
    final goingToRoom = state.matchedLocation == '/room';
    final hasRoom = session.isLive || session.phase == JamSessionPhase.ended;
    if (goingToRoom && !hasRoom) return '/';
    return null;
  },
  routes: [
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

/// Docks the room bar beneath whichever shell screen is showing.
///
/// The bar owns the bottom inset while it is visible, so the screen above it
/// must not also pad for the home indicator.
class _RoomBarShell extends StatelessWidget {
  const _RoomBarShell({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final live = JamSession.of(context).isLive;
    if (!live) return child;
    return Column(
      children: [
        Expanded(
          child: MediaQuery.removePadding(
            context: context,
            removeBottom: true,
            child: child,
          ),
        ),
        const RoomBar(),
      ],
    );
  }
}
