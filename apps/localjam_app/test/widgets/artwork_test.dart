import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/design/artwork_tint.dart';
import 'package:localjam_app/src/design/theme.dart';
import 'package:localjam_app/src/design/tokens.dart';
import 'package:localjam_app/src/widgets/artwork.dart';

/// A 1×1 PNG — enough for the tile to have real bytes to render.
final Uint8List _pixel = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAE'
  'hQGAhKmMIQAAAABJRU5ErkJggg==',
);

Future<void> pumpTile(WidgetTester tester, Widget child, {bool dark = false}) {
  final theme = dark ? jamDarkTheme() : jamLightTheme();
  return tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: Theme(
        data: theme,
        child: Scaffold(body: Center(child: child)),
      ),
    ),
  );
}

BoxDecoration tileDecoration(WidgetTester tester) =>
    tester
            .widget<Container>(
              find
                  .descendant(
                    of: find.byType(JamArtworkTile),
                    matching: find.byType(Container),
                  )
                  .first,
            )
            .decoration!
        as BoxDecoration;

void main() {
  group('JamArtworkTile', () {
    testWidgets('placeholder: fillSecondary ground, tertiary music note', (
      tester,
    ) async {
      for (final dark in [false, true]) {
        await pumpTile(tester, const JamArtworkTile(size: 100), dark: dark);
        final palette = dark ? JamColors.dark : JamColors.light;
        expect(tileDecoration(tester).color, palette.fillSecondary);
        expect(tileDecoration(tester).gradient, isNull);
        final note = tester.widget<Icon>(
          find.byIcon(CupertinoIcons.music_note),
        );
        expect(note.size, 40);
        expect(note.color, palette.tertiaryLabel);
        expect(find.byType(Image), findsNothing);
      }
    });

    testWidgets('on the backdrop the placeholder is white', (tester) async {
      await pumpTile(tester, const JamArtworkTile(onBackdrop: true));
      expect(
        tileDecoration(tester).color,
        JamNowPlayingColors.placeholderGround,
      );
      expect(
        tester.widget<Icon>(find.byIcon(CupertinoIcons.music_note)).color,
        JamNowPlayingColors.placeholderGlyph,
      );
    });

    testWidgets('radius follows the size bands', (tester) async {
      expect(JamRadius.artwork(40), 6);
      expect(JamRadius.artwork(44), 6);
      expect(JamRadius.artwork(56), 8);
      expect(JamRadius.artwork(64), 8);
      expect(JamRadius.artwork(200), 12);
      await pumpTile(tester, const JamArtworkTile(size: 340));
      expect(tileDecoration(tester).borderRadius, BorderRadius.circular(12));
    });

    testWidgets('renders bytes gaplessly once they arrive', (tester) async {
      await pumpTile(tester, JamArtworkTile(bytes: _pixel));
      expect(find.byType(Image), findsOneWidget);
      expect(tester.widget<Image>(find.byType(Image)).gaplessPlayback, isTrue);
    });

    testWidgets(
      'a failed cover shows the placeholder, loading never animates',
      (tester) async {
        await pumpTile(tester, const JamArtworkTile(hasError: true));
        expect(find.byIcon(CupertinoIcons.music_note), findsOneWidget);
        await pumpTile(tester, const JamArtworkTile(isLoading: true));
        await tester.pumpAndSettle();
        expect(find.byType(ShaderMask), findsNothing);
        expect(find.byIcon(CupertinoIcons.music_note), findsOneWidget);
      },
    );

    testWidgets('shadow is opt-in and is the artwork shadow', (tester) async {
      await pumpTile(tester, const JamArtworkTile(size: 300, shadow: true));
      final box = tester.widget<DecoratedBox>(
        find
            .descendant(
              of: find.byType(JamArtworkTile),
              matching: find.byType(DecoratedBox),
            )
            .first,
      );
      expect((box.decoration as BoxDecoration).boxShadow, JamShadow.artwork);
    });

    testWidgets('announces a label only when given one', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpTile(
        tester,
        const JamArtworkTile(semanticLabel: 'Cover for Blue Moon'),
      );
      expect(find.bySemanticsLabel('Cover for Blue Moon'), findsOneWidget);
      handle.dispose();
    });
  });

  group('JamBackdropView', () {
    testWidgets('the placeholder is a flat #1C1C1E, no image', (tester) async {
      await pumpTile(
        tester,
        const SizedBox(
          width: 200,
          height: 200,
          child: JamBackdropView(backdrop: JamBackdrop.placeholder),
        ),
      );
      expect(find.byType(Image), findsNothing);
      expect(
        tester
            .widgetList<ColoredBox>(find.byType(ColoredBox))
            .any((b) => b.color == const Color(0xFF1C1C1E)),
        isTrue,
      );
    });

    testWidgets('a cover is blurred under its overlay', (tester) async {
      final backdrop = JamBackdrop(
        id: 'a',
        image: MemoryImage(_pixel),
        overlayOpacity: 0.3,
        base: const Color(0xFF223344),
      );
      await pumpTile(
        tester,
        SizedBox(
          width: 200,
          height: 200,
          child: JamBackdropView(backdrop: backdrop),
        ),
      );
      expect(find.byType(ImageFiltered), findsOneWidget);
      expect(find.byType(Image), findsOneWidget);
      expect(
        tester
            .widgetList<ColoredBox>(find.byType(ColoredBox))
            .any((b) => b.color.a > 0.29 && b.color.a < 0.31),
        isTrue,
      );
    });
  });
}
