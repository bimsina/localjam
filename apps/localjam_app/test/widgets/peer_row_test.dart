import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/design/theme.dart';
import 'package:localjam_app/src/design/tokens.dart';
import 'package:localjam_app/src/widgets/avatar.dart';
import 'package:localjam_app/src/widgets/peer_row.dart';

Future<void> pumpRow(WidgetTester tester, Widget child, {bool dark = false}) {
  final theme = dark ? jamDarkTheme() : jamLightTheme();
  // An inner Theme, not just MaterialApp's: MaterialApp animates a theme
  // change, so a single pump would still be halfway through the old palette.
  return tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: Theme(
        data: theme,
        child: Scaffold(body: child),
      ),
    ),
  );
}

void main() {
  group('JamPeerRow', () {
    testWidgets('shows the name and detail in both themes, at 64 high', (
      tester,
    ) async {
      for (final dark in [false, true]) {
        await pumpRow(
          tester,
          const JamPeerRow(name: 'Silky Puffin', detail: 'You'),
          dark: dark,
        );
        expect(find.text('Silky Puffin'), findsOneWidget);
        expect(find.text('You'), findsOneWidget);
        expect(
          tester.getSize(find.byType(JamPeerRow)).height,
          kJamPeerRowHeight,
        );
      }
    });

    testWidgets('badges the host and the co-host, and nobody else', (
      tester,
    ) async {
      await pumpRow(
        tester,
        const JamPeerRow(name: 'Silky Puffin', role: JamPeerRole.host),
      );
      expect(find.text('HOST'), findsOneWidget);

      await pumpRow(
        tester,
        const JamPeerRow(name: 'Silky Puffin', role: JamPeerRole.cohost),
      );
      expect(find.text('CO-HOST'), findsOneWidget);

      await pumpRow(tester, const JamPeerRow(name: 'Silky Puffin'));
      expect(find.text('HOST'), findsNothing);
      expect(find.text('CO-HOST'), findsNothing);
    });

    testWidgets('faces carry no ring (D6)', (tester) async {
      await pumpRow(
        tester,
        const JamPeerRow(
          name: 'Silky Puffin',
          role: JamPeerRole.host,
          isYou: true,
        ),
      );
      final face = find.descendant(
        of: find.byType(JamAvatar),
        matching: find.byType(Container),
      );
      expect(
        (tester.widget<Container>(face).decoration! as BoxDecoration).border,
        isNull,
      );
    });

    testWidgets('readiness replaces the detail line', (tester) async {
      await pumpRow(
        tester,
        const JamPeerRow(
          name: 'Silky Puffin',
          detail: 'Joined just now',
          readiness: JamPeerReadiness.fetching,
          fetchProgress: 0.25,
        ),
      );
      expect(find.text('Joined just now'), findsNothing);
      expect(find.text(JamPeerRowStrings.fetching), findsOneWidget);
      expect(
        tester.widget<Text>(find.text(JamPeerRowStrings.fetching)).style!.color,
        JamColors.light.warning,
      );
      expect(
        tester
            .widget<CircularProgressIndicator>(
              find.byType(CircularProgressIndicator),
            )
            .value,
        0.25,
      );

      await pumpRow(
        tester,
        const JamPeerRow(
          name: 'Silky Puffin',
          readiness: JamPeerReadiness.missing,
        ),
      );
      expect(
        tester.widget<Text>(find.text(JamPeerRowStrings.missing)).style!.color,
        JamColors.light.danger,
      );

      await pumpRow(
        tester,
        const JamPeerRow(
          name: 'Silky Puffin',
          readiness: JamPeerReadiness.ready,
        ),
      );
      expect(find.text(JamPeerRowStrings.listening), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('offers the overflow only when asked to', (tester) async {
      await pumpRow(tester, const JamPeerRow(name: 'Silky Puffin'));
      expect(find.byIcon(Icons.more_horiz_rounded), findsNothing);

      var tapped = 0;
      await pumpRow(
        tester,
        JamPeerRow(
          name: 'Silky Puffin',
          showMenu: true,
          onMenuTap: () => tapped++,
        ),
      );
      await tester.tap(find.byIcon(Icons.more_horiz_rounded));
      expect(tapped, 1);
    });

    testWidgets('announces name, role and readiness together', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpRow(
        tester,
        const JamPeerRow(
          name: 'Silky Puffin',
          role: JamPeerRole.cohost,
          readiness: JamPeerReadiness.ready,
        ),
      );
      expect(
        find.bySemanticsLabel('Silky Puffin, CO-HOST, Listening'),
        findsOneWidget,
      );
      handle.dispose();
    });
  });
}
