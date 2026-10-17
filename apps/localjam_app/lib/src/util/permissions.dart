/// Runtime-permission helpers for the LAN, notifications and the music
/// library.
///
/// Every string the user could ever see about a permission lives in
/// [JamPermissionCopy], so the visual overhaul can lift them into a proper
/// rationale sheet without hunting through call sites.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

export 'package:permission_handler/permission_handler.dart'
    show openAppSettings;

/// Why LocalJam asks for each permission, in the user's words.
///
/// Deliberately a plain holder of strings rather than widgets: the redesign
/// owns the presentation, this owns the wording.
abstract final class JamPermissionCopy {
  /// Android 17's `ACCESS_LOCAL_NETWORK`.
  static const String localNetworkTitle = 'Let LocalJam use this network';
  static const String localNetworkDetail =
      'A jam runs entirely between the phones on your Wi-Fi or hotspot. '
      'Without local network access nothing can reach anything.';

  /// The same permission on iOS and macOS, where there is no API to request
  /// it: the OS fires its own alert the first time the app touches Bonjour
  /// or a LAN socket. All this sheet can do is make that alert expected —
  /// which is the difference between tapping Allow and tapping the greyed
  /// half of a dialog that came out of nowhere.
  static const String localNetworkAppleDetail =
      'A jam runs entirely between the phones on your Wi-Fi or hotspot. '
      'Next, the system will ask you to allow it — LocalJam cannot reach '
      'anyone without that.';

  /// Android 13+ `POST_NOTIFICATIONS`.
  static const String notificationsTitle = 'Show the playback card';
  static const String notificationsDetail =
      'The lock-screen card is how you pause and skip without unlocking. '
      'Music still plays if you say no.';

  /// Android `READ_MEDIA_AUDIO` / `READ_EXTERNAL_STORAGE`.
  static const String audioLibraryTitle = 'Reach your music';
  static const String audioLibraryDetail =
      'LocalJam reads the songs already on this phone so you can queue them. '
      'Nothing leaves your network.';

  /// Shown when the OS will no longer prompt and only Settings can undo it.
  static const String audioLibraryDenied =
      'LocalJam cannot see your music. Turn on music access in Settings, or '
      'add files with the file picker instead.';

  /// Camera, for the QR scanner.
  static const String cameraDenied =
      'LocalJam cannot open the camera. Turn on camera access in Settings, or '
      'join with a link instead.';

  /// Action label for anything that hands the user to the OS.
  static const String openSettings = 'Open settings';
}

/// The permissions LocalJam can explain before it asks the OS for them.
///
/// Named rather than passed as a [Permission] so the presenter (which lives
/// up in the widget layer) can map one to its rationale copy without this
/// file depending on any widget at all.
enum JamPermissionKind {
  /// Android 17's `ACCESS_LOCAL_NETWORK`, before hosting or joining.
  localNetwork,

  /// The local network on iOS and macOS, where nothing is requestable: the
  /// system prompt fires by itself on the first socket or Bonjour use. The
  /// sheet is the whole interaction — there is no OS ask behind it to gate.
  localNetworkApple,

  /// Android 13+'s `POST_NOTIFICATIONS`, before the playback card.
  notifications,

  /// Android's `READ_MEDIA_AUDIO`, before the first library browse.
  audioLibrary,

  /// The camera, before the first QR scan.
  camera,
}

/// Shows the rationale sheet for a permission and answers whether to go on.
///
/// Installed by the app shell (`app.dart`). Null in tests and in any
/// embedding without a navigator, where every ask simply proceeds
/// unexplained rather than silently failing.
Future<bool> Function(JamPermissionKind kind)? jamRationalePresenter;

Permission? _permissionFor(JamPermissionKind kind) => switch (kind) {
  JamPermissionKind.localNetwork => Permission.accessLocalNetwork,
  // Nothing to ask for; the sheet is all there is.
  JamPermissionKind.localNetworkApple => null,
  JamPermissionKind.notifications => Permission.notification,
  JamPermissionKind.audioLibrary => Permission.audio,
  JamPermissionKind.camera => Permission.camera,
};

