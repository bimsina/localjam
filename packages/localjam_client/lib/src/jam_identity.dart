/// Per-device jam identity: a quirky, human-friendly display name
/// ("Neon Walrus") generated once and persisted, used as the guest
/// `clientName` (§3.1) and for "added by" attribution — so nobody has to
/// type a name before joining a room.
library;

import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Word pools sized so collisions in one room are unlikely (48 × 48 = 2304
/// combinations) while every combination stays fit for a family living room.
const List<String> jamNameAdjectives = [
  'Amber',
  'Astral',
  'Bouncy',
  'Brave',
  'Breezy',
  'Bubbly',
  'Cheeky',
  'Chill',
  'Cosmic',
  'Crimson',
  'Dandy',
  'Dapper',
  'Disco',
  'Dizzy',
  'Dreamy',
  'Electric',
  'Fluffy',
  'Funky',
  'Fuzzy',
  'Gilded',
  'Glowing',
  'Golden',
  'Groovy',
  'Hasty',
  'Hazy',
  'Jazzy',
  'Jolly',
  'Lively',
  'Lunar',
  'Mellow',
  'Mighty',
  'Neon',
  'Nimble',
  'Peppy',
  'Plucky',
  'Polka',
  'Quirky',
  'Rowdy',
  'Sassy',
  'Silky',
  'Snazzy',
  'Sneaky',
  'Sparkly',
  'Speedy',
  'Sunny',
  'Turbo',
  'Velvet',
  'Zesty',
];

const List<String> jamNameAnimals = [
  'Alpaca',
  'Axolotl',
  'Badger',
  'Bison',
  'Capybara',
  'Chinchilla',
  'Cobra',
  'Comet',
  'Coyote',
  'Dingo',
  'Dodo',
  'Dolphin',
  'Falcon',
  'Fennec',
  'Ferret',
  'Flamingo',
  'Gecko',
  'Gibbon',
  'Heron',
  'Ibex',
  'Iguana',
  'Jackal',
  'Kiwi',
  'Koala',
  'Lemur',
  'Llama',
  'Lynx',
  'Macaw',
  'Manatee',
  'Marmot',
  'Meerkat',
  'Mongoose',
  'Narwhal',
  'Ocelot',
  'Otter',
  'Panda',
  'Pangolin',
  'Penguin',
  'Platypus',
  'Puffin',
  'Quokka',
  'Racoon',
  'Sloth',
  'Toucan',
  'Walrus',
  'Wombat',
  'Yak',
  'Zebra',
];

/// Generates one quirky display name; [random] injectable for tests.
String generateJamName([Random? random]) {
  final rng = random ?? Random();
  final adjective = jamNameAdjectives[rng.nextInt(jamNameAdjectives.length)];
  final animal = jamNameAnimals[rng.nextInt(jamNameAnimals.length)];
  return '$adjective $animal';
}

/// The device's persistent jam identity.
///
/// Identity has one hard rule: it must survive a cold start. A guest that
/// comes back with a new [clientId] is a *different device* as far as a host
/// is concerned, so the rejoin-supersede logic (§3.3) stops working and the
/// room grows a ghost; a display name that changes is the same betrayal in
/// public.
///
/// The old code broke that rule under one specific race. `getInstance()` was
/// given 300 ms — less than an unwarmed `shared_preferences` platform channel
/// can take on a cold start — and the timeout path *minted a new identity and
/// persisted it*, overwriting the stored one. One slow launch and "Disco
/// Badger" was gone for good.
///
/// So: a timeout is never an answer. It yields an in-memory **ephemeral**
/// identity for the calls that cannot wait, and a background re-read that
/// adopts the stored identity the moment prefs do answer (announced on
/// [changes]). Minting-and-persisting happens only when the store answers and
/// says, definitively, that there is nothing there.
class JamIdentity {
  JamIdentity._();

  static const _prefsKey = 'localjam.displayName';
  static const _clientIdKey = 'localjam.clientId';

  /// How long a caller waits for prefs before being handed an ephemeral
  /// identity. Generous enough for a cold start's first channel call (the
  /// old 300 ms was not), short enough that nothing visibly stalls behind it.
  static const Duration prefsTimeout = Duration(milliseconds: 1500);

  /// Backoff between background re-read attempts, capped by the last entry.
  static const List<Duration> _retryBackoff = [
    Duration(milliseconds: 250),
    Duration(milliseconds: 500),
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 4),
  ];

  static Future<SharedPreferences> _prefs() =>
      SharedPreferences.getInstance().timeout(prefsTimeout);

  /// Fires when the identity in use changes underneath whoever is showing it
  /// — a background re-read adopting the stored name after a timeout. UI that
  /// renders [displayName] should rebuild on this rather than assume the
  /// first value it was handed is final.
  static final ChangeNotifier changes = _IdentityChanges();

  /// Cached for the process lifetime after the first load.
  static String? _cached;
  static String? _cachedClientId;

  /// True while the value in use has not been confirmed against the store —
  /// prefs timed out or threw, so what we handed out is ephemeral and the
  /// stored identity (if any) is still the real one.
  static bool _nameNeedsRead = false;
  static bool _clientIdNeedsRead = false;

  /// True when the store owes us a write: a rename that could not be
  /// persisted. Beats [_nameNeedsRead] — an explicit rename is newer than
  /// anything on disk, so a retry writes it rather than adopting the old one.
  static bool _nameNeedsWrite = false;

  static Future<void>? _retry;

  /// This device's stable client id (§3.3 `hello.clientId`): random, opaque,
  /// persisted, and never shown to anyone. It is what lets a host recognize
  /// a returning device as the SAME peer — so a guest that force-quits and
  /// rejoins replaces its old slot instead of haunting the room as a second
  /// copy of itself.
  ///
  /// Unlike [displayName] this is not a rename target: it identifies the
  /// install, not the person. Never throws: an unavailable store yields an
  /// ephemeral id for this process and a background read that adopts the
  /// stored one.
  static Future<String> clientId() async {
    final cached = _cachedClientId;
    if (cached != null) return cached;
    final SharedPreferences prefs;
    try {
      prefs = await _prefs();
    } catch (_) {
      // Timed out or unavailable. Do NOT mint-and-persist: the stored id may
      // be sitting right there behind a channel that has not warmed up yet.
      return _cachedClientId = _ephemeralClientId();
    }
    final stored = prefs.getString(_clientIdKey);
    if (stored != null && stored.trim().isNotEmpty) {
      return _cachedClientId = stored;
    }
    // The store answered and there is nothing there: mint for real.
    final generated = _randomId();
    try {
      await prefs.setString(_clientIdKey, generated);
    } catch (_) {
      _clientIdNeedsRead = true;
      _scheduleRetry();
    }
    return _cachedClientId = generated;
  }

  static String _ephemeralClientId() {
    _clientIdNeedsRead = true;
    _scheduleRetry();
    return _randomId();
  }

  /// 128 bits of hex — collision-free enough that two devices sharing one is
  /// not a case worth handling.
  static String _randomId() {
    final rng = Random.secure();
    final sb = StringBuffer('c_');
    for (var i = 0; i < 16; i++) {
      sb.write(rng.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  /// The device's display name: loaded from prefs, generated (and saved) on
  /// first use. Never throws; on a store that will not answer in
  /// [prefsTimeout] it returns an ephemeral name and adopts the stored one
  /// in the background (see [changes]).
  static Future<String> displayName() async {
    final cached = _cached;
    if (cached != null) return cached;
    final SharedPreferences prefs;
    try {
      prefs = await _prefs();
    } catch (_) {
      _nameNeedsRead = true;
      _scheduleRetry();
      // Ephemeral, and deliberately not written anywhere: overwriting the
      // stored name is the bug this whole path exists to prevent.
      return _cached = generateJamName();
    }
    final stored = prefs.getString(_prefsKey);
    if (stored != null && stored.trim().isNotEmpty) {
      return _cached = stored;
    }
    final generated = generateJamName();
    try {
      await prefs.setString(_prefsKey, generated);
    } catch (_) {
      _nameNeedsWrite = true;
      _scheduleRetry();
    }
    return _cached = generated;
  }

  /// Replaces the display name (a UI rename). Empty/whitespace names are
  /// rejected by reverting to the current one.
  ///
  /// A name that changes is announced on [changes]: the rename comes from
  /// one screen (Settings, the sidebar), and every other one showing the
  /// name — Home's avatar among them — kept the old initials until the app
  /// was restarted.
  static Future<String> setDisplayName(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return displayName();
    final renamed = _cached != trimmed;
    _cached = trimmed;
    // Announced before the write: the name in use is the new one from here
    // on, whatever the store does, and nobody should wait on a slow channel
    // to see it.
    if (renamed) (changes as _IdentityChanges).announce();
    // A rename is newer than anything on disk: never let a pending re-read
    // adopt the old stored name over it.
    _nameNeedsRead = false;
    try {
      final prefs = await _prefs();
      await prefs.setString(_prefsKey, trimmed);
      _nameNeedsWrite = false;
    } catch (_) {
      // Prefs unavailable: the rename applies for this process now, and the
      // background retry carries it to disk.
      _nameNeedsWrite = true;
      _scheduleRetry();
    }
    return trimmed;
  }

  /// Keeps trying to reach prefs until the identity is settled.
  ///
  /// Runs at most one at a time and simply stops once nothing is owed, so a
  /// wedged channel costs a sleeping future and nothing else.
  static void _scheduleRetry() {
    if (_retry != null) return;
    if (!_nameNeedsRead && !_nameNeedsWrite && !_clientIdNeedsRead) return;
    final future = _retryUntilSettled();
    _retry = future;
    unawaited(future.whenComplete(() => _retry = null));
  }

  static Future<void> _retryUntilSettled() async {
    for (var attempt = 0; ; attempt++) {
      await Future<void>.delayed(
        _retryBackoff[attempt.clamp(0, _retryBackoff.length - 1)],
      );
      if (!_nameNeedsRead && !_nameNeedsWrite && !_clientIdNeedsRead) return;
      try {
        // No timeout here: this is the background, and a channel that takes
        // ten seconds to warm up should still be believed when it does.
        final prefs = await SharedPreferences.getInstance();
        await _settle(prefs);
        return;
      } catch (e) {
        if (attempt >= 8) {
          debugPrint('localjam: identity never reached prefs: $e');
          return;
        }
      }
    }
  }

  /// Reconciles the in-memory identity with the store, once prefs answer.
  static Future<void> _settle(SharedPreferences prefs) async {
    var changed = false;

    if (_nameNeedsWrite) {
      final current = _cached;
      if (current != null) await prefs.setString(_prefsKey, current);
      _nameNeedsWrite = false;
      _nameNeedsRead = false;
    } else if (_nameNeedsRead) {
      final stored = prefs.getString(_prefsKey);
      if (stored != null && stored.trim().isNotEmpty) {
        // The stored identity was there all along: adopt it, and let whoever
        // is showing the ephemeral one know.
        if (stored != _cached) changed = true;
        _cached = stored;
      } else {
        // Definitively empty: keep the name already in front of the user and
        // make it the persisted one.
        final current = _cached;
        if (current != null) await prefs.setString(_prefsKey, current);
      }
      _nameNeedsRead = false;
    }

    if (_clientIdNeedsRead) {
      final stored = prefs.getString(_clientIdKey);
      if (stored != null && stored.trim().isNotEmpty) {
        // A changed clientId breaks rejoin-supersede; the stored one wins.
        if (stored != _cachedClientId) changed = true;
        _cachedClientId = stored;
      } else {
        final current = _cachedClientId;
        if (current != null) await prefs.setString(_clientIdKey, current);
      }
      _clientIdNeedsRead = false;
    }

    if (changed) (changes as _IdentityChanges).announce();
  }

  /// Whether an identity handed out right now is still unconfirmed against
  /// the store — a background re-read is pending. Tests assert on this; the
  /// app has [changes].
  @visibleForTesting
  static bool get settling =>
      _nameNeedsRead || _nameNeedsWrite || _clientIdNeedsRead;

  /// Waits for any in-flight background reconciliation (tests).
  @visibleForTesting
  static Future<void> waitForSettle() async => _retry;

  /// Resets the in-process caches (tests).
  static void resetCacheForTesting() {
    _cached = null;
    _cachedClientId = null;
    _nameNeedsRead = false;
    _nameNeedsWrite = false;
    _clientIdNeedsRead = false;
    _retry = null;
  }
}

/// [ChangeNotifier.notifyListeners] is protected; this exposes it for the one
/// place that fires it.
class _IdentityChanges extends ChangeNotifier {
  void announce() => notifyListeners();
}
