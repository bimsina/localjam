import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show MaterialApp, Scaffold, Theme;
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/design/theme.dart';
import 'package:localjam_app/src/design/tokens.dart';
import 'package:localjam_app/src/widgets/avatar.dart';
import 'package:localjam_app/src/widgets/menu.dart';
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
    testWidgets('a 40 face, the name, and nothing else for a plain guest', (
      tester,
    ) async {
      for (final dark in [false, true]) {
        await pumpRow(
          tester,
          const JamPeerRow(name: 'Silky Puffin'),
          dark: dark,
        );
        expect(find.text('Silky Puffin'), findsOneWidget);
        expect(
          tester.widget<JamAvatar>(find.byType(JamAvatar)).size,
          JamAvatarSize.sheet,
        );
        // No "Listening", no "Guest": a person who is simply fine gets a
        // name.
        expect(const JamPeerRow(name: 'x').subtitle, isNull);
        expect(tester.takeException(), isNull);
      }
    });

    testWidgets('roles are plain secondary text, never a pill', (tester) async {
      await pumpRow(
        tester,
        const JamPeerRow(
          name: 'Silky Puffin',
          role: JamPeerRole.host,
          isYou: true,
        ),
      );
      expect(find.text('Host · You'), findsOneWidget);
      final text = tester.widget<Text>(find.text('Host · You'));
      expect(text.style!.color, JamColors.light.secondaryLabel);
      // Nothing uppercased for styling.
      expect(find.text('HOST'), findsNothing);

      expect(
        const JamPeerRow(name: 'x', role: JamPeerRole.cohost).subtitle,
        JamPeerRowStrings.cohost,
      );
      expect(const JamPeerRow(name: 'x', isYou: true).subtitle, 'You');
      expect(
        const JamPeerRow(
          name: 'x',
          role: JamPeerRole.cohost,
          detail: 'Can’t add music',
        ).subtitle,
        'Co-host · Can’t add music',
      );
    });

    testWidgets('a guest still loading says so in warning, with progress', (
      tester,
    ) async {
      await pumpRow(
        tester,
        const JamPeerRow(
          name: 'Silky Puffin',
          role: JamPeerRole.cohost,
          readiness: JamPeerReadiness.fetching,
          fetchProgress: 0.4,
        ),
      );
      final line = JamPeerRowStrings.loadingProgress(40);
      expect(find.text(line), findsOneWidget);
      expect(
        tester.widget<Text>(find.text(line)).style!.color,
        JamColors.light.warning,
      );

      // Not yet fetching at all: the same quiet warning, no percentage.
      expect(
        const JamPeerRow(
          name: 'x',
          readiness: JamPeerReadiness.missing,
        ).subtitle,
        JamPeerRowStrings.loading,
      );
      // Ready is not news.
      expect(
        const JamPeerRow(name: 'x', readiness: JamPeerReadiness.ready).subtitle,
        isNull,
      );
    });

    testWidgets('offers the "•••" only with a menu, and it opens', (
      tester,
    ) async {
      await pumpRow(tester, const JamPeerRow(name: 'Silky Puffin'));
      expect(find.byType(JamMenuButton), findsNothing);

      var tapped = 0;
      await pumpRow(
        tester,
        JamPeerRow(
          name: 'Silky Puffin',
          menu: [
            [JamMenuItem(title: 'Make Co-host', onPressed: () => tapped++)],
          ],
        ),
      );
      expect(
        find.bySemanticsLabel(JamPeerRowStrings.more('Silky Puffin')),
        findsOneWidget,
      );
      await tester.tap(find.byIcon(CupertinoIcons.ellipsis_circle));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Make Co-host'));
      await tester.pumpAndSettle();
      expect(tapped, 1);
    });

    testWidgets('reads as one element: name, then the line under it', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpRow(
        tester,
        const JamPeerRow(name: 'Silky Puffin', role: JamPeerRole.cohost),
      );
      expect(find.bySemanticsLabel('Silky Puffin\nCo-host'), findsOneWidget);
      handle.dispose();
    });
  });
}
