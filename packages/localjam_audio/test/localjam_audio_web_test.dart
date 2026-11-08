// Browser tests of the web platform (lib/localjam_audio_web.dart), run with
// `flutter test --platform chrome`. The plugin is registered on its own
// Registrar and the default (test) binary messenger is bridged to it, so the
// unchanged `LocaljamAudio` API talks to real Web Audio in headless Chrome.
@TestOn('browser')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'package:localjam_audio/localjam_audio.dart';
import 'package:localjam_audio/localjam_audio_web.dart';
import 'package:web/web.dart' as web;

import 'gapless_fixtures_web.dart';

/// A 16-bit PCM mono WAV of [frames] frames of a quiet 440 Hz sine.
Uint8List pcmWav({required int sampleRate, required int frames}) {
  final dataBytes = frames * 2;
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
  b.setUint32(16, 16, Endian.little); // fmt chunk size
  b.setUint16(20, 1, Endian.little); // PCM
  b.setUint16(22, 1, Endian.little); // channels
  b.setUint32(24, sampleRate, Endian.little);
  b.setUint32(28, sampleRate * 2, Endian.little); // byte rate
  b.setUint16(32, 2, Endian.little); // block align
  b.setUint16(34, 16, Endian.little); // bits per sample
  ascii(36, 'data');
  b.setUint32(40, dataBytes, Endian.little);
  for (var i = 0; i < frames; i++) {
    final sample = math.sin(2 * math.pi * 440 * i / sampleRate) * 0.1 * 32767;
    b.setInt16(44 + 2 * i, sample.round(), Endian.little);
  }
  return b.buffer.asUint8List();
}

/// A `blob:` URL of [bytes], as the page makes from prefetched media.
String blobUrl(Uint8List bytes, {String type = 'audio/wav'}) =>
    web.URL.createObjectURL(
      web.Blob(<JSAny>[bytes.toJS].toJS, web.BlobPropertyBag(type: type)),
    );

/// A WAV of [seconds] at 48 kHz as a blob URL.
String wavUrl(double seconds) =>
    blobUrl(pcmWav(sampleRate: 48000, frames: (seconds * 48000).round()));

int perfNowUs() => (web.window.performance.now() * 1000).floor();

