/// [JamTicker] keeps a [Timer]'s contract on every platform — on the VM it
/// is a plain `Timer`, in a browser a worker-driven one (PROTOCOL.md §3.3:
/// a browser guest's pings must come from a source the page's throttling
/// does not reach). Runs on both:
///
///     dart test test/jam_ticker_test.dart
///     dart test -p chrome test/jam_ticker_test.dart
library;

import 'dart:async';

import 'package:localjam_net/guest.dart';
import 'package:test/test.dart';

/// Compiled for a browser (dart2js or dart2wasm).
const bool _isWeb = bool.fromEnvironment('dart.library.js_interop');

void main() {
  test('a worker drives the timers exactly in a browser', () {
    expect(JamTicker.usesWorker, _isWeb);
  });

  test('periodic ticks, counts its ticks, and stops on cancel', () async {
    final ticks = <int>[];
    final timer = JamTicker.periodic(
      const Duration(milliseconds: 40),
      (t) => ticks.add(t.tick),
    );
    expect(timer.isActive, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(ticks.length, greaterThanOrEqualTo(3));
    expect(ticks, [for (var i = 1; i <= ticks.length; i++) i]);
    expect(timer.tick, ticks.length);
    timer.cancel();
    expect(timer.isActive, isFalse);
    final stoppedAt = ticks.length;
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(ticks.length, stoppedAt, reason: 'no tick after cancel');
  });

  test('after fires once, and not at all once cancelled', () async {
    var fired = 0;
    final once = JamTicker.after(
      const Duration(milliseconds: 30),
      () => fired++,
    );
    var cancelledFired = 0;
    final cancelled = JamTicker.after(
      const Duration(milliseconds: 30),
      () => cancelledFired++,
    )..cancel();
    expect(once.isActive, isTrue);
    expect(cancelled.isActive, isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(fired, 1);
    expect(once.isActive, isFalse);
    expect(once.tick, 1);
    expect(cancelledFired, 0);
  });

  test('callbacks run in the zone that made the timer, as Timer does', () {
    final key = Object();
    final fired = Completer<Object?>();
    runZoned(
      () => JamTicker.after(
        const Duration(milliseconds: 10),
        () => fired.complete(Zone.current[key]),
      ),
      zoneValues: {key: 'mine'},
    );
    expect(fired.future, completion('mine'));
  });

  test('an error in a callback reaches the zone that made the timer', () {
    final caught = Completer<Object>();
    runZonedGuarded(
      () => JamTicker.after(
        const Duration(milliseconds: 10),
        () => throw StateError('boom'),
      ),
      (error, _) => caught.complete(error),
    );
    expect(caught.future, completion(isA<StateError>()));
  });

  test('debugUseMainThreadTimers makes plain page timers everywhere', () {
    addTearDown(() => JamTicker.debugUseMainThreadTimers = false);
    JamTicker.debugUseMainThreadTimers = true;
    expect(JamTicker.usesWorker, isFalse);
    var created = 0;
    runZoned(
      () => JamTicker.after(Duration.zero, () {}),
      zoneSpecification: ZoneSpecification(
        createTimer: (self, parent, zone, duration, f) {
          created++;
          return parent.createTimer(zone, duration, f);
        },
      ),
    );
    expect(created, 1, reason: 'a Timer made through the zone');
  });
}
