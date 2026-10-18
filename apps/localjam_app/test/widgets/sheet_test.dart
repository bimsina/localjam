/// The sheet's header, its scroll plumbing, and the drag lock that keeps a
/// reorder drag from dismissing the sheet out from under the finger.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/design/theme.dart';
import 'package:localjam_app/src/design/tokens.dart';
import 'package:localjam_app/src/widgets/buttons.dart';
import 'package:localjam_app/src/widgets/list.dart';
import 'package:localjam_app/src/widgets/section.dart';
import 'package:localjam_app/src/widgets/sheet.dart';

Widget _host(void Function(BuildContext) onTap, {ThemeData? theme}) =>
    MaterialApp(
      theme: theme ?? jamLightTheme(),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => onTap(context),
            child: const Text('Open'),
          ),
        ),
      ),
    );

void main() {
  testWidgets('shows a title, a trailing action and the content', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        (context) => showJamSheet<void>(
          context,
          title: 'Queue',
          trailing: const Text('Add'),
          builder: (_) => const Text('Nothing queued'),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.byType(JamSheetHeader), findsOneWidget);
    expect(find.text('Queue'), findsOneWidget);
    expect(find.text('Add'), findsOneWidget);
    expect(find.text('Nothing queued'), findsOneWidget);
  });

  testWidgets('a scrollable sheet publishes its scroll controller', (
    tester,
  ) async {
    ScrollController? seen;
    await tester.pumpWidget(
      _host(
        (context) => showJamSheet<void>(
          context,
          title: 'People',
          builder: (context) {
            seen = JamSheetScrollController.maybeOf(context);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(seen, isNotNull);
  });

  testWidgets('a non-scrollable sheet has no controller to hand out', (
    tester,
  ) async {
    ScrollController? seen;
    var called = false;
    await tester.pumpWidget(
      _host(
        (context) => showJamSheet<void>(
          context,
          title: 'Diagnostics',
          scrollable: false,
          builder: (context) {
            called = true;
            seen = JamSheetScrollController.maybeOf(context);
            return const SizedBox(height: 80);
          },
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(called, isTrue);
    expect(seen, isNull);
  });

  testWidgets('content can lock and release the sheet drag', (tester) async {
    JamSheetDragLock? lock;
    await tester.pumpWidget(
      _host(
        (context) => showJamSheet<void>(
          context,
          title: 'Queue',
          builder: (context) {
            lock = JamSheetDragLock.maybeOf(context);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(lock, isNotNull);
    expect(lock!.isLocked, isFalse);
    expect(find.byKey(JamSheetDragGuard.blockerKey), findsNothing);

    lock!.lock();
    await tester.pump();
    // The guard only exists while locked, and it is what swallows the
    // vertical drag the sheet would otherwise dismiss on.
    expect(lock!.isLocked, isTrue);
    expect(find.byKey(JamSheetDragGuard.blockerKey), findsOneWidget);

    lock!.unlock();
    await tester.pump();
    expect(lock!.isLocked, isFalse);
    expect(find.byKey(JamSheetDragGuard.blockerKey), findsNothing);
  });

  test('the drag lock counts holders rather than flipping a flag', () {
    final lock = JamSheetDragLock();
    var notifications = 0;
    lock.addListener(() => notifications++);

    lock
      ..lock()
      ..lock();
    expect(lock.isLocked, isTrue);
    expect(notifications, 1, reason: 'only the transition notifies');

    lock.unlock();
    expect(lock.isLocked, isTrue, reason: 'the second holder still has it');
    lock.unlock();
    expect(lock.isLocked, isFalse);
    expect(notifications, 2);

    // An extra release from a cancelled drag must not go negative.
    lock.unlock();
    expect(lock.isLocked, isFalse);
    lock.dispose();
  });

  testWidgets('a sheet that cannot be dragged shows no grab handle', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        (context) => showJamSheet<void>(
          context,
          title: 'Locked',
          enableDrag: false,
          scrollable: false,
          builder: (_) => const SizedBox(height: 40),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    final scaffold = tester.widget<JamSheetScaffold>(
      find.byType(JamSheetScaffold),
    );
    expect(scaffold.showHandle, isFalse);
  });

  testWidgets('renders on the dark palette too', (tester) async {
    await tester.pumpWidget(
      _host(
        (context) => showJamSheet<void>(
          context,
          title: 'Queue',
          builder: (_) => const Text('Dark'),
        ),
        theme: jamDarkTheme(),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.text('Dark'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('iOS chrome: 36×5 grabber, centred headline title, Done', (
    tester,
  ) async {
    var done = 0;
    await tester.pumpWidget(
      _host(
        (context) => showJamSheet<void>(
          context,
          title: 'People',
          trailing: JamTextButton(
            label: JamSheetStrings.done,
            bold: true,
            onPressed: () => done++,
          ),
          builder: (_) => const SizedBox(height: 40),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    final grabber = find.descendant(
      of: find.byType(JamSheetGrabber),
      matching: find.byType(Container),
    );
    expect(tester.getSize(grabber), const Size(36, 5));
    final title = tester.widget<Text>(find.text('People')).style!;
    expect(title.fontSize, 17);
    expect(title.fontWeight, FontWeight.w600);
    final sheetCenter = tester.getCenter(find.byType(JamSheetHeader)).dx;
    expect(tester.getCenter(find.text('People')).dx, closeTo(sheetCenter, 1));
    await tester.tap(find.text('Done'));
    expect(done, 1);
  });

  testWidgets('a grouped sheet uses the grouped ground and elevated rows', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        (context) => showJamSheet<void>(
          context,
          title: 'People',
          grouped: true,
          builder: (_) =>
              const JamSection(children: [JamRow(title: 'Invite People')]),
        ),
        theme: jamDarkTheme(),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    final grounds = tester
        .widgetList<ColoredBox>(find.byType(ColoredBox))
        .map((b) => b.color)
        .toList();
    expect(grounds, contains(JamColors.dark.elevatedGroupedBackground));
    expect(grounds, contains(JamColors.dark.elevatedGroupedSurface));
  });

  testWidgets('the glass close button pops the sheet', (tester) async {
    await tester.pumpWidget(
      _host(
        (context) => showJamSheet<void>(
          context,
          title: 'Invite People',
          trailing: const JamSheetCloseButton(),
          builder: (_) => const SizedBox(height: 40),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(JamSheetCloseButton));
    await tester.pumpAndSettle();
    expect(find.text('Invite People'), findsNothing);
  });
}