String _rationaleKey(JamPermissionKind kind) =>
    'permission_rationale_${kind.name}';

/// Explains [kind] once, before the OS is asked, and answers whether the
/// caller should go ahead and ask.
///
/// The rules the spec sets, in order:
/// * **Before the prompt, never after a denial.** A sheet that appears once
///   the OS has stopped prompting is a dead end wearing a Continue button, so
///   anything already answered — granted, permanently denied, or soft-denied
///   once (which is what `shouldShowRequestRationale` reports on Android) —
///   goes straight through.
/// * **Once per permission**, remembered in shared preferences (and in this
///   process, for a store that will not answer), so the second library browse
///   of the day opens the picker rather than the pitch.
/// * A kind with no requestable permission behind it
///   ([JamPermissionKind.localNetworkApple]) skips the status check and is
///   shown on its own terms: the sheet is the whole interaction.
///
/// Returns false only when the user actually said "Not now": that is the one
/// answer that must stop the OS prompt from ever appearing.
Future<bool> jamExplainPermission(JamPermissionKind kind) async {
  final presenter = jamRationalePresenter;
  if (presenter == null) return true;
  if (_explained.contains(kind)) return true;
  final permission = _permissionFor(kind);
  try {
    if (permission != null) {
      final status = await permission.status;
      // `isDenied` on Android means "not granted", which covers both never
      // asked and asked-and-refused; everything else is settled already.
      if (!status.isDenied) return true;
      if (Platform.isAndroid && await permission.shouldShowRequestRationale) {
        return true;
      }
    }
    final prefs = await SharedPreferences.getInstance();
    final key = _rationaleKey(kind);
    if (prefs.getBool(key) ?? false) {
      _explained.add(kind);
      return true;
    }
    await prefs.setBool(key, true);
  } catch (e) {
    // A platform that cannot report a status or persist a flag is a platform
    // where the prompt is harmless; never block the ask on plumbing.
    debugPrint('localjam: could not check rationale for ${kind.name}: $e');
    // For a kind with no OS ask behind it (see [_permissionFor]) the sheet
    // *is* the interaction, so a prefs failure must not turn "once" into
    // "every time" — the in-process latch stands in for the flag.
    if (permission == null) _explained.add(kind);
    return true;
  }
  _explained.add(kind);
  return presenter(kind);
}

/// Kinds already explained in this process, so a prefs failure can never
/// turn a once-only sheet into one that appears before every jam.
final Set<JamPermissionKind> _explained = <JamPermissionKind>{};

/// Forgets the in-process "already explained" latch (tests).
@visibleForTesting
void resetExplainedPermissionsForTesting() => _explained.clear();

/// Prepares local-network access before hosting or joining.
///
/// Two platforms, two different jobs. On Android 17 (API 37) there is a real
/// permission to request — it blocks ALL local-network traffic, incoming
/// included, and dart:io will never ask for it. On iOS and macOS there is
/// nothing to request and the system asks by itself, so the only thing to do
/// is get in front of it (see below). Everywhere else this resolves
/// immediately.
///
/// Best-effort: a denial is not fatal here — the socket layer will surface
/// the failure, and callers shouldn't crash on permission plumbing.
Future<void> ensureLocalNetworkPermission() async {
  // iOS and macOS: there is no permission to request. The system raises its
  // own local-network alert the first time a socket or a Bonjour browse
  // touches the LAN, and `permission_handler` has nothing to bring that
  // forward — which is why this function used to return here having done
  // nothing at all, and why the alert landed on iOS users cold, mid-spinner,
  // with no idea what LocalJam wanted with their network.
  //
  // So the rationale still runs, once, right before the first host or join:
  // it explains what is about to be asked and that the system is the one
  // asking. Its answer is not a gate — there is nothing behind it to gate.
  if (Platform.isIOS || Platform.isMacOS) {
    await jamExplainPermission(JamPermissionKind.localNetworkApple);
    return;
  }
  if (!Platform.isAndroid) return;
  if (!await jamExplainPermission(JamPermissionKind.localNetwork)) return;
  try {
    await Permission.accessLocalNetwork.request();
  } catch (e) {
    // Older permission_handler platform implementations may not know the
    // permission: nothing to request yet.
    debugPrint('localjam: local-network permission request failed: $e');
  }
}

