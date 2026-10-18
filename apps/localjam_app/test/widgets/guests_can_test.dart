/// The presets' words, shared by Start a Jam and the People sheet.
library;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/design/theme.dart';
import 'package:localjam_app/src/widgets/guests_can.dart';
import 'package:localjam_client/localjam_client.dart';

void main() {
  test('one name and one description per preset, Custom past them', () {
    expect(JamPresetStrings.name(JamPolicy.open), 'Everything');
    expect(JamPresetStrings.name(JamPolicy.jam), 'Add Music');
    expect(JamPresetStrings.name(JamPolicy.listenOnly), 'Listen Only');
    final custom = JamPolicy.jam.copyWith(
      controlPlayback: true,
      editQueue: false,
    );
    expect(JamPresetStrings.name(custom), JamPresetStrings.custom);
    expect(JamPresetStrings.detail(custom), isNull);
    for (final preset in kJamPresets) {
      expect(JamPresetStrings.detail(preset), isNotNull);
    }
    expect(kJamPresets, [JamPolicy.open, JamPolicy.jam, JamPolicy.listenOnly]);
  });

  test('the summary says what guests can do in one sentence', () {
    expect(
      JamPresetStrings.summary(JamPolicy.open),
      'Everyone can add music, play, pause and skip and edit the queue.',
    );
    expect(
      JamPresetStrings.summary(JamPolicy.jam),
      'Everyone can add music and edit the queue.',
    );
    expect(
      JamPresetStrings.summary(JamPolicy.listenOnly),
      'The host runs this jam. Everyone else listens along.',
    );
  });

  testWidgets('the row shows the preset and its pull-down picks another', (
    tester,
  ) async {
    var policy = JamPolicy.jam;
    await tester.pumpWidget(
      MaterialApp(
        theme: jamLightTheme(),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => JamGuestsCanRow(
              policy: policy,
              onChanged: (p) => setState(() => policy = p),
            ),
          ),
        ),
      ),
    );
    expect(find.text('Add Music'), findsOneWidget);
    await tester.tap(find.text(JamPresetStrings.guestsCan));
    await tester.pumpAndSettle();
    final items = tester
        .widgetList<CupertinoMenuItem>(find.byType(CupertinoMenuItem))
        .toList();
    expect(items, hasLength(3));
    await tester.tap(find.text('Everything'));
    await tester.pumpAndSettle();
    expect(policy, JamPolicy.open);
    expect(find.text('Everything'), findsOneWidget);
  });
}
