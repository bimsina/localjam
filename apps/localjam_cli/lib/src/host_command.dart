/// `localjam host <file...>` — starts a [JamHostServer] on all interfaces,
/// registers the given files as the playlist, prints join URIs, and shows a
/// live status line with interactive keyboard transport control.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:args/args.dart';
import 'package:localjam_net/localjam_net.dart';

import 'tui.dart';

const _seekStepUs = 10_000_000; // 10 s

const hostUsage = '''
Usage: localjam host [options] <file...>

Serve one or more media files as a LocalJam session.

Keys: p = play/pause  s = seek +10s  S = seek -10s  n = next track  q = quit
''';

/// Runs the `host` command. Returns the process exit code.
Future<int> runHostCommand(ArgResults args) async {
  final files = args.rest;
  if (files.isEmpty) {
    stderr.writeln('host: at least one media file is required');
    stderr.writeln(hostUsage);
    return 64;
  }
  final port = int.tryParse(args['port'] as String);
  if (port == null || port < 0 || port > 65535) {
    stderr.writeln('host: --port must be an integer in [0, 65535]');
    return 64;
  }

  final server = JamHostServer(sessionName: args['name'] as String);
  await server.start(address: InternetAddress.anyIPv4, port: port);

  final screen = StatusScreen();
  try {
    for (final path in files) {
      final file = File(path);
      if (!await file.exists()) {
        stderr.writeln('host: no such file: $path');
        return 66;
      }
      final item = await JamHostServer.describeFile(
        file,
        kind: MediaKind.audio,
        mime: mimeForPath(path),
      );
      server.addMedia(item, file);
      screen.log('added ${item.mediaId}  ${item.name}  '
          '(${item.sizeBytes} bytes, ${item.mime})');
    }
    server.setMedia(server.playlist.first.mediaId);

    await _printJoinInfo(server, screen);
    screen.log('');
    screen.log('keys: p = play/pause | s = +10s | S = -10s | '
        'n = next track | q = quit');

    return await _runLoop(server, screen);
  } finally {
    screen.done();
    await server.close();
  }
}

Future<void> _printJoinInfo(JamHostServer server, StatusScreen screen) async {
  final addresses = <InternetAddress>[];
  try {
    for (final iface in await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    )) {
      addresses.addAll(iface.addresses);
    }
  } catch (_) {
    // NetworkInterface.list can fail on locked-down systems; fall back below.
  }
  if (addresses.isEmpty) addresses.add(InternetAddress.loopbackIPv4);

  screen.log('session "${server.sessionName}" (${server.sessionId}) '
      'on port ${server.port}');
  for (final addr in addresses) {
    screen.log('  ${addr.address.padRight(15)} ${server.joinUriFor(addr)}');
  }
  // One plain copy-paste line carrying every candidate address (§1: guests
  // try `host` candidates in order).
  final combined = Uri(
    scheme: 'localjam',
    host: 'join',
    queryParameters: {
      'v': '${MessageCodec.protocolVersion}',
      'host': addresses.map((a) => a.address).join(','),
      'port': '${server.port}',
      'token': server.token,
      'name': server.sessionName,
    },
  );
  screen.log('');
  screen.log('join with:');
  screen.log('$combined');
}

Future<int> _runLoop(JamHostServer server, StatusScreen screen) async {
  final quit = Completer<int>();
  void finish(int code) {
    if (!quit.isCompleted) quit.complete(code);
  }

  // Per-peer readiness for the status line, maintained from host events
  // (the server itself only exposes the aggregate allPeersReady()).
  final peerMedia = <String, ({String mediaId, MediaFetchState state})>{};

  final events = server.events.listen((event) {
    switch (event.kind) {
      case JamHostEventKind.peerJoined:
        final p = event.peer!;
        screen.log('+ peer joined: ${p.clientName} '
            '(${p.peerId}, ${p.clientKind})');
      case JamHostEventKind.peerLeft:
        peerMedia.remove(event.peerId);
        screen.log('- peer left: ${event.peerId}');
      case JamHostEventKind.peerMediaStatus:
        peerMedia[event.peerId!] =
            (mediaId: event.mediaId!, state: event.mediaState!);
        screen.log('  ${event.peerId} media ${event.mediaId}: '
            '${event.mediaState!.wire}');
      case JamHostEventKind.stateBroadcast:
        final s = event.snapshot!;
        screen.log('> state rev=${s.rev} ${s.status.name} '
            'media=${s.mediaId ?? '-'} pos=${formatPositionUs(s.positionUs)}');
      case JamHostEventKind.playlistBroadcast:
        screen.log('> playlist: ${event.playlist!.length} item(s)');
    }
  });

  void logError(Object e) => screen.log('! $e');

  final keys = KeyInput.start((key) {
    try {
      switch (key) {
        case 'p':
          server.snapshot.status == PlaybackStatus.playing
              ? server.pause()
              : server.play();
        case 's':
          server.seek(
            server.snapshot.positionAt(monotonicNowUs()) + _seekStepUs,
          );
        case 'S':
          server.seek(math.max(
            0,
            server.snapshot.positionAt(monotonicNowUs()) - _seekStepUs,
          ));
        case 'n':
          final playlist = server.playlist;
          if (playlist.isEmpty) break;
          final index = playlist
              .indexWhere((i) => i.mediaId == server.snapshot.mediaId);
          server.setMedia(playlist[(index + 1) % playlist.length].mediaId);
        case 'q':
          finish(0);
        case '\x03': // Ctrl-C in raw-ish mode.
          finish(130);
      }
    } on StateError catch (e) {
      logError(e.message);
    } on ArgumentError catch (e) {
      logError(e);
    }
  });

  StreamSubscription<ProcessSignal>? sigint;
  try {
    sigint = ProcessSignal.sigint.watch().listen((_) => finish(130));
  } catch (_) {
    // Signal watching unsupported; q still quits.
  }

  String peerSummary() {
    final peers = server.peers;
    if (peers.isEmpty) return 'peers(0)';
    final mediaId = server.snapshot.mediaId;
    final parts = peers.map((p) {
      final report = peerMedia[p.peerId];
      final state = (report != null && report.mediaId == mediaId)
          ? report.state.wire
          : 'none';
      return '${p.clientName}:$state';
    });
    return 'peers(${peers.length}) [${parts.join(' ')}]';
  }

  final ticker = Timer.periodic(const Duration(milliseconds: 250), (_) {
    final s = server.snapshot;
    final name = server.playlist
        .where((i) => i.mediaId == s.mediaId)
        .map((i) => i.name)
        .firstOrNull;
    screen.status('rev=${s.rev} ${s.status.name.padRight(7)} '
        '${(name ?? s.mediaId ?? '-')} '
        'pos=${formatPositionUs(s.positionAt(monotonicNowUs()))} | '
        '${peerSummary()}');
  });

  try {
    return await quit.future;
  } finally {
    ticker.cancel();
    await events.cancel();
    await sigint?.cancel();
    await keys.stop();
  }
}
