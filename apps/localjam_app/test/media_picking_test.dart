/// The picker's type group and the display-title fallback.
///
/// Android's DocumentsUI greyed out every `.m4a` on the device because the
/// group carried extensions and UTIs but no MIME types, and a tagless file
/// showed up as "track1.m4a" once it was in.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/util/format.dart';
import 'package:localjam_app/src/util/media_picking.dart';
import 'package:localjam_client/localjam_client.dart';

void main() {
  group('jamAudioTypeGroup', () {
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    test('carries the MIME types Android filters on', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final mimeTypes = jamAudioTypeGroup().mimeTypes;
      expect(mimeTypes, contains('audio/mp4'));
      expect(mimeTypes, contains('audio/x-m4a'));
      expect(mimeTypes, contains('audio/mpeg'));
      expect(mimeTypes, contains('audio/*'));
    });

    test('keeps the engine as the source of truth for extensions', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(jamAudioTypeGroup().extensions, supportedAudioExtensions);
      expect(jamAudioTypeGroup().extensions, contains('m4a'));
    });

    test('still names the Apple UTI', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      expect(
        jamAudioTypeGroup().uniformTypeIdentifiers,
        contains('public.audio'),
      );
    });
  });

  group('stripAudioExtension', () {
    test('drops a trailing audio extension', () {
      expect(stripAudioExtension('track1.m4a'), 'track1');
      expect(stripAudioExtension('Song.MP3'), 'Song');
      expect(stripAudioExtension('a.b.flac'), 'a.b');
    });

    test('leaves everything else alone', () {
      expect(stripAudioExtension('Track 1'), 'Track 1');
      expect(stripAudioExtension('Symphony No. 5'), 'Symphony No. 5');
      expect(stripAudioExtension('notes.txt'), 'notes.txt');
      expect(stripAudioExtension('.mp3'), '.mp3');
      expect(stripAudioExtension('trailing.'), 'trailing.');
      expect(stripAudioExtension(''), '');
    });
  });

  group('jamDisplayTitle', () {
    MediaItem item({String? title}) => MediaItem(
      mediaId: 'm1',
      kind: MediaKind.audio,
      name: 'track1.m4a',
      mime: 'audio/mp4',
      sizeBytes: 1,
      sha256: 'ab',
      title: title,
    );

    test('prefers the tag title', () {
      expect(jamDisplayTitle(item(title: 'Real Title')), 'Real Title');
    });

    test('strips the extension off a filename fallback', () {
      expect(jamDisplayTitle(item()), 'track1');
    });
  });
}
