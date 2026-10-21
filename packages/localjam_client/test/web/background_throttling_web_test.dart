/// A browser guest whose tab is in the background stays in the room
/// (PROTOCOL.md §3.3; docs/design/WEB_GUEST.md): its pings tick from a
/// worker ([JamTicker]), which Chrome's intensive wake-up throttling does
/// not reach.
///
/// Chrome coalesces a hidden, silent page's own timers into one wake-up a
/// minute once the page has been hidden for its grace period (5 minutes;
/// 10 s here). The guest pings every 2 s and the host drops a peer after
/// 10 s of silence, so a guest on page timers is dropped soon after
/// throttling starts — the `peer left` / `peer joined` cycles seen on the
/// Mac with a listener page left in a background pane. Both halves run
/// against a real host, with the room paused (nothing audible, so nothing
/// exempts the page):
///
/// 1. Control: the guest on page timers
///    ([JamTicker.debugUseMainThreadTimers]), the tab hidden for 75 s. A
///    page `Timer.periodic(2 s)` beside it degrades to about one tick a
///    minute, and the host drops the guest within 20 s of throttling
///    starting.
/// 2. The worker: the tab hidden for the grace plus 2 minutes. The page
///    timer degrades the same way — throttling did happen — while the
///    worker-driven 2 s probe keeps time, and the host never drops the
///    guest: no `peer_left`, the same peerId, no reconnect.
///
/// About four minutes; run it through the wrapper, which disables
/// flutter_tools' `--disable-background-timer-throttling`, shortens the
/// grace and lets the host helper hide the tab:
///
///     tool/web_engine_test.sh --throttling
///
/// A plain `flutter test` skips it (browser only); a plain
/// `flutter test --platform chrome`, or `tool/web_engine_test.sh` without
/// `--throttling`, skips it visibly.
@TestOn('browser')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_client/localjam_client.dart';
import 'package:web/web.dart' as web;

import 'web_test_support.dart';

/// Set by `tool/web_engine_test.sh --throttling`: Chrome's
/// `IntensiveWakeUpThrottling:grace_period_seconds` in that run.
const int _graceSeconds = 10;

/// Whether this run's Chrome throttles (the wrapper's `--throttling`), as
/// the host helper reports it.
bool _throttlingRun(Map<String, Object?> info) => info['throttling'] == true;

/// performance.now() in ms.
double _nowMs() => web.window.performance.now();

/// When ticks of a 2 s schedule landed, to measure its worst gap.
class _Probe {
  _Probe(Timer Function(void Function(Timer) onTick) start) {
    _timer = start((_) => ticksMs.add(_nowMs()));
  }

  late final Timer _timer;
  final List<double> ticksMs = [];

  /// The longest gap (s) between ticks landing in [fromMs, toMs], counting
  /// from [fromMs] and up to the first tick after [toMs].
  double worstGapS(double fromMs, double toMs) {
    var last = fromMs;
    var worst = 0.0;
    for (final t in ticksMs) {
      if (t < fromMs) continue;
      worst = math.max(worst, t - last);
      last = t;
      if (t > toMs) break;
    }
    return worst / 1000;
  }

  void cancel() => _timer.cancel();
}

/// Hides the test's tab for [seconds] (the host helper opens a tab in
/// front of it) and resolves once it is visible again: on
/// `visibilitychange`, an event, since every page timer is throttled in
/// between. Returns when it went hidden and visible (performance.now ms).
Future<({double hiddenMs, double visibleMs})> _hideFor(
  String control,
  int seconds,
) async {
  final hidden = Completer<double>();
  final visible = Completer<double>();
  final listener = ((web.Event _) {
    if (web.document.hidden) {
      if (!hidden.isCompleted) hidden.complete(_nowMs());
    } else if (hidden.isCompleted && !visible.isCompleted) {
      visible.complete(_nowMs());
    }
  }).toJS;
  web.document.addEventListener('visibilitychange', listener);
  try {
    await webTestControl('$control/hide/$seconds', method: 'POST');
    final hiddenMs = await hidden.future.timeout(const Duration(seconds: 10));
    final visibleMs = await visible.future;
    return (hiddenMs: hiddenMs, visibleMs: visibleMs);
  } finally {
    web.document.removeEventListener('visibilitychange', listener);
  }
}

