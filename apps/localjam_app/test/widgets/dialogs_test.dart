/// Confirm, destroy, and ask for a name — plus the controller lifetime that
/// used to red-screen the app: a `TextEditingController` disposed the instant
/// `showDialog` returned was still wired to a `TextField` the exit transition
/// kept building. Every prompt test below pumps that transition to the end.
library;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/design/theme.dart';
import 'package:localjam_app/src/design/tokens.dart';
import 'package:localjam_app/src/widgets/dialogs.dart';
import 'package:material_ui/material_ui.dart';

List<JamAlertAction> _actions(WidgetTester tester) => tester
    .widgetList<JamAlertButton>(find.byType(JamAlertButton))
    .map((b) => b.action)
    .toList();

Color? _ground(WidgetTester tester, String label) {
  final box = tester.widget<Container>(
    find
        .descendant(
          of: find.widgetWithText(JamAlertButton, label),
          matching: find.byType(Container),
        )
        .first,
  );
  return (box.decoration! as ShapeDecoration).color;
}

Widget _host(Future<void> Function(BuildContext) onTap, {ThemeData? theme}) =>
    MaterialApp(
      theme: theme ?? jamLightTheme(),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => onTap(context),
            child: const Text('Go'),
          ),
        ),
      ),
    );

void main() {
  testWidgets('confirm returns true only when confirmed', (tester) async {
    bool? answer;
    await tester.pumpWidget(
      _host(
        (context) async => answer = await JamDialogs.confirm(
          context,
          title: 'Leave the jam?',
          message: 'Everyone else keeps listening.',
          confirmLabel: 'Leave',
        ),
      ),
    );

    await tester.tap(find.text('Go'));
    await tester.pumpAndSettle();
    expect(find.text('Leave the jam?'), findsOneWidget);
    expect(find.text('Everyone else keeps listening.'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(answer, isFalse);

    await tester.tap(find.text('Go'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Leave'));
    await tester.pumpAndSettle();
    expect(answer, isTrue);
  });

  testWidgets('an alert ignores the barrier; a back dismissal is a no', (
    tester,
  ) async {
    bool? answer;
    await tester.pumpWidget(
      _host(
        (context) async =>
            answer = await JamDialogs.confirm(context, title: 'End the jam?'),
      ),
    );
    await tester.tap(find.text('Go'));
    await tester.pumpAndSettle();
    expect(find.byType(JamAlert), findsOneWidget);

    await tester.tapAt(const Offset(10, 10)); // the barrier: iOS keeps it up
    await tester.pumpAndSettle();
    expect(find.byType(JamAlert), findsOneWidget);

    // System back (Android) pops it.
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.pop();
    await tester.pumpAndSettle();
    expect(answer, isFalse);
  });

  testWidgets('an iOS 26 alert: 300 wide, radius 34, Cancel then the action', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        (context) async => JamDialogs.confirm(
          context,
          title: 'Join Mia’s Jam?',
          confirmLabel: 'Join',
        ),
      ),
    );
    await tester.tap(find.text('Go'));
    await tester.pumpAndSettle();
    final card = find
        .descendant(of: find.byType(JamAlert), matching: find.byType(ClipRRect))
        .first;
    expect(tester.getSize(card).width, JamMetrics.alertWidth);
    expect(
      tester.widget<ClipRRect>(card).borderRadius,
      BorderRadius.circular(JamRadius.alert),
    );
    final actions = _actions(tester);
    expect(actions.length, 2);
    expect(actions.first.isDefault, isFalse);
    expect(actions.last.isDefault, isTrue);
    // Two short labels sit side by side, Cancel first.
    expect(
      tester.getCenter(find.text('Cancel')).dx,
      lessThan(tester.getCenter(find.text('Join')).dx),
    );
    expect(
      tester.getCenter(find.text('Cancel')).dy,
      tester.getCenter(find.text('Join')).dy,
    );
    // Shape and fill tell them apart: grey Cancel, filled tint Join.
    expect(_ground(tester, 'Cancel'), JamColors.light.fill);
    expect(_ground(tester, 'Join'), JamColors.light.tintFilled);
  });

  testWidgets('a destructive confirm turns its action red', (tester) async {
    await tester.pumpWidget(
      _host(
        (context) async => JamDialogs.confirmDestructive(
          context,
          title: 'End the jam?',
          confirmLabel: 'End it',
        ),
      ),
    );
    await tester.tap(find.text('Go'));
    await tester.pumpAndSettle();

    final actions = _actions(tester);
    expect(actions.last.destructive, isTrue);
    // Cancel is the neutral grey capsule, the action filled red — never
    // two near-identical reds side by side.
    expect(actions.first.isDefault, isFalse);
    expect(_ground(tester, 'Cancel'), JamColors.light.fill);
    expect(_ground(tester, 'End it'), JamColors.light.dangerFilled);
    // Soft rectangles, not v3's capsules.
    final shape =
        (tester
                    .widget<Container>(
                      find
                          .descendant(
                            of: find.widgetWithText(JamAlertButton, 'End it'),
                            matching: find.byType(Container),
                          )
                          .first,
                    )
                    .decoration!
                as ShapeDecoration)
            .shape;
    expect(
      shape,
      RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(JamRadius.alertButton),
      ),
    );
  });

  testWidgets('dark mode fills a destructive action white-on-deep-red', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        (context) async => JamDialogs.confirmDestructive(
          context,
          title: 'End the jam?',
          confirmLabel: 'End it',
        ),
        theme: jamDarkTheme(),
      ),
    );
    await tester.tap(find.text('Go'));
    await tester.pumpAndSettle();
    // Not the bright dark `danger` (2.2:1 under white).
    expect(_ground(tester, 'End it'), JamColors.dark.dangerFilled);
    expect(_ground(tester, 'End it'), isNot(JamColors.dark.danger));
  });

  testWidgets('labels too long to sit side by side stack, action on top', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        (context) async => JamDialogs.confirmDestructive(
          context,
          title: 'Remove Electric Mongoose?',
          confirmLabel: 'Remove from this jam',
        ),
      ),
    );
    await tester.tap(find.text('Go'));
    await tester.pumpAndSettle();
    expect(
      tester.getCenter(find.text('Remove from this jam')).dy,
      lessThan(tester.getCenter(find.text('Cancel')).dy),
    );
  });

  testWidgets('a leading-aligned message runs to the card edge, with a '
      'Manrope title above it', (tester) async {
    const message =
        'The music stops for everyone and the jam ends for everyone in the jam.';
    await tester.pumpWidget(
      _host(
        (context) async =>
            JamDialogs.confirm(context, title: 'End jam?', message: message),
      ),
    );
    await tester.tap(find.text('Go'));
    await tester.pumpAndSettle();
    final text = find.text(message);
    final lineHeight = tester.widget<Text>(text).style!.fontSize! * 1.6;
    // Two lines across the whole text column: balancing a left-aligned
    // message only leaves a ragged gutter on the right (SU-15).
    expect(tester.getSize(text).height, greaterThan(lineHeight));
    expect(
      tester.getSize(text).width,
      closeTo(JamMetrics.alertWidth - 2 * JamSpace.xl, 1),
    );
    expect(
      tester.widget<Text>(find.text('End jam?')).style!.fontFamily,
      'Manrope',
    );
  });

  testWidgets('the alert field follows the app appearance', (tester) async {
    await tester.pumpWidget(
      _host(
        (context) async => JamDialogs.promptText(context, title: 'Name'),
        theme: jamLightTheme(),
      ),
    );
    await tester.tap(find.text('Go'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<CupertinoTextField>(find.byType(CupertinoTextField))
          .keyboardAppearance,
      Brightness.light,
    );
  });

  testWidgets('promptText returns the trimmed value and survives the exit', (
    tester,
  ) async {
    String? saved;
    await tester.pumpWidget(
      _host(
        (context) async => saved = await JamDialogs.promptText(
          context,
          title: 'Your name in the room',
          initialValue: 'Silky Puffin',
        ),
      ),
    );

    await tester.tap(find.text('Go'));
    await tester.pumpAndSettle();
    expect(find.byType(CupertinoTextField), findsOneWidget);

    await tester.enterText(find.byType(CupertinoTextField), '  Neon Walrus  ');
    await tester.tap(find.text('Save'));
    // All of it: this is where a caller-owned controller used to blow up.
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(saved, 'Neon Walrus');
  });

  testWidgets('promptText disables its primary action while empty', (
    tester,
  ) async {
    String? saved = 'unset';
    await tester.pumpWidget(
      _host(
        (context) async => saved = await JamDialogs.promptText(
          context,
          title: 'Room name',
          initialValue: 'Kitchen',
        ),
      ),
    );
    await tester.tap(find.text('Go'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(CupertinoTextField), '   ');
    await tester.pump();
    expect(_actions(tester).last.onPressed, isNull);
    // The one disabled look (R8): neutral, not a faded raspberry.
    expect(_ground(tester, 'Save'), JamColors.light.fill);
    expect(
      tester.widget<Text>(find.text('Save')).style!.color,
      JamColors.light.tertiaryLabel,
    );

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(saved, isNull);
  });

  testWidgets('promptText can be told an empty answer is fine', (tester) async {
    String? saved = 'unset';
    await tester.pumpWidget(
      _host(
        (context) async => saved = await JamDialogs.promptText(
          context,
          title: 'Note',
          allowEmpty: true,
        ),
      ),
    );
    await tester.tap(find.text('Go'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(saved, '');
  });

  testWidgets('renders on the dark palette', (tester) async {
    await tester.pumpWidget(
      _host(
        (context) async => JamDialogs.promptText(context, title: 'Dark'),
        theme: jamDarkTheme(),
      ),
    );
    await tester.tap(find.text('Go'));
    await tester.pumpAndSettle();

    expect(find.text('Dark'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('End Jam? asked for from the room is the room\'s dark (R2)', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: jamLightTheme(),
        home: Builder(
          builder: (outer) => Scaffold(
            body: Stack(
              children: [
                const JamPresentationAppearance(brightness: Brightness.dark),
                Center(
                  child: TextButton(
                    onPressed: () => JamDialogs.confirmDestructive(
                      outer,
                      title: 'End jam?',
                      confirmLabel: 'End jam',
                    ),
                    child: const Text('Go'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Go'));
    await tester.pumpAndSettle();
    expect(_ground(tester, 'Cancel'), JamColors.dark.fill);
    expect(_ground(tester, 'End jam'), JamColors.dark.dangerFilled);
    expect(
      Theme.of(tester.element(find.text('End jam?'))).brightness,
      Brightness.dark,
    );
  });
}
