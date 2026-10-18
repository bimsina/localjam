/// Home: a live view of what is around you (DESIGN_SPEC v3 §6.1, D3).
///
/// Not a landing page. The screen's whole job is to answer "is there a jam
/// here?" before you tap anything, which is why the mDNS browse runs here
/// rather than one screen deeper.
///
/// Layout, Apple-style: a large title **Nearby**, the scan and your avatar in
/// the nav bar, the rooms as plain list rows with a tinted **Join**, the
/// recent jams under them, and one filled **Start a Jam** pinned at the
/// bottom — hidden while a jam is running, because the floating mini player
/// takes that place and you cannot host two at once.
///
/// The empty states still read the network. On a trip, "nothing nearby"
/// usually means either *no network at all* (turn on a hotspot) or *you are on
/// a hotspot, where mDNS does not travel* (scan the code). Those need opposite
/// actions, so the screen says which one it is instead of one shrug.
library;

import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:go_router/go_router.dart';
import 'package:localjam_client/localjam_client.dart';

import '../design/breakpoints.dart';
import '../design/tokens.dart';
import '../state/session_controller.dart';
import '../util/capabilities.dart';
import '../util/network.dart';
import '../widgets/avatar.dart';
import '../widgets/buttons.dart';
import '../widgets/empty_state.dart';
import '../widgets/join_link_dialog.dart';
import '../widgets/list.dart';
import '../widgets/pressable.dart';
import '../widgets/scaffold.dart';
import '../widgets/section.dart';
import '../widgets/session_gate.dart';
import 'history_screen.dart'
    show
        HistoryStrings,
        JamArtworkMosaic,
        jamHistorySummary,
        showJamHistoryDetail;

/// Every user-facing string on this screen, in one place.
abstract final class HomeStrings {
  static const String title = 'Nearby';
  static const String join = 'Join';
  static String joining(String room) => 'Joining $room…';
  static String joinRoom(String room) => 'Join $room';

  static const String scan = 'Scan a Code';
  static const String host = 'Start a Jam';

  /// The paste-a-link way in. On a phone it lives in the scanner; here it is
  /// only the nav-bar action on platforms with no camera.
  static const String joinWithLink = 'Join with Link';

  static const String settings = 'Settings';
  static const String recent = 'Recent';
  static const String seeAll = 'See All';

  static const String offlineTitle = 'Not on Wi‑Fi';
  static const String offlineBody =
      'Join a Wi‑Fi network, or turn on your hotspot and have everyone '
      'connect to it.';
  static const String hotspotTitle = 'No Jams Nearby';
  static const String hotspotBody =
      'Jams don’t show up over a hotspot. Scan the host’s code to join.';
  static const String quietTitle = 'No Jams Nearby';
  static const String quietBody = 'Jams on this Wi‑Fi show up here.';

  /// What home says while *this* device is in a jam. The browse stops while
  /// one runs, and "No Jams Nearby" over your own live room is a
  /// contradiction.
  static const String hostingTitle = 'You’re Hosting';
  static String hostingBody(String room) =>
      'Nearby jams show up again when $room ends.';
  static const String guestingTitle = 'You’re in a Jam';
  static String guestingBody(String room) =>
      'Nearby jams show up again when you leave $room.';
  static const String openRoom = 'Open Jam';

  static const String badCode = 'That code isn’t a jam invite.';
}

/// The paste-a-link label, exported for the scanner's own fallback.
const String kJoinWithLink = HomeStrings.joinWithLink;

/// How many past jams the Recent section lists before "See All".
const int kJamHomeRecents = 3;

/// How far a newly discovered room rises into place.
const double _roomEntryOffset = 8;

/// The widest the list grows on a tablet or desktop window. Rows stretched
/// across 1000 px put the Join button a long way from the name it joins.
const double _maxContentWidth = 720;

/// The room name's possessive suffix ("Mia’s Jam"), used to give a nearby
/// room its host's initials rather than "MJ" for every jam.
final RegExp _possessiveJam = RegExp(r'^(.+?)[’\x27]s Jam$');

