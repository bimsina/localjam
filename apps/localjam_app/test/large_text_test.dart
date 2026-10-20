import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';
import 'screens/onboarding_screen_test.dart' show pumpOnboarding;

/// Onboarding and the empty home shell, on small to large phones at 2× and
/// at the largest accessibility text: nothing overflows. The wordmark, the
/// identity card and the empty state once did.
void main() {
  const sizes = [Size(320, 568), Size(375, 667), Size(402, 874)];
  const scales = [2.0, 3.1];

  for (final size in sizes) {
    for (final scale in scales) {
      final label = '${size.width.toInt()}×${size.height.toInt()} at ${scale}x';

      testWidgets('onboarding fits at $label', (tester) async {
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await pumpOnboarding(tester, size: size);
        expect(tester.takeException(), isNull);
      });

      testWidgets('an empty Nearby fits at $label', (tester) async {
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        tester.view.physicalSize = size * tester.view.devicePixelRatio;
        addTearDown(tester.view.resetPhysicalSize);
        await pumpApp(tester, testSession());
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 100));
          expect(tester.takeException(), isNull, reason: 'frame $i');
        }
      });
    }
  }
}
