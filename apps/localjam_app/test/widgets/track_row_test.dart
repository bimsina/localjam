import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/design/theme.dart';
import 'package:localjam_app/src/design/tokens.dart';
import 'package:localjam_app/src/util/format.dart';
import 'package:localjam_app/src/widgets/avatar.dart';
import 'package:localjam_app/src/widgets/list.dart';
import 'package:localjam_app/src/widgets/progress.dart';
import 'package:localjam_app/src/widgets/section.dart';
import 'package:localjam_app/src/widgets/track_row.dart';
import 'package:material_ui/material_ui.dart';

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

    group('a song with no artist: one rule on every row (N8)', () {
      // Each row type as its screen builds it: the queue and a past jam
      // credit people; Start a jam and the library do not.
      const length = Duration(minutes: 3);
      final rows = <String, JamTrackRow Function(String? byline)>{
        'queue': (byline) => JamTrackRow(
          title: 'Kitchen Session',
          byline: byline,
          addedByName: 'Sparkly Kiwi',
          addedByColor: const Color(0xFF2F815B),
          reserveCredit: true,
          duration: length,
          onBackdrop: true,
        ),
        'past jam': (byline) => JamTrackRow(
          title: 'Kitchen Session',
          byline: byline,
          addedByName: 'Sparkly Kiwi',
          addedByColor: const Color(0xFF2F815B),
          duration: length,
        ),
        'past jam, no face': (byline) => JamTrackRow(
          title: 'Kitchen Session',
          byline: byline,
          addedByName: 'Sparkly Kiwi',
          duration: length,
        ),
        'start a jam': (byline) => JamTrackRow(
          title: 'Kitchen Session',
          byline: byline,
          duration: length,
        ),
        'library': (byline) => JamTrackRow(
          title: 'Kitchen Session',
          byline: byline,
          duration: length,
          trailing: const SizedBox(width: 22),
        ),
      };

      for (final MapEntry(key: name, value: row) in rows.entries) {
        testWidgets('$name: the album and the length', (tester) async {
          await pumpRow(
            tester,
            row(jamSongByline(artist: null, album: 'Native QA')),
          );
          expect(find.text('Native QA · 3:00'), findsOneWidget);
          expect(find.textContaining('Added by'), findsNothing);
          expect(find.textContaining('Unknown'), findsNothing);
        });

        testWidgets('$name: with no album, the length alone', (tester) async {
          await pumpRow(tester, row(jamSongByline(artist: ' ', album: null)));
          expect(find.text('3:00'), findsOneWidget);
          expect(find.textContaining('Added by'), findsNothing);
          expect(find.textContaining('Unknown'), findsNothing);
        });
      }

      testWidgets('the credit is a face, only for someone else', (
        tester,
      ) async {
        await pumpRow(tester, rows['past jam']!(null));
        expect(find.byType(JamAvatar), findsOneWidget);
        await pumpRow(tester, rows['start a jam']!(null));
        expect(find.byType(JamAvatar), findsNothing);
      });

      test('the artist when there is one, else the album, else nothing', () {
        expect(jamSongByline(artist: 'Mira Sol', album: 'Drives'), 'Mira Sol');
        expect(jamSongByline(artist: '', album: 'Drives'), 'Drives');
        expect(jamSongByline(artist: null, album: '  '), isNull);
        expect(jamSongByline(), isNull);
      });
    });

    testWidgets('your own song carries no credit: the length stays', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpRow(
        tester,
        const JamTrackRow(
          title: 'Blue Moon',
          byline: 'Billie',
          addedByName: 'You',
          addedByYou: true,
          addedByColor: Color(0xFF2F815B),
          duration: Duration(minutes: 3),
        ),
      );
      expect(find.text('Billie · 3:00'), findsOneWidget);
      expect(find.textContaining('You'), findsNothing);
      expect(find.byType(JamAvatar), findsNothing);
      // A screen reader still hears whose it is.
      expect(
        find.bySemanticsLabel(RegExp(JamTrackRowStrings.addedByYou)),
        findsOneWidget,
      );
      handle.dispose();
    });

    testWidgets("someone else's song: two lines, and their face at the end", (
      tester,
    ) async {
      const mia = Color(0xFF2F815B);
      final handle = tester.ensureSemantics();
      await pumpRow(
        tester,
        const JamTrackRow(
          title: 'Blue Moon',
          byline: 'Billie',
          addedByName: 'Mia',
          addedByColor: mia,
          duration: Duration(minutes: 3, seconds: 42),
        ),
      );
      expect(find.text('Billie · 3:42'), findsOneWidget);
      expect(find.textContaining('Mia'), findsNothing);
      final face = tester.widget<JamAvatar>(find.byType(JamAvatar));
      expect(face.resolvedColor, mia);
      expect(face.size, JamAvatarSize.attribution);
      // Trailing: past the words, at the row's end.
      expect(
        tester.getCenter(find.byType(JamAvatar)).dx,
        greaterThan(tester.getRect(find.text('Billie · 3:42')).right),
      );
      expect(
        tester.getSize(find.byType(JamTrackRow)).height,
        kJamTrackRowHeight,
      );
      expect(
        find.bySemanticsLabel(RegExp('${JamTrackRowStrings.addedBy} Mia')),
        findsOneWidget,
      );
      handle.dispose();
    });

    testWidgets('faces share one column down a list: the slot is kept on '
        'rows without one', (tester) async {
      await pumpRow(
        tester,
        const Column(
          children: [
            JamTrackRow(
              title: 'Theirs',
              byline: 'Billie',
              addedByName: 'Mia',
              addedByColor: Color(0xFF2F815B),
            ),
            JamTrackRow(title: 'Mine', byline: 'Billie', addedByYou: true),
            JamTrackRow(title: 'Library', byline: 'Billie'),
          ],
        ),
      );
      double end(String title) =>
          tester.getRect(find.text(title)).left +
          tester
              .renderObject<RenderParagraph>(find.text(title))
              .constraints
              .maxWidth;
      expect(end('Mine'), end('Theirs'));
      // A row that never credits anyone (the library) keeps the width.
      expect(end('Library'), greaterThan(end('Theirs')));
    });

    testWidgets('a long artist is cut before the length ever is', (
      tester,
    ) async {
      await pumpRow(
        tester,
        const Center(
          child: SizedBox(
            width: 300,
            child: JamTrackRow(
              title: 'Blue Moon',
              byline: 'Electric Mongoose of the Long Road',
              duration: Duration(minutes: 4, seconds: 10),
            ),
          ),
        ),
      );
      expect(find.text(' · 4:10'), findsOneWidget);
      final length = tester.renderObject<RenderParagraph>(find.text(' · 4:10'));
      expect(length.didExceedMaxLines, isFalse);
      expect(
        tester
            .renderObject<RenderParagraph>(
              find.text('Electric Mongoose of the Long Road'),
            )
            .didExceedMaxLines,
        isTrue,
        reason: 'the artist takes the ellipsis',
      );
    });

    testWidgets('both lines and the face stay at large text sizes', (
      tester,
    ) async {
      for (final scale in [1.0, 2.0, 3.0]) {
        await pumpRow(
          tester,
          MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: const Center(
              child: JamTrackRow(
                title: 'Blue Moon',
                byline: 'Billie',
                addedByName: 'Mia',
                addedByColor: Color(0xFF2F815B),
                duration: Duration(minutes: 3, seconds: 42),
              ),
            ),
          ),
        );
        expect(find.text('Billie · 3:42'), findsOneWidget);
        expect(find.byType(JamAvatar), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
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
          byline: 'Billie',
          addedByName: 'Mia',
          onBackdrop: true,
        ),
      );
      expect(
        tester.widget<Text>(find.text('Blue Moon')).style!.color,
        JamNowPlayingColors.text,
      );
      expect(
        tester.widget<Text>(find.text('Billie')).style!.color,
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
      expect(find.byType(JamProgressRing), findsOneWidget);
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
    test('a clip under a second is 0:01, never 0:00', () {
      expect(formatTrackDuration(const Duration(milliseconds: 400)), '0:01');
      expect(formatTrackDuration(Duration.zero), '0:00');
    });

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
