/// The LocalJam browser listener page (docs/design/WEB_GUEST.md,
/// PROTOCOL.md §1.1): served by the host itself at `/join`, joined as a
/// `clientKind: "web"` guest, no install and no internet.
///
/// The page's own URL is the invitation: its fragment (`#v=1&token=…`)
/// carries the token and its origin is the host. It is read once, here,
/// before anything else runs ([InviteStartup]): kept in this tab's
/// `sessionStorage` and dropped from the address with
/// `history.replaceState` (same path, no fragment), so the token does not
/// sit in the browser's history; a reload reads it back from the tab. A
/// tab that cannot store it keeps the address as it was opened. No URL
/// strategy at all: Flutter's default hash strategy would read the
/// fragment as a route; the path strategy rewrites the address on startup
/// — under `--base-href /web/` to `/web/join` — so a reload would land on
/// a 404. The page has one screen and no routes, so it needs no
/// browser-history integration.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:localjam_client/localjam_client.dart';
import 'package:web/web.dart' as web;

import 'src/engine_room.dart';
import 'src/join_target.dart';
import 'src/listener_app.dart';

/// This tab's remembered invitation (the join fragment), per origin.
const String _inviteKey = 'localjam.invite';

void main() {
  final startup = InviteStartup.resolve(Uri.base, _readInvite());
  final remember = startup.remember;
  final clean = startup.cleanAddress;
  if (remember != null && clean != null && _storeInvite(remember)) {
    try {
      web.window.history.replaceState(null, '', clean.toString());
    } catch (_) {
      // The address keeps the token; the page works either way.
    }
  }
  final target = JoinTarget.fromPageUrl(startup.page);
  setUrlStrategy(null);
  runApp(
    ListenerApp(
      target: target,
      joiner: joinEngineRoom,
      // The app's identity names ("Neon Walrus"), kept in this browser's
      // storage like the clientId the engine sends in hello (§3.3).
      defaultName: JamIdentity.displayName,
      saveName: (name) async => JamIdentity.setDisplayName(name),
      unlockAudio: unlockAudioInGesture,
      openUrl: (uri) => web.window.location.href = uri.toString(),
    ),
  );
}

/// The remembered invitation, or null (none, or storage unavailable:
/// private modes and disabled site data throw).
String? _readInvite() {
  try {
    return web.window.sessionStorage.getItem(_inviteKey);
  } catch (_) {
    return null;
  }
}

/// Remembers [fragment] for this tab; false when it could not.
bool _storeInvite(String fragment) {
  try {
    web.window.sessionStorage.setItem(_inviteKey, fragment);
    return web.window.sessionStorage.getItem(_inviteKey) == fragment;
  } catch (_) {
    return false;
  }
}
