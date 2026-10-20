/// The scanner's dead ends, which are the part of it a widget test can hold:
/// there is no camera under `flutter_test`, and the whole point of these
/// states is that the screen still works when there is no camera anywhere.
library;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/design/theme.dart';
import 'package:localjam_app/src/design/tokens.dart';
import 'package:localjam_app/src/screens/scan_screen.dart';
import 'package:localjam_app/src/util/permissions.dart';
import 'package:localjam_app/src/widgets/buttons.dart';
import 'package:localjam_app/src/widgets/empty_state.dart';
import 'package:localjam_app/src/widgets/join_link_dialog.dart';
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
    expect(find.text(JamScanStrings.openSettings), findsOneWidget);
    expect(find.text(JamScanStrings.joinWithLink), findsOneWidget);
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
    expect(find.text(JamScanStrings.openSettings), findsNothing);
    // Asking again is what actually works here, and the link is still there.
    expect(find.text(JamScanStrings.retry), findsOneWidget);
    expect(find.text(JamScanStrings.joinWithLink), findsOneWidget);

    await tester.tap(find.text(JamScanStrings.retry));
    await tester.pumpAndSettle();
    expect(retried, 1);
  });

  testWidgets('a device with no scanner offers only the link', (tester) async {
    await pumpUnavailable(tester, MobileScannerErrorCode.unsupported);

    expect(find.text(JamScanStrings.unsupportedTitle), findsOneWidget);
    // Nothing in Settings can grow this phone a QR decoder.
    expect(find.text(JamScanStrings.openSettings), findsNothing);
    expect(find.text(JamScanStrings.joinWithLink), findsOneWidget);
  });

  testWidgets('a camera that would not start says so, not "denied"', (
    tester,
  ) async {
    await pumpUnavailable(tester, MobileScannerErrorCode.genericError);

    expect(find.text(JamScanStrings.failedTitle), findsOneWidget);
    expect(find.text(JamScanStrings.joinWithLink), findsOneWidget);
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
    expect(find.text(JamScanStrings.joinWithLink), findsOneWidget);
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

    await tester.tap(find.text(JamScanStrings.joinWithLink));
    await tester.pumpAndSettle();
    expect(asked, 1);
  });

  testWidgets('Enter Link sits right under the message, on every dead end', (
    tester,
  ) async {
    // It used to be a bare caption pinned 300 pt below at the bottom, where
    // the live scanner keeps it — on a page with no scanner, the eye
    // stopped at the message and never reached it.
    for (final (code, declined) in [
      (MobileScannerErrorCode.permissionDenied, false),
      (MobileScannerErrorCode.permissionDenied, true),
      (MobileScannerErrorCode.unsupported, false),
      (MobileScannerErrorCode.genericError, false),
    ]) {
      await pumpUnavailable(tester, code, declined: declined, onRetry: () {});
      expect(find.text(JamScanStrings.joinWithLink), findsOneWidget);
      final state = tester.getRect(find.byType(JamEmptyState));
      final link = tester.getRect(find.text(JamScanStrings.joinWithLink));
      expect(state.contains(link.center), isTrue, reason: '$code $declined');
    }
  });

  testWidgets('with no fix to offer, Enter Link is the button', (tester) async {
    await pumpUnavailable(tester, MobileScannerErrorCode.unsupported);
    final empty = tester.widget<JamEmptyState>(find.byType(JamEmptyState));
    expect(empty.actionLabel, JamScanStrings.joinWithLink);
    expect(empty.actionVariant, JamButtonVariant.gray);
    expect(empty.secondaryActionLabel, isNull);
  });

  testWidgets('with a fix, the fix is the button and the link sits under it', (
    tester,
  ) async {
    await pumpUnavailable(tester, MobileScannerErrorCode.permissionDenied);
    final empty = tester.widget<JamEmptyState>(find.byType(JamEmptyState));
    expect(empty.actionLabel, JamScanStrings.openSettings);
    expect(empty.secondaryActionLabel, JamScanStrings.joinWithLink);
  });

  testWidgets('Join with Link from the scanner is on the dark palette, '
      'whatever the app appearance', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: jamLightTheme(),
        home: Builder(
          builder: (context) => Center(
            child: GestureDetector(
              onTap: () =>
                  promptForJoinLink(context, brightness: Brightness.dark),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final dialog = find.byType(JoinLinkDialog);
    expect(dialog, findsOneWidget);
    expect(Theme.of(tester.element(dialog)).brightness, Brightness.dark);
    expect(
      CupertinoTheme.brightnessOf(tester.element(dialog)),
      Brightness.dark,
    );
  });

  test('the viewfinder is ~70% of the short side, held on big screens', () {
    expect(scanWindowFor(const Size(400, 860)), closeTo(280, 0.01));
    expect(scanWindowFor(const Size(1440, 900)), kScanWindowMax);
    expect(kScanWindowRadius, 24);
  });

  testWidgets('the dead end is the app’s dark ground, with the xmark', (
    tester,
  ) async {
    var closed = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: jamLightTheme(),
        home: Scaffold(
          body: ScannerUnavailableView(
            error: const MobileScannerException(
              errorCode: MobileScannerErrorCode.permissionDenied,
            ),
            onLink: () async {},
            onClose: () => closed++,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Dark whatever the app's appearance — but LocalJam's warm charcoal,
    // not camera black: there is no feed here to frame.
    final ground = tester.widget<ColoredBox>(
      find
          .descendant(
            of: find.byType(ScannerUnavailableView),
            matching: find.byType(ColoredBox),
          )
          .first,
    );
    expect(ground.color, JamColors.dark.background);
    // Open Settings is a neutral button with a white label — a tinted fill
    // on the dark ground read as a disabled maroon slab — and it hugs its
    // label.
    final settings = tester.widget<JamButton>(
      find.widgetWithText(JamButton, JamScanStrings.openSettings),
    );
    expect(settings.variant, JamButtonVariant.gray);
    expect(settings.color, const Color(0xFFFFFFFF));
    expect(settings.expand, isFalse);
    final width = tester
        .getSize(find.widgetWithText(JamButton, JamScanStrings.openSettings))
        .width;
    expect(width, inInclusiveRange(140, 300));

    // The xmark in the trailing corner, where a sheet's own close sits.
    final close = tester.getRect(find.bySemanticsLabel(JamScanStrings.close));
    final page = tester.getRect(find.byType(ScannerUnavailableView));
    expect(close.center.dx, greaterThan(page.center.dx));
    await tester.tap(find.bySemanticsLabel(JamScanStrings.close));
    await tester.pumpAndSettle();
    expect(closed, 1);
  });

  testWidgets('every dead end puts its glyph and title at one height', (
    tester,
  ) async {
    // Centred, the block moved with the length of its sentence and the
    // number of its actions; anchored, it does not move at all.
    final tops = <double>{};
    final titles = <double>{};
    for (final (code, declined) in [
      (MobileScannerErrorCode.permissionDenied, false),
      (MobileScannerErrorCode.permissionDenied, true),
      (MobileScannerErrorCode.unsupported, false),
      (MobileScannerErrorCode.genericError, false),
    ]) {
      await pumpUnavailable(tester, code, declined: declined, onRetry: () {});
      final state = find.byType(JamEmptyState);
      tops.add(
        tester
            .getTopLeft(
              find.descendant(of: state, matching: find.byType(Icon)).first,
            )
            .dy,
      );
      titles.add(
        tester
            .getTopLeft(
              find.descendant(of: state, matching: find.byType(Text)).first,
            )
            .dy,
      );
    }
    expect(tops, hasLength(1));
    expect(titles, hasLength(1));
  });
}
