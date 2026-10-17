import 'dart:io';

import 'package:args/args.dart';
import 'package:localjam_cli/src/clock_sim_command.dart';
import 'package:localjam_cli/src/host_command.dart';
import 'package:localjam_cli/src/join_command.dart';

ArgParser _buildParser() {
  final parser = ArgParser()
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show usage.');

  parser.addCommand('host')
    ..addOption(
      'port',
      abbr: 'p',
      defaultsTo: '0',
      help: 'TCP port to bind (0 = ephemeral).',
    )
    ..addOption('name', defaultsTo: 'LocalJam', help: 'Session name.')
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show usage.');

  parser.addCommand('join')
    ..addOption(
      'skew-ppm',
      defaultsTo: '0',
      help:
          'Artificial playback-clock skew in parts per million\n'
          '(e.g. 5000 = +0.5%; makes drift correction observable).',
    )
    ..addOption('name', defaultsTo: 'guest', help: 'Client name.')
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show usage.');

  addClockSimOptions(parser.addCommand('clock-sim'));

  return parser;
}

void _printUsage(ArgParser parser, IOSink out) {
  out.writeln('LocalJam demo CLI — synchronized playback over LAN, with a');
  out.writeln('SIMULATED player (no audio output; sync telemetry is the');
  out.writeln('product).');
  out.writeln();
  out.writeln('Usage: localjam <command> [options]');
  out.writeln();
  out.writeln('Global options:');
  out.writeln(parser.usage);
  out.writeln();
  out.writeln('Commands:');
  out.writeln();
  out.writeln('  host <file...>   Serve media files as a session.');
  out.writeln(_indent(parser.commands['host']!.usage));
  out.writeln();
  out.writeln('  join <uri>       Join a session as a guest.');
  out.writeln(_indent(parser.commands['join']!.usage));
  out.writeln();
  out.writeln(
    '  clock-sim        Simulate host/guest clock skew and Wi-Fi jitter',
  );
  out.writeln('                   against the clock-sync estimator.');
  out.writeln(_indent(parser.commands['clock-sim']!.usage));
  out.writeln();
  out.writeln('Example (two terminals):');
  out.writeln(r'  $ localjam host song.mp3 other.mp3');
  out.writeln(
    r'  $ localjam join "localjam://join?v=1&host=..." '
    '--skew-ppm 5000',
  );
  out.writeln();
  out.writeln('Example (clock sync under phone-like conditions):');
  out.writeln(
    r'  $ localjam clock-sim --clock-skew-ppm 100 --jitter powersave '
    '--sleep-at 20',
  );
}

String _indent(String text) => text.split('\n').map((l) => '    $l').join('\n');

Future<void> main(List<String> argv) async {
  final parser = _buildParser();
  final ArgResults args;
  try {
    args = parser.parse(argv);
  } on FormatException catch (e) {
    stderr.writeln('localjam: ${e.message}');
    stderr.writeln();
    _printUsage(parser, stderr);
    exit(64);
  }

  final command = args.command;
  if (args['help'] as bool || command == null) {
    _printUsage(parser, stdout);
    await stdout.flush();
    exit(
      command == null && !(args['help'] as bool) && argv.isNotEmpty ? 64 : 0,
    );
  }
  if (command['help'] as bool) {
    stdout.writeln(switch (command.name) {
      'host' => hostUsage,
      'join' => joinUsage,
      _ => clockSimUsage,
    });
    stdout.writeln(parser.commands[command.name]!.usage);
    await stdout.flush();
    exit(0);
  }

  final code = switch (command.name) {
    'host' => await runHostCommand(command),
    'join' => await runJoinCommand(command),
    'clock-sim' => runClockSimCommand(command, stdout, stderr),
    _ => 64, // Unreachable: the parser rejects unknown commands.
  };
  exit(code);
}
