/// The VM half of `web_smoke_test.dart`: a real [JamHostServer] for the
/// browser guest to join, run as a `spawnHybridUri` isolate (a browser
/// cannot host, PROTOCOL.md goal 5). Not a test suite itself.
///
/// Sends one map on start — the join URI, the media item and its bytes'
/// sha256, an artwork id, and the port of a TCP listener that accepts and
/// never answers (for the connect timeout) — then answers queries from the
/// browser: `['ready', mediaId]` → whether every peer reported `ready`
/// (§6.3), `['playlist']` → the host's playlist media ids.
library;

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:localjam_net/localjam_net.dart';
import 'package:stream_channel/stream_channel.dart';

/// A 1×1 PNG, as served from `/artwork/{id}` (§6.5).
final Uint8List _png = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, //
  0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53, 0xDE, 0x00, 0x00, 0x00, //
  0x0C, 0x49, 0x44, 0x41, 0x54, 0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00, //
  0x00, 0x00, 0x03, 0x00, 0x01, 0x9E, 0xDE, 0x81, 0x4A, 0x00, 0x00, 0x00, //
  0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

Future<void> hybridMain(StreamChannel<Object?> channel) async {
  final dir = await Directory.systemTemp.createTemp('localjam_web_smoke');
  // Big enough to arrive in many body chunks, so the browser's reader loop,
  // progress and idle bound all run.
  final rng = Random(7);
  final bytes = Uint8List.fromList([
    for (var i = 0; i < 1024 * 1024; i++) rng.nextInt(256),
  ]);
  final file = File('${dir.path}/track.bin');
  await file.writeAsBytes(bytes);

  final host = JamHostServer(sessionName: 'WebSmoke', policy: JamPolicy.open);
  await host.start(address: InternetAddress.loopbackIPv4);
  final item = await JamHostServer.describeFile(
    file,
    kind: MediaKind.audio,
    durationUs: 1_000_000,
  );
  host.addMedia(item, file);
  final artworkId = await host.addArtwork(_png, mime: 'image/png');

  // Accepts connections and never answers: a host that is there but asleep.
  final silent = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final held = <Socket>[];
  silent.listen(held.add);

  channel.sink.add({
    'joinUri': '${host.joinUriFor(InternetAddress.loopbackIPv4)}',
    'mediaId': item.mediaId,
    'sha256': item.sha256,
    'sizeBytes': item.sizeBytes,
    'artworkId': artworkId,
    'artworkBytes': _png.length,
    'silentPort': silent.port,
  });

  await for (final query in channel.stream) {
    final words = (query as List).cast<String>();
    switch (words.first) {
      case 'ready':
        channel.sink.add(host.allPeersReady(words[1]));
      case 'playlist':
        channel.sink.add([for (final i in host.playlist) i.mediaId]);
    }
  }
  for (final socket in held) {
    socket.destroy();
  }
  await silent.close();
  await host.close();
  await dir.delete(recursive: true);
}
