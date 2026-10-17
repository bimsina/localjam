/// The room — one player for both sides of a jam.
///
/// Written against the abstract [JamEngine] and gated on
/// `engine.can(JamCapability…)`, so a host and a guest render the same screen
/// and the difference is what you may touch.
///
/// The room is the subject, not the file that happens to be playing: the
/// cover art washes the whole page (§2.2 — the only place in the app a colour
/// comes from outside the palette), the people in the room sit on the player
/// as faces rather than behind a menu, and the track carries a credit for
/// whoever put it on. Sync stays a wordless dot until something is actually
/// wrong.
///
/// Leaving is explicit. The chevron minimises back to Home with the session
/// still running — before the overhaul, popping the route ended the jam.
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:localjam_client/localjam_client.dart';

import '../design/artwork_tint.dart';
import '../design/breakpoints.dart';
import '../design/tokens.dart';
import '../design/typography.dart';
import '../state/session_controller.dart';
import '../util/format.dart';
import '../util/network.dart';
import '../widgets/artwork.dart';
import '../widgets/avatar.dart';
import '../widgets/buttons.dart';
import '../widgets/diagnostics_sheet.dart';
import '../widgets/drag_to_dismiss.dart';
import '../router.dart' show HostSetupArgs;
import '../widgets/queue_sheet.dart';
import '../widgets/room_banner.dart';
import '../widgets/room_sheet.dart';
import '../widgets/sync_indicator.dart';
import '../widgets/track_row.dart';
import '../widgets/transport.dart';

/// Every user-facing string the room can show.
abstract final class JamRoomStrings {
  static const String back = 'Back to nearby';
  static const String people = 'Who’s here';
  static const String queue = 'Queue';
  static const String invite = 'Invite';
  static const String endJam = 'End jam';

  static const String nothingQueued = 'Nothing queued';
  static const String nothingQueuedBody = 'Add something to get the room going';
  static const String addMusic = 'Add music';
  static const String nothingToPlay = 'Nothing to play yet';
  static const String addedBy = 'ADDED BY';

  /// What the credit says when the track is yours. Uppercased with the rest
  /// of the caption at render time.
  static const String you = 'You';

  /// What a host with no shared display name is called. A guest learns the
  /// host's real name from the welcome frame; this is the fallback.
  static const String host = 'Host';

  static const String reconnecting = JamRoomBannerStrings.reconnecting;

  /// Under a transport the room has not taken away, but that cannot reach
  /// the host right now — dimmed with a reason, never silently dead.
  static const String waitForHost =
      'Controls come back when the host’s phone wakes';
  static const String waitForReconnect =
      'Controls come back once you reconnect';

  static String fetching(int percent) => 'Getting this track — $percent%';
  static const String fetchFailed = 'Couldn’t get this track';
  static const String retry = 'Retry';

  /// What "Retry" says to a screen reader, which hears it apart from the
  /// line before it.
  static const String retryFetch = 'Try getting this track again';
  static const String importing = 'Adding your music…';
  static String importingCount(int done, int total) =>
      'Adding your music · $done of $total';

  /// The host's play is held until every guest has the track (§6.3).
  static const String awaitingReadiness = 'Waiting for everyone’s download';
  static String inTheRoom(int n) => n == 1 ? '1 in the room' : '$n in the room';
  static String queued(int n) => n == 1 ? '1 queued' : '$n queued';
  static String waiting(int n) => n == 1
      ? 'Waiting for 1 person to get this track'
      : 'Waiting for $n people to get this track';

  static const String hostGoneTitle = 'The room closed';
  static const String hostGoneBody = 'The host left or went out of range.';
  static const String kickedTitle = 'You were removed';
  static const String kickedBody = 'The host removed you from this room.';
  // `rejected`, by the host's reason (JamSessionController.endRejectReason).
  // A reason this version does not know — or none — keeps the generic pair,
  // which names the likeliest cause without promising it.
  static const String rejectedTitle = 'Could not get back in';
  static const String rejectedBody =
      'The room turned this phone away. It may have restarted — ask the '
      'host for a fresh code.';

  /// `bad_token`: the room restarted under a new code. The old link can
  /// never work again, so there is no "Try again".
  static const String restartedTitle = 'The room restarted';
  static const String restartedBody =
      'The code this phone joined with no longer works. Ask the host for the '
      'new one.';

  /// `version`: no retry fixes this; an update does.
  static const String versionTitle = 'An update is needed';
  static const String versionBody = kJamVersionMismatch;

  /// `full`: the one refusal that can turn into a yes on its own.
  static const String fullTitle = 'The room is full';
  static const String fullBody =
      'Someone has to leave before this phone can get back in.';

  /// Host only: the OS took the room's listening socket while the app was
  /// away and it could not be reopened (listenerFailed).
  static const String listenerFailedTitle =
      'The room stopped letting people in';
  static const String listenerFailedBody =
      'Start a new one to keep going — your queue comes with you.';
  static const String startNew = 'Start a new jam';
  static const String hostEndedTitle = 'The host ended the jam';
  static const String hostEndedBody =
      'The room is closed. Everyone heard the same last song.';
  static const String endedTitle = 'Jam ended';
  static const String endedBody = 'That is everyone home safely.';
  static const String tryAgain = 'Try again';
  static const String rejoinFailed = kJamRejoinFailed;

  /// The docked panel's two tabs.
  static const String panelQueue = 'Queue';
  static const String panelRoom = 'Room';
}

/// Below this page height the vertical player cannot hold its own shape, so
/// the room turns side-on: hero left, controls right. Landscape phones live
/// here, and so does a short desktop window.
const double kRoomShortHeight = 560;

/// The hero's ceiling, whatever the window does (§5).
const double kRoomHeroMax = 340;

/// The app bar's height: a sync line above the room's name needs more than
/// the Material default.
const double _kRoomToolbarHeight = 72;

/// The app bar's two-line centre column, sliced into fixed slots.
///
/// The chevron used to centre against the *whole* column, which put it ~23 dp
/// above the room name — the eye reads the name as the title and the button as
/// floating. Reserving both slots lets the leading button be placed against
/// the name's own optical centre with plain arithmetic rather than a guess.
const double _kRoomSyncSlot = kJamSyncIndicatorCompactHeight;

/// The most air allowed between the hero's bottom edge and the title block.
/// With the column's own [JamSpace.lg] beneath it that is a 40 dp ceiling.
const double _kHeroGapBelowMax = JamSpace.xxl;
const double _kRoomNameSlot = 24;

/// Distance from the toolbar's top to the top of a 48 dp icon button whose
/// centre lands on the room name's centre line.
/// Where the chevron sits from the bar's left edge — the 4 dp that used to
/// centre a 48 dp button inside the 56 dp leading slot.
const double _kRoomLeadingInset = 4;

const double _kRoomLeadingTop =
    (_kRoomToolbarHeight - (_kRoomSyncSlot + _kRoomNameSlot)) / 2 +
    _kRoomSyncSlot +
    _kRoomNameSlot / 2 -
    24;

/// One cycle of the ambient loop: the glow's breath and the avatars' bob.
const Duration _kAmbientPeriod = Duration(milliseconds: 2400);

/// How far a face rises at the top of the bob.
const double _kAvatarBob = 2;

