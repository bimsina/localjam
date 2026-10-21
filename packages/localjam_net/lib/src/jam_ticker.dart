/// Timers for the guest's liveness and sync schedules (PROTOCOL.md §3.3, §4,
/// §5.4) that a browser does not throttle: natively a plain [Timer], in a
/// browser a [Timer] whose ticks come from a dedicated Web Worker — picked
/// at compile time like the guest transport (`guest_transport.dart`).
///
/// Why a browser needs its own source: once a page has been hidden for five
/// minutes and is not audibly playing, Chrome's intensive wake-up throttling
/// coalesces main-thread `setTimeout`/`setInterval` — which a Dart [Timer]
/// compiles to — into one wake-up per minute. The guest pings every 2 s and
/// calls a host dead after 6 s without a frame; the host drops a peer after
/// 10 s of silence (§3.3). A once-a-minute ping schedule turns a listening
/// tab whose room is paused (or a phone tab in the background) into a
/// peer that leaves and rejoins every 12–40 s. A worker's own timers are
/// not throttled that way, and a `postMessage` from it reaches the page as
/// a task, not a timer, so the page runs each tick on time.
///
/// The worker is a few lines of JavaScript started from a `blob:` URL —
/// same origin, no extra file in the bundle, no request to anywhere. A
/// browser that cannot start it (no `Worker`, a policy that refuses it, a
/// worker that reports an error) gets plain [Timer]s instead, timers already
/// running included: nothing worse than before.
///
/// Only the source of the ticks changes, never the schedule: the intervals
/// and every §3.3/§4 timeout are the caller's, as before.
library;

import 'dart:async';

import 'package:meta/meta.dart';

import 'jam_ticker_native.dart'
    if (dart.library.io) 'jam_ticker_native.dart'
    if (dart.library.js_interop) 'jam_ticker_web.dart'
    as platform;

/// Where a guest's schedule timers come from. Use [periodic] and [after]
/// wherever a missed tick in a background browser tab would cost liveness
/// (§3.3) or sync (§4, §5.4): the ping schedule, the liveness watchdog, the
/// reconnect backoff, the drift self-check.
abstract final class JamTicker {
  /// A periodic timer: [onTick] every [interval] until cancelled — natively
  /// exactly `Timer.periodic(interval, onTick)`. In a browser it is driven
  /// by the worker (see the library comment); [Timer.tick] counts the ticks
  /// delivered. [onTick] runs in the zone [periodic] was called in, as a
  /// [Timer]'s callback does.
  static Timer periodic(Duration interval, void Function(Timer) onTick) =>
      debugUseMainThreadTimers
      ? Timer.periodic(interval, onTick)
      : platform.periodic(interval, onTick);

  /// A one-shot timer: [onFire] once after [delay] unless cancelled —
  /// natively exactly `Timer(delay, onFire)`, worker-driven in a browser.
  static Timer after(Duration delay, void Function() onFire) =>
      debugUseMainThreadTimers
      ? Timer(delay, onFire)
      : platform.after(delay, onFire);

  /// Whether new timers are driven by a worker: true in a browser that
  /// started one (it starts on the first timer, so this may start one),
  /// false natively, after a fallback, or under [debugUseMainThreadTimers].
  static bool get usesWorker =>
      !debugUseMainThreadTimers && platform.usesWorker();

  /// Tests only: make [periodic] and [after] plain main-thread [Timer]s on
  /// every platform — the browser guest as it was before the worker, which
  /// a throttling test needs as its control. Natively it changes nothing.
  @visibleForTesting
  static bool debugUseMainThreadTimers = false;
}
