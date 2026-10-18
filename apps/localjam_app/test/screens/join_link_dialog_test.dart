/// Joining by pasted link — the way in when there is no camera and nothing
/// nearby.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/design/theme.dart';
import 'package:localjam_app/src/widgets/dialogs.dart';
import 'package:localjam_app/src/widgets/join_link_dialog.dart';

const String _link =
    'localjam://join?host=192.168.1.4&port=7000&token=abc123&name=Van';

/// Answers `Clipboard.getData` with [text], or with nothing at all.
void mockClipboard(String? text) {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method != 'Clipboard.getData') return null;
    return text == null ? null : <String, Object?>{'text': text};
  });
  addTearDown(
    () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
  );
}

/// Where the dialog's result lands. Held rather than returned: awaiting the
/// opener would await the dialog itself, and pumping from two places at once
/// deadlocks the tester.
Future<Uri?>? pending;

/// Opens the dialog. Read [pending] for what it answers.
Future<void> openDialog(WidgetTester tester, {ThemeData? theme}) async {
  pending = null;
  await tester.pumpWidget(
    MaterialApp(
      theme: theme ?? jamLightTheme(),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => pending = promptForJoinLink(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a link already on the clipboard is simply there', (
    tester,
  ) async {
    mockClipboard(_link);
    await openDialog(tester);

    expect(find.text(JamJoinLinkStrings.title), findsOneWidget);
    expect(find.text(_link), findsOneWidget);
    // A field that fills itself needs to say why.
    expect(find.text(JamJoinLinkStrings.pasted), findsOneWidget);

    await tester.tap(find.text(JamJoinLinkStrings.join));
    await tester.pumpAndSettle();
    expect((await pending)?.queryParameters['host'], '192.168.1.4');
  });

  testWidgets('anything that is not a jam link stays out of the field', (
    tester,
  ) async {
    // Pasting someone's shopping list into a URL box is worse than an empty
    // box.
    mockClipboard('milk, eggs, a new amp');
    await openDialog(tester);

    expect(find.text('milk, eggs, a new amp'), findsNothing);
    expect(find.text(JamJoinLinkStrings.pasted), findsNothing);
  });

  testWidgets('a bad link is answered in the field, not in a snackbar', (
    tester,
  ) async {
    mockClipboard(null);
    await openDialog(tester);

    await tester.enterText(find.byType(TextField), 'https://example.com');
    await tester.pumpAndSettle();
    await tester.tap(find.text(JamJoinLinkStrings.join));
    await tester.pumpAndSettle();

    expect(find.text(JamJoinLinkStrings.invalid), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    // Still open: the correction belongs where the mistake is.
    expect(find.text(JamJoinLinkStrings.title), findsOneWidget);

    // ...and typing clears it rather than leaving a stale accusation.
    await tester.enterText(find.byType(TextField), _link);
    await tester.pumpAndSettle();
    expect(find.text(JamJoinLinkStrings.invalid), findsNothing);
  });

  testWidgets('the primary action is dead until there is something to join', (
    tester,
  ) async {
    mockClipboard(null);
    await openDialog(tester);

    // The confirming action is disabled, not just untappable.
    final button = tester.widget<JamDialogPrimaryButton>(
      find.byType(JamDialogPrimaryButton),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('cancelling answers with nothing, on either palette', (
    tester,
  ) async {
    mockClipboard(_link);
    await openDialog(tester, theme: jamDarkTheme());

    await tester.tap(find.text(JamJoinLinkStrings.cancel));
    await tester.pumpAndSettle();
    expect(await pending, isNull);
  });
}
