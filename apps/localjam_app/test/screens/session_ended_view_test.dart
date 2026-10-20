/// The page a jam ends on names the jam, says what happened to it, offers
/// the one next step that can work — a new code for a jam that restarted —
/// and keeps its mark in one place whatever the news.
library;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/design/theme.dart';
import 'package:localjam_app/src/screens/session_ended_view.dart';
import 'package:localjam_app/src/state/session_controller.dart';
import 'package:localjam_app/src/widgets/buttons.dart';
import 'package:localjam_app/src/widgets/jam_mark.dart';
import 'package:localjam_client/localjam_client.dart';

const _jam = 'Sunday at home';

Future<void> _pump(
  WidgetTester tester,
  JamSessionEndReason? reason, {
  RejectReason? rejectReason,
  String? jamName = _jam,
  VoidCallback? onDone,
  VoidCallback? onRetry,
  VoidCallback? onScan,
  bool retrying = false,
  String? error,
  ThemeData? theme,
}) => tester.pumpWidget(
  MaterialApp(
    theme: theme ?? jamLightTheme(),
    home: JamSessionEndedView(
      reason: reason,
      rejectReason: rejectReason,
      jamName: jamName,
      onDone: retrying ? null : (onDone ?? () {}),
      onRetry: onRetry,
      onScan: onScan,
      retrying: retrying,
      error: error,
    ),
  ),
);

JamButton _button(WidgetTester tester, String label) =>
    tester.widget<JamButton>(
      find.ancestor(of: find.text(label), matching: find.byType(JamButton)),
    );

