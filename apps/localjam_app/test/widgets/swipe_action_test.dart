/// The one trailing swipe action Past Jams, Start a Jam and the queue share.
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SemanticsAction;
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/design/theme.dart';
import 'package:localjam_app/src/design/tokens.dart';
import 'package:localjam_app/src/widgets/list.dart';
import 'package:localjam_app/src/widgets/swipe_action.dart';

Widget _host(Widget child) => MaterialApp(
  theme: jamLightTheme(),
  home: Scaffold(body: ListView(children: [child])),
);

void main() {
  testWidgets('a short swipe uncovers the red button; tapping it runs the '
      'action, and the row collapses before it is removed', (tester) async {
    var asked = 0;
    var removed = 0;
    await tester.pumpWidget(
      _host(
        JamSwipeAction(
          label: 'Forget',
          onAction: () async {
            asked++;
            return true;
          },
          onRemoved: () => removed++,
          child: const JamRow(title: 'Van Jam'),
        ),
      ),
    );
    expect(find.text('Forget'), findsNothing);

    await tester.drag(find.text('Van Jam'), const Offset(-70, 0));
    await tester.pumpAndSettle();
    expect(find.text('Forget'), findsOneWidget);
    final button = tester.widget<ColoredBox>(
      find.ancestor(of: find.text('Forget'), matching: find.byType(ColoredBox)),
    );
    expect(button.color, JamColors.light.danger);

    await tester.tap(find.text('Forget'));
    await tester.pumpAndSettle();
    expect(asked, 1);
    expect(removed, 1);
    expect(
      tester.getSize(find.byType(JamSwipeAction, skipOffstage: false)).height,
      0,
    );
  });

  testWidgets('a declined action slides the row back and keeps it', (
    tester,
  ) async {
    var removed = 0;
    await tester.pumpWidget(
      _host(
        JamSwipeAction(
          label: 'Remove',
          onAction: () async => false,
          onRemoved: () => removed++,
          child: const JamRow(title: 'Night Drive'),
        ),
      ),
    );
    // All the way: the full swipe runs the action without a tap.
    await tester.drag(find.text('Night Drive'), const Offset(-600, 0));
    await tester.pumpAndSettle();
    expect(removed, 0);
    expect(find.text('Remove'), findsNothing);
    expect(tester.getTopLeft(find.byType(JamRow)).dx, 0);
    expect(tester.getSize(find.byType(JamSwipeAction)).height, 44);
  });

  testWidgets('tapping an uncovered row closes it rather than opening it', (
    tester,
  ) async {
    var opened = 0;
    await tester.pumpWidget(
      _host(
        JamSwipeAction(
          label: 'Forget',
          onAction: () async => true,
          child: JamRow(title: 'Bar Room', onTap: () => opened++),
        ),
      ),
    );
    await tester.drag(find.text('Bar Room'), const Offset(-70, 0));
    await tester.pumpAndSettle();
    expect(find.text('Forget'), findsOneWidget);
    // The middle of what is left of the row on screen.
    await tester.tapAt(tester.getCenter(find.byType(JamSwipeAction)));
    await tester.pumpAndSettle();
    expect(opened, 0);
    expect(find.text('Forget'), findsNothing);
  });

  testWidgets('a screen reader gets the action by name', (tester) async {
    final handle = tester.ensureSemantics();
    var asked = 0;
    await tester.pumpWidget(
      _host(
        JamSwipeAction(
          label: 'Forget',
          semanticLabel: 'Forget Van Jam',
          onAction: () async {
            asked++;
            return false;
          },
          child: const JamRow(title: 'Van Jam'),
        ),
      ),
    );
    final node = tester.getSemantics(find.byType(JamSwipeAction));
    expect(
      node.getSemanticsData().hasAction(SemanticsAction.customAction),
      isTrue,
    );
    expect(node.getSemanticsData().customSemanticsActionIds, isNotEmpty);
    handle.dispose();
    expect(asked, 0);
  });

  testWidgets('disabled, it is just the row', (tester) async {
    await tester.pumpWidget(
      _host(
        JamSwipeAction(
          label: 'Remove',
          enabled: false,
          onAction: () async => true,
          child: const JamRow(title: 'Golf'),
        ),
      ),
    );
    await tester.drag(find.text('Golf'), const Offset(-200, 0));
    await tester.pumpAndSettle();
    expect(find.text('Remove'), findsNothing);
  });
}
