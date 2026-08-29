/// Self-contained audio fixtures for tests: real, parseable MP3s generated
/// in-memory (no checked-in binaries — `test-media/` is gitignored, local
/// device-testing material only).
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:test/test.dart';

/// A 1×1 red PNG — the embedded-artwork payload.
final Uint8List tinyPngBytes = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, //
  0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53, 0xDE, 0x00, 0x00, 0x00, //
  0x0C, 0x49, 0x44, 0x41, 0x54, 0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00, //
  0x00, 0x00, 0x03, 0x00, 0x01, 0x9E, 0xDE, 0x81, 0x4A, 0x00, 0x00, 0x00, //
  0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

/// Writes a minimal valid MP3 (~1 s of silence): an empty ID3v2.4 header
/// followed by [frames] MPEG-1 Layer III frames (128 kbps / 44.1 kHz →
/// 417 bytes each). Parseable by `audio_metadata_reader` for duration, and
/// taggable via [makeTaggedMp3]. The file lives in a fresh temp dir cleaned
/// up after the test.
Future<File> makeUntaggedMp3({int frames = 40, String name = 'gen.mp3'}) async {
  final dir = await Directory.systemTemp.createTemp('localjam_fixture');
  addTearDown(() => dir.delete(recursive: true));
  final frame = Uint8List(417)..setRange(0, 4, [0xFF, 0xFB, 0x90, 0x00]);
  final builder = BytesBuilder()
    // Empty ID3v2.4 tag: lets the writer path select the MP3 writer.
    ..add([0x49, 0x44, 0x33, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]);
  for (var i = 0; i < frames; i++) {
    builder.add(frame);
  }
  final file = File('${dir.path}/$name');
  await file.writeAsBytes(builder.takeBytes());
  return file;
}

/// A generated MP3 carrying ID3v2 tags and (by default) embedded PNG
/// artwork — the fixture the §6.1 v0.2 / §6.5 tests run against.
Future<File> makeTaggedMp3({
  String title = 'Night Drive',
  String artist = 'The Localhosts',
  String album = 'Loopback Sessions',
  bool withArtwork = true,
  String name = 'tagged.mp3',
}) async {
  final file = await makeUntaggedMp3(name: name);
  updateMetadata(file, (metadata) {
    final mp3 = metadata as Mp3Metadata;
    mp3.songName = title;
    mp3.leadPerformer = artist;
    mp3.album = album;
    if (withArtwork) {
      mp3.pictures.add(
        Picture(tinyPngBytes, 'image/png', PictureType.coverFront),
      );
    }
  });
  return file;
}
