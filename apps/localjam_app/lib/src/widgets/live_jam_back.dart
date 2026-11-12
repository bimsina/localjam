/// Back at the bottom of the app while a jam is live puts LocalJam in the
/// background rather than closing it — what every music app does.
///
/// With nothing left to pop, a back on Android used to finish the activity:
/// the Flutter engine went with it, and with the engine the host's server and
/// the audio, so a host who closed the room to Home and pressed back once too
/// often ended the jam for everybody without a word — guests saw
/// "Reconnecting…" and then "Room closed". The task now goes to the back
/// instead (`moveTaskToBack`, through a small channel in `MainActivity.kt`),
/// exactly as Home would, and the jam keeps playing under its notification.
///
/// It is a [PopScope], not a key listener: with `targetSdk` 36 Android 16
/// delivers back only through `OnBackInvokedCallback` (predictive back), and
/// the engine registers one only while the framework says it can handle a
/// pop — which is what a [PopScope] that refuses to pop tells it. Gesture and
/// 3-button navigation reach it the same way. With no jam live, back exits as
/// it always has. iOS has no back to the home screen, and desktop and the web
/// none that closes the app, so they are left alone.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// The Android task, from Dart.
abstract final class JamAppTask {
  static const MethodChannel channel = MethodChannel('localjam/task');

  /// Whether a back at the root should background the app rather than let
  /// the platform close it: Android only (see the library comment).
  static bool get backgroundsOnBack =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Sends the app's task to the back, as Home would. True when it went.
  ///
  /// Never throws: a missing channel (tests, an old build) leaves the app in
  /// front, which costs the user one press of Home — never the jam.
  static Future<bool> moveToBack() async {
    try {
      return await channel.invokeMethod<bool>('moveToBack') ?? false;
    } catch (e) {
      debugPrint('localjam: could not move the task to the back: $e');
      return false;
    }
  }
}

/// Wraps the bottom page of the app (the shell under Home, Past Jams and
/// Settings): while [live], a back that reaches it backgrounds the app.
///
/// Only the bottom page: a back over anything still pops that — a sheet, a
/// dialog, the room, Settings — so nobody is trapped anywhere a back should
/// take them out of.
class JamLiveJamBackScope extends StatelessWidget {
  const JamLiveJamBackScope({
    super.key,
    required this.live,
    required this.child,
  });

  /// Whether this device is in a jam that would die with the activity.
  final bool live;

  final Widget child;

  @override
  Widget build(BuildContext context) => PopScope<Object?>(
    canPop: !(live && JamAppTask.backgroundsOnBack),
    onPopInvokedWithResult: (didPop, _) {
      if (didPop) return;
      unawaited(JamAppTask.moveToBack());
    },
    child: child,
  );
}
