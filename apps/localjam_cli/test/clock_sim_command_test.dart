import 'package:args/args.dart';
import 'package:localjam_cli/src/clock_sim_command.dart';
import 'package:test/test.dart';

/// Runs `clock-sim` with [argv]; returns (exit code, stdout, stderr).
(int, String, String) _run(List<String> argv) {
  final parser = ArgParser();
  addClockSimOptions(parser);
  final out = StringBuffer();
  final err = StringBuffer();
  final code = runClockSimCommand(parser.parse(argv), out, err);
  return (code, out.toString(), err.toString());
}

void main() {
  test('simulates skewed clocks and reports the estimator tracking them', () {
    final (code, out, err) = _run([
      '--clock-skew-ppm',
      '120',
      '--jitter',
      'powersave',
      '--minutes',
      '6',
    ]);
    expect(code, 0, reason: err);
    expect(out, contains('guest clock +120.0 ppm vs host'));
    // One table row per simulated minute.
    expect(
      RegExp(r'^\s+\d+\s+\d+\.\d{3}ms', multiLine: true).allMatches(out),
      hasLength(6),
    );

    final skew = RegExp(
      r'estimated skew ([+-][\d.]+) ppm \(true -120\.00 ppm',
    ).firstMatch(out);
    expect(skew, isNotNull, reason: out);
    expect(double.parse(skew![1]!), closeTo(-120, 1));

    final p99 = RegExp(r'p99 ([\d.]+)ms').firstMatch(out);
    expect(double.parse(p99![1]!), lessThan(0.5), reason: out);
    expect(
      out,
      contains(
        'mapping: largest jump when a sample landed 0us, 0 backward steps',
      ),
    );
  });

  test('a ping gap and a drifting crystal on heavy power save', () {
    final (code, out, err) = _run([
      '--clock-skew-ppm',
      '100',
      '--skew-drift-ppm',
      '20',
      '--jitter',
      'powersave-heavy',
      '--minutes',
      '10',
      '--gap-at',
      '3',
      '--gap-minutes',
      '3',
    ]);
    expect(code, 0, reason: err);
    expect(out, contains('guest clock +100.0 ppm vs host drifting to +120.0'));
    expect(out, contains('no pings from 3.0min for 3.0min'));
    expect('(no pings: extrapolating)'.allMatches(out), hasLength(3));
    expect(out, contains('0 backward steps'));
    // Minutes after the gap: the floor learned before it still holds, so
    // power-save-delayed pongs stay out (they once put this 20–30 ms off).
    for (final m in RegExp(
      r'^\s+([6-9])\s+(\d+\.\d{3})ms',
      multiLine: true,
    ).allMatches(out)) {
      expect(double.parse(m[2]!), lessThan(3), reason: out);
    }
  });

  test('accepts every network preset', () {
    for (final preset in [
      'lan',
      'good',
      'powersave',
      'powersave-heavy',
      'bad',
      'congested',
      'bursty',
      'correlated',
      'asymmetric',
      '2.5',
    ]) {
      final (code, _, err) = _run(['--jitter', preset, '--minutes', '1']);
      expect(code, 0, reason: '$preset: $err');
    }
  });

  test('a guest sleep is detected and annotated', () {
    final (code, out, _) = _run([
      '--sleep-at',
      '2',
      '--sleep-seconds',
      '60',
      '--minutes',
      '5',
    ]);
    expect(code, 0);
    expect(out, contains('(asleep)'));
    expect(out, contains('hard resyncs 1'));
    expect(out, matches(RegExp(r'recovered \d+\.\ds after waking')));
  });

  test('is reproducible for a seed', () {
    final a = _run(['--minutes', '3', '--seed', '9', '--jitter', 'bad']);
    final b = _run(['--minutes', '3', '--seed', '9', '--jitter', 'bad']);
    expect(a.$2, b.$2);
  });

  test('rejects bad options with exit code 64', () {
    for (final argv in [
      ['--clock-skew-ppm', 'fast'],
      ['--clock-skew-ppm', '5000'],
      ['--jitter', 'awful'],
      ['--minutes', '0'],
      ['--seed', 'x'],
      ['--minutes', '10', '--sleep-at', '10'],
      ['--sleep-at', '1', '--sleep-seconds', '0'],
      ['--clock-skew-ppm', '900', '--skew-drift-ppm', '200'],
      ['--skew-drift-ppm', 'warm'],
      ['--minutes', '10', '--gap-at', '12'],
      ['--gap-at', '1', '--gap-minutes', '-2'],
    ]) {
      final (code, out, err) = _run(argv);
      expect(code, 64, reason: '$argv');
      expect(err, startsWith('clock-sim: '), reason: '$argv');
      expect(out, isEmpty, reason: '$argv');
    }
  });

  test('--jitter takes presets or a median queueing delay in ms', () {
    expect(parseJitter('lan')!.uplinkFloorUs, 250);
    expect(parseJitter('powersave')!.spikeProbability, 0.10);
    final custom = parseJitter('2.5')!;
    expect(custom.uplinkJitterMedianUs, 2500);
    expect(custom.downlinkJitterMedianUs, 2500);
    expect(parseJitter('-1'), isNull);
    expect(parseJitter('wifi'), isNull);
  });
}
