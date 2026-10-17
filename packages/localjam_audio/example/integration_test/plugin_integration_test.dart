// On-device tests of the native localjam_audio implementation.
//
// Since integration tests run in a full Flutter application, they can interact
// with the host side of a plugin implementation, unlike Dart unit tests.
//
//   flutter test integration_test -d macos
//   flutter test integration_test -d <simulator-or-device-id>
//
// Everything played here is generated digital silence.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:localjam_audio/localjam_audio.dart';

/// A 16-bit PCM WAV of digital silence.
Uint8List silentWav({
  required int sampleRate,
  required int frames,
  int channels = 1,
}) {
  final blockAlign = channels * 2;
  final dataBytes = frames * blockAlign;
  final header = ByteData(44)
    ..setUint32(0, 0x52494646) // 'RIFF'
    ..setUint32(4, 36 + dataBytes, Endian.little)
    ..setUint32(8, 0x57415645) // 'WAVE'
    ..setUint32(12, 0x666d7420) // 'fmt '
    ..setUint32(16, 16, Endian.little)
    ..setUint16(20, 1, Endian.little) // PCM
    ..setUint16(22, channels, Endian.little)
    ..setUint32(24, sampleRate, Endian.little)
    ..setUint32(28, sampleRate * blockAlign, Endian.little)
    ..setUint16(32, blockAlign, Endian.little)
    ..setUint16(34, 16, Endian.little)
    ..setUint32(36, 0x64617461) // 'data'
    ..setUint32(40, dataBytes, Endian.little);
  return Uint8List(44 + dataBytes)..setAll(0, header.buffer.asUint8List());
}

/// Writes a CAF of 8-bit mono LPCM silence at [sampleRate] holding [frames]
/// frames. The audio data is a hole (sparse file), so even > 2^32 frames
/// costs no disk space.
void writeSparseCaf(File file, {required int sampleRate, required int frames}) {
  final bytes = cafHeader(sampleRate: sampleRate, declaredFrames: frames);
  final raf = file.openSync(mode: FileMode.write);
  try {
    raf.writeFromSync(bytes);
    raf.truncateSync(bytes.length + frames); // extends with a hole
  } finally {
    raf.closeSync();
  }
}

/// A crafted CAF: the header declares [declaredFrames] frames of 8-bit mono
/// LPCM, but only 1000 bytes of audio follow — the ~1 KB upload that claims
/// to be days or aeons long.
void writeLyingCaf(File file, {required int declaredFrames}) {
  file.writeAsBytesSync([
    ...cafHeader(sampleRate: 44100, declaredFrames: declaredFrames),
    ...List.filled(1000, 0x80),
  ]);
}

/// CAF header (file header + 'desc' + 'data' chunk header) for 8-bit mono
/// LPCM at [sampleRate] whose data chunk declares [declaredFrames] frames.
Uint8List cafHeader({required int sampleRate, required int declaredFrames}) {
  final header = BytesBuilder()
    ..add('caff'.codeUnits)
    ..add([0, 1, 0, 0]); // version 1, flags 0
  final desc = ByteData(32)
    ..setFloat64(0, sampleRate.toDouble())
    ..setUint32(8, 0x6c70636d) // 'lpcm'
    ..setUint32(12, 2) // little-endian (irrelevant for 8-bit), integer
    ..setUint32(16, 1) // bytes per packet
    ..setUint32(20, 1) // frames per packet
    ..setUint32(24, 1) // channels
    ..setUint32(28, 8); // bits per channel
  header
    ..add('desc'.codeUnits)
    ..add((ByteData(8)..setInt64(0, 32)).buffer.asUint8List())
    ..add(desc.buffer.asUint8List())
    ..add('data'.codeUnits)
    ..add((ByteData(8)..setInt64(0, 4 + declaredFrames)).buffer.asUint8List())
    ..add([0, 0, 0, 0]); // edit count
  return header.takeBytes();
}

