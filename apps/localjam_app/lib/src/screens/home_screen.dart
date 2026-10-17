/// Home: a live view of what is around you.
///
/// Not a landing page. The app is already installed, so nothing here explains
/// the product — no wordmark, no icon hero, no "no internet, no accounts".
/// The screen's whole job is to answer "is there a jam here?" before you tap
/// anything, which is why the mDNS browse runs here rather than one screen
/// deeper.
///
/// The three empty states are the important part. On a trip, "nothing nearby"
/// usually means either *no network at all* (turn on a hotspot) or *you are on
/// a hotspot, where mDNS does not travel* (scan the code). Those need opposite
/// actions, so the screen reads the network instead of showing one shrug.
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:localjam_client/localjam_client.dart';

import '../design/breakpoints.dart';
import '../design/tokens.dart';
import '../design/typography.dart';
import '../state/session_controller.dart';
import '../util/capabilities.dart';
import '../util/network.dart';
import 'history_screen.dart' show JamArtworkMosaic, jamRelativeTime;
import '../widgets/avatar.dart';
import '../widgets/buttons.dart';
import '../widgets/empty_state.dart';
import '../widgets/join_link_dialog.dart';
import '../widgets/rename_dialog.dart';

/// Every user-facing string on this screen, in one place.
abstract final class HomeStrings {
  static const String title = 'Nearby';
  static const String listening = 'Listening for rooms';
  static const String tapToJoin = 'Tap to join';
  static const String join = 'Join';
  static String joining(String room) => 'Joining $room…';
  static String joinRoom(String room) => 'Join $room';

  static const String scan = 'Scan code';
  static const String host = 'Start a jam';

  /// One label for the paste-a-link way in, used by every affordance that
  /// offers it (the overflow menu, the empty states, the scanner's fallback).
  static const String joinWithLink = 'Join with a link';

  static const String pastJams = 'Past jams';
  static const String settings = 'Settings';
  static const String recently = 'RECENTLY';
  static const String seeAll = 'See all';
  static const String rename = 'Change your name';

  static const String offlineTitle = 'No network';
  static const String offlineBody =
      'Join a Wi-Fi network, or turn on your hotspot and let everyone '
      'connect to it.';
  static const String hotspotTitle = 'Nothing nearby';
  static const String hotspotBody =
      'Rooms do not announce themselves across a hotspot. Scan the host’s '
      'code to get in.';
  static const String quietTitle = 'Nothing nearby';
  static const String quietBody = 'Nobody on this network is hosting yet.';

  /// What home says while *this* device is the one hosting. "Nobody is
  /// hosting yet" over a live room of your own was the review's flat
  /// contradiction.
  static String hostingTitle(String room) => 'You’re hosting $room';
  static const String hostingBody =
      'Your room is running. Nearby rooms come back when it ends.';
  static String guestingTitle(String room) => 'You’re in $room';
  static const String guestingBody =
      'Nearby rooms come back when you leave this one.';
  static const String openRoom = 'Open the room';

  static const String badCode = 'That code is not a jam invite.';
}

/// The paste-a-link label, exported for the scanner's own fallback.
const String kJoinWithLink = HomeStrings.joinWithLink;

/// Half a breath of the discovery dot, and the fade inside it. The fade is
/// deliberately shorter than the beat: the still moment between them is what
/// keeps the frame scheduler from running forever.
const Duration _pulseHalf = Duration(milliseconds: 800);
const Duration _pulseFade = Duration(milliseconds: 600);

/// How far a newly discovered room rises into place.
const double _roomEntryOffset = 12;

/// The scroll distance over which the large title dissolves under the bar.
const double _kTitleFade = 36;

/// Cards on the recents rail.
///
/// 168 rather than the spec's 152: at 152 a two-word room name — "Bibek's
/// Jam" — ellipsised on every card, and a rail of "Bibek's J…" says nothing.
/// The name also gets two lines now, which is what the extra width is for.
const double _recentCardWidth = 168;
const double _recentMosaic = _recentCardWidth - JamSpace.md * 2;
const int _recentTitleLines = 2;
const int _maxRecents = 5;

