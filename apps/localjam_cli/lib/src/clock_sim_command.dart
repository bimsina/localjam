/// `localjam clock-sim` — a single-terminal, virtual-time demo of the guest
/// clock estimator (PROTOCOL.md §4): a host and a guest whose monotonic
/// clocks run at different rates exchange `clock_ping` / `clock_pong` over a
/// modelled Wi-Fi path, and the command reports, minute by minute, how far
/// the guest's applied offset is from the truth.
///
/// The two-terminal `host` / `join` demo runs on one machine's clock (zero
/// skew, loopback jitter), so it cannot show the effects this models:
/// crystal skew between two phones (and its drift as a crystal warms up),
/// power-save latency spikes, congestion, a fixed path asymmetry, a
/// backgrounded app that stops pinging, deep sleep. An hour simulates in
/// well under a second.
library;

import 'package:args/args.dart';
// The simulator is deliberately not part of localjam_core's public surface
// (it is a test/demo harness), so the CLI reaches into src/.
// ignore: implementation_imports
import 'package:localjam_core/src/clock/clock_simulation.dart';
import 'package:localjam_core/localjam_core.dart';

const clockSimUsage = '''
Usage: localjam clock-sim [options]

Simulate a LocalJam host and guest whose clocks run at different rates,
talking over modelled Wi-Fi, and report how closely the guest's clock-sync
estimator (PROTOCOL.md §4) tracks the host's session clock. Virtual time:
an hour runs in well under a second; nothing touches the network.

--jitter presets: lan (sub-ms), good (home Wi-Fi, rare power-save spikes),
powersave (frequent 50-300 ms spikes), powersave-heavy (90% of pongs wait
0-300 ms for a beacon), bad (10 ms floor, heavy queueing), congested
(asymmetric 15 ms downlink queueing), bursty (8 s congestion every ~40 s),
correlated (queueing that stays slow for ~10 round trips), asymmetric
(1 ms up / 3 ms down: an invisible -1 ms bias) — or a number: the median
one-way queueing delay in ms on an otherwise good link.
''';

/// Registers the `clock-sim` options on [parser].
void addClockSimOptions(ArgParser parser) {
  parser
    ..addOption(
      'clock-skew-ppm',
      defaultsTo: '50',
      help:
          'Guest clock rate error relative to the host, ppm\n'
          '(two phones typically differ by up to ~100).',
    )
    ..addOption(
      'jitter',
      defaultsTo: 'good',
      help: 'Network model: lan|good|powersave|bad|congested, or a ms number.',
    )
    ..addOption(
      'skew-drift-ppm',
      defaultsTo: '0',
      help:
          'How far the guest clock rate drifts, linearly over the\n'
          'session (a crystal warming up), ppm.',
    )
    ..addOption('minutes', defaultsTo: '60', help: 'Session length.')
    ..addOption('seed', defaultsTo: '1', help: 'Random seed (reproducible).')
    ..addOption(
      'sleep-at',
      help: 'Minute at which the guest deep-sleeps (its clock stops).',
    )
    ..addOption(
      'sleep-seconds',
      defaultsTo: '120',
      help: 'How long the guest sleeps.',
    )
    ..addOption(
      'gap-at',
      help:
          'Minute at which the guest stops pinging (app backgrounded)\n'
          'while its clock keeps running.',
    )
    ..addOption(
      'gap-minutes',
      defaultsTo: '30',
      help: 'How long the ping gap lasts.',
    )
    ..addFlag(
      'lucky',
      negatable: false,
      help: 'Give the first join ping an unusually fast round trip.',
    )
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show usage.');
}

/// The network model for a `--jitter` value, or null if unrecognized.
SimNetwork? parseJitter(String value) {
  switch (value) {
    case 'lan':
      return SimNetwork.lan;
    case 'good':
      return SimNetwork.wifiGood;
    case 'powersave':
      return const SimNetwork(spikeProbability: 0.10, lossProbability: 0.005);
    case 'powersave-heavy':
      return SimNetwork.powerSaveHeavy;
    case 'bad':
      return SimNetwork.wifiBad;
    case 'congested':
      return SimNetwork.congestedDownlink;
    case 'bursty':
      return SimNetwork.burstyCongestion;
    case 'correlated':
      return SimNetwork.correlatedJitter;
    case 'asymmetric':
      return SimNetwork.asymmetricPath;
  }
  final ms = double.tryParse(value);
  if (ms == null || ms < 0) return null;
  final us = (ms * 1000).round();
  return SimNetwork(
    uplinkJitterMedianUs: us,
    downlinkJitterMedianUs: us,
    spikeProbability: 0.02,
    lossProbability: 0.002,
  );
}

