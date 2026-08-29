/// Tests for host-side tag extraction (PROTOCOL.md §6.1/§6.5).
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:localjam_net/localjam_net.dart';
import 'package:test/test.dart';

final _taggedFixture = File('../../test-media/track1_tagged.m4a');
final _untaggedFixture = File('../../test-media/track1.m4a');

void main() {
  test('reads title/artist/album, duration, and artwork from a tagged m4a',
      () async {
    final tags = await readAudioTags(_taggedFixture);
    expect(tags.title, 'Night Drive');
    expect(tags.artist, 'The Localhosts');
    expect(tags.album, 'Loopback Sessions');
    expect(tags.durationUs, isNotNull);
    expect(tags.durationUs, greaterThan(0));
    expect(tags.hasArtwork, isTrue);
    expect(tags.artworkBytes, isNotEmpty);
    expect(tags.artworkMime, 'image/png');
  });

  test('an untagged file yields nulls but still a tag-declared duration',
      () async {
    final tags = await readAudioTags(_untaggedFixture);
    expect(tags.title, isNull);
    expect(tags.artist, isNull);
    expect(tags.album, isNull);
    expect(tags.hasArtwork, isFalse);
    // The m4a container still declares its duration.
    expect(tags.durationUs, greaterThan(0));
  });

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
}