Future<void> sleepMs(int ms) =>
    Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('localjam_audio');
  late LocaljamAudio audio;
  late StreamSubscription<LocaljamAudioEvent> subscription;
  final received = <LocaljamAudioEvent>[];
  var consumed = 0;

  /// The next event not yet consumed, waiting up to [timeout] for it.
  Future<LocaljamAudioEvent> nextEvent({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (received.length <= consumed) {
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException('no event within $timeout');
      }
      await sleepMs(10);
    }
    return received[consumed++];
  }

  /// Whether this Chrome lets an `AudioContext` run without a user gesture.
  /// Plain `flutter test --platform chrome` does not (autoplay policy); run
  /// with `CHROME_EXECUTABLE=tool/chrome_autoplay.sh` for the playback tests.
  var autoplay = false;

  /// Skips (visibly) a test that needs a running context when it cannot run.
  bool needsAutoplay() {
    if (autoplay) return false;
    markTestSkipped(
      'headless Chrome blocks Web Audio without a gesture; run with '
      'CHROME_EXECUTABLE=tool/chrome_autoplay.sh',
    );
    return true;
  }

  setUpAll(() async {
    final probe = web.AudioContext();
    unawaited(probe.resume().toDart.then((_) {}, onError: (Object _) {}));
    final deadline = perfNowUs() + 500000;
    while (probe.state != 'running' && perfNowUs() < deadline) {
      await sleepMs(10);
    }
    autoplay = probe.state == 'running';
    await probe.close().toDart;

    final registrar = Registrar();
    LocaljamAudioWeb.registerWith(registrar);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in ['localjam_audio', 'localjam_audio/events']) {
      messenger.setMockMessageHandler(name, (data) {
        final reply = Completer<ByteData?>();
        registrar.handleFrameworkMessage(name, data, reply.complete);
        return reply.future;
      });
    }
  });

  setUp(() {
    audio = LocaljamAudio();
    received.clear();
    consumed = 0;
    subscription = audio.events.listen(received.add);
  });

  tearDown(() async {
    await audio.dispose();
    // dispose keeps the page's context; each case starts from a fresh one.
    await LocaljamAudioWeb.debugInstance!.debugCloseContext();
    await subscription.cancel();
    LocaljamAudioWeb.debugIsIOSOverride = null;
    LocaljamAudioWeb.debugOutputLatencyOverrideSec = null;
  });

  web.AudioContext context() => LocaljamAudioWeb.debugInstance!.debugContext!;

  Matcher platformError(String code) =>
      isA<PlatformException>().having((e) => e.code, 'code', code);

  /// Schedules [positionUs] to be HEARD at [heardAtUs], as the Dart
  /// controller does (§7): the anchor shifted by the reported output
  /// latency. `positionUs` reads the heard position, so it then follows
  /// `positionUs + (now − heardAtUs) × rate`.
  ///
  /// A fresh context reports only `baseLatency` until it runs (Chrome here:
  /// 23 ms, then 55 ms with `outputLatency`), so a latency read before the
  /// first schedule may not be the one `playAt` maps with: schedule again
  /// with the settled value, as a re-apply would.
  Future<void> playHeardAt(
    int heardAtUs,
    int positionUs, {
    double rate = 1,
  }) async {
    var latencyUs = await audio.outputLatencyUs();
    for (var attempt = 0; attempt < 3; attempt++) {
      await audio.playAt(
        nativeTimeUs: heardAtUs - latencyUs,
        positionUs: positionUs,
        rate: rate,
      );
      final settled = await audio.outputLatencyUs();
      if ((settled - latencyUs).abs() <= 1000) return;
      latencyUs = settled;
    }
  }

  group('clock', () {
    test('nowUs is performance.now() in µs and never runs backwards', () async {
      var previous = await audio.nativeNowUs();
      final before = perfNowUs();
      for (var i = 0; i < 200; i++) {
        final now = await audio.nativeNowUs();
        expect(now, greaterThanOrEqualTo(previous));
        previous = now;
      }
      await sleepMs(50);
      final now = await audio.nativeNowUs();
      expect(now - before, inInclusiveRange(50000, 1000000));
      expect((now - perfNowUs()).abs(), lessThan(20000));
    });

    test('calibrate measures the offset to performance.now()', () async {
      // A Dart clock 5000 s ahead of performance.now(): offset ≈ −5e9. (On
      // JS `1 << 62` is 0; calibrate used it as its "no sample yet" RTT and
      // returned offset 0 for any clock.)
      final calibration = await audio.calibrate(() => perfNowUs() + 5000000000);
      expect(calibration.rttUs, lessThan(100000));
      expect(
        calibration.offsetUs,
        closeTo(-5000000000, calibration.rttUs + 1000),
      );
    });
  });

  group('load', () {
    test('a generated WAV blob returns its duration', () async {
      expect(await audio.load(wavUrl(0.5)), closeTo(500000, 100));
    });

    test('probeDuration matches load and leaves playback alone', () async {
      if (needsAutoplay()) return;
      final url = wavUrl(2);
      final loaded = await audio.load(url);
      await audio.playAt(nativeTimeUs: perfNowUs(), positionUs: 0);
      expect(await audio.probeDurationUs(wavUrl(0.25)), closeTo(250000, 100));
      expect(await audio.probeDurationUs(url), loaded);
      expect(await audio.positionUs(), isNotNull);
    });

    test('probeDuration: null for bytes load would refuse, an error when '
        'it could not tell', () async {
      final garbage = blobUrl(Uint8List.fromList(List.filled(4096, 7)));
      expect(await audio.probeDurationUs(garbage), isNull);
      expect(await audio.probeDurationUs(blobUrl(Uint8List(0))), isNull);
      // Unreadable is not undecodable: the caller may try again.
      await expectLater(
        audio.probeDurationUs('/no/such/file.wav'),
        throwsA(platformError('load_failed')),
      );
      final revoked = wavUrl(0.1);
      web.URL.revokeObjectURL(revoked);
      await expectLater(
        audio.probeDurationUs(revoked),
        throwsA(platformError('load_failed')),
      );
    });

    test('probeDuration keepForLoad: the next load of that URL takes the '
        'decoded buffer instead of decoding again', () async {
      final kept = wavUrl(0.5);
      final probed = await audio.probeDurationUs(kept, keepForLoad: true);
      expect(probed, closeTo(500000, 100));
      // The bytes are gone: only the kept buffer can satisfy this load.
      web.URL.revokeObjectURL(kept);
      expect(await audio.load(kept), probed);

      // Without keepForLoad nothing is kept.
      final plain = wavUrl(0.5);
      expect(await audio.probeDurationUs(plain), isNotNull);
      web.URL.revokeObjectURL(plain);
      await expectLater(
        audio.load(plain),
        throwsA(platformError('load_failed')),
      );

      // A load of another URL drops what was kept.
      final dropped = wavUrl(0.25);
      await audio.probeDurationUs(dropped, keepForLoad: true);
      await audio.load(wavUrl(0.25));
      web.URL.revokeObjectURL(dropped);
      await expectLater(
        audio.load(dropped),
        throwsA(platformError('load_failed')),
      );

      // A kept probe of undecodable bytes answers null and keeps nothing.
      final garbage = blobUrl(Uint8List.fromList(List.filled(4096, 7)));
      expect(await audio.probeDurationUs(garbage, keepForLoad: true), isNull);
      await expectLater(
        audio.load(garbage),
        throwsA(platformError('unsupported_format')),
      );
    });

    test('undecodable bytes → unsupported_format, nothing loaded', () async {
      await audio.load(wavUrl(0.5));
      final garbage = blobUrl(Uint8List.fromList(List.filled(4096, 7)));
      await expectLater(
        audio.load(garbage),
        throwsA(platformError('unsupported_format')),
      );
      await expectLater(
        audio.playAt(nativeTimeUs: perfNowUs(), positionUs: 0),
        throwsA(platformError('no_file')),
      );
    });

    test('an unfetchable URL → load_failed', () async {
      await expectLater(
        audio.load('/no/such/file.wav'),
        throwsA(platformError('load_failed')),
      );
      final revoked = wavUrl(0.1);
      web.URL.revokeObjectURL(revoked);
      await expectLater(
        audio.load(revoked),
        throwsA(platformError('load_failed')),
      );
      await expectLater(
        audio.load(blobUrl(Uint8List(0))),
        throwsA(platformError('load_failed')),
      );
    });

    test('load without a path → bad_args', () async {
      await expectLater(
        channel.invokeMethod<int>('load', <String, Object?>{}),
        throwsA(platformError('bad_args')),
      );
      await expectLater(
        channel.invokeMethod<int>('probeDuration', null),
        throwsA(platformError('bad_args')),
      );
    });
  });

  group('media position (MP3 gapless)', () {
    // 1 s MP3s from tool/gapless_fixtures.sh (embedded: the browser test
    // runner cannot read package files).
    Uint8List fixture(String base64) => base64Decode(base64);

    /// The browser's own decode of [bytes] at the context's rate.
    Future<web.AudioBuffer> rawDecode(Uint8List bytes) {
      final rate = context().sampleRate;
      final ctx = web.OfflineAudioContext(1.toJS, 1, rate);
      return ctx.decodeAudioData(Uint8List.fromList(bytes).buffer.toJS).toDart;
    }

    /// Plugin buffer frame i must be raw decode frame i + [shift].
    void expectShifted(web.AudioBuffer plugin, web.AudioBuffer raw, int shift) {
      final a = plugin.getChannelData(0).toDart;
      final b = raw.getChannelData(0).toDart;
      for (final i in [0, 1, 1000, 4410, 30001, 40000]) {
        expect(a[i], b[i + shift], reason: 'frame $i');
      }
    }

    test(
      'a LAME-tagged MP3 that Chrome decodes gaplessly is untouched',
      () async {
        final bytes = fixture(taggedMp3Base64);
        final durationUs = await audio.load(blobUrl(bytes, type: 'audio/mpeg'));
        final plugin = LocaljamAudioWeb.debugInstance!.debugBuffer!;
        expect(durationUs, closeTo(1000000, 30)); // exactly the 1 s encoded
        expectShifted(plugin, await rawDecode(bytes), 0);
      },
    );

    test(
      'a tagless MP3 drops FFmpeg\'s 529-frame decoder delay, as native does',
      () async {
        final bytes = fixture(taglessMp3Base64);
        final durationUs = await audio.load(blobUrl(bytes, type: 'audio/mpeg'));
        final plugin = LocaljamAudioWeb.debugInstance!.debugBuffer!;
        final raw = await rawDecode(bytes);
        final rate = raw.sampleRate;
        final shift = (529 * rate / 44100).round();
        expect(durationUs, closeTo((raw.length - shift) * 1e6 / rate, 1));
        expectShifted(plugin, raw, shift);
        // The moved-out tail is not media (checked once playAt can run).
        if (!autoplay) return;
        await expectLater(
          audio.playAt(
            nativeTimeUs: perfNowUs() + 200000,
            positionUs: ((raw.length - shift / 2) * 1e6 / rate).round(),
          ),
          throwsA(platformError('bad_position')),
        );
      },
    );
  });

  group('playAt', () {
    /// Samples positionUs for [ms] and checks each against the anchor
    /// formula: position = start + (now − anchor) × rate (clamped at 0),
    /// where [anchorUs] is when [startUs] is HEARD (see [playHeardAt]).
    Future<void> expectFollowsAnchor({
      required int anchorUs,
      required int startUs,
      double rate = 1,
      int ms = 600,
      int toleranceUs = 25000,
    }) async {
      final end = perfNowUs() + ms * 1000;
      var samples = 0;
      while (perfNowUs() < end) {
        final before = perfNowUs();
        final position = await audio.positionUs();
        final after = perfNowUs();
        expect(position, isNotNull);
        final expected = math.max(
          0,
          startUs + ((before + after) / 2 - anchorUs) * rate,
        );
        expect(
          position!,
          closeTo(expected, toleranceUs + (after - before)),
          reason: 'sample $samples',
        );
        samples++;
        await sleepMs(40);
      }
      expect(samples, greaterThan(5));
    }

    test('a future anchor: positionUs then advances with wall time', () async {
      if (needsAutoplay()) return;
      await audio.load(wavUrl(3));
      final anchorUs = perfNowUs() + 300000;
      await playHeardAt(anchorUs, 1000000);
      expect(context().state, 'running');
      await expectFollowsAnchor(anchorUs: anchorUs, startUs: 1000000);
    });

    test('positionUs is the position HEARD now: a schedule shifted by the '
        'output latency reads the room position, not latency ahead', () async {
      if (needsAutoplay()) return;
      // A route reporting 150 ms (Bluetooth-like), whatever this machine's
      // output device says, so the latency term is far outside tolerance.
      LocaljamAudioWeb.debugOutputLatencyOverrideSec = 0.150;
      final latencyUs = await audio.outputLatencyUs();
      expect(latencyUs, 150000);
      await audio.load(wavUrl(3));
      // The controller's convention (§7): to be HEARD at T, schedule the
      // anchor the output latency earlier.
      final heardAtUs = perfNowUs() + 400000;
      await audio.playAt(
        nativeTimeUs: heardAtUs - latencyUs,
        positionUs: 1000000,
      );
      // So a drift check reads P + (now − T), the room's position — not
      // P + (now − T) + latency, the frame due (still to be heard) now.
      await sleepMs(500);
      await expectFollowsAnchor(anchorUs: heardAtUs, startUs: 1000000);
    });

    test('a position-0 schedule reads 0 until it starts', () async {
      if (needsAutoplay()) return;
      await audio.load(wavUrl(3));
      final anchorUs = perfNowUs() + 400000;
      await playHeardAt(anchorUs, 0);
      expect(await audio.positionUs(), 0);
      await sleepMs(600);
      expect(await audio.positionUs(), closeTo(perfNowUs() - anchorUs, 30000));
    });

    test('a past anchor joins late at the advanced position', () async {
      if (needsAutoplay()) return;
      await audio.load(wavUrl(3));
      final anchorUs = perfNowUs() - 500000;
      await playHeardAt(anchorUs, 200000);
      await expectFollowsAnchor(anchorUs: anchorUs, startUs: 200000, ms: 400);
    });

    test('rate scales the timeline', () async {
      if (needsAutoplay()) return;
      await audio.load(wavUrl(3));
      final anchorUs = perfNowUs() + 100000;
      await playHeardAt(anchorUs, 0, rate: 1.5);
      await expectFollowsAnchor(
        anchorUs: anchorUs,
        startUs: 0,
        rate: 1.5,
        ms: 500,
      );
    });

    test('after a suspension the next schedule starts on time, not late by '
        'the whole suspension', () async {
      if (needsAutoplay()) return;
      await audio.load(wavUrl(4));
      await audio.playAt(nativeTimeUs: perfNowUs(), positionUs: 0);
      await sleepMs(300); // A confirmed output timestamp is in use.
      await context().suspend().toDart;
      expect(
        (await nextEvent()).kind,
        LocaljamAudioEventKind.interruptionBegan,
      );
      await sleepMs(2000);
      await context().resume().toDart;
      expect(
        (await nextEvent()).kind,
        LocaljamAudioEventKind.interruptionEnded,
      );
      // The context clock stood still for 2 s while performance time ran
      // on: a schedule mapped through the old offset would start ~2 s late
      // (position 0 all along).
      final anchorUs = perfNowUs() + 300000;
      await playHeardAt(anchorUs, 0);
      await sleepMs(400);
      await expectFollowsAnchor(anchorUs: anchorUs, startUs: 0, ms: 500);
    });

    test('playAt again replaces the schedule', () async {
      if (needsAutoplay()) return;
      await audio.load(wavUrl(3));
      await audio.playAt(nativeTimeUs: perfNowUs(), positionUs: 0);
      final anchorUs = perfNowUs() + 100000;
      await playHeardAt(anchorUs, 2000000);
      await expectFollowsAnchor(anchorUs: anchorUs, startUs: 2000000, ms: 300);
    });

    test('bad_args, bad_position and no_file', () async {
      if (needsAutoplay()) return;
      await expectLater(
        audio.playAt(nativeTimeUs: perfNowUs(), positionUs: 0),
        throwsA(platformError('no_file')),
      );
      await audio.load(wavUrl(1));
      for (final rate in [1 / 33, 33.0, 0.0, -1.0, double.nan]) {
        await expectLater(
          audio.playAt(nativeTimeUs: perfNowUs(), positionUs: 0, rate: rate),
          throwsA(platformError('bad_args')),
          reason: 'rate $rate',
        );
      }
      // The bounds themselves are fine (a future anchor: a late join at ×32
      // would run past this 1 s file).
      for (final rate in [1 / 32, 32.0]) {
        await audio.playAt(
          nativeTimeUs: perfNowUs() + 200000,
          positionUs: 0,
          rate: rate,
        );
      }
      await expectLater(
        audio.playAt(nativeTimeUs: perfNowUs() + 3601 * 1000000, positionUs: 0),
        throwsA(platformError('bad_args')),
      );
      await expectLater(
        channel.invokeMethod<void>('playAt', {'positionUs': 0}),
        throwsA(platformError('bad_args')),
      );
      await expectLater(
        audio.playAt(nativeTimeUs: perfNowUs() + 100000, positionUs: 1000000),
        throwsA(platformError('bad_position')),
      );
      await expectLater(
        audio.playAt(nativeTimeUs: perfNowUs() + 100000, positionUs: -1),
        throwsA(platformError('bad_position')),
      );
      // A late join that runs past the end is out of the file too.
      await expectLater(
        audio.playAt(nativeTimeUs: perfNowUs() - 2000000, positionUs: 0),
        throwsA(platformError('bad_position')),
      );
      expect(await audio.positionUs(), isNull);
    });
  });

  group('setRate, pause, stop', () {
    test('setRate bends the live timeline without a jump', () async {
      if (needsAutoplay()) return;
      await audio.load(wavUrl(4));
      final anchorUs = perfNowUs() + 100000;
      await playHeardAt(anchorUs, 0);
      await sleepMs(300);
      final before = (await audio.positionUs())!;
      await audio.setRate(2);
      final right = (await audio.positionUs())!;
      expect(right - before, inInclusiveRange(-1000, 30000), reason: 'jump');
      // The change lands ~50 ms ahead of the render clock; from then on the
      // position runs at ×2 against wall time.
      await sleepMs(150);
      final t1 = perfNowUs();
      final p1 = (await audio.positionUs())!;
      await sleepMs(300);
      final t2 = perfNowUs();
      final p2 = (await audio.positionUs())!;
      expect(p2 - p1, closeTo(2 * (t2 - t1), 15000));

      // A §5.4 slew: ±0.5 % bends without a jump either.
      final p3 = (await audio.positionUs())!;
      await audio.setRate(1.005);
      final p4 = (await audio.positionUs())!;
      expect(p4 - p3, inInclusiveRange(-1000, 30000));
    });

    test('setRate before the start changes the rate from the start', () async {
      if (needsAutoplay()) return;
      await audio.load(wavUrl(3));
      final anchorUs = perfNowUs() + 300000;
      await playHeardAt(anchorUs, 0);
      await audio.setRate(1.5);
      await sleepMs(350);
      final position = (await audio.positionUs())!;
      expect(position, closeTo((perfNowUs() - anchorUs) * 1.5, 30000));
    });

    test('setRate validates its rate, even with nothing playing', () async {
      await audio.setRate(1.005);
      for (final rate in [0.0, 1 / 64, 64.0]) {
        await expectLater(
          audio.setRate(rate),
          throwsA(platformError('bad_args')),
        );
      }
      await expectLater(
        channel.invokeMethod<void>('setRate', {'rate': 'fast'}),
        throwsA(platformError('bad_args')),
      );
    });

    test('pause and stop: position null, file kept, playAt resumes', () async {
      if (needsAutoplay()) return;
      expect(await audio.positionUs(), isNull);
      await audio.load(wavUrl(3));
      expect(await audio.positionUs(), isNull);
      await playHeardAt(perfNowUs(), 0);
      await sleepMs(100);
      expect(await audio.positionUs(), greaterThan(0));
      await audio.pause();
      expect(await audio.positionUs(), isNull);
      await playHeardAt(perfNowUs() + 100000, 500000);
      await sleepMs(200);
      expect(await audio.positionUs(), closeTo(600000, 40000));
      await audio.stop();
      expect(await audio.positionUs(), isNull);
      await audio.playAt(nativeTimeUs: perfNowUs() + 100000, positionUs: 0);
      expect(await audio.positionUs(), isNotNull);
      // No finish event for a schedule we stopped ourselves.
      await audio.stop();
      await sleepMs(200);
      expect(received, isEmpty);
    });
  });

  group('events', () {
    test('no gesture yet: playAt completes without playing and reports '
        'interruptionBegan on every call', () async {
      if (autoplay) {
        markTestSkipped(
          'needs a Chrome that blocks Web Audio without a gesture (plain '
          '`flutter test --platform chrome`)',
        );
        return;
      }
      await audio.load(wavUrl(1));
      for (var i = 0; i < 2; i++) {
        await audio.playAt(nativeTimeUs: perfNowUs(), positionUs: 0);
        expect(await audio.positionUs(), isNull);
        final event = await nextEvent();
        expect(event.kind, LocaljamAudioEventKind.interruptionBegan);
      }
    });

    test('playbackFinished when the buffer runs out', () async {
      if (needsAutoplay()) return;
      await audio.load(wavUrl(0.3));
      await audio.playAt(nativeTimeUs: perfNowUs() + 50000, positionUs: 0);
      final event = await nextEvent();
      expect(event.kind, LocaljamAudioEventKind.playbackFinished);
      expect(await audio.positionUs(), isNull);
    });

    test('context suspended → interruptionBegan, output stopped; running '
        'again → interruptionEnded, nothing resumed', () async {
      if (needsAutoplay()) return;
      await audio.load(wavUrl(3));
      await audio.playAt(nativeTimeUs: perfNowUs(), positionUs: 0);
      await context().suspend().toDart;
      final began = await nextEvent();
      expect(began.kind, LocaljamAudioEventKind.interruptionBegan);
      expect(await audio.positionUs(), isNull);
      await context().resume().toDart;
      final ended = await nextEvent();
      expect(ended.kind, LocaljamAudioEventKind.interruptionEnded);
      expect(await audio.positionUs(), isNull);
      // The client re-anchors.
      await audio.playAt(nativeTimeUs: perfNowUs() + 100000, positionUs: 0);
      expect(await audio.positionUs(), isNotNull);
    });
  });

  group('misc', () {
    test('outputLatencyUs is non-negative; currentRouteId is null', () async {
      expect(await audio.outputLatencyUs(), greaterThanOrEqualTo(0));
      expect(await audio.currentRouteId(), isNull);
    });

    test('setMuted (web-only) validates and keeps playback going', () async {
      if (needsAutoplay()) return;
      await audio.load(wavUrl(2));
      await audio.playAt(nativeTimeUs: perfNowUs(), positionUs: 0);
      await channel.invokeMethod<void>('setMuted', {'muted': true});
      expect(await audio.positionUs(), isNotNull);
      await channel.invokeMethod<void>('setMuted', {'muted': false});
      await expectLater(
        channel.invokeMethod<void>('setMuted', {'muted': 'yes'}),
        throwsA(platformError('bad_args')),
      );
    });

    test('an unknown method is not implemented', () async {
      await expectLater(
        channel.invokeMethod<void>('frobnicate'),
        throwsA(isA<MissingPluginException>()),
      );
    });

    test('dispose releases the buffer but keeps the page\'s context, so '
        'the next engine needs no new gesture', () async {
      await audio.load(wavUrl(1));
      final first = context();
      await audio.dispose();
      expect(identical(context(), first), isTrue);
      expect(first.state, isNot('closed'));
      await expectLater(
        audio.playAt(nativeTimeUs: perfNowUs(), positionUs: 0),
        throwsA(platformError('no_file')),
      );
      await audio.load(wavUrl(1));
      expect(identical(context(), first), isTrue);
      if (needsAutoplay()) return;
      final anchorUs = perfNowUs() + 100000;
      await playHeardAt(anchorUs, 0);
      await sleepMs(300);
      expect(await audio.positionUs(), closeTo(perfNowUs() - anchorUs, 30000));
    });

    test('iOS graph: plays through a hidden <audio> element', () async {
      if (needsAutoplay()) return;
      LocaljamAudioWeb.debugIsIOSOverride = true;
      await audio.load(wavUrl(2));
      final anchorUs = perfNowUs() + 100000;
      await playHeardAt(anchorUs, 0);
      final element = LocaljamAudioWeb.debugInstance!.debugElement;
      expect(element, isNotNull);
      expect(element!.srcObject, isNotNull);
      expect(element.paused, isFalse);
      expect(element.isConnected, isTrue);
      await sleepMs(300);
      expect(await audio.positionUs(), closeTo(perfNowUs() - anchorUs, 30000));
      // Kept across dispose (it holds the gesture-unlocked audio route)…
      await audio.dispose();
      expect(element.isConnected, isTrue);
      expect(element.paused, isFalse);
      // …and removed only with its context.
      await LocaljamAudioWeb.debugInstance!.debugCloseContext();
      expect(element.isConnected, isFalse);
    });
  });
}
