/// The rationale gate in front of the OS prompts — and, on iOS and macOS,
/// in front of a prompt there is no API to ask for.
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/util/permissions.dart';
import 'package:localjam_app/src/widgets/permission_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Records every rationale the code asks to show.
List<JamPermissionKind> installPresenter({bool answer = true}) {
  final shown = <JamPermissionKind>[];
  jamRationalePresenter = (kind) async {
    shown.add(kind);
    return answer;
  };
  addTearDown(() => jamRationalePresenter = null);
  return shown;
}

/// The Apple path is the one under test; elsewhere `ensureLocalNetwork...`
/// has real permission plumbing behind it and no way to fake it here.
final bool _notApple = !Platform.isIOS && !Platform.isMacOS;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    resetExplainedPermissionsForTesting();
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('two asks at once share one sheet and its "Not now"', (
    tester,
  ) async {
    // The bug: the second ask read the flag the first had just set and went
    // straight to the OS prompt, so "Not now" was answered by the system
    // dialog anyway. Both now wait on the one sheet.
    final shown = installPresenter(answer: false);
    final answers = await Future.wait([
      jamExplainPermission(JamPermissionKind.localNetworkApple),
      jamExplainPermission(JamPermissionKind.localNetworkApple),
    ]);
    expect(shown, [JamPermissionKind.localNetworkApple]);
    expect(answers, [false, false]);
  });

  group('local network on iOS and macOS', () {
    testWidgets('is explained before the first jam, and only once', (
      tester,
    ) async {
      // The bug: `ensureLocalNetworkPermission` early-returned on anything
      // but Android, so an iOS user met the system's local-network alert
      // cold, mid-spinner, with nothing having said what it was for.
      final shown = installPresenter();

      await ensureLocalNetworkPermission();
      expect(shown, [JamPermissionKind.localNetworkApple]);

      // Same process, same launch, second jam: nothing.
      await ensureLocalNetworkPermission();
      await ensureLocalNetworkPermission();
      expect(shown, hasLength(1));
    }, skip: _notApple);

    testWidgets('stays explained across a restart', (tester) async {
      final first = installPresenter();
      await ensureLocalNetworkPermission();
      expect(first, hasLength(1));

      // A new process: the in-memory latch is gone, the persisted flag is
      // not. The sheet must not come back.
      resetExplainedPermissionsForTesting();
      final second = installPresenter();
      await ensureLocalNetworkPermission();
      expect(second, isEmpty);
    }, skip: _notApple);

    testWidgets('is shown once even when prefs will not answer', (
      tester,
    ) async {
      // Nothing is requestable behind this sheet, so a store that cannot
      // remember "already shown" must not turn once into every time.
      SharedPreferences.setMockInitialValues({});
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/shared_preferences'),
        (_) async => throw PlatformException(code: 'no'),
      );
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/shared_preferences'),
          null,
        ),
      );

      final shown = installPresenter();
      await ensureLocalNetworkPermission();
      await ensureLocalNetworkPermission();
      expect(shown.length, lessThanOrEqualTo(1));
    }, skip: _notApple);
  });

  group('the Apple rationale copy', () {
    test('says the system is about to ask', () {
      final rationale = JamPermissionRationale.forKind(
        JamPermissionKind.localNetworkApple,
      );
      expect(rationale.body, contains('the system will ask'));
    });

    test('offers no "Not now", because nothing here can be declined', () {
      // The OS alert is coming the moment the first socket opens; a decline
      // that cannot stop it would be a lie.
      final rationale = JamPermissionRationale.forKind(
        JamPermissionKind.localNetworkApple,
      );
      expect(rationale.dismissLabel, isEmpty);
      expect(rationale.continueLabel, JamPermissionSheetStrings.gotItLabel);
    });

    test('the Android variant still offers both answers', () {
      final rationale = JamPermissionRationale.forKind(
        JamPermissionKind.localNetwork,
      );
      expect(rationale.dismissLabel, JamPermissionSheetStrings.dismissLabel);
    });
  });
}
