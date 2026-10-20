/// The app root: owns the session and the settings, wires the router, and
/// listens for `localjam://` deep links.
///
/// The session controller lives here rather than in a route, which is what
/// lets a jam survive navigation and lets the docked room bar exist at all.
library;

import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:localjam_client/localjam_client.dart';

import 'design/theme.dart';
import 'design/tokens.dart';
import 'design/typography.dart';
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

/// What the app root says out loud.
abstract final class AppStrings {
  static const String notAnInvite = JamJoinLinkStrings.invalid;
  static const String notLocal =
      'That link points outside your Wi‑Fi. A jam only works between '
      'devices on the same network.';
  static const String couldNotJoin = 'Couldn’t join that jam.';
}

/// Carries the in-app appearance (Settings → Appearance) to the system's
/// own surfaces (spec §10.8).
///
/// Flutter paints every pixel of the app itself, but the keyboard, the
/// share sheet, the document and photo pickers and permission prompts are
/// UIKit's, and UIKit draws them from the *window's* trait collection — so
/// with the app forced Light on a phone in Dark mode, every keyboard came
/// up dark. On iOS this sets the window's `overrideUserInterfaceStyle`
/// through a tiny channel in the Runner (`AppDelegate.swift`). Android's
/// system pickers follow the system theme and an app cannot change that;
/// nothing is sent there.
abstract final class JamSystemAppearance {
  static const MethodChannel channel = MethodChannel('localjam/appearance');

  /// Sends [mode] to the platform. Never throws: an older Runner without
  /// the channel just keeps the system's style.
  static Future<void> apply(ThemeMode mode) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return;
    try {
      await channel.invokeMethod<void>('setStyle', mode.name);
    } catch (_) {
      // Missing channel (tests, an old build): nothing to do.
    }
  }
}

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

  ThemeMode? _sentAppearance;

  /// Keeps the system's surfaces on the app's appearance.
  void _syncAppearance() {
    final mode = _settings.themeMode;
    if (mode == _sentAppearance) return;
    _sentAppearance = mode;
    unawaited(JamSystemAppearance.apply(mode));
  }

  @override
  void initState() {
    super.initState();
    _settings.addListener(_syncAppearance);
    unawaited(_settings.load().whenComplete(_syncAppearance));
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
    // screen. A pre-rendered placeholder stands in.
    JamMediaSessionController.placeholderArtworkProvider = _brandArtwork;
  }

  /// The 1024 px placeholder for the lock-screen card.
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
      _session.notify(AppStrings.notAnInvite, tone: JamNoticeTone.warning);
      return;
    }
    // LocalJam is a LAN product; a link pointing anywhere routable is not a
    // jam, it is this app being aimed at someone else's server.
    if (!joinUriIsLocalOnly(parsed)) {
      _session.notify(AppStrings.notLocal, tone: JamNoticeTone.warning);
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
      _session.notify(
        _session.error ?? AppStrings.couldNotJoin,
        tone: JamNoticeTone.error,
      );
    }
  }

  @override
  void dispose() {
    jamRationalePresenter = null;
    JamMediaSessionController.placeholderArtworkProvider = null;
    _settings.removeListener(_syncAppearance);
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
              // Increase Contrast: firmer secondary text and hairlines, a
              // deeper tint (spec §8, AA everywhere).
              highContrastTheme: jamLightTheme(highContrast: true),
              highContrastDarkTheme: jamDarkTheme(highContrast: true),
              themeMode: _settings.themeMode,
              routerConfig: _router,
              // Screens without an app bar (the room, the sheets over it,
              // anything full-bleed) have nothing to publish an overlay
              // style, so the shell publishes the theme's. Screens that are
              // dark whatever the theme says — the scanner, onboarding —
              // annotate over this one.
              //
              // The root text style sits here too: anything drawn outside a
              // page's own `Material` (pull-down menus, overlays, sheets
              // built on Cupertino routes) would otherwise fall back to the
              // framework's debug style — red text, yellow underline.
              builder: (context, child) =>
                  AnnotatedRegion<SystemUiOverlayStyle>(
                    value: jamOverlayStyle(Theme.of(context).brightness),
                    child: DefaultTextStyle(
                      style: context.jamBody.copyWith(
                        color: context.jamColors.label,
                      ),
                      child: child ?? const SizedBox.shrink(),
                    ),
                  ),
            ),
          ),
        ),
      ),
    );
  }
}
