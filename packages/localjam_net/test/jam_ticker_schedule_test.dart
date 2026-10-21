/// Natively the guest's §3.3/§4 schedule is what it always was: plain
/// `Timer`s, made through the zone it runs in — which is what lets
/// `fake_async` tests drive it. The browser twin of this test
/// (`web_smoke_test.dart`) asserts the opposite: there no page timer
/// carries the schedule, a worker does ([JamTicker]).
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:localjam_net/localjam_net.dart';
import 'package:test/test.dart';

void main() {
  test('natively the ping schedule and the liveness watchdog are zone '
      'timers, and the reconnect backoff a zone one-shot', () async {
    expect(JamTicker.usesWorker, isFalse);
    final host = JamHostServer(sessionName: 'Ticker');
    await host.start(address: InternetAddress.loopbackIPv4);
    addTearDown(host.close);

    final periods = <Duration>[];
    final oneShots = <Duration>[];
    final spec = ZoneSpecification(
      createPeriodicTimer: (self, parent, zone, period, f) {
        periods.add(period);
        return parent.createPeriodicTimer(zone, period, f);
      },
      createTimer: (self, parent, zone, duration, f) {
        oneShots.add(duration);
        return parent.createTimer(zone, duration, f);
      },
    );
    final session = await runZoned(
      () => JamGuestSession.connect(
        host.joinUriFor(InternetAddress.loopbackIPv4),
        clientId: 'ticker-device',
        pingInterval: const Duration(milliseconds: 300),
        backoff: JamBackoff(
          initialDelay: const Duration(milliseconds: 70),
          jitterRatio: 0,
        ),
      ),
      zoneSpecification: spec,
    );
    addTearDown(session.close);
    // §4 steady pings every pingInterval; §3.3 watchdog every
    // livenessTimeout / 6 = 3 × 300 ms / 6.
    expect(
      periods,
      containsAll(<Duration>[
        const Duration(milliseconds: 300),
        const Duration(milliseconds: 150),
      ]),
    );
    // The join burst's 7 spaced pings (§4).
    expect(
      oneShots.where((d) => d.inMilliseconds % 100 == 0 && d.inSeconds < 1),
      hasLength(greaterThanOrEqualTo(7)),
    );

    // A drop: the reconnect waits its backoff on a zone one-shot (§3.3).
    final reconnecting = session.connectionStates.firstWhere(
      (s) => s == JamConnectionState.reconnecting,
    );
    host.kickPeer(session.selfPeerId, allowResume: true);
    await reconnecting;
    expect(oneShots, contains(const Duration(milliseconds: 70)));
  });
}
