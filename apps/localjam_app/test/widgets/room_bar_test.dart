/// The mini player's look and its two gestures. The session-bound `RoomBar`
/// (and the "This jam ended" dock) is exercised by the router tests; what is
/// worth pinning here is that a swipe up opens the room and a swipe down does
/// not, because that asymmetry is easy to lose in a refactor.
library;

import 'package:flutter/material.dart';
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
      _host(
        const JamRoomBar(
          title: 'Windowlicker',
          subtitle: "Ana's kitchen",
          progress: 0.5,
        ),
      ),
    );

    expect(find.text('Windowlicker'), findsOneWidget);
    expect(find.text("Ana's kitchen"), findsOneWidget);
    // Nothing was handed an artwork widget, so the slot's placeholder stands
    // in rather than the bar collapsing.
    expect(find.byType(JamRoomBarArtworkPlaceholder), findsOneWidget);
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
    expect(find.byType(IconButton), findsNothing);

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
    expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
    await tester.tap(find.byType(IconButton));
    expect(toggled, 1);
  });

  testWidgets('the people slot is rendered when given', (tester) async {
    await tester.pumpWidget(
      _host(
        const JamRoomBar(
          title: 'Track',
          subtitle: 'Room',
          people: Text('+3'),
          artwork: SizedBox.shrink(),
        ),
      ),
    );
    expect(find.text('+3'), findsOneWidget);
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
      tester.getSemantics(find.byType(JamRoomBar)),
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
              progress: 0.2,
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
