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
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart';
import 'package:go_router/go_router.dart';
import 'package:localjam_client/localjam_client.dart';

import '../design/breakpoints.dart';
import '../design/tokens.dart';
import '../design/typography.dart';
import '../state/session_controller.dart';
import '../util/capabilities.dart';
import '../util/network.dart';
import '../widgets/avatar.dart';
import '../widgets/buttons.dart';
import '../widgets/brand.dart';
import '../widgets/empty_state.dart';
import '../widgets/jam_mark.dart';
import '../widgets/join_link_dialog.dart';
import '../widgets/list.dart';
import '../widgets/pressable.dart';
import '../widgets/room_sheet.dart' show showInviteSheet;
import '../widgets/scaffold.dart';
import '../widgets/section.dart';
import '../widgets/session_gate.dart';
import '../widgets/wifi_glyph.dart';
import 'history_screen.dart' show JamHistoryRow, showJamHistoryDetail;

/// Every user-facing string on this screen, in one place.
abstract final class HomeStrings {
  static const String title = 'Nearby';
  static const String join = 'Join';
  static String joining(String room) => 'Joining $room…';
  static String joinRoom(String room) => 'Join $room';

  /// The scanner — the same two words on every button that opens it, and
  /// the scanner's own title.
  static const String scan = 'Scan Code';
  static const String host = 'Start a Jam';

  /// The paste-a-link way in: the nav-bar action on platforms with no
  /// camera, and the one way in on those everywhere else on this screen.
  static const String joinWithLink = 'Join with Link';

  /// The same alert where there *is* a camera — named as the scanner names
  /// it, and offered beside Scan so a link sent in a chat never has to go
  /// through the camera's permission sheet first.
  static const String enterLink = 'Enter Link';

  static const String settings = 'Settings';
  static const String recent = 'Recent';
  static const String seeAll = 'See All';

  static const String offlineTitle = 'Not on Wi‑Fi';
  static const String offlineBody =
      'Join a Wi‑Fi network, or turn on your hotspot and have everyone '
      'connect to it.';

  /// This phone is *sharing* the hotspot, so it is almost always the host.
  static const String hotspotTitle = 'You’re Sharing a Hotspot';
  static const String hotspotBody =
      'Nearby jams can’t be listed over a hotspot. Start one here, or scan '
      'the host’s code.';

  /// Not "No Jams Nearby" under a large "Nearby": the page title already
  /// says where.
  static const String quietTitle = 'No Jams Yet';
  static const String quietBody =
      'When someone on this Wi‑Fi starts one, it shows up here.';

  /// The one-line versions, for when Recent is under them: the full empty
  /// state is for a screen that has nothing else to show.
  static const String offlineLine = 'Not on Wi‑Fi. Nearby jams need one.';
  static const String hotspotLine = 'Jams can’t be listed over your hotspot.';
  static const String quietLine = 'No jams nearby on this Wi‑Fi.';

  /// Under the rooms: mDNS misses jams (hotspots, client isolation), so the
  /// other ways in are offered right where a missing jam is noticed.
  static const String notListed = 'Don’t see your jam?';

  /// What home says while *this* device is in a jam: the jam itself (its
  /// mark, its name as the title) and your part in it. The mini player is
  /// the way back in, and the browse stops while a jam runs — "No Jams
  /// Nearby" over your own live room is a contradiction.
  static const String hostingEnds =
      'You’re hosting. Nearby jams show up again when it ends.';
  static const String guestingEnds =
      'You’re in this jam. Nearby jams show up again when you leave.';
  static const String invite = 'Invite People';

  /// The one-line versions, above Recent.
  static String hostingBody(String room) =>
      'Nearby jams show up again when $room ends.';
  static String guestingBody(String room) =>
      'Nearby jams show up again when you leave $room.';

  static const String badCode = 'That code isn’t a jam invite.';
}

/// The paste-a-link label, exported for the scanner's own fallback.
const String kJoinWithLink = HomeStrings.joinWithLink;

/// How many past jams the Recent section lists before "See All".
const int kJamHomeRecents = 3;

/// How far a newly discovered room rises into place.
const double _roomEntryOffset = 8;

/// The narrowest a nearby jam's name gets beside its Join, at 1× text:
/// narrower, and Join moves under the name.
const double _minNameWidth = 140;