/// Requests Android 13+'s `POST_NOTIFICATIONS`, which the media card (and,
/// on a host, the foreground service that keeps the server alive while
/// backgrounded) needs in order to appear at all.
///
/// Non-fatal by design: playback runs either way, so a denial costs the
/// lock-screen controls and nothing else. Returns whether it is granted.
Future<bool> ensureNotificationPermission() async {
  if (!Platform.isAndroid) return true;
  if (!await jamExplainPermission(JamPermissionKind.notifications)) {
    return false;
  }
  try {
    final status = await Permission.notification.request();
    return status.isGranted;
  } catch (e) {
    debugPrint('localjam: notification permission request failed: $e');
    return false;
  }
}

/// The outcome of asking for the music library, which the UI has to tell
/// apart: a plain denial can be asked again, a permanent one only Settings
/// can undo.
enum JamPermissionOutcome {
  granted,
  denied,
  permanentlyDenied,
  unsupported,

  /// The rationale sheet was answered with "Not now", so the OS was never
  /// asked. Distinct from [denied] because there is nothing to explain and
  /// nothing to fix in Settings — the user has just said no to us.
  dismissed,
}

/// Requests audio-library access (Android `READ_MEDIA_AUDIO` on 13+,
/// `READ_EXTERNAL_STORAGE` below).
Future<JamPermissionOutcome> requestAudioLibraryPermission() async {
  if (!Platform.isAndroid) return JamPermissionOutcome.unsupported;
  if (!await jamExplainPermission(JamPermissionKind.audioLibrary)) {
    return JamPermissionOutcome.dismissed;
  }
  try {
    final status = await Permission.audio.request();
    if (status.isGranted || status.isLimited) {
      return JamPermissionOutcome.granted;
    }
    if (status.isPermanentlyDenied || status.isRestricted) {
      return JamPermissionOutcome.permanentlyDenied;
    }
    return JamPermissionOutcome.denied;
  } catch (e) {
    debugPrint('localjam: audio permission request failed: $e');
    return JamPermissionOutcome.denied;
  }
}

/// Whether audio-library access is granted, requesting it if needed.
Future<bool> ensureAudioLibraryPermission() async =>
    await requestAudioLibraryPermission() == JamPermissionOutcome.granted;

/// Requests the camera before the scanner is built.
///
/// Asked here rather than left to `mobile_scanner`'s own first-frame request
/// so the rationale can come first, and — more importantly — so a denial is a
/// *state this screen holds* rather than an error widget the scanner hands
/// back from inside its own stack.
Future<JamPermissionOutcome> requestCameraPermission() async {
  if (!Platform.isAndroid && !Platform.isIOS && !Platform.isMacOS) {
    return JamPermissionOutcome.unsupported;
  }
  if (!await jamExplainPermission(JamPermissionKind.camera)) {
    return JamPermissionOutcome.dismissed;
  }
  try {
    final status = await Permission.camera.request();
    if (status.isGranted || status.isLimited) {
      return JamPermissionOutcome.granted;
    }
    if (status.isPermanentlyDenied || status.isRestricted) {
      return JamPermissionOutcome.permanentlyDenied;
    }
    return JamPermissionOutcome.denied;
  } catch (e) {
    // No permission plumbing on this platform: let the scanner try, and let
    // its own error path speak if it cannot.
    debugPrint('localjam: camera permission request failed: $e');
    return JamPermissionOutcome.granted;
  }
}
