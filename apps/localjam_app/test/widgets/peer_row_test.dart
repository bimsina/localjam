import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show MaterialApp, Scaffold, Theme;
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/design/theme.dart';
import 'package:localjam_app/src/design/tokens.dart';
import 'package:localjam_app/src/widgets/avatar.dart';
import 'package:localjam_app/src/widgets/menu.dart';
import 'package:localjam_app/src/util/format.dart';
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
            [JamMenuItem(title: 'Make co-host', onPressed: () => tapped++)],
          ],
        ),
      );
      expect(
        find.bySemanticsLabel(JamPeerRowStrings.more('Silky Puffin')),
        findsOneWidget,
      );
      // A quiet glyph in secondaryLabel, not a raspberry circle per row.
      final glyph = tester.widget<Icon>(find.byIcon(CupertinoIcons.ellipsis));
      expect(glyph.color, JamColors.light.secondaryLabel);
      expect(find.byIcon(CupertinoIcons.ellipsis_circle), findsNothing);
      await tester.tap(find.byIcon(CupertinoIcons.ellipsis));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Make co-host'));
      await tester.pumpAndSettle();
      expect(tapped, 1);
    });

    testWidgets("passes the jam's colour to the face, else the name's", (
      tester,
    ) async {
      const assigned = Color(0xFF123456);
      await pumpRow(
        tester,
        const JamPeerRow(name: 'Silky Puffin', color: assigned),
      );
      expect(
        tester.widget<JamAvatar>(find.byType(JamAvatar)).resolvedColor,
        assigned,
      );
      await pumpRow(tester, const JamPeerRow(name: 'Silky Puffin'));
      expect(
        tester.widget<JamAvatar>(find.byType(JamAvatar)).resolvedColor,
        identityColor('Silky Puffin'),
      );
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

  group('JamPeopleLine', () {
    const style = TextStyle(fontSize: 10, height: 1.2);
    final eight = JamPeoplePhrase.summary([
      'Electric Mongoose Supreme',
      'Theo',
      'Ana',
      'Jo',
      'Okon',
      'Mia',
      'Sam',
      'Lu',
    ]);

    JamPeopleFit fit(JamPeoplePhrase phrase, double width) =>
        JamPeopleFit.of(phrase, style: style, maxWidth: width);

    test('the whole phrase when it fits', () {
      final whole = fit(eight, 2000);
      expect(whole.runs.single.text, eight.text);
      expect(whole.spoken, eight.text);
    });

    test('a narrow line cuts the names, never the count', () {
      final cut = fit(eight, 300);
      expect(cut.runs.last, (text: ' and 6 others', cut: false));
      // The long name gives way first; the short one keeps all of itself.
      final long = cut.runs.firstWhere((r) => r.cut);
      expect(long.text, endsWith('…'));
      expect(
        'Electric Mongoose Supreme',
        startsWith(long.text.substring(0, long.text.length - 1)),
      );
      expect(cut.runs.firstWhere((r) => r.text == 'Theo').cut, isFalse);
      // The spoken line is the phrase it stands for.
      expect(cut.spoken, eight.text);
    });

    test('a name cut at a space leaves no gap before its ellipsis', () {
      // The Now Playing footer's case: "Electric " fits and "Electric M"
      // does not — the line reads "With Electric…, Mia", not
      // "With Electric …, Mia".
      final four = JamPeoplePhrase.summary([
        'Electric Mongoose Supreme',
        'Mia',
        'Theo',
        'Ana',
        'Jo',
        'Sam',
      ]);
      for (var width = 120.0; width <= 260; width += 0.5) {
        final line = fit(four, width);
        for (final run in line.runs.where((r) => r.cut)) {
          expect(run.text, endsWith('…'));
          expect(run.text, isNot(contains(' …')), reason: 'at $width');
          expect(
            _width(line.runs.map((r) => r.text).join(), style),
            lessThanOrEqualTo(width),
            reason: 'at $width',
          );
        }
      }
      // And at the width where the cut lands just after "Electric ".
      final electric = _width('With Electric …, Mia and 4 others', style);
      final atSpace = fit(four, electric + 1);
      expect(
        atSpace.runs.map((r) => r.text).join(),
        'With Electric…, Mia and 4 others',
      );
    });

    test('too narrow for a letter of each name: the count alone', () {
      final counted = fit(eight, 160);
      expect(counted.runs.single.text, 'With 8 people');
      expect(counted.spoken, 'With 8 people');
    });

    testWidgets('drawn: the count whole, no overflow, the label what it '
        'shows', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: SizedBox(
              width: 300,
              child: JamPeopleLine(eight, style: style),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text(' and 6 others'), findsOneWidget);
      expect(find.bySemanticsLabel(eight.text), findsOneWidget);
      handle.dispose();
    });

    testWidgets('a cut name is as wide as it draws: the words after it '
        'follow straight on, their spaces kept', (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 300,
              child: JamPeopleLine(eight, style: style),
            ),
          ),
        ),
      );
      final shown = fit(eight, 300).runs.firstWhere((r) => r.cut).text;
      final name = tester.getRect(find.text(shown));
      final comma = tester.getRect(find.text(', '));
      final lead = tester.getRect(find.text('With '));
      // No gap between the ellipsis and the comma after it: the name's box
      // is what it draws.
      expect(name.width, closeTo(_width(shown, style), 0.5));
      expect(comma.left, closeTo(name.right, 0.5));
      // The words between keep their trailing space: "With " is wider
      // than "With".
      expect(lead.right, closeTo(name.left, 0.5));
      expect(lead.width, greaterThan(_width('With', style)));
    });
  });
}

double _width(String text, TextStyle style) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
  )..layout();
  final width = painter.width;
  painter.dispose();
  return width;
}