/// The rail's height, measured rather than hard-coded.
///
/// It used to be a const built from literal line heights (22 and 20), which
/// is a bet that nobody turns type up: at XXL those two lines are 40 dp
/// taller than the box holding them and the whole rail overflowed. Reading
/// the styles back through the ambient [TextScaler] makes the card grow with
/// the words instead.
double jamRecentCardHeight(BuildContext context) {
  final scaler = MediaQuery.textScalerOf(context);
  // Rounded up per line, plus a hair: a laid-out line runs a fraction over
  // `fontSize × height` once the font's own metrics are applied, and a card
  // that is right to the last tenth of a pixel is a card that overflows.
  double lineOf(TextStyle style) =>
      (scaler.scale(style.fontSize ?? 14) * (style.height ?? 1.3))
          .ceilToDouble();
  return _recentMosaic +
      JamSpace.md * 2 +
      JamSpace.md +
      lineOf(context.jamRowTitle) * _recentTitleLines +
      JamSpace.xxs +
      lineOf(context.jamFootnote) +
      JamSpace.xs;
}

/// How tall the blurred bottom bar is, above the home indicator.
///
/// The bar is drawn over the scroll view (`extendBody`), so the list has to
/// know how much of its own tail is underneath it: 12 padding, a 52 dp button
/// row, 4, the 44 dp tertiary, 12 padding.
const double kJamHomeActionsHeight =
    JamSpace.md + 52 + JamSpace.xs + 44 + JamSpace.md;

/// How much of the viewport the "nothing nearby" block reaches for, and the
/// height it aims for on a tall window. It no longer fills the viewport, so
/// the recents rail under it is on screen rather than a scroll away.
const double _emptyMaxFraction = 0.6;
const double _emptyMinHeight = 320;

/// The least the "nothing nearby" block gets, however tight the window.
const double _emptyMinRoom = 200;

