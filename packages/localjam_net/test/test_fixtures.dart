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

/// A small stand-in JPEG: SOI, an APP0 segment, EOI. Never decoded — what
/// matters is that it starts with the JPEG signature and ends where it ends.
final Uint8List fakeJpegBytes = Uint8List.fromList([
  0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, //
  0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0xFF, 0xD9,
]);

/// [text] as an ID3v2 text value in encoding 1: UTF-16LE with a BOM and a
/// UTF-16 NUL terminator.
List<int> _id3Utf16(String text) => [
  0xFF, 0xFE, //
  for (final unit in text.codeUnits) ...[unit & 0xFF, unit >> 8],
  0x00, 0x00,
];

/// One ID3v2.3 frame: id, big-endian size (not synchsafe in 2.3), no flags.
List<int> _id3v23Frame(String id, List<int> body) => [
  ...id.codeUnits,
  (body.length >> 24) & 0xFF,
  (body.length >> 16) & 0xFF,
  (body.length >> 8) & 0xFF,
  body.length & 0xFF,
  0x00,
  0x00,
  ...body,
];

/// A generated MP3 tagged the way real-world rips are: ID3v2.3, every text
/// frame UTF-16 (encoding 1), and the cover an APIC frame whose description
/// is UTF-16 too ("Cover" by default) — the layout audio_metadata_reader
/// 1.7 left part of in front of the image. A null value leaves its frame
/// out; a null [picture] leaves the APIC out.
Future<File> makeId3v23Mp3({
  String? title = 'Nila Sona Nila',
  String? leadPerformer = 'K.T. Varman/Ravi Seth/Nikhil Dharan',
  String? bandOrOrchestra = 'K.T. Varman',
  String? album = 'Driftwood',
  Uint8List? picture,
  String pictureMime = 'image/jpeg',
  String pictureDescription = 'Cover',
  String name = 'id3v23.mp3',
}) async {
  final dir = await Directory.systemTemp.createTemp('localjam_fixture');
  addTearDown(() => dir.delete(recursive: true));
  final frames = <int>[
    if (title != null) ..._id3v23Frame('TIT2', [0x01, ..._id3Utf16(title)]),
    if (leadPerformer != null)
      ..._id3v23Frame('TPE1', [0x01, ..._id3Utf16(leadPerformer)]),
    if (bandOrOrchestra != null)
      ..._id3v23Frame('TPE2', [0x01, ..._id3Utf16(bandOrOrchestra)]),
    if (album != null) ..._id3v23Frame('TALB', [0x01, ..._id3Utf16(album)]),
    if (picture != null)
      ..._id3v23Frame('APIC', [
        0x01, // UTF-16 description
        ...pictureMime.codeUnits,
        0x00,
        0x03, // front cover
        ..._id3Utf16(pictureDescription),
        ...picture,
      ]),
  ];
  final size = frames.length;
  final builder = BytesBuilder()
    ..add([0x49, 0x44, 0x33, 0x03, 0x00, 0x00])
    // Synchsafe tag size.
    ..add([
      (size >> 21) & 0x7F,
      (size >> 14) & 0x7F,
      (size >> 7) & 0x7F,
      size & 0x7F,
    ])
    ..add(frames);
  final frame = Uint8List(417)..setRange(0, 4, [0xFF, 0xFB, 0x90, 0x00]);
  for (var i = 0; i < 40; i++) {
    builder.add(frame);
  }
  final file = File('${dir.path}/$name');
  await file.writeAsBytes(builder.takeBytes());
  return file;
}
