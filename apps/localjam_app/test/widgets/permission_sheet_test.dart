/// The rationale sheet, and the rule that a dismissal is not consent.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/design/theme.dart';
import 'package:localjam_app/src/util/permissions.dart';
import 'package:localjam_app/src/widgets/permission_sheet.dart';

Widget _host(Future<void> Function(BuildContext) onTap, {ThemeData? theme}) =>
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
  test('the rationales are the copy from permissions.dart', () {
    expect(
      JamPermissionRationale.localNetwork.title,
      JamPermissionCopy.localNetworkTitle,
    );
    expect(
      JamPermissionRationale.localNetwork.body,
      JamPermissionCopy.localNetworkDetail,
    );
    expect(
      JamPermissionRationale.notifications.title,
      JamPermissionCopy.notificationsTitle,
    );
    expect(
      JamPermissionRationale.audioLibrary.body,
      JamPermissionCopy.audioLibraryDetail,
    );
  });

  testWidgets('shows the ask, the promise, and both actions', (tester) async {
    await tester.pumpWidget(
      _host(
        (context) => showJamPermissionSheet(
          context,
          JamPermissionRationale.localNetwork,
        ),
      ),
    );
    await tester.tap(find.text('Go'));
    await tester.pumpAndSettle();

    expect(find.text(JamPermissionCopy.localNetworkTitle), findsOneWidget);
    expect(find.text(JamPermissionCopy.localNetworkDetail), findsOneWidget);
    expect(
      find.text(JamPermissionSheetStrings.doesHeading.toUpperCase()),
      findsOneWidget,
    );
    expect(
      find.text(JamPermissionSheetStrings.neverHeading.toUpperCase()),
      findsOneWidget,
    );
    expect(find.text(JamPermissionSheetStrings.continueLabel), findsOneWidget);
    expect(find.text(JamPermissionSheetStrings.dismissLabel), findsOneWidget);
  });

  testWidgets('Continue resolves true', (tester) async {
    bool? answer;
    await tester.pumpWidget(
      _host(
        (context) async => answer = await showJamPermissionSheet(
          context,
          JamPermissionRationale.audioLibrary,
        ),
      ),
    );
    await tester.tap(find.text('Go'));
    await tester.pumpAndSettle();

    await tester.tap(find.text(JamPermissionSheetStrings.continueLabel));
    await tester.pumpAndSettle();
    expect(answer, isTrue);
  });

  testWidgets('Not now resolves false', (tester) async {
    bool? answer;
    await tester.pumpWidget(
      _host(
        (context) async => answer = await showJamPermissionSheet(
          context,
          JamPermissionRationale.camera,
        ),
      ),
    );
    await tester.tap(find.text('Go'));
    await tester.pumpAndSettle();

    await tester.tap(find.text(JamPermissionSheetStrings.dismissLabel));
    await tester.pumpAndSettle();
    expect(answer, isFalse);
  });

  testWidgets('a swiped-away sheet is not consent', (tester) async {
    bool? answer;
    await tester.pumpWidget(
      _host(
        (context) async => answer = await showJamPermissionSheet(
          context,
          JamPermissionRationale.notifications,
        ),
      ),
    );
    await tester.tap(find.text('Go'));
    await tester.pumpAndSettle();

    await tester.tapAt(const Offset(10, 10)); // the barrier
    await tester.pumpAndSettle();
    expect(answer, isFalse);
  });

  testWidgets('reads the bullets out as heading plus promise', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        theme: jamLightTheme(),
        home: const Scaffold(
          body: JamPermissionSheet(
            rationale: JamPermissionRationale.localNetwork,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.bySemanticsLabel(
        '${JamPermissionSheetStrings.neverHeading}: '
        '${JamPermissionRationale.localNetwork.neverBullet}',
      ),
      findsOneWidget,
    );
    handle.dispose();
  });

  testWidgets('renders on the dark palette', (tester) async {
    await tester.pumpWidget(
      _host(
        (context) =>
            showJamPermissionSheet(context, JamPermissionRationale.camera),
        theme: jamDarkTheme(),
      ),
    );
    await tester.tap(find.text('Go'));
    await tester.pumpAndSettle();

    expect(find.text(JamPermissionSheetStrings.cameraTitle), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
