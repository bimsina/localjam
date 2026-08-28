/// Headless LocalJam host for simulator demos: serves the given files,
/// prints the join URI, auto-plays once two peers are ready (or after 90 s),
/// and logs status every second.
library;

import 'dart:io';

import 'package:localjam_net/localjam_net.dart';

Future<void> main(List<String> args) async {
  final server = JamHostServer(sessionName: 'SimJam');
  await server.start(address: InternetAddress.anyIPv4);

  for (final path in args) {
    // afinfo reports "estimated duration: N sec" — the host needs durations
    // to know when a track ends (the anchor extrapolates forever otherwise).
    final info = await Process.run('afinfo', [path]);
    final match = RegExp(r'estimated duration: ([\d.]+)')
        .firstMatch(info.stdout as String);
    final durationUs =
        match == null ? null : (double.parse(match[1]!) * 1e6).round();
    final item = await JamHostServer.describeFile(
      File(path),
      kind: MediaKind.audio,
      mime: 'audio/mp4',
      durationUs: durationUs,
    );
    server.addMedia(item, File(path));
    print('added ${item.mediaId} ${item.name} ${durationUs}us');
  }
  server.setMedia(server.playlist.first.mediaId);

  final addrs = <String>[];
  for (final iface in await NetworkInterface.list(
      type: InternetAddressType.IPv4, includeLoopback: false)) {
    addrs.addAll(iface.addresses.map((a) => a.address));
  }
  final joinUri = Uri(scheme: 'localjam', host: 'join', queryParameters: {
    'v': '1',
    'host': addrs.join(','),
    'port': '${server.port}',
    'token': server.token,
    'name': 'SimJam',
  });
  print('JOIN_URI $joinUri');

  server.events.listen((e) => print('event: $e'));

  final mediaId = server.snapshot.mediaId!;
  final deadline = DateTime.now().add(const Duration(seconds: 90));
  while (DateTime.now().isBefore(deadline)) {
    if (server.peers.length >= 2 && server.allPeersReady(mediaId)) break;
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  print('peers=${server.peers.length} ready=${server.allPeersReady(mediaId)}'
      ' -> PLAY');
  server.play();

  while (true) {
    await Future<void>.delayed(const Duration(seconds: 1));
    final s = server.snapshot;
    final pos = s.positionAt(monotonicNowUs());
    print('status rev=${s.rev} ${s.status.name} '
        'pos=${(pos / 1e6).toStringAsFixed(2)}s '
        'peers=${server.peers.length}');
    // Auto-advance at end of track (host-side policy, PROTOCOL.md §5).
    if (s.status == PlaybackStatus.playing) {
      final item =
          server.playlist.firstWhere((i) => i.mediaId == s.mediaId);
      final dur = item.durationUs;
      if (dur != null && pos >= dur) {
        final list = server.playlist;
        final next =
            list[(list.indexOf(item) + 1) % list.length].mediaId;
        print('track ended -> setMedia($next) + play');
        server.setMedia(next);
        server.play();
      }
    }
  }
}
