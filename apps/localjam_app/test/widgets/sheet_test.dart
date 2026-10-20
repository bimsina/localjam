/// The sheet's header, its scroll plumbing, and the drag lock that keeps a
/// reorder drag from dismissing the sheet out from under the finger.
library;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/design/theme.dart';
import 'package:localjam_app/src/design/tokens.dart';
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
          actions: JamSheetActions.confirm(label: 'Add', onConfirm: () {}),
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
          actions: JamSheetActions.done(onDone: () => done++),
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

  ClipRRect surfaceClip(WidgetTester tester) => tester.widget<ClipRRect>(
    find
        .descendant(
          of: find.byType(JamSheetSurface),
          matching: find.byType(ClipRRect),
        )
        .first,
  );

  testWidgets('a medium sheet floats on all four corners, inset', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _host(
        (context) => showJamSheet<void>(
          context,
          title: 'People',
          actions: const JamSheetActions.done(),
          initialChildSize: kJamSheetMediumSize,
          builder: (_) => const SizedBox(height: 40),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    final radius = surfaceClip(tester).borderRadius as BorderRadius;
    expect(radius.bottomLeft.x, closeTo(JamRadius.sheetFloating, 0.1));
    final sheet = tester.getRect(find.byType(JamSheetHeader));
    expect(sheet.left, closeTo(JamRadius.sheetFloatingInset, 0.5));
    expect(jamOpenSheets.value, 1);
    await tester.tap(find.text(JamSheetStrings.done));
    await tester.pumpAndSettle();
    expect(jamOpenSheets.value, 0);
  });

  testWidgets('a large sheet is edge-attached', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _host(
        (context) => showJamSheet<void>(
          context,
          title: 'Queue',
          actions: const JamSheetActions.done(),
          builder: (_) => const SizedBox(height: 40),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    final radius = surfaceClip(tester).borderRadius as BorderRadius;
    expect(radius.bottomLeft.x, closeTo(0, 0.1));
    expect(radius.topLeft.x, JamRadius.sheet);
    expect(tester.getRect(find.byType(JamSheetHeader)).left, 0);
  });

  testWidgets('on a wide window a sheet is a centred form sheet', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1024, 1366);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _host(
        (context) => showJamSheet<void>(
          context,
          title: 'Invite People',
          actions: const JamSheetActions.done(),
          initialChildSize: kJamSheetMediumSize,
          builder: (_) => const SizedBox(height: 200),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    final header = tester.getRect(find.byType(JamSheetHeader));
    expect(header.center.dx, closeTo(512, 1));
    expect(header.width, lessThanOrEqualTo(kJamFormSheetMaxSize.width));
    // Centred, not bottom-attached, and no grabber: a form sheet does not
    // drag.
    expect(header.top, greaterThan(200));
    expect(find.byType(JamSheetGrabber), findsNothing);
  });

  testWidgets('the header rule: Cancel + verb, or one trailing Done', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var started = 0;
    Future<void> open(JamSheetActions actions) async {
      await tester.pumpWidget(
        _host(
          (context) => showJamSheet<void>(
            context,
            title: 'Sheet',
            actions: actions,
            scrollable: false,
            builder: (_) => const SizedBox(height: 40),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
    }

    await open(
      JamSheetActions.confirm(label: 'Start', onConfirm: () => started++),
    );
    expect(find.text(JamSheetStrings.cancel), findsOneWidget);
    await tester.tap(find.text('Start'));
    expect(started, 1);
    // Cancel sits left of the title, the verb right of it.
    expect(
      tester.getCenter(find.text(JamSheetStrings.cancel)).dx,
      lessThan(tester.getCenter(find.text('Sheet')).dx),
    );
    // Its text lands on the content margin, not 12 from the edge.
    expect(
      tester.getRect(find.text(JamSheetStrings.cancel)).left,
      closeTo(JamSpace.page + JamRadius.sheetFloatingInset, 1),
    );

    await tester.tap(find.text(JamSheetStrings.cancel));
    await tester.pumpAndSettle();
    expect(find.text('Sheet'), findsNothing);

    // Every other sheet — one that only shows something, one that applies
    // as it goes — closes one way (CR-24): one trailing Done, never an
    // xmark.
    await open(const JamSheetActions.done());
    expect(find.text(JamSheetStrings.done), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.xmark), findsNothing);
    expect(find.text(JamSheetStrings.cancel), findsNothing);
    expect(
      tester.getCenter(find.text(JamSheetStrings.done)).dx,
      greaterThan(tester.getCenter(find.text('Sheet')).dx),
    );
    await tester.tap(find.text(JamSheetStrings.done));
    await tester.pumpAndSettle();
    expect(find.text('Sheet'), findsNothing);
  });

  testWidgets('dragging the sheet down dismisses it', (tester) async {
    await tester.pumpWidget(
      _host(
        (context) => showJamSheet<void>(
          context,
          title: 'People',
          scrollable: false,
          builder: (_) => const SizedBox(height: 200),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.fling(find.text('People'), const Offset(0, 300), 1500);
    await tester.pumpAndSettle();
    expect(find.text('People'), findsNothing);
  });

  testWidgets('the closing Done pops the sheet', (tester) async {
    await tester.pumpWidget(
      _host(
        (context) => showJamSheet<void>(
          context,
          title: 'Invite People',
          actions: const JamSheetActions.done(),
          builder: (_) => const SizedBox(height: 40),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(JamSheetStrings.done));
    await tester.pumpAndSettle();
    expect(find.text('Invite People'), findsNothing);
  });

  group('the room keeps what it opens in its own dark (R2)', () {
    /// A page that is dark whatever the app says, as the room is: its
    /// State-level context sits above its own dark theme, and it declares
    /// the appearance of what it presents.
    Widget room(void Function(BuildContext) open, {bool declare = true}) =>
        MaterialApp(
          theme: jamLightTheme(),
          home: Builder(
            builder: (outer) => JamForcedAppearance(
              brightness: Brightness.dark,
              child: Scaffold(
                body: Stack(
                  children: [
                    if (declare)
                      const JamPresentationAppearance(
                        brightness: Brightness.dark,
                      ),
                    Center(
                      child: TextButton(
                        // The outer context: above the page's dark theme,
                        // like a room State's own.
                        onPressed: () => open(outer),
                        child: const Text('Open'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );

    Color sheetGround(WidgetTester tester) => tester
        .widget<ColoredBox>(
          find
              .descendant(
                of: find.byType(JamSheetSurface),
                matching: find.byType(ColoredBox),
              )
              .first,
        )
        .color;

    Color barrier(WidgetTester tester) =>
        tester.widgetList<ModalBarrier>(find.byType(ModalBarrier)).last.color!;

    testWidgets('a sheet asked for from the room is dark in a light app', (
      tester,
    ) async {
      await tester.pumpWidget(
        room(
          (context) => showJamSheet<void>(
            context,
            title: 'People',
            builder: (_) => const SizedBox(height: 40),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(sheetGround(tester), JamColors.dark.elevated);
      expect(
        Theme.of(tester.element(find.text('People'))).brightness,
        Brightness.dark,
      );
      expect(barrier(tester), JamColors.dark.scrim);
      // And anything opened from inside it stays dark too.
      expect(
        jamPresentationBrightness(tester.element(find.text('People'))),
        Brightness.dark,
      );
    });

    testWidgets('without the declaration the State context gets the app\'s', (
      tester,
    ) async {
      await tester.pumpWidget(
        room(
          (context) => showJamSheet<void>(
            context,
            title: 'People',
            builder: (_) => const SizedBox(height: 40),
          ),
          declare: false,
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(sheetGround(tester), JamColors.light.elevated);
    });

    testWidgets('a call from inside a dark subtree follows it', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: jamLightTheme(),
          home: JamForcedAppearance(
            brightness: Brightness.dark,
            child: Scaffold(
              body: Builder(
                builder: (inner) => TextButton(
                  onPressed: () => showJamSheet<void>(
                    inner,
                    title: 'Sound Offset',
                    builder: (_) => const SizedBox(height: 40),
                  ),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(sheetGround(tester), JamColors.dark.elevated);
    });

    testWidgets('on an ordinary page nothing changes', (tester) async {
      await tester.pumpWidget(
        _host(
          (context) => showJamSheet<void>(
            context,
            title: 'Library',
            builder: (_) => const SizedBox(height: 40),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(sheetGround(tester), JamColors.light.elevated);
      expect(barrier(tester), JamColors.light.scrim);
      expect(
        jamPresentationBrightness(tester.element(find.text('Library'))),
        isNull,
      );
    });

    testWidgets('the declaration goes with the page that made it', (
      tester,
    ) async {
      late BuildContext page;
      Widget app({required bool declare}) => MaterialApp(
        theme: jamLightTheme(),
        home: Builder(
          builder: (context) {
            page = context;
            return Stack(
              children: [
                if (declare)
                  const JamPresentationAppearance(brightness: Brightness.dark),
              ],
            );
          },
        ),
      );
      await tester.pumpWidget(app(declare: true));
      expect(jamPresentationBrightness(page), Brightness.dark);
      // The room becomes the light "jam ended" page: its sheets follow
      // the app again.
      await tester.pumpWidget(app(declare: false));
      expect(jamPresentationBrightness(page), isNull);
    });
  });
}
