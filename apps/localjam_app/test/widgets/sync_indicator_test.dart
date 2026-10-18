import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/design/theme.dart';
import 'package:localjam_app/src/design/tokens.dart';
import 'package:localjam_app/src/widgets/sync_indicator.dart';

Widget _host(
  JamSyncState state, {
  VoidCallback? onShowDetails,
  bool dark = false,
  bool reduceMotion = false,
  double height = 44,
}) => MediaQuery(
  data: MediaQueryData(disableAnimations: reduceMotion),
  child: MaterialApp(
    theme: dark ? jamDarkTheme() : jamLightTheme(),
    home: Scaffold(
      body: Center(
        child: JamSyncIndicator(
          state: state,
          onShowDetails: onShowDetails,
          height: height,
        ),
      ),
    ),
  ),
);

Color _dotColor(WidgetTester tester) {
  final box = tester.widget<DecoratedBox>(
    find
        .descendant(
          of: find.byType(JamSyncIndicator),
          matching: find.byType(DecoratedBox),
        )
        .first,
  );
  return (box.decoration as BoxDecoration).color!;
}

void main() {
  testWidgets('idle renders nothing at all', (tester) async {
    await tester.pumpWidget(_host(JamSyncState.idle));
    expect(
      find.descendant(
        of: find.byType(JamSyncIndicator),
        matching: find.byType(DecoratedBox),
      ),
      findsNothing,
    );
  });

  testWidgets('in sync is a quiet dot and a quiet word', (tester) async {
    await tester.pumpWidget(_host(JamSyncState.inSync));
    await tester.pumpAndSettle();
    // A lone 6 dp dot read as a speck of dust on a review build, so the calm
    // state says so — in `textSecondary`, with no colour of its own.
    expect(find.text(JamSyncStrings.inSync), findsOneWidget);
    expect(_dotColor(tester), JamColors.light.secondaryLabel);
    expect(tester.getSize(find.byType(JamSyncIndicator)).height, 44);
  });

  testWidgets('the room can pack the indicator into a shorter slot', (
    tester,
  ) async {
    await tester.pumpWidget(_host(JamSyncState.inSync, height: 28));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(JamSyncIndicator)).height, 28);
  });

  testWidgets('catching up pairs an apricot dot with a readable word', (
    tester,
  ) async {
    await tester.pumpWidget(_host(JamSyncState.catchingUp));
    await tester.pumpAndSettle();
    expect(find.text('Catching up'), findsOneWidget);
    expect(_dotColor(tester), JamColors.light.warning);
    expect(
      tester.widget<Text>(find.text('Catching up')).style!.color,
      JamColors.light.warning,
    );
  });

  testWidgets('out of sync is the only red state', (tester) async {
    await tester.pumpWidget(_host(JamSyncState.offSync));
    await tester.pumpAndSettle();
    expect(find.text('Out of sync'), findsOneWidget);
    expect(_dotColor(tester), JamColors.light.danger);
  });

  testWidgets('reconnecting and syncing pulse; a settled state does not', (
    tester,
  ) async {
    await tester.pumpWidget(_host(JamSyncState.reconnecting));
    expect(find.text('Reconnecting…'), findsOneWidget);
    // A repeating controller never settles.
    expect(tester.hasRunningAnimations, isTrue);

    await tester.pumpWidget(_host(JamSyncState.inSync));
    await tester.pumpAndSettle();
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('the pulse stops entirely under reduced motion', (tester) async {
    await tester.pumpWidget(_host(JamSyncState.syncing, reduceMotion: true));
    await tester.pumpAndSettle();
    expect(find.text('Syncing…'), findsOneWidget);
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('long-press opens the numbers; a tap does not', (tester) async {
    var opened = 0;
    await tester.pumpWidget(
      _host(JamSyncState.offSync, onShowDetails: () => opened++),
    );
    await tester.tap(find.byType(JamSyncIndicator));
    await tester.pump();
    expect(opened, 0);

    await tester.longPress(find.byType(JamSyncIndicator));
    await tester.pump();
    expect(opened, 1);
  });

  testWidgets('dark reads its own palette', (tester) async {
    await tester.pumpWidget(_host(JamSyncState.offSync, dark: true));
    await tester.pumpAndSettle();
    expect(_dotColor(tester), JamColors.dark.danger);
  });
}
