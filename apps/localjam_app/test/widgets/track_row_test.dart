import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/design/theme.dart';
import 'package:localjam_app/src/design/tokens.dart';
import 'package:localjam_app/src/widgets/avatar.dart';
import 'package:localjam_app/src/widgets/list.dart';
import 'package:localjam_app/src/widgets/section.dart';
import 'package:localjam_app/src/widgets/track_row.dart';

Future<void> pumpRow(WidgetTester tester, Widget child, {bool dark = false}) {
  final theme = dark ? jamDarkTheme() : jamLightTheme();
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
    testWidgets('title and byline in both themes, 60 tall', (tester) async {
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
        expect(kJamTrackRowHeight, 60);
      }
    });

    testWidgets('credits the adder in words with the length', (tester) async {
      await pumpRow(
        tester,
        const JamTrackRow(
          title: 'Blue Moon',
          addedByName: 'Mia',
          duration: Duration(minutes: 3, seconds: 42),
        ),
      );
      expect(find.text('Added by Mia · 3:42'), findsOneWidget);
      expect(find.byType(JamAvatar), findsNothing);

      await pumpRow(
        tester,
        const JamTrackRow(
          title: 'Blue Moon',
          addedByName: 'You',
          addedByYou: true,
        ),
      );
      expect(find.text(JamTrackRowStrings.addedByYou), findsOneWidget);
    });

    testWidgets('marks the current song in tint and announces it', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpRow(
        tester,
        const JamTrackRow(title: 'Blue Moon', isCurrent: true),
      );
      expect(
        tester.widget<Text>(find.text('Blue Moon')).style!.color,
        JamColors.light.tint,
      );
      expect(
        find.bySemanticsLabel(RegExp(JamTrackRowStrings.nowPlaying)),
        findsOneWidget,
      );
      handle.dispose();
    });

    testWidgets('white on the backdrop', (tester) async {
      await pumpRow(
        tester,
        const JamTrackRow(
          title: 'Blue Moon',
          addedByName: 'Mia',
          onBackdrop: true,
        ),
      );
      expect(
        tester.widget<Text>(find.text('Blue Moon')).style!.color,
        JamNowPlayingColors.text,
      );
      expect(
        tester.widget<Text>(find.text('Added by Mia')).style!.color,
        JamNowPlayingColors.secondary,
      );
    });

    testWidgets('a failure states its reason in danger', (tester) async {
      await pumpRow(
        tester,
        const JamTrackRow(
          title: 'Blue Moon',
          hasError: true,
          errorText: 'Unsupported format',
        ),
      );
      expect(
        tester.widget<Text>(find.text('Unsupported format')).style!.color,
        JamColors.light.danger,
      );
    });

    testWidgets('a fetch in progress shows a revealing indicator', (
      tester,
    ) async {
      await pumpRow(
        tester,
        const JamTrackRow(title: 'Blue Moon', prefetchProgress: 0.4),
      );
      expect(find.byType(CupertinoActivityIndicator), findsOneWidget);
    });

    testWidgets('offers a drag handle only when reordering is allowed', (
      tester,
    ) async {
      await pumpRow(tester, const JamTrackRow(title: 'Blue Moon'));
      expect(find.byIcon(CupertinoIcons.line_horizontal_3), findsNothing);
      await pumpRow(
        tester,
        const JamTrackRow(title: 'Blue Moon', showDragHandle: true),
      );
      expect(find.byIcon(CupertinoIcons.line_horizontal_3), findsOneWidget);
    });

    testWidgets('press highlight is fillPressed, no ink', (tester) async {
      await pumpRow(tester, JamTrackRow(title: 'Blue Moon', onTap: () {}));
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(JamTrackRow)),
      );
      await tester.pump();
      final boxes = tester.widgetList<DecoratedBox>(
        find.descendant(
          of: find.byType(JamTrackRow),
          matching: find.byType(DecoratedBox),
        ),
      );
      expect(
        boxes.any(
          (b) =>
              (b.decoration as BoxDecoration).color ==
              JamColors.light.fillPressed,
        ),
        isTrue,
      );
      expect(find.byType(InkWell), findsNothing);
      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('draws its separator inside a section, not after the last', (
      tester,
    ) async {
      await pumpRow(
        tester,
        const JamSection(
          children: [
            JamTrackRow(title: 'One'),
            JamTrackRow(title: 'Two'),
          ],
        ),
      );
      expect(find.byType(JamHairline), findsOneWidget);
    });
  });

  group('formatTrackDuration', () {
    test('is m:ss, and h:mm:ss past an hour', () {
      expect(formatTrackDuration(const Duration(seconds: 7)), '0:07');
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
