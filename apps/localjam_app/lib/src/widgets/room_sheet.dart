/// The room's people, and the way to let more in (DESIGN_SPEC v3 §6.5).
///
/// Two sheets where there used to be one long page:
///
/// * **People** ([showRoomSheet], [RoomPanel]) — a grouped list: Invite
///   People, who is here (with the host's per-guest "•••"), anyone removed,
///   what guests can do, the host's Show to People Nearby switch, and the
///   way out in its own last section.
/// * **Invite** ([showInviteSheet], [InvitePanel]) — the jam itself (its
///   mark: the cover playing and the host's face; its name; who is in it),
///   the QR on a white plate, Share Link and Copy Link. With no network
///   there is no code to show, and the sheet says what would make one.
///
/// Header rule (§10.2): People closes with **Done**; Invite, which edits
/// nothing, with a trailing glass xmark only.
///
/// The join URI never appears as text: `localjam://join?token=…` is machine
/// text on a page about people.
library;

import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show ValueListenable, debugPrint;
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:localjam_client/localjam_client.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../design/theme.dart';
import '../design/tokens.dart';
import '../design/typography.dart';
import '../state/session_controller.dart';
import '../util/format.dart';
import '../util/network.dart';
import 'buttons.dart';
import 'dialogs.dart';
import 'empty_state.dart';
import 'guests_can.dart';
import 'jam_mark.dart';
import 'list.dart';
import 'menu.dart';
import 'avatar.dart';
import 'peer_row.dart';
import 'section.dart';
import 'sheet.dart';

/// Everything these sheets say out loud.
abstract final class RoomSheetStrings {
  // People sheet.
  static const String title = 'People';
  static const String done = 'Done';
  static const String invitePeople = 'Invite People';

  /// The people section's header: "3 people".
  static String peopleCount(int n) => n == 1 ? '1 person' : '$n people';

  /// The host's row when this device is a guest and the host shared no
  /// display name.
  static const String host = 'Host';

  // What guests can do: every word lives in `JamPresetStrings`, so the
  // switches, the per-guest menu and the footer never disagree.
  static const String addMusic = JamPresetStrings.addSongs;
  static const String controlPlayback = JamPresetStrings.controlPlayback;
  static const String editQueue = JamPresetStrings.editQueue;

  // Whether people nearby can see the jam: chosen in Start a Jam, and the
  // host's to change while it runs. Same words as Start a Jam's switch.
  static const String nearby = 'Show to People Nearby';
  static const String nearbyOnFooter =
      'People on this Wi‑Fi can see and join this jam.';
  static const String nearbyOffFooter =
      'Only people with the link or the code can join.';

  // The per-guest menu.
  static const String makeCohost = 'Make Co-host';
  static const String removeCohost = 'Remove Co-host';
  static const String removePeer = 'Remove from Jam';
  static const String cancel = 'Cancel';
  static const String remove = 'Remove';
  static String removeTitle(String name) => 'Remove $name?';

  /// What removing someone does for certain. Whether the device also stays
  /// out depends on whether it identified itself when it joined
  /// ([JamHostEngine.kickKeepsOut]): every LocalJam app does, a bare client
  /// may not. [removeDetailHeld] when it did; this when it didn't, so the
  /// alert never promises a hold the room can't keep.
  static const String removeDetail = 'They’ll stop hearing the jam right away.';
  static const String removeDetailHeld =
      'They’ll stop hearing the jam right away. They can’t rejoin until you '
      'let them back in.';

  /// The subtitle words for what the host changed for one person.
  static String capabilityDetail(JamCapability capability, bool allowed) =>
      switch ((capability, allowed)) {
        (JamCapability.addTracks, false) => 'can’t add songs',
        (JamCapability.addTracks, true) => 'can add songs',
        (JamCapability.controlPlayback, false) => 'can’t control playback',
        (JamCapability.controlPlayback, true) => 'can control playback',
        (JamCapability.editQueue, false) => 'can’t edit the queue',
        (JamCapability.editQueue, true) => 'can edit the queue',
        _ => '',
      };

  // Removed people.
  static const String removed = 'Removed';
  static const String removedDetail =
      'They can’t rejoin until you let them back in.';
  static const String letBackIn = 'Let Back In';
  static String letBackInDone(String name) => '$name can join again';

  /// A host action the room refused — never the exception's own text.
  static const String actionFailed = 'Couldn’t change that. Try again.';

  // The way out.
  static const String endJam = 'End Jam';
  static const String leaveJam = 'Leave Jam';
  static const String endTitle = 'End Jam?';
  static const String endDetail = 'The music stops for everyone.';

  /// End Jam with nobody else here: there is no "everyone" to stop.
  static const String endDetailAlone = 'This ends the jam.';
  static const String leaveTitle = 'Leave Jam?';
  static const String leaveDetail =
      'You can rejoin as long as the jam is still going.';
  static const String leave = 'Leave';