/// "RECENTLY" over a 44 dp tertiary — one tap target tall.
const double _kRailHeaderHeight = 44;

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String _identity = '';

  /// How far the page has scrolled, normalised over [_kTitleFade].
  ///
  /// Drives two things at once: the large title fading out as it goes under
  /// the identity bar, and the hairline that appears under that bar. Without
  /// them a half-cut "Nearby" hung in the gap between the two, which reads as
  /// a clipping bug rather than as a scroll.
  final ValueNotifier<double> _scrolled = ValueNotifier<double>(0);
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
    _scrolled.dispose();
    super.dispose();
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    final pixels = notification.metrics.pixels;
    final next = (pixels / _kTitleFade).clamp(0.0, 1.0);
    if ((next - _scrolled.value).abs() > 0.01) _scrolled.value = next;
    return false;
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
    final next = records.take(_maxRecents).toList();
    if (next.length == _recents.length &&
        next.indexed.every((e) => e.$2.sessionId == _recents[e.$1].sessionId)) {
      return;
    }
    setState(() => _recents = next);
  }

  Future<void> _refreshNetwork() async {
    final status = await currentNetwork();
    if (mounted && status.addresses.join() != _network.addresses.join()) {
      setState(() => _network = status);
    }
  }

  Future<void> _rename() async {
    final name = await promptForName(context, current: _identity);
    if (name == null) return;
    await JamIdentity.setDisplayName(name);
    if (mounted) setState(() => _identity = name);
  }

  Future<void> _join(Uri joinUri, {String? roomName}) async {
    final session = JamSession.read(context);
    if (session.isBusy) return;
    // The local-network and notification asks land here, on a still screen,
    // rather than behind the row's own joining spinner.
    await session.prepareForSession();
    if (!mounted || session.isBusy) return;
    final joined = await session.join(joinUri, roomName: roomName);
    if (!mounted) return;
    if (joined) {
      context.push('/room');
    } else {
      _showError(session.error);
    }
  }

  /// The fallback when there is no camera, no mDNS, or both: someone sends
  /// you the link and you paste it.
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

  Future<void> _joinWithLink() async {
    final uri = await promptForJoinLink(context);
    if (uri == null || !mounted) return;
    await _join(uri, roomName: joinUriName(uri));
  }

  /// Opens host setup, having already asked for everything a jam needs.
  ///
  /// Host setup's own "Start the jam" spinner is what the notification prompt
  /// used to interrupt; asking on the way in means the prompts are answered
  /// before the button that spins even exists.
  Future<void> _host() async {
    final session = JamSession.read(context);
    await session.prepareForSession();
    if (mounted) context.push('/host');
  }

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
    // destinations, so repeating them in an app bar is noise.
    final wide = context.jamBreakpoint.hasSidebar;

    return Scaffold(
      // The blurred bar is drawn *over* the list, so the recents rail has
      // something to pass under instead of being sliced by it.
      extendBody: true,
      appBar: wide
          ? null
          : AppBar(
              toolbarHeight: 56,
              titleSpacing: JamSpace.page,
              // Opaque, and its own colour: a transparent bar let the large
              // title's descenders show through as it scrolled past.
              backgroundColor: context.jamColors.canvas,
              surfaceTintColor: Colors.transparent,
              scrolledUnderElevation: 0,
              bottom: _ScrolledUnderRule(progress: _scrolled),
              title: _IdentityButton(name: _identity, onTap: _rename),
              actions: [
                IconButton(
                  icon: const Icon(Icons.history_rounded),
                  tooltip: HomeStrings.pastJams,
                  onPressed: () => context.push('/history'),
                ),
                IconButton(
                  icon: const Icon(Icons.settings_rounded),
                  tooltip: HomeStrings.settings,
                  onPressed: () => context.push('/settings'),
                ),
                const SizedBox(width: JamSpace.sm),
              ],
            ),
      body: SafeArea(
        top: false,
        // Rows stretched across a 1300px window are unreadable; hold the
        // content to a column and centre it in the detail pane.
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: JamContentWidth.reading,
            ),
            child: NotificationListener<ScrollNotification>(
              onNotification: _onScroll,
              child: ValueListenableBuilder<List<JamNearbyRoom>>(
                valueListenable: session.nearbyRooms,
                builder: (context, rooms, _) =>
                    _body(context, session, rooms, wide: wide),
              ),
            ),
          ),
        ),
      ),
      // While a jam is live the docked room bar takes this slot — and both
      // of these actions would be no-ops, since a session can only start
      // from idle.
      bottomNavigationBar: session.isLive || wide
          ? null
          : _HomeActions(
              onScan: () => unawaited(_scan()),
              onHost: () => unawaited(_host()),
              onLink: () => unawaited(_joinWithLink()),
            ),
    );
  }

  Widget _body(
    BuildContext context,
    JamSessionController session,
    List<JamNearbyRoom> rooms, {
    required bool wide,
  }) {
    final arrivals = _arrivals(rooms);
    final joining = session.joiningUri;
    // What sits below the nearby block: the rail, and the bar the list has to
    // end clear of.
    final railSpace = _recents.isEmpty
        ? 0.0
        : JamSpace.section +
              _kRailHeaderHeight +
              JamSpace.md +
              jamRecentCardHeight(context) +
              // A breath, so the card's own bottom padding clears the bar's
              // hairline rather than kissing it.
              JamSpace.md;
    // What the bar itself covers, and the tail the list ends with. The
    // arithmetic below reserves only the bar: the 24 dp of air after it is
    // there for a *scrolled* page, and spending it at rest is what pushed the
    // rail's last few pixels back under the bar.
    final barSpace = wide || session.isLive
        ? 0.0
        : kJamHomeActionsHeight + MediaQuery.paddingOf(context).bottom;
    final tail = JamSpace.xxl + barSpace;

    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(
            JamSpace.page,
            JamSpace.sm,
            JamSpace.page,
            JamSpace.xxl,
          ),
          sliver: SliverToBoxAdapter(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Semantics(
                        header: true,
                        child: ValueListenableBuilder<double>(
                          valueListenable: _scrolled,
                          builder: (context, t, child) =>
                              Opacity(opacity: 1 - t, child: child),
                          child: Text(
                            HomeStrings.title,
                            style: context.jamLargeTitle,
                          ),
                        ),
                      ),
                      const SizedBox(height: JamSpace.xs),
                      if (session.discovering) const _ListeningFootnote(),
                    ],
                  ),
                ),
                // Wide layouts have no bottom bar, so the ways in sit beside
                // the title instead.
                if (wide)
                  _HomeActions(
                    onScan: () => unawaited(_scan()),
                    onHost: () => unawaited(_host()),
                    onLink: () => unawaited(_joinWithLink()),
                    inline: true,
                  ),
              ],
            ),
          ),
        ),
        if (rooms.isEmpty)
          // Sized to its content, not to the viewport. `SliverFillRemaining`
          // pushed the recents rail a whole screen below the fold — the rail
          // is the second thing this page has to offer and nobody scrolled
          // far enough to find it.
          SliverLayoutBuilder(
            builder: (context, constraints) => SliverToBoxAdapter(
              child: ConstrainedBox(
                // A floor, never a ceiling: the block gets a comfortable
                // stretch of a tall window and its own height on a short one.
                // Capping it instead would only move the overflow.
                //
                // What it may *not* do is push the recents rail under the
                // bottom bar. The sliver knows how much of the page is above
                // it, and the rail and the bar are both measurable, so the
                // leftover is arithmetic rather than a guess.
                constraints: BoxConstraints(
                  minHeight: math.min(
                    math.min(
                      _emptyMinHeight,
                      constraints.viewportMainAxisExtent * _emptyMaxFraction,
                    ),
                    math.max(
                      _emptyMinRoom,
                      constraints.viewportMainAxisExtent -
                          constraints.precedingScrollExtent -
                          railSpace -
                          barSpace,
                    ),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: JamSpace.xxl),
                  child: _EmptyNearby(
                    network: _network,
                    hosted: session.isLive
                        ? (session.isHost ? _Hosting.host : _Hosting.guest)
                        : null,
                    roomName: session.engine?.sessionName ?? '',
                    onScan: () => unawaited(_scan()),
                    onOpenRoom: () => context.push('/room'),
                  ),
                ),
              ),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: JamSpace.page),
            sliver: SliverList.separated(
              itemCount: rooms.length,
              separatorBuilder: (_, _) => const SizedBox(height: JamSpace.md),
              itemBuilder: (context, index) {
                final room = rooms[index];
                return _RoomCard(
                  key: ValueKey(room.key),
                  room: room,
                  // One join at a time: the others go quiet rather than
                  // queueing up handshakes behind the one in flight.
                  joining: joining == room.joinUri || _probing == room.key,
                  enabled:
                      joining == null && _probing == null && !session.isBusy,
                  animateIn: arrivals.contains(room.key),
                  onTap: () => unawaited(_joinNearby(room)),
                );
              },
            ),
          ),
        if (_recents.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(top: JamSpace.section),
              child: _RecentsRail(
                records: _recents,
                onSeeAll: () => context.push('/history'),
              ),
            ),
          ),
        SliverToBoxAdapter(
          child: SizedBox(
            // The bar floats over the list, so the list ends above it rather
            // than under it.
            height: tail,
          ),
        ),
      ],
    );
  }
}

