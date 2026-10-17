/// Everything about the room's people, on one page: the code that lets them
/// in, who is here, and what they may do.
///
/// Kept off the player deliberately. The now-playing screen should read as a
/// music player; presence lives in the chrome and opens into this.
///
/// Design spec §5 "People / Room sheet". Two label rules matter more than
/// they look: a role is a *badge*, never a detail line — a guest with every
/// right used to read "Listening", which sounds like a demotion — and the
/// join URI never appears as text (§6.8), because `localjam://join?token=…`
/// is machine text sitting in the middle of a page about people.
library;

import 'dart:async';
import 'dart:ui' show FontFeature, ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';
import 'package:localjam_client/localjam_client.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../design/tokens.dart';
import '../design/typography.dart';
import '../state/session_controller.dart';
import '../util/network.dart';
import 'avatar.dart';
import 'buttons.dart';
import 'chip.dart';
import 'dialogs.dart';
import 'peer_row.dart';
import 'sheet.dart';

/// Everything this sheet says out loud.
abstract final class RoomSheetStrings {
  static const String invite = 'Let people in';
  static const String inviteOnNetwork =
      'Anyone on this network can scan this to join.';
  static const String inviteOnHotspot =
      'Everyone joins your hotspot first, then scans this.';
  static const String roomCode = 'Room code';
  static const String roomCodeDetail = 'Tap to copy the invite link';
  static const String copy = 'Copy the invite link';
  static const String copied = 'Invite link copied.';
  static const String shareLink = 'Share link';
  static const String shareFailed = 'Could not open the share sheet.';

  /// What the OS share sheet is handed. A bare `localjam://…` gave every
  /// target a machine string and no sentence; this is the sentence, with the
  /// URI on a line of its own so the OS still linkifies it.
  static String shareSubject(String room) => 'Join $room on LocalJam';
  static String shareText(String room, Uri uri) =>
      'Join $room on LocalJam \u2014 same Wi\u2011Fi, no internet needed.\n$uri';

  /// The short code shown on the "Room code" row.
  static const String noCode = '——————';

  static const String everyoneCan = 'Everyone can';
  static const String addMusic = 'Add music';
  static const String controlPlayback = 'Play, pause, and skip';
  static const String editQueue = 'Reorder the queue';
  static const String cannotAdd = 'Cannot add music';

  static const String presetEverything = 'Everything';
  static const String presetAddMusic = 'Add music';
  static const String presetListen = 'Listen';
  static const String presetCustom = 'Custom';

  static const String makeCohost = 'Make co-host';
  static const String demote = 'Demote to guest';
  static const String blockAdds = 'Block adding music';
  static const String allowAdds = 'Allow adding music';
  static const String removePeer = 'Remove from the room';
  static const String stay = 'Stay';
  static const String remove = 'Remove';

  static const String endJam = 'End jam';
  static const String leaveJam = 'Leave jam';
  static const String endTitle = 'End this jam?';
  static const String endDetail = 'Everyone listening will be disconnected.';
  static const String leaveTitle = 'Leave this jam?';
  static const String leaveDetail =
      'You can rejoin as long as the room is still up.';
  static const String leave = 'Leave';

  /// The host's row when this device is a guest — a guest never learns the
  /// host's display name over the wire.
  static const String host = 'Host';

  /// "4 in the room".
  static String inTheRoom(int n) => '$n in the room';

  static String removeTitle(String name) => 'Remove $name?';
  static const String removeDetail =
      'They stop hearing the room straight away. They can come back with the '
      'room code.';

  /// The preset [policy] matches, or [presetCustom] once a switch diverges.
  static String presetName(JamPolicy policy) => switch (policy) {
    JamPolicy.open => presetEverything,
    JamPolicy.jam => presetAddMusic,
    JamPolicy.listenOnly => presetListen,
    _ => presetCustom,
  };

  /// What the room allows, said as a sentence.
  ///
  /// "Preset: Add music" was the field name showing through — it named an
  /// internal enum rather than telling the host what their guests can do.
  static String presetFootnote(JamPolicy policy) => guestSummary(policy);