/// The widest Start a Jam grows once the column is wider than a phone: a
/// full-width capsule across a desktop pane would be a banner.
const double _maxButtonWidth = 400;

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, this.networkReader, this.loadRecords});

  /// Optional data sources for deterministic previews and widget tests.
  final Future<JamNetworkStatus> Function()? networkReader;
  final Future<List<JamHistoryRecord>> Function()? loadRecords;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String _identity = '';
  JamNetworkStatus _network = JamNetworkStatus.offline;
  Timer? _networkPoll;
  List<JamHistoryRecord> _recents = const [];

  /// Rooms already on screen ([JamNearbyRoom.identity]), so only a *newly*
  /// discovered one animates in and buzzes — a rebuild is not an arrival,
  /// and nor is the same jam re-advertised under another mDNS name.
  final Set<String> _seenRooms = <String>{};
  bool _firstRoomsBuild = true;

  /// The identity of the room being verified right now, so its own row spins and
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
    // The ended page's "Scan New Code" came here for the scanner.
    if (!session.hasRoom && session.scanRequested) _scanWhenOnTop();
  }

  /// Opens the scanner (or Join with Link) that [JamSessionController.
  /// requestScan] asked for, once this page is the one on top: the room
  /// that asked is still on its way out when the request lands.
  void _scanWhenOnTop({int frames = 0}) {
    if (_scanScheduled) return;
    _scanScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scanScheduled = false;
      if (!mounted) return;
      final session = JamSession.read(context);
      if (session.hasRoom || !session.scanRequested) return;
      if (ModalRoute.of(context)?.isCurrent == false) {
        // Something is still over Home: look again next frame — for about
        // as long as a page takes to leave. A scanner that opened by itself
        // whenever Home next came back would be a surprise, not a follow-on.
        if (frames < _scanWaitFrames) {
          _scanWhenOnTop(frames: frames + 1);
        } else {
          session.takeScanRequest();
        }
        return;
      }
      if (session.takeScanRequest()) _scanOrLink();
    });
    // The callback needs a frame to run in, even on a page sitting still.
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  bool _scanScheduled = false;

  /// How many frames a scan request waits for Home to be on top.
  static const int _scanWaitFrames = 90;

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
    final loader = widget.loadRecords;
    final store = loader == null ? await JamHistoryStore.open() : null;
    final records = loader != null
        ? await loader()
        : store == null
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
    final status = await (widget.networkReader ?? currentNetwork)();
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
    setState(() => _probing = room.identity);
    final alive = await browser.probe(room);
    if (!mounted) return;
    setState(() => _probing = null);
    if (!alive) {
      browser.remove(room);
      session.notify(kJamRoomGone, tone: JamNoticeTone.neutral);
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

  /// The ways in that are not a nearby row, for the one-line states: Scan
  /// and Enter Link where there is a camera — the link straight to its
  /// alert, never through the camera's permission sheet — and Join with
  /// Link where there is not.
  List<_LineAction> get _waysIn => [
    if (canScanQrCodes) (HomeStrings.scan, () => unawaited(_scan())),
    (
      canScanQrCodes ? HomeStrings.enterLink : HomeStrings.joinWithLink,
      () => unawaited(_joinWithLink()),
    ),
  ];

  /// The live jam's Invite sheet, for a host who has come back to Home.
  void _invite(JamEngine engine) => unawaited(
    showInviteSheet(context, engine, selfName: _identity, network: _network),
  );

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
    JamSession.read(context).notify(message, tone: JamNoticeTone.error);
  }

  /// Marks which rooms are new, and buzzes for arrivals after the first
  /// paint. Called from the list builder, so it sees exactly what is drawn.
  Set<String> _arrivals(List<JamNearbyRoom> rooms) {
    final keys = {for (final room in rooms) room.identity};
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
        leading: wide ? null : const JamWordmark(),
        trailing: [
          JamIconButton(
            icon: canScanQrCodes
                ? CupertinoIcons.qrcode_viewfinder
                : CupertinoIcons.link,
            semanticLabel: canScanQrCodes
                ? HomeStrings.scan
                : HomeStrings.joinWithLink,
            // The viewfinder glyph draws small inside its em box; at 25 it
            // holds its own beside the 30 pt avatar.
            size: 25,
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
        // The scaffold holds the page to the reading column, centred in
        // the pane (not the window); wider than a phone, the capsule keeps
        // a phone's width on the column's axis.
        maxContentWidth: JamContentWidth.reading,
        bottomBar: startButton == null
            ? null
            : Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: _maxButtonWidth),
                  child: startButton,
                ),
              ),
        slivers: _content(context, session, rooms),
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
    // The jam this device is in is the mini player's to show. Listing it in
    // Recent as well put the same jam on screen two or three times.
    final liveId = session.engine?.sessionId;
    final records = [
      for (final record in _recents)
        if (record.sessionId != liveId) record,
    ];
    final recents = records.isEmpty
        ? null
        : Padding(
            // The header row is a 44 hit target around a 25 line; this
            // lands its text ~32 under the last row, the section gap.
            padding: const EdgeInsets.only(top: JamSpace.lg),
            child: _RecentSection(
              records: records,
              self: _identity,
              onSeeAll: () => unawaited(context.push('/history')),
              onOpen: (record) => unawaited(_openRecent(record)),
            ),
          );

    if (rooms.isEmpty) {
      final engine = session.engine;
      // In a jam, or with Recent to show, "nothing nearby" is one quiet
      // line rather than a 230 pt block that pushes Recent to mid-screen.
      if (session.isLive && engine != null) {
        final room = engine.sessionName;
        if (recents == null) {
          // Nothing else on the page: say whose jam this is, as a jam —
          // and offer the host the thing they most likely came back for.
          return [
            jamAnchoredEmptyState(
              JamEmptyState(
                // The cover the mini player under it shows: one jam, one
                // object. No face — on your own jam it would be yours.
                mark: _LiveJamMark(engine: engine),
                title: room,
                body: session.isHost
                    ? HomeStrings.hostingEnds
                    : HomeStrings.guestingEnds,
                actionLabel: session.isHost ? HomeStrings.invite : null,
                onAction: session.isHost ? () => _invite(engine) : null,
                actionVariant: JamButtonVariant.gray,
              ),
            ),
          ];
        }
        return [
          SliverToBoxAdapter(
            child: _NearbyLine(
              text: session.isHost
                  ? HomeStrings.hostingBody(room)
                  : HomeStrings.guestingBody(room),
            ),
          ),
          SliverToBoxAdapter(child: recents),
        ];
      }
      if (recents != null) {
        return [
          SliverToBoxAdapter(
            child: _NearbyLine.forNetwork(_network, actions: _waysIn),
          ),
          SliverToBoxAdapter(child: recents),
        ];
      }
      return [
        jamAnchoredEmptyState(
          _EmptyNearby(
            network: _network,
            onScan: _scanOrLink,
            onLink: canScanQrCodes ? () => unawaited(_joinWithLink()) : null,
          ),
        ),
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
            key: ValueKey(room.identity),
            room: room,
            // One join at a time: the others go quiet rather than queueing
            // up handshakes behind the one in flight.
            joining: joining == room.joinUri || _probing == room.identity,
            enabled: !busy,
            animateIn: arrivals.contains(room.identity),
            onTap: () => unawaited(_joinNearby(room)),
          );
        },
      ),
      SliverToBoxAdapter(
        child: _NearbyLine(text: HomeStrings.notListed, actions: _waysIn),
      ),
      if (recents != null) SliverToBoxAdapter(child: recents),
    ];
  }
}

