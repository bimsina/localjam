/// Tests for host-side tag extraction (PROTOCOL.md §6.1/§6.5).
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:localjam_net/localjam_net.dart';
import 'package:test/test.dart';

import 'test_fixtures.dart';

void main() {
  test(
    'reads title/artist/album, duration, and artwork from a tagged mp3',
    () async {
      final tags = await readAudioTags(await makeTaggedMp3());
      expect(tags.title, 'Night Drive');
      expect(tags.artist, 'The Localhosts');
      expect(tags.album, 'Loopback Sessions');
      expect(tags.durationUs, isNotNull);
      expect(tags.durationUs, greaterThan(0));
      expect(tags.hasArtwork, isTrue);
      expect(tags.artworkBytes, equals(tinyPngBytes));
      expect(tags.artworkMime, 'image/png');
    },
  );

  test(
    'an untagged file yields nulls but still a container duration',
    () async {
      final tags = await readAudioTags(await makeUntaggedMp3());
      expect(tags.title, isNull);
      expect(tags.artist, isNull);
      expect(tags.album, isNull);
      expect(tags.hasArtwork, isFalse);
      // The MPEG frames still yield a duration.
      expect(tags.durationUs, greaterThan(0));
    },
  );

  test('garbage bytes yield an empty result, never a throw', () async {
    final dir = await Directory.systemTemp.createTemp('localjam_meta_test');
    addTearDown(() => dir.delete(recursive: true));
    final garbage = File('${dir.path}/noise.mp3');
    await garbage.writeAsBytes(
      Uint8List.fromList(List.generate(4096, (i) => (i * 37) & 0xff)),
    );
    final tags = await readAudioTags(garbage);
    expect(tags.title, isNull);
    expect(tags.durationUs, isNull);
    expect(tags.hasArtwork, isFalse);
  });

  test('a missing file yields an empty result, never a throw', () async {
    final tags = await readAudioTags(File('/nonexistent/nope.mp3'));
    expect(tags.title, isNull);
    expect(tags.hasArtwork, isFalse);
  });

  group('ID3v2.3 with UTF-16 frames (real-world rips)', () {
    for (final bounded in [false, true]) {
      final label = bounded ? 'bounded read' : 'full read';
      test('the cover comes out as the image alone ($label)', () async {
        for (final description in ['Cover', 'Cover (front)', '']) {
          final file = await makeId3v23Mp3(
            picture: fakeJpegBytes,
            pictureDescription: description,
          );
          final tags = readAudioTagsSync(
            file,
            maxMetadataBytes: bounded ? 8 * 1024 * 1024 : null,
          );
          expect(tags.artworkBytes, equals(fakeJpegBytes), reason: description);
          expect(tags.artworkMime, 'image/jpeg');
        }
      });

      test('the artist is the track artist, not the album artist '
          '($label)', () async {
        final file = await makeId3v23Mp3(picture: fakeJpegBytes);
        final tags = readAudioTagsSync(
          file,
          maxMetadataBytes: bounded ? 8 * 1024 * 1024 : null,
        );
        expect(tags.title, 'Nila Sona Nila');
        expect(tags.artist, 'K.T. Varman, Ravi Seth, Nikhil Dharan');
        expect(tags.album, 'Driftwood');
      });
    }

    test('with no track artist, the album artist stands in', () async {
      final file = await makeId3v23Mp3(leadPerformer: null);
      final tags = await readAudioTags(file);
      expect(tags.artist, 'K.T. Varman');
    });

    test('a declared MIME type the bytes contradict loses', () async {
      final file = await makeId3v23Mp3(
        picture: tinyPngBytes,
        pictureMime: 'image/jpg',
      );
      final tags = await readAudioTags(file);
      expect(tags.artworkBytes, equals(tinyPngBytes));
      expect(tags.artworkMime, 'image/png');
    });

    test('a picture that is not an image is no cover', () async {
      final file = await makeId3v23Mp3(
        picture: Uint8List.fromList('http://example.com/c.jpg'.codeUnits),
        pictureMime: '-->',
      );
      final tags = await readAudioTags(file);
      expect(tags.hasArtwork, isFalse);
      expect(tags.artworkMime, isNull);
      expect(tags.title, 'Nila Sona Nila');
    });
  });

  group('sniffArtwork', () {
    test('drops a UTF-16 description left in front of a JPEG', () {
      // What audio_metadata_reader 1.7.1 returned for a cover described
      // "Cover": the description's tail and terminator, then the image.
      final corrupted = Uint8List.fromList([
        0x6F, 0x00, 0x76, 0x00, 0x65, 0x00, 0x72, 0x00, 0x00, 0x00, //
        ...fakeJpegBytes,
      ]);
      final sniffed = sniffArtwork(corrupted)!;
      expect(sniffed.bytes, equals(fakeJpegBytes));
      expect(sniffed.mime, 'image/jpeg');
    });

    test('drops a prefix in front of a PNG', () {
      final sniffed = sniffArtwork(
        Uint8List.fromList([0x43, 0x00, 0x00, 0x00, ...tinyPngBytes]),
      )!;
      expect(sniffed.bytes, equals(tinyPngBytes));
      expect(sniffed.mime, 'image/png');
    });

    test('keeps a clean image as it is', () {
      final sniffed = sniffArtwork(fakeJpegBytes)!;
      expect(identical(sniffed.bytes, fakeJpegBytes), isTrue);
    });

    test('knows GIF and WebP', () {
      expect(
        sniffArtwork(Uint8List.fromList([...'GIF89a'.codeUnits, 1, 0]))?.mime,
        'image/gif',
      );
      expect(
        sniffArtwork(
          Uint8List.fromList([
            ...'RIFF'.codeUnits,
            0x10, 0, 0, 0, //
            ...'WEBPVP8 '.codeUnits,
          ]),
        )?.mime,
        'image/webp',
      );
    });

    test('rejects bytes with no image signature', () {
      expect(sniffArtwork(Uint8List(0)), isNull);
      expect(
        sniffArtwork(Uint8List.fromList('not a picture'.codeUnits)),
        isNull,
      );
    });

    test('looks only so far for the image', () {
      final late = Uint8List.fromList([...Uint8List(600), ...fakeJpegBytes]);
      expect(sniffArtwork(late), isNull);
    });
  });

  group('normalizeArtistCredit', () {
    test('splits ID3 slash and NUL separators into one comma list', () {
      expect(
        normalizeArtistCredit('K.T. Varman/Ravi Seth/Nikhil Dharan'),
        'K.T. Varman, Ravi Seth, Nikhil Dharan',
      );
      expect(
        normalizeArtistCredit('Alka Yagnik\u0000Udit Narayan'),
        'Alka Yagnik, Udit Narayan',
      );
      expect(normalizeArtistCredit('Mano / Swarnalatha'), 'Mano, Swarnalatha');
    });

    test('keeps a name with a slash in it whole', () {
      expect(normalizeArtistCredit('AC/DC'), 'AC/DC');
      expect(normalizeArtistCredit('N/A'), 'N/A');
    });

    test('never splits commas, drops repeats and blanks', () {
      expect(normalizeArtistCredit('Earth, Wind & Fire'), 'Earth, Wind & Fire');
      expect(
        normalizeArtistCredit('K.T. Varman/k.t. varman/Ravi Seth'),
        'K.T. Varman, Ravi Seth',
      );
      expect(normalizeArtistCredit('﻿  \u0000 '), isNull);
      expect(normalizeArtistCredit(null), isNull);
    });
  });
}
