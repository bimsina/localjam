/// Test media and network fixtures generated in code.
///
/// `test-media/` is gitignored device-testing material, so a test that read
/// `../../test-media/track1.m4a` passed on one laptop and failed on every
/// clean clone (and in CI). These are written fresh per test instead: short
/// PCM WAVs — every platform's decoder and the tag reader accept them — each
/// with a different tone, so each has different bytes and therefore its own
/// content-hashed media id (§6.1).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_client/localjam_client.dart';

/// A mono 16-bit PCM WAV of a [hz] sine, [ms] long at [sampleRate].
Uint8List wavBytes({int hz = 440, int ms = 3000, int sampleRate = 8000}) {
  final frames = sampleRate * ms ~/ 1000;
  final dataBytes = frames * 2;
  final bytes = ByteData(44 + dataBytes);
  void ascii(int offset, String text) {
    for (var i = 0; i < text.length; i++) {
      bytes.setUint8(offset + i, text.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  bytes.setUint32(4, 36 + dataBytes, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  bytes
    ..setUint32(16, 16, Endian.little) // fmt chunk size
    ..setUint16(20, 1, Endian.little) // PCM
    ..setUint16(22, 1, Endian.little) // mono
    ..setUint32(24, sampleRate, Endian.little)
    ..setUint32(28, sampleRate * 2, Endian.little) // byte rate
    ..setUint16(32, 2, Endian.little) // block align
    ..setUint16(34, 16, Endian.little); // bits per sample
  ascii(36, 'data');
  bytes.setUint32(40, dataBytes, Endian.little);
  for (var i = 0; i < frames; i++) {
    final sample = (math.sin(2 * math.pi * hz * i / sampleRate) * 8000).round();
    bytes.setInt16(44 + i * 2, sample, Endian.little);
  }
  return bytes.buffer.asUint8List();
}

/// Writes [count] distinct short tracks (`track1.wav`, …) into a temp
/// directory removed after the test, and returns their paths.
List<String> makeTestTracks({int count = 3}) {
  final dir = Directory.systemTemp.createTempSync('localjam_app_media');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return [
    for (var i = 0; i < count; i++)
      (File(
        '${dir.path}/track${i + 1}.wav',
      )..writeAsBytesSync(wavBytes(hz: 330 + 110 * i))).path,
  ];
}

/// A network interface the host engine can be handed instead of the
/// machine's own, so "does the room have a LAN address?" is the test's
/// decision rather than the CI runner's.
class FakeInterface implements NetworkInterface {
  FakeInterface(this.name, List<String> addresses)
    : addresses = [for (final a in addresses) _FakeAddress(InternetAddress(a))];

  @override
  final String name;

  @override
  final List<InterfaceAddress> addresses;

  @override
  int get index => 7;
}

/// An interface address that is just an [InternetAddress] on a /24.
class _FakeAddress implements InterfaceAddress {
  _FakeAddress(this._address);

  final InternetAddress _address;

  @override
  int get prefixLength => 24;

  @override
  InternetAddress? get broadcast => null;

  @override
  String get address => _address.address;

  @override
  String get host => _address.host;

  @override
  Uint8List get rawAddress => _address.rawAddress;

  @override
  InternetAddressType get type => _address.type;

  @override
  bool get isLoopback => _address.isLoopback;

  @override
  bool get isLinkLocal => _address.isLinkLocal;

  @override
  bool get isMulticast => _address.isMulticast;

  @override
  Future<InternetAddress> reverse() => _address.reverse();

  @override
  String toString() => _address.toString();
}

/// Points [JamHostEngine]'s interface scan at [interfaces] for this test.
///
/// A room's link then names only the made-up LAN addresses (never loopback
/// beside them), so a guest joining in such a test dials loopback itself.
void fakeLan(List<NetworkInterface> interfaces) {
  final previous = JamHostEngine.networkInterfaceLister;
  JamHostEngine.networkInterfaceLister = () async => interfaces;
  addTearDown(() => JamHostEngine.networkInterfaceLister = previous);
}

/// An asset bundle holding exactly [files] (asset key → UTF-8 text), with
/// the binary `AssetManifest.bin` a real build writes listing them — what
/// `WebGuestBundle` reads the player out of.
///
/// [gate], when given, holds every read until it completes, so a test can
/// see a room open while its player is still loading. [loads] counts the
/// file reads (the manifest's not included).
class FakeAssetBundle extends AssetBundle {
  FakeAssetBundle(this.files, {this.gate, this.manifestError});

  final Map<String, String> files;
  final Completer<void>? gate;

  /// Thrown by the manifest read when set: a bundle that cannot be read.
  final Object? manifestError;

  int loads = 0;

  @override
  Future<ByteData> load(String key) async {
    await gate?.future;
    if (key == 'AssetManifest.bin') {
      if (manifestError != null) throw manifestError!;
      return const StandardMessageCodec().encodeMessage({
        for (final key in files.keys)
          key: [
            {'asset': key},
          ],
      })!;
    }
    final text = files[key];
    if (text == null) throw StateError('no asset $key');
    loads++;
    return ByteData.sublistView(Uint8List.fromList(utf8.encode(text)));
  }

  @override
  Future<T> loadStructuredData<T>(
    String key,
    Future<T> Function(String value) parser,
  ) async => parser(await loadString(key));
}

/// A web player as `tool/build_web_guest.sh` leaves it, placeholders
/// included, plus one asset of the app's own that is not part of it.
Map<String, String> webPlayerAssets({String index = '<!doctype html>player'}) =>
    {
      'assets/web/.gitkeep': '',
      'assets/web/index.html': index,
      'assets/web/main.dart.js': 'main();',
      'assets/web/canvaskit/.gitkeep': '',
      'assets/web/canvaskit/canvaskit.wasm': 'wasm',
      'assets/web/assets/NOTICES': 'licences',
      'assets/web/assets/fonts/MaterialIcons-Regular.otf': 'otf',
      'assets/brand/logo.svg': '<svg/>',
    };
