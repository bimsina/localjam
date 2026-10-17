/// The formatters behind the numbers on screen.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/util/format.dart';

void main() {
  group('formatSignedMs', () {
    test('signs a real figure', () {
      expect(formatSignedMs(12300), '+12.3 ms');
      expect(formatSignedMs(-12300), '-12.3 ms');
    });

    test('renders anything that rounds to zero as an unsigned 0.0 ms', () {
      // The flap: drift hovering around perfect alternated between "+0.0 ms"
      // and "-0.0 ms" every sample, which reads as instability that is not
      // there. Two readings that round the same must print the same.
      expect(formatSignedMs(0), '0.0 ms');
      expect(formatSignedMs(1), '0.0 ms');
      expect(formatSignedMs(-1), '0.0 ms');
      expect(formatSignedMs(49), '0.0 ms');
      expect(formatSignedMs(-49), '0.0 ms');
    });

    test('starts signing again at the deadband edge', () {
      expect(formatSignedMs(60), '+0.1 ms');
      expect(formatSignedMs(-60), '-0.1 ms');
    });

    test('formatDriftMs is the same formatter', () {
      expect(formatDriftMs(-1), formatSignedMs(-1));
      expect(formatDriftMs(4200), '+4.2 ms');
    });
  });

  group('formatPositionUs', () {
    test('mm:ss, and h:mm:ss past an hour', () {
      expect(formatPositionUs(0), '00:00');
      expect(formatPositionUs(65 * 1000000), '01:05');
      expect(formatPositionUs(3725 * 1000000), '1:02:05');
    });
  });
}