/// The host's `peer_joined`/`peer_left` log (§3.2) and its clock now (ms).
Future<({List<Map<String, Object?>> events, int nowMs})> _peerLog(
  String control,
) async {
  final reply = await webTestControl('$control/peers');
  return (
    events: (reply['events']! as List).cast<Map>().map((e) {
      return e.cast<String, Object?>();
    }).toList(),
    nowMs: (reply['now']! as num).toInt(),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final info = webTestHostInfo.isEmpty
      ? const <String, Object?>{}
      : (jsonDecode(webTestHostInfo) as Map).cast<String, Object?>();
  if (!_throttlingRun(info)) {
    test('a background tab keeps its guest in the room', () {
      markTestSkipped(
        'needs a throttling Chrome and a host: run '
        'tool/web_engine_test.sh --throttling',
      );
    });
    return;
  }
  final control = info['control']! as String;
  final joinUri = Uri.parse(info['joinUri']! as String);

  setUpAll(routeChannelsLikeThePage);

  tearDownAll(() async {
    JamTicker.debugUseMainThreadTimers = false;
    try {
      await webTestControl('$control/quit');
    } catch (_) {}
  });

  /// Joins as the listener page does, with the room paused.
  Future<JamGuestEngine> join(String clientId) async {
    final engine = await JamGuestEngine.join(
      joinUri,
      clientName: 'Background $clientId',
      clientKind: 'web',
      clientId: clientId,
      prefetchPolicy: const JamPrefetchPolicy(aheadCount: 1),
    );
    await waitFor(
      () => engine.clockSynced,
      reason: 'the join burst to sync the clock',
    );
    return engine;
  }

  test('control: on page timers, a hidden guest is dropped once Chrome '
      'throttles them', () async {
    JamTicker.debugUseMainThreadTimers = true;
    addTearDown(() => JamTicker.debugUseMainThreadTimers = false);
    final engine = await join('c_throttle_control');
    addTearDown(engine.close);
    final peerId = engine.selfPeerId;
    final pageTimer = _Probe((f) => Timer.periodic(_twoSeconds, f));
    addTearDown(pageTimer.cancel);

    final hostBefore = (await _peerLog(control)).nowMs;
    final window = await _hideFor(control, 75);
    final log = await _peerLog(control);
    // The host's clock, ms after the tab was hidden (the request that hid
    // it took a moment; hiding is one DevTools call after it).
    final left = [
      for (final e in log.events)
        if (e['kind'] == 'left' &&
            e['peerId'] == peerId &&
            (e['t']! as num) > hostBefore)
          (e['t']! as num).toInt() - hostBefore,
    ];
    final pageGap = pageTimer.worstGapS(window.hiddenMs, window.visibleMs);
    // ignore: avoid_print
    print(
      'control: page Timer.periodic(2 s) worst gap while hidden '
      '${pageGap.toStringAsFixed(1)} s; host dropped $peerId at '
      '${left.map((t) => '+${(t / 1000).toStringAsFixed(1)} s')} after '
      'hiding (grace $_graceSeconds s)',
    );
    expect(
      pageGap,
      greaterThan(30),
      reason: 'Chrome throttled the page timers (else nothing is proven)',
    );
    expect(left, isNotEmpty, reason: 'the host dropped the guest');
    expect(
      left.first,
      lessThan((_graceSeconds + 20) * 1000),
      reason: 'within ~20 s of throttling starting',
    );
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('with the worker, a hidden guest stays joined for two minutes of '
      'throttling', () async {
    expect(JamTicker.usesWorker, isTrue);
    final engine = await join('c_throttle_worker');
    addTearDown(engine.close);
    final peerId = engine.selfPeerId;
    final states = <JamConnectionState>[];
    final sub = engine.connectionStates.listen(states.add);
    addTearDown(sub.cancel);
    final pageTimer = _Probe((f) => Timer.periodic(_twoSeconds, f));
    addTearDown(pageTimer.cancel);
    final workerTimer = _Probe((f) => JamTicker.periodic(_twoSeconds, f));
    addTearDown(workerTimer.cancel);

    final hostBefore = (await _peerLog(control)).nowMs;
    final window = await _hideFor(control, _graceSeconds + 120);
    final log = await _peerLog(control);
    final left = [
      for (final e in log.events)
        if (e['kind'] == 'left' &&
            e['peerId'] == peerId &&
            (e['t']! as num) > hostBefore)
          e,
    ];
    final pageGap = pageTimer.worstGapS(window.hiddenMs, window.visibleMs);
    final workerGap = workerTimer.worstGapS(window.hiddenMs, window.visibleMs);
    // ignore: avoid_print
    print(
      'worker: hidden ${((window.visibleMs - window.hiddenMs) / 1000).toStringAsFixed(1)} s; '
      'page Timer.periodic(2 s) worst gap ${pageGap.toStringAsFixed(1)} s, '
      'worker-driven worst gap ${workerGap.toStringAsFixed(1)} s; '
      'peer_left for $peerId: ${left.length}; connection changes: $states',
    );
    expect(
      pageGap,
      greaterThan(30),
      reason: 'Chrome throttled the page timers (else nothing is proven)',
    );
    expect(workerGap, lessThan(4), reason: 'the worker kept time');
    expect(left, isEmpty, reason: 'the host never dropped the guest');
    expect(states, isEmpty, reason: 'no reconnect');
    expect(engine.selfPeerId, peerId);
    expect(engine.connectionState, JamConnectionState.connected);
  }, timeout: const Timeout(Duration(minutes: 4)));
}

const Duration _twoSeconds = Duration(seconds: 2);
