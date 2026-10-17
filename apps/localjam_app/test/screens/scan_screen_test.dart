/// The scanner's dead ends, which are the part of it a widget test can hold:
/// there is no camera under `flutter_test`, and the whole point of these
/// states is that the screen still works when there is no camera anywhere.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/design/theme.dart';
import 'package:localjam_app/src/screens/scan_screen.dart';
import 'package:localjam_app/src/util/permissions.dart';
import 'package:localjam_app/src/widgets/empty_state.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

Future<void> pumpUnavailable(
  WidgetTester tester,
  MobileScannerErrorCode code, {
  ThemeData? theme,
  VoidCallback? onRetry,
  bool declined = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: theme ?? jamLightTheme(),
      home: Scaffold(
        body: ScannerUnavailableView(
          error: MobileScannerException(errorCode: code),
          onLink: () async {},
          onRetry: onRetry,
          declined: declined,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a denial sends you to Settings and still lets you paste', (
    tester,
  ) async {
    await pumpUnavailable(tester, MobileScannerErrorCode.permissionDenied);

    expect(find.byType(JamEmptyState), findsOneWidget);
    expect(find.text(JamScanStrings.deniedTitle), findsOneWidget);
    expect(find.text(JamPermissionCopy.cameraDenied), findsOneWidget);
    // One primary — Settings is the thing that fixes it — and the link
    // field stays reachable underneath rather than competing with it.
    expect(find.text(JamPermissionCopy.openSettings), findsOneWidget);
    expect(find.text(JamScanStrings.enterLink), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('backing out of the rationale is not a denial', (tester) async {
    // The OS was never asked, so nothing in Settings is switched off. Sending
    // this user to "turn on camera access in Settings" points them at a
    // switch that is already where it should be.
    var retried = 0;
    await pumpUnavailable(
      tester,
      MobileScannerErrorCode.permissionDenied,
      declined: true,
      onRetry: () => retried++,
    );

    expect(find.text(JamScanStrings.declinedTitle), findsOneWidget);
    expect(find.text(JamScanStrings.deniedTitle), findsNothing);
    expect(find.text(JamPermissionCopy.openSettings), findsNothing);
    // Asking again is what actually works here, and the link is still there.
    expect(find.text(JamScanStrings.retry), findsOneWidget);
    expect(find.text(JamScanStrings.enterLink), findsOneWidget);

    await tester.tap(find.text(JamScanStrings.retry));
    await tester.pumpAndSettle();
    expect(retried, 1);
  });

  testWidgets('a device with no scanner offers only the link', (tester) async {
    await pumpUnavailable(tester, MobileScannerErrorCode.unsupported);

    expect(find.text(JamScanStrings.unsupportedTitle), findsOneWidget);
    // Nothing in Settings can grow this phone a QR decoder.
    expect(find.text(JamPermissionCopy.openSettings), findsNothing);
    expect(find.text(JamScanStrings.enterLink), findsOneWidget);
  });

  testWidgets('a camera that would not start says so, not "denied"', (
    tester,
  ) async {
    await pumpUnavailable(tester, MobileScannerErrorCode.genericError);

    expect(find.text(JamScanStrings.failedTitle), findsOneWidget);
    expect(find.text(JamScanStrings.enterLink), findsOneWidget);
  });

  testWidgets('a camera that would not start can simply be tried again', (
    tester,
  ) async {
    // Something else had the camera, or the vision stack failed once. That
    // is a dead end you can walk back out of, and until now the only way out
    // was to close the screen and come back.
    var retried = 0;
    await pumpUnavailable(
      tester,
      MobileScannerErrorCode.genericError,
      onRetry: () => retried++,
    );

    await tester.tap(find.text(JamScanStrings.retry));
    await tester.pumpAndSettle();
    expect(retried, 1);
    // The link is still there underneath, just no longer the loudest thing.
    expect(find.text(JamScanStrings.enterLink), findsOneWidget);
  });

  testWidgets('nothing offers to retry what a retry cannot fix', (
    tester,
  ) async {
    // A denial needs Settings and a device with no camera needs a different
    // phone; "Try again" on either is a button that does nothing.
    await pumpUnavailable(
      tester,
      MobileScannerErrorCode.permissionDenied,
      onRetry: () {},
    );
    expect(find.text(JamScanStrings.retry), findsNothing);

    await pumpUnavailable(
      tester,
      MobileScannerErrorCode.unsupported,
      onRetry: () {},
    );
    expect(find.text(JamScanStrings.retry), findsNothing);
  });

  testWidgets('the dead end renders on the dark palette', (tester) async {
    await pumpUnavailable(
      tester,
      MobileScannerErrorCode.permissionDenied,
      theme: jamDarkTheme(),
    );

    expect(find.text(JamScanStrings.deniedTitle), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the link is the way through from every dead end', (
    tester,
  ) async {
    var asked = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: jamLightTheme(),
        home: Scaffold(
          body: ScannerUnavailableView(
            error: const MobileScannerException(
              errorCode: MobileScannerErrorCode.unsupported,
            ),
            onLink: () async => asked++,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text(JamScanStrings.enterLink));
    await tester.pumpAndSettle();
    expect(asked, 1);
  });

  test('the aiming window is the 260 dp square the spec asks for', () {
    expect(kScanWindow, 260);
  });
}
