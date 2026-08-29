/// Shared plumbing for engine tests: a mocked `localjam_audio` method
/// channel (the native side does not exist under flutter_test), deterministic
/// media files, and a polling waiter for real-socket loopback tests.
library;

import 'dart:io';
import 'dart:math';
import 'dart:typed_data' show BytesBuilder;

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const audioChannel = MethodChannel('localjam_audio');

/// Installs a mock `localjam_audio` handler answering every method the
/// engines use, recording calls in the returned log. [durationUs] answers
/// `load`; `positionUs` answers null ("nothing playing") so the drift loop
/// stays quiet and deterministic.
List<MethodCall> mockAudioChannel({int durationUs = 60_000_000}) {
  final log = <MethodCall>[];
  var nativeNow = 1_000_000;
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(audioChannel, (call) async {
        log.add(call);
        return switch (call.method) {
          'nowUs' => nativeNow += 100,
          'load' => durationUs,
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