  /// What a guest is told the room allows, in a sentence.
  static String guestSummary(JamPolicy policy) {
    final allowed = [
      if (policy.addTracks) 'add music',
      if (policy.controlPlayback) 'play, pause and skip',
      if (policy.editQueue) 'reorder the queue',
    ];
    if (allowed.isEmpty) {
      return 'The host runs this room. Everyone else listens along.';
    }
    final last = allowed.removeLast();
    return allowed.isEmpty
        ? 'Everyone can $last.'
        : 'Everyone can ${allowed.join(', ')} and $last.';
  }
}

/// A room's join token, shortened into something a person can read out.
///
/// The URI itself is machine text and never appears (§6.8), but "Room code"
/// over a copy icon and nothing else was a label with no value under it. Six
/// characters of the token, uppercased and grouped three-and-three, is short
/// enough to say across a van and long enough to tell two rooms apart. It is
/// a *label*, not an input: copying still copies the whole URI.
String jamShortRoomCode(Uri joinUri) {
  final token = joinUri.queryParameters['token'] ?? '';
  final letters = token.replaceAll(RegExp('[^A-Za-z0-9]'), '').toUpperCase();
  if (letters.length < 6) {
    return letters.isEmpty ? RoomSheetStrings.noCode : letters;
  }
  return '${letters.substring(0, 3)} ${letters.substring(3, 6)}';
}

/// The QR plate's geometry (§5): a 264 dp white plate holding a 200 dp code
/// with the brand mark knocked into a 44 dp raspberry square at its centre.
const double _plateSize = 264;
const double _qrSize = 200;
const double _markSize = 44;
const String _logoAsset = 'assets/brand/logo.svg';

/// Opens the room page.
Future<void> showRoomSheet(
  BuildContext context,
  JamEngine engine, {
  required String selfName,
  required JamNetworkStatus network,
  Uri? joinUri,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    // Dragged to full height this sheet used to slide its grabber under the
    // clock; the safe area plus [buildJamDraggableSheet]'s clamp stop it.
    useSafeArea: true,
    // The surface, the shadow and the handle come from [JamSheetScaffold]
    // below, so the route paints nothing of its own.
    backgroundColor: Colors.transparent,
    elevation: 0,
    showDragHandle: false,
    constraints: const BoxConstraints(maxWidth: 640),
    builder: (_) => buildJamDraggableSheet(
      initialChildSize: kJamSheetInitialSize,
      maxChildSize: kJamSheetMaxSize,
      minChildSize: kJamSheetMinSize,
      builder: (context, scrollController) => _RoomSheetSurface(
        child: JamSheetScaffold(
          scrollController: scrollController,
          child: RoomPanel(
            engine: engine,
            selfName: selfName,
            network: network,
            joinUri: joinUri,
            inSheet: true,
          ),
        ),
      ),
    ),
  );
}

/// The sheet's ground.
///
/// A near-copy of `sheet.dart`'s own private surface: [showJamSheet] takes a
/// *String* title, and this sheet's title counts the people in the room and
/// has to stay live while they arrive.
class _RoomSheetSurface extends StatelessWidget {
  const _RoomSheetSurface({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    const radius = BorderRadius.vertical(top: Radius.circular(JamRadius.xl));
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceElevated,
        borderRadius: radius,
        boxShadow: JamShadow.overlay(colors),
      ),
      child: Material(
        color: Colors.transparent,
        clipBehavior: Clip.antiAlias,
        shape: const RoundedRectangleBorder(borderRadius: radius),
        child: child,
      ),
    );
  }
}

/// Who is here, the join code, and what guests may do — as a sheet body on
/// phones and a docked panel on desktop.
class RoomPanel extends StatefulWidget {
  const RoomPanel({
    super.key,
    required this.engine,
    required this.selfName,
    required this.network,
    this.joinUri,
    this.scrollController,
    this.inSheet = false,
  });

  final JamEngine engine;

  /// This device's display name — the engine knows peers, not itself.
  final String selfName;

  final JamNetworkStatus network;

  /// Host only: the room's join URI.
  final Uri? joinUri;

  /// Supplied by a DraggableScrollableSheet; when null the enclosing sheet's
  /// controller is picked up from [JamSheetScrollController].
  final ScrollController? scrollController;

  /// Whether this panel is inside a modal sheet, which the Leave row has to
  /// close on its way out. False when docked beside the player.
  final bool inSheet;

  @override
  State<RoomPanel> createState() => _RoomPanelState();
}

