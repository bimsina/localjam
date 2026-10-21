/// [JamTicker] where nothing throttles a timer that matters (see
/// `jam_ticker.dart`): the Dart VM, natively. Plain [Timer]s — the schedule
/// the guest always ran, and the one `fake_async` tests control.
library;

import 'dart:async';

/// `Timer.periodic(interval, onTick)`.
Timer periodic(Duration interval, void Function(Timer) onTick) =>
    Timer.periodic(interval, onTick);

/// `Timer(delay, onFire)`.
Timer after(Duration delay, void Function() onFire) => Timer(delay, onFire);

/// Never: there is no worker here.
bool usesWorker() => false;
