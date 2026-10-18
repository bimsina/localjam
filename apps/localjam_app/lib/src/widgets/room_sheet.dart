/// The room's people, and the way to let more in (DESIGN_SPEC v3 §6.5).
///
/// Two sheets where there used to be one long page:
///
/// * **People** ([showRoomSheet], [RoomPanel]) — a grouped list: Invite
///   People, who is here (with the host's per-guest "•••" and, under the
///   list, whether people nearby can see the jam), anyone removed, what
///   guests can do, and the way out in its own last section.
/// * **Invite** ([showInviteSheet], [InvitePanel]) — the QR on a white
///   plate, the jam's name, Share Link and Copy Link. With no network
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
import 'package:flutter/material.dart' show Theme, ThemeData;
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:localjam_client/localjam_client.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../design/tokens.dart';
import '../design/typography.dart';
import '../state/session_controller.dart';
import '../util/format.dart';
import '../util/network.dart';
import 'buttons.dart';
import 'dialogs.dart';
import 'empty_state.dart';
import 'guests_can.dart';
import 'list.dart';
import 'menu.dart';
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

  // Whether people nearby can see the jam: chosen in Start a Jam and fixed
  // for the jam's life, so it is said as a fact under the people list, not
  // drawn as a setting that cannot be changed.
  static const String nearby = 'Show to People Nearby';
  static const String on = 'On';
  static const String off = 'Off';
  static const String nearbyOnFooter =
      'People on this Wi‑Fi can see this jam and join it.';
  static const String nearbyOffFooter =
      'This jam is hidden from people nearby. Only people with the link or '
      'code can join.';

  // The per-guest menu.
  static const String makeCohost = 'Make Co-host';
  static const String removeCohost = 'Remove Co-host';
  static const String removePeer = 'Remove from Jam';
  static const String cancel = 'Cancel';
  static const String remove = 'Remove';
  static String removeTitle(String name) => 'Remove $name?';

  /// What removing someone does for certain. Whether the device also stays
  /// out depends on whether it identified itself when it joined — which the
  /// host engine keeps to itself — so the alert promises only this, and the
  /// Removed list (with its own footer) appears when the hold is real.
  static const String removeDetail = 'They’ll stop hearing the jam right away.';

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
  trailing: Builder(
    builder: (context) => JamTextButton(
      label: RoomSheetStrings.done,
      bold: true,
      onPressed: () => Navigator.of(context).maybePop(),
    ),
  ),
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
  trailing: const JamSheetCloseButton(),
  grouped: true,
  // Sized to its content: the code, two buttons, nothing to scroll — except
  // at large text sizes, where it scrolls rather than clips.
  scrollable: false,
  builder: (_) => SingleChildScrollView(
    child: InvitePanel(engine: engine, network: network),
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

  /// The backdrop theme, kept per base theme so a rebuild is not a new
  /// theme for every descendant.
  ThemeData? _backdropBase;
  ThemeData? _backdropTheme;

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
      JamSession.read(context).notify(RoomSheetStrings.actionFailed);
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

    final people = <Widget>[
      // This device first, so you can see your own standing.
      JamPeerRow(
        name: widget.selfName,
        colorKey: _engine.selfPeerId,
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
          colorKey: _engine.hostPeer?.peerId ?? JamPermissions.hostPeerId,
          role: JamPeerRole.host,
        ),
      for (final peer in peers)
        JamPeerRow(
          name: jamPeerName(peer),
          colorKey: peer.peerId,
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
            // Fixed when the jam started, so said as a fact rather than
            // drawn as a setting that can't be changed.
            footer: !isHost
                ? null
                : host.discoverable
                ? RoomSheetStrings.nearbyOnFooter
                : RoomSheetStrings.nearbyOffFooter,
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
                JamSession.read(
                  context,
                ).notify(RoomSheetStrings.letBackInDone(jamPeerName(peer)));
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

    if (!_onBackdrop) return list;
    // Docked beside the player (D7): no cards on the cover's colours. The
    // panel's shade is the ground, the rows are plain, and the text is the
    // backdrop's white — the same look as Up Next beside it.
    return Theme(
      data: _themeOnBackdrop(Theme.of(context)),
      child: JamGroupedSurface(elevated: false, child: list),
    );
  }

  ThemeData _themeOnBackdrop(ThemeData base) {
    if (identical(base, _backdropBase) && _backdropTheme != null) {
      return _backdropTheme!;
    }
    _backdropBase = base;
    return _backdropTheme = _themeForBackdrop(base);
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
      message: RoomSheetStrings.removeDetail,
      confirmLabel: RoomSheetStrings.remove,
      cancelLabel: RoomSheetStrings.cancel,
    );
    if (!confirmed || !mounted) return;
    _guarded(() => host.kickPeer(peer.peerId));
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

/// System red lifted toward white: ≥ 4.5:1 on the backdrop under its
/// overlay, where `danger` itself drops to about 2.7:1 on a vivid cover.
const Color _backdropDanger = Color(0xFFFFA8A0);

/// [base] with the Now Playing backdrop's colours: white text at the
/// backdrop's secondary and tertiary strengths, white for what can be
/// tapped (as on the rest of Now Playing), see-through row grounds and a
/// white press highlight. Switches stay green; destructive stays red, lifted
/// to [_backdropDanger] so End Jam still reads on a saturated cover.
ThemeData _themeForBackdrop(ThemeData base) {
  final colors = (base.extension<JamColors>() ?? JamColors.dark).copyWith(
    groupedSurface: JamFixedColors.clear,
    elevatedGroupedSurface: JamFixedColors.clear,
    label: JamNowPlayingColors.text,
    secondaryLabel: JamNowPlayingColors.secondary,
    tertiaryLabel: JamNowPlayingColors.tertiary,
    separator: JamNowPlayingColors.track,
    fillPressed: JamNowPlayingColors.pressed,
    tint: JamNowPlayingColors.text,
    tintPressed: JamNowPlayingColors.fill,
    danger: _backdropDanger,
  );
  return base.copyWith(
    extensions: [
      for (final extension in base.extensions.values)
        if (extension is! JamColors) extension,
      colors,
    ],
  );
}

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
              colorKey: peer.peerId,
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
  const InvitePanel({super.key, required this.engine, required this.network});

  final JamEngine engine;
  final JamNetworkStatus network;

  @override
  Widget build(BuildContext context) {
    final engine = this.engine;
    final roomName = engine.sessionName;
    if (engine is JamGuestEngine) {
      return _Invite(
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

/// The code, the room's name, and the two ways to send the link.
class _Invite extends StatelessWidget {
  const _Invite({
    required this.joinUri,
    required this.caption,
    required this.roomName,
  });

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
      session.notify(RoomSheetStrings.shareFailed);
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
          const SizedBox(height: JamSpace.xl),
          Text(
            roomName,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: context.jamHeadline,
          ),
          const SizedBox(height: JamSpace.xs),
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
          _CopyLinkButton(joinUri: joinUri),
        ],
      ),
    );
  }
}

/// How long a copy button says "Copied" before it goes back.
const Duration kJamCopiedFeedback = Duration(milliseconds: 1500);

/// Copy Link, which confirms in place: for [kJamCopiedFeedback] the label
/// reads "Copied" behind a checkmark, then returns. No toast — it would land
/// on Share Link, the very control beside it (§10.5).
class _CopyLinkButton extends StatefulWidget {
  const _CopyLinkButton({required this.joinUri});

  final Uri joinUri;

  @override
  State<_CopyLinkButton> createState() => _CopyLinkButtonState();
}

class _CopyLinkButtonState extends State<_CopyLinkButton> {
  Timer? _reset;
  bool _copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.joinUri.toString()));
    if (!mounted) return;
    JamHaptics.selection();
    _reset?.cancel();
    setState(() => _copied = true);
    _reset = Timer(kJamCopiedFeedback, () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  void dispose() {
    _reset?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: _copied,
    child: JamButton.plain(
      label: _copied ? RoomSheetStrings.copied : RoomSheetStrings.copyLink,
      icon: _copied ? CupertinoIcons.checkmark : null,
      expand: true,
      onPressed: () => unawaited(_copy()),
    ),
  );
}