/// Runs the `clock-sim` command, writing to [out]. Returns the exit code.
int runClockSimCommand(ArgResults args, StringSink out, StringSink err) {
  final skewPpm = double.tryParse(args['clock-skew-ppm'] as String);
  final network = parseJitter(args['jitter'] as String);
  final minutes = int.tryParse(args['minutes'] as String);
  final seed = int.tryParse(args['seed'] as String);
  final sleepAtArg = args['sleep-at'] as String?;
  final sleepAt = sleepAtArg == null ? null : double.tryParse(sleepAtArg);
  final sleepSeconds = double.tryParse(args['sleep-seconds'] as String);
  final driftPpm = double.tryParse(args['skew-drift-ppm'] as String);
  final gapAtArg = args['gap-at'] as String?;
  final gapAt = gapAtArg == null ? null : double.tryParse(gapAtArg);
  final gapMinutes = double.tryParse(args['gap-minutes'] as String);

  String? problem;
  // ClockSync tracks up to ±1000 ppm (maxSkewPpm): beyond any pair of
  // crystals, and above a Linux host's NTP-slewed CLOCK_MONOTONIC.
  if (skewPpm == null || skewPpm.abs() > 1000) {
    problem = '--clock-skew-ppm must be a number in [-1000, 1000]';
  } else if (driftPpm == null || (skewPpm + driftPpm).abs() > 1000) {
    problem =
        '--skew-drift-ppm must be a number keeping the rate in '
        '[-1000, 1000]';
  } else if (network == null) {
    problem =
        '--jitter must be lan|good|powersave|powersave-heavy|bad|'
        'congested|bursty|correlated|asymmetric or a number';
  } else if (minutes == null || minutes < 1 || minutes > 24 * 60) {
    problem = '--minutes must be an integer in [1, 1440]';
  } else if (seed == null) {
    problem = '--seed must be an integer';
  } else if (sleepAtArg != null &&
      (sleepAt == null || sleepAt < 0 || sleepAt >= minutes)) {
    problem = '--sleep-at must be a minute within the session';
  } else if (sleepSeconds == null || sleepSeconds <= 0) {
    problem = '--sleep-seconds must be a positive number';
  } else if (gapAtArg != null &&
      (gapAt == null || gapAt < 0 || gapAt >= minutes)) {
    problem = '--gap-at must be a minute within the session';
  } else if (gapMinutes == null || gapMinutes <= 0) {
    problem = '--gap-minutes must be a positive number';
  }
  if (problem != null) {
    err.writeln('clock-sim: $problem');
    return 64;
  }

  final durationUs = minutes! * 60000000;
  final scenario = ClockSimScenario(
    durationUs: durationUs,
    clockSkewPpm: skewPpm!,
    skewChanges: [
      if (driftPpm != 0)
        SimSkewChange(0, skewPpm + driftPpm!, rampUs: durationUs),
    ],
    network: network!,
    luckyJoinSample: args['lucky'] as bool,
    sleeps: [
      if (sleepAt != null)
        SimSleep((sleepAt * 60e6).round(), (sleepSeconds! * 1e6).round()),
    ],
    pingGaps: [
      if (gapAt != null)
        SimPingGap((gapAt * 60e6).round(), (gapMinutes! * 60e6).round()),
    ],
  );
  final sync = ClockSync();

  out.writeln(
    'clock-sim: guest clock ${_signed(skewPpm, 1)} ppm vs host'
    '${driftPpm == 0 ? '' : ' drifting to ${_signed(skewPpm + driftPpm!, 1)}'}'
    ', jitter=${args['jitter']}, $minutes min, seed $seed'
    '${sleepAt == null ? '' : ', sleep at ${sleepAt}min for ${sleepSeconds}s'}'
    '${gapAt == null ? '' : ', no pings from ${gapAt}min for ${gapMinutes}min'}',
  );
  out.writeln('minute  max|err|   est.skew     rtt floor  synced');
  final sleep = scenario.sleeps.isEmpty ? null : scenario.sleeps.single;
  final gap = scenario.pingGaps.isEmpty ? null : scenario.pingGaps.single;
  String note(int minute) {
    final from = minute * 60000000, to = from + 60000000;
    if (gap != null &&
        from < gap.atUs + gap.durationUs &&
        to > gap.atUs &&
        (sleep == null || from >= sleep.atUs + sleep.durationUs)) {
      return '  (no pings: extrapolating)';
    }
    if (sleep == null) return '';
    final wake = sleep.atUs + sleep.durationUs;
    if (from >= sleep.atUs && to <= wake) return '  (asleep)';
    final windowEnd = wake + scenario.settleAfterWakeUs;
    return from < windowEnd && to > sleep.atUs
        ? '  (sleep/wake: includes the stale pre-detection offset)'
        : '';
  }

  final result = runClockSimulation(
    scenario,
    ClockSyncSimAdapter(sync),
    seed: seed!,
    onMinute: (minute, maxAbsErrorUs) {
      final floor = sync.rttFloorUs;
      out.writeln(
        '${minute.toString().padLeft(6)}  '
        '${_ms(maxAbsErrorUs).padLeft(8)}  '
        '${'${_signed(sync.skewPpm, 1)}ppm'.padLeft(10)}  '
        '${(floor == null ? '-' : _ms(floor)).padLeft(10)}  '
        '${sync.isSynchronized ? 'yes' : 'NO'}${note(minute)}',
      );
    },
  );

  out.writeln('');
  out.writeln(
    'applied offset error (outside resync windows): '
    'p50 ${_ms(result.p50AbsUs)}, p99 ${_ms(result.p99AbsUs)}, '
    'max ${_ms(result.maxAbsUs)}',
  );
  out.writeln(
    'hard resyncs ${result.hardResyncs}, samples ${result.samplesDelivered} '
    '(${result.samplesLost} lost)'
    '${result.recoveryAfterWakeUs.isEmpty ? '' : ', recovered '
              '${(result.recoveryAfterWakeUs.single / 1e6).toStringAsFixed(1)}'
              's after waking'}',
  );
  out.writeln(
    'mapping: largest jump when a sample landed ${result.maxUpdateJumpUs}us, '
    '${result.backwardUpdates} backward steps (hard resyncs excluded)',
  );
  final finalPpm = skewPpm + driftPpm!;
  out.writeln(
    'estimated skew ${_signed(sync.skewPpm, 2)} ppm '
    '(true ${_signed(-finalPpm, 2)} ppm: host relative to guest)',
  );
  return 0;
}

String _ms(int us) => '${(us / 1000).toStringAsFixed(3)}ms';

String _signed(double v, int digits) =>
    '${v >= 0 ? '+' : ''}${v.toStringAsFixed(digits)}';
