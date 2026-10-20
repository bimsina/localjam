import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/design/theme.dart';
import 'package:localjam_app/src/design/tokens.dart';
import 'package:localjam_app/src/widgets/text_field.dart';

Widget _host(Widget child, {bool dark = false}) => MaterialApp(
  theme: dark ? jamDarkTheme() : jamLightTheme(),
  home: Scaffold(
    body: Center(child: SizedBox(width: 300, child: child)),
  ),
);

void main() {
  testWidgets('one field: fill, the field radius, one clear button (CR-16)', (
    tester,
  ) async {
    final text = TextEditingController();
    addTearDown(text.dispose);
    final changes = <String>[];
    await tester.pumpWidget(
      _host(JamTextField(controller: text, onChanged: changes.add)),
    );
    final field = tester.widget<CupertinoTextField>(
      find.byType(CupertinoTextField),
    );
    final box = field.decoration!;
    expect(box.color, JamColors.light.fillSecondary);
    expect(box.borderRadius, BorderRadius.circular(JamRadius.field));
    // Cupertino's own clear button is off; ours shows only with text.
    expect(field.clearButtonMode, OverlayVisibilityMode.never);
    expect(find.byType(JamFieldClearButton), findsNothing);

    await tester.enterText(find.byType(CupertinoTextField), 'Sunday');
    await tester.pump();
    expect(find.byType(JamFieldClearButton), findsOneWidget);
    final circle = tester.widget<Container>(
      find.descendant(
        of: find.byType(JamFieldClearButton),
        matching: find.byType(Container),
      ),
    );
    expect(
      (circle.decoration! as BoxDecoration).color,
      JamColors.light.tertiaryLabel,
    );
    expect(
      tester.getSize(find.byType(JamFieldClearButton)).width,
      greaterThanOrEqualTo(kJamFieldClearSize),
    );

    await tester.tap(find.byType(JamFieldClearButton));
    await tester.pump();
    expect(text.text, isEmpty);
    expect(changes.last, isEmpty);
    expect(find.byType(JamFieldClearButton), findsNothing);
  });

  testWidgets('a search field leads with a magnifier', (tester) async {
    final text = TextEditingController();
    addTearDown(text.dispose);
    await tester.pumpWidget(
      _host(
        JamTextField(controller: text, search: true, placeholder: 'Search'),
      ),
    );
    expect(find.byIcon(CupertinoIcons.search), findsOneWidget);
    expect(
      tester
          .widget<CupertinoTextField>(find.byType(CupertinoTextField))
          .textInputAction,
      TextInputAction.search,
    );
  });

  testWidgets('an error draws a danger hairline round the field', (
    tester,
  ) async {
    final text = TextEditingController();
    addTearDown(text.dispose);
    await tester.pumpWidget(
      _host(JamTextField(controller: text, error: true), dark: true),
    );
    await tester.pumpAndSettle();
    final box = tester
        .widget<CupertinoTextField>(find.byType(CupertinoTextField))
        .decoration!;
    expect((box.border! as Border).top.color, JamColors.dark.danger);
  });
}
