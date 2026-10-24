/// `localjam host <file...>` — starts a [JamHostServer] on all interfaces,
/// registers the given files as the playlist, prints join URLs, and shows a
/// live status line with interactive keyboard transport control. With
/// `--web-dir` it also serves a built web player to browser guests
/// (PROTOCOL.md §1.1) at the printed http join URL.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:args/args.dart';
import 'package:localjam_net/localjam_net.dart';

import 'tui.dart';
import 'web_dir.dart';

const _seekStepUs = 10_000_000; // 10 s

const hostUsage = '''
Usage: localjam host [options] <file...>

Serve one or more media files as a LocalJam session.

--web-dir <path> serves a built web player (flutter build web
--base-href /web/) to browsers that open the http join URL; without it
they get a page saying to install the app.

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

  StaticSite? site;
  final webDir = args['web-dir'] as String?;
  if (webDir != null) {
    try {
      site = await loadWebDir(Directory(webDir));
    } on WebDirException catch (e) {
      stderr.writeln('host: --web-dir: $e');
      return 66;
    } on FileSystemException catch (e) {
      stderr.writeln('host: --web-dir: ${e.message}: ${e.path}');
      return 66;
    }
  }

  final server = JamHostServer(
    sessionName: args['name'] as String,
    staticSite: site,
  );
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
      screen.log(
        'added ${item.mediaId}  ${item.name}  '
        '(${item.sizeBytes} bytes, ${item.mime})',
      );
    }
    server.setMedia(server.playlist.first.mediaId);

    if (site != null) {
      screen.log(
        'web player: ${site.files.length} files, '
        '${(site.totalBytes / (1024 * 1024)).toStringAsFixed(1)} MB'
        '${site.index == null ? ' — no index.html, browsers get the '
                  'install-the-app page' : ''}',
      );
    }
    await _printJoinInfo(server, screen);
    screen.log('');
    screen.log(
      'keys: p = play/pause | s = +10s | S = -10s | '
      'n = next track | q = quit',
    );

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

  screen.log(
    'session "${server.sessionName}" (${server.sessionId}) '
    'on port ${server.port}',
  );
  for (final addr in addresses) {
    screen.log(
      '  ${addr.address.padRight(15)} ${server.joinLinkFor(addr).toHttpUri()}',
    );
  }
  // One plain copy-paste line carrying every candidate address (§1: guests
  // try `host` candidates in order), in the http form a browser opens and
  // `localjam join` reads alike — plus the localjam:// form for 1.0 apps.
  final combined = JoinLink(
    v: MessageCodec.protocolVersion,
    token: server.token,
    name: server.sessionName,
    hosts: [for (final a in addresses) a.address],
    port: server.port,
  );
  screen.log('');
  screen.log('join with (browser, app or `localjam join`):');
  screen.log('${combined.toHttpUri()}');
  screen.log('or, in the app\'s own scheme:');
  screen.log('${combined.toLocaljamUri()}');
}

Future<int> _runLoop(JamHostServer server, StatusScreen screen) async {
  final quit = Completer<int>();
  void finish(int code) {
    if (!quit.isCompleted) quit.complete(code);
  }

  // Latest fetch progress per peer for the status line (readiness itself
  // comes from the server's peerMediaStates(); progress only rides events).
  final fetchProgress = <String, ({String mediaId, double progress})>{};

  final events = server.events.listen((event) {
    switch (event.kind) {
      case JamHostEventKind.peerJoined:
        final p = event.peer!;
        screen.log(
          '+ peer joined: ${p.clientName} '
          '(${p.peerId}, ${p.clientKind})',
        );
      case JamHostEventKind.peerLeft:
        fetchProgress.remove(event.peerId);
        screen.log('- peer left: ${event.peerId}');
      case JamHostEventKind.peerMediaStatus:
        final progress = event.progress;
        if (event.mediaState == MediaFetchState.fetching && progress != null) {
          fetchProgress[event.peerId!] = (
            mediaId: event.mediaId!,
            progress: progress,
          );
        } else {
          fetchProgress.remove(event.peerId);
        }
        screen.log(
          '  ${event.peerId} media ${event.mediaId}: '
          '${event.mediaState!.wire}'
          '${progress != null ? ' ${(progress * 100).round()}%' : ''}',
        );
      case JamHostEventKind.stateBroadcast:
        final s = event.snapshot!;
        screen.log(
          '> state rev=${s.rev} ${s.status.name} '
          'media=${s.mediaId ?? '-'} pos=${formatPositionUs(s.positionUs)}',
        );
      case JamHostEventKind.playlistBroadcast:
        screen.log('> playlist: ${event.playlist!.length} item(s)');
      case JamHostEventKind.mediaEnded:
        screen.log('> media ended: ${event.mediaId}');
      case JamHostEventKind.mediaUploaded:
        screen.log(
          '+ upload: ${event.mediaId}'
          '${event.peerId != null ? ' from ${event.peerId}' : ''}',
        );
      case JamHostEventKind.catalogAdded:
        screen.log(
          '+ catalog add: ${event.catalogId} -> ${event.mediaId}'
          '${event.peerId != null ? ' by ${event.peerId}' : ''}',
        );
      case JamHostEventKind.permissionsBroadcast:
        screen.log('> permissions rev=${event.permissions!.rev}');
      case JamHostEventKind.requestDenied:
        screen.log('! denied ${event.deniedAction!.wire} from ${event.peerId}');
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
          server.seek(
            math.max(
              0,
              server.snapshot.positionAt(monotonicNowUs()) - _seekStepUs,
            ),
          );
        case 'n':
          if (server.playlist.isEmpty) break;
          // A skip, not a pick: setMedia on the current item is a no-op
          // (§5.2), so a one-track playlist would never restart.
          server.next();
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
    final states = mediaId == null
        ? const <String, MediaReadiness>{}
        : server.peerMediaStates(mediaId);
    final parts = peers.map((p) {
      final state = states[p.peerId] ?? MediaReadiness.none;
      var label = state.name;
      if (state == MediaReadiness.fetching) {
        final report = fetchProgress[p.peerId];
        if (report != null && report.mediaId == mediaId) {
          label = 'fetching ${(report.progress * 100).round()}%';
        }
      }
      return '${p.clientName}:$label';
    });
    return 'peers(${peers.length}) [${parts.join(' ')}]';
  }

  final ticker = Timer.periodic(const Duration(milliseconds: 250), (_) {
    final s = server.snapshot;
    final name = server.playlist
        .where((i) => i.mediaId == s.mediaId)
        .map((i) => i.name)
        .firstOrNull;
    screen.status(
      'rev=${s.rev} ${s.status.name.padRight(7)} '
      '${(name ?? s.mediaId ?? '-')} '
      'pos=${formatPositionUs(s.positionAt(monotonicNowUs()))} | '
      '${peerSummary()}',
    );
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