void main() {
  testWidgets('a named jam is drawn by its mark and named in the copy', (
    tester,
  ) async {
    await _pump(tester, JamSessionEndReason.hostEnded);
    final mark = tester.widget<JamMark>(find.byType(JamMark));
    expect(mark.name, _jam);
    expect(mark.size, JamMarkSize.ended);
    expect(find.text(JamSessionEndedStrings.hostEndedTitle), findsOneWidget);
    // Which jam, and where it went.
    expect(find.text(JamSessionEndedStrings.hostEnded(_jam)), findsOneWidget);
    expect(JamSessionEndedStrings.hostEnded(_jam), contains('Past Jams'));
  });

  testWidgets('a jam with no name keeps a glyph for the reason', (
    tester,
  ) async {
    await _pump(
      tester,
      JamSessionEndReason.hostGone,
      jamName: null,
      onRetry: () {},
    );
    expect(find.byType(JamMark), findsNothing);
    expect(find.byIcon(CupertinoIcons.wifi_slash), findsOneWidget);
    expect(find.text(JamSessionEndedStrings.hostGoneBody), findsOneWidget);
  });

  testWidgets('a jam that restarted offers its new code first', (tester) async {
    await _pump(
      tester,
      JamSessionEndReason.rejected,
      rejectReason: RejectReason.badToken,
      onRetry: () {},
      onScan: () {},
    );
    expect(find.text(JamSessionEndedStrings.restartedTitle), findsOneWidget);
    expect(find.text(JamSessionEndedStrings.restarted(_jam)), findsOneWidget);
    // The old link can never work: no "Try Again".
    expect(find.text(JamSessionEndedStrings.tryAgain), findsNothing);
    expect(
      _button(tester, JamSessionEndedStrings.newCode).variant,
      JamButtonVariant.filled,
    );
    expect(
      _button(tester, JamSessionEndedStrings.back).variant,
      JamButtonVariant.plain,
    );
  });

  testWidgets('without a way to scan, a restarted jam still has a way home', (
    tester,
  ) async {
    await _pump(
      tester,
      JamSessionEndReason.rejected,
      rejectReason: RejectReason.badToken,
    );
    expect(find.text(JamSessionEndedStrings.newCode), findsNothing);
    expect(
      _button(tester, JamSessionEndedStrings.back).variant,
      JamButtonVariant.gray,
    );
  });

  testWidgets('turned away for no known reason: try again, a new code, or '
      'home', (tester) async {
    var scanned = 0;
    await _pump(
      tester,
      JamSessionEndReason.rejected,
      rejectReason: RejectReason.unknown,
      onRetry: () {},
      onScan: () => scanned++,
    );
    expect(
      _button(tester, JamSessionEndedStrings.tryAgain).variant,
      JamButtonVariant.filled,
    );
    expect(
      _button(tester, JamSessionEndedStrings.newCode).variant,
      JamButtonVariant.plain,
    );
    // Home never goes missing.
    expect(
      _button(tester, JamSessionEndedStrings.back).variant,
      JamButtonVariant.plain,
    );
    await tester.tap(find.text(JamSessionEndedStrings.newCode));
    expect(scanned, 1);
  });

  testWidgets('a new code is not offered where it cannot help', (tester) async {
    for (final (reason, reject) in [
      (JamSessionEndReason.hostGone, null),
      (JamSessionEndReason.hostEnded, null),
      (JamSessionEndReason.kicked, null),
      (JamSessionEndReason.rejected, RejectReason.full),
      (JamSessionEndReason.rejected, RejectReason.version),
    ]) {
      await _pump(
        tester,
        reason,
        rejectReason: reject,
        onRetry: () {},
        onScan: () {},
      );
      expect(
        find.text(JamSessionEndedStrings.newCode),
        findsNothing,
        reason: '$reason $reject',
      );
    }
  });

  testWidgets('a retry in flight says so in words', (tester) async {
    await _pump(
      tester,
      JamSessionEndReason.rejected,
      rejectReason: RejectReason.unknown,
      onRetry: () {},
      onScan: () {},
      retrying: true,
    );
    expect(find.text(JamSessionEndedStrings.retrying(_jam)), findsOneWidget);
    expect(_button(tester, JamSessionEndedStrings.tryAgain).loading, isTrue);
    // Nothing else to start while it runs.
    expect(find.text(JamSessionEndedStrings.newCode), findsNothing);
    expect(find.text(JamSessionEndedStrings.back), findsNothing);
  });

  testWidgets('a retry that failed says so, and what is left to check', (
    tester,
  ) async {
    // No answer at all: the jam is named, and the one thing left to check.
    await _pump(
      tester,
      JamSessionEndReason.hostGone,
      onRetry: () {},
      error: kJamRejoinFailed,
    );
    expect(
      find.text(JamSessionEndedStrings.stillUnreachable(_jam)),
      findsOneWidget,
    );
    // The host answered no: its answer is the title now, and the reason's
    // own sentence says what to do — not a bare "couldn't get back in".
    await _pump(
      tester,
      JamSessionEndReason.rejected,
      rejectReason: RejectReason.full,
      onRetry: () {},
      error: kJamRejoinFailed,
    );
    expect(find.text(JamSessionEndedStrings.full(_jam)), findsOneWidget);
    expect(find.text(kJamRejoinFailed), findsNothing);
    // The controller's own, specific account is kept as it is.
    const specific =
        'Couldn’t reach that jam. Check you’re both on the same '
        'network or hotspot.';
    await _pump(
      tester,
      JamSessionEndReason.hostGone,
      onRetry: () {},
      error: specific,
    );
    expect(find.text(specific), findsOneWidget);
  });

  testWidgets('the mark stays put whatever the news', (tester) async {
    tester.view.physicalSize = const Size(402, 874) * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    Future<Offset> markAt(
      JamSessionEndReason reason, {
      RejectReason? reject,
      bool retrying = false,
      String? error,
    }) async {
      await _pump(
        tester,
        reason,
        rejectReason: reject,
        onRetry: () {},
        onScan: () {},
        retrying: retrying,
        error: error,
      );
      return tester.getTopLeft(find.byType(JamMark));
    }

    final gone = await markAt(JamSessionEndReason.hostGone);
    expect(await markAt(JamSessionEndReason.hostGone, retrying: true), gone);
    expect(
      await markAt(JamSessionEndReason.hostGone, error: kJamRejoinFailed),
      gone,
    );
    // One action, or three.
    expect(await markAt(JamSessionEndReason.kicked), gone);
    expect(
      await markAt(JamSessionEndReason.rejected, reject: RejectReason.unknown),
      gone,
    );
  });

  testWidgets('renders on the dark palette', (tester) async {
    await _pump(
      tester,
      JamSessionEndReason.rejected,
      rejectReason: RejectReason.unknown,
      onRetry: () {},
      onScan: () {},
      theme: jamDarkTheme(),
    );
    expect(tester.takeException(), isNull);
    expect(find.text(JamSessionEndedStrings.rejectedTitle), findsOneWidget);
  });
}