/// The hairline that separates the identity bar from a page scrolled under
/// it — absent while the page is at rest, so the bar reads as part of the
/// canvas until it has something to hold back.
class _ScrolledUnderRule extends StatelessWidget
    implements PreferredSizeWidget {
  const _ScrolledUnderRule({required this.progress});

  final ValueListenable<double> progress;

  @override
  Size get preferredSize => const Size.fromHeight(0.5);

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<double>(
    valueListenable: progress,
    builder: (context, t, _) => Opacity(
      opacity: t,
      child: Container(height: 0.5, color: context.jamColors.separator),
    ),
  );
}

/// Your face and name, tappable to rename. `JamIdentity.setDisplayName` has
/// existed since v1 with no caller — this is it.
class _IdentityButton extends StatelessWidget {
  const _IdentityButton({required this.name, required this.onTap});

  final String name;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    if (name.isEmpty) return const SizedBox.shrink();
    return Semantics(
      button: true,
      label: '$name. ${HomeStrings.rename}',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(JamRadius.pill),
        child: Padding(
          padding: const EdgeInsets.all(JamSpace.xs),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              JamAvatar(name: name, size: JamAvatarSize.identity),
              const SizedBox(width: JamSpace.sm),
              // Flexible, not fixed: the app bar's title slot is narrow once
              // the action icons take their share, and a long identity should
              // truncate rather than overflow.
              Flexible(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.jamRowTitle,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "Listening for rooms", with the apricot dot that says the radio is live.
///
/// No Wi-Fi name: nothing on this device can read an SSID (see
/// `util/network.dart` — it enumerates interfaces and addresses, not
/// networks), and inventing one would be worse than omitting it.
///
/// The breath is a timer flipping an [AnimatedOpacity] rather than a
/// permanently repeating [AnimationController]: identical on screen, but it
/// leaves a beat of stillness between breaths, so the frame scheduler goes
/// quiet and a `pumpAndSettle` anywhere in the app still settles.
class _ListeningFootnote extends StatefulWidget {
  const _ListeningFootnote();

  @override
  State<_ListeningFootnote> createState() => _ListeningFootnoteState();
}

class _ListeningFootnoteState extends State<_ListeningFootnote> {
  Timer? _timer;
  bool _lit = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (still) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    _timer ??= Timer.periodic(_pulseHalf, (_) {
      if (mounted) setState(() => _lit = !_lit);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    return Semantics(
      liveRegion: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedOpacity(
            opacity: _lit ? 1 : 0.4,
            duration: _pulseFade,
            curve: JamCurve.ambient,
            child: Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: colors.liveDot,
                shape: BoxShape.circle,
              ),
            ),
          ),
          const SizedBox(width: JamSpace.sm),
          Flexible(
            child: Text(
              HomeStrings.listening,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.jamFootnote.copyWith(color: colors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

/// One discoverable room.
///
/// A card, not a `ListTile`: this is the thing the screen exists to offer, and
/// joining is not instant — a handshake, a clock burst of eight pings, and a
/// prefetch decision — so the card says so instead of looking dead.
///
/// `JamNearbyRoom` carries only a key, a name and a join URI over mDNS, so the
/// byline never implies a listener count or a host name it cannot know.
class _RoomCard extends StatelessWidget {
  const _RoomCard({
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
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final dimmed = !enabled && !joining;

    final card = Opacity(
      opacity: dimmed ? 0.5 : 1,
      child: Container(
        height: 88,
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: BorderRadius.circular(JamRadius.lg),
          border: Border.all(color: colors.separator, width: 0.5),
          boxShadow: JamShadow.raised(colors),
        ),
        clipBehavior: Clip.antiAlias,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: enabled ? onTap : null,
            child: Padding(
              padding: const EdgeInsets.all(JamSpace.card),
              child: Row(
                children: [
                  JamAvatar(name: room.sessionName, size: 48),
                  const SizedBox(width: JamSpace.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          room.sessionName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.jamRowTitle,
                        ),
                        const SizedBox(height: JamSpace.xxs),
                        Text(
                          joining
                              ? HomeStrings.joining(room.sessionName)
                              : HomeStrings.tapToJoin,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.jamFootnote.copyWith(
                            color: joining
                                ? colors.warning
                                : colors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: JamSpace.sm),
                  if (joining)
                    SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: colors.accent,
                      ),
                    )
                  else
                    JamButton.tertiary(
                      label: HomeStrings.join,
                      onPressed: enabled ? onTap : null,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    final labelled = Semantics(
      button: true,
      enabled: enabled,
      label: joining
          ? HomeStrings.joining(room.sessionName)
          : HomeStrings.joinRoom(room.sessionName),
      child: ExcludeSemantics(child: card),
    );

    if (!animateIn || still) return labelled;
    // A one-shot rise, with no controller of its own to keep alive: the
    // tween runs once on first build and the builder is never rebuilt again.
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: JamDuration.base,
      curve: JamCurve.base,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset(0, (1 - t) * _roomEntryOffset),
          child: child,
        ),
      ),
      child: labelled,
    );
  }
}

/// The jams you were in, as a rail you can flick through.
class _RecentsRail extends StatelessWidget {
  const _RecentsRail({required this.records, required this.onSeeAll});

  final List<JamHistoryRecord> records;
  final VoidCallback onSeeAll;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: JamSpace.page),
          child: Row(
            children: [
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(
                    HomeStrings.recently,
                    style: context.jamCaption.copyWith(
                      color: colors.textTertiary,
                    ),
                  ),
                ),
              ),
              JamButton.tertiary(
                label: HomeStrings.seeAll,
                onPressed: onSeeAll,
              ),
            ],
          ),
        ),
        const SizedBox(height: JamSpace.md),
        SizedBox(
          height: jamRecentCardHeight(context),
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: JamSpace.page),
            itemCount: records.length,
            separatorBuilder: (_, _) => const SizedBox(width: JamSpace.md),
            itemBuilder: (context, index) =>
                _RecentCard(record: records[index], onTap: onSeeAll),
          ),
        ),
      ],
    );
  }
}

class _RecentCard extends StatelessWidget {
  const _RecentCard({required this.record, required this.onTap});

  final JamHistoryRecord record;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    return Semantics(
      button: true,
      label: '${record.sessionName}, ${jamRelativeTime(record.updatedAt)}',
      child: ExcludeSemantics(
        child: SizedBox(
          width: _recentCardWidth,
          child: Material(
            color: colors.surface,
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(JamRadius.lg),
              side: BorderSide(color: colors.separator, width: 0.5),
            ),
            child: InkWell(
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.all(JamSpace.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    JamArtworkMosaic(
                      tracks: record.tracks,
                      size: _recentMosaic,
                    ),
                    const SizedBox(height: JamSpace.md),
                    Text(
                      record.sessionName,
                      maxLines: _recentTitleLines,
                      overflow: TextOverflow.ellipsis,
                      style: context.jamRowTitle,
                    ),
                    const SizedBox(height: JamSpace.xxs),
                    Text(
                      jamRelativeTime(record.updatedAt),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.jamFootnote.copyWith(
                        color: colors.textTertiary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Which side of a live session this device is on, for the empty state.
enum _Hosting { host, guest }

/// The "nothing nearby" situations, which need different actions.
///
/// Four now, not three: the fourth is *you are the reason the list is empty*.
/// The browse stops while a jam runs, so a host looking at home was told
/// "Nobody on this network is hosting yet" over their own live room.
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
        icon: Icons.graphic_eq_rounded,
        gradientMark: true,
        title: live == _Hosting.host
            ? HomeStrings.hostingTitle(roomName)
            : HomeStrings.guestingTitle(roomName),
        body: live == _Hosting.host
            ? HomeStrings.hostingBody
            : HomeStrings.guestingBody,
        actionLabel: onOpenRoom == null ? null : HomeStrings.openRoom,
        onAction: onOpenRoom,
        actionVariant: JamButtonVariant.tertiary,
      );
    }

    final (icon, title, body, showScan) = switch (network) {
      JamNetworkStatus(connected: false) => (
        Icons.wifi_off_rounded,
        HomeStrings.offlineTitle,
        HomeStrings.offlineBody,
        false,
      ),
      JamNetworkStatus(isHotspotHost: true) => (
        Icons.qr_code_scanner_rounded,
        HomeStrings.hotspotTitle,
        HomeStrings.hotspotBody,
        true,
      ),
      _ => (
        Icons.podcasts_rounded,
        HomeStrings.quietTitle,
        HomeStrings.quietBody,
        false,
      ),
    };
    final scannable = showScan && canScanQrCodes;

    // One action, and only one: "Join with a link" also lives in the bottom
    // bar, and the same words twice on one screen (§4 "never two competing
    // actions") read as two different doors to two different places.
    return JamEmptyState(
      icon: icon,
      gradientMark: true,
      title: title,
      body: body,
      // The bottom bar already owns this screen's primary action, so the
      // empty state's own is deliberately quieter.
      actionLabel: scannable ? HomeStrings.scan : null,
      onAction: scannable ? onScan : null,
      actionVariant: JamButtonVariant.secondary,
    );
  }
}

/// The ways into music, always reachable.
///
/// On a phone this is the blurred bottom bar; on a desktop window it is the
/// row beside the page title, where a bar stretched across 1300px would look
/// stranded.
class _HomeActions extends StatelessWidget {
  const _HomeActions({
    required this.onScan,
    required this.onHost,
    this.onLink,
    this.inline = false,
  });

  final VoidCallback onScan;
  final VoidCallback onHost;

  /// Pasting a link: the way in with no camera and no mDNS. Quieter than the
  /// other two, and directly under them.
  final VoidCallback? onLink;

  final bool inline;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final link = onLink;

    if (inline) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // A label here would push the two real actions off a 600 dp
          // header; the phone's bottom bar is where the link gets words.
          if (link != null) ...[
            IconButton(
              onPressed: link,
              icon: const Icon(Icons.link_rounded),
              tooltip: HomeStrings.joinWithLink,
            ),
            const SizedBox(width: JamSpace.xs),
          ],
          if (canScanQrCodes) ...[
            JamButton.secondary(
              label: HomeStrings.scan,
              icon: Icons.qr_code_scanner_rounded,
              onPressed: onScan,
            ),
            const SizedBox(width: JamSpace.md),
          ],
          JamButton.primary(
            label: HomeStrings.host,
            icon: Icons.graphic_eq_rounded,
            onPressed: onHost,
          ),
        ],
      );
    }

    return ClipRect(
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colors.surface.withValues(
              alpha: Theme.of(context).brightness == Brightness.light
                  ? 0.82
                  : 0.86,
            ),
            border: Border(
              top: BorderSide(color: colors.separator, width: 0.5),
            ),
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                JamSpace.page,
                JamSpace.md,
                JamSpace.page,
                JamSpace.md,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      if (canScanQrCodes) ...[
                        Expanded(
                          child: JamButton.secondary(
                            label: HomeStrings.scan,
                            icon: Icons.qr_code_scanner_rounded,
                            onPressed: onScan,
                            expand: true,
                          ),
                        ),
                        const SizedBox(width: JamSpace.md),
                      ],
                      Expanded(
                        child: JamButton.primary(
                          label: HomeStrings.host,
                          icon: Icons.graphic_eq_rounded,
                          onPressed: onHost,
                          expand: true,
                        ),
                      ),
                    ],
                  ),
                  // The third way in, where the other two are. It used to
                  // hide behind an ellipsis in the app bar, which made three
                  // trailing icons up there read as a toolbar.
                  if (link != null) ...[
                    const SizedBox(height: JamSpace.xs),
                    JamButton.tertiary(
                      label: HomeStrings.joinWithLink,
                      onPressed: link,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
