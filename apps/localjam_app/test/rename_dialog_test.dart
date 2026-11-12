/// The dialog used to dispose its TextEditingController the moment
/// `showDialog` returned, while the exit transition was still building the
/// TextField that pointed at it — `'_dependents.isEmpty': is not true`, red
/// screen, on every rename. Pumping the exit animation to completion is the
/// whole test.
library;

import 'package:cupertino_ui/cupertino_ui.dart' show CupertinoTextField;
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/widgets/rename_dialog.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('saving a new name survives the dialog exit animation', (
    tester,
  ) async {
    String? saved;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                saved = await promptForName(context, current: 'Silky Puffin');
              },
              child: const Text('Rename'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    expect(find.byType(CupertinoTextField), findsOneWidget);

    await tester.enterText(find.byType(CupertinoTextField), 'Neon Walrus');
    await tester.tap(find.text('Save'));
    // The exit transition, all of it: this is where the disposed controller
    // used to blow up.
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(saved, 'Neon Walrus');
  });

  testWidgets('cancelling returns null and disposes cleanly', (tester) async {
    String? saved = 'unset';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                saved = await promptForName(context, current: 'Silky Puffin');
              },
              child: const Text('Rename'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(saved, isNull);
  });
}
