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
Usage: localjam join [options] <localjam://join?...>

Join a LocalJam session as a guest and run a simulated, drift-corrected
player (no audio output; the sync telemetry is the product).

Keys: p = request play/pause  s = request seek +10s  S = request seek -10s
      q = quit
''';

/// Runs the `join` command. Returns the process exit code.
Future<int> runJoinCommand(ArgResults args) async {
  if (args.rest.length != 1) {
    stderr.writeln('join: exactly one join URI is required');
    stderr.writeln(joinUsage);
    return 64;
  }
  final Uri joinUri;
  try {
    joinUri = Uri.parse(args.rest.single);
  } on FormatException catch (e) {
    stderr.writeln('join: invalid URI: ${e.message}');
    return 64;
  }
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
      screen.log('connection closed by host');
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
    'bestRtt=${client.clock.bestRttUs}us',
  );
  screen.log(
    'keys: p = play/pause | s = +10s | S = -10s | q = quit '
    '(requests; the host applies them)',
  );

  final sim = SimPlayer(skewPpm: skewPpm);

  final keys = KeyInput.start((key) {
    final snapshot = client.snapshot;
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

    final snapshot = client.snapshot;
    final sessionNowUs = client.sessionNowUs;
    sim.tick(
      snapshot: snapshot,
      sessionNowUs: sessionNowUs,
      elapsedUs: elapsedUs,
    );
    final expectedUs = snapshot.positionAt(sessionNowUs);

    screen.status(
      'offset=${formatSignedUs(client.clock.offsetUs ?? 0)} '
      'rtt=${client.clock.bestRttUs}us | '
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
