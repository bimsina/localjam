/// Shared plumbing for engine tests: a mocked `localjam_audio` method
/// channel (the native side does not exist under flutter_test), deterministic
/// media files, a polling waiter for real-socket loopback tests, and a proxy
/// that hands a guest's session clock to the test.
library;

import 'dart:async';
import 'dart:convert' show ascii;
import 'dart:io';
import 'dart:math';
import 'dart:typed_data' show BytesBuilder, Uint8List;

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_client/localjam_client.dart'
    show CatalogEntry, JamCatalogSource;
import 'package:localjam_net/localjam_net.dart' show JoinLink;

const audioChannel = MethodChannel('localjam_audio');

/// Installs a mock `localjam_audio` handler answering every method the
/// engines use, recording calls in the returned log. [durationUs] answers
/// `load` and `probeDuration`; [routeId] answers `currentRouteId`;
/// `positionUs` answers null ("nothing playing") so the drift loop stays
/// quiet and deterministic.
List<MethodCall> mockAudioChannel({
  int durationUs = 60_000_000,
  bool probeKnowsDuration = true,
  String? Function()? routeId,
}) {
  final log = <MethodCall>[];
  var nativeNow = 1_000_000;
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(audioChannel, (call) async {
        log.add(call);
        return switch (call.method) {
          'nowUs' => nativeNow += 100,
          'load' => durationUs,
          'probeDuration' => probeKnowsDuration ? durationUs : null,
          'currentRouteId' => routeId?.call(),
          'positionUs' => null,
          'outputLatencyUs' => 0,
          _ => null, // playAt, pause, stop, setRate, dispose.
        };
      });
  addTearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(audioChannel, null);
  });
  return log;
}

const audioEventChannel = EventChannel('localjam_audio/events');

/// Mocks the native audio event channel and returns a function that pushes
/// one event map (`{'type': 'routeChanged', ...}`) to whichever player is
/// listening. Events pushed before anyone listens are delivered on listen.
/// One listening player per test: the channel has one handler.
void Function(Map<String, Object?> event) mockAudioEvents() {
  MockStreamHandlerEventSink? sink;
  final pending = <Map<String, Object?>>[];
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockStreamHandler(
        audioEventChannel,
        MockStreamHandler.inline(
          onListen: (Object? _, MockStreamHandlerEventSink events) {
            sink = events;
            for (final event in pending) {
              events.success(event);
            }
            pending.clear();
          },
          onCancel: (Object? _) => sink = null,
        ),
      );
  addTearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(audioEventChannel, null),
  );
  return (event) {
    final events = sink;
    if (events == null) {
      pending.add(event);
    } else {
      events.success(event);
    }
  };
}

/// A network interface the host's LAN scan can be handed in tests.
class FakeNetworkInterface implements NetworkInterface {
  FakeNetworkInterface(this.name, List<String> addresses, {this.index = 1})
    : addresses = [for (final a in addresses) _FakeInterfaceAddress(a)];

  @override
  final String name;

  @override
  final int index;

  @override
  final List<InterfaceAddress> addresses;
}

class _FakeInterfaceAddress implements InterfaceAddress {
  _FakeInterfaceAddress(String address) : _address = InternetAddress(address);

  final InternetAddress _address;

  @override
  int get prefixLength => 24;

  @override
  InternetAddress? get broadcast => null;

  @override
  InternetAddressType get type => _address.type;

  @override
  String get address => _address.address;

  @override
  String get host => _address.host;

  @override
  Uint8List get rawAddress => _address.rawAddress;

  @override
  bool get isLoopback => _address.isLoopback;

  @override
  bool get isLinkLocal => _address.isLinkLocal;

  @override
  bool get isMulticast => _address.isMulticast;

  @override
  Future<InternetAddress> reverse() => _address.reverse();
}

/// Deterministic pseudo-random media payload.
Uint8List makeMediaBytes(int length, {int seed = 42}) {
  final rng = Random(seed);
  return Uint8List.fromList([
    for (var i = 0; i < length; i++) rng.nextInt(256),
  ]);
}

/// Writes [bytes] to a fresh temp file (cleaned up after the test).
Future<File> writeTempMedia(
  Uint8List bytes, {
  String name = 'track.mp3',
}) async {
  final dir = await Directory.systemTemp.createTemp('localjam_client_test');
  addTearDown(() => dir.delete(recursive: true));
  final file = File('${dir.path}/$name');
  await file.writeAsBytes(bytes);
  return file;
}

/// A 1×1 red PNG — the embedded-artwork payload for tagged fixtures.
final Uint8List tinyPngBytes = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, //
  0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53, 0xDE, 0x00, 0x00, 0x00, //
  0x0C, 0x49, 0x44, 0x41, 0x54, 0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00, //
  0x00, 0x00, 0x03, 0x00, 0x01, 0x9E, 0xDE, 0x81, 0x4A, 0x00, 0x00, 0x00, //
  0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

