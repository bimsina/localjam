/// Shared plumbing for engine tests: a mocked `localjam_audio` method
/// channel (the native side does not exist under flutter_test), deterministic
/// media files, and a polling waiter for real-socket loopback tests.
library;

import 'dart:io';
import 'dart:math';

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
