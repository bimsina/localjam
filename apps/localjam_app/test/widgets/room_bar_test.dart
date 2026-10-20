/// The mini player's look and its two gestures. The session-bound `RoomBar`
/// (and the "This jam ended" dock) is exercised by the router tests; what is
/// worth pinning here is that a swipe up opens the room and a swipe down does
/// not, because that asymmetry is easy to lose in a refactor.
library;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:localjam_app/src/widgets/artwork.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/design/theme.dart';
import 'package:localjam_app/src/widgets/room_bar.dart';

Widget _host(Widget bar, {ThemeData? theme}) => MaterialApp(
  theme: theme ?? jamLightTheme(),
  home: Scaffold(bottomNavigationBar: bar),
);

void main() {
  testWidgets('shows the track over the session name', (tester) async {
    await tester.pumpWidget(
      _host(const JamRoomBar(title: 'Windowlicker', subtitle: "Ana's kitchen")),
    );

    expect(find.text('Windowlicker'), findsOneWidget);
    expect(find.text("Ana's kitchen"), findsOneWidget);
    // Nothing was handed an artwork widget, so the slot's placeholder stands
    // in rather than the bar collapsing.
    expect(find.byType(JamArtworkTile), findsOneWidget);
  });

  testWidgets('a tap opens the room', (tester) async {
    var opened = 0;
    await tester.pumpWidget(
      _host(
        JamRoomBar(
          title: 'Windowlicker',
          subtitle: 'Room',
          onOpen: () => opened++,
        ),
      ),
    );

    await tester.tap(find.byType(JamRoomBar));
    expect(opened, 1);
  });

  testWidgets('a swipe up opens the room and a swipe down does nothing', (
    tester,
  ) async {
    var opened = 0;
    await tester.pumpWidget(
      _host(
        JamRoomBar(
          title: 'Windowlicker',
          subtitle: 'Room',
          onOpen: () => opened++,
        ),
      ),
    );

    await tester.fling(find.byType(JamRoomBar), const Offset(0, -80), 1000);
    await tester.pumpAndSettle();
    expect(opened, 1);

    await tester.fling(find.byType(JamRoomBar), const Offset(0, 80), 1000);
    await tester.pumpAndSettle();
    expect(opened, 1, reason: 'down is deliberately inert');
  });

  testWidgets('the transport slot is absent without a callback', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(const JamRoomBar(title: 'Track', subtitle: 'Room')),
    );
    expect(find.bySemanticsLabel(JamRoomBarStrings.play), findsNothing);
    expect(find.bySemanticsLabel(JamRoomBarStrings.next), findsNothing);

    var toggled = 0;
    await tester.pumpWidget(
      _host(
        JamRoomBar(
          title: 'Track',
          subtitle: 'Room',
          playing: true,
          onPlayPause: () => toggled++,
        ),
      ),
    );
    expect(find.byIcon(CupertinoIcons.pause_fill), findsOneWidget);
    await tester.tap(find.byIcon(CupertinoIcons.pause_fill));
    expect(toggled, 1);
  });

  testWidgets('next is offered when permitted, and only on a wide enough '
      'capsule', (tester) async {
    var skipped = 0;
    Widget bar() => JamRoomBar(
      title: 'Track',
      subtitle: 'Room',
      onPlayPause: () {},
      onNext: () => skipped++,
    );
    await tester.pumpWidget(_host(bar()));
    await tester.tap(find.byIcon(CupertinoIcons.forward_end_fill));
    expect(skipped, 1);

    // The iPad sidebar dock (~240 wide) keeps both glyphs…
    await tester.pumpWidget(
      _host(Center(child: SizedBox(width: 240, child: bar()))),
    );
    expect(find.byIcon(CupertinoIcons.forward_end_fill), findsOneWidget);
    // …and only a capsule narrower than any real one drops next.
    await tester.pumpWidget(
      _host(Center(child: SizedBox(width: 200, child: bar()))),
    );
    expect(find.byIcon(CupertinoIcons.forward_end_fill), findsNothing);
    expect(find.byIcon(CupertinoIcons.play_fill), findsOneWidget);
  });

  testWidgets('at accessibility sizes the capsule keeps its height and drops '
      'to one line rather than clipping', (tester) async {
    Widget bar({String? alert}) => MediaQuery(
      data: const MediaQueryData(
        size: Size(390, 844),
        textScaler: TextScaler.linear(3),
      ),
      child: JamRoomBar(
        title: 'A Song',
        subtitle: 'Van Jam',
        alert: alert,
        onPlayPause: () {},
        onNext: () {},
      ),
    );
    await tester.pumpWidget(_host(bar()));
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byType(JamRoomBar)).height, kJamRoomBarHeight);
    expect(find.text('A Song'), findsOneWidget);
    expect(find.text('Van Jam'), findsNothing);
    expect(find.byIcon(CupertinoIcons.play_fill), findsOneWidget);

    // A problem is what matters off Now Playing: it takes the one line.
    await tester.pumpWidget(_host(bar(alert: 'Headphones disconnected')));
    expect(tester.takeException(), isNull);
    expect(find.text('Headphones disconnected'), findsOneWidget);
    expect(find.text('A Song'), findsNothing);
  });

  testWidgets('a capsule: 64 tall, no progress line, a problem replaces the '
      "room's name", (tester) async {
    await tester.pumpWidget(
      _host(
        const JamRoomBar(
          title: 'Track',
          subtitle: 'Room',
          alert: 'Headphones disconnected',
        ),
      ),
    );
    expect(tester.getSize(find.byType(JamRoomBar)).height, 64);
    expect(find.text('Room'), findsNothing);
    expect(find.text('Headphones disconnected'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('is announced as one button with the track and the room', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _host(
        JamRoomBar(title: 'Windowlicker', subtitle: 'Kitchen', onOpen: () {}),
      ),
    );

    expect(
      tester.getSemantics(find.text('Windowlicker')),
      matchesSemantics(
        label: 'Windowlicker. Kitchen',
        hint: JamRoomBarStrings.open,
        isButton: true,
        hasTapAction: true,
      ),
    );
    handle.dispose();
  });

  testWidgets('renders on the dark palette and with animations off', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: jamDarkTheme(),
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Scaffold(
            bottomNavigationBar: JamRoomBar(
              title: 'Track',
              subtitle: 'Room',
              playing: true,
              onPlayPause: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Track'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
