/// Sound Offset (the §7 nudge) and Diagnostics: one clear control with its
/// value, a Reset, a footnote — and the sync figures as plain rows.
library;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart'
    show MaterialApp, Scaffold, TextButton, ThemeData;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/design/theme.dart';
import 'package:localjam_app/src/state/session_controller.dart';
import 'package:localjam_app/src/widgets/diagnostics_sheet.dart';
import 'package:localjam_app/src/widgets/nudge_slider.dart';

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
      // Nothing to reset yet.
      final reset = find.text(JamNudgeStrings.reset);
      expect(reset, findsOneWidget);

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

  testWidgets('Diagnostics: plain rows, the nudge still works there, and '
      'Copy copies', (tester) async {
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

    // The nudge, working in place.
    expect(find.text(JamNudgeStrings.title), findsOneWidget);
    await tester.tap(find.bySemanticsLabel(JamNudgeStrings.earlier));
    await tester.runAsync(pumpEventQueue);
    await tester.pump();
    expect(engine.nudgeUs.value, 10000);

    await tester.tap(find.text(JamDiagnosticsStrings.copy));
    await tester.runAsync(pumpEventQueue);
    await tester.pump();
    expect(copied, contains('${JamDiagnosticsStrings.clockOffset}: +3.2 ms'));
    expect(copied, contains('${JamNudgeStrings.title}: +10 ms'));
    expect(heard, contains(JamDiagnosticsStrings.copied));

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
