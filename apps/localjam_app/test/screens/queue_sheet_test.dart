/// The queue in place (DESIGN_SPEC v3 §6.3 D5): Up Next in play order, the
/// reorder maths behind it, and the capability gates on every control.
library;

import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/design/theme.dart';
import 'package:localjam_app/src/state/session_controller.dart';
import 'package:localjam_app/src/util/format.dart';
import 'package:localjam_app/src/design/tokens.dart';
import 'package:localjam_app/src/widgets/queue_sheet.dart';
import 'package:localjam_app/src/widgets/track_row.dart';
import 'package:localjam_client/localjam_client.dart';

import '../fixtures.dart';
import '../harness.dart';

/// Three real files, generated per test, so the engine has something it can
/// actually register (see fixtures.dart — no gitignored media).
List<String> _media() => makeTestTracks();

/// Polls on the real clock — the engines run over actual sockets.
Future<bool> _waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  return condition();
}

Directory _tempCache() {
  final dir = Directory.systemTemp.createTempSync('localjam_queue_test');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return dir;
}

Future<void> _pump(
  WidgetTester tester,
  JamSessionController session,
  Widget child, {
  ThemeData? theme,
}) async {
  await tester.pumpWidget(
    JamSession(
      controller: session,
      child: MaterialApp(
        theme: theme ?? jamLightTheme(),
        home: Scaffold(body: child),
      ),
    ),
  );
  await tester.pump();
}

MediaItem _item(String id) => MediaItem(
  mediaId: id,
  kind: MediaKind.audio,
  name: '$id.m4a',
  mime: 'audio/mp4',
  sizeBytes: 1,
  sha256: id,
);

