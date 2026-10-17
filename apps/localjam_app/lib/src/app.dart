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
import 'state/link_inbox.dart';
import 'state/onboarding_prefs.dart';
import 'state/session_controller.dart';
import 'util/network.dart';
import 'util/permissions.dart';
import 'widgets/artwork.dart';
import 'widgets/join_link_dialog.dart';
import 'widgets/permission_sheet.dart';
import 'widgets/session_gate.dart';

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

  /// Dedupes the cold-start double delivery, and parks a link that arrives
  /// before the intro is done, while another link is in hand, or while a
  /// session is starting — see [JamLinkInbox]. Parked, not dropped: it is
  /// handed over once the way is clear.
  late final JamLinkInbox _links = JamLinkInbox(
    onLink: _handleLinkSoon,
    ready: () => _onboarding.loaded && _onboarding.seen && !_session.isBusy,
  );

  @override
  void initState() {
    super.initState();
    unawaited(_settings.load());
    // The gate holds every route until this lands, so nobody sees the intro
    // flash past on their second launch.
    unawaited(_onboarding.load());
    _onboarding.addListener(_links.readyChanged);
    // A start finishing (or failing) clears the way for a parked link.
    _session.addListener(_links.readyChanged);
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
      _linkSub = _appLinks.uriLinkStream.listen(_links.receive);
      // app_links 6 also replays the launch link on the stream, so on a cold
      // start the same link arrives twice — two confirm dialogs, two joins.
      // Both deliveries go through the inbox, which keeps the first.
      final initial = await _appLinks.getInitialLink();
      if (initial != null) _links.receive(initial);
    } catch (_) {
      // No deep-link support on this platform; QR and nearby still work.
    }
  }

  /// A cold start's link arrives before the shell exists — and the shell
  /// owns both the navigator the confirm dialog needs and the subscriber
  /// that turns notices into SnackBars. Handled a frame later, it lands.
  ///
  /// The inbox holds every other link until the returned future completes:
  /// one link at a time, and never on top of a start already in flight.
  Future<void> _handleLinkSoon(Uri uri) {
    final done = Completer<void>();
    WidgetsBinding.instance
      ..addPostFrameCallback((_) => done.complete(_joinFromLink(uri)))
      ..ensureVisualUpdate();
    return done.future;
  }

  /// A link is the one entry point the user did not aim: it can arrive from a
  /// chat, a web page, a QR sticker on a wall. So it is the one that has to
  /// be checked and confirmed before it opens a socket.
  Future<void> _joinFromLink(Uri uri) async {
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
    // Never yank someone out of a running jam because a link arrived — but
    // never swallow the link either. A live jam gets the "leave it first?"
    // question, which is the confirmation; otherwise the usual one.
    if (_session.isLive) {
      if (!await jamReadyForNewSession(context, _session)) return;
    } else {
      final go = await confirmLinkJoin(context, roomName: joinUriName(parsed));
      if (!go) return;
    }
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
    _onboarding.removeListener(_links.readyChanged);
    _session.removeListener(_links.readyChanged);
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
