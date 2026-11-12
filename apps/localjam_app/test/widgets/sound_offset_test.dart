/// Sound Offset (the §7 nudge) and Diagnostics: one clear control with its
/// value, a Reset, a footnote — and the sync figures as plain rows.
library;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/design/theme.dart';
import 'package:localjam_app/src/state/session_controller.dart';
import 'package:localjam_app/src/widgets/diagnostics_sheet.dart';
import 'package:localjam_app/src/widgets/nudge_slider.dart';
import 'package:localjam_app/src/widgets/sheet.dart';
import 'package:material_ui/material_ui.dart'
    show MaterialApp, Scaffold, TextButton, ThemeData;

import '../harness.dart';

Future<void> _pumpOpener(
  WidgetTester tester,
  JamSessionController session,
  void Function(BuildContext context) open, {
  ThemeData? theme,
}) async {
  await tester.pumpWidget(
    JamSession(
      controller: session,
      child: MaterialApp(
        theme: theme ?? jamLightTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => open(context),
              child: const Text('Go'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Go'));
  await tester.pumpAndSettle();
}

void main() {
  test('the value reads as a signed figure with a real minus', () {
    expect(JamNudgeStrings.value(0), '0 ms');
    expect(JamNudgeStrings.value(120), '+120 ms');
    expect(JamNudgeStrings.value(-40), '−40 ms');
  });

  testWidgets('the Sound Offset sheet: value, slider, Reset and a footnote', (
    tester,
  ) async {
    for (final theme in [jamLightTheme(), jamDarkTheme()]) {
      final session = testSession();
      await startTestHost(tester, session, 'Nudge Jam');
      final engine = session.engine!;
      await _pumpOpener(
        tester,
        session,
        (context) => showSoundOffsetSheet(context, engine),
        theme: theme,
      );

      expect(find.text(JamNudgeStrings.title), findsOneWidget);
      expect(find.text(JamNudgeStrings.value(0)), findsOneWidget);
      expect(find.text(JamNudgeStrings.noOffset), findsOneWidget);
      expect(find.text(JamNudgeStrings.footnote), findsOneWidget);
      expect(find.byType(CupertinoSlider), findsOneWidget);
      // The ends say which way is which.
      expect(find.text(JamNudgeStrings.later), findsOneWidget);
      expect(find.text(JamNudgeStrings.earlier), findsOneWidget);
      expect(
        tester.getCenter(find.text(JamNudgeStrings.later)).dx,
        lessThan(tester.getCenter(find.text(JamNudgeStrings.earlier)).dx),
      );
      // The header holds Done alone: Reset lives beside the caption, and
      // only while there is something to reset.
      final header = find.byType(JamSheetHeader);
      expect(
        find.descendant(of: header, matching: find.text(JamNudgeStrings.reset)),
        findsNothing,
      );
      final reset = find.text(JamNudgeStrings.reset);
      expect(reset.hitTestable(), findsNothing);

      // A step earlier: applied and shown at once.
      await tester.tap(find.bySemanticsLabel(JamNudgeStrings.earlier));
      await tester.runAsync(pumpEventQueue);
      await tester.pump();
      expect(engine.nudgeUs.value, 10000);
      expect(find.text(JamNudgeStrings.value(10)), findsOneWidget);
      expect(find.text(JamNudgeStrings.playsEarlier), findsOneWidget);

      // The engine moves it (a route change): the sheet follows.
      await tester.runAsync(() => engine.setNudgeUs(-120000));
      await tester.pump();
      expect(find.text(JamNudgeStrings.value(-120)), findsOneWidget);
      expect(find.text(JamNudgeStrings.playsLater), findsOneWidget);

      // Reset goes back to zero.
      await tester.pumpAndSettle();
      expect(reset.hitTestable(), findsOneWidget);
      await tester.tap(reset);
      await tester.runAsync(pumpEventQueue);
      await tester.pump();
      expect(engine.nudgeUs.value, 0);
      expect(find.text(JamNudgeStrings.value(0)), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.text(JamNudgeStrings.done));
      await tester.pumpAndSettle();
      expect(find.text(JamNudgeStrings.footnote), findsNothing);
      await leaveTestSession(tester, session);
    }
  });

  test('diagnostics durations read like numbers, not log lines', () {
    expect(formatDiagnosticsDuration(0), '0.0 ms');
    expect(formatDiagnosticsDuration(-20), '0.0 ms');
    expect(formatDiagnosticsDuration(3200), '+3.2 ms');
    expect(formatDiagnosticsDuration(-100), '−0.1 ms');
    expect(formatDiagnosticsDuration(-272391400), '−272.4 s');
    expect(formatDiagnosticsDuration(3600000000), '+3,600.0 s');
  });

  testWidgets('Diagnostics: plain rows, Sound Offset as a row that opens its '
      'sheet, and Copy confirms in place', (tester) async {
    final session = testSession();
    final heard = <String>[];
    final sub = session.notices.listen((n) => heard.add(n.message));
    addTearDown(sub.cancel);
    String? copied;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String?;
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );

    await startTestHost(tester, session, 'Diag Jam');
    final engine = session.engine!;
    await _pumpOpener(
      tester,
      session,
      (context) =>
          showDiagnosticsSheet(context, engine, clockOffsetUs: () => 3200),
    );

    expect(find.text(JamDiagnosticsStrings.title), findsOneWidget);
    expect(find.text(JamDiagnosticsStrings.clockOffset), findsOneWidget);
    expect(find.text('+3.2 ms'), findsOneWidget);
    expect(find.text(JamDiagnosticsStrings.drift), findsOneWidget);
    expect(find.text(JamDiagnosticsStrings.lastCorrection), findsOneWidget);
    // No uppercase labels.
    expect(find.text(JamDiagnosticsStrings.drift.toUpperCase()), findsNothing);

    // One home for Sound Offset: a read-only row here, no second slider.
    expect(find.byType(CupertinoSlider), findsNothing);
    expect(find.text(JamNudgeStrings.title), findsOneWidget);
    expect(find.text(JamNudgeStrings.value(0)), findsOneWidget);
    await tester.runAsync(() => engine.setNudgeUs(10000));
    await tester.pump();
    expect(find.text(JamNudgeStrings.value(10)), findsOneWidget);

    // Copy is in the content, not the header, and confirms itself.
    expect(
      find.descendant(
        of: find.byType(JamSheetHeader),
        matching: find.text(JamDiagnosticsStrings.copy),
      ),
      findsNothing,
    );
    await tester.tap(find.text(JamDiagnosticsStrings.copy));
    await tester.runAsync(pumpEventQueue);
    await tester.pump();
    expect(copied, contains('${JamDiagnosticsStrings.clockOffset}: +3.2 ms'));
    expect(copied, contains('${JamNudgeStrings.title}: +10 ms'));
    expect(find.text(JamDiagnosticsStrings.copied), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.checkmark), findsOneWidget);
    // No toast over the sheet.
    expect(heard, isEmpty);
    await tester.pump(const Duration(milliseconds: 1600));
    expect(find.text(JamDiagnosticsStrings.copy), findsOneWidget);
    expect(find.text(JamDiagnosticsStrings.copied), findsNothing);

    // The row opens the Sound Offset sheet, where the slider lives.
    await tester.tap(find.text(JamNudgeStrings.title));
    await tester.pumpAndSettle();
    expect(find.byType(CupertinoSlider), findsOneWidget);
    expect(find.text(JamNudgeStrings.footnote), findsOneWidget);

    await leaveTestSession(tester, session);
  });

  testWidgets(
    'a host has no clock offset, and no error row while all is well',
    (tester) async {
      final session = testSession();
      await startTestHost(tester, session, 'Diag Jam');
      final engine = session.engine!;
      await tester.pumpWidget(
        JamSession(
          controller: session,
          child: MaterialApp(
            theme: jamLightTheme(),
            home: Scaffold(body: DiagnosticsSheet(engine: engine)),
          ),
        ),
      );
      expect(find.text(JamDiagnosticsStrings.clockOffset), findsNothing);
      expect(find.text(JamDiagnosticsStrings.playerError), findsNothing);
      await leaveTestSession(tester, session);
    },
  );
}