  // Invite sheet.
  static const String inviteTitle = 'Invite People';
  static const String inviteOnNetwork =
      'Anyone on this Wi‑Fi can scan to join.';
  static const String inviteOnHotspot =
      'People join your hotspot first, then scan to join.';
  static String qrLabel(String room) => 'Code to join $room';

  /// Who is in the jam, under its name on the Invite sheet — the host
  /// first: "Bibek", "Bibek and Mia", "Bibek, Mia and Theo", "Bibek, Mia
  /// and 3 others".
  static String everyone(List<String> names) {
    if (names.isEmpty) return '';
    if (names.length == 1) return names.single;
    if (names.length == 2) return '${names[0]} and ${names[1]}';
    if (names.length == 3) return '${names[0]}, ${names[1]} and ${names[2]}';
    final others = names.length - 2;
    return '${names[0]}, ${names[1]} and $others others';
  }

  static const String shareLink = 'Share Link';
  static const String copyLink = 'Copy Link';

  /// Copy Link's label for a moment after it worked — the confirmation
  /// happens in place, not in a toast over the buttons (§10.5).
  static const String copied = 'Copied';
  static const String shareFailed = 'Couldn’t open the share sheet.';

  /// No Wi-Fi and no hotspot: there is no address a guest could reach, so
  /// there is no code to show. The engine re-checks every couple of seconds
  /// and the code appears by itself once a network does.
  static const String noNetworkTitle = 'No Network';
  static const String noNetworkDetail =
      'Connect to Wi‑Fi or turn on your hotspot. The code shows up here '
      'as soon as there’s a network to share.';

  /// What the OS share sheet is handed: a sentence, with the URI on a line
  /// of its own so the OS still linkifies it.
  static String shareSubject(String room) => 'Join $room on LocalJam';
  static String shareText(String room, Uri uri) =>
      'Join $room on LocalJam — same Wi‑Fi, no internet needed.\n$uri';
}

/// The QR's geometry (§6.5): a 220 code on a white plate, 16 padding,
/// radius 20.
const double _qrSize = 220;
const double _platePadding = JamSpace.lg;
const double _plateRadius = 20;

/// Opens the People sheet.
Future<void> showRoomSheet(
  BuildContext context,
  JamEngine engine, {
  required String selfName,
  required JamNetworkStatus network,
}) => showJamSheet<void>(
  context,
  title: RoomSheetStrings.title,
  actions: const JamSheetActions.done(),
  grouped: true,
  initialChildSize: kJamSheetMediumSize,
  builder: (_) => RoomPanel(
    engine: engine,
    selfName: selfName,
    network: network,
    inSheet: true,
  ),
);

/// Opens the Invite sheet: the code, Share Link and Copy Link.
Future<void> showInviteSheet(
  BuildContext context,
  JamEngine engine, {
  required String selfName,
  required JamNetworkStatus network,
}) => showJamSheet<void>(
  context,
  title: RoomSheetStrings.inviteTitle,
  actions: const JamSheetActions.close(),
  grouped: true,
  // Sized to its content: the code, two buttons, nothing to scroll — except
  // at large text sizes, where it scrolls rather than clips.
  scrollable: false,
  builder: (_) => SingleChildScrollView(
    child: InvitePanel(engine: engine, network: network, selfName: selfName),
  ),
);

/// Who is here and what they may do — the People sheet's body on phones and
/// the docked panel on wide windows.
class RoomPanel extends StatefulWidget {
  const RoomPanel({
    super.key,
    required this.engine,
    required this.selfName,
    required this.network,
    this.scrollController,
    this.inSheet = false,
    this.onBackdrop,
  });

  final JamEngine engine;

  /// This device's display name — the engine knows peers, not itself.
  final String selfName;

  final JamNetworkStatus network;

  /// Supplied by a DraggableScrollableSheet; when null the enclosing sheet's
  /// controller is picked up from [JamSheetScrollController].
  final ScrollController? scrollController;

  /// Whether this panel is inside a modal sheet, which the Leave row has to
  /// close on its way out. False when docked beside the player.
  final bool inSheet;

  /// Whether the panel sits on the Now Playing backdrop (docked beside the
  /// player on wide windows). Defaults to `!inSheet`: the docked panel is
  /// the only place a RoomPanel appears outside its sheet.
  ///
  /// On the backdrop the panel drops the grouped look — opaque cards there
  /// read as Settings pasted onto the cover's colours, and one-row cards
  /// turn into pills — for plain rows on the panel's shade, in the backdrop's
  /// white text, like Up Next beside it.
  final bool? onBackdrop;

  @override
  State<RoomPanel> createState() => _RoomPanelState();
}

class _RoomPanelState extends State<RoomPanel> {
  final List<StreamSubscription<Object?>> _subs = [];

  bool get _onBackdrop => widget.onBackdrop ?? !widget.inSheet;

