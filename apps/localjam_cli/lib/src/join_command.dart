/// `localjam join <uri>` — connects as a guest, prefetches every playlist
/// item, then runs the SIMULATED player: a 250 ms tick that follows the
/// authoritative anchor, accumulates artificial playback-clock skew, and
/// applies §5.4 drift correction — rendering everything as one status line.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:args/args.dart';
import 'package:localjam_net/localjam_net.dart';

import 'sim_player.dart';
import 'tui.dart';

const _seekStepUs = 10_000_000; // 10 s
const _tickInterval = Duration(milliseconds: 250);

const joinUsage = '''
Usage: localjam join [options] <join URL>

The join URL is either form a host prints: http://host:port/join#...
or localjam://join?...

Join a LocalJam session as a guest and run a simulated, drift-corrected
player (no audio output; the sync telemetry is the product).

Keys: p = request play/pause  s = request seek +10s  S = request seek -10s
      q = quit
''';

/// The `hello.clientId` this run announces (PROTOCOL.md §3.3): [requested]
/// (`--client-id`) when given, otherwise a fresh random id for this process.
///
/// The id is what a host keeps a removed guest out by (§5.6) — without one
/// a kicked CLI guest could join straight back. It is not persisted: a
/// stored per-user id would be shared by every `localjam join` on the
/// machine, and the host treats one id as one device, so a second terminal
/// would push the first out of the room (§3.3). A guest that wants to be
/// recognised across runs passes the same `--client-id` each time.
String cliClientId(String? requested, {math.Random? random}) {
  final pinned = requested?.trim() ?? '';
  if (pinned.isNotEmpty) return pinned;
  final rng = random ?? math.Random.secure();
  final hex = StringBuffer('cli-');
  for (var i = 0; i < 16; i++) {
    hex.write(rng.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return hex.toString();
}

/// Runs the `join` command. Returns the process exit code.
Future<int> runJoinCommand(ArgResults args) async {
  if (args.rest.length != 1) {
    stderr.writeln('join: exactly one join URI is required');
    stderr.writeln(joinUsage);
    return 64;
  }
  // Either form (§1); JoinLink.parse also forgives the whitespace and <…>
  // a pasted link can come with.
  final link = JoinLink.parse(args.rest.single);
  if (link == null) {
    stderr.writeln('join: not a LocalJam join URL: ${args.rest.single}');
    return 64;
  }
  final joinUri = link.toHttpUri();
  final skewPpm = double.tryParse(args['skew-ppm'] as String);
  if (skewPpm == null) {
    stderr.writeln('join: --skew-ppm must be a number');
    return 64;
  }

  final screen = StatusScreen();
  final JamGuestClient client;
  try {
    client = await JamGuestClient.connect(
      joinUri,
      clientName: args['name'] as String,
      clientKind: 'cli',
      clientId: cliClientId(args['client-id'] as String?),
    );
  } on Object catch (e) {
    stderr.writeln('join: could not connect: $e');
    return 69;
  }

  try {
    screen.log(
      'joined "${client.sessionName}" (${client.sessionId}) '
      'as ${client.selfPeerId}',
    );
    for (final peer in client.peers) {
      screen.log('  peer: ${peer.clientName} (${peer.peerId})');
    }
    return await _runLoop(client, screen, skewPpm: skewPpm);
  } finally {
    screen.done();
    await client.close();
  }
}

/// What to say when the host's socket closes: a deliberate end (the host
/// sent `session_ended` first, §3.4) is not a dropped connection.
String describeHostClose(SessionEndedMessage? ended) => switch (ended?.reason) {
  SessionEndedReason.hostEnded => 'The host ended the jam',
  // Terminal whatever the reason; one this build predates is still an end.
  SessionEndedReason.unknown => 'The jam ended',
  null => 'connection closed by host',
};

Future<int> _runLoop(
  JamGuestClient client,
  StatusScreen screen, {
  required double skewPpm,
}) async {
  final quit = Completer<int>();
  void finish(int code) {
    if (!quit.isCompleted) quit.complete(code);
  }

  final subs = <StreamSubscription<Object?>>[];
  final fetched = <String>{};

  Future<void> prefetch(MediaItem item) async {
    if (!fetched.add(item.mediaId)) return;
    try {
      await client.fetchMedia(
        item.mediaId,
        onProgress: (p) {
          screen.status(
            'fetch ${item.name.padRight(20)} '
            '${progressBar(p)}',
          );
        },
      );
      screen.log('fetched ${item.mediaId}  ${item.name}  (sha256 ok)');
    } on Object catch (e) {
      fetched.remove(item.mediaId);
      screen.log('! fetch failed for ${item.mediaId}: $e');
    }
  }

  subs.add(
    client.peerEvents.listen((event) {
      switch (event.kind) {
        case JamPeerEventKind.joined:
          screen.log(
            '+ peer joined: ${event.peer!.clientName} (${event.peerId})',
          );
        case JamPeerEventKind.left:
          screen.log('- peer left: ${event.peerId}');
      }
    }),
  );
  subs.add(
    client.playlistUpdates.listen((items) {
      screen.log('> playlist: ${items.length} item(s)');
      for (final item in items) {
        unawaited(prefetch(item));
      }
    }),
  );
  subs.add(
    client.states.listen(
      (s) => screen.log(
        '> state rev=${s.rev} ${s.status.name} '
        'media=${s.mediaId ?? '-'} pos=${formatPositionUs(s.positionUs)}',
      ),
    ),
  );
  // The socket closing (host shutdown or drop) ends the session. `done` also
  // completes on our own close() after quitting, hence the guard.
  unawaited(
    client.done.then((_) {
      if (quit.isCompleted) return;
      screen.log(describeHostClose(client.sessionEnded));
      finish(0);
    }),
  );

  // §6.2 v1 policy: fully prefetch everything before playing.
  for (final item in client.playlist) {
    await prefetch(item);
  }

  // Wait for the join burst to synchronize the clock (§4).
  while (!client.clock.isSynchronized) {
    if (quit.isCompleted) return quit.future;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  screen.log(
    'clock synchronized: offset=${client.clock.offsetUs}us '
    'bestRtt=${client.clock.bestRttUs}us '
    '(skew is learned over the next ~10 s; see skew= below)',
  );
  screen.log(
    'keys: p = play/pause | s = +10s | S = -10s | q = quit '
    '(requests; the host applies them)',
  );

  final sim = SimPlayer(skewPpm: skewPpm);

  final keys = KeyInput.start((key) {
    final snapshot = client.snapshot;
    // Seeking needs session time, undefined while the clock re-bursts.
    if ((key == 's' || key == 'S') && !client.clock.isSynchronized) return;
    switch (key) {
      case 'p':
        unawaited(
          snapshot.status == PlaybackStatus.playing
              ? client.requestPause()
              : client.requestPlay(),
        );
      case 's':
        unawaited(
          client.requestSeek(
            snapshot.positionAt(client.sessionNowUs) + _seekStepUs,
          ),
        );
      case 'S':
        unawaited(
          client.requestSeek(
            math.max(0, snapshot.positionAt(client.sessionNowUs) - _seekStepUs),
          ),
        );
      case 'q':
        finish(0);
      case '\x03':
        finish(130);
    }
  });

  StreamSubscription<ProcessSignal>? sigint;
  try {
    sigint = ProcessSignal.sigint.watch().listen((_) => finish(130));
  } catch (_) {
    // Signal watching unsupported; q still quits.
  }

  var lastTickUs = client.localNowUs;
  final ticker = Timer.periodic(_tickInterval, (_) {
    final nowUs = client.localNowUs;
    final elapsedUs = nowUs - lastTickUs;
    lastTickUs = nowUs;

    // A detected clock discontinuity (this machine slept) resets the
    // estimator until a fresh join burst lands (§4); session time is
    // undefined until then.
    if (!client.clock.isSynchronized) {
      screen.status('clock resyncing after a discontinuity (device sleep?)…');
      return;
    }
    final snapshot = client.snapshot;
    final sessionNowUs = client.sessionNowUs;
    sim.tick(
      snapshot: snapshot,
      sessionNowUs: sessionNowUs,
      elapsedUs: elapsedUs,
    );
    final expectedUs = snapshot.positionAt(sessionNowUs);

    // Clock telemetry (§4): the RTT floor gating samples, and the host
    // clock's estimated rate relative to ours — the number that matters
    // when the two terminals run on different machines.
    final clock = client.clock;
    screen.status(
      'offset=${formatSignedUs(clock.offsetUs ?? 0)} '
      'floor=${clock.rttFloorUs}us '
      'skew=${clock.skewPpm >= 0 ? '+' : ''}'
      '${clock.skewPpm.toStringAsFixed(1)}ppm | '
      '${snapshot.status.name.padRight(7)} '
      'exp=${formatPositionUs(expectedUs)} '
      'act=${formatPositionUs(sim.positionUs)} '
      'drift=${formatSignedUs(sim.lastDriftUs)} '
      'action=${describeDriftAction(sim.lastAction)} '
      'slews=${sim.slews} resyncs=${sim.hardResyncs}',
    );
  });

  try {
    return await quit.future;
  } finally {
    ticker.cancel();
    for (final sub in subs) {
      await sub.cancel();
    }
    await sigint?.cancel();
    await keys.stop();
  }
}