class _RoomPanelState extends State<RoomPanel> {
  final List<StreamSubscription<Object?>> _subs = [];

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
  }

  @override
  void dispose() {
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    super.dispose();
  }

  void _guarded(void Function() action) {
    try {
      action();
      if (mounted) setState(() {});
    } catch (e) {
      if (!mounted) return;
      JamSession.read(context).notify('$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final host = _host;
    final peers = _engine.peers;
    final permissions = _engine.permissions;
    final isHost = host != null;
    final joinUri = widget.joinUri;
    final mediaId = _engine.snapshot.mediaId;
    final readinessById = isHost && mediaId != null
        ? host.peerMediaStates(mediaId)
        : const <String, MediaReadiness>{};

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // A guest's `peers` holds neither this device nor the host, so the
        // room is two people bigger than the list from that side.
        JamSheetHeader(
          title: RoomSheetStrings.inTheRoom(peers.length + (isHost ? 1 : 2)),
        ),
        Expanded(
          child: ListView(
            controller:
                widget.scrollController ??
                JamSheetScrollController.maybeOf(context),
            // The gesture bar ate the last switch row on a Pixel: the sheet's
            // own SafeArea does not reach a list this one scrolls itself.
            padding: EdgeInsets.only(
              bottom: JamSpace.xl + MediaQuery.paddingOf(context).bottom,
            ),
            children: [
              const SizedBox(height: JamSpace.sm),

              // This device first, so you can see your own standing.
              _Person(
                name: widget.selfName,
                role: isHost
                    ? JamPeerRole.host
                    : _roleOf(permissions.roleOf(_engine.selfPeerId)),
                isYou: true,
                addsBlocked:
                    permissions.overrides[_engine.selfPeerId]?[JamCapability
                        .addTracks] ==
                    false,
              ),
              // The host holds the reserved peer id and is never in `peers`,
              // so a guest has to put them back or the room looks a person
              // short — and the room's owner belongs near the top.
              if (!isHost)
                _Person(
                  // The host's own display name when they shared one; the
                  // role word only as a fallback.
                  name: _hostName(_engine),
                  role: JamPeerRole.host,
                ),

              for (final peer in peers)
                _Person(
                  name: peer.clientName.isEmpty ? peer.peerId : peer.clientName,
                  role: _roleOf(permissions.roleOf(peer.peerId)),
                  addsBlocked:
                      permissions.overrides[peer.peerId]?[JamCapability
                          .addTracks] ==
                      false,
                  // Only the host can observe whether somebody actually has
                  // the track; a guest showing "Listening" would be guessing.
                  readiness: isHost
                      ? _readiness(readinessById[peer.peerId])
                      : null,
                  fetchProgress: _fetchProgress(host, peer.peerId, mediaId),
                  onMenu: isHost
                      ? (menuContext) => unawaited(
                          _openPeerMenu(menuContext, host, peer, permissions),
                        )
                      : null,
                ),

              if (isHost && joinUri != null) ...[
                const SizedBox(height: JamSpace.section),
                _Invite(
                  joinUri: joinUri,
                  network: widget.network,
                  roomName: _engine.sessionName,
                ),
              ],

              const SizedBox(height: JamSpace.section),
              if (isHost)
                _EveryoneCan(
                  policy: permissions.policy,
                  onChanged: (policy) => _guarded(() => host.setPolicy(policy)),
                )
              else
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: JamSpace.page,
                  ),
                  child: Text(
                    RoomSheetStrings.guestSummary(permissions.policy),
                    style: context.jamFootnote,
                  ),
                ),

              const SizedBox(height: JamSpace.section),
              _LeaveRow(
                isHost: isHost,
                onLeft: () {
                  if (widget.inSheet && Navigator.of(context).canPop()) {
                    Navigator.of(context).pop();
                  }
                },
              ),
            ],
          ),
        ),
      ],
    );
  }

  double? _fetchProgress(JamHostEngine? host, String peerId, String? mediaId) {
    final entry = host?.peerFetchProgress[peerId];
    if (entry == null || mediaId == null || entry.mediaId != mediaId) {
      return null;
    }
    return entry.progress;
  }

  Future<void> _openPeerMenu(
    BuildContext anchor,
    JamHostEngine host,
    PeerInfo peer,
    JamPermissions permissions,
  ) async {
    final isCohost = permissions.roleOf(peer.peerId) == JamRole.cohost;
    final addsBlocked =
        permissions.overrides[peer.peerId]?[JamCapability.addTracks] == false;
    final box = anchor.findRenderObject() as RenderBox?;
    final overlay = Overlay.of(anchor).context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null) return;
    final origin = box.localToGlobal(Offset.zero, ancestor: overlay);

    final action = await showMenu<_PeerAction>(
      context: anchor,
      position: RelativeRect.fromLTRB(
        origin.dx,
        origin.dy + box.size.height,
        overlay.size.width - origin.dx - box.size.width,
        0,
      ),
      items: [
        PopupMenuItem(
          value: isCohost ? _PeerAction.demote : _PeerAction.promote,
          child: Text(
            isCohost ? RoomSheetStrings.demote : RoomSheetStrings.makeCohost,
          ),
        ),
        PopupMenuItem(
          value: addsBlocked ? _PeerAction.allowAdds : _PeerAction.blockAdds,
          child: Text(
            addsBlocked
                ? RoomSheetStrings.allowAdds
                : RoomSheetStrings.blockAdds,
          ),
        ),
        const PopupMenuItem(
          value: _PeerAction.kick,
          child: Text(RoomSheetStrings.removePeer),
        ),
      ],
    );
    if (action == null || !mounted) return;

    if (action == _PeerAction.kick) {
      final name = peer.clientName.isEmpty ? peer.peerId : peer.clientName;
      final confirmed = await JamDialogs.confirmDestructive(
        context,
        title: RoomSheetStrings.removeTitle(name),
        message: RoomSheetStrings.removeDetail,
        confirmLabel: RoomSheetStrings.remove,
        cancelLabel: RoomSheetStrings.stay,
      );
      if (!confirmed || !mounted) return;
    }
    _guarded(() => _apply(host, peer, action));
  }

  void _apply(JamHostEngine host, PeerInfo peer, _PeerAction action) {
    switch (action) {
      case _PeerAction.promote:
        host.promotePeer(peer.peerId);
      case _PeerAction.demote:
        host.demotePeer(peer.peerId);
      case _PeerAction.blockAdds:
        host.setCapabilityOverride(
          peer.peerId,
          JamCapability.addTracks,
          allowed: false,
        );
      case _PeerAction.allowAdds:
        host.setCapabilityOverride(
          peer.peerId,
          JamCapability.addTracks,
          allowed: null,
        );
      case _PeerAction.kick:
        host.kickPeer(peer.peerId);
    }
  }
}

