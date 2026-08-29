/// Runtime-permission helpers for the LAN and the music library.
library;

import 'dart:io';

import 'package:permission_handler/permission_handler.dart';

/// Requests Android 17's `ACCESS_LOCAL_NETWORK` before hosting or joining.
///
/// Android 17 (API 37) blocks ALL local-network traffic — incoming
/// included — without it, and dart:io will never request it. On older
/// Android releases (and every other platform) this resolves immediately.
/// Best-effort: a denial is not fatal here — the socket layer will surface
/// the failure, and callers shouldn't crash on permission plumbing.
Future<void> ensureLocalNetworkPermission() async {
  if (!Platform.isAndroid) return;
  try {
    await Permission.accessLocalNetwork.request();
  } catch (_) {
    // Older permission_handler platform implementations may not know the
    // permission: nothing to request yet.
  }
}

/// Requests audio-library access (Android `READ_MEDIA_AUDIO` on 13+,
/// `READ_EXTERNAL_STORAGE` below). Returns whether it is granted.
Future<bool> ensureAudioLibraryPermission() async {
  if (!Platform.isAndroid) return false;
  try {
    return (await Permission.audio.request()).isGranted;
  } catch (_) {
    return false;
  }
}
