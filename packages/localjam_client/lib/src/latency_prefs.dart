/// Persistence for the manual sync nudge (PROTOCOL.md §7: "persisted per
/// output device").
///
/// Keyed on the native output-route id ([LocaljamAudio.currentRouteId] /
/// [LocaljamAudioEvent.routeId]): the same headphones get the same id across
/// sessions, a different device a different one. A route the platform
/// cannot name (null id) shares one "unknown route" slot.
library;

import 'package:localjam_audio/localjam_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';

class LatencyPrefs {
  LatencyPrefs._();

  /// The prefs key for [routeId].
  static String keyFor(String? routeId) => routeId == null || routeId.isEmpty
      ? 'nudgeUs.routeId.unknown'
      : 'nudgeUs.routeId.$routeId';

  /// The player's current output route id, or null when the platform cannot
  /// name it (or has no native side at all).
  static Future<String?> currentRouteId(LocaljamAudio player) async {
    try {
      return await player.currentRouteId();
    } catch (_) {
      return null;
    }
  }

  /// Loads the persisted nudge (µs) for [routeId] — the route the caller
  /// means, which it has to know: one that changed between asking and
  /// loading would hand one device's nudge to another.
  static Future<int> load(String? routeId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(keyFor(routeId)) ?? 0;
  }

  /// Persists the nudge (µs) for [routeId]: the route it was set on, not
  /// whatever the output is by the time the write happens.
  static Future<void> save(String? routeId, int offsetUs) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(keyFor(routeId), offsetUs);
  }
}
