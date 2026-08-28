/// Best-effort OS keep-alive for active jam sessions.
///
/// Backgrounded apps get frozen (timers, sockets, audio) unless the platform
/// is told a session is running:
///
/// * **iOS**: the `audio` `UIBackgroundModes` entry in the app's Info.plist
///   keeps the process running while audio plays — nothing to do at runtime.
/// * **Android**: the embedding app must run a foreground service (type
///   `mediaPlayback`) and hold wake/Wi-Fi locks. The engines ask for that via
///   the `localjam/keepalive` [MethodChannel]; the LocalJam app implements it
///   with a tiny Kotlin service (see `KeepAliveService.kt`).
/// * everywhere else (desktop, tests, CLI embeddings): a no-op.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Asks the embedding app to hold (or release) its OS-level session
/// keep-alive: on Android a `mediaPlayback` foreground service plus
/// wake/Wi-Fi locks behind the `localjam/keepalive` method channel.
///
/// Every call is best effort and never throws: it is a no-op when the
/// platform is not Android or when the embedding app has not wired the
/// channel (tests, CLI hosts, apps that opt out).
class JamKeepAlive {
  JamKeepAlive._();

  /// The channel the embedding app implements: `acquire` starts the
  /// foreground service and takes the locks, `release` undoes both.
  static const MethodChannel channel = MethodChannel('localjam/keepalive');

  /// Platform gate, overridable in tests (flutter_test defaults
  /// [defaultTargetPlatform] to Android, which is also handy: the engine
  /// tests can mock [channel] and observe the acquire/release calls).
  @visibleForTesting
  static bool Function() isAndroid = () =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Asks the app to keep the process alive (session started).
  static Future<void> acquire() => _invoke('acquire');

  /// Releases the keep-alive (session closed).
  static Future<void> release() => _invoke('release');

  static Future<void> _invoke(String method) async {
    if (!isAndroid()) return;
    try {
      await channel.invokeMethod<void>(method);
    } on MissingPluginException {
      // The embedding app does not implement the channel: nothing to hold.
    } on PlatformException {
      // Best effort: never let keep-alive break session startup or teardown.
    }
  }
}
