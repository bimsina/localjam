/// The VM half of `test/web/guest_engine_web_test.dart`: a real
/// [JamHostServer] for the browser guest to join (a browser cannot host,
/// PROTOCOL.md goal 5), run by `tool/web_engine_test.sh` beside
/// `flutter test --platform chrome`, which has no `spawnHybridUri`.
///
/// Serves two items: a 20 s 440 Hz WAV every browser decodes, and bytes
/// that are no audio at all (labelled `audio/mpeg`) — sha256-verified like
/// any item, but undecodable, the stand-in for Ogg in Safari (§3.1). Prints
/// one JSON line (`joinUri`, `control`, the two media ids, whether this run
/// throttles) and then answers
/// a small control plane on loopback, with CORS so the test page can call
/// it:
///
/// * `GET /ready/<mediaId>` → `{"states": {peerId: none|fetching|ready}}`
/// * `POST /play` → starts the room (§5.3 scheduled start); the snapshot
/// * `GET /peers` → `{"now": ms, "events": [{t, kind, peerId, name}]}`:
///   every `peer_joined`/`peer_left` (§3.2) since start, `t` and `now` in
///   ms on this process's clock
/// * `POST /hide/<seconds>` → `{"at": ms}`: hides the test's tab for that
///   long — opens a blank tab in front of it over the Chrome DevTools
///   protocol, then brings the test's tab back and closes the blank one —
///   so the page runs as a background page (`document.hidden`), which is
///   what Chrome throttles. Needs the DevTools port, which
///   `tool/chrome_web_test.sh` writes to `$LOCALJAM_CHROME_DEVTOOLS_FILE`.
/// * `GET /quit` → shuts down
///
/// Lives until `/quit`, or `$LOCALJAM_WEB_TEST_MINUTES` (default 5) minutes.
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

  final clock = Stopwatch()..start();
  final peerLog = <Map<String, Object?>>[];
  host.events.listen((event) {
    if (event.kind != JamHostEventKind.peerJoined &&
        event.kind != JamHostEventKind.peerLeft) {
      return;
    }
    final entry = {
      't': clock.elapsedMilliseconds,
      'kind': event.kind == JamHostEventKind.peerJoined ? 'joined' : 'left',
      'peerId': event.peer?.peerId ?? event.peerId,
      'name': event.peer?.clientName,
    };
    peerLog.add(entry);
    stderr.writeln(
      'host: peer ${entry['kind']} ${entry['peerId']} '
      '${entry['name'] ?? ''} at ${entry['t']} ms',
    );
  });

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
    } else if (segments.length == 1 && segments.first == 'peers') {
      body = {'now': clock.elapsedMilliseconds, 'events': peerLog};
    } else if (segments.length == 2 && segments.first == 'hide') {
      final seconds = int.parse(segments[1]);
      body = {'at': clock.elapsedMilliseconds};
      unawaited(
        _hideTestTab(Duration(seconds: seconds)).catchError((Object e) {
          stderr.writeln('host: could not hide the test tab: $e');
        }),
      );
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
      // `tool/web_engine_test.sh --throttling`: Chrome throttles this run.
      'throttling':
          (Platform.environment['LOCALJAM_CHROME_THROTTLE'] ?? '').isNotEmpty,
    }),
  );
  // Ends on /quit, or on its own (a crashed test run).
  final minutes =
      int.tryParse(Platform.environment['LOCALJAM_WEB_TEST_MINUTES'] ?? '') ??
      5;
  await done.future.timeout(Duration(minutes: minutes), onTimeout: () {});
  await control.close(force: true);
  await host.close();
  await dir.delete(recursive: true);
  exit(0);
}

/// Puts a blank tab in front of the test's tab for [hidden], then brings
/// the test's tab back: in between it is a background page, hidden as a
/// tab the person switched away from is (headless Chrome counts its one
/// tab as visible otherwise). Chrome DevTools protocol, browser target.
Future<void> _hideTestTab(Duration hidden) async {
  final file = Platform.environment['LOCALJAM_CHROME_DEVTOOLS_FILE'];
  if (file == null) throw StateError('LOCALJAM_CHROME_DEVTOOLS_FILE unset');
  final port = int.parse(File(file).readAsStringSync().trim());
  final client = HttpClient();
  final Map<String, Object?> version;
  try {
    final request = await client.getUrl(
      Uri.parse('http://127.0.0.1:$port/json/version'),
    );
    final response = await request.close();
    final text = await response.transform(utf8.decoder).join();
    version = (jsonDecode(text) as Map).cast<String, Object?>();
  } finally {
    client.close();
  }
  final ws = await WebSocket.connect(
    version['webSocketDebuggerUrl']! as String,
  );
  var next = 0;
  final pending = <int, Completer<Map<String, Object?>>>{};
  ws.listen((raw) {
    final message = (jsonDecode(raw as String) as Map).cast<String, Object?>();
    final id = message['id'];
    if (id is int) pending.remove(id)?.complete(message);
  });
  Future<Map<String, Object?>> call(
    String method, [
    Map<String, Object?> params = const {},
  ]) async {
    final id = ++next;
    final reply = pending[id] = Completer<Map<String, Object?>>();
    ws.add(jsonEncode({'id': id, 'method': method, 'params': params}));
    final message = await reply.future.timeout(const Duration(seconds: 10));
    return (message['result'] as Map?)?.cast<String, Object?>() ?? {};
  }

  try {
    final targets = ((await call('Target.getTargets'))['targetInfos']! as List)
        .cast<Map>();
    final testTab = targets.firstWhere(
      (t) => t['type'] == 'page' && '${t['url']}'.startsWith('http'),
    )['targetId'];
    final blank = (await call('Target.createTarget', {
      'url': 'about:blank',
    }))['targetId'];
    await call('Target.activateTarget', {'targetId': blank});
    stderr.writeln('host: test tab hidden for ${hidden.inSeconds} s');
    await Future<void>.delayed(hidden);
    await call('Target.activateTarget', {'targetId': testTab});
    await call('Target.closeTarget', {'targetId': blank});
    stderr.writeln('host: test tab visible again');
  } finally {
    await ws.close();
  }
}
