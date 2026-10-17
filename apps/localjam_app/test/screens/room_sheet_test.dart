/// The People / Room sheet: who is here, the way in, and the two label rules
/// an iOS pass found broken — a role that read as a status, and a raw
/// `localjam://` URI printed on a page about people (§6.8).
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/design/theme.dart';
import 'package:localjam_app/src/state/session_controller.dart';
import 'package:localjam_app/src/util/network.dart';
import 'package:localjam_app/src/widgets/chip.dart';
import 'package:localjam_app/src/widgets/peer_row.dart';
import 'package:localjam_app/src/widgets/buttons.dart';
import 'package:localjam_app/src/widgets/room_sheet.dart';
import 'package:localjam_client/localjam_client.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../harness.dart';

Future<bool> _waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  return condition();
}

Directory _tempCache() {
  final dir = Directory.systemTemp.createTempSync('localjam_room_test');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return dir;
}

/// Tall enough to lay the whole page out without scrolling.
Future<void> _pump(
  WidgetTester tester,
  JamSessionController session,
  Widget child, {
  ThemeData? theme,
}) async {
  tester.view.physicalSize =
      const Size(420, 2400) * tester.view.devicePixelRatio;
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    JamSession(
      controller: session,
      child: MaterialApp(
        theme: theme ?? jamLightTheme(),
        home: Scaffold(body: child),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('a host sees the room, the way in, and the way out', (
    tester,
  ) async {
    final host = testSession();
    await tester.runAsync(
      () => host.startHost(sessionName: 'Van Jam', discoverable: false),
    );
    await tester.pump();

    await _pump(
      tester,
      host,
      RoomPanel(
        engine: host.engine!,
        selfName: 'Silky Puffin',
        network: JamNetworkStatus.offline,
        joinUri: host.joinUri,
      ),
    );
    await tester.pump();

    expect(find.text(RoomSheetStrings.inTheRoom(1)), findsOneWidget);
    expect(find.byType(JamPeerRow), findsOneWidget);
    expect(find.text(JamPeerRowStrings.host), findsOneWidget);

    // The invite, without the machine text (§6.8, §8 check 3).
    expect(find.byType(QrImageView), findsOneWidget);
    expect(find.text('Van Jam'), findsOneWidget);
    expect(find.text(RoomSheetStrings.roomCode), findsOneWidget);
    expect(find.text(RoomSheetStrings.shareLink), findsOneWidget);
    expect(find.textContaining('localjam://'), findsNothing);

    // Three switches over the policy, summarised in a sentence — `jam` is
    // what `startHost` defaults to (§5 "Host setup"). `JamSwitchRow`, not
    // `SwitchListTile`: the stock tile fills its track with the accent and
    // three of those out-shouted the sheet's own primary action.
    expect(find.byType(JamSwitchRow), findsNWidgets(3));
    expect(
      find.text(RoomSheetStrings.presetFootnote(JamPolicy.jam)),
      findsOneWidget,
    );

    // §6.1: Leave is a labelled row here, not a third item behind an ellipsis.
    expect(find.text(RoomSheetStrings.endJam), findsOneWidget);

    await tester.runAsync(host.leave);
  });

  testWidgets('a diverging switch renames the preset Custom', (tester) async {
    final host = testSession();
    await tester.runAsync(
      () => host.startHost(sessionName: 'Van Jam', discoverable: false),
    );
    await tester.pump();

    await _pump(
      tester,
      host,
      RoomPanel(
        engine: host.engine!,
        selfName: 'Silky Puffin',
        network: JamNetworkStatus.offline,
        joinUri: host.joinUri,
      ),
    );
    await tester.pump();

    // `startHost` opens on JamPolicy.open; dropping one right leaves a
    // combination no preset names.
    await tester.tap(find.text(RoomSheetStrings.addMusic));
    await tester.pump();

    expect(host.engine!.permissions.policy.addTracks, isFalse);
    // "Preset: Custom" was the enum showing through. The summary says what
    // the room actually allows, whether or not a preset happens to name it.
    expect(
      find.text(
        RoomSheetStrings.presetFootnote(host.engine!.permissions.policy),
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Preset:'), findsNothing);

    await tester.runAsync(host.leave);
  });

  testWidgets('a guest gets a read-only room and never a bogus role', (
    tester,
  ) async {
    final host = testSession();
    final guest = testSession();
    final cache = _tempCache();

    await tester.runAsync(() async {
      await host.startHost(
        sessionName: 'Open Room',
        policy: JamPolicy.open,
        discoverable: false,
      );
      expect(
        await guest.join(
          host.joinUri!,
          clientName: 'Ana',
          mediaCacheDir: cache,
        ),
        isTrue,
      );
      expect(await _waitFor(() => guest.engine != null), isTrue);
    });
    await tester.pump();

    await _pump(
      tester,
      guest,
      RoomPanel(
        engine: guest.engine!,
        selfName: 'Ana',
        network: JamNetworkStatus.offline,
      ),
    );
    await tester.pump();

    // You, then the host.
    expect(find.text(RoomSheetStrings.inTheRoom(2)), findsOneWidget);
    expect(find.byType(JamPeerRow), findsNWidgets(2));
    expect(find.text(JamPeerRowStrings.host), findsOneWidget);

    // The iOS report: a guest with every right read "Listening" as if that
    // were their standing in the room. Readiness is the host's to observe.
    expect(find.text(JamPeerRowStrings.listening), findsNothing);

    // No invite, no switches — a summary of what the room allows instead.
    expect(find.byType(QrImageView), findsNothing);
    expect(find.byType(JamSwitchRow), findsNothing);
    expect(
      find.text(RoomSheetStrings.guestSummary(JamPolicy.open)),
      findsOneWidget,
    );
    expect(find.text(RoomSheetStrings.leaveJam), findsOneWidget);
    expect(find.text(RoomSheetStrings.endJam), findsNothing);

    await tester.runAsync(guest.leave);
    await tester.runAsync(host.leave);
  });

  testWidgets('a blocked guest gets a badge and a capability chip', (
    tester,
  ) async {
    final host = testSession();
    final guest = testSession();
    final cache = _tempCache();

    await tester.runAsync(() async {
      await host.startHost(sessionName: 'Van Jam', discoverable: false);
      expect(
        await guest.join(
          host.joinUri!,
          clientName: 'Ana',
          mediaCacheDir: cache,
        ),
        isTrue,
      );
      expect(await _waitFor(() => host.engine!.peers.isNotEmpty), isTrue);
      final peerId = host.engine!.peers.first.peerId;
      host.hostEngine!
        ..promotePeer(peerId)
        ..setCapabilityOverride(
          peerId,
          JamCapability.addTracks,
          allowed: false,
        );
    });
    await tester.pump();

    await _pump(
      tester,
      host,
      RoomPanel(
        engine: host.engine!,
        selfName: 'Silky Puffin',
        network: JamNetworkStatus.offline,
        joinUri: host.joinUri,
      ),
    );
    await tester.pump();

    // The old row crammed both into one line: "Co-host · Cannot add".
    expect(find.text(JamPeerRowStrings.cohost), findsOneWidget);
    expect(find.widgetWithText(JamChip, RoomSheetStrings.cannotAdd), findsOne);
    expect(find.text('Co-host · Cannot add'), findsNothing);

    await tester.runAsync(guest.leave);
    await tester.runAsync(host.leave);
  });

  testWidgets('the sheet opens at the spec height, on the dark palette', (
    tester,
  ) async {
    final host = testSession();
    await tester.runAsync(
      () => host.startHost(sessionName: 'Dark Jam', discoverable: false),
    );
    await tester.pump();

    late BuildContext sheetContext;
    await _pump(
      tester,
      host,
      Builder(
        builder: (context) {
          sheetContext = context;
          return const SizedBox.shrink();
        },
      ),
      theme: jamDarkTheme(),
    );

    showRoomSheet(
      sheetContext,
      host.engine!,
      selfName: 'Silky Puffin',
      network: JamNetworkStatus.offline,
      joinUri: host.joinUri,
    ).ignore();
    await tester.pumpAndSettle();

    final sheet = tester.widget<DraggableScrollableSheet>(
      find.byType(DraggableScrollableSheet),
    );
    expect(sheet.initialChildSize, 0.82);
    expect(sheet.maxChildSize, 0.96);
    expect(find.text(RoomSheetStrings.inTheRoom(1)), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.runAsync(host.leave);
  });
}