void main() {
  group('jamUpNext', () {
    final playlist = [
      for (final id in ['a', 'b', 'c', 'd']) _item(id),
    ];
    List<String> ids(List<MediaItem> items) => [
      for (final item in items) item.mediaId,
    ];

    test('after a wrap, NEXT UP is the play order — not the stored order', () {
      // 2026-10-17 run: with `c` on, the sheet said "a b d" — two songs the
      // room had already played ahead of the one it plays next.
      expect(ids(jamUpNext(playlist, 'c')), ['d', 'a', 'b']);
      expect(ids(jamUpNext(playlist, 'd')), ['a', 'b', 'c']);
      expect(ids(jamUpNext(playlist, 'a')), ['b', 'c', 'd']);
    });

    test('with nothing current (or a current track no longer queued) it is '
        'the queue', () {
      expect(ids(jamUpNext(playlist, null)), ['a', 'b', 'c', 'd']);
      expect(ids(jamUpNext(playlist, 'gone')), ['a', 'b', 'c', 'd']);
    });
  });

  group('queueReorderTarget', () {
    final playlist = [
      for (final id in ['a', 'b', 'c', 'd']) _item(id),
    ];

    /// The NEXT UP order after [move] is applied to [playlist].
    List<String> playOrderAfter(
      ({String mediaId, int toIndex}) move,
      String currentId,
    ) {
      final ids = [for (final item in playlist) item.mediaId]
        ..remove(move.mediaId);
      ids.insert(move.toIndex, move.mediaId);
      return [
        for (final item in jamUpNext([
          for (final id in ids) _item(id),
        ], currentId))
          item.mediaId,
      ];
    }

    test('replays a NEXT UP drop against the whole playlist', () {
      // "b c d" with a pinned first: dropping d at the front of NEXT UP puts
      // it at index 1 of the real queue, right behind the current track.
      expect(
        queueReorderTarget(
          playlist: playlist,
          currentId: 'a',
          oldIndex: 2,
          newIndex: 0,
        ),
        (mediaId: 'd', toIndex: 1),
      );
    });

    test('after a wrap, a drop keeps the play order the person sees', () {
      // `c` on: NEXT UP reads "d a b". Dragging d to the bottom reads
      // "a b d" — the queue becomes a b d c, which plays exactly that.
      final move = queueReorderTarget(
        playlist: playlist,
        currentId: 'c',
        oldIndex: 0,
        newIndex: 2,
      )!;
      expect(move, (mediaId: 'd', toIndex: 2));
      expect(playOrderAfter(move, 'c'), ['a', 'b', 'd']);

      // And a to the top: "a d b", straight after the current track.
      final up = queueReorderTarget(
        playlist: playlist,
        currentId: 'c',
        oldIndex: 1,
        newIndex: 0,
      )!;
      expect(up, (mediaId: 'a', toIndex: 2));
      expect(playOrderAfter(up, 'c'), ['a', 'd', 'b']);
    });

    test('every drop on a wrapped NEXT UP lands where it was dropped', () {
      for (var current = 0; current < playlist.length; current++) {
        final currentId = playlist[current].mediaId;
        final upNext = [
          for (final item in jamUpNext(playlist, currentId)) item.mediaId,
        ];
        for (var from = 0; from < upNext.length; from++) {
          for (var to = 0; to < upNext.length; to++) {
            final move = queueReorderTarget(
              playlist: playlist,
              currentId: currentId,
              oldIndex: from,
              newIndex: to,
            );
            final expected = List.of(upNext)
              ..removeAt(from)
              ..insert(to, upNext[from]);
            if (from == to) {
              expect(move, isNull);
            } else {
              expect(
                playOrderAfter(move!, currentId),
                expected,
                reason: '$currentId on, $from → $to',
              );
            }
          }
        }
      }
    });

    test('a drop that changes nothing sends nothing', () {
      expect(
        queueReorderTarget(
          playlist: playlist,
          currentId: 'a',
          oldIndex: 1,
          newIndex: 1,
        ),
        isNull,
      );
    });

    test('with nothing playing the list is the queue', () {
      expect(
        queueReorderTarget(
          playlist: playlist,
          currentId: null,
          oldIndex: 0,
          newIndex: 3,
        ),
        (mediaId: 'a', toIndex: 3),
      );
    });
  });

  Future<JamSessionController> hostWithQueue(
    WidgetTester tester, {
    bool hold = false,
  }) async {
    final host = testSession();
    await tester.runAsync(() async {
      // `startHost` cues the first track: it is the cover above the list,
      // and Up Next is the rest.
      await host.startHost(
        sessionName: 'Van Jam',
        discoverable: false,
        paths: _media(),
      );
      // The files import behind the already-open room.
      await host.hostImport!.done;
      if (hold) {
        // A running position ticker is a live `Ticker` that `pumpAndSettle`
        // waits on forever; freeze the transport in the zone it runs in.
        host.hostEngine!.pause();
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    });
    await tester.pump();
    return host;
  }

  testWidgets('a host queue lists Up Next after the current track, with Add '
      'Songs first and a grip on every row', (tester) async {
    final host = await hostWithQueue(tester);
    expect(host.engine!.playlist.length, 3);

    await _pump(tester, host, QueuePanel(engine: host.engine!));
    await tester.pump();

    expect(find.text(QueueSheetStrings.title), findsOneWidget);
    expect(find.text(QueueSheetStrings.count(2)), findsOneWidget);
    expect(find.text(QueueSheetStrings.addSongs), findsOneWidget);
    // The current track is the cover above the list, not a row in it.
    expect(find.byType(JamTrackRow), findsNWidgets(2));
    expect(find.byType(SliverReorderableList), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.line_horizontal_3), findsNWidgets(2));
    // White on the backdrop, whatever the app theme.
    expect(
      tester.widget<Text>(find.text(QueueSheetStrings.title)).style!.color,
      JamNowPlayingColors.text,
    );

    await tester.runAsync(host.leave);
  });

  testWidgets('Up Next lists what plays next once the room has gone round', (
    tester,
  ) async {
    final host = testSession();
    await tester.runAsync(() async {
      await host.startHost(
        sessionName: 'Van Jam',
        discoverable: false,
        paths: _media(),
      );
      await host.hostImport!.done;
      final engine = host.hostEngine!;
      engine.setMedia(engine.playlist[1].mediaId);
    });
    await tester.pump();
    final engine = host.engine!;
    final titles = [for (final item in engine.playlist) jamDisplayTitle(item)];

    await _pump(tester, host, QueuePanel(engine: engine));
    await tester.pump();

    double top(String title) => tester.getTopLeft(find.text(title)).dy;
    expect(find.text(titles[1]), findsNothing, reason: 'the current track');
    expect(
      top(titles[2]),
      lessThan(top(titles[0])),
      reason: 'the last track plays next, then round to the first',
    );

    await tester.runAsync(host.leave);
  });

  testWidgets('an empty queue says so and offers Add Songs', (tester) async {
    final host = testSession();
    await tester.runAsync(
      () => host.startHost(sessionName: 'Quiet Jam', discoverable: false),
    );
    await tester.pump();

    await _pump(tester, host, QueuePanel(engine: host.engine!));
    await tester.pump();

    expect(find.text(QueueSheetStrings.empty), findsOneWidget);
    expect(find.text(QueueSheetStrings.addSongs), findsOneWidget);

    await tester.runAsync(host.leave);
  });

  testWidgets('a guest who may not add is told so', (tester) async {
    final host = testSession();
    final guest = testSession();
    final cache = _tempCache();

    await tester.runAsync(() async {
      await host.startHost(
        sessionName: 'Listen Room',
        policy: JamPolicy.listenOnly,
        discoverable: false,
      );
      expect(await guest.join(host.joinUri!, mediaCacheDir: cache), isTrue);
      expect(await _waitFor(() => guest.engine != null), isTrue);
    });
    await tester.pump();

    final engine = guest.engine!;
    expect(engine.can(JamCapability.addTracks), isFalse);

    await _pump(tester, guest, QueuePanel(engine: engine));
    await tester.pump();

    expect(find.text(QueueSheetStrings.hostRunsQueue), findsOneWidget);
    // §6.3: the Add Songs row is only there with `addTracks`.
    expect(find.text(QueueSheetStrings.addSongs), findsNothing);
    expect(find.byIcon(CupertinoIcons.line_horizontal_3), findsNothing);

    await tester.runAsync(guest.leave);
    await tester.runAsync(host.leave);
  });

  testWidgets('a long press offers Play Next and Remove', (tester) async {
    final host = await hostWithQueue(tester, hold: true);
    final engine = host.engine!;
    final last = engine.playlist.last;
    final first = engine.playlist.first.mediaId;

    await _pump(tester, host, QueuePanel(engine: engine));
    await tester.pump();

    await tester.longPress(find.text(jamDisplayTitle(last)));
    await tester.pumpAndSettle();
    expect(find.text(QueueSheetStrings.playNext), findsOneWidget);
    expect(find.text(QueueSheetStrings.remove), findsOneWidget);

    await tester.tap(find.text(QueueSheetStrings.playNext));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      expect(
        await _waitFor(() => engine.playlist[1].mediaId == last.mediaId),
        isTrue,
        reason: 'Play Next puts it straight after the current track',
      );
    });
    expect(engine.playlist.first.mediaId, first);

    await tester.runAsync(host.leave);
  });

  testWidgets('the grip picks a row up', (tester) async {
    // On Android the drag once fell through to the sheet underneath:
    // `ReorderableDragStartListener` wraps its child in a hit-test-deferring
    // `Listener`, and the grip's box was empty.
    final host = await hostWithQueue(tester, hold: true);
    final engine = host.engine!;
    final before = [for (final item in engine.playlist) item.name];

    await _pump(tester, host, QueuePanel(engine: engine));
    await tester.pump();

    // The grip on the last Up Next row, dragged onto the one above it.
    final grip = find.byIcon(CupertinoIcons.line_horizontal_3).last;
    final drag = await tester.startGesture(tester.getCenter(grip));
    await tester.pump(const Duration(milliseconds: 200));
    await drag.moveBy(const Offset(0, -kJamTrackRowHeight));
    await tester.pump();
    await drag.up();
    await tester.pumpAndSettle();

    await tester.runAsync(() async {
      expect(
        await _waitFor(
          () =>
              [for (final item in engine.playlist) item.name].join() !=
              before.join(),
        ),
        isTrue,
        reason: 'the drag should have reordered the queue',
      );
    });

    await tester.runAsync(host.leave);
  });

  testWidgets('a removal the room refuses springs back instead of vanishing '
      'from this phone only', (tester) async {
    // The host's phone is asleep (§3.5): the request cannot go anywhere, so
    // the swipe must not leave the row gone here while it plays on there.
    final previous = JamHostEngine.backgroundSuspendPolicy;
    JamHostEngine.backgroundSuspendPolicy = (_) => true;
    addTearDown(() => JamHostEngine.backgroundSuspendPolicy = previous);
    final host = testSession();
    final guest = testSession(identity: 'Ana');
    final cache = _tempCache();
    final heard = <String>[];
    final sub = guest.notices.listen((n) => heard.add(n.message));
    addTearDown(sub.cancel);
    await tester.runAsync(() async {
      await host.startHost(
        sessionName: 'Van Jam',
        policy: JamPolicy.open,
        discoverable: false,
        paths: _media(),
      );
      await host.hostImport!.done;
      host.hostEngine!.pause();
      expect(await guest.join(host.joinUri!, mediaCacheDir: cache), isTrue);
      expect(await _waitFor(() => guest.engine!.playlist.length == 3), isTrue);
      await host.hostEngine!.handleLifecycleState(AppLifecycleState.paused);
      expect(await _waitFor(() => guest.hostAway), isTrue);
    });
    final engine = guest.engine!;
    expect(engine.canRemove(engine.playlist.last), isTrue);
    final victim = engine.playlist.last.mediaId;

    await _pump(tester, guest, QueuePanel(engine: engine));
    await tester.pump();
    expect(find.byType(JamTrackRow), findsNWidgets(2));

    await tester.drag(
      find.byKey(ValueKey<String>('queue-dismiss-$victim')),
      const Offset(-600, 0),
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(
      find.byType(JamTrackRow),
      findsNWidgets(2),
      reason: 'refused: the row stays',
    );
    expect(heard, contains(kJamHostAsleepTryLater));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async {
      await guest.leave();
      await host.leave();
    });
  });

  testWidgets('renders the same on a dark app theme', (tester) async {
    final host = await hostWithQueue(tester);
    await _pump(
      tester,
      host,
      QueuePanel(engine: host.engine!),
      theme: jamDarkTheme(),
    );
    await tester.pump();
    expect(
      tester.widget<Text>(find.text(QueueSheetStrings.title)).style!.color,
      JamNowPlayingColors.text,
    );
    expect(tester.takeException(), isNull);

    await tester.runAsync(host.leave);
  });
}
