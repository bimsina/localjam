/// Joining by pasted link — the way in when there is no camera and nothing
/// nearby.
library;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart'
    show ElevatedButton, MaterialApp, Scaffold, SnackBar, Theme, ThemeData;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/design/theme.dart';
import 'package:localjam_app/src/widgets/join_link_dialog.dart';

const String _link =
    'localjam://join?host=192.168.1.4&port=7000&token=abc123&name=Van';

/// What the dialog asked of the clipboard.
final List<String> clipboardCalls = [];

/// Answers the clipboard with [text], or with nothing at all, and records
/// every call.
void mockClipboard(String? text) {
  clipboardCalls.clear();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    clipboardCalls.add(call.method);
    return switch (call.method) {
      'Clipboard.hasStrings' => <String, Object?>{'value': text != null},
      'Clipboard.getData' =>
        text == null ? null : <String, Object?>{'text': text},
      _ => null,
    };
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
Future<void> openDialog(
  WidgetTester tester, {
  ThemeData? theme,
  Brightness? brightness,
}) async {
  pending = null;
  await tester.pumpWidget(
    MaterialApp(
      theme: theme ?? jamLightTheme(),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () =>
                  pending = promptForJoinLink(context, brightness: brightness),
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

/// Taps Join, whatever state it is in.
Future<void> tapJoin(WidgetTester tester) async {
  await tester.tap(find.text(JamJoinLinkStrings.join), warnIfMissed: false);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('opening never reads the clipboard (no Allow Paste prompt)', (
    tester,
  ) async {
    mockClipboard(_link);
    await openDialog(tester);

    expect(find.text(JamJoinLinkStrings.title), findsOneWidget);
    // Asking whether there is text doesn't prompt; reading it would.
    expect(clipboardCalls, isNot(contains('Clipboard.getData')));
    expect(find.text(_link), findsNothing);
    // ...but Paste is offered, because there is something to paste.
    expect(find.text(JamJoinLinkStrings.paste), findsOneWidget);
  });

  testWidgets('Paste takes a jam link from the clipboard, then Join joins', (
    tester,
  ) async {
    mockClipboard(_link);
    await openDialog(tester);

    await tester.tap(find.text(JamJoinLinkStrings.paste));
    await tester.pumpAndSettle();
    expect(clipboardCalls, contains('Clipboard.getData'));
    expect(find.text(_link), findsOneWidget);
    // Nothing left to paste.
    expect(find.text(JamJoinLinkStrings.paste), findsNothing);

    await tapJoin(tester);
    expect((await pending)?.queryParameters['host'], '192.168.1.4');
  });

  testWidgets('pasting something that is not a jam link keeps it out', (
    tester,
  ) async {
    // Pasting someone's shopping list into a URL box is worse than an empty
    // box.
    mockClipboard('milk, eggs, a new amp');
    await openDialog(tester);

    await tester.tap(find.text(JamJoinLinkStrings.paste));
    await tester.pumpAndSettle();
    expect(find.text('milk, eggs, a new amp'), findsNothing);
    // The message line says why, in its own place.
    expect(find.text(JamJoinLinkStrings.invalid), findsOneWidget);
    expect(find.text(JamJoinLinkStrings.message), findsNothing);
  });

  testWidgets('no Paste when the clipboard is empty', (tester) async {
    mockClipboard(null);
    await openDialog(tester);
    expect(find.text(JamJoinLinkStrings.paste), findsNothing);
  });

  testWidgets('Join stays dead until the text is a jam link', (tester) async {
    mockClipboard(null);
    await openDialog(tester);

    // Empty: nothing happens.
    await tapJoin(tester);
    expect(find.text(JamJoinLinkStrings.title), findsOneWidget);

    // Not a link: still nothing, and no error for merely typing.
    await tester.enterText(
      find.byType(CupertinoTextField),
      'https://example.com',
    );
    await tester.pumpAndSettle();
    await tapJoin(tester);
    expect(find.text(JamJoinLinkStrings.title), findsOneWidget);
    expect(find.text(JamJoinLinkStrings.invalid), findsNothing);
    expect(find.text(JamJoinLinkStrings.message), findsOneWidget);

    // A link: Join works.
    await tester.enterText(find.byType(CupertinoTextField), _link);
    await tester.pumpAndSettle();
    await tapJoin(tester);
    expect(find.text(JamJoinLinkStrings.title), findsNothing);
    expect((await pending)?.queryParameters['token'], 'abc123');
  });

  testWidgets('Return on a bad link says why, in the message line', (
    tester,
  ) async {
    mockClipboard(null);
    await openDialog(tester);

    await tester.enterText(find.byType(CupertinoTextField), 'not a link');
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await tester.pumpAndSettle();

    expect(find.text(JamJoinLinkStrings.invalid), findsOneWidget);
    expect(find.text(JamJoinLinkStrings.message), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
    // Still open: the correction belongs where the mistake is.
    expect(find.text(JamJoinLinkStrings.title), findsOneWidget);

    // ...and typing clears it rather than leaving a stale accusation.
    await tester.enterText(find.byType(CupertinoTextField), _link);
    await tester.pumpAndSettle();
    expect(find.text(JamJoinLinkStrings.invalid), findsNothing);
    expect(find.text(JamJoinLinkStrings.message), findsOneWidget);
  });

  testWidgets('a link field: no autocorrect, the URL keyboard', (tester) async {
    mockClipboard(null);
    await openDialog(tester);
    final field = tester.widget<CupertinoTextField>(
      find.byType(CupertinoTextField),
    );
    expect(field.autocorrect, isFalse);
    expect(field.enableSuggestions, isFalse);
    expect(field.keyboardType, TextInputType.url);
    expect(field.placeholder, JamJoinLinkStrings.hint);
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

  testWidgets('opened over the camera, the alert is dark on a light app', (
    tester,
  ) async {
    mockClipboard(null);
    await openDialog(tester, brightness: Brightness.dark);
    final context = tester.element(find.text(JamJoinLinkStrings.title));
    expect(Theme.of(context).brightness, Brightness.dark);
    expect(CupertinoTheme.brightnessOf(context), Brightness.dark);
  });

  group('the deep-link confirmation', () {
    Future<bool>? answer;

    Future<void> openConfirm(WidgetTester tester, {String? roomName}) async {
      answer = null;
      await tester.pumpWidget(
        MaterialApp(
          theme: jamLightTheme(),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () =>
                      answer = confirmLinkJoin(context, roomName: roomName),
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

    testWidgets('names the jam, and Join answers yes', (tester) async {
      await openConfirm(tester, roomName: "Mia's Jam");
      expect(find.text("Join Mia's Jam?"), findsOneWidget);
      expect(find.text(JamJoinLinkStrings.confirmBody), findsOneWidget);
      expect(find.text(JamJoinLinkStrings.cancel), findsOneWidget);
      await tester.tap(find.text(JamJoinLinkStrings.join));
      await tester.pumpAndSettle();
      expect(await answer, isTrue);
    });

    testWidgets('without a name it still asks, and Cancel answers no', (
      tester,
    ) async {
      await openConfirm(tester);
      expect(
        find.text(
          JamJoinLinkStrings.confirmTitle(
            JamJoinLinkStrings.confirmFallbackName,
          ),
        ),
        findsOneWidget,
      );
      await tester.tap(find.text(JamJoinLinkStrings.cancel));
      await tester.pumpAndSettle();
      expect(await answer, isFalse);
    });
  });
}
