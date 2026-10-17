import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/design/theme.dart';
import 'package:localjam_app/src/design/tokens.dart';
import 'package:localjam_app/src/widgets/buttons.dart';
import 'package:localjam_app/src/widgets/empty_state.dart';

Widget _host(Widget child, {bool dark = false}) => MaterialApp(
  theme: dark ? jamDarkTheme() : jamLightTheme(),
  home: Scaffold(body: child),
);

void main() {
  testWidgets('shows a mark, a title, a body and one action', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      _host(
        JamEmptyState(
          icon: Icons.wifi_tethering_rounded,
          title: 'No rooms nearby',
          body: 'Start one and the people around you will see it.',
          actionLabel: 'Start a jam',
          onAction: () => taps++,
        ),
      ),
    );

    expect(find.byIcon(Icons.wifi_tethering_rounded), findsOneWidget);
    expect(find.text('No rooms nearby'), findsOneWidget);
    expect(
      find.text('Start one and the people around you will see it.'),
      findsOneWidget,
    );
    // Exactly one action — never two competing buttons.
    expect(find.byType(JamButton), findsOneWidget);

    await tester.tap(find.byType(JamButton));
    expect(taps, 1);
  });

  testWidgets(
    'the glyph is 56 dp in tertiary text, and the block caps at 320',
    (tester) async {
      await tester.pumpWidget(
        _host(
          const JamEmptyState(
            icon: Icons.queue_music_rounded,
            title: 'Nothing queued',
            body: 'Add a track.',
          ),
        ),
      );
      final icon = tester.widget<Icon>(find.byType(Icon));
      expect(icon.size, 56);
      expect(icon.color, JamColors.light.textTertiary);
      expect(
        tester
            .getSize(
              find
                  .descendant(
                    of: find.byType(JamEmptyState),
                    matching: find.byType(ConstrainedBox),
                  )
                  .first,
            )
            .width,
        lessThanOrEqualTo(320),
      );
    },
  );

  testWidgets('a music-shaped empty uses the placeholder gradient', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const JamEmptyState(
          icon: Icons.queue_music_rounded,
          gradientMark: true,
          title: 'Nothing queued',
          body: 'Add a track.',
        ),
      ),
    );
    final mark = tester.widget<Container>(find.byType(Container).first);
    final decoration = mark.decoration! as BoxDecoration;
    expect(decoration.gradient, isA<LinearGradient>());
    expect(tester.getSize(find.byType(Container).first), const Size(72, 72));
  });

  testWidgets('no action label means no button', (tester) async {
    await tester.pumpWidget(
      _host(
        const JamEmptyState(
          icon: Icons.history_rounded,
          title: 'No past jams',
          body: 'Rooms you host or join will show up here.',
        ),
      ),
    );
    expect(find.byType(JamButton), findsNothing);
  });

  testWidgets('a custom mark replaces the glyph', (tester) async {
    await tester.pumpWidget(
      _host(
        const JamEmptyState(
          mark: SizedBox(key: Key('logo'), width: 72, height: 72),
          icon: Icons.history_rounded,
          title: 'No past jams',
          body: 'Rooms you host or join will show up here.',
        ),
      ),
    );
    expect(find.byKey(const Key('logo')), findsOneWidget);
    expect(find.byIcon(Icons.history_rounded), findsNothing);
  });
}
