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
  // The primers' titles and bodies live with the sheet that shows them
  // (`JamPermissionSheetStrings`); what is left here is what the app says
  // after the OS has answered.

  /// Shown when the OS will no longer prompt and only Settings can undo it.
  static const String audioLibraryDenied =
      'LocalJam can’t see your music. Turn on music access in Settings, or '
      'add songs from Files instead.';

  /// Camera, for the QR scanner.
  static const String cameraDenied =
      'LocalJam can’t use the camera. Turn it on in Settings, or join with a '
      'link instead.';

  /// Action label for anything that hands the user to the OS.
  static const String openSettings = 'Open Settings';
}

/// The permissions LocalJam can explain before it asks the OS for them.
///
/// Named rather than passed as a [Permission] so the presenter (which lives
/// up in the widget layer) can map one to its rationale copy without this
/// file depending on any widget at all.
enum JamPermissionKind {
  /// Android 17's `ACCESS_LOCAL_NETWORK`, before hosting or joining. Unused
  /// while [androidRequestsLocalNetwork] is off.
  localNetwork,

  /// The local network on iOS and macOS, where nothing is requestable: the
  /// system prompt fires by itself on the first socket or Bonjour use. The
  /// sheet is the whole interaction — there is no OS ask behind it to gate.
  localNetworkApple,

  /// Android 13+'s `POST_NOTIFICATIONS`, before the playback card.
  notifications,

  /// Android's `READ_MEDIA_AUDIO`, before the first library browse.
  audioLibrary,

  /// The same `READ_MEDIA_AUDIO`, asked by turning on "Share my music
  /// library". A kind of its own because the promise is different: the
  /// picker's "nothing leaves this phone" is untrue of a library whose titles
  /// the jam is about to see.
  audioLibraryShare,

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
  JamPermissionKind.audioLibrary ||
  JamPermissionKind.audioLibraryShare => Permission.audio,
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
///
/// Concurrent asks for one kind share a single answer. Two at once used to
/// race: the first set the "explained" flag and showed the sheet, the second
/// read the flag and went straight to the OS prompt — so "Not now" on the
/// sheet was answered by the system dialog anyway.
Future<bool> jamExplainPermission(JamPermissionKind kind) {
  final pending = _explaining[kind];
  if (pending != null) return pending;
  final answer = _explain(kind);
  _explaining[kind] = answer;
  return answer.whenComplete(() => _explaining.remove(kind));
}

/// Rationales on screen (or being decided), so a second ask joins the first.
final Map<JamPermissionKind, Future<bool>> _explaining = {};

Future<bool> _explain(JamPermissionKind kind) async {
  final presenter = jamRationalePresenter;
  if (presenter == null) return true;
  // "Not now" holds for the rest of this run: the session code asks again as
  // a backstop right after the shell's ask, and that second ask must not go
  // to the OS behind the user's back.
  if (_declined.contains(kind)) return false;
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
  final proceed = await presenter(kind);
  if (!proceed) {
    // Not explained after all: the next launch shows the sheet again rather
    // than taking the stored flag as leave to prompt cold.
    _explained.remove(kind);
    _declined.add(kind);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_rationaleKey(kind), false);
    } catch (e) {
      debugPrint('localjam: could not forget rationale for ${kind.name}: $e');
    }
  }
  return proceed;
}

/// Kinds the user answered "Not now" for in this process.
final Set<JamPermissionKind> _declined = <JamPermissionKind>{};

/// Kinds already explained in this process, so a prefs failure can never
/// turn a once-only sheet into one that appears before every jam.
final Set<JamPermissionKind> _explained = <JamPermissionKind>{};

/// Forgets the in-process "already explained" latch (tests).
@visibleForTesting
void resetExplainedPermissionsForTesting() {
  _explained.clear();
  _declined.clear();
}

/// Whether Android asks for `ACCESS_LOCAL_NETWORK` before hosting or joining.
///
/// Off while the app targets API 36: Google's guidance is that apps targeting
/// 36 or lower must neither declare nor request it (INTERNET still covers the
/// LAN for them), and the rationale sheet would explain a permission that
/// does nothing for such an app on any Android release. Turn it on in the same change that moves
/// `targetSdk` to 37 and declares the permission in the manifest — see the
/// `targetSdk` comment in `android/app/build.gradle.kts`.
const bool androidRequestsLocalNetwork = false;

/// Prepares local-network access before hosting or joining.
///
/// Two platforms, two different jobs. On Android 17 (API 37) there is a real
/// permission to request — it blocks ALL local-network traffic, incoming
/// included, and dart:io will never ask for it — though only for apps that
/// target 37 (see [androidRequestsLocalNetwork]). On iOS and macOS there is
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
  if (!Platform.isAndroid || !androidRequestsLocalNetwork) return;
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
///
/// Callers that overlap share one ask: one sheet, one OS prompt, one answer.
Future<bool> ensureNotificationPermission() => _notificationAsk ??=
    _askNotifications().whenComplete(() => _notificationAsk = null);

Future<bool>? _notificationAsk;

Future<bool> _askNotifications() async {
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
///
/// [sharing]: asked by turning on "Share my music library", whose rationale
/// says what the jam will see rather than the picker's "nothing leaves this
/// phone".
Future<JamPermissionOutcome> requestAudioLibraryPermission({
  bool sharing = false,
}) async {
  if (!Platform.isAndroid) return JamPermissionOutcome.unsupported;
  final kind = sharing
      ? JamPermissionKind.audioLibraryShare
      : JamPermissionKind.audioLibrary;
  if (!await jamExplainPermission(kind)) {
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