  JamEngine get _engine => widget.engine;
  JamHostEngine? get _host =>
      _engine is JamHostEngine ? _engine as JamHostEngine : null;

  @override
  void initState() {
    super.initState();
    void refresh(Object? _) {
      if (mounted) setState(() {});
    }

    _subs
      ..add(_engine.permissionUpdates.listen(refresh))
      ..add(_engine.states.listen(refresh));
    final guest = _engine;
    if (guest is JamGuestEngine) {
      _subs.add(guest.peerEvents.listen(refresh));
    } else {
      _subs.add(_host!.events.listen(refresh));
    }
    // The end rebuilds the page off the engine's listenables (see
    // [_whileLive]) before the engine releases them.
    if (_engine.sessionEnded.value == null) {
      _engine.sessionEnded.addListener(_onEnded);
    }
  }

  void _onEnded() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _engine.sessionEnded.removeListener(_onEnded);
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    super.dispose();
  }

  /// Runs a host mutation that may throw (a peer who left between the menu
  /// opening and the tap, a policy the server refused). The exception is for
  /// the log; the person gets a sentence.
  void _guarded(void Function() action) {
    try {
      action();
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('localjam: host action failed: $e');
      if (!mounted) return;
      JamSession.read(
        context,
      ).notify(RoomSheetStrings.actionFailed, tone: JamNoticeTone.error);
    }
  }

  void _invite() => unawaited(
    showInviteSheet(
      context,
      _engine,
      selfName: widget.selfName,
      network: widget.network,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final host = _host;
    final peers = _engine.peers;
    final permissions = _engine.permissions;
    final isHost = host != null;
    final mediaId = _engine.snapshot.mediaId;
    final readinessById = isHost && mediaId != null
        ? host.peerMediaStates(mediaId)
        : const <String, MediaReadiness>{};
    final selfId = isHost ? JamPermissions.hostPeerId : _engine.selfPeerId;

    // A guest's `peers` holds neither this device nor the host, so the room
    // is two people bigger than the list from that side.
    final count = peers.length + (isHost ? 1 : 2);

    // Coloured over the same ordered names as the face pile, so a person
    // is one colour on every screen of the jam (§10.10, D3).
    final faces = jamRosterColors(_engine, selfName: widget.selfName);
    Color? faceOf(String peerId) => faces[peerId];

    final people = <Widget>[
      // This device first, so you can see your own standing.
      JamPeerRow(
        name: widget.selfName,
        color: faceOf(_engine.selfPeerId),
        role: isHost
            ? JamPeerRole.host
            : _roleOf(permissions.roleOf(_engine.selfPeerId)),
        isYou: true,
        detail: isHost ? null : _overrideDetail(permissions, selfId),
      ),
      // The host holds the reserved peer id and is never in `peers`, so a
      // guest puts them back or the room looks a person short.
      if (!isHost)
        JamPeerRow(
          name: _hostName(_engine),
          color: faceOf(_engine.hostPeer?.peerId ?? JamPermissions.hostPeerId),
          role: JamPeerRole.host,
        ),
      for (final peer in peers)
        JamPeerRow(
          name: jamPeerName(peer),
          color: faceOf(peer.peerId),
          role: _roleOf(permissions.roleOf(peer.peerId)),
          detail: _overrideDetail(permissions, peer.peerId),
          // Only the host can observe whether somebody actually has the
          // track; a guest would be guessing.
          readiness: isHost ? _readiness(readinessById[peer.peerId]) : null,
          fetchProgress: _fetchProgress(host, peer.peerId, mediaId),
          menu: isHost ? _peerMenu(host, peer, permissions) : null,
        ),
    ];

    final plain = _onBackdrop;
    final sections = <Widget>[
      _section(
        plain: plain,
        children: [
          JamRow(
            title: RoomSheetStrings.invitePeople,
            icon: CupertinoIcons.person_badge_plus,
            tinted: true,
            onTap: _invite,
          ),
        ],
      ),
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _section(
            plain: plain,
            header: RoomSheetStrings.peopleCount(count),
            children: people,
          ),
          if (isHost)
            _Removed(
              host: host,
              plain: plain,
              onLetBackIn: (peer) => _guarded(() {
                // False when they were already let back in from somewhere else
                // (another sheet, the docked panel): what the tap asked for is
                // true, so there is nothing to report.
                if (!host.unkickPeer(peer.peerId)) return;
                JamSession.read(context).notify(
                  RoomSheetStrings.letBackInDone(jamPeerName(peer)),
                  tone: JamNoticeTone.done,
                );
              }),
            ),
        ],
      ),
      if (isHost)
        _GuestsCan(
          plain: plain,
          policy: permissions.policy,
          onChanged: (policy) => _guarded(() => host.setPolicy(policy)),
        )
      else
        _section(
          plain: plain,
          footer: JamPresetStrings.summary(permissions.policy),
          children: [
            JamRow(
              title: JamPresetStrings.guestsCan,
              value: JamPresetStrings.name(permissions.policy),
            ),
          ],
        ),
      if (isHost) _Nearby(host: host, plain: plain),
      _LeaveSection(
        isHost: isHost,
        plain: plain,
        alone: isHost && peers.isEmpty,
        onLeft: () {
          if (widget.inSheet && Navigator.of(context).canPop()) {
            Navigator.of(context).pop();
          }
        },
      ),
    ];

    final list = ListView(
      controller:
          widget.scrollController ?? JamSheetScrollController.maybeOf(context),
      padding: EdgeInsets.only(
        top: widget.inSheet ? JamSpace.sm : JamSpace.xl,
        bottom: JamSpace.xxxl + MediaQuery.paddingOf(context).bottom,
      ),
      children: [JamSectionList(children: sections)],
    );

    if (widget.inSheet) {
      // The sheet opens at its floating medium height, whose bottom corners
      // would otherwise slice the card scrolled under them: the list fades
      // out over the corner's height instead, so it reads as "more below".
      // An alpha mask, not a painted gradient.
      return ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (rect) {
          final fade = rect.height <= 0
              ? 0.0
              : (JamRadius.sheetFloating / rect.height).clamp(0.0, 1.0);
          return LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: const [JamFixedColors.white, JamFixedColors.clear],
            stops: [1 - fade, 1],
          ).createShader(rect);
        },
        child: list,
      );
    }
    if (!_onBackdrop) return list;
    // Docked beside the player (D7): no cards on the cover's colours. The
    // panel's shade is the ground, the rows are plain, and the text is the
    // backdrop's white — the same look as Up Next beside it.
    return JamOnBackdrop(
      child: JamGroupedSurface(elevated: false, child: list),
    );
  }

  double? _fetchProgress(JamHostEngine? host, String peerId, String? mediaId) {
    final entry = host?.peerFetchProgress[peerId];
    if (entry == null || mediaId == null || entry.mediaId != mediaId) {
      return null;
    }
    return entry.progress;
  }

  /// The host's "•••" for one guest: co-host, per-capability overrides,
  /// and removal.
  List<List<JamMenuItem>> _peerMenu(
    JamHostEngine host,
    PeerInfo peer,
    JamPermissions permissions,
  ) {
    final isCohost = permissions.roleOf(peer.peerId) == JamRole.cohost;
    final can = permissions.capabilitiesOf(peer.peerId);
    JamMenuItem capability(String title, IconData icon, JamCapability cap) =>
        JamMenuItem(
          title: title,
          icon: icon,
          checked: can.contains(cap),
          onPressed: () => _guarded(
            () => _toggleCapability(host, peer.peerId, cap, permissions),
          ),
        );
    return [
      [
        JamMenuItem(
          title: isCohost
              ? RoomSheetStrings.removeCohost
              : RoomSheetStrings.makeCohost,
          icon: isCohost
              ? CupertinoIcons.person_crop_circle_badge_minus
              : CupertinoIcons.person_crop_circle_badge_checkmark,
          onPressed: () => _guarded(
            () => isCohost
                ? host.demotePeer(peer.peerId)
                : host.promotePeer(peer.peerId),
          ),
        ),
      ],
      [
        capability(
          RoomSheetStrings.addMusic,
          CupertinoIcons.plus,
          JamCapability.addTracks,
        ),
        capability(
          RoomSheetStrings.controlPlayback,
          CupertinoIcons.playpause,
          JamCapability.controlPlayback,
        ),
        capability(
          RoomSheetStrings.editQueue,
          CupertinoIcons.list_bullet,
          JamCapability.editQueue,
        ),
      ],
      [
        JamMenuItem(
          title: RoomSheetStrings.removePeer,
          icon: CupertinoIcons.person_badge_minus,
          destructive: true,
          onPressed: () => unawaited(_confirmRemove(host, peer)),
        ),
      ],
    ];
  }

  Future<void> _confirmRemove(JamHostEngine host, PeerInfo peer) async {
    final name = jamPeerName(peer);
    final confirmed = await JamDialogs.confirmDestructive(
      context,
      title: RoomSheetStrings.removeTitle(name),
      // Asked now, not when the jam started: it is about this person's
      // device, and whether it said who it is.
      message: host.kickKeepsOut(peer.peerId)
          ? RoomSheetStrings.removeDetailHeld
          : RoomSheetStrings.removeDetail,
      confirmLabel: RoomSheetStrings.remove,
      cancelLabel: RoomSheetStrings.cancel,
    );
    if (!confirmed || !mounted) return;
    // Through the session, so the departure that follows is told as the
    // host's own act ("Removed Okon"), not as theirs ("Okon left").
    _guarded(() => JamSession.read(context).removePeer(peer.peerId));
  }
}