/// The host's name, when the room name is the default "Mia’s Jam".
String jamHostNameFromRoom(String room) =>
    _possessiveJam.firstMatch(room.trim())?.group(1) ?? room;

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String _identity = '';
  JamNetworkStatus _network = JamNetworkStatus.offline;
  Timer? _networkPoll;
  List<JamHistoryRecord> _recents = const [];

  /// Rooms already on screen, so only a *newly* discovered one animates in
  /// and buzzes — a rebuild is not an arrival.
  final Set<String> _seenRooms = <String>{};
  bool _firstRoomsBuild = true;

  /// The key of the room being verified right now, so its own row spins and
  /// the rest go quiet — same one-at-a-time rule a join follows.
  String? _probing;

  @override
  void initState() {
    super.initState();
    unawaited(_loadIdentity());
    // A name adopted from the store after a prefs timeout has to replace the
    // ephemeral one already on screen (see [JamIdentity.changes]).
    JamIdentity.changes.addListener(_onIdentityChanged);
    unawaited(_refreshNetwork());
    unawaited(_loadRecents());
    // Wi-Fi and hotspots come and go on the road; re-read rather than making
    // the user pull to refresh a fact the OS already knows.
    _networkPoll = Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(_refreshNetwork()),
    );
  }

  /// Discovery is (re)started here rather than from `initState` alone.
  ///
  /// Home is never rebuilt from scratch when a jam ends — it has been sitting
  /// under the room the whole time — so a one-shot start in `initState` ran
  /// exactly once per app launch and the nearby list stayed empty for every
  /// jam after the first. Depending on the session makes this run again on
  /// every lifecycle change, which is precisely when the answer changes.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final session = JamSession.of(context);
    if (!session.hasRoom && !session.discovering) {
      unawaited(session.startBrowsing());
    }
    // A jam that just ended leaves a fresh record behind it.
    if (!session.hasRoom) unawaited(_loadRecents());
  }

  @override
  void dispose() {
    JamIdentity.changes.removeListener(_onIdentityChanged);
    _networkPoll?.cancel();
    super.dispose();
  }

  void _onIdentityChanged() => unawaited(_loadIdentity());

  Future<void> _loadIdentity() async {
    final name = await JamIdentity.displayName();
    if (mounted && name != _identity) setState(() => _identity = name);
  }

  Future<void> _loadRecents() async {
    final store = await JamHistoryStore.open();
    final records = store == null
        ? const <JamHistoryRecord>[]
        : await store.list();
    if (!mounted) return;
    final next = records.take(kJamHomeRecents).toList();
    if (next.length == _recents.length &&
        next.indexed.every(
          (e) =>
              e.$2.sessionId == _recents[e.$1].sessionId &&
              e.$2.updatedAt == _recents[e.$1].updatedAt,
        )) {
      return;
    }
    setState(() => _recents = next);
  }

  /// A past jam's detail page; Forget there has to take the row away
  /// here too.
  Future<void> _openRecent(JamHistoryRecord record) async {
    await showJamHistoryDetail(context, record);
    if (mounted) await _loadRecents();
  }

  Future<void> _refreshNetwork() async {
    final status = await currentNetwork();
    if (mounted && status.addresses.join() != _network.addresses.join()) {
      setState(() => _network = status);
    }
  }

  Future<void> _join(Uri joinUri, {String? roomName}) async {
    final session = JamSession.read(context);
    // One jam at a time: a live one is ended (or left) first, on the user's
    // say-so — the join used to be refused with nothing on screen.
    if (!await jamReadyForNewSession(context, session) || !mounted) return;
    // The local-network and notification asks land here, on a still screen,
    // rather than behind the row's own joining spinner.
    await session.prepareForSession();
    if (!mounted || session.isBusy) return;
    final joined = await session.join(joinUri, roomName: roomName);
    if (!mounted) return;
    if (joined) {
      unawaited(context.push('/room'));
    } else {
      _showError(session.error);
    }
  }

  /// A nearby room, tapped: verify it is still there, then join.
  ///
  /// mDNS says a room *was* advertised — a record outlives its room by up to
  /// two TTLs — so a tap on a host that has gone home used to sit on a
  /// spinner until the socket gave up. A probe is a TCP handshake with a
  /// sub-second budget: a ghost fails in a blink, says why, and leaves the
  /// list.
  Future<void> _joinNearby(JamNearbyRoom room) async {
    final session = JamSession.read(context);
    if (session.isBusy || _probing != null) return;
    final browser = session.browser;
    if (browser == null) {
      await _join(room.joinUri, roomName: room.sessionName);
      return;
    }
    setState(() => _probing = room.key);
    final alive = await browser.probe(room);
    if (!mounted) return;
    setState(() => _probing = null);
    if (!alive) {
      browser.remove(room);
      session.notify(kJamRoomGone);
      return;
    }
    await _join(room.joinUri, roomName: room.sessionName);
  }

  /// The fallback when there is no camera: someone sends you the link and
  /// you paste it.
  Future<void> _joinWithLink() async {
    final uri = await promptForJoinLink(context);
    if (uri == null || !mounted) return;
    await _join(uri, roomName: joinUriName(uri));
  }

  /// Opens Start a Jam, having already asked for everything a jam needs.
  ///
  /// Start a Jam's own spinner is what the notification prompt used to
  /// interrupt; asking on the way in means the prompts are answered before
  /// the button that spins even exists.
  Future<void> _host() async {
    final session = JamSession.read(context);
    if (!await jamReadyForNewSession(context, session) || !mounted) return;
    await session.prepareForSession();
    // A blank setup: nothing left over from a "Host Again" backed out of.
    session.hostSetupDraft = null;
    if (mounted) unawaited(context.push('/host'));
  }

  /// The nav-bar code action: the scanner where there is a camera, the Join
  /// with Link alert where there is not.
  void _scanOrLink() => unawaited(canScanQrCodes ? _scan() : _joinWithLink());

  Future<void> _scan() async {
    final scanned = await context.push<String>('/scan');
    if (scanned == null || !mounted) return;
    // The scanner hands back a raw string; parsing here keeps a mangled code
    // from becoming a FormatException inside the transport.
    final uri = parseJoinUri(scanned);
    if (uri == null) {
      _showError(HomeStrings.badCode);
      return;
    }
    await _join(uri, roomName: joinUriName(uri));
  }

  void _showError(String? message) {
    if (message == null || !mounted) return;
    JamSession.read(context).notify(message);
  }

  /// Marks which rooms are new, and buzzes for arrivals after the first
  /// paint. Called from the list builder, so it sees exactly what is drawn.
  Set<String> _arrivals(List<JamNearbyRoom> rooms) {
    final keys = {for (final room in rooms) room.key};
    final arrived = keys.difference(_seenRooms);
    _seenRooms
      ..retainWhere(keys.contains)
      ..addAll(keys);
    if (_firstRoomsBuild) {
      _firstRoomsBuild = false;
      return arrived;
    }
    if (arrived.isNotEmpty) JamHaptics.peerJoined();
    return arrived;
  }

  @override
  Widget build(BuildContext context) {
    final session = JamSession.of(context);
    // On a wide window the sidebar already carries identity and the
    // destinations, so repeating them in the nav bar is noise.
    final wide = context.jamBreakpoint.hasSidebar;
    final width = MediaQuery.sizeOf(context).width;

    final Widget? startButton = session.hasRoom
        ? null
        : JamButton.filled(
            label: HomeStrings.host,
            expand: true,
            onPressed: () => unawaited(_host()),
          );

    return ValueListenableBuilder<List<JamNearbyRoom>>(
      valueListenable: session.nearbyRooms,
      builder: (context, rooms, _) => JamScaffold(
        title: HomeStrings.title,
        automaticallyImplyLeading: false,
        trailing: [
          JamIconButton(
            icon: canScanQrCodes
                ? CupertinoIcons.qrcode_viewfinder
                : CupertinoIcons.link,
            semanticLabel: canScanQrCodes
                ? HomeStrings.scan
                : HomeStrings.joinWithLink,
            onPressed: _scanOrLink,
          ),
          if (!wide) ...[
            _AvatarButton(
              name: _identity,
              onTap: () => unawaited(context.push('/settings')),
            ),
            // The nav bar's own end inset is 4; a face wants iOS's 16.
            const SizedBox(width: JamSpace.xs),
          ],
        ],
        // A full-width capsule across a desktop pane would be a banner; on a
        // wide window it keeps a phone's width, centred.
        bottomBar: startButton == null
            ? null
            : width > _maxContentWidth
            ? Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 400),
                  child: startButton,
                ),
              )
            : startButton,
        slivers: [
          SliverConstrainedCrossAxis(
            maxExtent: _maxContentWidth,
            sliver: SliverMainAxisGroup(
              slivers: _content(context, session, rooms),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _content(
    BuildContext context,
    JamSessionController session,
    List<JamNearbyRoom> rooms,
  ) {
    final arrivals = _arrivals(rooms);
    final joining = session.joiningUri;
    final recents = _recents.isEmpty
        ? null
        : Padding(
            padding: const EdgeInsets.only(top: JamSpace.section),
            child: _RecentSection(
              records: _recents,
              onSeeAll: () => unawaited(context.push('/history')),
              onOpen: (record) => unawaited(_openRecent(record)),
            ),
          );

    if (rooms.isEmpty) {
      final empty = _EmptyNearby(
        network: _network,
        hosted: session.isLive
            ? (session.isHost ? _Hosting.host : _Hosting.guest)
            : null,
        roomName: session.engine?.sessionName ?? '',
        onScan: _scanOrLink,
        onOpenRoom: () => unawaited(context.push('/room')),
      );
      // Alone, the empty state sits in the middle of the page. With recent
      // jams under it, it keeps to its own height so they are on screen
      // rather than a scroll away.
      if (recents == null) {
        return [
          SliverFillRemaining(
            hasScrollBody: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: JamSpace.xxxl),
              child: empty,
            ),
          ),
        ];
      }
      return [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(
              top: JamSpace.huge,
              bottom: JamSpace.lg,
            ),
            child: empty,
          ),
        ),
        SliverToBoxAdapter(child: recents),
      ];
    }

    final busy = joining != null || _probing != null || session.isBusy;
    return [
      const SliverToBoxAdapter(child: SizedBox(height: JamSpace.xs)),
      SliverList.builder(
        itemCount: rooms.length,
        itemBuilder: (context, index) {
          final room = rooms[index];
          return _RoomRow(
            key: ValueKey(room.key),
            room: room,
            // One join at a time: the others go quiet rather than queueing
            // up handshakes behind the one in flight.
            joining: joining == room.joinUri || _probing == room.key,
            enabled: !busy,
            animateIn: arrivals.contains(room.key),
            separator: index < rooms.length - 1,
            onTap: () => unawaited(_joinNearby(room)),
          );
        },
      ),
      if (recents != null) SliverToBoxAdapter(child: recents),
    ];
  }
}

