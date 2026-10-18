/// The presets' words, shared by Start a Jam and the People sheet.
library;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/design/theme.dart';
import 'package:localjam_app/src/widgets/guests_can.dart';
import 'package:localjam_app/src/widgets/list.dart';
import 'package:localjam_app/src/widgets/section.dart';
import 'package:localjam_client/localjam_client.dart';

void main() {
  test('one name and one description per preset, Custom past them', () {
    expect(JamPresetStrings.name(JamPolicy.open), 'Everything');
    expect(JamPresetStrings.name(JamPolicy.jam), 'Songs & Queue');
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

  test('no preset is called what a capability is called', () {
    // A preset named like the switch under it ("Add Music" over "Add
    // Music") reads as the same control twice.
    const capabilities = [
      JamPresetStrings.addSongs,
      JamPresetStrings.controlPlayback,
      JamPresetStrings.editQueue,
    ];
    for (final preset in kJamPresets) {
      expect(capabilities, isNot(contains(JamPresetStrings.name(preset))));
    }
    expect(capabilities, isNot(contains(JamPresetStrings.custom)));
  });

  test('the summary says what guests can do in the switches\' words', () {
    expect(
      JamPresetStrings.summary(JamPolicy.open),
      'Guests can add songs, control playback and edit the queue.',
    );
    expect(
      JamPresetStrings.summary(JamPolicy.jam),
      'Guests can add songs and edit the queue.',
    );
    expect(
      JamPresetStrings.summary(JamPolicy.listenOnly),
      'Only the host adds songs and controls playback.',
    );
    expect(
      JamPresetStrings.summary(
        JamPolicy.listenOnly.copyWith(controlPlayback: true),
      ),
      'Guests can control playback.',
    );
    // The descriptions use the same words as the footer.
    expect(
      JamPresetStrings.everythingDetail.toLowerCase(),
      contains('control playback'),
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
    expect(find.text('Songs & Queue'), findsOneWidget);
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

  group('the pull-down hangs from the value, clear of the switches', () {
    Future<void> pumpRow(WidgetTester tester, {required double top}) async {
      await tester.binding.setSurfaceSize(const Size(400, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: jamLightTheme(),
          home: Scaffold(
            body: Padding(
              padding: EdgeInsets.only(top: top),
              child: Align(
                alignment: Alignment.topCenter,
                child: JamSection(
                  children: [
                    JamGuestsCanRow(
                      policy: JamPolicy.jam,
                      onChanged: (_) {},
                      controls: [
                        for (final title in const [
                          JamPresetStrings.addSongs,
                          JamPresetStrings.controlPlayback,
                          JamPresetStrings.editQueue,
                        ])
                          JamRow.toggle(
                            title: title,
                            value: true,
                            onChanged: (_) {},
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text(JamPresetStrings.guestsCan));
      await tester.pumpAndSettle();
    }

    Rect menuRect(WidgetTester tester) {
      final items = find.byType(CupertinoMenuItem);
      return tester
          .getRect(items.first)
          .expandToInclude(tester.getRect(items.last));
    }

    for (final top in const [40.0, 520.0]) {
      testWidgets('with the row at y $top', (tester) async {
        await pumpRow(tester, top: top);
        final menu = menuRect(tester);
        final chevron = tester.getRect(
          find.byIcon(CupertinoIcons.chevron_up_chevron_down),
        );
        // Trailing-aligned with the value, not centred on the row.
        expect((menu.right - chevron.right).abs(), lessThan(12));
        expect(menu.center.dx, greaterThan(200));
        // Never over a switch, or the value it came from.
        for (final title in const [
          JamPresetStrings.addSongs,
          JamPresetStrings.controlPlayback,
          JamPresetStrings.editQueue,
        ]) {
          final row = tester.getRect(
            find.ancestor(of: find.text(title), matching: find.byType(JamRow)),
          );
          expect(menu.overlaps(row), isFalse, reason: title);
        }
        expect(menu.overlaps(chevron), isFalse);
      });
    }
  });
}
