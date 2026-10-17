/// The queue sheet: the two groups §5 asks for, the reorder maths behind
/// them, and the capability gate that must never silently remove a control.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/design/theme.dart';
import 'package:localjam_app/src/state/session_controller.dart';
import 'package:localjam_app/src/widgets/buttons.dart';
import 'package:localjam_app/src/widgets/empty_state.dart';
import 'package:localjam_app/src/widgets/queue_sheet.dart';
import 'package:localjam_app/src/widgets/track_row.dart';
import 'package:localjam_client/localjam_client.dart';

import '../harness.dart';

/// Three real files, so the engine has something it can actually register.
List<String> _media() => [
  for (final name in ['track1.m4a', 'track2.m4a', 'track3.m4a'])
    '../../test-media/$name',
];

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
  group('queueReorderTarget', () {
    final playlist = [
      for (final id in ['a', 'b', 'c', 'd']) _item(id),
    ];

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

    test('accounts for a current track that is not first', () {
      expect(
        queueReorderTarget(
          playlist: playlist,
          currentId: 'c',
          oldIndex: 0,
          newIndex: 2,
        ),
        (mediaId: 'a', toIndex: 3),
      );
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

    test('a NEXT UP drop can never land in front of the current track', () {
      // playlist a b c d with `c` playing. Dropping `a` in the middle of
      // NEXT UP put it at index 1 — still ahead of the track the room is
      // listening to, which silently changed what was playing. NOW PLAYING
      // is not a drop target: the floor is the slot just after `c`.
      expect(
        queueReorderTarget(
          playlist: playlist,
          currentId: 'c',
          oldIndex: 0,
          newIndex: 1,
        ),
        (mediaId: 'a', toIndex: 2),
      );
    });

    test('a drop that only bumps against that floor sends nothing', () {
      // Dragging `d` to the top of NEXT UP clamps it back to where it
      // already is, so there is no move to send.
      expect(
        queueReorderTarget(
          playlist: playlist,
          currentId: 'c',
          oldIndex: 2,
          newIndex: 0,
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
    expect(find.byIcon(Icons.drag_handle_rounded), findsNWidgets(2));

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
    expect(add.variant, JamButtonVariant.tertiary);
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
    await tester.runAsync(
      () => host.startHost(
        sessionName: 'Van Jam',
        discoverable: false,
        paths: _media(),
      ),
    );
    await tester.pump();
    final engine = host.engine!;
    // Starting a jam with a queue now starts the music, and a running
    // position ticker is a live `Ticker` that `pumpAndSettle` waits on
    // forever. This test is about the drag; freeze the transport.
    host.hostEngine!.pause();
    await tester.pump();
    final before = [for (final item in engine.playlist) item.name];

    await _pump(tester, host, QueuePanel(engine: engine));
    await tester.pump();

    // The grip on the last NEXT UP row, dragged onto the one above it.
    final grip = find.byIcon(Icons.drag_handle_rounded).last;
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
    expect(sheet.initialChildSize, 0.82);
    expect(sheet.maxChildSize, 0.96);
    expect(find.text(QueueSheetStrings.title), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.runAsync(host.leave);
  });
}

/// `showQueueSheet` without the analyzer complaining about the dropped future.
void unawaitedShow(BuildContext context, JamEngine engine) {
  showQueueSheet(context, engine).ignore();
}