/// Your avatar in the nav bar: the way to Settings (and from there your
/// name), as in Apple Music and Invites.
class _AvatarButton extends StatelessWidget {
  const _AvatarButton({required this.name, required this.onTap});

  final String name;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      button: true,
      label: HomeStrings.settings,
      onTap: onTap,
      excludeSemantics: true,
      child: JamPressable(
        onTap: onTap,
        child: SizedBox(
          width: JamMetrics.hitTarget,
          height: JamMetrics.hitTarget,
          child: Center(
            child: name.isEmpty
                ? Icon(
                    CupertinoIcons.person_crop_circle,
                    size: JamAvatarSize.identity,
                    color: context.jamColors.tint,
                  )
                : JamAvatar(name: name, size: JamAvatarSize.identity),
          ),
        ),
      ),
    );
  }
}

/// One discoverable room: a plain row with the host's face, the room's name
/// and a tinted Join.
///
/// `JamNearbyRoom` carries only a key, a name and a join URI over mDNS, so
/// the row says nothing it cannot know — no listener count, no preset.
class _RoomRow extends StatelessWidget {
  const _RoomRow({
    super.key,
    required this.room,
    required this.onTap,
    this.joining = false,
    this.enabled = true,
    this.animateIn = false,
    this.separator = false,
  });

