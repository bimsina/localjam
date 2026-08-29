/// The app root: owns the session and the settings, wires the router, and
/// listens for `localjam://` deep links.
///
/// The session controller lives here rather than in a route, which is what
/// lets a jam survive navigation and lets the docked room bar exist at all.
library;

import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'design/theme.dart';
import 'router.dart';
import 'state/app_settings.dart';
import 'state/session_controller.dart';

class LocalJamApp extends StatefulWidget {
  const LocalJamApp({super.key});

  @override
  State<LocalJamApp> createState() => _LocalJamAppState();
}

class _LocalJamAppState extends State<LocalJamApp> {
  final JamSessionController _session = JamSessionController();
  final JamAppSettings _settings = JamAppSettings();
  late final GoRouter _router = buildRouter(_session);
  final AppLinks _appLinks = AppLinks();
  StreamSubscription<Uri>? _linkSub;

  @override
  void initState() {
    super.initState();
    unawaited(_settings.load());
    unawaited(_listenForLinks());
  }

  /// A shared `localjam://join?...` link should land in the room, not in a
  /// paste field. Registered at the OS level in Info.plist and the Android
  /// manifest; before the overhaul neither existed and links were inert.
  Future<void> _listenForLinks() async {
    try {
      _linkSub = _appLinks.uriLinkStream.listen(_handleLink);
      final initial = await _appLinks.getInitialLink();
      if (initial != null) await _handleLink(initial);
    } catch (_) {
      // No deep-link support on this platform; QR and nearby still work.
    }
  }

  Future<void> _handleLink(Uri uri) async {
    if (uri.scheme != 'localjam') return;
    // Never yank someone out of a running jam because a link arrived.
    if (_session.phase != JamSessionPhase.idle) return;
    final joined = await _session.join(uri);
    if (joined) _router.push('/room');
  }

  @override
  void dispose() {
    unawaited(_linkSub?.cancel());
    _session.dispose();
    _settings.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return JamSettings(
      settings: _settings,
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
          ),
        ),
      ),
    );
  }
}
