import 'package:flutter/cupertino.dart';
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
  testWidgets('shows a glyph, a title, a sentence and one action', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      _host(
        JamEmptyState(
          icon: CupertinoIcons.dot_radiowaves_left_right,
          title: 'No Jams Nearby',
          body: 'Jams on this Wi‑Fi show up here.',
          actionLabel: 'Scan a Code',
          actionVariant: JamButtonVariant.plain,
          onAction: () => taps++,
        ),
      ),
    );

    expect(
      find.byIcon(CupertinoIcons.dot_radiowaves_left_right),
      findsOneWidget,
    );
    expect(find.text('No Jams Nearby'), findsOneWidget);
    expect(find.text('Jams on this Wi‑Fi show up here.'), findsOneWidget);
    expect(find.byType(JamButton), findsOneWidget);
    expect(
      tester.widget<JamButton>(find.byType(JamButton)).variant,
      JamButtonVariant.plain,
    );

    await tester.tap(find.byType(JamButton));
    expect(taps, 1);
  });

  testWidgets('48 glyph in secondaryLabel, 22 bold title, capped at 320', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const JamEmptyState(
          icon: CupertinoIcons.music_note_list,
          title: 'Nothing Up Next',
          body: 'Add songs to keep the jam going.',
        ),
      ),
    );
    final icon = tester.widget<Icon>(find.byType(Icon));
    expect(icon.size, 48);
    // ContentUnavailableView's colour: tertiary all but vanished on black.
    expect(icon.color, JamColors.light.secondaryLabel);
    final title = tester.widget<Text>(find.text('Nothing Up Next')).style!;
    expect(title.fontSize, 22);
    expect(title.fontWeight, FontWeight.w700);
    final body = tester
        .widget<Text>(find.text('Add songs to keep the jam going.'))
        .style!;
    expect(body.fontSize, 15);
    expect(body.color, JamColors.light.secondaryLabel);
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
  });

  testWidgets('the action hugs its label (min 140), never a full-width bar', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        JamEmptyState(
          icon: CupertinoIcons.wifi_slash,
          title: 'Host Is Gone',
          body: 'The host left the network.',
          actionLabel: 'Retry',
          onAction: () {},
          secondaryActionLabel: 'Back to Nearby',
          onSecondaryAction: () {},
        ),
      ),
    );
    final primary = tester.getSize(find.widgetWithText(JamButton, 'Retry'));
    expect(primary.width, greaterThanOrEqualTo(kJamEmptyStateActionMinWidth));
    expect(primary.width, lessThan(200));
    final secondary = tester.getSize(
      find.widgetWithText(JamButton, 'Back to Nearby'),
    );
    expect(secondary.width, lessThan(288));
  });

  testWidgets('no action label means no button', (tester) async {
    await tester.pumpWidget(
      _host(
        const JamEmptyState(
          icon: CupertinoIcons.clock,
          title: 'No Past Jams',
          body: 'Jams you host or join show up here.',
        ),
      ),
    );
    expect(find.byType(JamButton), findsNothing);
  });

  testWidgets('terminal states can carry a second, plain action', (
    tester,
  ) async {
    var retry = 0;
    var back = 0;
    await tester.pumpWidget(
      _host(
        JamEmptyState(
          icon: CupertinoIcons.wifi_slash,
          title: 'Host Is Gone',
          body: 'The host left the network.',
          actionLabel: 'Try Again',
          onAction: () => retry++,
          secondaryActionLabel: 'Back to Nearby',
          onSecondaryAction: () => back++,
        ),
      ),
    );
    expect(find.byType(JamButton), findsNWidgets(2));
    await tester.tap(find.text('Try Again'));
    await tester.tap(find.text('Back to Nearby'));
    expect((retry, back), (1, 1));
  });

  testWidgets('a custom mark replaces the glyph', (tester) async {
    await tester.pumpWidget(
      _host(
        const JamEmptyState(
          mark: SizedBox(key: Key('logo'), width: 72, height: 72),
          icon: CupertinoIcons.clock,
          title: 'No Past Jams',
          body: 'Jams you host or join show up here.',
        ),
      ),
    );
    expect(find.byKey(const Key('logo')), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.clock), findsNothing);
  });
}
