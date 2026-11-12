/// The engine-state capsule under Now Playing's header: its sentence is never cut short, and
/// at large text sizes its action moves under it instead of squeezing it.
library;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/design/theme.dart';
import 'package:localjam_app/src/widgets/room_banner.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  Future<void> pumpBanner(
    WidgetTester tester, {
    required double width,
    required double scale,
    required String message,
    VoidCallback? onAction,
  }) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: jamLightTheme(),
        home: MediaQuery(
          data: MediaQueryData(
            size: Size(width, 900),
            textScaler: TextScaler.linear(scale),
          ),
          child: Scaffold(
            body: Column(
              children: [
                JamRoomBanner(
                  icon: CupertinoIcons.exclamationmark_circle,
                  message: message,
                  actionLabel: JamRoomBannerStrings.resume,
                  onAction: onAction ?? () {},
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  const messages = [
    JamRoomBannerStrings.playbackErrorRetrying,
    JamRoomBannerStrings.outputLost,
    JamRoomBannerStrings.interruption,
    JamRoomBannerStrings.reconnecting,
  ];

  for (final width in [320.0, 360.0]) {
    for (final scale in [1.0, 2.0, 3.0]) {
      testWidgets('at ${scale}x text on $width dp: whole sentence, no '
          'overflow, and the action still works', (tester) async {
        for (final message in messages) {
          var tapped = 0;
          await pumpBanner(
            tester,
            width: width,
            scale: scale,
            message: message,
            onAction: () => tapped++,
          );
          expect(tester.takeException(), isNull, reason: '$message overflow');
          final paragraph = tester.renderObject<RenderParagraph>(
            find.text(message),
          );
          expect(
            paragraph.didExceedMaxLines,
            isFalse,
            reason: '"$message" cut short',
          );
          await tester.tap(find.text(JamRoomBannerStrings.resume));
          expect(tapped, 1);
        }
      });
    }
  }

  testWidgets('past 1.3x the action sits under the sentence; at 1x beside it', (
    tester,
  ) async {
    double gapBelow() =>
        tester.getTopLeft(find.text(JamRoomBannerStrings.resume)).dy -
        tester.getTopLeft(find.text(JamRoomBannerStrings.outputLost)).dy;

    await pumpBanner(
      tester,
      width: 360,
      scale: 1,
      message: JamRoomBannerStrings.outputLost,
    );
    expect(
      tester.getTopLeft(find.text(JamRoomBannerStrings.resume)).dx,
      greaterThan(
        tester.getTopRight(find.text(JamRoomBannerStrings.outputLost)).dx - 1,
      ),
      reason: 'one row',
    );
    await pumpBanner(
      tester,
      width: 360,
      scale: 2,
      message: JamRoomBannerStrings.outputLost,
    );
    expect(
      gapBelow(),
      greaterThan(
        tester.getSize(find.text(JamRoomBannerStrings.outputLost)).height - 1,
      ),
      reason: 'the action is on its own line',
    );
  });
}
