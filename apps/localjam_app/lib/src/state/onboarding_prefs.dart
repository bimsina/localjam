/// Whether this device has been introduced to LocalJam.
///
/// One boolean, persisted, read once at launch: the three onboarding panels
/// are a first-run courtesy, not a wall, so the flag is written the moment
/// the user leaves them — by finishing *or* by skipping — and never again.
///
/// Kept out of [JamAppSettings] deliberately. Appearance is a preference the
/// user changes; this is a fact about the install, and the router gate reads
/// it before the first frame while settings load lazily.
library;

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The persisted flag. Deliberately unprefixed — it is named in the design
/// spec, and the gate that reads it lives outside this class.
const String kOnboardingSeenKey = 'onboarding_seen';

/// "Has this device seen the intro?", persisted.
///
/// Notifies on every change, so a router built with this as its
/// `refreshListenable` re-evaluates its redirect the instant [markSeen]
/// lands.
class JamOnboardingPrefs extends ChangeNotifier {
  bool _seen = false;
  bool _loaded = false;

  /// Whether the intro has been seen or skipped. False until [load] has run,
  /// so a gate must wait on [loaded] rather than showing onboarding to
  /// everyone for one frame.
  bool get seen => _seen;

  /// Whether [load] has completed. A gate that renders before this is true
  /// should show nothing rather than guess.
  bool get loaded => _loaded;

  /// Reads the flag. Never throws — a platform with no prefs implementation
  /// (tests, headless embeddings) simply reports "not seen".
  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _seen = prefs.getBool(kOnboardingSeenKey) ?? false;
    } catch (_) {
      _seen = false;
    }
    _loaded = true;
    notifyListeners();
  }

  /// Records that the intro is done. Idempotent, and the in-memory flag flips
  /// before the write so the caller can navigate immediately.
  Future<void> markSeen() async {
    if (!_seen) {
      _seen = true;
      _loaded = true;
      notifyListeners();
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(kOnboardingSeenKey, true);
    } catch (_) {
      // The flag still holds for this run; the intro will simply come back
      // on a platform that cannot persist anything at all.
    }
  }

  /// Puts the intro back, for a test or a "show me that again" affordance.
  @visibleForTesting
  Future<void> reset() async {
    _seen = false;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(kOnboardingSeenKey);
    } catch (_) {
      // Nothing persisted, nothing to remove.
    }
  }
}

/// Provides [JamOnboardingPrefs] to the widget tree, the way [JamSettings]
/// provides appearance.
class JamOnboarding extends InheritedNotifier<JamOnboardingPrefs> {
  const JamOnboarding({
    super.key,
    required JamOnboardingPrefs prefs,
    required super.child,
  }) : super(notifier: prefs);

  /// The prefs, subscribing this context to changes. Asserts when absent.
  static JamOnboardingPrefs of(BuildContext context) {
    final prefs = maybeOf(context);
    assert(prefs != null, 'No JamOnboarding above this context.');
    return prefs!;
  }

  /// The prefs, or null where the app shell has not provided any — which is
  /// how [OnboardingScreen] stays pumpable on its own in a test.
  static JamOnboardingPrefs? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<JamOnboarding>()?.notifier;
}
