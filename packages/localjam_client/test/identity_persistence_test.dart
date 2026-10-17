/// Identity across a cold start, which is the one thing it has to survive.
///
/// The report: "Disco Badger" became "Chill Toucan" after one launch, and the
/// new name then stuck. The cause was a 300 ms timeout on an unwarmed
/// `shared_preferences` channel, whose failure path minted a fresh identity
/// *and wrote it over the stored one*. These tests hold the store at arm's
/// length — slow, then failing — and check that nothing is ever minted over
/// an identity that was simply late.
library;

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_client/localjam_client.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';

const String _nameKey = 'flutter.localjam.displayName';
const String _idKey = 'flutter.localjam.clientId';

/// A prefs store that answers only when told to — and remembers every write,
/// because "did anything overwrite the stored identity?" is the question.
class TestPrefsStore extends SharedPreferencesStorePlatform {
  TestPrefsStore({
    Map<String, Object>? data,
    this.gated = false,
    this.failures = 0,
  }) : _data = <String, Object>{...?data};

  final Map<String, Object> _data;

  /// When true, reads wait for [release].
  final bool gated;

  /// How many reads throw before the store starts answering.
  int failures;

  final Completer<void> _gate = Completer<void>();
  final List<String> writes = <String>[];

  void release() {
    if (!_gate.isCompleted) _gate.complete();
  }

  Map<String, Object> get data => Map<String, Object>.unmodifiable(_data);

  Future<Map<String, Object>> _read() async {
    if (failures > 0) {
      failures--;
      throw PlatformException(code: 'channel-error');
    }
    if (gated) await _gate.future;
    return Map<String, Object>.from(_data);
  }

  @override
  Future<Map<String, Object>> getAll() => _read();

  @override
  Future<Map<String, Object>> getAllWithParameters(GetAllParameters p) =>
      _read();

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    writes.add(key);
    _data[key] = value;
    return true;
  }

  @override
  Future<bool> remove(String key) async {
    _data.remove(key);
    return true;
  }

  @override
  Future<bool> clear() async {
    _data.clear();
    return true;
  }

  @override
  Future<bool> clearWithParameters(ClearParameters parameters) => clear();
}

TestPrefsStore install(TestPrefsStore store) {
  SharedPreferences.resetStatic();
  SharedPreferencesStorePlatform.instance = store;
  JamIdentity.resetCacheForTesting();
  return store;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    JamIdentity.resetCacheForTesting();
    SharedPreferences.resetStatic();
  });

  test('the timeout is long enough for a cold start', () {
    // 300 ms was less than an unwarmed platform channel takes on a first
    // launch, which is how a race became a lost identity.
    expect(JamIdentity.prefsTimeout, const Duration(milliseconds: 1500));
  });

  test('a store that is merely slow never costs the stored identity', () async {
    final store = install(
      TestPrefsStore(
        gated: true,
        data: {_nameKey: 'Disco Badger', _idKey: 'c_stored'},
      ),
    );
    var announced = 0;
    void listener() => announced++;
    JamIdentity.changes.addListener(listener);
    addTearDown(() => JamIdentity.changes.removeListener(listener));

    // Both callers give up at the timeout and are handed something to use.
    final ephemeral = await Future.wait([
      JamIdentity.displayName(),
      JamIdentity.clientId(),
    ]);
    expect(ephemeral[0], isNot('Disco Badger'));
    expect(ephemeral[1], isNot('c_stored'));
    // The bug, in one line: nothing may be written on a timeout.
    expect(store.writes, isEmpty);
    expect(store.data[_nameKey], 'Disco Badger');
    expect(JamIdentity.settling, isTrue);

    // The channel warms up. The stored identity is adopted, not replaced.
    store.release();
    await JamIdentity.waitForSettle();
    expect(await JamIdentity.displayName(), 'Disco Badger');
    expect(await JamIdentity.clientId(), 'c_stored');
    expect(store.writes, isEmpty);
    expect(announced, greaterThan(0), reason: 'the UI has to be told');
    expect(JamIdentity.settling, isFalse);
  });

  test('a store that throws is retried, not overruled', () {
    // On fake time: the background retry is 250 ms behind the first answer,
    // and on a machine loaded far past its cores the first `await` used to
    // resume after the retry had already adopted the stored name.
    fakeAsync((async) {
      final store = install(
        TestPrefsStore(failures: 2, data: {_nameKey: 'Disco Badger'}),
      );
      String? first;
      unawaited(JamIdentity.displayName().then((name) => first = name));
      async.flushMicrotasks();
      expect(first, isNotNull);
      expect(first, isNot('Disco Badger'));
      expect(store.writes, isEmpty);

      // The retry fails once more (250 ms), then the store answers (500 ms).
      async.elapse(const Duration(seconds: 2));
      expect(JamIdentity.settling, isFalse);
      String? later;
      unawaited(JamIdentity.displayName().then((name) => later = name));
      async.flushMicrotasks();
      expect(later, 'Disco Badger');
      expect(store.writes, isEmpty);
    });
  });

  test('a store that answers "nothing here" does mint, and persists it', () {
    // The other half of the rule: a definitive empty answer is the only
    // thing that may create an identity.
    final store = install(TestPrefsStore());
    return JamIdentity.displayName().then((name) async {
      expect(name, isNotEmpty);
      expect(store.data[_nameKey], name);
      expect(await JamIdentity.clientId(), startsWith('c_'));
      expect(store.data[_idKey], await JamIdentity.clientId());
    });
  });

  test(
    'an ephemeral name is kept once the store confirms it is empty',
    () async {
      // Continuity: the user has already seen this name. If the store turns
      // out to be genuinely empty, that name becomes the persisted one rather
      // than being swapped for a third.
      final store = install(TestPrefsStore(gated: true));
      final shown = await JamIdentity.displayName();
      expect(store.writes, isEmpty);

      store.release();
      await JamIdentity.waitForSettle();
      expect(await JamIdentity.displayName(), shown);
      expect(store.data[_nameKey], shown);
    },
  );

  test('a rename beats a late read, and reaches the store', () async {
    final store = install(
      TestPrefsStore(gated: true, data: {_nameKey: 'Disco Badger'}),
    );
    await JamIdentity.displayName(); // times out, ephemeral
    unawaited(JamIdentity.setDisplayName('DJ Sloth'));
    store.release();
    await JamIdentity.waitForSettle();

    expect(await JamIdentity.displayName(), 'DJ Sloth');
    expect(store.data[_nameKey], 'DJ Sloth');
  });
}
