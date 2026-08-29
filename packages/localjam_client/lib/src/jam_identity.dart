/// Per-device jam identity: a quirky, human-friendly display name
/// ("Neon Walrus") generated once and persisted, used as the guest
/// `clientName` (§3.1) and for "added by" attribution — so nobody has to
/// type a name before joining a room.
library;

import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

/// Word pools sized so collisions in one room are unlikely (48 × 48 = 2304
/// combinations) while every combination stays fit for a family living room.
const List<String> jamNameAdjectives = [
  'Amber', 'Astral', 'Bouncy', 'Brave', 'Breezy', 'Bubbly', 'Cheeky',
  'Chill', 'Cosmic', 'Crimson', 'Dandy', 'Dapper', 'Disco', 'Dizzy',
  'Dreamy', 'Electric', 'Fluffy', 'Funky', 'Fuzzy', 'Gilded', 'Glowing',
  'Golden', 'Groovy', 'Hasty', 'Hazy', 'Jazzy', 'Jolly', 'Lively',
  'Lunar', 'Mellow', 'Mighty', 'Neon', 'Nimble', 'Peppy', 'Plucky',
  'Polka', 'Quirky', 'Rowdy', 'Sassy', 'Silky', 'Snazzy', 'Sneaky',
  'Sparkly', 'Speedy', 'Sunny', 'Turbo', 'Velvet', 'Zesty',
];

const List<String> jamNameAnimals = [
  'Alpaca', 'Axolotl', 'Badger', 'Bison', 'Capybara', 'Chinchilla',
  'Cobra', 'Comet', 'Coyote', 'Dingo', 'Dodo', 'Dolphin', 'Falcon',
  'Fennec', 'Ferret', 'Flamingo', 'Gecko', 'Gibbon', 'Heron', 'Ibex',
  'Iguana', 'Jackal', 'Kiwi', 'Koala', 'Lemur', 'Llama', 'Lynx',
  'Macaw', 'Manatee', 'Marmot', 'Meerkat', 'Mongoose', 'Narwhal',
  'Ocelot', 'Otter', 'Panda', 'Pangolin', 'Penguin', 'Platypus',
  'Puffin', 'Quokka', 'Racoon', 'Sloth', 'Toucan', 'Walrus', 'Wombat',
  'Yak', 'Zebra',
];

/// Generates one quirky display name; [random] injectable for tests.
String generateJamName([Random? random]) {
  final rng = random ?? Random();
  final adjective = jamNameAdjectives[rng.nextInt(jamNameAdjectives.length)];
  final animal = jamNameAnimals[rng.nextInt(jamNameAnimals.length)];
  return '$adjective $animal';
}

/// The device's persistent jam identity.
class JamIdentity {
  JamIdentity._();

  static const _prefsKey = 'localjam.displayName';

  /// Cached for the process lifetime after the first load.
  static String? _cached;

  /// The device's display name: loaded from prefs, generated (and saved) on
  /// first use. Falls back to a fresh unpersisted name when prefs are
  /// unavailable (tests, headless embeddings) — never throws.
  static Future<String> displayName() async {
    final cached = _cached;
    if (cached != null) return cached;
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString(_prefsKey);
      if (stored != null && stored.trim().isNotEmpty) {
        return _cached = stored;
      }
      final generated = generateJamName();
      await prefs.setString(_prefsKey, generated);
      return _cached = generated;
    } catch (_) {
      return _cached = generateJamName();
    }
  }

  /// Replaces the display name (a UI rename). Empty/whitespace names are
  /// rejected by reverting to the current one.
  static Future<String> setDisplayName(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return displayName();
    _cached = trimmed;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, trimmed);
    } catch (_) {
      // Prefs unavailable: the rename still applies for this process.
    }
    return trimmed;
  }

  /// Resets the in-process cache (tests).
  static void resetCacheForTesting() => _cached = null;
}