/// A section of the panel: inset grouped in the sheet, plain rows (sentence
/// case footnote header, no card) on the backdrop.
JamSection _section({
  required bool plain,
  String? header,
  String? footer,
  required List<Widget> children,
}) => plain
    ? JamSection.plain(
        header: header,
        prominentHeader: false,
        footer: footer,
        children: children,
      )
    : JamSection(header: header, footer: footer, children: children);

/// What [peerId]'s role and the room policy give them, before overrides.
bool _baseAllows(JamPermissions permissions, String peerId, JamCapability c) {
  if (permissions.roleOf(peerId) == JamRole.cohost) {
    return JamPermissions.cohostCapabilities.contains(c);
  }
  final policy = permissions.policy;
  return switch (c) {
    JamCapability.addTracks => policy.addTracks,
    JamCapability.controlPlayback => policy.controlPlayback,
    JamCapability.editQueue => policy.editQueue,
    _ => false,
  };
}

/// Flips one capability for one person. An override that would only repeat
/// what their role already gives is cleared rather than set, so a later
/// policy change still reaches them.
void _toggleCapability(
  JamHostEngine host,
  String peerId,
  JamCapability capability,
  JamPermissions permissions,
) {
  final target = !permissions.capabilitiesOf(peerId).contains(capability);
  final base = _baseAllows(permissions, peerId, capability);
  host.setCapabilityOverride(
    peerId,
    capability,
    allowed: target == base ? null : target,
  );
}

