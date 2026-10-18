/// Routes, and the shell that floats the mini player over everything you can
/// reach while a jam is running (DESIGN_SPEC v3 §6.11).
library;

import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:go_router/go_router.dart';
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
      // Start a Jam is a sheet (§6.2): it rises over home, which recedes
      // behind it the way an iOS page sheet does, with Cancel and Start in
      // its own nav bar. A desktop window gets a plain page instead — a
      // phone-shaped card over a 1280 px window is a dialog wearing a
      // costume.
      pageBuilder: (context, state) {
        // `extra` when the router still has it; the controller's draft when
        // a rebuild dropped it — the same args either way.
        final args = state.extra as HostSetupArgs?;
        final draft = session.hostSetupDraft;
        Widget screen([ScrollController? controller]) => HostSetupScreen(
          initialPaths: args?.paths ?? draft?.paths,
          initialName: args?.name ?? draft?.name,
          scrollController: controller,
        );
        if (context.jamBreakpoint.hasSidebar) {
          return CupertinoPage<void>(
            key: state.pageKey,
            fullscreenDialog: true,
            child: screen(),
          );
        }
        return _JamSheetPage<void>(
          key: state.pageKey,
          builder: (context, controller) => screen(controller),
        );
      },
    ),
    GoRoute(path: '/scan', builder: (context, state) => const ScanScreen()),
  ],
);

/// A go_router page that presents its route as an iOS page sheet
/// ([CupertinoSheetRoute]): the page under it scales back, the sheet keeps a
/// gap at the top, and a downward drag — on the sheet or on its scroll view
/// at rest — dismisses it.
class _JamSheetPage<T> extends Page<T> {
  const _JamSheetPage({super.key, required this.builder});

  /// Builds the sheet's content; hand the controller to its scroll view so
  /// the drag-to-dismiss can take over at the top of the scroll.
  final Widget Function(BuildContext context, ScrollController controller)
  builder;

  @override
  Route<T> createRoute(BuildContext context) =>
      CupertinoSheetRoute<T>(settings: this, scrollableBuilder: builder);
}

/// How far the floating mini player reaches up from the home indicator: the
/// 64 capsule and the 8 it floats above the indicator. Screens in the shell
/// see it as extra bottom padding, so their last row scrolls clear of it.
const double kJamMiniPlayerReach = JamMetrics.miniPlayerHeight + JamSpace.sm;

/// The gap between the mini player and a notice floating above it.
const double _kNoticeAboveBar = JamSpace.md;

/// Navigation chrome, per breakpoint.
///
/// Wide windows get a sidebar holding identity, destinations and the live
/// jam; compact and medium ones float the mini player over the bottom of
/// whatever screen is showing. Both are the same information — a 1400px
/// window just has somewhere better to put it.
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
    // A name changed in Settings (or adopted after a prefs timeout) has to
    // reach the sidebar's identity row too.
    JamIdentity.changes.addListener(_onIdentityChanged);
  }

  void _onIdentityChanged() => unawaited(_load());

  /// The single place notices are shown.
  ///
  /// The shell sits above every screen, so one subscription here covers the
  /// whole app and no screen has to grow error plumbing of its own.
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
  /// the *window* regardless of which route is on top. Everything it has to
  /// clear is known here, in the one place that knows both the breakpoint and
  /// the current route.
  ///
  /// The safe area is *not* added here: the host applies it, so what these
  /// numbers describe is the chrome sitting above the home indicator.
  EdgeInsets _noticeMargin() {
    const base = JamSpace.lg;
    final onRoom = GoRouter.of(context).state.matchedLocation == kRoomPath;
    if (onRoom) {
      return const EdgeInsets.all(
        base,
      ).copyWith(bottom: base + kJamRoomPeopleStrip);
    }
    final phoneChrome = !context.jamBreakpoint.hasSidebar;
    final hasBar = phoneChrome && JamSession.of(context).hasRoom;
    if (!hasBar) {
      // Home pins Start a Jam to the bottom while no jam runs; a notice
      // floats above it rather than over the button.
      final onHome = GoRouter.of(context).state.matchedLocation == '/';
      if (phoneChrome && onHome) {
        // The button sits on the home indicator's inset, or 16 above the
        // edge where there is none (JamBottomBar).
        final floor = MediaQuery.paddingOf(context).bottom > 0
            ? 0.0
            : JamSpace.lg;
        return const EdgeInsets.all(
          base,
        ).copyWith(bottom: floor + JamMetrics.buttonHeight + _kNoticeAboveBar);
      }
      return kJamNoticeMargin;
    }
    // Above the floating capsule, never on it.
    return const EdgeInsets.all(
      base,
    ).copyWith(bottom: kJamMiniPlayerReach + _kNoticeAboveBar);
  }

  @override
  void dispose() {
    JamIdentity.changes.removeListener(_onIdentityChanged);
    unawaited(_noticeSub?.cancel());
    super.dispose();
  }

  Future<void> _load() async {
    final name = await JamIdentity.displayName();
    if (mounted && name != _identity) setState(() => _identity = name);
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
      return ColoredBox(
        color: context.jamColors.background,
        child: Row(
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

    // The mini player floats over the screen (D1): it paints its own capsule,
    // margins and bottom inset, so nothing here frames it. The screen
    // underneath sees the capsule as bottom padding — its content scrolls
    // under the blur and its last row comes to rest above it.
    final media = MediaQuery.of(context);
    return Stack(
      children: [
        MediaQuery(
          data: media.copyWith(
            padding: media.padding.copyWith(
              bottom: media.padding.bottom + kJamMiniPlayerReach,
            ),
          ),
          child: widget.child,
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Center(
            // A capsule stretched across a tablet carries a 40 pt cover a
            // long way from its controls; past a phone's width it centres.
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: JamContentWidth.floatingRoomBar,
              ),
              child: const RoomBar(),
            ),
          ),
        ),
      ],
    );
  }
}