enum _PeerAction { promote, demote, blockAdds, allowAdds, kick }

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

/// The engine's readiness, as the row's — and null for `ready`, so a person
/// who is simply fine gets a name and a badge rather than a status line.
JamPeerReadiness? _readiness(MediaReadiness? readiness) => switch (readiness) {
  MediaReadiness.fetching => JamPeerReadiness.fetching,
  MediaReadiness.none => JamPeerReadiness.missing,
  MediaReadiness.ready => JamPeerReadiness.ready,
  null => null,
};

/// One person: the shared [JamPeerRow], plus the capability chip that used to
/// be crammed into the detail line as "Co-host · Cannot add".
class _Person extends StatelessWidget {
  const _Person({
    required this.name,
    required this.role,
    this.isYou = false,
    this.addsBlocked = false,
    this.readiness,
    this.fetchProgress,
    this.onMenu,
  });

  final String name;
  final JamPeerRole role;
  final bool isYou;
  final bool addsBlocked;
  final JamPeerReadiness? readiness;
  final double? fetchProgress;

  /// Called with the row's own context, so the menu opens against the row.
  final void Function(BuildContext anchor)? onMenu;

  @override
  Widget build(BuildContext context) {
    final menu = onMenu;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Builder(
          builder: (rowContext) => JamPeerRow(
            name: name,
            role: role,
            isYou: isYou,
            readiness: readiness,
            fetchProgress: fetchProgress,
            showMenu: menu != null,
            onMenuTap: menu == null ? null : () => menu(rowContext),
          ),
        ),
        if (addsBlocked)
          Padding(
            padding: const EdgeInsets.only(
              left: JamSpace.page + JamAvatarSize.sheet + JamSpace.md,
              bottom: JamSpace.sm,
            ),
            child: Align(
              alignment: Alignment.centerLeft,
              child: JamChip(
                label: RoomSheetStrings.cannotAdd,
                icon: Icons.block_rounded,
              ),
            ),
          ),
      ],
    );
  }
}