/// The jam-started overlay's whole life (addendum §4 — 700 ms, not 900).
const Duration _kCelebration = Duration(milliseconds: 700);

/// The session the jam-started moment has already played for. Held above the
/// widget so re-entering the room mid-jam does not replay it.
String? _celebratedSessionId;

@visibleForTesting
void resetJamCelebration() => _celebratedSessionId = null;

class RoomScreen extends StatefulWidget {
  const RoomScreen({super.key});

  @override
  State<RoomScreen> createState() => _RoomScreenState();
}

class _RoomScreenState extends State<RoomScreen>
    with SingleTickerProviderStateMixin {
  final List<StreamSubscription<Object?>> _subs = [];
  JamEngine? _bound;
  String _identity = '';
  JamNetworkStatus _network = JamNetworkStatus.offline;

  /// The single controller behind every idle animation on this screen — the
  /// glow's breath and the avatar bob ride the same 2.4 s cycle, so they read
  /// as one room breathing rather than two widgets fidgeting.
  late final AnimationController _ambient = AnimationController(
    vsync: this,
    duration: _kAmbientPeriod,
  );

  /// Set while the jam-started overlay is on screen.
  bool _celebrating = false;
  Timer? _celebrationTimer;

  /// Set once this screen, left without a room, asked to go home.
  bool _leavingEmpty = false;

  /// Leaves a room that no longer exists, after this frame (no navigation
  /// from inside a build): the same way down as the chevron.
  void _leaveEmptyRoom() {
    if (_leavingEmpty) return;
    _leavingEmpty = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || JamSession.read(context).hasRoom) {
        _leavingEmpty = false;
        return;
      }
      // Already on its way out (whoever ended the room navigated on, e.g.
      // "Start a new jam" to host setup): leave the new top route alone.
      if (ModalRoute.of(context)?.isCurrent == false) return;
      // The app always has a router; a room shown on its own (a test, an
      // embedding) just gets popped if it can be.
      final router = GoRouter.maybeOf(context);
      if (router == null) {
        unawaited(Navigator.maybeOf(context)?.maybePop());
      } else if (router.canPop()) {
        router.pop();
      } else {
        router.go('/');
      }
    });
  }

  @override
  void initState() {
    super.initState();
    unawaited(_loadIdentity());
    unawaited(_refreshNetwork());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bind(JamSession.of(context).engine);
    _syncAmbient();
  }

  /// Subscribes to the engine's own streams. Deliberately not the session
  /// controller's job: a track change should repaint this screen, not the app.
  void _bind(JamEngine? engine) {
    if (identical(engine, _bound)) return;
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    _subs.clear();
    _bound = engine;
    if (engine == null) return;
    void refresh(Object? _) {
      if (mounted) setState(() {});
    }

    _subs
      ..add(engine.states.listen(refresh))
      ..add(engine.playlistUpdates.listen(refresh))
      ..add(engine.permissionUpdates.listen(refresh))
      // The big button is "Resume audio" while this phone is silenced.
      ..add(engine.outputSuspensionChanges.listen(refresh));
    if (engine is JamGuestEngine) {
      _subs.add(engine.peerEvents.listen(refresh));
    } else if (engine is JamHostEngine) {
      _subs.add(engine.events.listen(refresh));
    }
    _maybeCelebrate(engine);
  }

  @override
  void dispose() {
    _celebrationTimer?.cancel();
    _ambient.dispose();
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    super.dispose();
  }

  Future<void> _loadIdentity() async {
    final name = await JamIdentity.displayName();
    if (mounted) setState(() => _identity = name);
  }

  Future<void> _refreshNetwork() async {
    final status = await currentNetwork();
    if (mounted) setState(() => _network = status);
  }

  /// Runs the ambient loop only when it can be felt: something playing, and
  /// animations not turned off at the OS.
  void _syncAmbient() {
    final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final playing = _bound?.snapshot.status == PlaybackStatus.playing;
    if (playing && !reduced) {
      if (!_ambient.isAnimating) _ambient.repeat();
    } else if (_ambient.isAnimating) {
      _ambient
        ..stop()
        ..value = 0;
    }
  }

  /// The jam-started moment: once per session, never on a desktop window
  /// (addendum §4), and skippable by touching it.
  void _maybeCelebrate(JamEngine engine) {
    if (_celebratedSessionId == engine.sessionId) return;
    if (breakpointFor(MediaQuery.sizeOf(context).width) ==
        JamBreakpoint.expanded) {
      return;
    }
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) return;
    _celebratedSessionId = engine.sessionId;
    _celebrating = true;
    JamHaptics.jamStarted();
    _celebrationTimer = Timer(_kCelebration, _endCelebration);
  }

  void _endCelebration() {
    _celebrationTimer?.cancel();
    if (mounted && _celebrating) setState(() => _celebrating = false);
  }

  /// "Try again": the controller keeps this room mounted for the whole
  /// rejoin ([JamSessionController.rejoining]) and, if it fails, lands back
  /// on the same ended screen with [JamSessionController.error] saying why —
  /// so there is nothing to navigate here, in either outcome.
  Future<void> _retry(JamSessionController session) => session.rejoin();

  /// "Start a new jam" after the OS took the room away: host setup again,
  /// same name, same queue.
  Future<void> _startNew(JamSessionController session) async {
    final args = session.restartArgs;
    await session.acknowledgeEnd();
    if (!mounted) return;
    // Held by the controller as well as passed along: the route's `extra`
    // is in-memory state a router rebuild does not promise to keep.
    session.hostSetupDraft = args;
    context.go('/');
    context.push(
      '/host',
      extra: args == null
          ? null
          : HostSetupArgs(paths: args.paths, name: args.name),
    );
  }

  @override
  Widget build(BuildContext context) {
    final session = JamSession.of(context);
    final engine = session.engine;
    final colors = context.jamColors;

    if (session.phase == JamSessionPhase.ended || session.rejoining) {
      final reason = session.endReason;
      final rejoining = session.rejoining;
      return JamSessionEndedView(
        reason: reason,
        rejectReason: session.endRejectReason,
        retrying: rejoining,
        // Only a failed "Try again" leaves an error behind on this screen;
        // anything older was cleared when the session started.
        error: rejoining ? null : session.error,
        onDone: rejoining
            ? null
            : () async {
                await session.acknowledgeEnd();
                if (context.mounted) context.go('/');
              },
        // A host that suspended and came back is the documented graceful-death
        // path (DEVICE_TESTING §11), and the engine kept the URI that gets
        // you back in — the sha-keyed cache means the rejoin re-fetches
        // nothing. Not offered after a kick: §5.6 says never auto-rejoin,
        // and a "try again" on a removal would just be rude. (The view also
        // drops it for refusals no retry can fix.)
        onRetry:
            session.lastJoinUri != null && reason != JamSessionEndReason.kicked
            ? () => unawaited(_retry(session))
            : null,
        onStartNew: reason == JamSessionEndReason.listenerFailed
            ? () => unawaited(_startNew(session))
            : null,
      );
    }
    if (engine == null) {
      // The room went away under this screen. The router's redirect only
      // guards going TO /room — a room already pushed stays on the stack —
      // and whoever ended it may not be around to send it home: ending a
      // jam with a guest in it from the People sheet unwound the sheet
      // while the room was still closing, and the host sat on this empty
      // page (2026-10-17 run). Go home on our own.
      if (!session.hasRoom) _leaveEmptyRoom();
      return const Scaffold(body: SizedBox.shrink());
    }

    _syncAmbient();

    final guest = engine is JamGuestEngine ? engine : null;
    final wide = context.jamBreakpoint.hasSidePanel;

    void minimise() => context.canPop() ? context.pop() : context.go('/');

    void openRoom() => unawaited(
      showRoomSheet(context, engine, selfName: _identity, network: _network),
    );

    return DragToDismiss(
      // A desktop window has no dismiss gesture — the room is a destination
      // beside the sidebar, not a sheet over a phone screen.
      enabled: !wide,
      onDismiss: minimise,
      // The jam-started moment sits ABOVE the Scaffold, app bar included —
      // inside the body it would have the chevron and the room's name
      // floating over the raspberry, which reads as a glitch.
      child: Stack(
        children: [
          // The cover's colour, resolved once per track through the cache the
          // session holds — so minimising to the room bar does not re-derive
          // the tint the bar is already wearing.
          JamTintBuilder(
            engine: engine,
            cache: session.tints,
            builder: (context, tint) => Scaffold(
              backgroundColor: colors.canvas,
              // The gradient wash runs to the very top; the app bar floats on it.
              extendBodyBehindAppBar: true,
              appBar: AppBar(
                centerTitle: true,
                backgroundColor: Colors.transparent,
                // Two lines — the sync dot over the room's name — do not fit the
                // 56 dp default, and a clipped app bar is the first thing anyone
                // notices.
                toolbarHeight: _kRoomToolbarHeight,
                // No `leading`, and the title owns the whole bar. A leading
                // slot with no trailing one makes `centerTitle` centre inside
                // what is *left* of the bar the moment the title is wide, and
                // the room name sat ~28 dp right of centre. One full-width
                // stack centres it against the screen instead, with the
                // chevron laid over the top.
                automaticallyImplyLeading: false,
                titleSpacing: 0,
                title: SizedBox(
                  height: _kRoomToolbarHeight,
                  width: double.infinity,
                  child: Stack(
                    children: [
                      Positioned(
                        left: _kRoomLeadingInset,
                        top: _kRoomLeadingTop,
                        child: IconButton(
                          icon: const Icon(Icons.keyboard_arrow_down_rounded),
                          tooltip: JamRoomStrings.back,
                          // A pop, so the room plays its reverse slide back
                          // down. `go` would replace the stack and skip the
                          // exit animation entirely.
                          onPressed: minimise,
                        ),
                      ),
                      Center(
                        child: Padding(
                          // Both sides, so the centre column is centred on the
                          // screen and still cannot reach the chevron.
                          padding: const EdgeInsets.symmetric(
                            horizontal: _kRoomLeadingInset + 48,
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // Fixed slots, held open whether or not the indicator has
                              // anything to say, so the chevron's offset is constant.
                              SizedBox(
                                height: _kRoomSyncSlot,
                                child: Center(
                                  child: SyncIndicator(
                                    engine: engine,
                                    connection: session.connection,
                                    clockSynced: guest?.clockSynced ?? true,
                                    hostAway: session.hostAway,
                                    height: _kRoomSyncSlot,
                                    // The numbers live one long-press away — §6.1's
                                    // replacement for the "Sync details" menu item.
                                    onShowDetails: () => unawaited(
                                      showDiagnosticsSheet(
                                        context,
                                        engine,
                                        clockOffsetUs: guest == null
                                            ? null
                                            : () => guest.clockOffsetUs,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              SizedBox(
                                height: _kRoomNameSlot,
                                child: Center(
                                  child: Text(
                                    engine.sessionName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: context.jamRowTitle,
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
                // No trailing action. Leaving is one labelled row at the bottom
                // of the People sheet (§6.1) — the strip's faces are the door to
                // it, and the chevron minimises without ending anything. A
                // second, redder way out sitting permanently beside the room's
                // name was the interim while that sheet was being built.
              ),
              body: Stack(
                children: [
                  // §2.2 (2): the cover's colour over the top 45% of the page,
                  // cross-fading whenever the track changes.
                  Positioned.fill(child: _TintWash(tint: tint)),
                  // The wash runs behind the app bar, so the content has to step
                  // out of its way by hand — otherwise the hero slides under the
                  // room's name.
                  Padding(
                    padding: EdgeInsets.only(
                      top:
                          MediaQuery.paddingOf(context).top +
                          _kRoomToolbarHeight,
                    ),
                    child: SafeArea(
                      // The app bar covers the top; this is about the home
                      // indicator, which the people strip sits on otherwise.
                      top: false,
                      child: Column(
                        children: [
                          // This phone's own sound first: it is the one strip
                          // with something for the user to do.
                          JamOutputBanner(engine: engine),
                          // "Asleep" and "reconnecting" are different waits —
                          // the first is the host's phone doing what iOS does
                          // to a paused app, and needs nothing from anyone.
                          if (session.hostAway)
                            const JamRoomBanner(
                              icon: Icons.bedtime_rounded,
                              message: JamRoomBannerStrings.hostAsleep,
                            )
                          else if (session.connection !=
                              JamConnectionState.connected)
                            const JamRoomBanner(
                              busy: true,
                              message: JamRoomBannerStrings.reconnecting,
                            ),
                          Expanded(
                            child: Row(
                              children: [
                                Expanded(
                                  child: _RoomBody(
                                    engine: engine,
                                    guest: guest,
                                    session: session,
                                    identity: _identity,
                                    tint: tint,
                                    ambient: _ambient,
                                    leftAlignHero: wide,
                                    onPeople: openRoom,
                                    onQueue: () => unawaited(
                                      showQueueSheet(context, engine),
                                    ),
                                  ),
                                ),
                                if (wide)
                                  _SidePanel(
                                    engine: engine,
                                    selfName: _identity,
                                    network: _network,
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_celebrating)
            _JamStarted(roomName: engine.sessionName, onSkip: _endCelebration),
        ],
      ),
    );
  }
}

/// The top-45% colour wash (§2.2 item 2). Its own widget so the cross-fade
/// lives in one place and the rest of the room can be `const`-ish.
class _TintWash extends StatelessWidget {
  const _TintWash({required this.tint});

  final JamTint tint;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return TweenAnimationBuilder<Color?>(
      tween: ColorTween(end: tint.base),
      duration: reduced ? Duration.zero : JamDuration.ambient,
      curve: JamCurve.ambient,
      builder: (context, value, _) => IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                (value ?? tint.base).withValues(alpha: 0.10),
                colors.canvas.withValues(alpha: 0),
              ],
              stops: const [0, 0.45],
            ),
          ),
        ),
      ),
    );
  }
}

/// The player itself, in whichever shape the window can hold.
class _RoomBody extends StatelessWidget {
  const _RoomBody({
    required this.engine,
    required this.guest,
    required this.session,
    required this.identity,
    required this.tint,
    required this.ambient,
    required this.leftAlignHero,
    required this.onPeople,
    required this.onQueue,
  });

  final JamEngine engine;
  final JamGuestEngine? guest;
  final JamSessionController session;
  final String identity;
  final JamTint tint;
  final Animation<double> ambient;

  /// Wide windows sit the hero at the left of the player column with the
  /// title block under it, rather than centring it in the window (§5).
  final bool leftAlignHero;

  final VoidCallback onPeople;
  final VoidCallback onQueue;

  /// The host holds the reserved peer id "host" and is never in `peers`, so
  /// a guest has to add it back or the room looks a person short.
  List<String> get _roster => <String>[
    if (identity.isNotEmpty) identity,
    if (guest != null) _hostName,
    for (final peer in engine.peers) jamPeerName(peer),
  ];

  /// The host, by name. Yours when you are hosting; otherwise the name the
  /// welcome frame carried, and the role word only when they shared none.
  String get _hostName {
    if (guest == null) return identity;
    final name = engine.hostPeer?.clientName.trim() ?? '';
    return name.isEmpty ? JamRoomStrings.host : name;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final short = constraints.maxHeight < kRoomShortHeight;
        final strip = _PeopleStrip(
          roster: _roster,
          hostName: _hostName,
          selfName: identity,
          isHost: session.isHost,
          queueCount: engine.playlist.length,
          ambient: ambient,
          onPeople: onPeople,
          onQueue: onQueue,
        );
        final controls = _Controls(
          engine: engine,
          guest: guest,
          session: session,
          identity: identity,
          compact: short,
          strip: short ? null : strip,
          onQueue: onQueue,
        );

        if (short) {
          // Landscape and short windows: the hero shrinks and moves beside
          // the controls rather than squeezing them off the bottom.
          //
          // The people strip is pinned to the foot of the column: it is the
          // way to the queue and the people, and an Android phone on its
          // side (a Pixel: ~255 dp of column under the status bar and the
          // room's own bar) showed only the tops of its faces — the strip
          // sat past the end of a scrolling column nobody thought to scroll
          // (2026-10-17 run). The player takes what is left, centred in it,
          // at tightened spacing that fits a phone held sideways. When even
          // that is too tall (a guest without playback control has a line
          // under the transport; every note at once; a large text size) it
          // is scaled down to fit rather than scrolled: a play button cut in
          // half by a scroll edge, or a reason nobody can see, is worse than
          // the whole player a little smaller.
          final artSize = _clampArt(
            math.min(
              constraints.maxHeight - JamSpace.xxl,
              constraints.maxWidth * 0.38,
            ),
          );
          return Padding(
            padding: const EdgeInsets.fromLTRB(
              JamSpace.xl,
              JamSpace.sm,
              JamSpace.xl,
              JamSpace.md,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _Hero(
                  engine: engine,
                  size: artSize,
                  tint: tint,
                  ambient: ambient,
                ),
                const SizedBox(width: JamSpace.xxl),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: LayoutBuilder(
                          builder: (context, box) => Center(
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: SizedBox(
                                width: box.maxWidth,
                                child: controls,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: JamSpace.sm),
                      strip,
                    ],
                  ),
                ),
              ],
            ),
          );
        }

        // The hero takes what the controls leave, never the other way round:
        // a Column lays its inflexible children out first, so the inner
        // LayoutBuilder sees the real leftover and the cover shrinks to fit
        // instead of pushing the people strip off the bottom of a short
        // window. (An Android landscape build overflowed by 113 px this way.)
        return Padding(
          padding: const EdgeInsets.fromLTRB(
            JamSpace.xxxl,
            JamSpace.sm,
            JamSpace.xxxl,
            JamSpace.lg,
          ),
          child: Column(
            crossAxisAlignment: leftAlignHero
                ? CrossAxisAlignment.start
                : CrossAxisAlignment.center,
            children: [
              Expanded(
                child: LayoutBuilder(
                  builder: (context, box) {
                    final artSize = _clampArt(
                      math.min(
                        math.min(
                          constraints.maxWidth - JamSpace.xxxl * 2,
                          constraints.maxHeight * 0.42,
                        ),
                        box.maxHeight - JamSpace.lg,
                      ),
                    );
                    // Budgeted, not weighted. An `Alignment(0, -0.35)` gives
                    // the leftover height away in a ratio, which on a 6.1"
                    // phone opened a 95 dp hole between the cover and the
                    // track title. The gap below the hero is capped instead,
                    // and whatever is left goes above it.
                    final slack = math.max(0.0, box.maxHeight - artSize);
                    final below = math.min(slack * 0.3, _kHeroGapBelowMax);
                    return Column(
                      crossAxisAlignment: leftAlignHero
                          ? CrossAxisAlignment.start
                          : CrossAxisAlignment.center,
                      children: [
                        SizedBox(height: slack - below),
                        _Hero(
                          engine: engine,
                          size: artSize,
                          tint: tint,
                          ambient: ambient,
                        ),
                        SizedBox(height: below),
                      ],
                    );
                  },
                ),
              ),
              const SizedBox(height: JamSpace.lg),
              controls,
            ],
          ),
        );
      },
    );
  }

  static double _clampArt(double size) => size.clamp(0.0, kRoomHeroMax);
}

/// The hero cover with §2.2's ambient glow behind it — a radial wash of the
/// cover's own colour, blurred past recognition, breathing ±4% on the room's
/// one animation controller.
class _Hero extends StatelessWidget {
  const _Hero({
    required this.engine,
    required this.size,
    required this.tint,
    required this.ambient,
  });

  final JamEngine engine;
  final double size;
  final JamTint tint;
  final Animation<double> ambient;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final glowAlpha = dark ? 0.40 : 0.28;

    return SizedBox(
      // Room for the glow to spill without pushing the layout around.
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          Positioned(
            // Centred 8% above the artwork's centre, so the light reads as
            // coming off the top of the sleeve.
            top: -size * 0.38,
            child: IgnorePointer(
              child: TweenAnimationBuilder<Color?>(
                tween: ColorTween(end: tint.base),
                duration: reduced ? Duration.zero : JamDuration.ambient,
                curve: JamCurve.ambient,
                builder: (context, value, _) => AnimatedBuilder(
                  animation: ambient,
                  builder: (context, _) {
                    // ±4% on the same 2.4 s cycle as the avatar bob.
                    final breathe =
                        1 + 0.04 * math.sin(ambient.value * 2 * math.pi);
                    final d = size * 1.6 * breathe;
                    return ImageFiltered(
                      imageFilter: ui.ImageFilter.blur(
                        sigmaX: 60,
                        sigmaY: 60,
                        tileMode: TileMode.decal,
                      ),
                      child: Container(
                        width: d,
                        height: d,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: RadialGradient(
                            colors: [
                              (value ?? tint.base).withValues(alpha: glowAlpha),
                              (value ?? tint.base).withValues(alpha: 0),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(JamRadius.artwork(size)),
              boxShadow: JamShadow.floating(colors),
            ),
            child: JamArtwork(
              engine: engine,
              item: engine.currentItem,
              size: size,
            ),
          ),
        ],
      ),
    );
  }
}

/// Everything under the cover: the credit block, the timeline, the transport,
/// the readiness note and the people strip.
class _Controls extends StatelessWidget {
  const _Controls({
    required this.engine,
    required this.guest,
    required this.session,
    required this.identity,
    required this.compact,
    required this.strip,
    required this.onQueue,
  });

  final JamEngine engine;
  final JamGuestEngine? guest;
  final JamSessionController session;
  final String identity;

  /// The short (side-on) layout tightens every gap; nothing is dropped.
  final bool compact;

  /// The people strip, at the foot of the column — or null when the layout
  /// pins it somewhere of its own (side-on).
  final Widget? strip;

  /// Opens the queue — the empty room's "Add music".
  final VoidCallback onQueue;

  @override
  Widget build(BuildContext context) {
    final item = engine.currentItem;
    final canControl = engine.can(JamCapability.controlPlayback);
    // The room lets you, but the host cannot hear you right now (asleep, or
    // the link is down): seeking is as dead as the transport, and says so
    // there.
    final canSend = session.canSendCommands;
    final hasQueue = engine.playlist.isNotEmpty;
    final gap = compact ? JamSpace.md : JamSpace.xl;
    final import = session.hostImport;
    final importing = import != null && !import.progress.value.isDone;
    final strip = this.strip;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _TitleBlock(
          engine: engine,
          item: item,
          identity: identity,
          importing: importing,
          onAdd: engine.can(JamCapability.addTracks) ? onQueue : null,
        ),
        SizedBox(height: compact ? JamSpace.sm : gap),
        if (session.position case final ticker?)
          // The length follows the loaded file as well as the clock: a track
          // whose file lands while the room is paused (a Retry) has a
          // position that does not move, and the old track's length used to
          // stay on screen until something else redrew it.
          ValueListenableBuilder<int?>(
            valueListenable: engine.loadedDurationUs,
            builder: (context, loadedUs, _) => ValueListenableBuilder<int?>(
              valueListenable: ticker,
              builder: (context, positionUs, _) => JamScrubber(
                positionUs: positionUs ?? 0,
                durationUs: loadedUs ?? item?.durationUs,
                enabled: canControl && canSend && item != null,
                onSeek: canControl && canSend
                    ? (us) => unawaited(session.act((e) => e.transportSeek(us)))
                    : null,
              ),
            ),
          ),
        SizedBox(height: compact ? JamSpace.xs : JamSpace.md),
        _TransportArea(
          engine: engine,
          guest: guest,
          session: session,
          canControl: canControl,
          hasQueue: hasQueue,
        ),
        SizedBox(height: compact ? JamSpace.xs : JamSpace.lg),
        _ReadinessNote(engine: engine),
        if (import != null) _ImportNote(import: import),
        if (strip != null) ...[
          SizedBox(height: gap),
          strip,
          SizedBox(height: compact ? 0 : JamSpace.md),
        ],
      ],
    );
  }
}

/// Title, artist, and — only when it was somebody else — who queued it.
/// Left-aligned to the artwork's edge, the way a player reads.
class _TitleBlock extends StatelessWidget {
  const _TitleBlock({
    required this.engine,
    required this.item,
    required this.identity,
    required this.onAdd,
    this.importing = false,
  });

  final JamEngine engine;
  final MediaItem? item;
  final String identity;

  /// Offered instead of an artist line when the room is empty.
  final VoidCallback? onAdd;

  /// The host's starting files are still being added. An empty room in that
  /// moment is not "Nothing queued" — the music is on its way.
  final bool importing;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final current = item;
    if (current == null && importing) {
      return Text(
        JamRoomStrings.importing,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: context.jamTrackTitle.copyWith(color: colors.textPrimary),
      );
    }
    // The credit is always shown, yours included. Hiding "added by You" left
    // a solo-hosted room with no people on it at all — and the room, not the
    // track, is what this screen is about.
    final addedBy = current == null ? null : jamAddedByLabel(engine, current);
    final youAdded = addedBy == 'You';
    final credit = addedBy;

    // An untagged file has no artist, and "Unknown artist" is a label for
    // the absence of one — it says nothing and takes the most legible line
    // under the title. When there is no artist, the credit moves up into
    // that line instead: who put this on is the more interesting fact about
    // a track in a shared room anyway.
    final byline = current == null ? null : artworkByline(current);
    final creditWidget = credit == null
        ? null
        : _AddedBy(
            label: youAdded ? JamRoomStrings.you : credit,
            // Your own face, not a disc lettered from the word "You".
            faceName: youAdded && identity.isNotEmpty ? identity : credit,
            you: youAdded,
            colors: colors,
          );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          current == null
              ? JamRoomStrings.nothingQueued
              : jamDisplayTitle(current),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: context.jamTrackTitle.copyWith(color: colors.textPrimary),
        ),
        const SizedBox(height: JamSpace.xxs),
        if (current == null && onAdd != null)
          Align(
            alignment: Alignment.centerLeft,
            child: JamButton.tertiary(
              label: JamRoomStrings.addMusic,
              onPressed: onAdd,
            ),
          )
        else if (current == null)
          Text(
            JamRoomStrings.nothingQueuedBody,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.jamBody.copyWith(color: colors.textSecondary),
          )
        else if (byline != null) ...[
          Text(
            byline,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.jamBody.copyWith(color: colors.textSecondary),
          ),
          if (creditWidget != null) ...[
            const SizedBox(height: JamSpace.sm),
            creditWidget,
          ],
        ] else
          // No artist: the credit takes the artist's line, or the block just
          // ends after the title.
          ?creditWidget,
      ],
    );
  }
}

/// "ADDED BY *NAME*" with the adder's 20 dp face — the credit that makes a
/// queue read as something people made together.
class _AddedBy extends StatelessWidget {
  const _AddedBy({
    required this.label,
    required this.faceName,
    required this.colors,
    this.you = false,
  });

  /// The word after "ADDED BY": a name, or "You".
  final String label;

  /// The name the face's colour and initials derive from.
  final String faceName;

  /// Whether the adder is this device, which rings the face in apricot.
  final bool you;

  final JamColors colors;

  @override
  Widget build(BuildContext context) => Semantics(
    label: you
        ? JamTrackRowStrings.addedByYou
        : '${JamTrackRowStrings.addedBy} $label',
    excludeSemantics: true,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        JamAvatar(
          name: faceName,
          size: JamAvatarSize.attribution,
          ring: you ? JamAvatarRing.you : JamAvatarRing.none,
        ),
        const SizedBox(width: JamSpace.sm),
        Flexible(
          child: Text(
            '${JamRoomStrings.addedBy} ${label.toUpperCase()}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.jamCaption.copyWith(color: colors.textTertiary),
          ),
        ),
      ],
    ),
  );
}

/// Where a guest's copy of the current track is, as far as the player cares.
enum JamTrackFetch {
  /// Local and playable — or not a guest's problem at all.
  ready,

  /// On its way (queued, in flight, or failed with a retry scheduled).
  fetching,

  /// Failed and the engine stopped retrying: only the user can ask again.
  failed,
}

/// Classifies [state] for the player. A failure with a retry scheduled is
/// still "on its way" — the engine has it in hand — and only a failure it
/// gave up on turns into "Couldn't get this track · Retry".
JamTrackFetch jamTrackFetchOf(JamPrefetchState? state) {
  if (state == null || state.ready) return JamTrackFetch.ready;
  if (state.phase == JamPrefetchPhase.failed && !state.willRetry) {
    return JamTrackFetch.failed;
  }
  return JamTrackFetch.fetching;
}

/// The transport — and, for a guest whose current track is not on this
/// phone yet, what is happening to it.
///
/// Anyone the room lets skip keeps the full transport whatever the fetch is
/// doing: a track that will not come down is exactly when someone wants
/// "next", and replacing the bar with a progress ring took that away. A
/// guest who could not touch the transport anyway gets the ring instead.
class _TransportArea extends StatelessWidget {
  const _TransportArea({
    required this.engine,
    required this.guest,
    required this.session,
    required this.canControl,
    required this.hasQueue,
  });

  final JamEngine engine;
  final JamGuestEngine? guest;
  final JamSessionController session;
  final bool canControl;
  final bool hasQueue;

  @override
  Widget build(BuildContext context) {
    final mediaId = engine.snapshot.mediaId;
    final fetcher = guest;
    final canSend = session.canSendCommands;
    final roomPlaying = engine.snapshot.status == PlaybackStatus.playing;
    // While this phone's own sound is suspended (a call, another app,
    // headphones out) the room plays on without it, and the big button is
    // "Resume audio" — for everyone, since it touches only this phone. As
    // "Pause" it stopped the whole room for someone who only wanted their
    // own sound back. Mirrors the docked bar.
    final suspended = engine.outputSuspension.value != null;
    final playing = roomPlaying && !suspended;
    final controls = canControl && canSend && hasQueue;

    final bar = JamTransport(
      state: playing ? JamPlaybackState.playing : JamPlaybackState.paused,
      enabled: suspended || controls,
      playLabel: suspended ? JamRoomBannerStrings.resume : null,
      // The bar is dimmed for different reasons and each needs its own
      // sentence: a host with an empty room is not being told that somebody
      // else is in charge, and a guest whose host is asleep is not being
      // told the rules changed.
      gatedMessage: !canControl
          ? jamHostControlsPlayback
          : !canSend
          ? (session.hostAway
                ? JamRoomStrings.waitForHost
                : JamRoomStrings.waitForReconnect)
          : JamRoomStrings.nothingToPlay,
      onPlayPause: suspended
          ? () => unawaited(engine.resumeLocalOutput())
          : () => unawaited(
              session.act(
                (e) => roomPlaying ? e.transportPause() : e.transportPlay(),
              ),
            ),
      onPrevious: controls
          ? () => unawaited(session.act((e) => e.transportPrevious()))
          : null,
      onNext: controls
          ? () => unawaited(session.act((e) => e.transportNext()))
          : null,
    );

    if (fetcher == null || mediaId == null) return bar;

    void retry() {
      // False when there is nothing left to retry (it landed, or is already
      // being fetched again); the next state change redraws either way, but
      // a tap that did nothing visible deserves a word.
      if (!fetcher.retryFetch(mediaId)) session.notify(kJamIntentFailed);
    }

    return ValueListenableBuilder<Map<String, JamPrefetchState>>(
      valueListenable: fetcher.prefetchStates,
      builder: (context, states, _) {
        final state = states[mediaId];
        return switch (jamTrackFetchOf(state)) {
          JamTrackFetch.ready => bar,
          JamTrackFetch.fetching when canControl => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              bar,
              const SizedBox(height: JamSpace.sm),
              _FetchCaption(progress: state!.progress),
            ],
          ),
          JamTrackFetch.fetching => _Fetching(progress: state!.progress),
          JamTrackFetch.failed when canControl => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              bar,
              const SizedBox(height: JamSpace.xs),
              _FetchFailed(onRetry: retry, compact: true),
            ],
          ),
          JamTrackFetch.failed => _FetchFailed(onRetry: retry),
        };
      },
    );
  }
}

/// "Getting this track — 63%" under a transport that stays usable.
class _FetchCaption extends StatelessWidget {
  const _FetchCaption({required this.progress});

  final double progress;

  @override
  Widget build(BuildContext context) {
    final percent = (progress.clamp(0.0, 1.0) * 100).round();
    return Text(
      JamRoomStrings.fetching(percent),
      textAlign: TextAlign.center,
      style: context.jamCaption.copyWith(color: context.jamColors.warning),
    );
  }
}

/// "Couldn't get this track · Retry" — the end of the line for a fetch the
/// engine gave up on, which used to sit on "Getting this track — 40%" with
/// nothing moving and nothing to press.
class _FetchFailed extends StatelessWidget {
  const _FetchFailed({required this.onRetry, this.compact = false});

  final VoidCallback onRetry;

  /// One line under a live transport, rather than the 72 dp glyph that
  /// stands in for one.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final line = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            JamRoomStrings.fetchFailed,
            textAlign: TextAlign.center,
            style: context.jamCaption.copyWith(color: colors.danger),
          ),
        ),
        const SizedBox(width: JamSpace.xs),
        JamButton.tertiary(
          label: JamRoomStrings.retry,
          semanticLabel: JamRoomStrings.retryFetch,
          onPressed: onRetry,
        ),
      ],
    );
    if (compact) return Center(child: line);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 72,
          height: 72,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: colors.surfaceMuted,
            shape: BoxShape.circle,
          ),
          child: Icon(
            Icons.music_off_rounded,
            size: 28,
            color: colors.textSecondary,
          ),
        ),
        const SizedBox(height: JamSpace.xs),
        line,
      ],
    );
  }
}

