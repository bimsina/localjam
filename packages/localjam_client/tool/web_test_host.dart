/// The VM half of `test/web/guest_engine_web_test.dart`: a real
/// [JamHostServer] for the browser guest to join (a browser cannot host,
/// PROTOCOL.md goal 5), run by `tool/web_engine_test.sh` beside
/// `flutter test --platform chrome`, which has no `spawnHybridUri`.
///
/// Serves two items: a 20 s 440 Hz WAV every browser decodes, and bytes
/// that are no audio at all (labelled `audio/mpeg`) — sha256-verified like
/// any item, but undecodable, the stand-in for Ogg in Safari (§3.1). Prints
/// one JSON line (`joinUri`, `control`, the two media ids) and then answers
/// a small control plane on loopback, with CORS so the test page can call
/// it:
///
/// * `GET /ready/<mediaId>` → `{"states": {peerId: none|fetching|ready}}`
/// * `POST /play` → starts the room (§5.3 scheduled start); the snapshot
/// * `GET /quit` → shuts down
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:localjam_net/localjam_net.dart';

/// A 16-bit stereo PCM WAV of a quiet 440 Hz sine.
Uint8List _wav({int sampleRate = 44100, int seconds = 20}) {
  final frames = sampleRate * seconds;
  final dataBytes = frames * 4;
  final b = ByteData(44 + dataBytes);
  void ascii(int offset, String s) {
    for (var i = 0; i < s.length; i++) {
      b.setUint8(offset + i, s.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  b.setUint32(4, 36 + dataBytes, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  b.setUint32(16, 16, Endian.little);
  b.setUint16(20, 1, Endian.little);
  b.setUint16(22, 2, Endian.little);
  b.setUint32(24, sampleRate, Endian.little);
  b.setUint32(28, sampleRate * 4, Endian.little);
  b.setUint16(32, 4, Endian.little);
  b.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  b.setUint32(40, dataBytes, Endian.little);
  for (var i = 0; i < frames; i++) {
    final s = (math.sin(2 * math.pi * 440 * i / sampleRate) * 3000).round();
    b.setInt16(44 + 4 * i, s, Endian.little);
    b.setInt16(46 + 4 * i, s, Endian.little);
  }
  return b.buffer.asUint8List();
}

Future<void> main() async {
  final dir = await Directory.systemTemp.createTemp('localjam_web_engine');
  final wavFile = File('${dir.path}/tone.wav')..writeAsBytesSync(_wav());
  final rng = math.Random(11);
  final junkFile = File('${dir.path}/junk.mp3')
    ..writeAsBytesSync([for (var i = 0; i < 64 * 1024; i++) rng.nextInt(256)]);

  final host = JamHostServer(sessionName: 'Web Engine', policy: JamPolicy.open);
  await host.start(address: InternetAddress.loopbackIPv4);
  final wav = await JamHostServer.describeFile(
    wavFile,
    kind: MediaKind.audio,
    mime: 'audio/wav',
    durationUs: 20000000,
  );
  host.addMedia(wav, wavFile);
  final junk = await JamHostServer.describeFile(
    junkFile,
    kind: MediaKind.audio,
    mime: 'audio/mpeg',
    durationUs: 10000000,
  );
  host.addMedia(junk, junkFile);
  host.setMedia(wav.mediaId);

  final control = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final done = Completer<void>();
  control.listen((request) async {
    final response = request.response
      ..headers.set('Access-Control-Allow-Origin', '*')
      ..headers.contentType = ContentType.json;
    final segments = request.uri.pathSegments;
    Object? body;
    if (segments.length == 2 && segments.first == 'ready') {
      body = {
        'states': {
          for (final peer in host.peers)
            peer.peerId: host.peerMediaState(peer.peerId, segments[1]).name,
        },
      };
    } else if (segments.length == 1 && segments.first == 'play') {
      host.play();
      body = host.snapshot.toJson();
    } else if (segments.length == 1 && segments.first == 'quit') {
      body = {'bye': true};
      if (!done.isCompleted) done.complete();
    } else {
      response.statusCode = HttpStatus.notFound;
    }
    response.write(jsonEncode(body));
    await response.close();
  });

  stdout.writeln(
    jsonEncode({
      'joinUri':
          '${host.joinLinkFor(InternetAddress.loopbackIPv4).toHttpUri()}',
      'control': 'http://127.0.0.1:${control.port}',
      'wav': wav.mediaId,
      'junk': junk.mediaId,
    }),
  );
  // Ends on /quit, or on its own after 5 minutes (a crashed test run).
  await done.future.timeout(const Duration(minutes: 5), onTimeout: () {});
  await control.close(force: true);
  await host.close();
  await dir.delete(recursive: true);
  exit(0);
}