/// What the host changed for [peerId], said as subtitle words ("Can’t add
/// music"), or null when nothing differs from their role.
String? _overrideDetail(JamPermissions permissions, String peerId) {
  final can = permissions.capabilitiesOf(peerId);
  final phrases = [
    for (final c in const [
      JamCapability.addTracks,
      JamCapability.controlPlayback,
      JamCapability.editQueue,
    ])
      if (can.contains(c) != _baseAllows(permissions, peerId, c))
        RoomSheetStrings.capabilityDetail(c, can.contains(c)),
  ];
  if (phrases.isEmpty) return null;
  final text = phrases.join(', ');
  return text[0].toUpperCase() + text.substring(1);
}

/// The host's display name, or the role word when they shared none.
String _hostName(JamEngine engine) {
  final name = engine.hostPeer?.clientName.trim() ?? '';
  return name.isEmpty ? RoomSheetStrings.host : name;
}

/// Everyone in [engine]'s jam by display name, in room order: this device
/// ([selfName], or "You" before it is known), then — from a guest — the
/// host, then everyone else. Parallel to `jamRosterPeerIds`.
List<String> jamRosterNames(JamEngine engine, {required String selfName}) {
  final self = selfName.trim();
  return <String>[
    self.isEmpty ? JamPeerRowStrings.you : self,
    if (engine is JamGuestEngine) _hostName(engine),
    for (final peer in engine.peers) jamPeerName(peer),
  ];
}

/// Each person's face colour in [engine]'s jam, by peer id (D3): the jam's
/// names through [jamPeopleColors], the host first — the order every phone
/// in the jam agrees on — so a person is the same colour on every phone in
/// the jam, and in the footer, the People sheet and every "Added by" credit
/// on each, and on Past Jams afterwards.
Map<String, Color> jamRosterColors(
  JamEngine engine, {
  required String selfName,
}) {
  final ids = jamRosterPeerIds(engine);
  final names = jamRosterNames(engine, selfName: selfName);
  final byName = jamPeopleColors(
    names,
    host: names[engine is JamGuestEngine ? 1 : 0],
  );
  return {
    for (var i = 0; i < ids.length && i < names.length; i++)
      ids[i]: byName[names[i]] ?? identityColor(names[i]),
  };
}

/// The engine's role, as the row's presentational one.
JamPeerRole _roleOf(JamRole role) => switch (role) {
  JamRole.host => JamPeerRole.host,
  JamRole.cohost => JamPeerRole.cohost,
  JamRole.guest => JamPeerRole.guest,
};

/// The engine's readiness, as the row's — null for `ready`, so a person who
/// is simply fine gets a name and nothing else.
JamPeerReadiness? _readiness(MediaReadiness? readiness) => switch (readiness) {
  MediaReadiness.fetching => JamPeerReadiness.fetching,
  MediaReadiness.none => JamPeerReadiness.missing,
  MediaReadiness.ready => null,
  null => null,
};

/// [listenable], followed while the room lives — and read once, without
/// subscribing, after it ended.
///
/// Ending the jam with a sheet open releases the engine's listenables while
/// the sheet is still on screen: it animates out, and a part of it can be
/// built again on the way. A fresh subscription then landed on a disposed
/// notifier (the 2026-10-17 run's "ValueNotifier used after being
/// disposed"). Nothing changes after the end, so the last value is all there
/// is to show.
Widget _whileLive<T>(
  JamEngine engine,
  ValueListenable<T> listenable,
  Widget Function(BuildContext context, T value) builder,
) {
  if (engine.sessionEnded.value != null) {
    return Builder(builder: (context) => builder(context, listenable.value));
  }
  return ValueListenableBuilder<T>(
    valueListenable: listenable,
    builder: (context, value, _) => builder(context, value),
  );
}

