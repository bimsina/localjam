/// Shared helpers for the hardening suites: hosts and guests on loopback,
/// raw sockets that skip the client library, a scriptable fake host, and a
/// proxy that can go dark the way a dead host does.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:localjam_net/localjam_net.dart';
import 'package:test/test.dart';

Uint8List makeMediaBytes(int length, {int seed = 42}) {
  final rng = Random(seed);
  return Uint8List.fromList([
    for (var i = 0; i < length; i++) rng.nextInt(256),
  ]);
}

Future<File> writeTempMedia(
  Uint8List bytes, {
  String name = 'track.bin',
}) async {
  final dir = await Directory.systemTemp.createTemp('localjam_hardening');
  addTearDown(() => dir.delete(recursive: true));
  final file = File('${dir.path}/$name');
  await file.writeAsBytes(bytes);
  return file;
}

Future<JamHostServer> startHost({
  JamPolicy policy = JamPolicy.open,
  JamEndPolicy endPolicy = JamEndPolicy.pause,
  Duration silenceTimeout = const Duration(seconds: 10),
  Duration reconnectGrace = const Duration(seconds: 30),
  Duration livenessCheckInterval = const Duration(seconds: 1),
  Duration readinessWait = const Duration(milliseconds: 2500),
  int maxArtworkBytes = JamHostServer.defaultMaxArtworkBytes,
  Directory? uploadDir,
  int uploadBudgetBytes = JamHostServer.defaultUploadBudgetBytes,
  int maxPlaylistLength = JamHostServer.defaultMaxPlaylistLength,
  Duration uploadStallTimeout = const Duration(seconds: 30),
  int minUploadBytesPerSecond = 32 * 1024,
  int maxUploadsPerPeer = 2,
  int maxConnections = JamHostServer.defaultMaxConnections,
  int maxConnectionsPerRemote = JamHostServer.defaultMaxConnectionsPerRemote,
  int maxRequestHeaderBytes = 16 * 1024,
  int maxPreHelloFrameBytes = 16 * 1024,
  int maxPendingConnections = 8,
  Duration helloTimeout = const Duration(seconds: 10),
  int maxControlFrameBytes = 256 * 1024,
  int? maxInboundBytesPerSecond = JamHostServer.defaultMaxInboundBytesPerSecond,
  int? maxInboundFramesPerSecond =
      JamHostServer.defaultMaxInboundFramesPerSecond,
  int? maxRequestsPerSecond = JamHostServer.defaultMaxRequestsPerSecond,
}) async {
  final host = JamHostServer(
    sessionName: 'HardJam',
    policy: policy,
    endPolicy: endPolicy,
    silenceTimeout: silenceTimeout,
    reconnectGrace: reconnectGrace,
    livenessCheckInterval: livenessCheckInterval,
    readinessWait: readinessWait,
    maxArtworkBytes: maxArtworkBytes,
    uploadDir: uploadDir,
    uploadBudgetBytes: uploadBudgetBytes,
    maxPlaylistLength: maxPlaylistLength,
    uploadStallTimeout: uploadStallTimeout,
    minUploadBytesPerSecond: minUploadBytesPerSecond,
    maxUploadsPerPeer: maxUploadsPerPeer,
    maxConnections: maxConnections,
    maxConnectionsPerRemote: maxConnectionsPerRemote,
    maxRequestHeaderBytes: maxRequestHeaderBytes,
    maxPreHelloFrameBytes: maxPreHelloFrameBytes,
    maxPendingConnections: maxPendingConnections,
    helloTimeout: helloTimeout,
    maxControlFrameBytes: maxControlFrameBytes,
    maxInboundBytesPerSecond: maxInboundBytesPerSecond,
    maxInboundFramesPerSecond: maxInboundFramesPerSecond,
    maxRequestsPerSecond: maxRequestsPerSecond,
  );
  await host.start(address: InternetAddress.loopbackIPv4);
  addTearDown(host.close);
  return host;
}

Uri joinUriForPort(int port, {String token = 'anytoken'}) => Uri(
  scheme: 'localjam',
  host: 'join',
  queryParameters: {
    'v': '1',
    'host': '127.0.0.1',
    'port': '$port',
    'token': token,
    'name': 'Hard',
  },
);

Future<JamGuestClient> joinGuest(
  JamHostServer host, {
  String clientName = 'guest',
  String? clientId,
  Duration pingInterval = const Duration(seconds: 2),
  Duration? livenessTimeout,
}) async {
  final guest = await JamGuestClient.connect(
    host.joinUriFor(InternetAddress.loopbackIPv4),
    clientName: clientName,
    clientId: clientId,
    pingInterval: pingInterval,
    livenessTimeout: livenessTimeout,
  );
  addTearDown(guest.close);
  return guest;
}

Future<MediaItem> addTrack(
  JamHostServer host, {
  int seed = 1,
  int? durationUs,
}) async {
  final file = await writeTempMedia(makeMediaBytes(4096, seed: seed));
  final item = await JamHostServer.describeFile(
    file,
    kind: MediaKind.audio,
    durationUs: durationUs,
  );
  host.addMedia(item, file);
  return item;
}

Future<void> waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
  String reason = 'condition',
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for $reason');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// A TCP proxy in front of a host that can go dark: after [blackhole], every
/// connection open at that moment keeps its sockets open but forwards
/// nothing, in either direction, and propagates no close — exactly what a
/// guest sees when the host's battery dies, it walks out of range, or its
/// Wi-Fi is switched off (no FIN ever arrives). Connections made AFTER the
/// blackhole are forwarded normally, which stands in for the host coming
/// back.
class BlackholeProxy {
  BlackholeProxy._(this._server, this._targetPort) {
    _server.listen(_accept);
  }