/// A one-line state's action: its label and what it does.
typedef _LineAction = (String, VoidCallback);

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

/// The jam this phone is in, as Home's page draws it: its mark with the
/// cover that is playing — the one the mini player under it shows, and the
/// Invite sheet's — and its monogram until something with a cover plays.
class _LiveJamMark extends StatefulWidget {
  const _LiveJamMark({required this.engine});

  final JamEngine engine;

  @override
  State<_LiveJamMark> createState() => _LiveJamMarkState();
}

class _LiveJamMarkState extends State<_LiveJamMark> {
  StreamSubscription<PlaybackSnapshot>? _states;

  /// The cover being shown, and the artwork it was read for.
  String? _artworkId;
  Uint8List? _cover;

  @override
  void initState() {
    super.initState();
    _bind();
  }

  @override
  void didUpdateWidget(_LiveJamMark old) {
    super.didUpdateWidget(old);
    if (!identical(old.engine, widget.engine)) _bind();
  }

  @override
  void dispose() {
    unawaited(_states?.cancel());
    super.dispose();
  }

  void _bind() {
    unawaited(_states?.cancel());
    _states = widget.engine.states.listen((_) => _follow());
    _follow();
  }

  /// Reads the playing song's cover when the song changes. The engines
  /// cache what they have read, so a song that comes back costs nothing.
  void _follow() {
    final item = widget.engine.currentItem;
    final id = item?.artworkId;
    if (id == _artworkId) return;
    _artworkId = id;
    if (id == null) {
      if (_cover != null && mounted) setState(() => _cover = null);
      return;
    }
    unawaited(
      widget.engine.artworkFor(item!).then((bytes) {
        if (!mounted || _artworkId != id) return;
        setState(() => _cover = bytes == null || bytes.isEmpty ? null : bytes);
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cover = _cover;
    const size = JamMarkSize.row;
    final px = (size * MediaQuery.devicePixelRatioOf(context)).round();
    return JamMark(
      name: widget.engine.sessionName,
      size: size,
      covers: [
        if (cover != null)
          ResizeImage(MemoryImage(cover), width: px, height: px),
      ],
    );
  }
}

/// One discoverable room, as a jam: its mark, its name in Manrope, and a
/// tinted Join — on a card of its own, the whole card the target.
///
/// `JamNearbyRoom` carries only a key, a name and a join URI over mDNS, so
/// the row says nothing it cannot know — no listener count, no preset, no
/// cover, no face. The mark is the name's monogram: a jam called "Mia’s
/// Jam" may well not be Mia's, so no face is guessed from it.
class _RoomRow extends StatelessWidget {
  const _RoomRow({
    super.key,
    required this.room,
    required this.onTap,
    this.joining = false,
    this.enabled = true,
    this.animateIn = false,
  });

  final JamNearbyRoom room;
  final VoidCallback onTap;

  /// This is the row whose join is in flight.
  final bool joining;

  /// False while some other join or host start is running.
  final bool enabled;

  /// Whether this room was just discovered, and should rise into place.
  final bool animateIn;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final still = MediaQuery.disableAnimationsOf(context);
    final tap = enabled ? onTap : null;
    final name = room.sessionName;
    final side = JamSpace.pageFor(MediaQuery.sizeOf(context).width);
    // The card's corner, concentric with the mark's at the card's padding.
    final radius = BorderRadius.circular(JamRadius.section);

    final body = Padding(
      padding: const EdgeInsets.all(JamSpace.md),
      child: Row(
        children: [
          // `fill`, not the mark's usual ground: on the card's surface
          // `fillSecondary` all but disappears in dark.
          JamMark(name: name, size: JamMarkSize.nearby, ground: colors.fill),
          const SizedBox(width: kJamRowLeadingGap),
          Expanded(
            // Join beside the name while the name keeps a readable
            // width; under it at large text or on a narrow phone, so a
            // name is never squeezed to a sliver.
            child: _BesideOrBelow(
              minLeadWidth: MediaQuery.textScalerOf(
                context,
              ).scale(_minNameWidth),
              lead: Text(
                name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                // A jam's name is a named thing: Manrope, at row scale.
                style: context.jamNameRow,
              ),
              trailing: JamButton.tinted(
                label: HomeStrings.join,
                size: JamButtonSize.small,
                loading: joining,
                onPressed: tap ?? (joining ? () {} : null),
              ),
            ),
          ),
        ],
      ),
    );

    final card = Padding(
      padding: EdgeInsets.fromLTRB(side, JamSpace.xs, side, JamSpace.xs),
      child: Semantics(
        container: true,
        button: true,
        enabled: enabled || joining,
        label: joining ? HomeStrings.joining(name) : HomeStrings.joinRoom(name),
        onTap: tap,
        excludeSemantics: true,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colors.groupedSurface,
            border: Border.all(
              color: colors.separator,
              width: JamHairline.thicknessOf(context),
            ),
            borderRadius: radius,
          ),
          child: JamPressable(
            onTap: tap,
            style: JamPressStyle.highlight,
            borderRadius: radius,
            child: body,
          ),
        ),
      ),
    );
    if (!animateIn || still) return card;
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
      child: card,
    );
  }
}

