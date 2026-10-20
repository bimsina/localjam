/// Now Playing at the largest text sizes (R10): on the smallest phones,
/// for a host and for a guest whose transport is gated, nothing overflows,
/// no control is drawn over another, every control is whole and full size,
/// and the song's title is on the page.
library;

import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/design/theme.dart';
import 'package:localjam_app/src/design/tokens.dart';
import 'package:localjam_app/src/screens/room_screen.dart';
import 'package:localjam_app/src/state/session_controller.dart';
import 'package:localjam_app/src/widgets/artwork.dart';
import 'package:localjam_app/src/widgets/queue_sheet.dart';
import 'package:localjam_app/src/widgets/transport.dart';
import 'package:localjam_client/localjam_client.dart';

import '../fixtures.dart';
import '../harness.dart';

/// A title long enough to need the marquee on any phone.
const String _title = 'Kun Jaat Ko Ho Timi (feat. Bipul Chettri)';

Future<bool> _waitFor(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  return condition();
}

/// Hosts a room playing one tagged track (title, artist, album).
Future<void> _hostTrack(JamSessionController session) async {
  final tracks = makeTestTracks(count: 1);
  await session.startHost(
    sessionName: 'Rohan’s Birthday Road Trip to Pokhara',
    discoverable: false,
  );
  final host = session.hostEngine!;
  final file = File(tracks.single);
  final item = await JamHostServer.describeFile(
    file,
    kind: MediaKind.audio,
    mime: 'audio/wav',
    durationUs: 300000000,
    title: _title,
    artist: 'Bipul Chettri',
    album: 'Maya',
  );
  host.debugServer.addMedia(item, file);
  host.setMedia(item.mediaId);
  host.pause();
}

Future<void> _pumpRoom(
  WidgetTester tester,
  JamSessionController session, {
  required Size size,
  required double scale,
}) async {
  const insets = EdgeInsets.only(top: 20);
  tester.view.physicalSize = size * tester.view.devicePixelRatio;
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    JamSession(
      controller: session,
      child: MaterialApp(
        theme: jamLightTheme(),
        home: MediaQuery(
          data: MediaQueryData(
            size: size,
            padding: insets,
            viewPadding: insets,
            textScaler: TextScaler.linear(scale),
          ),
          child: const RoomScreen(),
        ),
      ),
    ),
  );
  // Not pumpAndSettle: a guest's room keeps a sync indicator moving.
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Every control whole, on the page, at full size, and apart.
void _expectWholeAndApart(
  WidgetTester tester,
  Size size, {
  String? gated,
  bool title = true,
}) {
  expect(tester.takeException(), isNull, reason: 'no overflow');
  Rect rect(Finder finder) {
    expect(finder, findsOneWidget);
    return tester.getRect(finder);
  }

  final scrubber = rect(find.byType(JamScrubber));
  final transport = rect(find.byType(JamTransport));
  final faces = rect(find.byKey(kJamRoomFacesKey));
  final upNext = rect(find.byIcon(CupertinoIcons.list_bullet));
  for (final (what, r) in [
    ('the timeline', scrubber),
    ('the transport', transport),
    ('the faces', faces),
    ('Up Next', upNext),
  ]) {
    expect(r.top, greaterThanOrEqualTo(0), reason: what);
    expect(r.bottom, lessThanOrEqualTo(size.height), reason: '$what clipped');
    expect(r.left, greaterThanOrEqualTo(0), reason: what);
    expect(r.right, lessThanOrEqualTo(size.width), reason: what);
  }
  // Never drawn over each other: timeline, transport, footer, in order.
  expect(scrubber.bottom, lessThanOrEqualTo(transport.top));
  expect(transport.bottom, lessThanOrEqualTo(faces.top));
  expect(transport.bottom, lessThanOrEqualTo(upNext.top));
  // Full size: the play square is never scaled down to fit.
  expect(
    tester.getSize(
      find.descendant(
        of: find.byType(JamTransport),
        matching: find.byType(AnimatedContainer),
      ),
    ),
    const Size.square(JamMetrics.playSquare),
  );
  if (gated != null) {
    final why = rect(find.text(gated));
    expect(why.bottom, lessThanOrEqualTo(faces.top), reason: 'gated line');
    expect(why.bottom, lessThanOrEqualTo(size.height));
  }
  if (title) {
    // The song is on the page: its title starts below the room's header
    // and above the controls.
    final song = tester.getRect(find.text(_title).first);
    expect(song.top, greaterThanOrEqualTo(0));
    expect(song.top, lessThan(scrubber.top));
  }
}

