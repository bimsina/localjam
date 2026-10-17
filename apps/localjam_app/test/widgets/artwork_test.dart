import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/design/theme.dart';
import 'package:localjam_app/src/design/tokens.dart';
import 'package:localjam_app/src/widgets/artwork.dart';

/// A 1×1 PNG — enough for the tile to have real bytes to render.
final Uint8List _pixel = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAE'
  'hQGAhKmMIQAAAABJRU5ErkJggg==',
);

Future<void> pumpTile(
  WidgetTester tester,
  Widget child, {
  bool dark = false,
  bool disableAnimations = false,
}) {
  final theme = dark ? jamDarkTheme() : jamLightTheme();
  // An inner Theme, not just MaterialApp's: MaterialApp animates a theme
  // change, so a single pump would still be halfway through the old palette.
  return tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: disableAnimations),
        child: Theme(
          data: theme,
          child: Scaffold(body: Center(child: child)),
        ),
      ),
    ),
  );
}

BoxDecoration tileDecoration(WidgetTester tester) =>
    tester
            .widget<Container>(
              find.descendant(
                of: find.byType(JamArtworkTile),
                matching: find.byType(Container),
              ),
            )
            .decoration!
        as BoxDecoration;

void main() {
  group('JamArtworkTile', () {
    testWidgets('falls back to the brand mark when there is no cover', (
      tester,
    ) async {
      for (final dark in [false, true]) {
        await pumpTile(tester, const JamArtworkTile(), dark: dark);
        expect(find.byType(SvgPicture), findsOneWidget);
        expect(find.byType(Image), findsNothing);
      }
    });

    testWidgets('takes its radius from the edge length', (tester) async {
      await pumpTile(tester, const JamArtworkTile(size: 340));
      expect(
        tileDecoration(tester).borderRadius,
        BorderRadius.circular(JamRadius.artwork(340)),
      );
      expect(JamRadius.artwork(48), 10);
    });

    testWidgets('is hairlined on light and bare on dark', (tester) async {
      await pumpTile(tester, const JamArtworkTile());
      final light = tileDecoration(tester).border! as Border;
      expect(light.top.width, 0.5);
      expect(light.top.color, JamColors.light.separator);

      await pumpTile(tester, const JamArtworkTile(), dark: true);
      expect(tileDecoration(tester).border, isNull);
    });

    testWidgets('renders bytes gaplessly once they arrive', (tester) async {
      await pumpTile(tester, JamArtworkTile(bytes: _pixel));
      expect(find.byType(Image), findsOneWidget);
      expect(tester.widget<Image>(find.byType(Image)).gaplessPlayback, isTrue);
    });

    testWidgets('shows a music glyph when the cover failed', (tester) async {
      await pumpTile(tester, const JamArtworkTile(hasError: true));
      expect(find.byIcon(Icons.music_note_rounded), findsOneWidget);
    });

    testWidgets('shimmers while loading, and holds still without motion', (
      tester,
    ) async {
      await pumpTile(tester, const JamArtworkTile(isLoading: true));
      expect(find.byType(ShaderMask), findsOneWidget);

      await pumpTile(
        tester,
        const JamArtworkTile(isLoading: true),
        disableAnimations: true,
      );
      expect(find.byType(ShaderMask), findsNothing);
      expect(find.byType(SvgPicture), findsOneWidget);
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
}
