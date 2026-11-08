// Mp3Info: where an MP3's media frame 0 is, whatever the browser's decoder
// did. Fixtures are the Android test ones (tool/gapless_fixtures.sh): 3 s of
// audio, so the gapless length is known exactly. Decoded lengths below are
// the ones measured from Chrome 157's and Core Audio's decoders.
@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_audio/src/gapless_mp3.dart';

Uint8List fixture(String name) =>
    File('android/src/test/resources/gapless/$name').readAsBytesSync();

void main() {
  group('parse', () {
    test('LAME-tagged MPEG-1 stereo CBR', () {
      final info = Mp3Info.parse(fixture('lame_cbr_44100_stereo.mp3'))!;
      expect(info.sampleRate, 44100);
      expect(info.samplesPerFrame, 1152);
      expect(info.frames, 116);
      expect(info.hasLameTag, isTrue);
      expect(info.delay, 576);
      expect(info.frames! * 1152 - info.delay - info.padding, 132300);
    });

    test('LAME-tagged MPEG-2 mono VBR, behind an ID3v2 tag', () {
      final info = Mp3Info.parse(fixture('lame_vbr_22050_mono.mp3'))!;
      expect(info.sampleRate, 22050);
      expect(info.samplesPerFrame, 576);
      expect(info.frames, 117);
      expect(info.delay, 576);
      expect(info.frames! * 576 - info.delay - info.padding, 66150);
    });

    test('no Xing frame: no tag', () {
      final info = Mp3Info.parse(fixture('noxing_44100_mono.mp3'))!;
      expect(info.hasLameTag, isFalse);
      expect(info.delay, 0);
      expect(info.frames, isNull);
    });

    test('not an MP3', () {
      expect(Mp3Info.parse(Uint8List(0)), isNull);
      expect(
        Mp3Info.parse(Uint8List.fromList(List.filled(5000, 0x55))),
        isNull,
      );
      final wav = Uint8List.fromList([
        ...'RIFF'.codeUnits,
        ...List.filled(4000, 0),
      ]);
      expect(Mp3Info.parse(wav), isNull);
    });
  });

  group('mediaWindow', () {
    final tagged = Mp3Info.parse(fixture('lame_cbr_44100_stereo.mp3'))!;
    final tagless = Mp3Info.parse(fixture('noxing_44100_mono.mp3'))!;

    test(
      'Chrome applied the LAME tag (also resampled to 48 kHz): untouched',
      () {
        for (final keeps in [true, false]) {
          expect(
            tagged.mediaWindow(
              decodedLength: 132300,
              decodedRate: 44100,
              decoderKeepsDelay: keeps,
            ),
            isNull,
          );
          expect(
            tagged.mediaWindow(
              decodedLength: 144000,
              decodedRate: 48000,
              decoderKeepsDelay: keeps,
            ),
            isNull,
          );
        }
      },
    );

    test(
      'Core Audio skipped the LAME tag: shift by the delay, cut the padding',
      () {
        expect(
          tagged.mediaWindow(
            decodedLength: 133632,
            decodedRate: 44100,
            decoderKeepsDelay: false,
          ),
          (576, 132300),
        );
        // Resampled to 48 kHz: 133632 → 145451 frames.
        expect(
          tagged.mediaWindow(
            decodedLength: 145451,
            decodedRate: 48000,
            decoderKeepsDelay: false,
          ),
          (627, 144000),
        );
      },
    );

    test('an unrecognized length leaves the decode alone', () {
      expect(
        tagged.mediaWindow(
          decodedLength: 140000,
          decodedRate: 44100,
          decoderKeepsDelay: true,
        ),
        isNull,
      );
    });

    test(
      'tagless: FFmpeg keeps the 529-frame decoder delay, Core Audio does not',
      () {
        expect(
          tagless.mediaWindow(
            decodedLength: 133632,
            decodedRate: 44100,
            decoderKeepsDelay: true,
          ),
          (529, 133632 - 529),
        );
        expect(
          tagless.mediaWindow(
            decodedLength: 145451,
            decodedRate: 48000,
            decoderKeepsDelay: true,
          ),
          (576, 145451 - 576), // 529 × 48000/44100 = 575.8
        );
        expect(
          tagless.mediaWindow(
            decodedLength: 133632,
            decodedRate: 44100,
            decoderKeepsDelay: false,
          ),
          isNull,
        );
      },
    );
  });
}
