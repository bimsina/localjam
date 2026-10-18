/// Licences read like Settings › Legal: this platform's packages only, even
/// margins, no column padding from the plain-text files.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/screens/licenses_screen.dart';

void main() {
  test('another platform\'s plugin is left out', () {
    expect(
      jamLicenseIsOtherPlatform('app_links_linux', TargetPlatform.iOS),
      isTrue,
    );
    expect(
      jamLicenseIsOtherPlatform('url_launcher_web', TargetPlatform.android),
      isTrue,
    );
    expect(
      jamLicenseIsOtherPlatform('bonsoir_darwin', TargetPlatform.iOS),
      isFalse,
    );
    expect(
      jamLicenseIsOtherPlatform(
        'path_provider_android',
        TargetPlatform.android,
      ),
      isFalse,
    );
    expect(jamLicenseIsOtherPlatform('go_router', TargetPlatform.iOS), isFalse);
  });

  test('runs of spaces collapse', () {
    expect(
      jamLicenseParagraph('Apache License  Version 2.0,   January 2004'),
      'Apache License Version 2.0, January 2004',
    );
  });

  test('the section header is sentence case', () {
    expect(LicensesStrings.packages, 'Open-source software');
  });
}
