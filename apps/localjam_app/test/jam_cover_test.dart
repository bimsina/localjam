/// One jam, one cover (N5): the first song in the queue with art — on the
/// page it ended on, on Home, on Invite, as in Past jams. The ended page
/// used to show whatever was playing, so one jam wore two covers a minute
/// apart.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/util/jam_cover.dart';
import 'package:localjam_client/localjam_client.dart';

MediaItem _song(String id, {String? art}) => MediaItem(
  mediaId: id,
  kind: MediaKind.audio,
  name: '$id.mp3',
  mime: 'audio/mpeg',
  sizeBytes: 1,
  sha256: id,
  artworkId: art,
);

class _Engine implements JamEngine {
  _Engine(this.playlist, this.art, {this.current});

  @override
  final List<MediaItem> playlist;

  /// Bytes per artwork id; a missing id fails to read.
  final Map<String, List<int>> art;

  final MediaItem? current;

  @override
  MediaItem? get currentItem => current;

  @override
  Future<Uint8List?> artworkFor(MediaItem item) async {
    final bytes = art[item.artworkId];
    if (bytes == null) throw StateError('unreadable');
    return Uint8List.fromList(bytes);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('the first song with art, whatever is playing', () async {
    final queue = [
      _song('intro'),
      _song('golden', art: 'a1'),
      _song('tide', art: 'a2'),
    ];
    final engine = _Engine(queue, {
      'a1': [1],
      'a2': [2],
    }, current: queue.last);
    expect(await jamCoverOf(engine), [1]);
  });

  test('art that cannot be read hands over to the next song', () async {
    final engine = _Engine(
      [_song('golden', art: 'gone'), _song('tide', art: 'a2')],
      {
        'a2': [2],
      },
    );
    expect(await jamCoverOf(engine), [2]);
  });

  test('a queue with no art has no cover', () async {
    final engine = _Engine([_song('intro'), _song('outro')], const {});
    expect(await jamCoverOf(engine), isNull);
    expect(jamCoverKey(engine), isEmpty);
  });

  test('the key follows the queue’s art, not the playing song', () {
    final queue = [_song('golden', art: 'a1'), _song('tide', art: 'a2')];
    final first = _Engine(queue, const {}, current: queue.first);
    final later = _Engine(queue, const {}, current: queue.last);
    expect(jamCoverKey(first), jamCoverKey(later));
    final reordered = _Engine(queue.reversed.toList(), const {});
    expect(jamCoverKey(reordered), isNot(jamCoverKey(first)));
  });
}