final bool isApple = Platform.isIOS || Platform.isMacOS;
final bool isDesktop = Platform.isLinux || Platform.isWindows;
final bool isAndroid = Platform.isAndroid;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late LocaljamAudio audio;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('localjam_audio_it');
    audio = LocaljamAudio();
  });

  tearDown(() async {
    await audio.dispose();
    await dir.delete(recursive: true);
  });

  Future<File> writeWav(String name, {required int sampleRate, int? frames}) =>
      File('${dir.path}/$name').writeAsBytes(
        silentWav(sampleRate: sampleRate, frames: frames ?? sampleRate * 3),
      );

  testWidgets('nowUs returns a monotonic native clock', (tester) async {
    final int a = await audio.nativeNowUs();
    final int b = await audio.nativeNowUs();
    expect(a, greaterThan(0));
    expect(b, greaterThanOrEqualTo(a));
  });

  testWidgets('calibrate produces a plausible offset', (tester) async {
    final Stopwatch clock = Stopwatch()..start();
    final NativeClockCalibration cal = await audio.calibrate(
      () => clock.elapsedMicroseconds,
    );
    expect(cal.rttUs, greaterThanOrEqualTo(0));
    // offset + dartNow should be close to nativeNow (within one second).
    final int predicted = clock.elapsedMicroseconds + cal.offsetUs;
    final int native = await audio.nativeNowUs();
    expect((native - predicted).abs(), lessThan(1000000));
  });

  group('probeDurationUs', () {
    testWidgets('reports exactly what load reports', (tester) async {
      final file = await writeWav('a.wav', sampleRate: 44100, frames: 132300);
      final probed = await audio.probeDurationUs(file.path);
      expect(probed, 3000000);
      expect(await audio.load(file.path), probed);
    });

    testWidgets('is null for unreadable and missing files', (tester) async {
      final garbage = File('${dir.path}/garbage.mp3')
        ..writeAsBytesSync(List.generate(4096, (i) => (i * 7919) & 0xff));
      expect(await audio.probeDurationUs(garbage.path), isNull);
      expect(await audio.probeDurationUs('${dir.path}/missing.wav'), isNull);
    });

    testWidgets('leaves a live schedule alone, even concurrently', (
      tester,
    ) async {
      final playing = await writeWav('playing.wav', sampleRate: 48000);
      final other = await writeWav('other.wav', sampleRate: 22050);
      await audio.load(playing.path);
      final anchor = await audio.nativeNowUs() + 300000;
      await audio.playAt(nativeTimeUs: anchor, positionUs: 0);
      await Future<void>.delayed(const Duration(milliseconds: 700));
      final before = await audio.positionUs();
      expect(before, isNotNull);

      final probes = await Future.wait([
        for (var i = 0; i < 4; i++) audio.probeDurationUs(other.path),
        audio.probeDurationUs(playing.path),
      ]);
      expect(probes, [...List.filled(4, 3000000), 3000000]);

      // Still playing the SAME schedule: position kept tracking the anchor.
      final now = await audio.nativeNowUs();
      final after = await audio.positionUs();
      expect(after, isNotNull);
      expect((after! - (now - anchor)).abs(), lessThan(100000));
      await audio.stop();
    });
  });

  testWidgets('currentRouteId is stable and does not need a loaded file', (
    tester,
  ) async {
    final first = await audio.currentRouteId();
    final second = await audio.currentRouteId();
    expect(second, first);
    if (isApple) {
      // Simulators and Macs always have some output route.
      expect(first, isNotNull);
      expect(first, isNotEmpty);
    }
  });

  testWidgets('a failed load leaves nothing loaded', (tester) async {
    final good = await writeWav('good.wav', sampleRate: 44100);
    await audio.load(good.path);
    final garbage = File('${dir.path}/garbage.wav')
      ..writeAsBytesSync(List.filled(64, 0x42));
    await expectLater(
      audio.load(garbage.path),
      throwsA(isA<PlatformException>()),
    );
    await expectLater(
      audio.playAt(nativeTimeUs: await audio.nativeNowUs(), positionUs: 0),
      throwsA(
        isA<PlatformException>().having((e) => e.code, 'code', 'no_file'),
      ),
    );
  }, skip: !(isApple || isDesktop || isAndroid));

  // Inputs that used to crash the whole app on iOS/macOS (NSException or a
  // Swift conversion trap), hang it, or size huge buffers from a crafted
  // header. Each must now be a PlatformException at worst.
  group('hardening', () {
    testWidgets('a file >= 2^32 frames schedules instead of trapping', (
      tester,
    ) async {
      // AVAudioFrameCount is UInt32: the whole-file remainder used to trap.
      final frames = (1 << 32) + 80000;
      final huge = File('${dir.path}/huge.caf');
      writeSparseCaf(huge, sampleRate: 8000, frames: frames);
      final expectedUs = frames * 1000000 ~/ 8000;
      expect(await audio.probeDurationUs(huge.path), expectedUs);
      expect(await audio.load(huge.path), expectedUs);
      final anchor = await audio.nativeNowUs() + 300000;
      await audio.playAt(nativeTimeUs: anchor, positionUs: 0);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(await audio.positionUs(), isNotNull);
      await audio.stop();
    }, skip: !isApple);

    testWidgets('a 32 Hz file is refused at load, not crashed on at play', (
      tester,
    ) async {
      // AVAudioPlayerNode never "sees an IO cycle" at such rates, and
      // play(at:) raised an uncatchable NSException.
      final low = await writeWav('low.wav', sampleRate: 32, frames: 96);
      await expectLater(
        audio.load(low.path),
        throwsA(
          isA<PlatformException>().having((e) => e.code, 'code', 'load_failed'),
        ),
      );
      expect(await audio.probeDurationUs(low.path), isNull);
    }, skip: !(isApple || isDesktop || isAndroid));

    testWidgets('a ~1 KB CAF declaring 2^62 / 2^40 frames is refused at load', (
      tester,
    ) async {
      // AVAudioFile reports whatever the header claims. 2^62 frames used to
      // load, and playAt then queued 2^32 scheduleSegment calls on the
      // plugin's serial queue: a hang, then out of memory — from a file any
      // peer can upload to a host.
      for (final declared in [1 << 62, 1 << 40]) {
        final lying = File('${dir.path}/lying_$declared.caf');
        writeLyingCaf(lying, declaredFrames: declared);
        await expectLater(
          audio.load(lying.path).timeout(const Duration(seconds: 5)),
          throwsA(
            isA<PlatformException>().having(
              (e) => e.code,
              'code',
              'load_failed',
            ),
          ),
        );
        expect(
          await audio
              .probeDurationUs(lying.path)
              .timeout(const Duration(seconds: 5)),
          isNull,
        );
      }
      // The plugin still works afterwards.
      final ok = await writeWav('after.wav', sampleRate: 44100);
      await audio.load(ok.path);
      await audio.playAt(
        nativeTimeUs: await audio.nativeNowUs() + 300000,
        positionUs: 0,
      );
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(await audio.positionUs(), greaterThan(0));
      await audio.stop();
    }, skip: !isApple);

    testWidgets(
      'a lying CAF inside the length bound schedules in bounded time',
      (tester) async {
        // 2^36 declared frames (64 segments of 2^30) over 1000 real bytes:
        // accepted, and playAt must neither hang nor crash, whatever the node
        // does when the data runs out.
        final lying = File('${dir.path}/lying_2^36.caf');
        writeLyingCaf(lying, declaredFrames: 1 << 36);
        try {
          await audio.load(lying.path).timeout(const Duration(seconds: 5));
          await audio
              .playAt(
                nativeTimeUs: await audio.nativeNowUs() + 300000,
                positionUs: 0,
              )
              .timeout(const Duration(seconds: 5));
          await Future<void>.delayed(const Duration(milliseconds: 500));
          await audio.positionUs().timeout(const Duration(seconds: 5));
          await audio.stop().timeout(const Duration(seconds: 5));
        } on PlatformException {
          // Refusing it is fine too; hanging or crashing is not.
        }
      },
      skip: !isApple,
    );

    testWidgets('a file with no frames is refused at load', (tester) async {
      final empty = await writeWav('empty.wav', sampleRate: 44100, frames: 0);
      await expectLater(
        audio.load(empty.path),
        throwsA(
          isA<PlatformException>().having((e) => e.code, 'code', 'load_failed'),
        ),
      );
      expect(await audio.probeDurationUs(empty.path), isNull);
    }, skip: !(isApple || isDesktop || isAndroid));

    testWidgets('sample rates outside 4–384 kHz are refused at load', (
      tester,
    ) async {
      // Same bounds as the desktop core, so a file plays everywhere or
      // nowhere. Header values are untrusted: on desktop a 2^31 Hz header
      // used to size a 1.7 GB decode buffer.
      for (final rate in [3999, 384001]) {
        final odd = await writeWav(
          'odd_$rate.wav',
          sampleRate: rate,
          frames: 400,
        );
        await expectLater(
          audio.load(odd.path),
          throwsA(
            isA<PlatformException>().having(
              (e) => e.code,
              'code',
              'load_failed',
            ),
          ),
        );
        expect(await audio.probeDurationUs(odd.path), isNull);
      }
      final edge = await writeWav('edge.wav', sampleRate: 4000, frames: 4000);
      expect(await audio.probeDurationUs(edge.path), 1000000);
      expect(await audio.load(edge.path), 1000000);
    }, skip: !(isApple || isDesktop || isAndroid));

    testWidgets('absurd playAt/setRate arguments are errors, not traps', (
      tester,
    ) async {
      final file = await writeWav('args.wav', sampleRate: 44100);
      await audio.load(file.path);
      final now = await audio.nativeNowUs();
      Matcher code(String c) =>
          throwsA(isA<PlatformException>().having((e) => e.code, 'code', c));

      // Int64 overflow in the late-anchor arithmetic.
      await expectLater(
        audio.playAt(nativeTimeUs: -9223372036854775808, positionUs: 0),
        code('bad_position'),
      );
      // Int64 overflow when the late-anchor advance is added.
      await expectLater(
        audio.playAt(nativeTimeUs: now - 1000, positionUs: 9223372036854775807),
        code('bad_position'),
      );
      // Non-finite / non-positive / out-of-range rates.
      for (final rate in [0.0, -1.0, double.nan, double.infinity, 64.0]) {
        await expectLater(
          audio.playAt(nativeTimeUs: now - 1000, positionUs: 0, rate: rate),
          code('bad_args'),
        );
        await expectLater(audio.setRate(rate), code('bad_args'));
      }

      // A far-future anchor overflowed the µs → host-tick conversion; now
      // anything more than an hour ahead is refused.
      await expectLater(
        audio.playAt(nativeTimeUs: 9223372036854775807, positionUs: 0),
        code('bad_args'),
      );
      await expectLater(
        audio.playAt(nativeTimeUs: now + 7200000000, positionUs: 0),
        code('bad_args'),
      );

      // And the engine still plays normally afterwards.
      final anchor = await audio.nativeNowUs() + 300000;
      await audio.playAt(nativeTimeUs: anchor, positionUs: 0);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(await audio.positionUs(), greaterThan(0));
      await audio.stop();
    }, skip: !(isApple || isDesktop || isAndroid));
  });
}
