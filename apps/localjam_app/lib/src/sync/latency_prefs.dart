/// Persistence for the manual sync nudge (PROTOCOL.md §7: "persisted per
/// output device").
///
/// The pinned `localjam_audio` API does not (yet) expose a route identifier,
/// so the platform-reported output latency is used as a stable-per-route
/// proxy key: built-in speakers, wired, and Bluetooth routes report distinct
/// constant latencies. TODO: switch to a real route id once the plugin
/// exposes one.
library;

import 'package:localjam_audio/localjam_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';

class LatencyPrefs {
  LatencyPrefs._();

  static Future<String> _routeKey(LocaljamAudio player) async {
    int reported;
    try {
      reported = await player.outputLatencyUs();
    } catch (_) {
      reported = 0; // Native side not available yet; use the default route.
    }
    return 'nudgeUs.route_$reported';
  }

  /// Loads the persisted nudge (µs) for the player's current output route.
  static Future<int> load(LocaljamAudio player) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(await _routeKey(player)) ?? 0;
  }

  /// Persists the nudge (µs) for the player's current output route.
  static Future<void> save(LocaljamAudio player, int offsetUs) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(await _routeKey(player), offsetUs);
  }
}
