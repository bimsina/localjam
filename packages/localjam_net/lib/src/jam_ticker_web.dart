/// [JamTicker] in a browser (see `jam_ticker.dart`): one dedicated Web
/// Worker per page runs the `setTimeout`/`setInterval` calls and posts each
/// tick back; the page runs the Dart callback when the message arrives.
///
/// Measured in Chrome 155 (headless, a background tab, intensive wake-up
/// throttling after a 10 s grace): a page `setInterval(2 s)` ticked at
/// 42 s and 60 s gaps once throttled; the same interval in a worker, its
/// ticks delivered by `postMessage`, kept 2 s throughout.
///
/// The protocol between the page and the worker is three numbers per
/// message, `[op, id, ms]` — op 0 starts a one-shot of `ms`, 1 a periodic
/// one, 2 clears `id` — and the worker answers each tick with the bare
/// `id`. Ids are the page's, so a tick for a timer the page already
/// cancelled (it crossed the clear in flight) is simply not found.
library;

import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// The worker's whole source. Starts and clears timers on request and
/// posts each tick's id; a one-shot forgets itself as it fires. One
/// `clearTimeout` clears either kind (HTML keeps both in one list).
const String _workerSource = '''
const t = new Map();
onmessage = (e) => {
  const [op, id, ms] = e.data;
  if (op === 2) { clearTimeout(t.get(id)); t.delete(id); return; }
  t.set(id, op === 1
    ? setInterval(() => postMessage(id), ms)
    : setTimeout(() => { t.delete(id); postMessage(id); }, ms));
};
''';

/// A worker-driven periodic timer, or a plain one where no worker runs.
Timer periodic(Duration interval, void Function(Timer) onTick) {
  final timer = _WorkerTimer._(
    interval,
    periodic: true,
    onTick: Zone.current.bindUnaryCallbackGuarded(onTick),
  );
  timer._start();
  return timer;
}

/// A worker-driven one-shot timer, or a plain one where no worker runs.
Timer after(Duration delay, void Function() onFire) {
  final timer = _WorkerTimer._(
    delay,
    periodic: false,
    onFire: Zone.current.bindCallbackGuarded(onFire),
  );
  timer._start();
  return timer;
}

/// Whether timers are worker-driven here: starts the worker if none runs
/// yet, false once it could not start or failed.
bool usesWorker() => _WorkerTicks.instance != null;

/// The page's one worker and the timers it drives.
final class _WorkerTicks {
  _WorkerTicks._(this._worker) {
    _worker.onmessage = _onMessage.toJS;
    // A worker that fails to load (a policy refusing `blob:` workers) or
    // throws reports it here, asynchronously: everything it was driving
    // moves to plain timers.
    _worker.onerror = _onError.toJS;
  }

  static _WorkerTicks? _instance;
  static bool _unavailable = false;

  /// The running worker, started on first use; null when this page cannot
  /// run one (then and from then on: plain timers).
  static _WorkerTicks? get instance {
    if (_unavailable) return null;
    final running = _instance;
    if (running != null) return running;
    try {
      final source = web.Blob(
        <JSAny>[_workerSource.toJS].toJS,
        web.BlobPropertyBag(type: 'text/javascript'),
      );
      // Kept, not revoked: one tiny blob for the page's lifetime, and some
      // browsers read a worker's script after the constructor returns.
      final url = web.URL.createObjectURL(source);
      return _instance = _WorkerTicks._(web.Worker(url.toJS));
    } catch (_) {
      // No `Worker` at all, or one the page may not start.
      _unavailable = true;
      return null;
    }
  }

  final web.Worker _worker;
  final Map<int, _WorkerTimer> _timers = {};
  int _nextId = 1;

  /// Starts [timer] in the worker; its id.
  int start(_WorkerTimer timer) {
    final id = _nextId++;
    _timers[id] = timer;
    final ms = timer._duration.inMilliseconds;
    _post(timer._periodic ? 1 : 0, id, ms < 0 ? 0 : ms);
    return id;
  }

  /// Clears timer [id] in the worker (a no-op for one already gone).
  void stop(int id) {
    if (_timers.remove(id) != null) _post(2, id, 0);
  }

  /// A one-shot that fired: the worker already forgot it.
  void forget(int id) => _timers.remove(id);

  void _post(int op, int id, int ms) {
    _worker.postMessage(<JSAny>[op.toJS, id.toJS, ms.toJS].toJS);
  }

  void _onMessage(web.MessageEvent event) {
    final data = event.data;
    if (data == null || !data.isA<JSNumber>()) return;
    _timers[(data as JSNumber).toDartInt]?._fire();
  }

  void _onError(web.Event event) {
    event.preventDefault();
    _unavailable = true;
    _instance = null;
    try {
      _worker.terminate();
    } catch (_) {}
    final live = _timers.values.toList();
    _timers.clear();
    for (final timer in live) {
      timer._fallBack();
    }
  }
}

/// A [Timer] whose ticks come from [_WorkerTicks], or from a plain [Timer]
/// when there is no worker (or it failed while this one ran).
final class _WorkerTimer implements Timer {
  _WorkerTimer._(
    this._duration, {
    required this._periodic,
    this._onTick,
    this._onFire,
  });

  final Duration _duration;
  final bool _periodic;

  /// The caller's callback, already bound to the zone it was created in
  /// (what `Timer`'s own constructors do).
  final void Function(Timer)? _onTick;
  final void Function()? _onFire;

  int? _id;
  Timer? _fallback;
  bool _active = true;
  int _tick = 0;

  void _start() {
    final ticks = _WorkerTicks.instance;
    if (ticks == null) {
      _fallBack();
    } else {
      _id = ticks.start(this);
    }
  }

  /// Plain-timer ticks from here on. A one-shot restarts its whole delay:
  /// it only happens when the worker failed, and late beats never.
  void _fallBack() {
    if (!_active) return;
    _id = null;
    _fallback = _periodic
        ? Timer.periodic(_duration, (_) => _fire())
        : Timer(_duration, _fire);
  }

  void _fire() {
    if (!_active) return;
    _tick++;
    if (_periodic) {
      _onTick!(this);
    } else {
      _active = false;
      final id = _id;
      if (id != null) _WorkerTicks._instance?.forget(id);
      _onFire!();
    }
  }

  @override
  int get tick => _tick;

  @override
  bool get isActive => _active;

  @override
  void cancel() {
    if (!_active) return;
    _active = false;
    _fallback?.cancel();
    final id = _id;
    if (id != null) _WorkerTicks._instance?.stop(id);
  }
}
