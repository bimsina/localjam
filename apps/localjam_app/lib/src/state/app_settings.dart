/// App-level preferences that are not part of a jam.
///
/// Appearance lives here rather than in the engine: it survives sessions, and
/// the default is [ThemeMode.system] so a phone that dims itself after dark
/// does the right thing in a vehicle without anyone opening settings.
library;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _themeModeKey = 'localjam.themeMode';

/// Persisted app preferences.
class JamAppSettings extends ChangeNotifier {
  ThemeMode _themeMode = ThemeMode.system;

  /// Light, dark, or follow the OS. Light is the theme the app is designed
  /// against; system is the default so night handles itself.
  ThemeMode get themeMode => _themeMode;

  /// Reads persisted preferences. Never throws — a platform without a prefs
  /// implementation just gets the defaults.
  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString(_themeModeKey);
      final mode = _decode(stored);
      if (mode != null && mode != _themeMode) {
        _themeMode = mode;
        notifyListeners();
      }
    } catch (_) {
      // Prefs unavailable (tests, headless): defaults stand.
    }
  }

  /// Applies and persists an appearance choice.
  Future<void> setThemeMode(ThemeMode mode) async {
    if (_themeMode == mode) return;
    _themeMode = mode;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_themeModeKey, mode.name);
    } catch (_) {
      // The choice still applies for this run.
    }
  }

  static ThemeMode? _decode(String? name) => switch (name) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    'system' => ThemeMode.system,
    _ => null,
  };
}

/// Provides [JamAppSettings] to the widget tree.
class JamSettings extends InheritedNotifier<JamAppSettings> {
  const JamSettings({
    super.key,
    required JamAppSettings settings,
    required super.child,
  }) : super(notifier: settings);

  static JamAppSettings of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<JamSettings>();
    assert(scope != null, 'No JamSettings above this context.');
    return scope!.notifier!;
  }
}