/// "Getting this track — 63%". The transport's shape with a determinate ring
/// standing in for the play button: a guest can see that the room is playing
/// something they simply do not have yet.
class _Fetching extends StatelessWidget {
  const _Fetching({required this.progress});

  final double progress;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final percent = (progress.clamp(0.0, 1.0) * 100).round();
    return Semantics(
      label: JamRoomStrings.fetching(percent),
      excludeSemantics: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 72,
            height: 72,
            child: Stack(
              alignment: Alignment.center,
              children: [
                SizedBox(
                  width: 72,
                  height: 72,
                  child: CircularProgressIndicator(
                    value: progress.clamp(0.0, 1.0),
                    strokeWidth: 3,
                    backgroundColor: colors.surfaceMuted,
                    color: colors.accent,
                  ),
                ),
                Icon(
                  Icons.south_rounded,
                  size: 28,
                  color: colors.textSecondary,
                ),
              ],
            ),
          ),
          const SizedBox(height: JamSpace.sm),
          Text(
            JamRoomStrings.fetching(percent),
            textAlign: TextAlign.center,
            style: context.jamCaption.copyWith(color: colors.warning),
          ),
        ],
      ),
    );
  }
}

/// Faces, not counts (§6.2). The strip is the People sheet's door on the
/// left and the Queue's on the right, with the host's invite between them.
class _PeopleStrip extends StatelessWidget {
  const _PeopleStrip({
    required this.roster,
    required this.hostName,
    required this.selfName,
    required this.isHost,
    required this.queueCount,
    required this.ambient,
    required this.onPeople,
    required this.onQueue,
  });

