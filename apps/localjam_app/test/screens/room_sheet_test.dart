/// The People and Invite sheets (§6.5): who is here and what they may do,
/// and the code that lets more people in — without the machine text of a
/// raw `localjam://` URI anywhere on a page about people.
library;

import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart'
    show MaterialApp, Scaffold, Theme, ThemeData;
import 'package:flutter/rendering.dart' show SemanticsAction;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/design/theme.dart';
import 'package:localjam_app/src/design/tokens.dart';
import 'package:localjam_app/src/state/session_controller.dart';
import 'package:localjam_app/src/state/web_guest_bundle.dart';
import 'package:localjam_app/src/util/format.dart';
import 'package:localjam_app/src/util/media_picking.dart';
import 'package:localjam_app/src/util/network.dart';
import 'package:localjam_app/src/util/permissions.dart';
import 'package:localjam_app/src/widgets/avatar.dart';
import 'package:localjam_app/src/widgets/guests_can.dart';
import 'package:localjam_app/src/widgets/jam_mark.dart';
import 'package:localjam_app/src/widgets/list.dart';
import 'package:localjam_app/src/widgets/peer_row.dart';
import 'package:localjam_app/src/widgets/room_sheet.dart';
import 'package:localjam_app/src/widgets/section.dart';
import 'package:localjam_app/src/widgets/sheet.dart';
import 'package:localjam_app/src/widgets/switch.dart';
import 'package:localjam_app/src/widgets/menu.dart';
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

RoomPanel _panel(
  JamSessionController session, {
  String self = 'Silky Puffin',
}) => RoomPanel(
  engine: session.engine!,
  selfName: self,
  network: JamNetworkStatus.offline,
);

/// Starts a host and joins one guest called [name]; returns the guest.
Future<JamSessionController> _hostWithGuest(
  WidgetTester tester,
  JamSessionController host, {
  String name = 'Ana',
  JamPolicy policy = JamPolicy.jam,
  bool viaDeepLink = false,
}) async {
  final guest = testSession();
  final cache = _tempCache();
  await tester.runAsync(() async {
    await host.startHost(
      sessionName: 'Van Jam',
      policy: policy,
      discoverable: false,
    );
    final link = viaDeepLink ? host.hostEngine!.localjamUri : host.joinUri!;
    expect(
      await guest.join(link, clientName: name, mediaCacheDir: cache),
      isTrue,
    );
    expect(await _waitFor(() => host.engine!.peers.isNotEmpty), isTrue);
    expect(await _waitFor(() => guest.engine != null), isTrue);
  });
  await tester.pump();
  return guest;
}

/// A music library of one song, for the share switch.
class _Library extends JamCatalogSource {
  @override
  Future<List<CatalogEntry>> list() async => const [
    CatalogEntry(catalogId: 'c_1', title: 'Low Tide'),
  ];

  @override
  Future<File?> open(String catalogId) async => null;
}

/// This platform has a library, and the permission ask answers [outcome].
void _libraryHere(JamPermissionOutcome outcome, {void Function()? onAsk}) {
  debugJamLibraryAvailable = true;
  jamAudioPermissionRequest = () async {
    onAsk?.call();
    return outcome;
  };
  addTearDown(() {
    debugJamLibraryAvailable = null;
    jamAudioPermissionRequest = requestAudioLibraryPermission;
  });
}

Finder _shareSwitch() => find.descendant(
  of: find.widgetWithText(JamRow, RoomSheetStrings.shareLibrary),
  matching: find.byType(JamSwitch),
);

/// Lets the engine's own work (listing, broadcasting) run until [done].
Future<void> _settle(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 50 && !done(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump();
  }
}

/// A pull-down item by its title (the toggle rows share some titles).
Finder _menuItem(String title) => find.widgetWithText(JamMenuRow, title);