/// The code that gets people in.
///
/// This matters more than mDNS discovery on a trip: a personal hotspot does
/// not carry Bonjour, so the nearby list stays empty and the QR is the way in.
class _Invite extends StatelessWidget {
  const _Invite({
    required this.joinUri,
    required this.network,
    required this.roomName,
  });

  final Uri joinUri;
  final JamNetworkStatus network;
  final String roomName;

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: joinUri.toString()));
    if (!context.mounted) return;
    JamSession.read(context).notify(RoomSheetStrings.copied);
  }

  Future<void> _share(BuildContext context) async {
    final session = JamSession.read(context);
    try {
      // Text, not `uri:`: a bare URI reaches Messages and Mail as a machine
      // string with no sentence around it (the review's raw-URI share sheet).
      await SharePlus.instance.share(
        ShareParams(
          text: RoomSheetStrings.shareText(roomName, joinUri),
          subject: RoomSheetStrings.shareSubject(roomName),
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            JamSpace.page,
            0,
            JamSpace.page,
            JamSpace.xs,
          ),
          child: Semantics(
            header: true,
            child: Text(RoomSheetStrings.invite, style: context.jamTitle),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: JamSpace.page),
          child: Text(
            network.isHotspotHost
                ? RoomSheetStrings.inviteOnHotspot
                : RoomSheetStrings.inviteOnNetwork,
            style: context.jamFootnote,
          ),
        ),
        const SizedBox(height: JamSpace.xl),
        Center(
          child: Stack(
            alignment: Alignment.center,
            children: [
              // A blurred circle, not a box shadow. `BoxShadow` traces the
              // plate's own rounded rectangle, so the "glow" arrived as a
              // pink square with soft corners; this is a genuine radial
              // falloff sitting behind the plate.
              const _QrHalo(),
              Container(
                width: _plateSize,
                height: _plateSize,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  // The QR needs a light ground to scan; on dark that stays
                  // an explicit white plate rather than the sheet's plum.
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(JamRadius.xl),
                  // White on white was invisible in light: the plate needs
                  // its own edge and its own lift off the sheet.
                  border: Border.all(color: colors.separator, width: 0.5),
                  boxShadow: JamShadow.raised(colors),
                ),
                child: Semantics(
                  label: RoomSheetStrings.inviteOnNetwork,
                  excludeSemantics: true,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      QrImageView(
                        data: joinUri.toString(),
                        size: _qrSize,
                        backgroundColor: Colors.white,
                        // The scanning phone is often across a vehicle; a denser
                        // code at lower error correction reads better at distance,
                        // and a 44 dp mark covers under 5% of the symbol's area —
                        // comfortably inside M's recovery budget.
                        errorCorrectionLevel: QrErrorCorrectLevel.M,
                      ),
                      Container(
                        width: _markSize,
                        height: _markSize,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: JamColors.brandRaspberry,
                          borderRadius: BorderRadius.circular(JamRadius.md),
                        ),
                        child: SvgPicture.asset(
                          _logoAsset,
                          width: _markSize * 0.5,
                          height: _markSize * 0.5,
                          fit: BoxFit.contain,
                          colorFilter: const ColorFilter.mode(
                            Colors.white,
                            BlendMode.srcIn,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: JamSpace.lg),
        Text(
          roomName,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: context.jamRowTitle,
        ),
        const SizedBox(height: JamSpace.lg),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: JamSpace.page),
          child: Semantics(
            button: true,
            label:
                '${RoomSheetStrings.roomCode} '
                '${jamShortRoomCode(joinUri)}. ${RoomSheetStrings.copy}',
            excludeSemantics: true,
            child: Material(
              color: colors.surfaceMuted,
              borderRadius: BorderRadius.circular(JamRadius.md),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () => unawaited(_copy(context)),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: JamSpace.lg,
                    vertical: JamSpace.md,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.link_rounded,
                        size: 20,
                        color: colors.textSecondary,
                      ),
                      const SizedBox(width: JamSpace.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              RoomSheetStrings.roomCode,
                              style: context.jamFootnote,
                            ),
                            Text(
                              jamShortRoomCode(joinUri),
                              style: context.jamRowTitle.copyWith(
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                                letterSpacing: 1.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Icon(
                        Icons.copy_rounded,
                        size: 20,
                        color: colors.textSecondary,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: JamSpace.sm),
        Center(
          child: JamButton.tertiary(
            label: RoomSheetStrings.shareLink,
            icon: Icons.ios_share_rounded,
            onPressed: () => unawaited(_share(context)),
          ),
        ),
      ],
    );
  }
}

/// The soft radial glow behind the invite plate — "point a camera at this".
class _QrHalo extends StatelessWidget {
  const _QrHalo();

  static const double _size = _plateSize + JamSpace.huge;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    return ExcludeSemantics(
      child: ImageFiltered(
        imageFilter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: Container(
          width: _size,
          height: _size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              colors: [
                colors.accent.withValues(alpha: 0.22),
                colors.accent.withValues(alpha: 0),
              ],
              stops: const [0.55, 1],
            ),
          ),
        ),
      ),
    );
  }
}

/// The three room-wide switches, and the preset they add up to.
class _EveryoneCan extends StatelessWidget {
  const _EveryoneCan({required this.policy, required this.onChanged});

  final JamPolicy policy;
  final ValueChanged<JamPolicy> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            JamSpace.page,
            0,
            JamSpace.page,
            JamSpace.xs,
          ),
          child: Semantics(
            header: true,
            child: Text(RoomSheetStrings.everyoneCan, style: context.jamTitle),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: JamSpace.page),
          child: Text(
            RoomSheetStrings.presetFootnote(policy),
            style: context.jamFootnote,
          ),
        ),
        const SizedBox(height: JamSpace.sm),
        Divider(height: 0.5, thickness: 0.5, color: colors.separator),
        // Chips were the alternative here. Switches won: each of these three
        // is an independent, immediately-applied rule, and a chip row reads
        // as a single choice among several. What changed is the volume —
        // JamSwitchRow keeps the accent on the thumb, so three toggles no
        // longer out-shout the sheet's one raspberry action.
        JamSwitchRow(
          label: RoomSheetStrings.addMusic,
          value: policy.addTracks,
          onChanged: (v) => onChanged(policy.copyWith(addTracks: v)),
        ),
        JamSwitchRow(
          label: RoomSheetStrings.controlPlayback,
          value: policy.controlPlayback,
          onChanged: (v) => onChanged(policy.copyWith(controlPlayback: v)),
        ),
        JamSwitchRow(
          label: RoomSheetStrings.editQueue,
          value: policy.editQueue,
          onChanged: (v) => onChanged(policy.copyWith(editQueue: v)),
        ),
      ],
    );
  }
}

