import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/design/theme.dart';
import 'package:localjam_app/src/design/tokens.dart';
import 'package:localjam_app/src/widgets/avatar.dart';
import 'package:localjam_app/src/widgets/track_row.dart';

Future<void> pumpRow(WidgetTester tester, Widget child, {bool dark = false}) {
  final theme = dark ? jamDarkTheme() : jamLightTheme();
  // An inner Theme, not just MaterialApp's: MaterialApp animates a theme
  // change, so a single pump would still be halfway through the old palette.
  return tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: Theme(
        data: theme,
        child: Scaffold(body: child),
      ),
    ),
  );
}

void main() {
  group('JamTrackRow', () {
    testWidgets('shows title and byline in both themes, at 68 high', (
      tester,
    ) async {
      for (final dark in [false, true]) {
        await pumpRow(
          tester,
          const JamTrackRow(title: 'Blue Moon', byline: 'Billie · Nights'),
          dark: dark,
        );
        expect(find.text('Blue Moon'), findsOneWidget);
        expect(find.text('Billie · Nights'), findsOneWidget);
        expect(
          tester.getSize(find.byType(JamTrackRow)).height,
          kJamTrackRowHeight,
        );
      }
    });

    testWidgets('marks the current track in accent and announces it', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpRow(
        tester,
        const JamTrackRow(title: 'Blue Moon', isCurrent: true),
      );
      expect(
        tester.widget<Text>(find.text('Blue Moon')).style!.color,
        JamColors.light.accent,
      );
      expect(
        find.bySemanticsLabel(RegExp(JamTrackRowStrings.nowPlaying)),
        findsOneWidget,
      );
      handle.dispose();
    });

    testWidgets('credits every adder, you included', (tester) async {
      await pumpRow(
        tester,
        const JamTrackRow(title: 'Blue Moon', addedByName: 'Silky Puffin'),
      );
      expect(find.byType(JamAvatar), findsOneWidget);
      expect(
        tester.widget<JamAvatar>(find.byType(JamAvatar)).ring,
        JamAvatarRing.none,
      );

      // Your own row keeps its face — and wears the apricot ring, drawn from
      // the name the caller hands over rather than from the word "You".
      await pumpRow(
        tester,
        const JamTrackRow(
          title: 'Blue Moon',
          addedByName: 'You',
          addedByAvatarName: 'Chill Toucan',
          addedByYou: true,
        ),
      );
      final you = tester.widget<JamAvatar>(find.byType(JamAvatar));
      expect(you.ring, JamAvatarRing.you);
      expect(you.name, 'Chill Toucan');

      // Nothing to credit: no face, and no gap where one would have been.
      await pumpRow(tester, const JamTrackRow(title: 'Blue Moon'));
      expect(find.byType(JamAvatar), findsNothing);
    });

    testWidgets('trails a duration, a prefetch ring, or an error glyph', (
      tester,
    ) async {
      await pumpRow(
        tester,
        const JamTrackRow(
          title: 'Blue Moon',
          duration: Duration(minutes: 3, seconds: 7),
        ),
      );
      expect(find.text('03:07'), findsOneWidget);

      await pumpRow(
        tester,
        const JamTrackRow(title: 'Blue Moon', prefetchProgress: 0.4),
      );
      expect(
        tester
            .widget<CircularProgressIndicator>(
              find.byType(CircularProgressIndicator),
            )
            .value,
        0.4,
      );

      await pumpRow(
        tester,
        const JamTrackRow(title: 'Blue Moon', hasError: true),
      );
      expect(find.byIcon(Icons.error_outline_rounded), findsOneWidget);
    });

    testWidgets('offers a drag handle only when reordering is allowed', (
      tester,
    ) async {
      await pumpRow(tester, const JamTrackRow(title: 'Blue Moon'));
      expect(find.byIcon(Icons.drag_handle_rounded), findsNothing);

      await pumpRow(
        tester,
        const JamTrackRow(title: 'Blue Moon', showDragHandle: true),
      );
      expect(find.byIcon(Icons.drag_handle_rounded), findsOneWidget);
    });

    testWidgets('lifts onto surfaceElevated while dragging', (tester) async {
      await pumpRow(
        tester,
        const JamTrackRow(title: 'Blue Moon', dragging: true),
      );
      final container = tester.widget<AnimatedContainer>(
        find.byType(AnimatedContainer),
      );
      expect(
        (container.decoration! as BoxDecoration).color,
        JamColors.light.surfaceElevated,
      );
      expect(find.byType(Transform), findsWidgets);
    });

    testWidgets('fills while pressed', (tester) async {
      await pumpRow(tester, JamTrackRow(title: 'Blue Moon', onTap: () {}));
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(JamTrackRow)),
      );
      await tester.pump(JamDuration.fast);
      expect(
        (tester
                    .widget<AnimatedContainer>(find.byType(AnimatedContainer))
                    .decoration!
                as BoxDecoration)
            .color,
        JamColors.light.surfaceMuted,
      );
      await gesture.up();
      await tester.pumpAndSettle();
    });
  });

  group('formatTrackDuration', () {
    test('is mm:ss, and h:mm:ss past an hour', () {
      expect(formatTrackDuration(const Duration(seconds: 7)), '00:07');
      expect(
        formatTrackDuration(const Duration(minutes: 12, seconds: 3)),
        '12:03',
      );
      expect(
        formatTrackDuration(const Duration(hours: 1, minutes: 2, seconds: 3)),
        '1:02:03',
      );
    });
  });
}
