/// The notice consumes the controller's own `JamNotice`, so the router shell
/// can hand its subscription straight to `showJamNotice` — and it is drawn
/// into the ROOT overlay, which is what puts it above a modal sheet.
library;

import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/design/theme.dart';
import 'package:localjam_app/src/widgets/notice.dart';

Widget _host(void Function(BuildContext) onTap, {ThemeData? theme}) =>
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
  group('how long a notice stays (N10)', () {
    const restarted =
        'That code no longer works because the jam restarted. Ask for a '
        'fresh one.';

    test('4 s, plus 60 ms a character', () {
      expect(
        jamNoticeDuration(const JamNotice('Ana joined')),
        const Duration(milliseconds: 4000 + 60 * 10),
      );
      // The restarted-jam toast QA missed twice: no longer 4 s.
      expect(
        jamNoticeDuration(const JamNotice(restarted)),
        const Duration(milliseconds: 4000 + 60 * restarted.length),
      );
      expect(
        jamNoticeDuration(const JamNotice(restarted))!,
        greaterThan(const Duration(seconds: 8)),
      );
    });

    test('never more than 10 s on its own', () {
      expect(jamNoticeDuration(JamNotice('word ' * 60)), kJamNoticeMaxDuration);
      expect(kJamNoticeMaxDuration, const Duration(seconds: 10));
    });

    test('an error with a way out waits for it', () {
      void retry() {}
      expect(
        jamNoticeDuration(
          JamNotice(
            'Couldn’t get this song',
            actionLabel: 'Try again',
            onAction: retry,
            tone: JamNoticeTone.error,
          ),
        ),
        isNull,
      );
      // An error with nothing to do, and a warning with an action, still
      // go on their own.
      expect(
        jamNoticeDuration(
          const JamNotice('Couldn’t open', tone: JamNoticeTone.error),
        ),
        isNotNull,
      );
      expect(
        jamNoticeDuration(
          JamNotice(
            'Music access is off',
            actionLabel: 'Open Settings',
            onAction: retry,
            tone: JamNoticeTone.warning,
          ),
        ),
        isNotNull,
      );
    });

    testWidgets('a long notice outlasts 4 s, then goes', (tester) async {
      await tester.pumpWidget(
        _host((context) => showJamNotice(context, const JamNotice(restarted))),
      );
      await tester.tap(find.text('Go'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 5));
      expect(find.byType(JamNoticeCard), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(find.byType(JamNoticeCard), findsNothing);
    });

    testWidgets('an error with an action stays until acted on or dismissed', (
      tester,
    ) async {
      var retried = 0;
      JamNotice error() => JamNotice(
        'Couldn’t get this song',
        actionLabel: 'Try again',
        onAction: () => retried++,
        tone: JamNoticeTone.error,
      );
      await tester.pumpWidget(
        _host((context) => showJamNotice(context, error())),
      );
      await tester.tap(find.text('Go'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(minutes: 1));
      expect(find.byType(JamNoticeCard), findsOneWidget);

      // Acted on: it goes.
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(retried, 1);
      expect(find.byType(JamNoticeCard), findsNothing);

      // Dismissed with a tap: it goes, without acting.
      await tester.tap(find.text('Go'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Couldn’t get this song'));
      await tester.pumpAndSettle();
      expect(retried, 1);
      expect(find.byType(JamNoticeCard), findsNothing);
    });
  });

  testWidgets('shows the message with a status glyph', (tester) async {
    await tester.pumpWidget(
      _host(
        (context) => showJamNotice(
          context,
          const JamNotice('Ana joined', tone: JamNoticeTone.people),
        ),
      ),
    );
    await tester.tap(find.text('Go'));
    await tester.pumpAndSettle();

    expect(find.byType(JamNoticeCard), findsOneWidget);
    expect(find.text('Ana joined'), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.person_fill), findsOneWidget);
  });

  testWidgets('the glyph follows the tone the sender gave', (tester) async {
    const glyphs = <JamNoticeTone, IconData?>{
      JamNoticeTone.neutral: null,
      JamNoticeTone.done: CupertinoIcons.checkmark_circle_fill,
      JamNoticeTone.people: CupertinoIcons.person_fill,
      JamNoticeTone.warning: CupertinoIcons.exclamationmark_triangle_fill,
      JamNoticeTone.error: CupertinoIcons.xmark_octagon_fill,
    };
    for (final MapEntry(key: tone, value: glyph) in glyphs.entries) {
      await tester.pumpWidget(
        MaterialApp(
          theme: jamLightTheme(),
          home: Scaffold(
            body: JamNoticeBody(message: 'x', tone: tone),
          ),
        ),
      );
      final icons = find.descendant(
        of: find.byType(JamNoticeBody),
        matching: find.byType(Icon),
      );
      if (glyph == null) {
        expect(icons, findsNothing, reason: '$tone');
      } else {
        expect(find.byIcon(glyph), findsOneWidget, reason: '$tone');
      }
    }
    // Unsaid is neutral: no glyph, never a guess from the words.
    expect(const JamNotice('Link copied').tone, JamNoticeTone.neutral);
  });

  testWidgets('an Undo notice carries no glyph at all', (tester) async {
    await tester.pumpWidget(
      _host(
        (context) => showJamNotice(
          context,
          JamNotice('Removed “Low Tide”', actionLabel: 'Undo', onAction: () {}),
        ),
      ),
    );
    await tester.tap(find.text('Go'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(JamNoticeBody),
        matching: find.byType(Icon),
      ),
      findsNothing,
    );
    expect(find.text('Undo'), findsOneWidget);
  });

  testWidgets('a top notice floats under the status bar', (tester) async {
    await tester.pumpWidget(
      _host(
        (context) => showJamNotice(
          context,
          const JamNotice('Ana joined'),
          position: JamNoticePosition.top,
        ),
      ),
    );
    await tester.tap(find.text('Go'));
    await tester.pumpAndSettle();
    final card = tester.getRect(find.byType(JamNoticeCard));
    expect(card.top, lessThan(100));
  });

  testWidgets('an error carries its own glyph and its action', (tester) async {
    var retried = 0;
    await tester.pumpWidget(
      _host(
        (context) => showJamNotice(
          context,
          JamNotice(
            'Could not join',
            actionLabel: 'Retry',
            onAction: () => retried++,
            tone: JamNoticeTone.error,
          ),
        ),
      ),
    );
    await tester.tap(find.text('Go'));
    await tester.pumpAndSettle();

    expect(find.byIcon(CupertinoIcons.xmark_octagon_fill), findsOneWidget);
    // Still a capsule, not a pill the height of the window: the action's
    // own 44 box must not stretch the row.
    expect(
      tester.getSize(find.byType(JamNoticeCard)).height,
      lessThanOrEqualTo(60),
    );
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(retried, 1);
  });

  testWidgets('an action with no callback is not rendered', (tester) async {
    await tester.pumpWidget(
      _host(
        (context) => showJamNotice(
          context,
          const JamNotice('Something happened', actionLabel: 'Retry'),
        ),
      ),
    );
    await tester.tap(find.text('Go'));
    await tester.pumpAndSettle();

    expect(find.text('Retry'), findsNothing);
  });

  testWidgets('a second notice replaces the first rather than queueing', (
    tester,
  ) async {
    late BuildContext ctx;
    await tester.pumpWidget(
      _host((context) {
        ctx = context;
        showJamNotice(context, const JamNotice('First'));
      }),
    );
    await tester.tap(find.text('Go'));
    await tester.pumpAndSettle();
    expect(find.text('First'), findsOneWidget);

    showJamNotice(ctx, const JamNotice('Second'));
    await tester.pumpAndSettle();

    expect(find.text('First'), findsNothing);
    expect(find.text('Second'), findsOneWidget);
  });

  testWidgets('announces the kind to a screen reader', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        theme: jamLightTheme(),
        home: const Scaffold(
          body: JamNoticeBody(
            message: 'Out of sync',
            tone: JamNoticeTone.error,
          ),
        ),
      ),
    );

    expect(find.bySemanticsLabel('Error. Out of sync'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('draws above a modal sheet', (tester) async {
    // The whole reason it is not a SnackBar: a messenger's snackbar is a
    // child of the messenger, which sits under every modal route, so "Room
    // code copied" was painted behind the sheet that raised it.
    late BuildContext sheetContext;
    await tester.pumpWidget(
      _host((context) {
        unawaited(
          showModalBottomSheet<void>(
            context: context,
            builder: (context) {
              sheetContext = context;
              return const SizedBox(height: 200);
            },
          ),
        );
      }),
    );
    await tester.tap(find.text('Go'));
    await tester.pumpAndSettle();

    showJamNotice(sheetContext, const JamNotice('Invite link copied.'));
    await tester.pumpAndSettle();

    final notice = tester.getTopLeft(find.byType(JamNoticeCard));
    expect(find.text('Invite link copied.'), findsOneWidget);
    // Below the sheet's own top edge, and painted after it.
    expect(notice.dy, greaterThan(0));
    expect(tester.takeException(), isNull);
  });

  testWidgets('goes on its own after its duration', (tester) async {
    await tester.pumpWidget(
      _host(
        (context) => showJamNotice(
          context,
          const JamNotice('Ana joined'),
          duration: const Duration(seconds: 1),
        ),
      ),
    );
    await tester.tap(find.text('Go'));
    await tester.pumpAndSettle();
    expect(find.byType(JamNoticeCard), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.byType(JamNoticeCard), findsNothing);
  });

  testWidgets('rises into place — and under Reduce Motion fades where it '
      'stands', (tester) async {
    Future<double> midwayOffset({required bool still}) async {
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(disableAnimations: still),
          child: _host(
            (context) => showJamNotice(context, const JamNotice('Ana joined')),
          ),
        ),
      );
      await tester.tap(find.text('Go'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      final midway = tester.getTopLeft(find.byType(JamNoticeCard)).dy;
      await tester.pumpAndSettle();
      final settled = tester.getTopLeft(find.byType(JamNoticeCard)).dy;
      // Gone before the next case.
      await tester.pump(kJamNoticeMaxDuration);
      await tester.pumpAndSettle();
      return midway - settled;
    }

    expect(await midwayOffset(still: false), greaterThan(0));
    expect(await midwayOffset(still: true), 0);
  });

  testWidgets('renders on the dark palette', (tester) async {
    await tester.pumpWidget(
      _host(
        (context) => showJamNotice(
          context,
          const JamNotice('Reconnecting', tone: JamNoticeTone.warning),
        ),
        theme: jamDarkTheme(),
      ),
    );
    await tester.tap(find.text('Go'));
    await tester.pumpAndSettle();

    expect(
      find.byIcon(CupertinoIcons.exclamationmark_triangle_fill),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
