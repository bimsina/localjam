/// Picked songs outlive the picker.
///
/// iOS's Files picker hands back copies in `tmp/<bundle>-Inbox/` that the OS
/// deleted about a minute later, mid-jam: the next song failed to open, the
/// guests got a 500, and the history could not play the jam again.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/util/picked_files.dart';

void main() {
  late Directory root;
  late JamPickedFileKeeper keeper;

  String at(String relative) => '${root.path}/$relative';

  File write(String relative, List<int> bytes) => File(at(relative))
    ..createSync(recursive: true)
    ..writeAsBytesSync(bytes);

  List<String> imported() {
    final dir = Directory(at('support/imports'));
    if (!dir.existsSync()) return const [];
    return [
      for (final entity in dir.listSync())
        entity.uri.pathSegments.lastWhere((s) => s.isNotEmpty),
    ]..sort();
  }

  setUp(() {
    root = Directory.systemTemp.createTempSync('picked_files_test');
    keeper = JamPickedFileKeeper(
      importsDir: Directory(at('support/imports')),
      temporaryRoots: [at('tmp'), at('caches')],
    );
  });

  tearDown(() => root.deleteSync(recursive: true));

  group('what counts as temporary', () {
    test('the iOS Files Inbox and the platform temp and cache folders', () {
      expect(keeper.isTemporary(at('tmp/np.app-Inbox/a.mp3')), isTrue);
      expect(keeper.isTemporary(at('caches/6f1c/b.m4a')), isTrue);
      expect(keeper.isTemporary(at('Documents/Inbox/c.mp3')), isTrue);
    });

    test('the person’s own files, and copies already kept, are not', () {
      expect(keeper.isTemporary(at('Documents/LocalJam/a.mp3')), isFalse);
      expect(keeper.isTemporary('/storage/emulated/0/Music/b.mp3'), isFalse);
      expect(keeper.isTemporary(at('support/imports/a.mp3')), isFalse);
      // A file named like a folder is still just a file.
      expect(keeper.isTemporary(at('Music/Inbox')), isFalse);
      // A folder that merely starts like a temp root is not inside it.
      expect(keeper.isTemporary(at('tmpfiles/a.mp3')), isFalse);
    });

    test('/private/var and /var are the same place', () {
      final k = JamPickedFileKeeper(
        importsDir: Directory('/var/mobile/C/Library/Application Support/i'),
        temporaryRoots: const ['/private/var/mobile/C/tmp/'],
      );
      expect(k.isTemporary('/var/mobile/C/tmp/x-Inbox/a.mp3'), isTrue);
      expect(k.isTemporary('/private/var/mobile/C/tmp/a.mp3'), isTrue);
    });
  });

  group('keep', () {
    test('copies an Inbox pick into the app’s container', () async {
      final picked = write('tmp/np.app-Inbox/Campfire Static.mp3', [1, 2, 3]);
      final kept = await keeper.keep(picked.path);

      expect(kept, at('support/imports/Campfire Static.mp3'));
      expect(File(kept).readAsBytesSync(), [1, 2, 3]);
      // The OS's copy is left for the OS to clear.
      expect(picked.existsSync(), isTrue);

      // Once the Inbox is purged, the kept copy still plays.
      picked.deleteSync();
      expect(File(kept).existsSync(), isTrue);
    });

    test('copies a cached pick (Android’s picker and library)', () async {
      final picked = write('caches/9a2e/Low Tide.m4a', [4, 5]);
      final kept = await keeper.keep(picked.path);
      expect(kept, at('support/imports/Low Tide.m4a'));
      expect(File(kept).readAsBytesSync(), [4, 5]);
    });

    test('the same song picked twice is kept once', () async {
      final first = write('tmp/np.app-Inbox/Low Tide.mp3', [1, 2, 3]);
      final again = write('caches/77/Low Tide.mp3', [1, 2, 3]);

      final a = await keeper.keep(first.path);
      final b = await keeper.keep(again.path);

      expect(b, a);
      expect(imported(), ['Low Tide.mp3']);
    });

    test('a different song with the same name gets its own copy', () async {
      final one = write('tmp/x-Inbox/Intro.mp3', [1, 2, 3]);
      final other = write('caches/2/Intro.mp3', [9, 9, 9, 9]);

      final a = await keeper.keep(one.path);
      final b = await keeper.keep(other.path);

      expect(a, at('support/imports/Intro.mp3'));
      expect(b, at('support/imports/Intro 2.mp3'));
      expect(File(b).readAsBytesSync(), [9, 9, 9, 9]);
      // And picking the second one again finds its copy.
      expect(await keeper.keep(other.path), b);
      expect(imported(), ['Intro 2.mp3', 'Intro.mp3']);
    });

    test('leaves a path that is not temporary alone', () async {
      final own = write('Documents/LocalJam/Golden Hour Drive.mp3', [7]);
      expect(await keeper.keep(own.path), own.path);
      expect(imported(), isEmpty);
    });

    test('a pick that is already gone comes back unchanged', () async {
      final gone = at('tmp/x-Inbox/gone.mp3');
      expect(await keeper.keep(gone), gone);
      expect(imported(), isEmpty);
    });

    test('keepAll keeps the order and mixes kept and own paths', () async {
      final own = write('Music/a.mp3', [1]);
      final inbox = write('tmp/x-Inbox/b.mp3', [2]);
      final kept = await keeper.keepAll([own.path, inbox.path]);
      expect(kept, [own.path, at('support/imports/b.mp3')]);
    });
  });
}