/// A generated, genuinely parseable MP3 (~1 s: empty ID3v2.4 header + MPEG-1
/// Layer III frames) carrying ID3 tags and embedded PNG artwork — no
/// checked-in binaries (`test-media/` is gitignored, local device-testing
/// material only). Mirrors localjam_net's test fixture generator.
Future<File> makeTaggedMp3({
  String title = 'Night Drive',
  String artist = 'The Localhosts',
  String album = 'Loopback Sessions',
}) async {
  final dir = await Directory.systemTemp.createTemp('localjam_fixture');
  addTearDown(() => dir.delete(recursive: true));
  final frame = Uint8List(417)..setRange(0, 4, [0xFF, 0xFB, 0x90, 0x00]);
  final builder = BytesBuilder()
    ..add([0x49, 0x44, 0x33, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]);
  for (var i = 0; i < 40; i++) {
    builder.add(frame);
  }
  final file = File('${dir.path}/tagged.mp3');
  await file.writeAsBytes(builder.takeBytes());
  updateMetadata(file, (metadata) {
    final mp3 = metadata as Mp3Metadata;
    mp3.songName = title;
    mp3.leadPerformer = artist;
    mp3.album = album;
    mp3.pictures.add(
      Picture(tinyPngBytes, 'image/png', PictureType.coverFront),
    );
  });
  return file;
}

/// A [JamCatalogSource] over files on disk (a temp dir of generated media):
/// what a host's library looks like to the engine, without Android. Each
/// file is listed under its own `c_<n>` id with the [CatalogEntry] given;
/// [add] and [remove] change what the next [list] says; [opens] counts
/// [open] calls per id; [failList] makes the next [list] throw it;
/// [openGate] holds every [open] and [artGate] every [openForArtwork]
/// until completed.
class FakeCatalogSource extends JamCatalogSource {
  final List<({CatalogEntry entry, File file})> _songs = [];
  final Map<String, int> opens = {};
  Object? failList;
  Completer<void>? openGate;
  Completer<void>? artGate;
  var _next = 1;

  /// Lists [file] as a new song; returns its catalog id.
  String add(
    File file, {
    String? title,
    String? artist,
    String? album,
    int? durationUs,
    bool? hasArtwork,
  }) {
    final id = 'c_${_next++}';
    _songs.add((
      entry: CatalogEntry(
        catalogId: id,
        title: title ?? file.uri.pathSegments.last,
        artist: artist,
        album: album,
        durationUs: durationUs,
        sizeBytes: file.lengthSync(),
        hasArtwork: hasArtwork,
      ),
      file: file,
    ));
    return id;
  }

  void remove(String catalogId) =>
      _songs.removeWhere((s) => s.entry.catalogId == catalogId);

  File fileOf(String catalogId) =>
      _songs.firstWhere((s) => s.entry.catalogId == catalogId).file;

  @override
  Future<List<CatalogEntry>> list() async {
    final failure = failList;
    if (failure != null) {
      failList = null;
      throw failure;
    }
    return [for (final s in _songs) s.entry];
  }

  @override
  Future<File?> openForArtwork(String catalogId) async {
    await artGate?.future;
    return open(catalogId);
  }

  @override
  Future<File?> open(String catalogId) async {
    opens[catalogId] = (opens[catalogId] ?? 0) + 1;
    await openGate?.future;
    for (final s in _songs) {
      if (s.entry.catalogId == catalogId) {
        return s.file.existsSync() ? s.file : null;
      }
    }
    return null;
  }
}

/// A fresh temp directory (cleaned up after the test).
Future<Directory> makeTempDir() async {
  final dir = await Directory.systemTemp.createTemp('localjam_client_cache');
  addTearDown(() => dir.delete(recursive: true));
  return dir;
}

/// Polls [condition] every 10 ms until true or [timeout] elapses.
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

/// A loopback TCP proxy in front of a host that keeps every §4 clock pong
/// from reaching the guest, so the guest's `ClockSync` only ever sees the
/// readings a test hands it (`ClockSync.addSample`) — and a test about
/// how many readings were accepted, and when, no longer depends on how
/// fast this machine answers pings under load.
///
/// Inside the host→guest WebSocket stream each `clock_pong` frame is renamed
/// to a type of the same length the guest ignores (§2: unknown types are
/// skipped), so the connection stays live — any frame is liveness (§3.3) —
/// while its readings never land. Everything else (the handshake, every
/// other frame, the media plane) passes untouched. Point the guest at
/// [joinUriFor].
class PongMutingProxy {
  PongMutingProxy._(this._server, this._targetPort);

