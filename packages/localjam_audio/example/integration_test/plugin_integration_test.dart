// This is a basic Flutter integration test.
//
// Since integration tests run in a full Flutter application, they can interact
// with the host side of a plugin implementation, unlike Dart unit tests.
//
// For more information about Flutter integration tests, please see
// https://flutter.dev/to/integration-testing

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:localjam_audio/localjam_audio.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('nowUs returns a monotonic native clock', (
    WidgetTester tester,
  ) async {
    final LocaljamAudio plugin = LocaljamAudio();
    final int a = await plugin.nativeNowUs();
    final int b = await plugin.nativeNowUs();
    expect(a, greaterThan(0));
    expect(b, greaterThanOrEqualTo(a));
  });

  testWidgets('calibrate produces a plausible offset', (
    WidgetTester tester,
  ) async {
    final LocaljamAudio plugin = LocaljamAudio();
    final Stopwatch clock = Stopwatch()..start();
    final NativeClockCalibration cal = await plugin.calibrate(
      () => clock.elapsedMicroseconds,
    );
    expect(cal.rttUs, greaterThanOrEqualTo(0));
    // offset + dartNow should be close to nativeNow (within one second).
    final int predicted = clock.elapsedMicroseconds + cal.offsetUs;
    final int native = await plugin.nativeNowUs();
    expect((native - predicted).abs(), lessThan(1000000));
  });
}
