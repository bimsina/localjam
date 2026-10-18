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
  testWidgets('shows the message with a status glyph', (tester) async {
    await tester.pumpWidget(
      _host((context) => showJamNotice(context, const JamNotice('Ana joined'))),
    );
    await tester.tap(find.text('Go'));
    await tester.pumpAndSettle();

    expect(find.byType(JamNoticeCard), findsOneWidget);
    expect(find.text('Ana joined'), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.info_circle_fill), findsOneWidget);
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
          ),
          kind: JamNoticeKind.error,
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
            kind: JamNoticeKind.error,
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

  testWidgets('renders on the dark palette', (tester) async {
    await tester.pumpWidget(
      _host(
        (context) => showJamNotice(
          context,
          const JamNotice('Reconnecting'),
          kind: JamNoticeKind.warning,
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
