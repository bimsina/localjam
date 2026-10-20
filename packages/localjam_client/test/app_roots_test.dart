/// Portable paths: what a stored path means in this run of the app, after
/// its container moved (an iOS reinstall, Android's two names for one app
/// folder).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_client/localjam_client.dart';

import 'engine_test_utils.dart';

void main() {
  test('a path is kept relative to the innermost app folder; one outside '
      'them stays absolute', () {
    final roots = _iosRoots('/var/mobile/Containers/Data/Application/U1');
    expect(
      roots.refFor(
        '/var/mobile/Containers/Data/Application/U1/Library/Caches/'
        'localjam_media/abc',
      ),
      // iOS's cache and temp are one folder: cache names it.
      const JamPathRef(JamAppRoot.cache, 'localjam_media/abc'),
    );
    expect(
      roots.refFor(
        '/var/mobile/Containers/Data/Application/U1/Library/'
        'Application Support/imports/Night Drive.mp3',
      ),
      const JamPathRef(JamAppRoot.support, 'imports/Night Drive.mp3'),
    );
    expect(roots.refFor('/Users/me/Music/Night Drive.mp3'), isNull);
    // A root itself is no file in it.
    expect(roots.refFor(roots.pathOf(JamAppRoot.documents)!), isNull);
    expect(JamAppRoots.none.refFor('/anything/at/all.mp3'), isNull);
  });

  test('a stored reference never climbs out of its folder', () {
    for (final path in ['../x.mp3', 'a/../../x.mp3', '/abs.mp3', '', '.']) {
      expect(
        JamPathRef.fromJson({'root': 'support', 'path': path}),
        isNull,
        reason: path,
      );
    }
    expect(JamPathRef.fromJson({'root': 'nowhere', 'path': 'a.mp3'}), isNull);
    expect(
      JamPathRef.fromJson({'root': 'cache', 'path': 'localjam_media/abc'}),
      const JamPathRef(JamAppRoot.cache, 'localjam_media/abc'),
    );
  });

  test(
    'Android: /data/data/<pkg> paths re-base onto /data/user/0/<pkg>',
    () async {
      final base = await makeTempDir();
      final now = '${base.path}/data/user/0/com.example.localjam';
      final roots = JamAppRoots({
        JamAppRoot.support: '$now/files',
        JamAppRoot.cache: '$now/cache',
        JamAppRoot.documents: '$now/app_flutter',
        JamAppRoot.temp: '$now/cache',
      });
      _touch('$now/files/imports/a.mp3');
      _touch('$now/cache/localjam_media/b');
      final old = '${base.path}/data/data/com.example.localjam';
      expect(
        roots.locate(absolutePath: '$old/files/imports/a.mp3'),
        '$now/files/imports/a.mp3',
      );
      expect(
        roots.locate(absolutePath: '$old/cache/localjam_media/b'),
        '$now/cache/localjam_media/b',
      );
      // Another user's copy of the app is the same container, renamed.
      expect(
        roots.locate(
          absolutePath:
              '${base.path}/data/user/10/com.example.localjam/files/imports/'
              'a.mp3',
        ),
        '$now/files/imports/a.mp3',
      );
      // A library path that is gone is not guessed into the app's folders.
      expect(
        roots.locate(absolutePath: '${base.path}/storage/Music/a.mp3'),
        isNull,
      );
    },
  );
}

/// An iOS container's folders, as path_provider names them there: the cache
/// and temp are one folder (`Library/Caches`).
JamAppRoots _iosRoots(String container) => JamAppRoots({
  JamAppRoot.support: '$container/Library/Application Support',
  JamAppRoot.cache: '$container/Library/Caches',
  JamAppRoot.documents: '$container/Documents',
  JamAppRoot.temp: '$container/Library/Caches',
}, separator: '/');

/// Creates [path] (and its folders) with a few bytes in it.
File _touch(String path) => File(path)
  ..createSync(recursive: true)
  ..writeAsBytesSync(const [1, 2, 3]);
