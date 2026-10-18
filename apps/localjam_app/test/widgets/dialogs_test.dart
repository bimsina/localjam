/// Confirm, destroy, and ask for a name — plus the controller lifetime that
/// used to red-screen the app: a `TextEditingController` disposed the instant
/// `showDialog` returned was still wired to a `TextField` the exit transition
/// kept building. Every prompt test below pumps that transition to the end.
library;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/design/theme.dart';
import 'package:localjam_app/src/widgets/dialogs.dart';

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
    expect(find.byType(CupertinoAlertDialog), findsOneWidget);

    await tester.tapAt(const Offset(10, 10)); // the barrier: iOS keeps it up
    await tester.pumpAndSettle();
    expect(find.byType(CupertinoAlertDialog), findsOneWidget);

    // System back (Android) pops it.
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.pop();
    await tester.pumpAndSettle();
    expect(answer, isFalse);
  });

  testWidgets('an iOS alert: 270 wide, Cancel then the action', (tester) async {
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
    expect(
      tester
          .getSize(
            find
                .descendant(
                  of: find.byType(CupertinoAlertDialog),
                  matching: find.byType(CupertinoPopupSurface),
                )
                .first,
          )
          .width,
      270,
    );
    final actions = tester
        .widgetList<CupertinoDialogAction>(find.byType(CupertinoDialogAction))
        .toList();
    expect(actions.length, 2);
    expect(actions.first.isDefaultAction, isFalse);
    expect(actions.last.isDefaultAction, isTrue);
    expect(
      tester.getCenter(find.text('Cancel')).dx,
      lessThan(tester.getCenter(find.text('Join')).dx),
    );
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

    final actions = tester
        .widgetList<CupertinoDialogAction>(find.byType(CupertinoDialogAction))
        .toList();
    expect(actions.last.isDestructiveAction, isTrue);
    // iOS makes Cancel the bold one beside a destructive action.
    expect(actions.first.isDefaultAction, isTrue);
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
    expect(
      tester
          .widgetList<CupertinoDialogAction>(find.byType(CupertinoDialogAction))
          .last
          .onPressed,
      isNull,
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
}
