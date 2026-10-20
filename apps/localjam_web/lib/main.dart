/// The LocalJam browser listener page (docs/design/WEB_GUEST.md,
/// PROTOCOL.md §1.1): served by the host itself at `/join`, joined as a
/// `clientKind: "web"` guest, no install and no internet.
///
/// The page's own URL is the invitation: its fragment (`#v=1&token=…`)
/// carries the token and its origin is the host. It is read once, here,
/// before anything else runs, and the address bar is then left exactly as
/// it was opened: no URL strategy at all. Flutter's default hash strategy
/// would read the fragment as a route; the path strategy keeps the
/// fragment out of routing but rewrites the address on startup — under
/// `--base-href /web/` to `/web/join`, without the fragment — so a reload
/// would land on a 404 with the invitation gone. The page has one screen
/// and no routes, so it needs no browser-history integration.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:localjam_client/localjam_client.dart';
import 'package:web/web.dart' as web;

import 'src/engine_room.dart';
import 'src/join_target.dart';
import 'src/listener_app.dart';

void main() {
  final target = JoinTarget.fromPageUrl(Uri.base);
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
