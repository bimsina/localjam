/// The People / Room sheet: who is here, the way in, and the two label rules
/// an iOS pass found broken — a role that read as a status, and a raw
/// `localjam://` URI printed on a page about people (§6.8).
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/design/theme.dart';
import 'package:localjam_app/src/state/session_controller.dart';
import 'package:localjam_app/src/util/format.dart';
import 'package:localjam_app/src/util/network.dart';
import 'package:localjam_app/src/widgets/chip.dart';
import 'package:localjam_app/src/widgets/peer_row.dart';
import 'package:localjam_app/src/widgets/buttons.dart';
import 'package:localjam_app/src/widgets/room_sheet.dart';
import 'package:localjam_client/localjam_client.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../fixtures.dart';
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
    // A LAN of the test's choosing: whether the runner has Wi-Fi must not
    // decide whether there is a code to show.
    fakeLan([
      FakeInterface('en0', ['192.168.77.10']),
    ]);
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

    // The code is a button of its own a screen reader can press — not part
    // of the invite's paragraph, as the 2026-10-17 run found it.
    final semantics = tester.ensureSemantics();
    await tester.pump();
    final codeRow = tester.getSemantics(find.text(RoomSheetStrings.roomCode));
    expect(
      codeRow,
      matchesSemantics(
        label: codeRow.label,
        isButton: true,
        hasTapAction: true,
      ),
    );
    expect(codeRow.label, startsWith(RoomSheetStrings.roomCode));
    expect(codeRow.label, isNot(contains(RoomSheetStrings.invite)));
    // And the way out can be pressed too: its tap used to go with its
    // excluded semantics.
    expect(
      tester.getSemantics(find.text(RoomSheetStrings.endJam)),
      matchesSemantics(
        label: RoomSheetStrings.endJam,
        isButton: true,
        hasTapAction: true,
      ),
    );
    semantics.dispose();

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

  testWidgets('no network, no code — and the code turns up by itself', (
    tester,
  ) async {
    // Airplane mode, or a phone about to start its hotspot: there is no
    // address a guest could reach, so a QR would be a lie.
    fakeLan(const []);
    final host = testSession();
    await tester.runAsync(
      () => host.startHost(sessionName: 'Van Jam', discoverable: false),
    );
    final engine = host.hostEngine!;
    expect(engine.hasLanAddress, isFalse);

    await _pump(
      tester,
      host,
      RoomPanel(
        engine: engine,
        selfName: 'Silky Puffin',
        network: JamNetworkStatus.offline,
      ),
    );
    expect(find.byType(QrImageView), findsNothing);
    expect(find.text(RoomSheetStrings.noNetworkTitle), findsOneWidget);
    expect(find.text(RoomSheetStrings.shareLink), findsNothing);

    // Wi-Fi comes up. Nobody reopens anything: the engine re-scans and the
    // code appears.
    fakeLan([
      FakeInterface('en0', ['192.168.77.10']),
    ]);
    await tester.runAsync(engine.refreshLanAddresses);
    await tester.pump();
    expect(engine.hasLanAddress, isTrue);
    expect(find.text(RoomSheetStrings.noNetworkTitle), findsNothing);
    expect(find.byKey(ValueKey('${engine.joinUri}')), findsOneWidget);
    expect('${engine.joinUri}', contains('192.168.77.10'));

    // The phone moves to another network: the code follows the link, not
    // the network it was first drawn for.
    fakeLan([
      FakeInterface('en0', ['192.168.88.20']),
    ]);
    await tester.runAsync(engine.refreshLanAddresses);
    await tester.pump();
    expect('${engine.joinUri}', contains('192.168.88.20'));
    expect(find.byKey(ValueKey('${engine.joinUri}')), findsOneWidget);
    expect(find.byType(QrImageView), findsOneWidget);

    await tester.runAsync(host.leave);
  });

  testWidgets('a guest with no name is "Guest", and can be let back in', (
    tester,
  ) async {
    final host = testSession();
    final guest = testSession();
    final cache = _tempCache();
    late String peerId;

    await tester.runAsync(() async {
      await host.startHost(sessionName: 'Van Jam', discoverable: false);
      // A client that shared no display name at all.
      expect(
        await guest.join(host.joinUri!, clientName: '', mediaCacheDir: cache),
        isTrue,
      );
      expect(await _waitFor(() => host.engine!.peers.isNotEmpty), isTrue);
      peerId = host.engine!.peers.single.peerId;
    });

    await _pump(
      tester,
      host,
      RoomPanel(
        engine: host.engine!,
        selfName: 'Silky Puffin',
        network: JamNetworkStatus.offline,
      ),
    );
    // Never the wire id standing in for a name.
    expect(find.text(kJamUnnamedPeer), findsOneWidget);
    expect(find.textContaining(peerId), findsNothing);
    expect(find.text(RoomSheetStrings.removed), findsNothing);

    // Removed: they are listed, by the same friendly name, with the one
    // way back in (§5.6 — a kicked device stays out until then).
    await tester.runAsync(() async {
      host.hostEngine!.kickPeer(peerId);
      expect(await _waitFor(() => host.engine!.peers.isEmpty), isTrue);
    });
    await tester.pump();
    expect(find.text(RoomSheetStrings.removed), findsOneWidget);
    expect(find.text(kJamUnnamedPeer), findsOneWidget);
    expect(find.text(RoomSheetStrings.letBackIn), findsOneWidget);
    // A button of its own — not folded into the "Removed" paragraph around
    // it, as the 2026-10-17 run found — named by the words on it, then whom
    // it lets back in.
    final semantics = tester.ensureSemantics();
    await tester.pump();
    expect(
      tester.getSemantics(find.text(RoomSheetStrings.letBackIn)),
      matchesSemantics(
        label: RoomSheetStrings.letBackInFor(kJamUnnamedPeer),
        isButton: true,
        isEnabled: true,
        hasEnabledState: true,
        hasTapAction: true,
      ),
    );
    expect(
      RoomSheetStrings.letBackInFor(kJamUnnamedPeer),
      startsWith(RoomSheetStrings.letBackIn),
    );
    semantics.dispose();

    await tester.tap(find.text(RoomSheetStrings.letBackIn));
    await tester.pump();
    expect(host.hostEngine!.kickedPeers, isEmpty);
    expect(find.text(RoomSheetStrings.removed), findsNothing);

    await tester.runAsync(guest.leave);
    await tester.runAsync(host.leave);
  });

  testWidgets('removing someone says what a removal is now: out until you '
      'let them back in — not "they can come back with the room code"', (
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
    });
    await _pump(
      tester,
      host,
      RoomPanel(
        engine: host.engine!,
        selfName: 'Silky Puffin',
        network: JamNetworkStatus.offline,
      ),
    );

    await tester.tap(find.byIcon(Icons.more_horiz_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text(RoomSheetStrings.removePeer));
    await tester.pumpAndSettle();
    expect(find.text(RoomSheetStrings.removeTitle('Ana')), findsOneWidget);
    expect(find.text(RoomSheetStrings.removeDetail), findsOneWidget);
    expect(find.textContaining('room code'), findsNothing);
    expect(RoomSheetStrings.removeDetail, contains('let them back in'));

    await tester.tap(find.text(RoomSheetStrings.remove));
    await tester.pumpAndSettle();
    await tester.runAsync(() => _waitFor(() => host.engine!.peers.isEmpty));
    await tester.pump();
    expect(host.hostEngine!.kickedPeers.single.clientName, 'Ana');
    expect(find.text(RoomSheetStrings.letBackIn), findsOneWidget);

    await tester.runAsync(guest.leave);
    await tester.runAsync(host.leave);
  });

  testWidgets('letting in someone already let back in elsewhere just '
      'redraws — it is not a failure', (tester) async {
    final host = testSession();
    final guest = testSession();
    final cache = _tempCache();
    final heard = <String>[];
    final sub = host.notices.listen((n) => heard.add(n.message));
    addTearDown(sub.cancel);
    late String peerId;
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
      peerId = host.engine!.peers.single.peerId;
      host.hostEngine!.kickPeer(peerId);
      expect(await _waitFor(() => host.engine!.peers.isEmpty), isTrue);
    });
    await _pump(
      tester,
      host,
      RoomPanel(
        engine: host.engine!,
        selfName: 'Silky Puffin',
        network: JamNetworkStatus.offline,
      ),
    );
    expect(find.text(RoomSheetStrings.letBackIn), findsOneWidget);

    // Let back in from somewhere else; this sheet has not redrawn yet.
    host.hostEngine!.unkickPeer(peerId);
    await tester.tap(find.text(RoomSheetStrings.letBackIn));
    await tester.pump();
    await tester.runAsync(pumpEventQueue);
    expect(heard, isNot(contains(RoomSheetStrings.actionFailed)));
    expect(find.text(RoomSheetStrings.removed), findsNothing);

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

  testWidgets('ending the jam with the sheet open: a part of it built again '
      'on the way out reads the last code, it does not subscribe', (
    tester,
  ) async {
    // 2026-10-17 run: End jam sits under the invite, so the invite had been
    // scrolled out of the lazy list; the sheet animating away built it again
    // after the engine had released its listenables, and a fresh
    // subscription tripped "ValueNotifier used after being disposed".
    fakeLan([
      FakeInterface('en0', ['192.168.77.10']),
    ]);
    final host = testSession();
    await tester.runAsync(
      () => host.startHost(sessionName: 'Van Jam', discoverable: false),
    );
    await tester.pump();
    final engine = host.hostEngine!;
    Widget panel(int generation) => RoomPanel(
      // A new key mounts every row afresh, as the lazy list does for a row
      // scrolled back into view.
      key: ValueKey(generation),
      engine: engine,
      selfName: 'Silky Puffin',
      network: JamNetworkStatus.offline,
    );
    await _pump(tester, host, panel(1));
    expect(find.byType(QrImageView), findsOneWidget);
    expect(find.byType(ValueListenableBuilder<Uri>), findsOneWidget);

    await tester.runAsync(host.leave);
    expect(engine.sessionEnded.value, JamSessionEndReason.closedLocally);
    await tester.pump();
    expect(
      find.byType(ValueListenableBuilder<Uri>),
      findsNothing,
      reason: 'the end rebuilt the page off the listenables',
    );

    await _pump(tester, host, panel(2));
    expect(tester.takeException(), isNull);
    expect(find.byType(QrImageView), findsOneWidget, reason: 'the last code');
    expect(find.byType(ValueListenableBuilder<Uri>), findsNothing);
    expect(
      find.byType(ValueListenableBuilder<List<InternetAddress>>),
      findsNothing,
    );
  });
}
