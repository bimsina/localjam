/// Confirm, destroy, and ask for a name — plus the controller lifetime that
/// used to red-screen the app: a `TextEditingController` disposed the instant
/// `showDialog` returned was still wired to a `TextField` the exit transition
/// kept building. Every prompt test below pumps that transition to the end.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/design/theme.dart';
import 'package:localjam_app/src/design/tokens.dart';
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

  testWidgets('a dismissed confirm is a no', (tester) async {
    bool? answer;
    await tester.pumpWidget(
      _host(
        (context) async =>
            answer = await JamDialogs.confirm(context, title: 'End the jam?'),
      ),
    );
    await tester.tap(find.text('Go'));
    await tester.pumpAndSettle();

    await tester.tapAt(const Offset(10, 10)); // the barrier
    await tester.pumpAndSettle();
    expect(answer, isFalse);
  });

  testWidgets('a destructive confirm fills its primary action in danger', (
    tester,
  ) async {
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

    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    final colors = JamColors.light;
    expect(
      button.style?.backgroundColor?.resolve(<WidgetState>{}),
      colors.danger,
    );
    expect(
      button.style?.foregroundColor?.resolve(<WidgetState>{}),
      colors.onAccent,
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
    expect(find.byType(TextField), findsOneWidget);

    await tester.enterText(find.byType(TextField), '  Neon Walrus  ');
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

    await tester.enterText(find.byType(TextField), '   ');
    await tester.pump();
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
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
