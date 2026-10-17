import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/design/theme.dart';
import 'package:localjam_app/src/widgets/transport.dart';

const int _minute = 60000000;

Widget _host(Widget child, {bool dark = false, double width = 300}) =>
    MaterialApp(
      theme: dark ? jamDarkTheme() : jamLightTheme(),
      home: Scaffold(
        body: Center(
          child: SizedBox(width: width, child: child),
        ),
      ),
    );

void main() {
  group('JamTransport', () {
    testWidgets('names its three controls and fires each', (tester) async {
      var play = 0;
      var next = 0;
      var previous = 0;
      await tester.pumpWidget(
        _host(
          JamTransport(
            state: JamPlaybackState.paused,
            onPlayPause: () => play++,
            onNext: () => next++,
            onPrevious: () => previous++,
          ),
        ),
      );

      expect(find.bySemanticsLabel('Play'), findsOneWidget);
      expect(find.bySemanticsLabel('Next'), findsOneWidget);
      expect(find.bySemanticsLabel('Previous'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.play_arrow_rounded));
      await tester.tap(find.byIcon(Icons.skip_next_rounded));
      await tester.tap(find.byIcon(Icons.skip_previous_rounded));
      expect([play, next, previous], [1, 1, 1]);
    });

    testWidgets('playing offers Pause, and the glyph cross-fades', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          JamTransport(state: JamPlaybackState.playing, onPlayPause: () {}),
        ),
      );
      expect(find.bySemanticsLabel('Pause'), findsOneWidget);
      expect(find.byIcon(Icons.pause_rounded), findsOneWidget);

      await tester.pumpWidget(
        _host(JamTransport(state: JamPlaybackState.paused, onPlayPause: () {})),
      );
      await tester.pump(const Duration(milliseconds: 70));
      // Mid-transition both glyphs are on screen: a cross-fade, not a swap.
      expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.pause_rounded), findsNothing);
    });

    testWidgets('loading shows a ring and swallows the tap', (tester) async {
      var play = 0;
      await tester.pumpWidget(
        _host(
          JamTransport(
            state: JamPlaybackState.loading,
            onPlayPause: () => play++,
          ),
        ),
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.tap(
        find.byType(CircularProgressIndicator),
        warnIfMissed: false,
      );
      expect(play, 0);
    });

    testWidgets('a gated bar dims, goes inert, and says whose call it is', (
      tester,
    ) async {
      var play = 0;
      await tester.pumpWidget(
        _host(
          JamTransport(
            state: JamPlaybackState.paused,
            enabled: false,
            onPlayPause: () => play++,
            onNext: () {},
          ),
        ),
      );

      expect(find.text(jamHostControlsPlayback), findsOneWidget);
      expect(
        tester
            .widget<Opacity>(
              find.descendant(
                of: find.byType(JamTransport),
                matching: find.byType(Opacity),
              ),
            )
            .opacity,
        0.38,
      );
      // Never hidden — visible, and inert.
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
      await tester.tap(
        find.byIcon(Icons.play_arrow_rounded),
        warnIfMissed: false,
      );
      expect(play, 0);
    });

    testWidgets('a missing next callback disables that glyph only', (
      tester,
    ) async {
      var play = 0;
      await tester.pumpWidget(
        _host(
          JamTransport(
            state: JamPlaybackState.paused,
            onPlayPause: () => play++,
          ),
        ),
      );
      await tester.tap(
        find.byIcon(Icons.skip_next_rounded),
        warnIfMissed: false,
      );
      await tester.tap(find.byIcon(Icons.play_arrow_rounded));
      expect(play, 1);
    });
  });

  group('JamScrubber', () {
    testWidgets('a tap on the painted track centre seeks to the middle', (
      tester,
    ) async {
      int? seeked;
      await tester.pumpWidget(
        _host(
          JamScrubber(
            positionUs: 0,
            durationUs: _minute,
            onSeek: (us) => seeked = us,
          ),
        ),
      );

      final track = tester.getRect(find.byKey(jamScrubberTrackKey));
      final hit = tester.getRect(find.byKey(jamScrubberHitKey));

      // The regression this guards: an iOS build whose taps landed ~24 pt
      // above the painted slider. Paint and touch must share a centre line.
      expect(hit.height, 44);
      expect(track.center.dy, closeTo(hit.center.dy, 0.01));

      await tester.tapAt(track.center);
      await tester.pumpAndSettle();
      expect(seeked, isNotNull);
      expect(seeked! / _minute, closeTo(0.5, 0.01));
    });

    testWidgets('dragging holds its own value against an incoming position', (
      tester,
    ) async {
      int? seeked;
      Widget build(int positionUs) => _host(
        JamScrubber(
          positionUs: positionUs,
          durationUs: _minute,
          onSeek: (us) => seeked = us,
        ),
      );

      await tester.pumpWidget(build(0));
      final track = tester.getRect(find.byKey(jamScrubberTrackKey));
      final gesture = await tester.startGesture(
        Offset(track.left + 20, track.center.dy),
      );
      await tester.pump();
      await gesture.moveTo(Offset(track.right - 11, track.center.dy));
      await tester.pump();

      // The ticker keeps publishing while the finger is down; the thumb and
      // the readout must follow the finger, not the ticker.
      await tester.pumpWidget(build(_minute ~/ 10));
      await tester.pump();
      expect(find.text('01:00'), findsOneWidget);

      await gesture.up();
      await tester.pumpAndSettle();
      expect(seeked, _minute);
    });

    testWidgets('shows elapsed and remaining in tabular figures', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          JamScrubber(
            positionUs: 30000000,
            durationUs: 2 * _minute,
            onSeek: (_) {},
          ),
        ),
      );
      expect(find.text('00:30'), findsOneWidget);
      expect(find.text('-01:30'), findsOneWidget);
      final style = tester.widget<Text>(find.text('00:30')).style!;
      expect(style.fontFeatures, contains(const FontFeature.tabularFigures()));
    });

    testWidgets('an unknown duration renders inert with a dashed remaining', (
      tester,
    ) async {
      var seeks = 0;
      await tester.pumpWidget(
        _host(
          JamScrubber(positionUs: 0, durationUs: null, onSeek: (_) => seeks++),
        ),
      );
      expect(find.text('--:--'), findsOneWidget);
      await tester.tapAt(
        tester.getRect(find.byKey(jamScrubberTrackKey)).center,
      );
      expect(seeks, 0);
    });

    testWidgets('a disabled scrubber does not seek', (tester) async {
      var seeks = 0;
      await tester.pumpWidget(
        _host(
          JamScrubber(
            positionUs: 0,
            durationUs: _minute,
            enabled: false,
            onSeek: (_) => seeks++,
          ),
        ),
      );
      await tester.tapAt(
        tester.getRect(find.byKey(jamScrubberTrackKey)).center,
      );
      await tester.pumpAndSettle();
      expect(seeks, 0);
    });

    testWidgets('announces itself as a slider with a spoken value', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(
          JamScrubber(
            positionUs: 30000000,
            durationUs: 2 * _minute,
            onSeek: (_) {},
          ),
        ),
      );
      final node = tester.getSemantics(
        find.bySemanticsLabel('Playback position'),
      );
      expect(node.value, '00:30 of 02:00');
      expect(node.increasedValue, '00:35 of 02:00');
      expect(node.decreasedValue, '00:25 of 02:00');
      handle.dispose();
    });
  });
}
