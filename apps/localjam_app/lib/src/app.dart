/// The app root: owns the session and the settings, wires the router, and
/// listens for `localjam://` deep links.
///
/// The session controller lives here rather than in a route, which is what
/// lets a jam survive navigation and lets the docked room bar exist at all.
library;

import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:localjam_client/localjam_client.dart';

import 'design/theme.dart';
import 'router.dart';
import 'state/app_settings.dart';
import 'state/onboarding_prefs.dart';
import 'state/session_controller.dart';
import 'util/network.dart';
import 'util/permissions.dart';
import 'widgets/artwork.dart';
import 'widgets/join_link_dialog.dart';
import 'widgets/permission_sheet.dart';

class LocalJamApp extends StatefulWidget {
  const LocalJamApp({super.key});

  @override
  State<LocalJamApp> createState() => _LocalJamAppState();
}

class _LocalJamAppState extends State<LocalJamApp> {
  final JamSessionController _session = JamSessionController();
  final JamAppSettings _settings = JamAppSettings();
  final JamOnboardingPrefs _onboarding = JamOnboardingPrefs();
  late final GoRouter _router = buildRouter(_session, onboarding: _onboarding);
  final AppLinks _appLinks = AppLinks();
  StreamSubscription<Uri>? _linkSub;

  @override
  void initState() {
    super.initState();
    unawaited(_settings.load());
    // The gate holds every route until this lands, so nobody sees the intro
    // flash past on their second launch.
    unawaited(_onboarding.load());
    unawaited(_listenForLinks());
    // Every OS permission prompt in the app goes through `util/permissions`,
    // and this is what lets it explain itself first. Installed here because
    // the root navigator is the one context that outlives every screen the
    // ask can come from — host setup, the scanner, a library browse.
    jamRationalePresenter = _explainPermission;
    // The OS media card is drawn by the platform from bytes, so it cannot
    // fall back to `JamArtworkTile`'s painted placeholder the way the app
    // does: an untagged track came up as a blank grey square on the lock
    // screen. Same gradient, same mark, pre-rendered.
    JamMediaSessionController.placeholderArtworkProvider = _brandArtwork;
  }

  /// The 512 dp brand placeholder for the lock-screen card.
  ///
  /// Resolved at most once — [JamMediaSessionController] caches what this
  /// returns for the life of the process — and never throws: a missing asset
  /// costs a blank card, not a session.
  static Future<Uint8List?> _brandArtwork() async {
    try {
      final data = await rootBundle.load(kJamPlaceholderArtworkAsset);
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } catch (e) {
      debugPrint('localjam: placeholder artwork unavailable: $e');
      return null;
    }
  }

  /// Shows the rationale sheet for [kind] and answers whether to go on.
  ///
  /// A missing navigator is not a refusal: it means the app is starting up or
  /// tearing down, and the OS prompt should simply proceed unexplained rather
  /// than be swallowed.
  Future<bool> _explainPermission(JamPermissionKind kind) async {
    final context = _router.routerDelegate.navigatorKey.currentContext;
    if (context == null || !context.mounted) return true;
    return showJamPermissionSheet(
      context,
      JamPermissionRationale.forKind(kind),
    );
  }

  /// A shared `localjam://join?...` link should land in the room, not in a
  /// paste field. Registered at the OS level in Info.plist and the Android
  /// manifest; before the overhaul neither existed and links were inert.
  Future<void> _listenForLinks() async {
    try {
      _linkSub = _appLinks.uriLinkStream.listen(_handleLink);
      final initial = await _appLinks.getInitialLink();
      if (initial == null) return;
      // A cold start's link arrives before the shell exists — and the shell
      // owns both the navigator the confirm dialog needs and the subscriber
      // that turns notices into SnackBars. Handled a frame later, it lands.
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => unawaited(_handleLink(initial)),
      );
    } catch (_) {
      // No deep-link support on this platform; QR and nearby still work.
    }
  }

  /// A link is the one entry point the user did not aim: it can arrive from a
  /// chat, a web page, a QR sticker on a wall. So it is the one that has to
  /// be checked and confirmed before it opens a socket.
  Future<void> _handleLink(Uri uri) async {
    if (uri.scheme != 'localjam') return;
    // Never yank someone out of a running jam because a link arrived. An
    // `ended` session is different: join() clears it and proceeds.
    if (_session.phase == JamSessionPhase.live ||
        _session.phase == JamSessionPhase.starting) {
      return;
    }
    final parsed = parseJoinUri('$uri');
    if (parsed == null) {
      _session.notify('That link is not a jam invite.');
      return;
    }
    // LocalJam is a LAN product; a link pointing anywhere routable is not a
    // jam, it is this app being aimed at someone else's server.
    if (!joinUriIsLocalOnly(parsed)) {
      _session.notify(
        'That link points outside your network. A jam only runs between '
        'devices on it.',
      );
      return;
    }
    final context = _router.routerDelegate.navigatorKey.currentContext;
    if (context == null || !context.mounted) return;
    final go = await confirmLinkJoin(context, roomName: joinUriName(parsed));
    if (!go) return;
    // Permission prompts before the join, not through its spinner.
    await _session.prepareForSession();
    final joined = await _session.join(parsed, roomName: joinUriName(parsed));
    if (joined) {
      _router.push('/room');
    } else {
      // Deep links showed nothing at all on failure before this.
      _session.notify(_session.error ?? 'Could not join that room.');
    }
  }

  @override
  void dispose() {
    jamRationalePresenter = null;
    JamMediaSessionController.placeholderArtworkProvider = null;
    unawaited(_linkSub?.cancel());
    _session.dispose();
    _settings.dispose();
    _onboarding.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return JamSettings(
      settings: _settings,
      child: JamOnboarding(
        prefs: _onboarding,
        child: JamSession(
          controller: _session,
          child: ListenableBuilder(
            listenable: _settings,
            builder: (context, _) => MaterialApp.router(
              title: 'LocalJam',
              debugShowCheckedModeBanner: false,
              theme: jamLightTheme(),
              darkTheme: jamDarkTheme(),
              themeMode: _settings.themeMode,
              routerConfig: _router,
              // Screens without an app bar (the room, the sheets over it,
              // anything full-bleed) have nothing to publish an overlay
              // style, so the shell publishes the theme's. Screens that are
              // dark whatever the theme says — the scanner, onboarding —
              // annotate over this one.
              builder: (context, child) =>
                  AnnotatedRegion<SystemUiOverlayStyle>(
                    value: jamOverlayStyle(Theme.of(context).brightness),
                    child: child ?? const SizedBox.shrink(),
                  ),
            ),
          ),
        ),
      ),
    );
  }
}
