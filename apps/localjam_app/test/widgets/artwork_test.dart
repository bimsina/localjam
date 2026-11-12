import 'dart:convert';
import 'dart:typed_data';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/design/artwork_tint.dart';
import 'package:localjam_app/src/design/theme.dart';
import 'package:localjam_app/src/design/tokens.dart';
import 'package:localjam_app/src/widgets/artwork.dart';
import 'package:material_ui/material_ui.dart';

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
      expect(JamRadius.artwork(120), 12);
      // A large cover (from 160) matches Now Playing's 18.
      expect(JamRadius.artwork(200), JamRadius.largeCover);
      await pumpTile(tester, const JamArtworkTile(size: 340));
      expect(
        tileDecoration(tester).borderRadius,
        BorderRadius.circular(JamRadius.largeCover),
      );
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
    testWidgets('the placeholder uses matte charcoal without an image', (
      tester,
    ) async {
      await pumpTile(
        tester,
        const SizedBox(
          width: 200,
          height: 200,
          child: JamBackdropView(backdrop: JamBackdrop.placeholder),
        ),
      );
      expect(find.byType(Image), findsNothing);
      final decoration = tester
          .widgetList<DecoratedBox>(find.byType(DecoratedBox))
          .map((w) => w.decoration)
          .whereType<BoxDecoration>()
          .firstWhere((d) => d.gradient != null);
      expect(
        decoration.gradient!.colors.last,
        JamNowPlayingColors.backdropPlaceholder,
      );
    });

    testWidgets('cover color settles into charcoal behind controls', (
      tester,
    ) async {
      const backdrop = JamBackdrop(id: 'a', base: Color(0xFF223344));
      await pumpTile(
        tester,
        SizedBox(
          width: 200,
          height: 200,
          child: JamBackdropView(backdrop: backdrop),
        ),
      );
      final decoration = tester
          .widgetList<DecoratedBox>(find.byType(DecoratedBox))
          .map((w) => w.decoration)
          .whereType<BoxDecoration>()
          .firstWhere((d) => d.gradient != null);
      expect(decoration.gradient!.colors.first, backdrop.base);
      expect(
        decoration.gradient!.colors.last,
        JamNowPlayingColors.backdropPlaceholder,
      );
      expect(find.byType(ImageFiltered), findsNothing);
    });

    testWidgets('mid cross-fade it stays opaque: the page under the room '
        'never shows through (N4)', (tester) async {
      Future<void> show(String id, Color base) => pumpTile(
        tester,
        SizedBox(
          width: 200,
          height: 200,
          child: JamBackdropView(
            backdrop: JamBackdrop(id: id, base: base),
          ),
        ),
      );
      await show('a', const Color(0xFF223344));
      await show('b', const Color(0xFF884422));
      await tester.pump(const Duration(milliseconds: 300));
      // Both washes are part-transparent now; an opaque floor sits under
      // them.
      expect(find.byType(FadeTransition), findsNWidgets(2));
      final floor = tester.widget<ColoredBox>(
        find
            .descendant(
              of: find.byType(JamBackdropView),
              matching: find.byType(ColoredBox),
            )
            .first,
      );
      expect(floor.color, JamNowPlayingColors.backdropPlaceholder);
      expect(floor.color.a, 1);
      await tester.pumpAndSettle();
    });
  });

  testWidgets('under reduced motion the cover does not fly between the mini '
      'player and Now Playing (RB-13)', (tester) async {
    for (final reduced in [false, true]) {
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(disableAnimations: reduced),
          child: const JamArtworkHero(child: SizedBox.square(dimension: 40)),
        ),
      );
      expect(tester.widget<HeroMode>(find.byType(HeroMode)).enabled, !reduced);
    }
  });
}