/// People the host removed this session (§5.6): a removed device stays out
/// until the host lets it back in, and this is the only place that can.
/// Hidden while nobody has been removed — gap included, so an empty list
/// leaves no hole in the page.
class _Removed extends StatelessWidget {
  const _Removed({
    required this.host,
    required this.onLetBackIn,
    this.plain = false,
  });

  final JamHostEngine host;
  final bool plain;
  final ValueChanged<PeerInfo> onLetBackIn;

  @override
  Widget build(BuildContext context) => _whileLive(
    host,
    // Follows removals made anywhere — this sheet's menu, the docked panel,
    // an engine-level kick — not only the ones this widget saw.
    host.kickedPeersListenable,
    (context, kicked) {
      if (kicked.isEmpty) return const SizedBox.shrink();
      final section = _section(
        plain: plain,
        header: RoomSheetStrings.removed,
        footer: RoomSheetStrings.removedDetail,
        children: [
          for (final peer in kicked)
            JamPeerRow(
              name: jamPeerName(peer),
              dimmed: true,
              trailing: JamButton.plain(
                label: RoomSheetStrings.letBackIn,
                size: JamButtonSize.small,
                onPressed: () => onLetBackIn(peer),
              ),
            ),
        ],
      );
      return Padding(
        padding: const EdgeInsets.only(top: JamSpace.section),
        child: section,
      );
    },
  );
}

/// The host's Show to People Nearby switch (§1 discovery): on, the jam is
/// advertised to everyone on the Wi‑Fi; off, it is withdrawn at once and only
/// the link or the code lets anyone in. Follows the engine, so a change made
/// from the docked panel shows in the sheet too.
class _Nearby extends StatelessWidget {
  const _Nearby({required this.host, this.plain = false});

  final JamHostEngine host;
  final bool plain;

  @override
  Widget build(BuildContext context) => _whileLive(
    host,
    host.discoveryEnabledListenable,
    (context, shown) => _section(
      plain: plain,
      footer: shown
          ? RoomSheetStrings.nearbyOnFooter
          : RoomSheetStrings.nearbyOffFooter,
      children: [
        JamRow.toggle(
          title: RoomSheetStrings.nearby,
          value: shown,
          onChanged: (value) => unawaited(host.setDiscoverable(value)),
        ),
      ],
    ),
  );
}

/// What guests can do: the preset (a pull-down) and the three switches it
/// stands for. The pull-down opens clear of the switches.
class _GuestsCan extends StatelessWidget {
  const _GuestsCan({
    required this.policy,
    required this.onChanged,
    this.plain = false,
  });

  final JamPolicy policy;
  final ValueChanged<JamPolicy> onChanged;
  final bool plain;

  @override
  Widget build(BuildContext context) {
    return _section(
      plain: plain,
      footer: JamPresetStrings.summary(policy),
      children: [
        JamGuestsCanRow(
          policy: policy,
          onChanged: onChanged,
          controls: [
            JamRow.toggle(
              title: RoomSheetStrings.addMusic,
              value: policy.addTracks,
              onChanged: (v) => onChanged(policy.copyWith(addTracks: v)),
            ),
            JamRow.toggle(
              title: RoomSheetStrings.controlPlayback,
              value: policy.controlPlayback,
              onChanged: (v) => onChanged(policy.copyWith(controlPlayback: v)),
            ),
            JamRow.toggle(
              title: RoomSheetStrings.editQueue,
              value: policy.editQueue,
              onChanged: (v) => onChanged(policy.copyWith(editQueue: v)),
            ),
          ],
        ),
      ],
    );
  }
}

/// End Jam / Leave Jam: a centred destructive row in its own last section,
/// behind a confirmation.
class _LeaveSection extends StatelessWidget {
  const _LeaveSection({
    required this.isHost,
    required this.onLeft,
    this.plain = false,
    this.alone = false,
  });

  final bool isHost;
  final bool plain;

  /// A host with nobody else in the jam: "everyone" would be nobody.
  final bool alone;

  /// Called after the session is torn down, before the route change.
  final VoidCallback onLeft;

  Future<void> _confirm(BuildContext context) async {
    final session = JamSession.read(context);
    final router = GoRouter.maybeOf(context);
    final confirmed = await JamDialogs.confirmDestructive(
      context,
      title: isHost ? RoomSheetStrings.endTitle : RoomSheetStrings.leaveTitle,
      message: !isHost
          ? RoomSheetStrings.leaveDetail
          : alone
          ? RoomSheetStrings.endDetailAlone
          : RoomSheetStrings.endDetail,
      confirmLabel: isHost ? RoomSheetStrings.endJam : RoomSheetStrings.leave,
      cancelLabel: RoomSheetStrings.cancel,
    );
    if (!confirmed || !context.mounted) return;
    await session.leave();
    if (!context.mounted) return;
    onLeft();
    router?.go('/');
  }

