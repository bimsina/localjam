/// Best-effort OS keep-alive for active jam sessions.
///
/// Backgrounded apps get frozen (timers, sockets, audio) unless the platform
/// is told a session is running:
///
/// * **iOS**: the `audio` `UIBackgroundModes` entry in the app's Info.plist
///   keeps the process running while audio plays — nothing to do at runtime.
///   (While PAUSED and backgrounded the OS can still suspend the app after a
///   few minutes; there is no supported way around that — hosts should warn,
///   guests auto-heal. See JamGuestEngine.joinUri.)
/// * **Android**: a foreground service (type `mediaPlayback`) holding
///   wake/Wi-Fi locks, implemented by the `localjam_audio` plugin
///   (`JamSessionService`) behind the `localjam/keepalive` [MethodChannel] —
///   its notification doubles as the OS media card (see
///   `JamMediaSessionManager`). Nothing app-side to wire.
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
///
/// Holding it can also simply be refused. Android 12+ forbids starting a
/// foreground service from the background, and 14+ adds foreground-service
/// type/permission checks on top; either way the OS says no and the jam runs
/// without a keep-alive — fine while the app is on screen, fatal to a
/// backgrounded host's server. [acquire] therefore answers whether the
/// keep-alive is actually held, and [active] tracks it afterwards: the
/// refusal can also arrive later, once the service tries to go foreground.
class JamKeepAlive {
  JamKeepAlive._();

  /// The channel the embedding app implements: `acquire` starts the
  /// foreground service and takes the locks (answering a bool), `release`
  /// undoes both. The platform calls back `keepAliveLost` when a started
  /// keep-alive turns out not to hold.
  static const MethodChannel channel = MethodChannel('localjam/keepalive');

  /// Whether the OS-level keep-alive is currently believed to be held.
  ///
  /// False on platforms that have none (iOS, desktop, tests) — "no keep-alive
  /// was needed" and "the OS refused one" are the same thing to a caller, so
  /// UI should read this together with the [acquire] result it got.
  static final ValueNotifier<bool> active = ValueNotifier<bool>(false);

  /// Platform gate, overridable in tests (flutter_test defaults
  /// [defaultTargetPlatform] to Android, which is also handy: the engine
  /// tests can mock [channel] and observe the acquire/release calls).
  @visibleForTesting
  static bool Function() isAndroid = () =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static bool _listening = false;

  /// Asks the app to keep the process alive (session started). Returns
  /// whether the platform accepted — false on every platform without a
  /// keep-alive, and on an Android that refused one.
  static Future<bool> acquire() async {
    _listenForLoss();
    final held = await _invoke('acquire') ?? false;
    active.value = held;
    return held;
  }

  /// Releases the keep-alive (session closed).
  static Future<void> release() async {
    await _invoke('release');
    active.value = false;
  }

  /// Subscribes to the platform's `keepAliveLost` callback: the service can
  /// be refused foreground status *after* `acquire` returned true, and a host
  /// that thinks it is protected when it is not is the worst of both.
  static void _listenForLoss() {
    if (_listening) return;
    _listening = true;
    channel.setMethodCallHandler((call) async {
      if (call.method == 'keepAliveLost') active.value = false;
      return null;
    });
  }

  static Future<bool?> _invoke(String method) async {
    if (!isAndroid()) return null;
    try {
      return await channel.invokeMethod<bool>(method);
    } on MissingPluginException {
      // The embedding app does not implement the channel: nothing to hold.
      return null;
    } on PlatformException {
      // Best effort: never let keep-alive break session startup or teardown.
      return null;
    }
  }
}