/// The last few jams under a "Recent" header — each one the row Past Jams
/// draws it with (`JamHistoryRow`): its mark, its name, who was there, what
/// it was and when.
class _RecentSection extends StatelessWidget {
  const _RecentSection({
    required this.records,
    required this.self,
    required this.onSeeAll,
    required this.onOpen,
  });

  final List<JamHistoryRecord> records;

  /// This device's name, for the faces' colours.
  final String self;
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
        for (final (i, record) in records.indexed)
          JamHistoryRow(
            key: ValueKey(record.sessionId),
            record: record,
            self: self,
            separator: i < records.length - 1,
            onTap: () => onOpen(record),
          ),
      ],
    );
  }
}

/// "Nothing nearby" (or "not listed") as one quiet line, for a Home that
/// has other things on it: the rooms above, Recent below, or the mini
/// player of the jam you are in.
class _NearbyLine extends StatelessWidget {
  const _NearbyLine({required this.text, this.actions = const []});

  /// The line for this network, with the other ways in where they help.
  factory _NearbyLine.forNetwork(
    JamNetworkStatus network, {
    required List<_LineAction> actions,
  }) => switch (network) {
    // Nothing to scan or paste into without a network.
    JamNetworkStatus(connected: false) => const _NearbyLine(
      text: HomeStrings.offlineLine,
    ),
    JamNetworkStatus(isHotspotHost: true) => _NearbyLine(
      text: HomeStrings.hotspotLine,
      actions: actions,
    ),
    _ => _NearbyLine(text: HomeStrings.quietLine, actions: actions),
  };