  @override
  Widget build(BuildContext context) => _section(
    plain: plain,
    children: [
      JamRow(
        title: isHost ? RoomSheetStrings.endJam : RoomSheetStrings.leaveJam,
        destructive: true,
        centered: true,
        onTap: () => unawaited(_confirm(context)),
      ),
    ],
  );
}

/// The Invite sheet's body: the code that gets people in, following the
/// room's reachable addresses.
///
/// The join link is not fixed for the life of a room: the engine re-scans
/// the phone's interfaces, so moving from one Wi-Fi to another — or turning
/// the hotspot on — changes the addresses inside it. With no LAN at all
/// there is nothing a guest could reach, so instead of a code that cannot
/// work the sheet says what would make one.
///
/// A guest invites with the link they joined by: same room, same token.
class InvitePanel extends StatelessWidget {
  const InvitePanel({
    super.key,
    required this.engine,
    required this.network,
    this.selfName = '',
  });

  final JamEngine engine;
  final JamNetworkStatus network;

  /// This device's display name: how it is named among the jam's people.
  final String selfName;

  @override
  Widget build(BuildContext context) {
    final engine = this.engine;
    final roomName = engine.sessionName;
    if (engine is JamGuestEngine) {
      return _Invite(
        engine: engine,
        selfName: selfName,
        joinUri: engine.joinUri,
        caption: RoomSheetStrings.inviteOnNetwork,
        roomName: roomName,
      );
    }
    final host = engine as JamHostEngine;
    return _whileLive(
      host,
      host.lanAddresses,
      (context, addresses) => addresses.isEmpty
          ? const _NoNetworkInvite()
          : _whileLive(
              host,
              host.joinUriListenable,
              (context, joinUri) => _Invite(
                engine: host,
                selfName: selfName,
                joinUri: joinUri,
                caption: network.isHotspotHost
                    ? RoomSheetStrings.inviteOnHotspot
                    : RoomSheetStrings.inviteOnNetwork,
                roomName: roomName,
              ),
            ),
    );
  }
}

/// Where the code would be, while there is no network to put in it.
class _NoNetworkInvite extends StatelessWidget {
  const _NoNetworkInvite();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      JamSpace.page,
      JamSpace.huge,
      JamSpace.page,
      JamSpace.giant,
    ),
    child: Semantics(
      liveRegion: true,
      child: const JamEmptyState(
        icon: CupertinoIcons.wifi_slash,
        title: RoomSheetStrings.noNetworkTitle,
        body: RoomSheetStrings.noNetworkDetail,
      ),
    ),
  );
}

/// The jam, the code, and the two ways to send the link.
class _Invite extends StatelessWidget {
  const _Invite({
    required this.engine,
    required this.selfName,
    required this.joinUri,
    required this.caption,
    required this.roomName,
  });

  final JamEngine engine;
  final String selfName;
  final Uri joinUri;
  final String caption;
  final String roomName;