void main() {
  testWidgets('a host sees the people, what guests can do, and the way out', (
    tester,
  ) async {
    final host = testSession();
    await tester.runAsync(
      () => host.startHost(sessionName: 'Van Jam', discoverable: false),
    );
    await tester.pump();
    await _pump(tester, host, _panel(host));

    expect(find.text(RoomSheetStrings.invitePeople), findsOneWidget);
    expect(find.text(RoomSheetStrings.peopleCount(1)), findsOneWidget);
    expect(find.byType(JamPeerRow), findsOneWidget);
    // "Host" is plain secondary text on the row, not a pill.
    expect(find.text('Host · You'), findsOneWidget);

    // The code lives in the Invite sheet now, not on this page.
    expect(find.byType(QrImageView), findsNothing);
    expect(find.textContaining('localjam://'), findsNothing);

    // The preset and the three switches it stands for, summarised in a
    // sentence — `jam` is what `startHost` defaults to.
    expect(find.text(JamPresetStrings.guestsCan), findsOneWidget);
    // The three guest switches, Show to People Nearby, then Share My Music
    // Library.
    expect(find.byType(JamSwitch), findsNWidgets(5));
    expect(find.text(JamPresetStrings.summary(JamPolicy.jam)), findsOneWidget);
    // An invite-only jam, which the host can still show mid-jam.
    expect(find.text(RoomSheetStrings.nearby), findsOneWidget);
    expect(find.text(RoomSheetStrings.nearbyOffFooter), findsOneWidget);
    expect(
      tester
          .widget<JamSwitch>(
            find.descendant(
              of: find.widgetWithText(JamRow, RoomSheetStrings.nearby),
              matching: find.byType(JamSwitch),
            ),
          )
          .value,
      false,
    );

    // The way out, a row a screen reader can press.
    expect(find.text(RoomSheetStrings.endJam), findsOneWidget);
    expect(find.text(RoomSheetStrings.leaveJam), findsNothing);
    final semantics = tester.ensureSemantics();
    await tester.pump();
    final end = tester
        .getSemantics(find.text(RoomSheetStrings.endJam))
        .getSemanticsData();
    expect(end.label, RoomSheetStrings.endJam);
    expect(end.hasAction(SemanticsAction.tap), isTrue);
    semantics.dispose();

    // End Jam asks first; Cancel keeps the room. Nobody else is here, so
    // it doesn't talk about stopping the music for "everyone".
    await tester.tap(find.text(RoomSheetStrings.endJam));
    await tester.pumpAndSettle();
    expect(find.text(RoomSheetStrings.endTitle), findsOneWidget);
    expect(find.text(RoomSheetStrings.endDetailAlone), findsOneWidget);
    await tester.tap(find.text(RoomSheetStrings.cancel));
    await tester.pumpAndSettle();
    expect(host.isLive, isTrue);

    await tester.runAsync(host.leave);
  });

  testWidgets('a diverging switch renames the preset Custom', (tester) async {
    final host = testSession();
    await tester.runAsync(
      () => host.startHost(sessionName: 'Van Jam', discoverable: false),
    );
    await tester.pump();
    await _pump(tester, host, _panel(host));

    expect(find.text(JamPresetStrings.songsOnly), findsOneWidget);
    // The first switch is Add Songs — a different name from any preset.
    expect(find.text(JamPresetStrings.addSongs), findsOneWidget);
    await tester.tap(find.byType(JamSwitch).first);
    await tester.pump();

    final policy = host.engine!.permissions.policy;
    expect(policy.addTracks, isFalse);
    expect(find.text(JamPresetStrings.custom), findsOneWidget);
    expect(find.text(JamPresetStrings.summary(policy)), findsOneWidget);
    expect(find.textContaining('Preset:'), findsNothing);

    await tester.runAsync(host.leave);
  });

  testWidgets('the Guests Can pull-down applies a preset', (tester) async {
    final host = testSession();
    await tester.runAsync(
      () => host.startHost(sessionName: 'Van Jam', discoverable: false),
    );
    await tester.pump();
    await _pump(tester, host, _panel(host));

    await tester.tap(find.text(JamPresetStrings.guestsCan));
    await tester.pumpAndSettle();
    expect(find.text(JamPresetStrings.everythingDetail), findsOneWidget);
    await tester.tap(find.text(JamPresetStrings.everything));
    await tester.pumpAndSettle();

    expect(host.engine!.permissions.policy, JamPolicy.open);
    expect(find.text(JamPresetStrings.summary(JamPolicy.open)), findsOneWidget);

    await tester.runAsync(host.leave);
  });

  testWidgets('a guest gets a read-only page and never a bogus role', (
    tester,
  ) async {
    final host = testSession();
    final guest = await _hostWithGuest(tester, host, policy: JamPolicy.open);
    await _pump(tester, guest, _panel(guest, self: 'Ana'));

    // You, then the host.
    expect(find.text(RoomSheetStrings.peopleCount(2)), findsOneWidget);
    expect(find.byType(JamPeerRow), findsNWidgets(2));
    expect(find.text(JamPeerRowStrings.you), findsOneWidget);
    expect(find.text(JamPeerRowStrings.host), findsOneWidget);
    // Readiness is the host's to observe.
    expect(find.text(JamPeerRowStrings.loading), findsNothing);

    // No switches, no nearby setting — a summary of what the room allows.
    expect(find.byType(JamSwitch), findsNothing);
    expect(find.text(RoomSheetStrings.nearby), findsNothing);
    expect(find.text(JamPresetStrings.name(JamPolicy.open)), findsOneWidget);
    expect(find.text(JamPresetStrings.summary(JamPolicy.open)), findsOneWidget);
    expect(find.text(RoomSheetStrings.leaveJam), findsOneWidget);
    expect(find.text(RoomSheetStrings.endJam), findsNothing);
    // Guests can invite too, with the link they joined by.
    expect(find.text(RoomSheetStrings.invitePeople), findsOneWidget);

    await tester.runAsync(guest.leave);
    await tester.runAsync(host.leave);
  });

  testWidgets('a co-host with a blocked capability reads as plain words', (
    tester,
  ) async {
    final host = testSession();
    final guest = await _hostWithGuest(tester, host);
    final peerId = host.engine!.peers.first.peerId;
    host.hostEngine!
      ..promotePeer(peerId)
      ..setCapabilityOverride(peerId, JamCapability.addTracks, allowed: false);
    await tester.pump();

    await _pump(tester, host, _panel(host));
    expect(find.text('Co-host · Can’t add songs'), findsOneWidget);

    await tester.runAsync(guest.leave);
    await tester.runAsync(host.leave);
  });

  testWidgets('the per-guest menu flips one capability, and flips it back to '
      'the room default rather than pinning it', (tester) async {
    final host = testSession();
    final guest = await _hostWithGuest(tester, host);
    final peerId = host.engine!.peers.first.peerId;
    await _pump(tester, host, _panel(host));

    // `jam`: guests cannot control playback; the menu grants it to Ana.
    await tester.tap(find.byIcon(CupertinoIcons.ellipsis));
    await tester.pumpAndSettle();
    expect(find.text(RoomSheetStrings.makeCohost), findsOneWidget);
    await tester.tap(_menuItem(RoomSheetStrings.controlPlayback));
    await tester.pumpAndSettle();
    var permissions = host.engine!.permissions;
    expect(permissions.overrides[peerId]?[JamCapability.controlPlayback], true);
    expect(find.text('Can control playback'), findsOneWidget);

    // And back: the override goes, so a later policy change still reaches
    // her.
    await tester.tap(find.byIcon(CupertinoIcons.ellipsis));
    await tester.pumpAndSettle();
    await tester.tap(_menuItem(RoomSheetStrings.controlPlayback));
    await tester.pumpAndSettle();
    permissions = host.engine!.permissions;
    expect(permissions.overrides[peerId]?[JamCapability.controlPlayback], null);
    expect(find.text('Can control playback'), findsNothing);

    // Make Co-host.
    await tester.tap(find.byIcon(CupertinoIcons.ellipsis));
    await tester.pumpAndSettle();
    await tester.tap(find.text(RoomSheetStrings.makeCohost));
    await tester.pumpAndSettle();
    expect(host.engine!.permissions.roleOf(peerId), JamRole.cohost);
    expect(find.text(JamPeerRowStrings.cohost), findsOneWidget);

    await tester.runAsync(guest.leave);
    await tester.runAsync(host.leave);
  });

  testWidgets('faces are coloured by name, the same on every device (D3)', (
    tester,
  ) async {
    final host = testSession();
    // A guest whose own colour differs from the host's, so nobody is moved
    // off theirs.
    final name = [
      'Ana',
      'Mia',
      'Theo',
      'Okon',
      'Bea',
    ].firstWhere((n) => identityColor(n) != identityColor('Silky Puffin'));
    final guest = await _hostWithGuest(tester, host, name: name);

    Map<String, Color?> colors() => {
      for (final row in tester.widgetList<JamPeerRow>(find.byType(JamPeerRow)))
        row.name: row.color,
    };

    await _pump(tester, host, _panel(host));
    final fromHost = colors();
    expect(fromHost['Silky Puffin'], identityColor('Silky Puffin'));
    expect(fromHost[name], identityColor(name));
    // The colour reaches the face.
    expect(
      tester
          .widgetList<JamAvatar>(find.byType(JamAvatar))
          .map((a) => a.resolvedColor),
      containsAll(<Color>[identityColor('Silky Puffin'), identityColor(name)]),
    );

    await _pump(tester, guest, _panel(guest, self: name));
    final fromGuest = colors();
    expect(fromGuest[name], fromHost[name]);
    expect(
      fromGuest.entries.where((e) => e.key != name).single.value,
      fromHost['Silky Puffin'],
      reason: 'the host is the same colour from the guest\'s side',
    );

    await tester.runAsync(guest.leave);
    await tester.runAsync(host.leave);
  });

  testWidgets('docked on the backdrop: plain rows in white, no cards', (
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
      ColoredBox(
        color: const Color(0xFF7A1F4A),
        child: RoomPanel(
          engine: host.engine!,
          selfName: 'Silky Puffin',
          network: JamNetworkStatus.offline,
        ),
      ),
      theme: jamDarkTheme(),
    );

    // Every section is plain: no rounded card, so no one-row pills.
    final sections = tester.widgetList<JamSection>(find.byType(JamSection));
    expect(sections, isNotEmpty);
    expect(sections.every((s) => s.plain), isTrue);
    expect(find.byType(ClipRRect), findsNothing);
    // The backdrop's text: white titles, translucent white secondary.
    final colors = Theme.of(
      tester.element(find.text(RoomSheetStrings.invitePeople)),
    ).extension<JamColors>()!;
    expect(colors.label, JamNowPlayingColors.text);
    expect(colors.secondaryLabel, JamNowPlayingColors.secondary);
    expect(colors.groupedSurface.a, 0);
    // End Jam is lifted off system red, which sinks into a vivid cover.
    expect(colors.danger, isNot(JamColors.dark.danger));
    final invite = tester.widget<Text>(
      find.text(RoomSheetStrings.invitePeople),
    );
    expect(invite.style?.color, JamNowPlayingColors.text);

    // In its sheet the same panel keeps the grouped look.
    await _pump(
      tester,
      host,
      RoomPanel(
        engine: host.engine!,
        selfName: 'Silky Puffin',
        network: JamNetworkStatus.offline,
        inSheet: true,
      ),
    );
    expect(
      tester
          .widgetList<JamSection>(find.byType(JamSection))
          .every((s) => !s.plain),
      isTrue,
    );

    await tester.runAsync(host.leave);
  });

  testWidgets('a guest with no name is "Guest", and can be let back in', (
    tester,
  ) async {
    final host = testSession();
    final guest = await _hostWithGuest(tester, host, name: '');
    final peerId = host.engine!.peers.single.peerId;
    await _pump(tester, host, _panel(host));

    // Never the wire id standing in for a name.
    expect(find.text(kJamUnnamedPeer), findsOneWidget);
    expect(find.textContaining(peerId), findsNothing);
    expect(find.text(RoomSheetStrings.removed), findsNothing);

    // Removed: listed by the same friendly name, with the one way back in
    // (§5.6 — a removed device stays out until then).
    await tester.runAsync(() async {
      host.hostEngine!.kickPeer(peerId);
      expect(await _waitFor(() => host.engine!.peers.isEmpty), isTrue);
    });
    await tester.pump();
    expect(find.text(RoomSheetStrings.removed), findsOneWidget);
    expect(find.text(RoomSheetStrings.removedDetail), findsOneWidget);
    expect(find.text(kJamUnnamedPeer), findsOneWidget);
    expect(find.text(RoomSheetStrings.letBackIn), findsOneWidget);
    // One element a screen reader can press, saying whom and what.
    final semantics = tester.ensureSemantics();
    await tester.pump();
    final node = tester
        .getSemantics(find.text(RoomSheetStrings.letBackIn))
        .getSemanticsData();
    expect(node.label, contains(kJamUnnamedPeer));
    expect(node.label, contains(RoomSheetStrings.letBackIn));
    expect(node.hasAction(SemanticsAction.tap), isTrue);
    expect(node.flagsCollection.isButton, isTrue);
    semantics.dispose();

    await tester.tap(find.text(RoomSheetStrings.letBackIn));
    await tester.pump();
    expect(host.hostEngine!.kickedPeers, isEmpty);
    expect(find.text(RoomSheetStrings.removed), findsNothing);

    await tester.runAsync(guest.leave);
    await tester.runAsync(host.leave);
  });

  testWidgets('removing someone says what a removal is: out until you let '
      'them back in', (tester) async {
    final host = testSession();
    final guest = await _hostWithGuest(tester, host);
    await _pump(tester, host, _panel(host));

    await tester.tap(find.byIcon(CupertinoIcons.ellipsis));
    await tester.pumpAndSettle();
    await tester.tap(find.text(RoomSheetStrings.removePeer));
    await tester.pumpAndSettle();
    expect(find.text(RoomSheetStrings.removeTitle('Ana')), findsOneWidget);
    // The app identifies its device when it joins, so the host can keep it
    // out — and the alert can say so.
    expect(
      host.hostEngine!.kickKeepsOut(host.engine!.peers.single.peerId),
      true,
    );
    expect(find.text(RoomSheetStrings.removeDetailHeld), findsOneWidget);
    expect(find.textContaining('room code'), findsNothing);

    await tester.tap(find.text(RoomSheetStrings.remove));
    await tester.pumpAndSettle();
    await tester.runAsync(() => _waitFor(() => host.engine!.peers.isEmpty));
    await tester.pump();
    expect(host.hostEngine!.kickedPeers.single.clientName, 'Ana');
    expect(find.text(RoomSheetStrings.letBackIn), findsOneWidget);

    await tester.runAsync(guest.leave);
    await tester.runAsync(host.leave);
  });

  testWidgets('a guest that never said who it is gets the softer removal '
      'wording: nothing can keep it out', (tester) async {
    final host = testSession();
    late JamGuestClient bare;
    await tester.runAsync(() async {
      await host.startHost(sessionName: 'Van Jam', discoverable: false);
      // A client with no `hello.clientId` (an old CLI, a third-party tool).
      bare = await JamGuestClient.connect(
        host.hostEngine!.joinUriFor(InternetAddress.loopbackIPv4),
        clientName: 'Terminal',
        clientKind: 'cli',
      );
      expect(await _waitFor(() => host.engine!.peers.isNotEmpty), isTrue);
    });
    await tester.pump();
    await _pump(tester, host, _panel(host));
    expect(host.hostEngine!.kickKeepsOut(bare.selfPeerId), isFalse);

    await tester.tap(find.byIcon(CupertinoIcons.ellipsis));
    await tester.pumpAndSettle();
    await tester.tap(find.text(RoomSheetStrings.removePeer));
    await tester.pumpAndSettle();
    expect(find.text(RoomSheetStrings.removeDetail), findsOneWidget);
    expect(find.text(RoomSheetStrings.removeDetailHeld), findsNothing);
    expect(RoomSheetStrings.removeDetail, isNot(contains('rejoin')));
    await tester.tap(find.text(RoomSheetStrings.cancel));
    await tester.pumpAndSettle();

    await tester.runAsync(bare.close);
    await tester.runAsync(host.leave);
  });

  testWidgets('the host shows and hides the jam to people nearby from the '
      'People sheet', (tester) async {
    // No mDNS in a widget test: an advertiser that answers at once.
    var live = 0;
    JamHostEngine.roomAdvertiserStarter =
        ({
          required String sessionName,
          required int port,
          required String token,
          String? hostName,
          List<InternetAddress> addresses = const [],
          Duration timeout = JamRoomAdvertiser.defaultTimeout,
        }) async {
          live++;
          return JamRoomAdvertiser.fake(onStop: () async => live--);
        };
    addTearDown(
      () => JamHostEngine.roomAdvertiserStarter = JamRoomAdvertiser.start,
    );
    final host = testSession();
    await tester.runAsync(
      () => host.startHost(sessionName: 'Van Jam', discoverable: false),
    );
    await tester.pump();
    await _pump(tester, host, _panel(host));
    final engine = host.hostEngine!;
    Finder nearbySwitch() => find.descendant(
      of: find.widgetWithText(JamRow, RoomSheetStrings.nearby),
      matching: find.byType(JamSwitch),
    );
    expect(tester.widget<JamSwitch>(nearbySwitch()).value, isFalse);

    await tester.tap(nearbySwitch());
    expect(engine.discoveryEnabled, isTrue, reason: 'at once, for the UI');
    // The advertisement catches up across both zones the test runs in.
    for (var i = 0; i < 50 && !engine.discoverable; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump();
    }
    expect(engine.discoverable, isTrue);
    expect(live, 1);
    expect(tester.widget<JamSwitch>(nearbySwitch()).value, isTrue);
    expect(find.text(RoomSheetStrings.nearbyOnFooter), findsOneWidget);
    expect(find.text(RoomSheetStrings.nearbyOffFooter), findsNothing);

    // A change made elsewhere (the docked panel, the engine) shows here too.
    await tester.runAsync(() => engine.setDiscoverable(false));
    await tester.pump();
    expect(tester.widget<JamSwitch>(nearbySwitch()).value, isFalse);
    expect(find.text(RoomSheetStrings.nearbyOffFooter), findsOneWidget);
    expect(live, 0, reason: 'withdrawn');

    await tester.runAsync(host.leave);
  });

  testWidgets('letting in someone already let back in elsewhere just '
      'redraws — it is not a failure', (tester) async {
    final host = testSession();
    final heard = <String>[];
    final sub = host.notices.listen((n) => heard.add(n.message));
    addTearDown(sub.cancel);
    final guest = await _hostWithGuest(tester, host);
    final peerId = host.engine!.peers.single.peerId;
    await tester.runAsync(() async {
      host.hostEngine!.kickPeer(peerId);
      expect(await _waitFor(() => host.engine!.peers.isEmpty), isTrue);
    });
    await _pump(tester, host, _panel(host));
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

  testWidgets('the People sheet opens at the medium detent, on the dark '
      'palette, and Invite People opens the Invite sheet', (tester) async {
    fakeLan([
      FakeInterface('en0', ['192.168.77.10']),
    ]);
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
    expect(sheet.initialChildSize, kJamSheetMediumSize);
    expect(sheet.maxChildSize, greaterThan(0.9));
    expect(find.text(RoomSheetStrings.title), findsOneWidget);
    expect(find.text(RoomSheetStrings.done), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text(RoomSheetStrings.invitePeople));
    await tester.pumpAndSettle();
    expect(find.text(RoomSheetStrings.inviteTitle), findsWidgets);
    expect(find.byType(QrImageView), findsOneWidget);
    // Closed with the same trailing Done as every sheet (CR-24).
    expect(find.text(JamSheetStrings.done), findsWidgets);
    expect(find.byIcon(CupertinoIcons.xmark), findsNothing);

    await tester.runAsync(host.leave);
  });

  testWidgets('the Invite sheet: the code on white, the name, Share and Copy, '
      'and never the machine text', (tester) async {
    fakeLan([
      FakeInterface('en0', ['192.168.77.10']),
    ]);
    final host = testSession();
    final heard = <String>[];
    final sub = host.notices.listen((n) => heard.add(n.message));
    addTearDown(sub.cancel);
    String? copied;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String?;
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );

    await tester.runAsync(
      () => host.startHost(sessionName: 'Van Jam', discoverable: false),
    );
    await tester.pump();
    await _pump(
      tester,
      host,
      InvitePanel(engine: host.engine!, network: JamNetworkStatus.offline),
    );

    expect(find.byType(QrImageView), findsOneWidget);
    final qr = tester.widget<QrImageView>(find.byType(QrImageView));
    expect(qr.backgroundColor, const Color(0xFFFFFFFF));
    expect(find.text('Van Jam'), findsOneWidget);
    expect(find.text(RoomSheetStrings.inviteOnNetwork), findsOneWidget);
    expect(find.text(RoomSheetStrings.shareLink), findsOneWidget);
    expect(find.text(RoomSheetStrings.copyLink), findsOneWidget);
    expect(find.textContaining('localjam://'), findsNothing);
    expect(find.textContaining('http://'), findsNothing);
    // The code is the http form (§1, 1.2): a camera opens it with no app.
    expect(find.byKey(ValueKey('${host.joinUri}')), findsOneWidget);
    expect('${host.joinUri}', startsWith('http://'));

    await tester.tap(find.text(RoomSheetStrings.copyLink));
    await tester.pump();
    await tester.runAsync(pumpEventQueue);
    await tester.pump();
    expect(copied, '${host.joinUri}');
    // Confirmed in place, not by a toast over Share Link.
    expect(heard, isEmpty);
    expect(find.text(RoomSheetStrings.copied), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.checkmark), findsOneWidget);
    expect(find.text(RoomSheetStrings.copyLink), findsNothing);
    await tester.pump(const Duration(milliseconds: 1600));
    expect(find.text(RoomSheetStrings.copyLink), findsOneWidget);
    expect(find.text(RoomSheetStrings.copied), findsNothing);

    await tester.runAsync(host.leave);
  });

  testWidgets('the host\'s Invite promises a browser player only while the '
      'room serves one', (tester) async {
    fakeLan([
      FakeInterface('en0', ['192.168.77.10']),
    ]);
    final player = StaticSite({
      'index.html': StaticFile.text('<p>', 'text/html; charset=utf-8'),
    });

    // A build without the player: its rooms answer the link with "install
    // the app", so the sheet says nothing about a browser.
    final plain = testSession();
    await tester.runAsync(
      () => plain.startHost(sessionName: 'Van Jam', discoverable: false),
    );
    await _pump(
      tester,
      plain,
      InvitePanel(engine: plain.engine!, network: JamNetworkStatus.offline),
    );
    expect(find.text(RoomSheetStrings.inviteOnNetwork), findsOneWidget);
    expect(find.text(RoomSheetStrings.inviteInBrowser), findsNothing);
    await tester.runAsync(plain.leave);

    final host = testSession(webGuest: WebGuestBundle.loaded(player));
    final guest = await _hostWithGuest(tester, host);
    expect(host.servesWebPlayer.value, isTrue);
    await _pump(
      tester,
      host,
      InvitePanel(engine: host.engine!, network: JamNetworkStatus.offline),
    );
    expect(find.text(RoomSheetStrings.inviteInBrowser), findsOneWidget);
    // The caption already says to scan; the line adds only the browser.
    expect(
      RoomSheetStrings.inviteInBrowser,
      'No app needed: the link opens in the browser.',
    );
    expect(RoomSheetStrings.inviteInBrowser, isNot(contains('Scan')));
    // Under the code, after the caption.
    expect(
      tester.getTopLeft(find.text(RoomSheetStrings.inviteInBrowser)).dy,
      greaterThan(
        tester.getBottomLeft(find.text(RoomSheetStrings.inviteOnNetwork)).dy,
      ),
    );

    // A guest cannot know what the host's room serves: no promise.
    await _pump(
      tester,
      guest,
      InvitePanel(engine: guest.engine!, network: JamNetworkStatus.offline),
    );
    expect(find.text(RoomSheetStrings.inviteOnNetwork), findsOneWidget);
    expect(find.text(RoomSheetStrings.inviteInBrowser), findsNothing);

    await tester.runAsync(guest.leave);
    await tester.runAsync(host.leave);
  });

  testWidgets('the Invite sheet shows the jam: its mark with the host\'s '
      'face, its name once, and who else is in it, host first', (tester) async {
    fakeLan([
      FakeInterface('en0', ['192.168.77.10']),
    ]);
    final host = testSession();
    final guest = await _hostWithGuest(tester, host);
    await _pump(
      tester,
      guest,
      InvitePanel(
        engine: guest.engine!,
        network: JamNetworkStatus.offline,
        selfName: 'Ana',
      ),
    );
    final mark = tester.widget<JamMark>(find.byType(JamMark));
    expect(mark.name, 'Van Jam');
    expect(mark.hostName, 'Silky Puffin');
    expect(find.text('Van Jam'), findsOneWidget);
    // Said as the room's footer says it: the others, from your side.
    expect(find.text('With Silky Puffin'), findsOneWidget);

    // The host's own Invite: no face of their own on their own jam (R5).
    await _pump(
      tester,
      host,
      InvitePanel(
        engine: host.engine!,
        network: JamNetworkStatus.offline,
        selfName: 'Silky Puffin',
      ),
    );
    expect(tester.widget<JamMark>(find.byType(JamMark)).hostName, isNull);
    expect(find.text('With Ana'), findsOneWidget);

    await tester.runAsync(guest.leave);
    await tester.runAsync(host.leave);
  });

  testWidgets('two people with one name are two people: told apart in the '
      'roster, the People sheet and their colours', (tester) async {
    final host = testSession();
    await tester.runAsync(() async {
      await host.startHost(sessionName: 'Van Jam', discoverable: false);
      final uri = host.hostEngine!.joinUriFor(InternetAddress.loopbackIPv4);
      for (final name in ['Sam', 'Sam', '']) {
        final client = await JamGuestClient.connect(uri, clientName: name);
        addTearDown(client.close);
      }
      expect(await _waitFor(() => host.engine!.peers.length == 3), isTrue);
    });
    final engine = host.engine!;
    final names = jamRosterNames(engine, selfName: 'Silky Puffin');
    expect(names.first, 'Silky Puffin');
    expect(names.skip(1).toSet(), {'Sam', 'Sam 2', kJamUnnamedPeer});
    final colors = jamRosterColors(engine, selfName: 'Silky Puffin');
    final sams = [
      for (final peer in engine.peers)
        if (peer.clientName == 'Sam') colors[peer.peerId],
    ];
    expect(sams.toSet(), hasLength(2), reason: 'one colour each');

    // Before this device's own name has loaded, its placeholder "You" is
    // left out of the assignment: nobody else's colour depends on it
    // (RB-20).
    final early = jamRosterColors(engine, selfName: '');
    final others = jamPeopleColors(names.skip(1));
    for (final peer in engine.peers) {
      final name = jamRosterNamesById(engine, selfName: '')[peer.peerId]!;
      expect(early[peer.peerId], others[name], reason: name);
    }

    await _pump(tester, host, _panel(host));
    expect(find.text('Sam'), findsOneWidget);
    expect(find.text('Sam 2'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(host.leave);
  });

  test('who else is in the jam, said as every screen says it', () {
    expect(jamPeopleSummary(const []), 'Just you');
    expect(jamPeopleSummary(['Bibek']), 'With Bibek');
    expect(
      jamPeopleSummary(['Bibek', 'Mia', 'Theo']),
      'With Bibek, Mia and Theo',
    );
    expect(
      jamPeopleSummary(['Bibek', 'Mia', 'Theo', 'Ana', 'Okon']),
      'With Bibek, Mia and 3 others',
    );
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
      InvitePanel(engine: engine, network: JamNetworkStatus.offline),
    );
    expect(find.byType(QrImageView), findsNothing);
    expect(find.text(RoomSheetStrings.noNetworkTitle), findsOneWidget);
    expect(find.text(RoomSheetStrings.shareLink), findsNothing);
    // The jam is still the jam above it: its mark and its name (CR-23).
    expect(find.byType(JamMark), findsOneWidget);
    expect(find.text('Van Jam'), findsOneWidget);

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

    // The phone moves to another network: the code follows the link.
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

  testWidgets('a guest who came in by a localjam:// link passes on the '
      'http form', (tester) async {
    final host = testSession();
    final guest = await _hostWithGuest(tester, host, viaDeepLink: true);
    expect(guest.guestEngine!.joinUri.scheme, 'localjam');
    await _pump(
      tester,
      guest,
      InvitePanel(engine: guest.engine!, network: JamNetworkStatus.offline),
    );
    final http = JoinLink.fromUri(guest.guestEngine!.joinUri)!.toHttpUri();
    expect(http.scheme, 'http');
    expect(find.byKey(ValueKey('$http')), findsOneWidget);

    await tester.runAsync(guest.leave);
    await tester.runAsync(host.leave);
  });

  testWidgets('a guest invites with the link they joined by', (tester) async {
    final host = testSession();
    final guest = await _hostWithGuest(tester, host);
    await _pump(
      tester,
      guest,
      InvitePanel(engine: guest.engine!, network: JamNetworkStatus.offline),
    );
    expect(
      find.byKey(ValueKey('${guest.guestEngine!.joinUri}')),
      findsOneWidget,
    );
    expect(find.text('Van Jam'), findsOneWidget);

    await tester.runAsync(guest.leave);
    await tester.runAsync(host.leave);
  });

  testWidgets('ending the jam with the Invite sheet open: a part of it built '
      'again on the way out reads the last code, it does not subscribe', (
    tester,
  ) async {
    // 2026-10-17 run: a sheet animating away built the code again after the
    // engine had released its listenables, and a fresh subscription tripped
    // "ValueNotifier used after being disposed".
    fakeLan([
      FakeInterface('en0', ['192.168.77.10']),
    ]);
    final host = testSession();
    await tester.runAsync(
      () => host.startHost(sessionName: 'Van Jam', discoverable: false),
    );
    await tester.pump();
    final engine = host.hostEngine!;
    Widget panel(int generation) => InvitePanel(
      // A new key mounts everything afresh, as a rebuilt sheet does.
      key: ValueKey(generation),
      engine: engine,
      network: JamNetworkStatus.offline,
    );
    await _pump(tester, host, panel(1));
    expect(find.byType(QrImageView), findsOneWidget);
    expect(find.byType(ValueListenableBuilder<Uri>), findsOneWidget);

    await tester.runAsync(host.leave);
    expect(engine.sessionEnded.value, JamSessionEndReason.closedLocally);

    await _pump(tester, host, panel(2));
    expect(tester.takeException(), isNull);
    expect(find.byType(QrImageView), findsOneWidget, reason: 'the last code');
    expect(find.byType(ValueListenableBuilder<Uri>), findsNothing);
    expect(
      find.byType(ValueListenableBuilder<List<InternetAddress>>),
      findsNothing,
    );
  });

  testWidgets('the People page survives the end of the jam it shows', (
    tester,
  ) async {
    final host = testSession();
    await tester.runAsync(
      () => host.startHost(sessionName: 'Van Jam', discoverable: false),
    );
    await tester.pump();
    await _pump(tester, host, _panel(host));
    await tester.runAsync(host.leave);
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.byType(ValueListenableBuilder<List<PeerInfo>>), findsNothing);
  });

  testWidgets('at 1.3x text on a phone, nothing clips', (tester) async {
    fakeLan([
      FakeInterface('en0', ['192.168.77.10']),
    ]);
    // With the browser player, so its line under the code is laid out too.
    final host = testSession(
      webGuest: WebGuestBundle.loaded(
        StaticSite({
          'index.html': StaticFile.text('<p>', 'text/html; charset=utf-8'),
        }),
      ),
    );
    final guest = await _hostWithGuest(
      tester,
      host,
      name: 'Anastasia Montgomery',
    );
    tester.view.physicalSize =
        const Size(375, 812) * tester.view.devicePixelRatio;
    addTearDown(tester.view.resetPhysicalSize);
    for (final child in <Widget>[
      _panel(host),
      SingleChildScrollView(
        child: InvitePanel(
          engine: host.engine!,
          network: JamNetworkStatus.offline,
        ),
      ),
    ]) {
      await tester.pumpWidget(
        JamSession(
          controller: host,
          child: MaterialApp(
            theme: jamLightTheme(),
            home: MediaQuery(
              data: const MediaQueryData(
                size: Size(375, 812),
                textScaler: TextScaler.linear(1.3),
              ),
              child: Scaffold(body: child),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
    }

    await tester.runAsync(guest.leave);
    await tester.runAsync(host.leave);
  });

  group('Share my music library', () {
    testWidgets('is the host’s, and live: on asks for the library and '
        'shares it, off stops at once', (tester) async {
      var asked = 0;
      _libraryHere(JamPermissionOutcome.granted, onAsk: () => asked++);
      final host = testSession(librarySource: _Library.new);
      await tester.runAsync(
        () => host.startHost(sessionName: 'Van Jam', discoverable: false),
      );
      await tester.pump();
      await _pump(tester, host, _panel(host));
      final engine = host.hostEngine!;

      // An invite-only jam where guests add songs.
      expect(
        find.text('People in the jam can see your song titles and add them'),
        findsOneWidget,
      );
      expect(tester.widget<JamSwitch>(_shareSwitch()).value, isFalse);
      expect(engine.catalog.value, isNull, reason: 'off by default');

      await tester.tap(_shareSwitch());
      await _settle(tester, () => engine.catalog.value != null);
      await tester.pump();
      expect(asked, 1);
      expect(engine.catalog.value?.count, 1);
      expect(tester.widget<JamSwitch>(_shareSwitch()).value, isTrue);

      await tester.tap(_shareSwitch());
      await _settle(tester, () => engine.catalog.value == null);
      await tester.pump();
      expect(engine.catalog.value, isNull);
      expect(tester.widget<JamSwitch>(_shareSwitch()).value, isFalse);
      expect(asked, 1, reason: 'turning it off asks for nothing');

      await tester.runAsync(host.leave);
    });

    testWidgets('a denied permission leaves it off, and says so', (
      tester,
    ) async {
      _libraryHere(JamPermissionOutcome.permanentlyDenied);
      final host = testSession(librarySource: _Library.new);
      final heard = <JamNotice>[];
      final sub = host.notices.listen(heard.add);
      addTearDown(sub.cancel);
      await tester.runAsync(
        () => host.startHost(sessionName: 'Van Jam', discoverable: false),
      );
      await tester.pump();
      await _pump(tester, host, _panel(host));

      await tester.tap(_shareSwitch());
      await _settle(tester, () => heard.isNotEmpty);
      await tester.pump();
      expect(host.hostEngine!.catalog.value, isNull);
      expect(tester.widget<JamSwitch>(_shareSwitch()).value, isFalse);
      final notice = heard.singleWhere(
        (n) => n.message == JamPermissionCopy.audioLibraryDenied,
      );
      expect(notice.actionLabel, JamPermissionCopy.openSettings);

      await tester.runAsync(host.leave);
    });

    testWidgets('is not offered where the phone has no library to share', (
      tester,
    ) async {
      debugJamLibraryAvailable = false;
      addTearDown(() => debugJamLibraryAvailable = null);
      final host = testSession(librarySource: _Library.new);
      await tester.runAsync(
        () => host.startHost(sessionName: 'Van Jam', discoverable: false),
      );
      await tester.pump();
      await _pump(tester, host, _panel(host));
      expect(find.text(RoomSheetStrings.shareLibrary), findsNothing);
      await tester.runAsync(host.leave);
    });

    testWidgets('a guest has no such switch', (tester) async {
      _libraryHere(JamPermissionOutcome.granted);
      final host = testSession();
      final guest = await _hostWithGuest(tester, host);
      await _pump(tester, guest, _panel(guest, self: 'Ana'));
      expect(find.text(RoomSheetStrings.shareLibrary), findsNothing);
      await tester.runAsync(() async {
        await guest.leave();
        await host.leave();
      });
    });
  });
}