  final JamNearbyRoom room;
  final VoidCallback onTap;

  /// This is the row whose join is in flight.
  final bool joining;

  /// False while some other join or host start is running.
  final bool enabled;

  /// Whether this room was just discovered, and should rise into place.
  final bool animateIn;

  final bool separator;

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.disableAnimationsOf(context);
    final tap = enabled ? onTap : null;

    final row = Semantics(
      container: true,
      button: true,
      enabled: enabled || joining,
      label: joining
          ? HomeStrings.joining(room.sessionName)
          : HomeStrings.joinRoom(room.sessionName),
      onTap: tap,
      excludeSemantics: true,
      child: JamRow(
        title: room.sessionName,
        leading: JamAvatar(
          name: jamHostNameFromRoom(room.sessionName),
          size: JamAvatarSize.list,
        ),
        separator: separator,
        onTap: tap,
        trailing: JamButton.tinted(
          label: HomeStrings.join,
          size: JamButtonSize.small,
          loading: joining,
          onPressed: tap ?? (joining ? () {} : null),
        ),
      ),
    );

    if (!animateIn || still) return row;
    // A one-shot rise, with no controller of its own to keep alive: the
    // tween runs once on first build and the builder is never rebuilt again.
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: JamDuration.base,
      curve: JamCurve.standard,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset(0, (1 - t) * _roomEntryOffset),
          child: child,
        ),
      ),
      child: row,
    );
  }
}