  final String text;
  final List<_LineAction> actions;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final sentence = Text(
      text,
      style: context.jamSubheadline.copyWith(color: colors.secondaryLabel),
    );
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: JamMetrics.rowHeight),
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(
          kJamRowInset,
          JamSpace.xs,
          kJamRowInset,
          JamSpace.xs,
        ),
        child: Align(
          alignment: AlignmentDirectional.centerStart,
          child: actions.isEmpty
              ? sentence
              // The sentence on one line with the buttons beside it; when
              // that does not fit (a narrow phone, large text) the sentence
              // has the line to itself and the buttons go under it — never
              // a sentence squeezed into a column beside them.
              : _BesideOrBelow(
                  gap: JamSpace.md,
                  leadOnOneLine: true,
                  lead: sentence,
                  // Small neutral buttons, not bare words: beside a
                  // sentence, two tinted words read as its last phrase
                  // ("…Wi‑Fi. Scan Code Enter Link"). Neutral, so they never
                  // pose as a room's Join.
                  trailing: Wrap(
                    spacing: JamSpace.sm,
                    children: [
                      for (final (label, onPressed) in actions)
                        JamButton.gray(
                          label: label,
                          size: JamButtonSize.small,
                          onPressed: onPressed,
                        ),
                    ],
                  ),
                ),
        ),
      ),
    );
  }
}

/// [lead] with [trailing] beside it while there is room, and under it when
/// there is not.
///
/// Beside: [lead] gets the width [trailing] leaves (less [gap]) — as long as
/// that is at least [minLeadWidth], or, with [leadOnOneLine], as long as it
/// holds [lead] on one line — and the two are centred on each other.
/// Otherwise [lead] takes the full width and [trailing] sits under it, at
/// its start, [runGap] below.
///
/// Neither a `Row` (which squeezes [lead] to a sliver, then overflows) nor a
/// `Wrap` (which moves [trailing] down as soon as [lead] would wrap at all)
/// makes that choice.
class _BesideOrBelow extends MultiChildRenderObjectWidget {
  _BesideOrBelow({
    required Widget lead,
    required Widget trailing,
    this.gap = JamSpace.sm,
    this.minLeadWidth = 0,
    this.leadOnOneLine = false,
  }) : super(children: [lead, trailing]);

  final double gap;
  final double minLeadWidth;
  final bool leadOnOneLine;

  /// Between [lead] and [trailing] when stacked. A small button's 44 pt hit
  /// area already pads it.
  static const double runGap = JamSpace.xs;

  @override
  _RenderBesideOrBelow createRenderObject(BuildContext context) =>
      _RenderBesideOrBelow(
        gap,
        minLeadWidth,
        leadOnOneLine,
        Directionality.of(context),
      );

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderBesideOrBelow renderObject,
  ) {
    renderObject
      ..gap = gap
      ..minLeadWidth = minLeadWidth
      ..leadOnOneLine = leadOnOneLine
      ..textDirection = Directionality.of(context);
  }
}

class _BesideOrBelowParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderBesideOrBelow extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _BesideOrBelowParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _BesideOrBelowParentData> {
  _RenderBesideOrBelow(
    this._gap,
    this._minLeadWidth,
    this._leadOnOneLine,
    this._textDirection,
  );

  double _gap;
  set gap(double value) {
    if (value == _gap) return;
    _gap = value;
    markNeedsLayout();
  }

  double _minLeadWidth;
  set minLeadWidth(double value) {
    if (value == _minLeadWidth) return;
    _minLeadWidth = value;
    markNeedsLayout();
  }

  bool _leadOnOneLine;
  set leadOnOneLine(bool value) {
    if (value == _leadOnOneLine) return;
    _leadOnOneLine = value;
    markNeedsLayout();
  }