  final List<String> roster;
  final String hostName;
  final String selfName;
  final bool isHost;
  final int queueCount;
  final Animation<double> ambient;
  final VoidCallback onPeople;
  final VoidCallback onQueue;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;

    final faces = JamAvatarStack(
      names: roster,
      size: JamAvatarSize.strip,
      maxVisible: 4,
      hostName: hostName,
      youName: selfName,
    );

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Flexible(
          child: Semantics(
            container: true,
            button: true,
            label: '${JamRoomStrings.people}, ${roster.length}',
            // The InkWell's tap is excluded with its semantics; the action
            // has to be declared here or a screen reader cannot press it.
            onTap: onPeople,
            excludeSemantics: true,
            child: InkWell(
              onTap: onPeople,
              borderRadius: BorderRadius.circular(JamRadius.pill),
              child: Padding(
                // No horizontal inset: the strip, the title block and the
                // scrubber all start on the column's own left edge. Three
                // near-misses read as a wobble, which is exactly what the
                // landscape review caught.
                padding: const EdgeInsets.symmetric(vertical: JamSpace.sm),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // The bob: 2 dp on the room's own cycle. Per-avatar phase
                    // offsets would mean reimplementing JamAvatarStack, so
                    // the strip breathes as one.
                    AnimatedBuilder(
                      animation: ambient,
                      builder: (context, child) => Transform.translate(
                        offset: Offset(
                          0,
                          -_kAvatarBob * math.sin(ambient.value * 2 * math.pi),
                        ),
                        child: child,
                      ),
                      child: faces,
                    ),
                    const SizedBox(width: JamSpace.sm),
                    Flexible(
                      child: Text(
                        JamRoomStrings.inTheRoom(roster.length),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.jamFootnote.copyWith(
                          color: colors.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (isHost)
          JamButton.tertiary(label: JamRoomStrings.invite, onPressed: onPeople),
        Semantics(
          container: true,
          button: true,
          label:
              '${JamRoomStrings.queue}, ${JamRoomStrings.queued(queueCount)}',
          onTap: onQueue,
          excludeSemantics: true,
          child: InkWell(
            onTap: onQueue,
            borderRadius: BorderRadius.circular(JamRadius.pill),
            child: Padding(
              // Mirrors the people side: flush to the column's right edge.
              padding: const EdgeInsets.symmetric(vertical: JamSpace.sm),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.queue_music_rounded,
                    size: 20,
                    color: colors.textSecondary,
                  ),
                  const SizedBox(width: JamSpace.sm),
                  Text(
                    JamRoomStrings.queued(queueCount),
                    style: context.jamFootnote.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// PROTOCOL.md §6.3: do not start a track people do not have yet. The host
/// has always tracked this; the old UI showed it only as per-peer chips
/// buried in a list, so a host would start a song two people could not hear.
class _ReadinessNote extends StatelessWidget {
  const _ReadinessNote({required this.engine});

  final JamEngine engine;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final host = engine is JamHostEngine ? engine as JamHostEngine : null;
    final mediaId = engine.snapshot.mediaId;
    if (host == null || mediaId == null) return const SizedBox.shrink();

    final waiting = host
        .peerMediaStates(mediaId)
        .values
        .where((s) => s != MediaReadiness.ready)
        .length;
    // The gate says why a play has not started yet; the count says who the
    // room is waiting on otherwise. The gate goes first: a hold only exists
    // while somebody is mid-download, so behind the count it could never be
    // seen, and it is the answer to the play the host just pressed — the
    // music will start by itself (§6.3). Listened to, not read: a hold that
    // a guest's play request started comes with no broadcast to rebuild
    // this screen.
    return ValueListenableBuilder<bool>(
      valueListenable: host.awaitingReadiness,
      builder: (context, awaiting, _) {
        final String? note = awaiting
            ? JamRoomStrings.awaitingReadiness
            : waiting > 0
            ? JamRoomStrings.waiting(waiting)
            : null;
        if (note == null) return const SizedBox.shrink();
        return Text(
          note,
          textAlign: TextAlign.center,
          style: context.jamCaption.copyWith(color: colors.warning),
        );
      },
    );
  }
}

/// "Adding your music · 3 of 12" while the host's starting files go in — in
/// the room, which is already open, rather than behind a spinner on the
/// button that opened it.
class _ImportNote extends StatelessWidget {
  const _ImportNote({required this.import});

  final JamImport import;

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<JamImportProgress>(
        valueListenable: import.progress,
        builder: (context, progress, _) {
          // One file is in or not; a count only means something for several.
          if (progress.isDone || progress.total < 2) {
            return const SizedBox.shrink();
          }
          return Padding(
            padding: const EdgeInsets.only(top: JamSpace.xs),
            child: Text(
              JamRoomStrings.importingCount(progress.completed, progress.total),
              textAlign: TextAlign.center,
              style: context.jamCaption.copyWith(
                color: context.jamColors.textSecondary,
              ),
            ),
          );
        },
      );
}

/// The jam-started moment: the brand gradient, the room's name, 700 ms, gone.
/// Tap to skip — it is a flourish, not a step.
class _JamStarted extends StatelessWidget {
  const _JamStarted({required this.roomName, required this.onSkip});

  final String roomName;
  final VoidCallback onSkip;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: GestureDetector(
        onTap: onSkip,
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0, end: 1),
          duration: _kCelebration,
          builder: (context, t, _) {
            final scale =
                0.8 +
                0.2 * JamCurve.celebration.transform(math.min(t / 0.5, 1));
            final fade = t < 0.7 ? 1.0 : 1 - (t - 0.7) / 0.3;
            return Opacity(
              opacity: fade.clamp(0.0, 1.0),
              child: DecoratedBox(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [JamColors.brandRaspberry, Color(0xFFC71F5E)],
                  ),
                ),
                child: Center(
                  child: Transform.scale(
                    scale: scale,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.graphic_eq_rounded,
                          size: 72,
                          color: Colors.white,
                        ),
                        const SizedBox(height: JamSpace.xl),
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: JamSpace.xxxl,
                          ),
                          child: Text(
                            roomName,
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: context.jamDisplay.copyWith(
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// The terminal states. Each says what happened and what to do about it —
/// never "check your connection", because there is no connection by design.
///
/// Getting back in is the primary action wherever getting back in is a real
/// possibility (addendum §2): the room that closed was probably a host whose
/// phone went to sleep, and the sha-keyed cache means a rejoin costs nothing.
class JamSessionEndedView extends StatelessWidget {
  const JamSessionEndedView({
    super.key,
    required this.reason,
    this.rejectReason,
    required this.onDone,
    this.onRetry,
    this.onStartNew,
    this.retrying = false,
    this.error,
  });

  final JamSessionEndReason? reason;

  /// For [JamSessionEndReason.rejected]: what the host said (§3.1), which
  /// picks the copy and whether a retry is offered ([jamRejectIsRetryable]).
  final RejectReason? rejectReason;

  /// Back to nearby. Null while a retry is in flight.
  final VoidCallback? onDone;

  /// Rejoin the room this device came from, when there is one to rejoin.
  final VoidCallback? onRetry;

  /// Host only: open host setup again on the room the OS took away.
  final VoidCallback? onStartNew;

  /// A "Try again" is running: its button spins in place.
  final bool retrying;

  /// Why the last "Try again" failed, said here rather than in a snackbar
  /// over a screen that is about to be read anyway.
  final String? error;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final (icon, title, detail) = switch (reason) {
      JamSessionEndReason.hostGone => (
        Icons.podcasts_rounded,
        JamRoomStrings.hostGoneTitle,
        JamRoomStrings.hostGoneBody,
      ),
      JamSessionEndReason.kicked => (
        Icons.person_remove_rounded,
        JamRoomStrings.kickedTitle,
        JamRoomStrings.kickedBody,
      ),
      JamSessionEndReason.rejected => switch (rejectReason) {
        RejectReason.badToken => (
          Icons.lock_reset_rounded,
          JamRoomStrings.restartedTitle,
          JamRoomStrings.restartedBody,
        ),
        RejectReason.version => (
          Icons.system_update_rounded,
          JamRoomStrings.versionTitle,
          JamRoomStrings.versionBody,
        ),
        RejectReason.full => (
          Icons.groups_rounded,
          JamRoomStrings.fullTitle,
          JamRoomStrings.fullBody,
        ),
        // `kicked` arrives as its own end reason; it is here only so the
        // switch is total.
        RejectReason.kicked => (
          Icons.person_remove_rounded,
          JamRoomStrings.kickedTitle,
          JamRoomStrings.kickedBody,
        ),
        RejectReason.unknown || null => (
          Icons.lock_outline_rounded,
          JamRoomStrings.rejectedTitle,
          JamRoomStrings.rejectedBody,
        ),
      },
      // The host said goodbye on purpose (§3.4). Nothing to try again for —
      // the room they would rejoin does not exist any more.
      JamSessionEndReason.hostEnded => (
        // `nightlight_round` is a *different* icon, not the rounded cut of
        // this one; every other glyph on this screen is `_rounded`.
        Icons.nightlight_round_rounded,
        JamRoomStrings.hostEndedTitle,
        JamRoomStrings.hostEndedBody,
      ),
      // The host's own room, gone without "End jam" being pressed.
      JamSessionEndReason.listenerFailed => (
        Icons.wifi_tethering_off_rounded,
        JamRoomStrings.listenerFailedTitle,
        JamRoomStrings.listenerFailedBody,
      ),
      _ => (
        Icons.check_circle_outline_rounded,
        JamRoomStrings.endedTitle,
        JamRoomStrings.endedBody,
      ),
    };
    // Only a room that might still let you in is worth offering a way back
    // into: hostGone (a phone that slept) and a refusal a retry could turn
    // around (a full room). A restarted room or a version mismatch never
    // lets the same link back in; a kick must never be undoable (§5.6); and
    // a host who ended the jam deliberately has no room left to rejoin.
    final retry = switch (reason) {
      JamSessionEndReason.hostGone => onRetry,
      JamSessionEndReason.rejected when jamRejectIsRetryable(rejectReason) =>
        onRetry,
      _ => null,
    };
    final startNew = reason == JamSessionEndReason.listenerFailed
        ? onStartNew
        : null;
    final message = error;

    // One primary per screen (§8 check 5): getting back in, or starting
    // again, when either is possible; otherwise the way home.
    final List<Widget> actions;
    if (retry != null || retrying) {
      actions = [
        JamButton.primary(
          label: JamRoomStrings.tryAgain,
          onPressed: retrying ? null : retry,
          loading: retrying,
          expand: true,
        ),
        const SizedBox(height: JamSpace.md),
        JamButton.secondary(
          label: JamRoomStrings.back,
          onPressed: onDone,
          expand: true,
        ),
      ];
    } else if (startNew != null) {
      actions = [
        JamButton.primary(
          label: JamRoomStrings.startNew,
          onPressed: startNew,
          expand: true,
        ),
        const SizedBox(height: JamSpace.md),
        JamButton.secondary(
          label: JamRoomStrings.back,
          onPressed: onDone,
          expand: true,
        ),
      ];
    } else {
      actions = [
        JamButton.primary(
          label: JamRoomStrings.back,
          onPressed: onDone,
          expand: true,
        ),
      ];
    }

    return Scaffold(
      backgroundColor: colors.canvas,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Padding(
              padding: const EdgeInsets.all(JamSpace.xxxl),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 72,
                    height: 72,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: colors.surfaceMuted,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(icon, size: 32, color: colors.textSecondary),
                  ),
                  const SizedBox(height: JamSpace.xl),
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: context.jamSheetTitle,
                  ),
                  const SizedBox(height: JamSpace.sm),
                  Text(
                    detail,
                    textAlign: TextAlign.center,
                    style: context.jamByline.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                  if (message != null) ...[
                    const SizedBox(height: JamSpace.md),
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        message,
                        textAlign: TextAlign.center,
                        style: context.jamFootnote.copyWith(
                          color: colors.danger,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: JamSpace.xxxl),
                  ...actions,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Queue and room, docked beside the player on wide windows.
///
/// The same [QueuePanel] and [RoomPanel] a phone opens as modal sheets. A
/// desktop window has the room to leave them open, and hiding them behind a
/// tap there is pure cost.
class _SidePanel extends StatefulWidget {
  const _SidePanel({
    required this.engine,
    required this.selfName,
    required this.network,
  });

  final JamEngine engine;
  final String selfName;
  final JamNetworkStatus network;

  @override
  State<_SidePanel> createState() => _SidePanelState();
}

enum _PanelTab { queue, room }

class _SidePanelState extends State<_SidePanel> {
  _PanelTab _tab = _PanelTab.queue;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    // A Material, not a coloured Container: the panel's rows are ListTiles
    // and SwitchListTiles, which paint their fill and their ink on the
    // nearest Material ancestor — a DecoratedBox in between hides both, and
    // the framework says so out loud.
    return SizedBox(
      width: JamContentWidth.panel,
      child: Material(
        color: colors.surface,
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(color: colors.separator, width: 0.5),
            ),
          ),
          child: Column(
            children: [
              // Two flat tabs under a 2 dp accent underline (§5 Wide layouts) —
              // a SegmentedButton in a 340 dp panel reads as a form control.
              Row(
                children: [
                  for (final tab in _PanelTab.values)
                    Expanded(
                      child: _PanelTabButton(
                        label: tab == _PanelTab.queue
                            ? JamRoomStrings.panelQueue
                            : JamRoomStrings.panelRoom,
                        selected: _tab == tab,
                        onTap: () => setState(() => _tab = tab),
                      ),
                    ),
                ],
              ),
              Divider(height: 0.5, color: colors.separator),
              Expanded(
                child: switch (_tab) {
                  // The tab above already says "Queue", so the panel drops its
                  // own header and keeps only what it carries — the count and
                  // the Add action.
                  _PanelTab.queue => Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                          JamSpace.md,
                          JamSpace.sm,
                          JamSpace.md,
                          0,
                        ),
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: QueueHeaderActions(engine: widget.engine),
                        ),
                      ),
                      Expanded(
                        child: QueuePanel(
                          engine: widget.engine,
                          showHeader: false,
                        ),
                      ),
                    ],
                  ),
                  _PanelTab.room => RoomPanel(
                    engine: widget.engine,
                    selfName: widget.selfName,
                    network: widget.network,
                  ),
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PanelTabButton extends StatelessWidget {
  const _PanelTabButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    return Semantics(
      container: true,
      button: true,
      selected: selected,
      label: label,
      onTap: onTap,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: 48,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: selected ? colors.accent : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Text(
            label,
            style: context.jamRowTitle.copyWith(
              color: selected ? colors.accent : colors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}