void main() {
  const sizes = [Size(320, 568), Size(375, 667), Size(375, 812)];
  // 2×: Android's largest; 3.12×: iOS's largest accessibility size.
  const scales = [2.0, 3.12];

  for (final size in sizes) {
    for (final scale in scales) {
      final where = '${size.width.toInt()}×${size.height.toInt()} at $scale×';

      testWidgets('$where: the host\'s player holds together', (tester) async {
        final session = testSession();
        await tester.runAsync(() => _hostTrack(session));
        await _pumpRoom(tester, session, size: size, scale: scale);
        _expectWholeAndApart(tester, size);

        // Up Next opens in place of the song, and nothing breaks.
        await tester.tap(find.bySemanticsLabel(JamRoomStrings.queue));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byType(QueuePanel), findsOneWidget);
        _expectWholeAndApart(tester, size, title: false);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(session.leave);
      });

      testWidgets('$where: an empty room keeps Add Songs clear of the footer', (
        tester,
      ) async {
        final session = testSession();
        await tester.runAsync(
          () => session.startHost(sessionName: 'Empty', discoverable: false),
        );
        await _pumpRoom(tester, session, size: size, scale: scale);
        expect(tester.takeException(), isNull);
        final add = tester.getRect(find.text(JamRoomStrings.addSongs));
        expect(add.bottom, lessThanOrEqualTo(size.height));
        expect(
          add.bottom,
          lessThanOrEqualTo(tester.getRect(find.byKey(kJamRoomFacesKey)).top),
        );

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(session.leave);
      });
    }
  }

  testWidgets('the cover shrinks with the text, then gives way to the song', (
    tester,
  ) async {
    final session = testSession();
    await tester.runAsync(() => _hostTrack(session));
    // An iPhone SE.
    const size = Size(375, 667);

    await _pumpRoom(tester, session, size: size, scale: 1);
    final cover = tester.getSize(find.byType(JamArtworkTile)).width;
    expect(cover, greaterThan(240));

    await _pumpRoom(tester, session, size: size, scale: 2);
    final smaller = tester.getSize(find.byType(JamArtworkTile)).width;
    expect(smaller, lessThan(cover));
    expect(smaller, greaterThanOrEqualTo(kRoomArtFloor));

    // Past its floor the cover goes: the title wraps instead of scrolling
    // by, so the whole of it can be read.
    await _pumpRoom(tester, session, size: size, scale: 3.12);
    expect(find.byType(JamArtworkTile), findsNothing);
    final title = tester.widget<Text>(find.text(_title));
    expect(title.maxLines, isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(session.leave);
  });

  for (final size in sizes) {
    testWidgets('${size.width.toInt()}×${size.height.toInt()} at 3.12×: a '
        'guest without playback control sees the transport whole, why it '
        'is dimmed, and the footer below it', (tester) async {
      // The tallest player there is: the gated line under the transport.
      final previousHttp = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = previousHttp);
      final host = testSession();
      final guest = testSession(identity: 'Velvet Sloth');
      final cache = Directory.systemTemp.createTempSync('localjam_ax');
      addTearDown(() => cache.deleteSync(recursive: true));
      await tester.runAsync(() async {
        await _hostTrack(host);
        expect(await guest.join(host.joinUri!, mediaCacheDir: cache), isTrue);
        expect(
          await _waitFor(() {
            final engine = guest.engine;
            final id = engine?.currentItem?.mediaId;
            return engine is JamGuestEngine &&
                id != null &&
                (engine.prefetchStates.value[id]?.ready ?? false);
          }),
          isTrue,
        );
      });
      expect(guest.engine!.can(JamCapability.controlPlayback), isFalse);
      await _pumpRoom(tester, guest, size: size, scale: 3.12);
      _expectWholeAndApart(tester, size, gated: jamHostControlsPlayback);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(guest.leave);
      await tester.runAsync(host.leave);
    });
  }
}