  Future<void> _share(BuildContext context) async {
    final session = JamSession.read(context);
    final box = context.findRenderObject() as RenderBox?;
    try {
      // Text, not `uri:`: a bare URI reaches Messages and Mail as a machine
      // string with no sentence around it.
      await SharePlus.instance.share(
        ShareParams(
          text: RoomSheetStrings.shareText(roomName, joinUri),
          subject: RoomSheetStrings.shareSubject(roomName),
          // iPad and macOS anchor the share popover here.
          sharePositionOrigin: box == null || !box.hasSize
              ? null
              : box.localToGlobal(Offset.zero) & box.size,
        ),
      );
    } catch (e) {
      debugPrint('localjam: share sheet failed: $e');
      session.notify(RoomSheetStrings.shareFailed, tone: JamNoticeTone.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        JamSpace.page,
        JamSpace.lg,
        JamSpace.page,
        JamSpace.xl,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // What is being shared, as the jam looks everywhere else (D4):
          // on the code's own width, so the two read as one card's worth.
          Center(
            child: SizedBox(
              width: _qrSize + _platePadding * 2,
              child: _InviteIdentity(engine: engine, selfName: selfName),
            ),
          ),
          const SizedBox(height: JamSpace.xl),
          Center(
            child: Semantics(
              image: true,
              label: RoomSheetStrings.qrLabel(roomName),
              excludeSemantics: true,
              // Always white, in both themes: a code needs a light ground to
              // scan, and the plate is that ground — nothing more.
              child: Container(
                padding: const EdgeInsets.all(_platePadding),
                decoration: BoxDecoration(
                  color: JamFixedColors.white,
                  borderRadius: BorderRadius.circular(_plateRadius),
                ),
                child: QrImageView(
                  // Keyed on the link, so a new address list (another Wi-Fi,
                  // the hotspot coming up) is a new code rather than a
                  // repaint of the old one's cached state.
                  key: ValueKey<String>(joinUri.toString()),
                  data: joinUri.toString(),
                  size: _qrSize,
                  padding: EdgeInsets.zero,
                  backgroundColor: JamFixedColors.white,
                  eyeStyle: const QrEyeStyle(
                    eyeShape: QrEyeShape.square,
                    color: JamFixedColors.black,
                  ),
                  dataModuleStyle: const QrDataModuleStyle(
                    dataModuleShape: QrDataModuleShape.square,
                    color: JamFixedColors.black,
                  ),
                  // The scanning phone is often across a room; a sparser code
                  // reads better at distance.
                  errorCorrectionLevel: QrErrorCorrectLevel.M,
                ),
              ),
            ),
          ),
          const SizedBox(height: JamSpace.md),
          Text(
            caption,
            textAlign: TextAlign.center,
            style: context.jamSubheadline.copyWith(
              color: colors.secondaryLabel,
            ),
          ),
          const SizedBox(height: JamSpace.xxl),
          JamButton.filled(
            label: RoomSheetStrings.shareLink,
            icon: CupertinoIcons.share,
            expand: true,
            onPressed: () => unawaited(_share(context)),
          ),
          const SizedBox(height: JamSpace.sm),
          // Confirms in place: a toast would land on Share Link, the very
          // control beside it (§10.5).
          JamCopyButton(
            label: RoomSheetStrings.copyLink,
            copiedLabel: RoomSheetStrings.copied,
            expand: true,
            onCopy: () async {
              await Clipboard.setData(ClipboardData(text: joinUri.toString()));
              JamHaptics.selection();
              return true;
            },
          ),
        ],
      ),
    );
  }
}

/// The jam on the Invite sheet: its mark (the cover that is playing, the
/// host's face on its corner), its name in Manrope, and who is in it — the
/// same object a guest saw on Nearby and will see in Past Jams.
///
/// Follows the room while it lives — a new song, someone who just scanned
/// in — and reads it once, without subscribing, after it ended.
class _InviteIdentity extends StatefulWidget {
  const _InviteIdentity({required this.engine, required this.selfName});

  final JamEngine engine;
  final String selfName;

  @override
  State<_InviteIdentity> createState() => _InviteIdentityState();
}

class _InviteIdentityState extends State<_InviteIdentity> {
  final List<StreamSubscription<Object?>> _subs = [];
  String? _coverId;
  Future<Uint8List?>? _cover;

  @override
  void initState() {
    super.initState();
    final engine = widget.engine;
    if (engine.sessionEnded.value != null) return;
    void refresh(Object? _) {
      if (mounted) setState(() {});
    }

    _subs.add(engine.states.listen(refresh));
    if (engine is JamGuestEngine) {
      _subs.add(engine.peerEvents.listen(refresh));
    } else if (engine is JamHostEngine) {
      _subs.add(engine.events.listen(refresh));
    }
  }

  @override
  void dispose() {
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    super.dispose();
  }

  Future<Uint8List?>? _coverFor(MediaItem? item) {
    final id = item?.artworkId;
    if (id != _coverId) {
      _coverId = id;
      _cover = id == null ? null : widget.engine.artworkFor(item!);
    }
    return _cover;
  }

  @override
  Widget build(BuildContext context) {
    final engine = widget.engine;
    final colors = context.jamColors;
    final names = jamRosterNames(engine, selfName: widget.selfName);
    final faces = jamRosterColors(engine, selfName: widget.selfName);
    final guest = engine is JamGuestEngine;
    final hostName = names[guest ? 1 : 0];
    final hostId = guest
        ? (engine.hostPeer?.peerId ?? JamPermissions.hostPeerId)
        : engine.selfPeerId;
    // The host first: it is their jam a guest is being asked into.
    final people = [
      hostName,
      for (final n in names)
        if (n != hostName) n,
    ];

    Widget mark(Uint8List? cover) => JamMark(
      name: engine.sessionName,
      size: JamMarkSize.row,
      covers: [if (cover != null && cover.isNotEmpty) MemoryImage(cover)],
      hostName: hostName,
      hostColor: faces[hostId],
    );
    final future = _coverFor(engine.currentItem);

    return Row(
      children: [
        if (future == null)
          mark(null)
        else
          FutureBuilder<Uint8List?>(
            future: future,
            builder: (context, snapshot) => mark(snapshot.data),
          ),
        const SizedBox(width: JamSpace.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                engine.sessionName,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: context.jamTitle3,
              ),
              Text(
                RoomSheetStrings.everyone(people),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.jamSubheadline.copyWith(
                  color: colors.secondaryLabel,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
