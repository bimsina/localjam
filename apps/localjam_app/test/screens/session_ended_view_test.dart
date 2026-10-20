/// The page a jam ends on names the jam, says what happened to it, offers
/// the one next step that can work — a new code for a jam that restarted —
/// and keeps its mark in one place whatever the news.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/design/theme.dart';
import 'package:localjam_app/src/screens/history_screen.dart';
import 'package:localjam_app/src/screens/session_ended_view.dart';
import 'package:localjam_app/src/state/session_controller.dart';
import 'package:localjam_app/src/widgets/buttons.dart';
import 'package:localjam_app/src/widgets/jam_mark.dart';
import 'package:localjam_app/src/widgets/wifi_glyph.dart';
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
      onDone: onDone ?? () {},
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
    expect(
      JamSessionEndedStrings.hostEnded(_jam),
      contains(HistoryStrings.title),
    );
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
    // The outline Wi‑Fi slash, bare: a glyph in the mark's square would
    // pose as a jam.
    final glyph = tester.widget<JamWifiGlyph>(find.byType(JamWifiGlyph));
    expect(glyph.slashed, isTrue);
    expect(
      find.ancestor(
        of: find.byType(JamWifiGlyph),
        matching: find.descendant(
          of: find.byType(JamSessionEndedView),
          matching: find.byType(DecoratedBox),
        ),
      ),
      findsNothing,
    );
    expect(find.text(JamSessionEndedStrings.hostGoneBody), findsOneWidget);
  });

  testWidgets('named or not, the title sits at one height', (tester) async {
    await _pump(tester, JamSessionEndReason.hostGone, onRetry: () {});
    final named = tester.getTopLeft(
      find.text(JamSessionEndedStrings.hostGoneTitle),
    );
    await _pump(
      tester,
      JamSessionEndReason.hostGone,
      jamName: null,
      onRetry: () {},
    );
    final unnamed = tester.getTopLeft(
      find.text(JamSessionEndedStrings.hostGoneTitle),
    );
    expect(unnamed.dy, named.dy);
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
    // The button under it is the way back: the sentence says only why.
    expect(
      find.text(JamSessionEndedStrings.restarted(_jam, offersCode: true)),
      findsOneWidget,
    );
    expect(find.textContaining('Ask the host'), findsNothing);
    // The old link can never work: no "Try again".
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
    // With no button for it, the copy says where the new code comes from.
    expect(find.text(JamSessionEndedStrings.restarted(_jam)), findsOneWidget);
    expect(JamSessionEndedStrings.restarted(_jam), contains('Ask the host'));
    await _pump(
      tester,
      JamSessionEndReason.rejected,
      rejectReason: RejectReason.badToken,
      jamName: null,
    );
    expect(find.text(JamSessionEndedStrings.restartedBody), findsOneWidget);
  });

  testWidgets('turned away for no known reason: no scanner, and the '
      'sentence says where a new code comes from', (tester) async {
    await _pump(
      tester,
      JamSessionEndReason.rejected,
      rejectReason: RejectReason.unknown,
      onScan: () {},
    );
    expect(find.text(JamSessionEndedStrings.rejected(_jam)), findsOneWidget);
    expect(find.textContaining('ask the host'), findsOneWidget);
    expect(find.text(JamSessionEndedStrings.newCode), findsNothing);
  });

  testWidgets('a restarted jam with its new code on offer: the reason, and '
      'no "ask the host"', (tester) async {
    await _pump(
      tester,
      JamSessionEndReason.rejected,
      rejectReason: RejectReason.badToken,
      jamName: null,
      onScan: () {},
    );
    expect(
      find.text(JamSessionEndedStrings.restarted(null, offersCode: true)),
      findsOneWidget,
    );
    expect(find.textContaining('Ask the host'), findsNothing);
  });

  testWidgets('turned away for no known reason: Try again, and home as the '
      'one plain second', (tester) async {
    await _pump(
      tester,
      JamSessionEndReason.rejected,
      rejectReason: RejectReason.unknown,
      onRetry: () {},
      onScan: () {},
    );
    expect(
      _button(tester, JamSessionEndedStrings.tryAgain).variant,
      JamButtonVariant.filled,
    );
    // Home never goes missing.
    expect(
      _button(tester, JamSessionEndedStrings.back).variant,
      JamButtonVariant.plain,
    );
    // At most one action plus a plain second: no scanner between them.
    expect(find.text(JamSessionEndedStrings.newCode), findsNothing);
    expect(find.byType(JamButton), findsNWidgets(2));
  });

  test('the scanner is called what it is called everywhere', () {
    expect(JamSessionEndedStrings.scanCode, 'Scan code');
    expect(JamSessionEndedStrings.joinWithLink, 'Join with link');
    expect(
      JamSessionEndedStrings.newCode,
      anyOf(
        JamSessionEndedStrings.scanCode,
        JamSessionEndedStrings.joinWithLink,
      ),
    );
  });

  testWidgets('a new code is not offered where it cannot help', (tester) async {
    for (final (reason, reject) in [
      (JamSessionEndReason.hostGone, null),
      (JamSessionEndReason.hostEnded, null),
      (JamSessionEndReason.kicked, null),
      (JamSessionEndReason.rejected, RejectReason.full),
      (JamSessionEndReason.rejected, RejectReason.version),
      (JamSessionEndReason.rejected, RejectReason.unknown),
      (JamSessionEndReason.rejected, null),
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
    // The button says so too, in place: a ring beside "Trying…".
    final trying = _button(tester, JamSessionEndedStrings.trying);
    expect(trying.loading, isTrue);
    expect(trying.loadingLabel, JamSessionEndedStrings.trying);
    // The way home stays on the page, so it neither shrinks nor loses its
    // way home, and home still works (it gives the retry up).
    expect(_button(tester, JamSessionEndedStrings.back).onPressed, isNotNull);
  });

  testWidgets('a retry keeps every action, in its place under the first', (
    tester,
  ) async {
    // The sentence above changes length; the stack under the primary does
    // not shrink.
    Future<Map<String, double>> actions({required bool retrying}) async {
      await _pump(
        tester,
        JamSessionEndReason.rejected,
        rejectReason: RejectReason.unknown,
        onRetry: () {},
        onScan: () {},
        retrying: retrying,
      );
      Offset at(String label) => tester.getTopLeft(
        find.ancestor(of: find.text(label), matching: find.byType(JamButton)),
      );
      final primary = at(
        retrying
            ? JamSessionEndedStrings.trying
            : JamSessionEndedStrings.tryAgain,
      );
      return {
        for (final label in [JamSessionEndedStrings.back])
          label: at(label).dy - primary.dy,
      };
    }

    final before = await actions(retrying: false);
    final during = await actions(retrying: true);
    expect(during, before);
  });

  testWidgets('a room that can let you leave mid-retry gets Back to Nearby '
      'on', (tester) async {
    var left = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: jamLightTheme(),
        home: JamSessionEndedView(
          reason: JamSessionEndReason.hostGone,
          jamName: _jam,
          onDone: () => left++,
          onRetry: () {},
          retrying: true,
        ),
      ),
    );
    await tester.tap(find.text(JamSessionEndedStrings.back));
    expect(left, 1);
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
