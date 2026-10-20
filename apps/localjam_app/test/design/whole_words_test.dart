/// Headings never break inside a word (N3): at AX5 the player's title read
/// "Golde / n Hour / Drive" and Home's header "Recen / t" beside See all.
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/design/theme.dart';
import 'package:localjam_app/src/design/typography.dart';
import 'package:localjam_app/src/widgets/buttons.dart';
import 'package:localjam_app/src/widgets/section.dart';

const _style = TextStyle(fontSize: 20, height: 1.2);

double _widestWord(String text, TextStyle style, TextScaler scaler) {
  var widest = 0.0;
  for (final word in text.split(' ')) {
    final p = TextPainter(
      text: TextSpan(text: word, style: style),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
    )..layout();
    if (p.width > widest) widest = p.width;
    p.dispose();
  }
  return widest;
}

void main() {
  group('jamWholeWordScaler', () {
    test('keeps the person’s scale when every word fits', () {
      const base = TextScaler.linear(2);
      final scaler = jamWholeWordScaler(
        text: 'Golden Hour Drive',
        style: _style,
        base: base,
        maxWidth: 1000,
      );
      expect(scaler, base);
    });

    test('steps down until the widest word fits', () {
      const base = TextScaler.linear(3);
      expect(_widestWord('Golden', _style, base), greaterThan(300));
      final scaler = jamWholeWordScaler(
        text: 'Golden Hour Drive',
        style: _style,
        base: base,
        maxWidth: 300,
      );
      expect(scaler.scale(20), lessThan(base.scale(20)));
      expect(scaler.scale(20), greaterThanOrEqualTo(20));
      expect(
        _widestWord('Golden Hour Drive', _style, scaler),
        lessThanOrEqualTo(300),
      );
    });

    test('never shrinks below the design size', () {
      final scaler = jamWholeWordScaler(
        text: 'Supercalifragilisticexpialidocious',
        style: _style,
        base: const TextScaler.linear(3),
        maxWidth: 100,
      );
      expect(scaler.scale(20), 20);
    });
  });

  Widget app(Widget child, {double scale = 3, double width = 300}) =>
      MaterialApp(
        theme: jamLightTheme(),
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(scale)),
          child: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(width: width, child: child),
            ),
          ),
        ),
      );

  testWidgets('a wrapped title breaks between words, not inside them', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(const JamWholeWords(child: Text('Golden Hour Drive', style: _style))),
    );
    // Still a Text, as before.
    expect(find.text('Golden Hour Drive'), findsOneWidget);
    final paragraph = tester.renderObject<RenderParagraph>(
      find.text('Golden Hour Drive'),
    );
    expect(paragraph.textScaler.scale(20), lessThan(60));
    expect(
      _widestWord('Golden Hour Drive', _style, paragraph.textScaler),
      lessThanOrEqualTo(300),
    );
  });

  testWidgets('at ordinary sizes nothing changes', (tester) async {
    await tester.pumpWidget(
      app(
        const JamWholeWords(child: Text('Golden Hour Drive', style: _style)),
        scale: 1,
      ),
    );
    final paragraph = tester.renderObject<RenderParagraph>(
      find.text('Golden Hour Drive'),
    );
    expect(paragraph.textScaler, TextScaler.noScaling);
  });

  testWidgets('it answers intrinsic sizes, so a row can measure it', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(
        const IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: JamWholeWords(
                  child: Text('Golden Hour Drive', style: _style),
                ),
              ),
              ColoredBox(color: Color(0xFF000000), child: SizedBox(width: 8)),
            ],
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });

  group('a section header and its action', () {
    Widget section() => JamSection.plain(
      header: 'Recent',
      headerTrailing: JamButton.plain(
        label: 'See all',
        size: JamButtonSize.small,
        onPressed: () {},
      ),
      children: const [SizedBox(height: 10)],
    );

    testWidgets('sit side by side when they fit', (tester) async {
      await tester.pumpWidget(app(section(), scale: 1, width: 400));
      final header = tester.getRect(find.text('Recent'));
      final action = tester.getRect(find.text('See all'));
      expect(action.left, greaterThan(header.right));
      expect(action.top, lessThan(header.bottom));
    });

    testWidgets('at the largest sizes the action wraps under the header, '
        'and the header stays whole', (tester) async {
      await tester.pumpWidget(app(section(), scale: 3.1, width: 370));
      final header = tester.getRect(find.text('Recent'));
      final action = tester.getRect(find.text('See all'));
      expect(action.top, greaterThanOrEqualTo(header.bottom - 0.5));
      // "Recent" on one line: no "Recen / t".
      final paragraph = tester.renderObject<RenderParagraph>(
        find.text('Recent'),
      );
      final boxes = paragraph.getBoxesForSelection(
        const TextSelection(baseOffset: 0, extentOffset: 6),
      );
      expect({for (final b in boxes) b.top}, hasLength(1));
      // The action's words start on the header's edge, not its padding's.
      expect(action.left, moreOrLessEquals(header.left, epsilon: 0.5));
    });
  });
}