  static Future<BlackholeProxy> start(int targetPort) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final proxy = BlackholeProxy._(server, targetPort);
    addTearDown(proxy.close);
    return proxy;
  }

  final ServerSocket _server;
  final int _targetPort;
  final List<_ProxyPair> _pairs = [];

  int get port => _server.port;

  Future<void> _accept(Socket client) async {
    final Socket upstream;
    try {
      upstream = await Socket.connect(
        InternetAddress.loopbackIPv4,
        _targetPort,
      );
    } catch (_) {
      client.destroy();
      return;
    }
    final pair = _ProxyPair(client, upstream);
    _pairs.add(pair);
    client.listen(
      (data) {
        if (!pair.dark) upstream.add(data);
      },
      onDone: () {
        if (!pair.dark) upstream.destroy();
      },
      onError: (Object _) {},
    );
    upstream.listen(
      (data) {
        if (!pair.dark) client.add(data);
      },
      onDone: () {
        if (!pair.dark) client.destroy();
      },
      onError: (Object _) {},
    );
  }

  /// Goes dark on every connection open right now.
  void blackhole() {
    for (final pair in _pairs) {
      pair.dark = true;
    }
  }

  Future<void> close() async {
    await _server.close();
    for (final pair in _pairs) {
      pair.client.destroy();
      pair.upstream.destroy();
    }
  }
}

class _ProxyPair {
  _ProxyPair(this.client, this.upstream);
  final Socket client;
  final Socket upstream;
  bool dark = false;
}

/// A scriptable raw host for guest-side tests: answers `/ws` upgrades and
/// hands each decoded `hello` envelope (and its socket) to [onHello];
/// `/media/...` requests go to [onMedia].
class FakeHost {
  FakeHost._(this._server);

  static Future<FakeHost> start({
    required void Function(WebSocket ws, Map<String, Object?> hello) onHello,
    Future<void> Function(HttpRequest req)? onMedia,
    void Function(HttpRequest upgrade)? onUpgrade,
    void Function(WebSocket ws, Map<String, Object?> envelope)? onFrame,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = FakeHost._(server);
    addTearDown(fake.close);
    server.listen((req) async {
      if (req.uri.path == '/ws' && WebSocketTransformer.isUpgradeRequest(req)) {
        onUpgrade?.call(req);
        final ws = await WebSocketTransformer.upgrade(req);
        fake.sockets.add(ws);
        ws.listen((data) {
          if (data is! String) return;
          final envelope = (jsonDecode(data) as Map).cast<String, Object?>();
          fake.received.add(envelope);
          if (envelope['type'] == 'hello') onHello(ws, envelope);
          onFrame?.call(ws, envelope);
        }, onError: (Object _) {});
        return;
      }
      if (onMedia != null) {
        await onMedia(req);
        return;
      }
      req.response.statusCode = HttpStatus.notFound;
      await req.response.close();
    });
    return fake;
  }

  final HttpServer _server;
  final List<WebSocket> sockets = [];

  /// Every envelope any guest sent, in arrival order.
  final List<Map<String, Object?>> received = [];

  int get port => _server.port;

  Future<void> close() async {
    for (final ws in sockets) {
      unawaited(ws.close().catchError((Object _) {}));
    }
    await _server.close(force: true);
  }
}

/// A §3.1 welcome for fake hosts.
WelcomeMessage fakeWelcome({
  List<MediaItem> playlist = const [],
  String? uploadKey,
  bool hostAway = false,
}) => WelcomeMessage(
  sessionId: 's_fake',
  sessionName: 'Fake',
  selfPeerId: 'p_1',
  snapshot: PlaybackSnapshot.initial,
  playlist: playlist,
  permissions: const JamPermissions.initial(policy: JamPolicy.open),
  uploadKey: uploadKey,
  hostAway: hostAway,
);

/// Opens a raw control socket and completes the §3.1 handshake, returning
/// the socket and a queue of the frames that follow.
Future<(WebSocket, List<Map<String, Object?>>)> rawJoin(
  JamHostServer host, {
  Map<String, Object?> extraHello = const {},
  String? clientId,
}) async {
  final ws = await WebSocket.connect('ws://127.0.0.1:${host.port}/ws');
  addTearDown(() => ws.close().catchError((Object _) {}));
  final frames = <Map<String, Object?>>[];
  ws.listen((data) {
    if (data is String) {
      frames.add((jsonDecode(data) as Map).cast<String, Object?>());
    }
  }, onError: (Object _) {});
  ws.add(
    jsonEncode({
      'v': 1,
      'type': 'hello',
      'seq': 0,
      'payload': {
        'token': host.token,
        'clientName': 'raw',
        'clientKind': 'future',
        'clientId': ?clientId,
        ...extraHello,
      },
    }),
  );
  await waitFor(
    () => frames.any((f) => f['type'] == 'welcome'),
    reason: 'raw welcome',
  );
  return (ws, frames);
}

/// POSTs [bytes] to `/media` with whatever credential headers are given.
Future<int> rawUpload(
  JamHostServer host,
  Uint8List bytes, {
  String? uploadKey,
  Map<String, String> headers = const {},
}) async {
  final http = HttpClient();
  addTearDown(() => http.close(force: true));
  final req = await http.postUrl(
    Uri.parse('http://127.0.0.1:${host.port}/media'),
  );
  req.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${host.token}');
  req.headers.set('X-LocalJam-Kind', 'audio');
  if (uploadKey != null) {
    req.headers.set(JamGuestClient.uploadKeyHeader, uploadKey);
  }
  headers.forEach(req.headers.set);
  req.contentLength = bytes.length;
  req.add(bytes);
  final res = await req.close();
  await res.drain<void>();
  return res.statusCode;
}