/// The last few jams, as plain rows under a "Recent" header.
class _RecentSection extends StatelessWidget {
  const _RecentSection({
    required this.records,
    required this.onSeeAll,
    required this.onOpen,
  });

  final List<JamHistoryRecord> records;
  final VoidCallback onSeeAll;
  final ValueChanged<JamHistoryRecord> onOpen;

  @override
  Widget build(BuildContext context) {
    return JamSection.plain(
      header: HomeStrings.recent,
      headerTrailing: JamButton.plain(
        label: HomeStrings.seeAll,
        size: JamButtonSize.small,
        onPressed: onSeeAll,
      ),
      children: [
        for (final record in records)
          JamRow(
            key: ValueKey(record.sessionId),
            title: record.sessionName,
            subtitle: jamHistorySummary(record),
            subtitleMaxLines: 1,
            // The same covers Past Jams reads back off this device.
            leading: JamArtworkMosaic(
              tracks: record.tracks,
              size: JamArtworkSize.thumb,
              semanticLabel: HistoryStrings.cover(record.sessionName),
            ),
            leadingWidth: JamArtworkSize.thumb,
            onTap: () => onOpen(record),
          ),
      ],
    );
  }
}

/// Which side of a live session this device is on, for the empty state.
enum _Hosting { host, guest }

/// The "nothing nearby" situations, which need different actions.
///
/// Four, not three: the fourth is *you are the reason the list is empty*.
/// The browse stops while a jam runs, so a host looking at home was told
/// nobody was hosting over their own live room.
class _EmptyNearby extends StatelessWidget {
  const _EmptyNearby({
    required this.network,
    required this.onScan,
    this.hosted,
    this.roomName = '',
    this.onOpenRoom,
  });

  final JamNetworkStatus network;
  final VoidCallback onScan;

  /// Non-null while this device is in a jam of its own.
  final _Hosting? hosted;
  final String roomName;
  final VoidCallback? onOpenRoom;

  @override
  Widget build(BuildContext context) {
    final live = hosted;
    if (live != null) {
      return JamEmptyState(
        icon: CupertinoIcons.music_note_2,
        title: live == _Hosting.host
            ? HomeStrings.hostingTitle
            : HomeStrings.guestingTitle,
        body: live == _Hosting.host
            ? HomeStrings.hostingBody(roomName)
            : HomeStrings.guestingBody(roomName),
        actionLabel: onOpenRoom == null ? null : HomeStrings.openRoom,
        onAction: onOpenRoom,
        actionVariant: JamButtonVariant.plain,
      );
    }

    final (icon, title, body, showScan) = switch (network) {
      JamNetworkStatus(connected: false) => (
        CupertinoIcons.wifi_slash,
        HomeStrings.offlineTitle,
        HomeStrings.offlineBody,
        false,
      ),
      JamNetworkStatus(isHotspotHost: true) => (
        CupertinoIcons.qrcode,
        HomeStrings.hotspotTitle,
        HomeStrings.hotspotBody,
        true,
      ),
      _ => (
        CupertinoIcons.antenna_radiowaves_left_right,
        HomeStrings.quietTitle,
        HomeStrings.quietBody,
        true,
      ),
    };

    return JamEmptyState(
      icon: icon,
      title: title,
      body: body,
      // Quieter than Start a Jam, which owns the bottom of the screen.
      actionLabel: !showScan
          ? null
          : canScanQrCodes
          ? HomeStrings.scan
          : HomeStrings.joinWithLink,
      onAction: showScan ? onScan : null,
      actionVariant: JamButtonVariant.plain,
    );
  }
}
