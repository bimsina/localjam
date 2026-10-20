/// The picker's type group and the display-title fallback.
///
/// Android's DocumentsUI greyed out every `.m4a` on the device because the
/// group carried extensions and UTIs but no MIME types, and a tagless file
/// showed up as "track1.m4a" once it was in.
library;

import 'dart:io';

import 'package:flutter/cupertino.dart' show CupertinoActionSheet;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/design/theme.dart';
import 'package:localjam_app/src/util/format.dart';
import 'package:localjam_app/src/util/media_picking.dart';
import 'package:localjam_app/src/widgets/list.dart';
import 'package:localjam_app/src/widgets/sheet.dart';
import 'package:localjam_client/localjam_client.dart';

import 'fixtures.dart';

void main() {
  group('the Add Songs From choice', () {
    Future<Future<JamAddSource?>> open(WidgetTester tester) async {
      late Future<JamAddSource?> answer;
      await tester.pumpWidget(
        MaterialApp(
          theme: jamLightTheme(),
          home: Builder(
            builder: (context) => Center(
              child: GestureDetector(
                onTap: () => answer = showJamAddSourceSheet(context),
                child: const Text('Go'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Go'));
      await tester.pumpAndSettle();
      return answer;
    }

    testWidgets('is the app’s own sheet, not the system action sheet', (
      tester,
    ) async {
      await open(tester);
      expect(find.byType(CupertinoActionSheet), findsNothing);
      expect(find.byType(JamSheetSurface), findsOneWidget);
      expect(find.text(JamPickerStrings.addFrom), findsOneWidget);
      // Two rows that say where their songs come from.
      expect(find.byType(JamRow), findsNWidgets(2));
      expect(find.text(JamPickerStrings.libraryDetail), findsOneWidget);
      expect(find.text(JamPickerStrings.filesDetail), findsOneWidget);
    });

    testWidgets('a row answers with its source', (tester) async {
      final answer = await open(tester);
      await tester.tap(find.text(JamPickerStrings.files));
      await tester.pumpAndSettle();
      expect(await answer, JamAddSource.files);
      expect(find.byType(JamSheetSurface), findsNothing);
    });

    testWidgets('Done backs out with no answer', (tester) async {
      final answer = await open(tester);
      await tester.tap(find.text(JamSheetStrings.done));
      await tester.pumpAndSettle();
      expect(await answer, isNull);
    });
  });

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

  group('JamPickedTrack', () {
    test('keeps what the library knew instead of a file name', () {
      const library = JamLibraryTrack(
        id: 7,
        title: 'Low Tide',
        artist: 'Harbour Kids',
        durationMs: 200000,
        sizeBytes: 1,
        contentUri: 'content://media/7',
      );
      final picked = JamPickedTrack.fromLibrary(library, '/cache/tide.m4a');
      expect(picked.displayTitle, 'Low Tide');
      expect(picked.artist, 'Harbour Kids');
      expect(picked.duration, const Duration(seconds: 200));
      expect(picked.path, '/cache/tide.m4a');
      expect(picked.tagsRead, isFalse);
    });

    test('falls back to the file name, without its extension', () {
      expect(
        const JamPickedTrack(path: '/music/Night Drive.mp3').displayTitle,
        'Night Drive',
      );
    });

    test('tags fill the gaps but never overwrite the library', () {
      final cover = Uint8List.fromList([1, 2, 3]);
      final read = const JamPickedTrack(path: '/a.m4a', title: 'Library Title')
          .withTags(
            JamAudioTags(
              title: 'Tag Title',
              artist: 'Tag Artist',
              durationUs: 3000000,
              artworkBytes: cover,
            ),
          );
      expect(read.title, 'Library Title');
      expect(read.artist, 'Tag Artist');
      expect(read.duration, const Duration(seconds: 3));
      expect(read.artworkBytes, cover);
      expect(read.tagsRead, isTrue);
    });

    test('reading a file off the UI isolate gives its length', () async {
      final dir = Directory.systemTemp.createTempSync('localjam_pick');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}${Platform.pathSeparator}tone.wav')
        ..writeAsBytesSync(wavBytes(ms: 2000));
      final read = await readPickedTrack(JamPickedTrack(path: file.path));
      expect(read.tagsRead, isTrue);
      expect(read.displayTitle, 'tone');
      expect(read.duration?.inMilliseconds, closeTo(2000, 50));
    });

    test('a missing file is read as tagless, never thrown', () async {
      final read = await readPickedTrack(
        const JamPickedTrack(path: '/nowhere/gone.mp3'),
      );
      expect(read.tagsRead, isTrue);
      expect(read.displayTitle, 'gone');
      expect(read.artworkBytes, isNull);
    });
  });
}
