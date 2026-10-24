/// Test plumbing: the native channels `localjam_audio` needs (there is no
/// native side under flutter_test), plus a pump helper that builds the real
/// app shell — session controller, settings, and router — so screen tests
/// exercise the actual routing and capability gating rather than a mock.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:localjam_app/src/design/theme.dart';
import 'package:localjam_app/src/router.dart';
import 'package:localjam_app/src/state/app_settings.dart';
import 'package:localjam_app/src/state/session_controller.dart';
import 'package:localjam_app/src/state/web_guest_bundle.dart';
import 'package:localjam_client/localjam_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _audio = MethodChannel('localjam_audio');
const _mediaSession = MethodChannel('localjam_audio/media_session');
const _keepAlive = MethodChannel('localjam/keepalive');
// The route/interruption EventChannel the sync controller subscribes to.
const _audioEvents = MethodChannel('localjam_audio/events');

/// Answers every native call the engines make. `positionUs` returns null
/// ("nothing playing") so the drift loop stays quiet and deterministic.
void mockNativeChannels({int durationUs = 60000000}) {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  var nativeNow = 1000000;
  messenger.setMockMethodCallHandler(_audio, (call) async {
    return switch (call.method) {
      'nowUs' => nativeNow += 100,
      'load' => durationUs,
      'positionUs' => null,
      'outputLatencyUs' => 0,
      _ => null,
    };
  });
  messenger.setMockMethodCallHandler(_mediaSession, (_) async => null);
  messenger.setMockMethodCallHandler(_keepAlive, (_) async => null);
  messenger.setMockMethodCallHandler(_audioEvents, (_) async => null);
  addTearDown(() {
    messenger
      ..setMockMethodCallHandler(_audio, null)
      ..setMockMethodCallHandler(_mediaSession, null)
      ..setMockMethodCallHandler(_keepAlive, null)
      ..setMockMethodCallHandler(_audioEvents, null);
  });
}

/// A controller wired for tests: native channels mocked, prefs seeded with a
/// known identity, and jam-history recording disabled so nothing touches
/// the real application-support directory.
///
/// Its rooms serve no browser player unless [webGuest] brings one: the
/// app's own is whatever this checkout last built into `assets/web/`, and a
/// test must not pass on one laptop and fail on a clean clone.
///
/// [librarySource] stands in for the device music library a host shares
/// (§6.6); without one, sharing lists the real (here: empty) library.
JamSessionController testSession({
  String identity = 'Silky Puffin',
  WebGuestBundle? webGuest,
  JamCatalogSource Function()? librarySource,
}) {
  mockNativeChannels();
  SharedPreferences.setMockInitialValues({'localjam.displayName': identity});
  final previous = JamEngine.historyStoreProvider;
  JamEngine.historyStoreProvider = () async => null;
  final controller = JamSessionController(
    webGuest: webGuest ?? WebGuestBundle.loaded(null),
    librarySource: librarySource,
  );
  addTearDown(() async {
    await controller.leave();
    JamEngine.historyStoreProvider = previous;
  });
  return controller;
}

/// Pumps the real app shell around [session].
Future<GoRouter> pumpApp(
  WidgetTester tester,
  JamSessionController session, {
  ThemeData? theme,
}) async {
  final router = buildRouter(session);
  await tester.pumpWidget(
    JamSettings(
      settings: JamAppSettings(),
      child: JamSession(
        controller: session,
        child: MaterialApp.router(
          theme: theme ?? jamLightTheme(),
          routerConfig: router,
        ),
      ),
    ),
  );
  await tester.pump();
  return router;
}

/// Starts a real host engine.
///
/// [tester.runAsync] is required: `testWidgets` bodies run in a fake-async
/// zone where real socket I/O never completes, and `JamHostEngine.start`
/// binds an actual server.
Future<void> startTestHost(
  WidgetTester tester,
  JamSessionController session,
  String name,
) async {
  await tester.runAsync(
    () => session.startHost(sessionName: name, discoverable: false),
  );
  await tester.pump();
}

/// Tears a live session down through the same real-async escape hatch.
Future<void> leaveTestSession(
  WidgetTester tester,
  JamSessionController session,
) async {
  await tester.runAsync(session.leave);
  await tester.pump();
}