  TextDirection _textDirection;
  set textDirection(TextDirection value) {
    if (value == _textDirection) return;
    _textDirection = value;
    markNeedsLayout();
  }

  RenderBox get _lead => firstChild!;
  RenderBox get _trailing => lastChild!;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _BesideOrBelowParentData) {
      child.parentData = _BesideOrBelowParentData();
    }
  }

  /// Lays both out (or measures them, [dry]) and returns the size.
  Size _layout(BoxConstraints constraints, {required bool dry}) {
    assert(constraints.hasBoundedWidth);
    final width = constraints.maxWidth;
    Size measure(RenderBox child, double maxWidth) {
      final c = BoxConstraints(maxWidth: math.max(0, maxWidth));
      if (dry) return child.getDryLayout(c);
      child.layout(c, parentUsesSize: true);
      return child.size;
    }

    final trailing = measure(_trailing, width);
    final room = width - trailing.width - _gap;
    final need = _leadOnOneLine
        ? _lead.getMaxIntrinsicWidth(double.infinity)
        : _minLeadWidth;
    final beside = room >= need;
    final lead = measure(_lead, beside ? room : width);
    final height = beside
        ? math.max(lead.height, trailing.height)
        : lead.height + _BesideOrBelow.runGap + trailing.height;
    if (!dry) {
      final rtl = _textDirection == TextDirection.rtl;
      double start(double childWidth) => rtl ? width - childWidth : 0;
      double end(double childWidth) => rtl ? 0 : width - childWidth;
      (_lead.parentData! as _BesideOrBelowParentData).offset = Offset(
        start(lead.width),
        beside ? (height - lead.height) / 2 : 0,
      );
      (_trailing.parentData! as _BesideOrBelowParentData).offset = beside
          ? Offset(end(trailing.width), (height - trailing.height) / 2)
          : Offset(start(trailing.width), lead.height + _BesideOrBelow.runGap);
    }
    return constraints.constrain(Size(width, height));
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      _layout(constraints, dry: true);

  @override
  void performLayout() => size = _layout(constraints, dry: false);

  @override
  double computeMinIntrinsicWidth(double height) => math.max(
    _lead.getMinIntrinsicWidth(height),
    _trailing.getMinIntrinsicWidth(height),
  );

  @override
  double computeMaxIntrinsicWidth(double height) =>
      _lead.getMaxIntrinsicWidth(height) +
      _gap +
      _trailing.getMaxIntrinsicWidth(height);

  @override
  double computeMinIntrinsicHeight(double width) =>
      _layout(BoxConstraints(maxWidth: width), dry: true).height;

  @override
  double computeMaxIntrinsicHeight(double width) =>
      computeMinIntrinsicHeight(width);

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}

/// The "nothing nearby" situations, which need different actions — on a
/// Home with nothing else to show.
class _EmptyNearby extends StatelessWidget {
  const _EmptyNearby({
    required this.network,
    required this.onScan,
    this.onLink,
  });

  final JamNetworkStatus network;

  /// The scanner, or Join with Link where there is no camera.
  final VoidCallback onScan;

  /// Enter Link beside the scanner, where there is one: a link sent in a
  /// chat goes straight to its alert, not through the camera's sheet.
  final VoidCallback? onLink;

  @override
  Widget build(BuildContext context) {
    final (icon, title, body, showScan) = switch (network) {
      // Drawn rather than CupertinoIcons' solid wedge, so it is the same
      // outline family as the other states' glyphs.
      JamNetworkStatus(connected: false) => (
        null,
        HomeStrings.offlineTitle,
        HomeStrings.offlineBody,
        false,
      ),
      JamNetworkStatus(isHotspotHost: true) => (
        // The same viewfinder the nav bar and the camera primer show.
        CupertinoIcons.qrcode_viewfinder,
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
      mark: icon == null ? const JamWifiGlyph(slashed: true) : null,
      title: title,
      body: body,
      // Neutral — quieter than Start a Jam, which owns the bottom of the
      // screen — with the link plainly under it: a button and its
      // alternative, not two loose words.
      actionLabel: !showScan
          ? null
          : canScanQrCodes
          ? HomeStrings.scan
          : HomeStrings.joinWithLink,
      onAction: showScan ? onScan : null,
      actionVariant: JamButtonVariant.gray,
      secondaryActionLabel: showScan && onLink != null
          ? HomeStrings.enterLink
          : null,
      onSecondaryAction: showScan ? onLink : null,
    );
  }
}
