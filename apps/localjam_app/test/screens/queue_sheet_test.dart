/// The queue sheet: the two groups §5 asks for, the reorder maths behind
/// them, and the capability gate that must never silently remove a control.
library;

import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/design/theme.dart';
import 'package:localjam_app/src/state/session_controller.dart';
import 'package:localjam_app/src/util/format.dart';
import 'package:localjam_app/src/widgets/buttons.dart';
import 'package:localjam_app/src/widgets/empty_state.dart';
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

  testWidgets('a host queue splits into NOW PLAYING and NEXT UP', (
    tester,
  ) async {
    final host = testSession();
    await tester.runAsync(() async {
      // `startHost` cues the first track, which is what gives the sheet a
      // NOW PLAYING group to pin.
      await host.startHost(
        sessionName: 'Van Jam',
        discoverable: false,
        paths: _media(),
      );
      // The files import behind the already-open room.
      await host.hostImport!.done;
    });
    await tester.pump();
    expect(host.engine!.playlist.length, 3);

    await _pump(tester, host, QueuePanel(engine: host.engine!));
    await tester.pump();

    expect(find.text(QueueSheetStrings.nowPlaying), findsOneWidget);
    expect(find.text(QueueSheetStrings.nextUp), findsOneWidget);
    expect(find.byType(JamTrackRow), findsNWidgets(3));
    expect(find.text(QueueSheetStrings.count(3)), findsOneWidget);

    // Reorderable, and the grip is visible rather than a hidden long-press.
    expect(find.byType(SliverReorderableList), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.line_horizontal_3), findsNWidgets(2));

    await tester.runAsync(host.leave);
  });

  testWidgets('NEXT UP lists what plays next once the room has gone round, '
      'and the pinned track is not a button', (tester) async {
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
    expect(top(titles[1]), lessThan(top(titles[2])), reason: 'pinned first');
    expect(
      top(titles[2]),
      lessThan(top(titles[0])),
      reason: 'the last track plays next, then round to the first',
    );
    // Picking the track that is on changes nothing (§5.2), so it is inert.
    final pinned = tester.widget<JamTrackRow>(
      find.ancestor(
        of: find.text(titles[1]),
        matching: find.byType(JamTrackRow),
      ),
    );
    expect(pinned.onTap, isNull);

    await tester.runAsync(host.leave);
  });

  testWidgets('an empty queue offers the one thing to do', (tester) async {
    final host = testSession();
    await tester.runAsync(
      () => host.startHost(sessionName: 'Quiet Jam', discoverable: false),
    );
    await tester.pump();

    await _pump(tester, host, QueuePanel(engine: host.engine!));
    await tester.pump();

    expect(find.byType(JamEmptyState), findsOneWidget);
    expect(find.text(QueueSheetStrings.emptyTitle), findsOneWidget);
    expect(find.text(QueueSheetStrings.emptyCanAdd), findsOneWidget);
    expect(find.text(QueueSheetStrings.addMusic), findsOneWidget);

    await tester.runAsync(host.leave);
  });

  testWidgets('a guest who may not add is told so, not quietly stripped', (
    tester,
  ) async {
    // The iOS report: the Add control simply vanished, which reads as a bug
    // rather than as a rule the host set.
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
    final add = tester.widget<JamButton>(
      find.widgetWithText(JamButton, QueueSheetStrings.add),
    );
    expect(add.variant, JamButtonVariant.plain);
    expect(add.onPressed, isNull);

    await tester.runAsync(guest.leave);
    await tester.runAsync(host.leave);
  });

  testWidgets('the grip picks a row up instead of dragging the sheet', (
    tester,
  ) async {
    // On Android the drag fell through to the sheet, which grew instead of
    // lifting the row: `ReorderableDragStartListener` wraps its child in a
    // hit-test-deferring `Listener`, and the grip's box was empty.
    final host = testSession();
    await tester.runAsync(() async {
      await host.startHost(
        sessionName: 'Van Jam',
        discoverable: false,
        paths: _media(),
      );
      await host.hostImport!.done;
    });
    await tester.pump();
    final engine = host.engine!;
    // Starting a jam with a queue now starts the music, and a running
    // position ticker is a live `Ticker` that `pumpAndSettle` waits on
    // forever. This test is about the drag; freeze the transport. In the
    // real zone: the engine (and the ticker's subscription to its states)
    // were created there, and the paused snapshot that stops the ticker is
    // delivered there too — the import now starts the music from that zone.
    await tester.runAsync(() async {
      host.hostEngine!.pause();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    final before = [for (final item in engine.playlist) item.name];

    await _pump(tester, host, QueuePanel(engine: engine));
    await tester.pump();

    // The grip on the last NEXT UP row, dragged onto the one above it.
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
        reason: 'the drag should have reordered the queue, not the sheet',
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
    expect(find.byType(JamTrackRow), findsNWidgets(3));

    await tester.drag(
      find.byKey(ValueKey<String>('queue-dismiss-$victim')),
      const Offset(-600, 0),
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(
      find.byType(JamTrackRow),
      findsNWidgets(3),
      reason: 'refused: the row stays',
    );
    expect(heard, contains(kJamHostAsleepTryLater));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async {
      await guest.leave();
      await host.leave();
    });
  });

  testWidgets('the sheet opens at the spec height and renders dark', (
    tester,
  ) async {
    final host = testSession();
    await tester.runAsync(
      () => host.startHost(sessionName: 'Dark Jam', discoverable: false),
    );
    await tester.pump();

    late BuildContext sheetContext;
    await _pump(
      tester,
      host,
      Builder(
        builder: (context) {
          sheetContext = context;
          return const SizedBox.shrink();
        },
      ),
      theme: jamDarkTheme(),
    );

    unawaitedShow(sheetContext, host.engine!);
    await tester.pumpAndSettle();

    final sheet = tester.widget<DraggableScrollableSheet>(
      find.byType(DraggableScrollableSheet),
    );
    // Opens at the large detent, clamped under the status bar.
    expect(sheet.initialChildSize, sheet.maxChildSize);
    expect(sheet.maxChildSize, greaterThan(0.9));
    expect(find.text(QueueSheetStrings.title), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.runAsync(host.leave);
  });
}

/// `showQueueSheet` without the analyzer complaining about the dropped future.
void unawaitedShow(BuildContext context, JamEngine engine) {
  showQueueSheet(context, engine).ignore();
}