  final ServerSocket _server;
  final int _targetPort;
  final List<Socket> _sockets = [];

  /// How many pongs were kept from the guest so far.
  int mutedPongs = 0;

  /// Starts a proxy in front of the host listening on loopback [targetPort].
  static Future<PongMutingProxy> start(int targetPort) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final proxy = PongMutingProxy._(server, targetPort);
    server.listen(
      proxy._onClient,
      // A connection reset before it was accepted (a client that gave up
      // under load and retried): nothing to forward, nothing to fail.
      onError: (Object _) {},
    );
    addTearDown(proxy.close);
    return proxy;
  }

  /// [joinUri] (the host's own, either form), pointed at this proxy
  /// instead.
  Uri joinUriFor(Uri joinUri) => JoinLink.fromUri(joinUri)!
      .copyWith(
        hosts: [InternetAddress.loopbackIPv4.address],
        port: _server.port,
      )
      .toLocaljamUri();

  Future<void> _onClient(Socket client) async {
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
    _sockets
      ..add(client)
      ..add(upstream);
    void forward(Socket to, List<int> bytes) {
      try {
        to.add(bytes);
      } catch (_) {
        // The other side is gone; its own listener tears this one down.
      }
    }

    client.listen(
      (bytes) => forward(upstream, bytes),
      onDone: upstream.destroy,
      onError: (Object _) => upstream.destroy(),
      cancelOnError: true,
    );
    final downstream = _Downstream(this, (bytes) => forward(client, bytes));
    upstream.listen(
      downstream.add,
      onDone: client.destroy,
      onError: (Object _) => client.destroy(),
      cancelOnError: true,
    );
  }

  Future<void> close() async {
    await _server.close();
    for (final socket in _sockets) {
      socket.destroy();
    }
  }
}

/// One host→guest byte stream through a [PongMutingProxy]: passed through
/// as is unless the HTTP response is a WebSocket upgrade, after which it is
/// cut into whole frames and every `clock_pong` text frame renamed.
class _Downstream {
  _Downstream(this._proxy, this._send);

  final PongMutingProxy _proxy;
  final void Function(List<int> bytes) _send;
  final List<int> _pending = [];

  /// null until the response head is in; then whether it upgraded.
  bool? _webSocket;

  static final List<int> _pong = ascii.encode('"type":"clock_pong"');
  static final List<int> _muted = ascii.encode('"type":"clock_pung"');
  static final List<int> _headEnd = ascii.encode('\r\n\r\n');

  void add(List<int> bytes) {
    if (_webSocket == false) return _send(bytes);
    _pending.addAll(bytes);
    if (_webSocket == null) {
      final end = _indexOf(_pending, _headEnd, 0);
      if (end < 0) return;
      final head = _pending.sublist(0, end + _headEnd.length);
      _webSocket = ascii
          .decode(head, allowInvalid: true)
          .startsWith('HTTP/1.1 101');
      _send(head);
      _pending.removeRange(0, head.length);
      if (_webSocket == false) {
        if (_pending.isNotEmpty) _send(List.of(_pending));
        _pending.clear();
        return;
      }
    }
    _drainFrames();
  }

  /// Sends every whole frame buffered (RFC 6455 §5.2; a server's frames are
  /// unmasked, and nothing here is compressed — localjam turns it off).
  void _drainFrames() {
    while (_pending.length >= 2) {
      final masked = _pending[1] & 0x80 != 0;
      var length = _pending[1] & 0x7f;
      var offset = 2;
      if (length == 126) {
        if (_pending.length < 4) return;
        length = (_pending[2] << 8) | _pending[3];
        offset = 4;
      } else if (length == 127) {
        if (_pending.length < 10) return;
        length = 0;
        for (var i = 2; i < 10; i++) {
          length = (length << 8) | _pending[i];
        }
        offset = 10;
      }
      if (masked) offset += 4;
      if (_pending.length < offset + length) return;
      final frame = _pending.sublist(0, offset + length);
      _pending.removeRange(0, frame.length);
      final textFrame = frame[0] & 0x0f == 0x1;
      if (textFrame && !masked) {
        final at = _indexOf(frame, _pong, offset);
        if (at >= 0) {
          frame.setRange(at, at + _muted.length, _muted);
          _proxy.mutedPongs++;
        }
      }
      _send(frame);
    }
  }

  static int _indexOf(List<int> haystack, List<int> needle, int from) {
    for (var i = from; i <= haystack.length - needle.length; i++) {
      var match = true;
      for (var j = 0; j < needle.length; j++) {
        if (haystack[i + j] != needle[j]) {
          match = false;
          break;
        }
      }
      if (match) return i;
    }
    return -1;
  }
}
