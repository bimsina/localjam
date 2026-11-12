/// Back at the bottom of the app while a jam is live (B1).
///
/// The report: hosting, close the room to Home, press back — the activity
/// finished, the engine went with it, and so did the server and the audio;
/// guests got "Reconnecting…" and then "Room closed", with no goodbye. Back
/// there now backgrounds the app, as Home would; everywhere else it still
/// pops, and with no jam it still exits.
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState, SizedBox;
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/router.dart';
import 'package:localjam_app/src/state/session_controller.dart';
import 'package:localjam_app/src/widgets/live_jam_back.dart';

import 'harness.dart';

/// What the app asked of the platform when back was pressed.
class _Platform {
  int movedToBack = 0;
  int exited = 0;

  /// The last word the framework sent the engine about handling back
  /// itself: what decides, under Android 16's predictive back, whether
  /// back reaches the app at all.
  bool? frameworkHandlesBack;
}

Future<_Platform> _watchPlatform(WidgetTester tester) async {
  final platform = _Platform();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  // The app has to be running for the framework to tell the engine anything
  // about back (a detached app keeps quiet), and a test starts with no
  // lifecycle at all.
  await messenger.handlePlatformMessage(
    SystemChannels.lifecycle.name,
    const StringCodec().encodeMessage(AppLifecycleState.resumed.toString()),
    (_) {},
  );
  addTearDown(tester.binding.resetInternalState);
  messenger.setMockMethodCallHandler(JamAppTask.channel, (call) async {
    if (call.method == 'moveToBack') platform.movedToBack++;
    return true;
  });
  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    switch (call.method) {
      case 'SystemNavigator.pop':
        platform.exited++;
      case 'SystemNavigator.setFrameworkHandlesBack':
        platform.frameworkHandlesBack = call.arguments as bool;
    }
    return null;
  });
  addTearDown(() {
    messenger
      ..setMockMethodCallHandler(JamAppTask.channel, null)
      ..setMockMethodCallHandler(SystemChannels.platform, null);
  });
  return platform;
}

/// The system back button (or gesture), as the engine delivers it.
Future<void> _back(WidgetTester tester) async {
  await tester.binding.handlePopRoute();
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}

/// Takes the app down and the jam with it, without leaving discovery's
/// periodic sweep behind in the fake zone.
Future<void> _end(WidgetTester tester, JamSessionController session) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.runAsync(() async {
    await session.leave();
    await session.stopBrowsing();
  });
}

void main() {
  testWidgets(
    'hosting, a back at Home backgrounds the app and the jam plays on',
    (tester) async {
      final platform = await _watchPlatform(tester);
      final session = testSession();
      final router = await pumpApp(tester, session);
      await startTestHost(tester, session, 'Rooftop');
      await _settle(tester);
      expect(platform.frameworkHandlesBack, isTrue);

      await _back(tester);

      expect(platform.movedToBack, 1);
      expect(platform.exited, 0);
      expect(session.isLive, isTrue);
      expect(router.state.matchedLocation, '/');

      await _end(tester, session);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets('with no jam, a back at Home exits as it always has', (
    tester,
  ) async {
    final platform = await _watchPlatform(tester);
    final session = testSession();
    await pumpApp(tester, session);
    await _settle(tester);
    expect(platform.frameworkHandlesBack, isNot(isTrue));

    await _back(tester);

    expect(platform.movedToBack, 0);
    expect(platform.exited, 1);
    await _end(tester, session);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets(
    'a back over Home still pops what is on top — nobody is trapped',
    (tester) async {
      final platform = await _watchPlatform(tester);
      final session = testSession();
      final router = await pumpApp(tester, session);
      await startTestHost(tester, session, 'Rooftop');
      await _settle(tester);

      for (final path in ['/settings', '/history', kRoomPath]) {
        unawaited(router.push(path));
        await _settle(tester);
        expect(router.state.matchedLocation, path);
        await _back(tester);
        expect(router.state.matchedLocation, '/', reason: path);
        expect(platform.movedToBack, 0, reason: path);
      }

      // And once it is Home, the jam is what back protects.
      await _back(tester);
      expect(platform.movedToBack, 1);
      expect(platform.exited, 0);

      // The jam over, back exits again.
      await tester.runAsync(session.leave);
      await _settle(tester);
      expect(platform.frameworkHandlesBack, isFalse);
      await _back(tester);
      expect(platform.movedToBack, 1);
      expect(platform.exited, 1);

      await _end(tester, session);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets('iOS has no back to the home screen: nothing changes there', (
    tester,
  ) async {
    final platform = await _watchPlatform(tester);
    final session = testSession();
    await pumpApp(tester, session);
    await startTestHost(tester, session, 'Rooftop');
    await _settle(tester);

    await _back(tester);

    expect(platform.movedToBack, 0);
    await _end(tester, session);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
}
