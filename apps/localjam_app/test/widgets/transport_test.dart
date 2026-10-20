import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/design/theme.dart';
import 'package:localjam_app/src/design/tokens.dart';
import 'package:localjam_app/src/widgets/progress.dart';
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

/// The play square's ground.
Color? _squareColor(WidgetTester tester) =>
    (tester
                .widget<AnimatedContainer>(
                  find.descendant(
                    of: find.byType(JamTransport),
                    matching: find.byType(AnimatedContainer),
                  ),
                )
                .decoration!
            as ShapeDecoration)
        .color;

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

      await tester.tap(find.byIcon(CupertinoIcons.play_fill));
      await tester.tap(find.byIcon(CupertinoIcons.forward_end_fill));
      await tester.tap(find.byIcon(CupertinoIcons.backward_end_fill));
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
      expect(find.byIcon(CupertinoIcons.pause_fill), findsOneWidget);

      await tester.pumpWidget(
        _host(JamTransport(state: JamPlaybackState.paused, onPlayPause: () {})),
      );
      await tester.pump(const Duration(milliseconds: 70));
      // Mid-transition both glyphs are on screen: a cross-fade, not a swap.
      expect(find.byIcon(CupertinoIcons.pause_fill), findsOneWidget);
      expect(find.byIcon(CupertinoIcons.play_fill), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.byIcon(CupertinoIcons.pause_fill), findsNothing);
    });

    testWidgets('loading shows a turning ring and swallows the tap', (
      tester,
    ) async {
      var play = 0;
      await tester.pumpWidget(
        _host(
          JamTransport(
            state: JamPlaybackState.loading,
            onPlayPause: () => play++,
          ),
        ),
      );
      expect(find.byType(JamProgressRing), findsOneWidget);
      expect(find.byType(CupertinoActivityIndicator), findsNothing);
      await tester.tap(find.byType(JamProgressRing), warnIfMissed: false);
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
      // Quiet, not a dimmed slab: no opacity over the controls; every glyph
      // in the backdrop's tertiary white, and the square only an outline —
      // no fill to say "button" louder than anything else (CR-25).
      expect(
        find.descendant(
          of: find.byType(JamTransport),
          matching: find.byType(Opacity),
        ),
        findsNothing,
      );
      final glyphs = tester
          .widgetList<Icon>(
            find.descendant(
              of: find.byType(JamTransport),
              matching: find.byType(Icon),
            ),
          )
          .map((i) => i.color);
      expect(glyphs, hasLength(3));
      expect(glyphs, everyElement(JamNowPlayingColors.tertiary));
      expect(_squareColor(tester), JamNowPlayingColors.clear);
      final outline =
          (tester
                      .widget<AnimatedContainer>(
                        find.descendant(
                          of: find.byType(JamTransport),
                          matching: find.byType(AnimatedContainer),
                        ),
                      )
                      .decoration!
                  as ShapeDecoration)
              .shape;
      expect(
        (outline as RoundedSuperellipseBorder).side.color,
        JamNowPlayingColors.separator,
      );
      // Its footprint kept: nothing moves when the host promotes you.
      expect(
        tester.getSize(find.byType(AnimatedContainer)),
        const Size.square(JamMetrics.playSquare),
      );
      // Its reason sits clear of the square, not against it.
      expect(
        tester.getTopLeft(find.text(jamHostControlsPlayback)).dy -
            tester.getBottomLeft(find.byType(AnimatedContainer)).dy,
        greaterThanOrEqualTo(8),
      );
      // Never hidden — visible, and inert.
      expect(find.byIcon(CupertinoIcons.play_fill), findsOneWidget);
      await tester.tap(
        find.byIcon(CupertinoIcons.play_fill),
        warnIfMissed: false,
      );
      expect(play, 0);
    });

    testWidgets('the play square: ivory, warm ink, continuous corners', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(JamTransport(state: JamPlaybackState.paused, onPlayPause: () {})),
      );
      expect(_squareColor(tester), JamNowPlayingColors.playSurface);
      final square = tester.widget<AnimatedContainer>(
        find.descendant(
          of: find.byType(JamTransport),
          matching: find.byType(AnimatedContainer),
        ),
      );
      final shape = (square.decoration! as ShapeDecoration).shape;
      expect(shape, isA<RoundedSuperellipseBorder>());
      expect(
        tester.getSize(find.byType(AnimatedContainer)),
        const Size.square(JamMetrics.playSquare),
      );
      expect(
        tester.widget<Icon>(find.byIcon(CupertinoIcons.play_fill)).color,
        JamNowPlayingColors.playGlyph,
      );
    });

    testWidgets('the play square squeezes under a finger; under reduced '
        'motion it deepens instead', (tester) async {
      await tester.pumpWidget(
        _host(JamTransport(state: JamPlaybackState.paused, onPlayPause: () {})),
      );
      double scale() => tester
          .widget<AnimatedScale>(
            find.descendant(
              of: find.byType(JamTransport),
              matching: find.byType(AnimatedScale),
            ),
          )
          .scale;
      final gesture = await tester.startGesture(
        tester.getCenter(find.byIcon(CupertinoIcons.play_fill)),
      );
      await tester.pump();
      expect(scale(), lessThan(1));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(scale(), 1);

      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: _host(
            JamTransport(state: JamPlaybackState.paused, onPlayPause: () {}),
          ),
        ),
      );
      expect(
        find.descendant(
          of: find.byType(JamTransport),
          matching: find.byType(AnimatedScale),
        ),
        findsNothing,
      );
      expect(_squareColor(tester), JamNowPlayingColors.playSurface);
      final still = await tester.startGesture(
        tester.getCenter(find.byIcon(CupertinoIcons.play_fill)),
      );
      await tester.pump();
      // No movement, but the press still shows (RB-18).
      expect(_squareColor(tester), isNot(JamNowPlayingColors.playSurface));
      await still.up();
      await tester.pump();
      expect(_squareColor(tester), JamNowPlayingColors.playSurface);
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
        find.byIcon(CupertinoIcons.forward_end_fill),
        warnIfMissed: false,
      );
      await tester.tap(find.byIcon(CupertinoIcons.play_fill));
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
      await gesture.moveTo(Offset(track.right + 20, track.center.dy));
      await tester.pump();

      // The ticker keeps publishing while the finger is down; the thumb and
      // the readout must follow the finger, not the ticker.
      await tester.pumpWidget(build(_minute ~/ 10));
      await tester.pump();
      expect(find.text('1:00'), findsOneWidget);

      await gesture.up();
      await tester.pumpAndSettle();
      expect(seeked, _minute);
    });

    testWidgets('the track thickens while held and has no thumb', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(JamScrubber(positionUs: 0, durationUs: _minute, onSeek: (_) {})),
      );
      final track = find.byKey(jamScrubberTrackKey);
      expect(tester.getSize(track).height, 6);
      final gesture = await tester.startGesture(tester.getCenter(track));
      await tester.pumpAndSettle();
      expect(tester.getSize(track).height, 10);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(tester.getSize(track).height, 6);
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
      expect(find.text('0:30'), findsOneWidget);
      // A real minus sign, the Music app's m:ss.
      expect(find.text('\u22121:30'), findsOneWidget);
      final style = tester.widget<Text>(find.text('0:30')).style!;
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
      expect(node.value, '0:30 of 2:00');
      expect(node.increasedValue, '0:35 of 2:00');
      expect(node.decreasedValue, '0:25 of 2:00');
      handle.dispose();
    });
  });
}