/// The way out, as a labelled row rather than a third thing behind an
/// ellipsis (§6.1).
class _LeaveRow extends StatelessWidget {
  const _LeaveRow({required this.isHost, required this.onLeft});

  final bool isHost;

  /// Called after the session is torn down, before the route change.
  final VoidCallback onLeft;

  Future<void> _confirm(BuildContext context) async {
    final session = JamSession.read(context);
    final confirmed = await JamDialogs.confirmDestructive(
      context,
      title: isHost ? RoomSheetStrings.endTitle : RoomSheetStrings.leaveTitle,
      message: isHost
          ? RoomSheetStrings.endDetail
          : RoomSheetStrings.leaveDetail,
      confirmLabel: isHost ? RoomSheetStrings.endJam : RoomSheetStrings.leave,
      cancelLabel: RoomSheetStrings.stay,
    );
    if (!confirmed || !context.mounted) return;
    await session.leave();
    if (!context.mounted) return;
    onLeft();
    if (context.mounted) context.go('/');
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final label = isHost ? RoomSheetStrings.endJam : RoomSheetStrings.leaveJam;
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Divider(height: 0.5, thickness: 0.5, color: colors.separator),
          InkWell(
            onTap: () => unawaited(_confirm(context)),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: JamSpace.page,
                vertical: JamSpace.lg,
              ),
              child: Row(
                children: [
                  Icon(
                    // `stop_rounded` is a transport glyph — it reads as
                    // "stop the music", not "close the room". A door you
                    // walk out of is the right metaphor for both roles.
                    isHost ? Icons.meeting_room_outlined : Icons.logout_rounded,
                    size: 22,
                    color: colors.danger,
                  ),
                  const SizedBox(width: JamSpace.md),
                  Expanded(
                    child: Text(
                      label,
                      style: context.jamRowTitle.copyWith(color: colors.danger),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
