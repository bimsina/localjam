/// Now Playing — one player for both sides of a jam (DESIGN_SPEC v3 §6.3).
///
/// Written against the abstract [JamEngine] and gated on
/// `engine.can(JamCapability…)`, so a host and a guest render the same screen
/// and the difference is what you may touch.
///
/// Immersive in both themes (D4): a matte wash of the cover's colour that
/// falls into warm charcoal fills the window behind white text. The subtree
/// is themed dark so every shared component on it (menus, the docked People
/// panel through `JamOnBackdrop`) resolves its dark, white-on-colour variant
/// whatever the app's appearance. The song is the focus — cover, title,
/// artist, timeline, the ivory play square; the people are one line in the
/// footer and, when someone else put the song on, one quiet credit. The
/// queue opens in place (D5): the cover shrinks into a thumbnail beside the
/// title and the list takes the middle of the page, with the scrubber and
/// transport pinned.
///
/// Quiet when correct: nothing says "in sync". A problem is one footnote
/// under the room's name; a state that wants something done is a notice
/// above the cover with its one action.
///
/// Leaving is explicit. The chevron (and the drag down) minimises back to
/// Home with the session still running; ending or leaving is in the •••
/// menu, behind a confirmation.
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart'
    show
        Material,
        MaterialBasedCupertinoThemeData,
        MaterialType,
        Theme,
        ThemeData;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:localjam_client/localjam_client.dart';

import '../design/breakpoints.dart';
import '../design/motion.dart';
import '../design/theme.dart';
import '../design/tokens.dart';
import '../design/typography.dart';
import '../router.dart' show HostSetupArgs;
import '../state/session_controller.dart';
import '../util/format.dart';
import '../util/network.dart';
import 'session_ended_view.dart';
import '../widgets/artwork.dart';
import '../widgets/avatar.dart';
import '../widgets/buttons.dart';
import '../widgets/diagnostics_sheet.dart';
import '../widgets/dialogs.dart';
import '../widgets/drag_to_dismiss.dart';
import '../widgets/jam_mark.dart' show JamMark, JamMarkSize, jamMarkShape;
import '../widgets/list.dart' show JamDisclosureChevron;
import '../widgets/marquee.dart';
import '../widgets/menu.dart';
import '../widgets/nudge_slider.dart';
import '../widgets/peer_row.dart' show JamPeopleFit, JamPeopleLine;
import '../widgets/pressable.dart';
import '../widgets/queue_sheet.dart';
import '../widgets/room_banner.dart';
import '../widgets/room_sheet.dart';
import '../widgets/switch.dart';
import '../widgets/sync_indicator.dart';
import '../widgets/track_row.dart';
import '../widgets/transport.dart';

/// Every user-facing string the room can show.
abstract final class JamRoomStrings {
  // Header and footer.
  static const String close = 'Close now playing';
  static const String invite = 'Invite people';
  static const String people = 'People';
  static const String soundOffset = 'Sound offset';
  static const String queue = 'Up next';
  static const String more = 'More';

  /// The footer names who you are listening with, from your side.
  static const String justYou = JamPeopleStrings.justYou;

  /// "With Mia and Theo" — the people besides you, as every screen says
  /// them ([jamPeopleSummary]).
  static String withPeople(List<String> others) => jamPeopleSummary(others);

  /// What the footer's people button does, after it says who is here: its
  /// label is what it shows (RB-9), so the word "People" is the hint.
  static const String peopleHint = 'Shows everyone in the jam';

  // The ••• menu (spec §10.1): only what has no control of its own.
  static const String diagnostics = 'Diagnostics';
  static const String endJam = 'End jam';
  static const String leaveJam = 'Leave jam';
  // The same confirmation the People sheet asks, word for word.
  static const String endTitle = RoomSheetStrings.endTitle;
  static const String endBody = RoomSheetStrings.endDetail;
  static const String leaveTitle = RoomSheetStrings.leaveTitle;
  static const String leaveBody = RoomSheetStrings.leaveDetail;
  static const String leave = RoomSheetStrings.leave;
  static const String cancel = 'Cancel';

  // The title block.
  static const String nothingPlaying = 'Nothing playing';
  static const String addSongs = 'Add songs';
  static const String nothingQueuedBody = 'The host hasn’t added any songs.';
  static const String importing = 'Adding your music…';

  /// "Added by Mia" / "Added by you".
  static String addedBy(String name) => '${JamTrackRowStrings.addedBy} $name';
  static const String addedByYou = JamTrackRowStrings.addedByYou;

  /// What a host with no shared display name is called. A guest learns the
  /// host's real name from the welcome frame; this is the fallback.
  static const String host = 'Host';

  // Under a transport the room has not taken away, but that cannot reach the
  // host right now — dimmed with a reason, never silently dead.
  static const String waitForHost =
      'Controls come back when the host’s phone wakes.';
  static const String waitForReconnect =
      'Controls come back once you reconnect.';
  static const String nothingToPlay = 'Add songs to start the jam.';

  // Status lines under the room's name, and the fetch capsule.
  static String fetching(int percent) => 'Getting this song… $percent%';
  static const String fetchFailed = 'Couldn’t get this song';
  static const String retry = 'Try again';

  /// What "Try again" says to a screen reader, which hears it apart from
  /// the sentence before it.
  static const String retryFetch = 'Try getting this song again';
  static String importingCount(int done, int total) =>
      'Adding your music… $done of $total';

  /// The host's play is held until every guest has the track (§6.3).
  static const String awaitingReadiness = 'Waiting for everyone’s download…';
  static String waiting(int n) => n == 1
      ? 'Waiting for 1 person to get this song'
      : 'Waiting for $n people to get this song';

  /// The docked panel's two views (wide windows).
  static const String panelQueue = 'Up next';
  static const String panelRoom = 'People';
}

/// The footer's faces: the people in the room, as a pile.
const Key kJamRoomFacesKey = Key('jam.room.faces');

/// Below this page height the vertical player cannot hold its own shape, so
/// the room turns side-on: cover left, controls right. Landscape phones live
/// here, and so does a short desktop window.
const double kRoomShortHeight = 560;

/// The cover's side margin in a tablet or desktop pane, where the cover
/// grows with the space (§10.12) rather than stopping at a phone's size.
const double _kArtMarginWide = 48;

/// The widest the cover gets in a large pane: past this a cover stops
/// reading as an object held in the hand and starts reading as a poster.
const double _kArtMaxWide = 640;

/// The most the gap between the transport and the footer grows. In a tall
/// pane the leftover height goes above and below the player as a group,
/// so the footer stays with the controls (§10.12).
const double _kTransportFooterMaxGap = 56;

/// The queue-in-place thumbnail (§6.3) and the gap beside it.
const double _kThumb = JamArtworkSize.list;
const double _kThumbGap = 12;

/// The empty room's jam mark at rest: the jam as a page draws it (its
/// monogram at the page marks' proportion), not a cover-sized slab that
/// reads as missing artwork. Never more than half the cover's square.
const double _kEmptyMark = 152;

/// How far the paused cover springs back (§6.3).
const double _kPausedScale = 0.96;

/// How far the paused cover dims instead, under reduced motion (RB-18).
const double _kPausedDim = 0.72;

/// The hairline on the Now Playing cover's edge (RB-23).
const BorderSide _kCoverEdge = BorderSide(
  color: JamNowPlayingColors.separator,
  width: 0.5,
);

class RoomScreen extends StatefulWidget {
  const RoomScreen({super.key});

  @override
  State<RoomScreen> createState() => _RoomScreenState();
}

enum _PanelView { queue, people }

class _RoomScreenState extends State<RoomScreen>
    with SingleTickerProviderStateMixin {
  /// This device's name as last read, kept across visits: the room reads it
  /// asynchronously, and a face that showed "Y" in one colour and then "B"
  /// in another a frame later on every open was a flicker (RB-20).
  static String _knownIdentity = '';

  final List<StreamSubscription<Object?>> _subs = [];
  JamEngine? _bound;
  String _identity = _knownIdentity;

  /// The song whose credit line is being kept, so the line never folds away
  /// mid-song when the room changes under it (RB-16).
  String? _creditHeldFor;
  JamNetworkStatus _network = JamNetworkStatus.offline;

  /// The queue in place (D5): 0 = the big cover, 1 = the list.
  late final AnimationController _queue = AnimationController(
    vsync: this,
    duration: JamDuration.slow,
  );

  /// What the docked panel shows on wide windows.
  _PanelView _panel = _PanelView.queue;

  /// The stage's memory across the queue's morph.
  final _StageMemo _stageMemo = _StageMemo();

  /// The dark theme the immersive subtree runs under, per platform.
  ThemeData? _theme;
  TargetPlatform? _themePlatform;

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
      // "Start a New Jam" to host setup): leave the new top route alone.
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
    JamIdentity.changes.addListener(_onIdentityChanged);
    unawaited(_loadIdentity());
    unawaited(_refreshNetwork());
  }

  void _onIdentityChanged() => unawaited(_loadIdentity());

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bind(JamSession.of(context).engine);
  }

  /// Subscribes to the engine's own streams. Deliberately not the session
  /// controller's job: a track change should repaint this screen, not the
  /// app.
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
  }

  @override
  void dispose() {
    JamIdentity.changes.removeListener(_onIdentityChanged);
    _queue.dispose();
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    super.dispose();
  }

  Future<void> _loadIdentity() async {
    final name = await JamIdentity.displayName();
    _knownIdentity = name;
    if (mounted && name != _identity) setState(() => _identity = name);
  }

  Future<void> _refreshNetwork() async {
    final status = await currentNetwork();
    if (mounted) setState(() => _network = status);
  }

  ThemeData _nowPlayingTheme(BuildContext context) {
    final platform = Theme.of(context).platform;
    if (_theme == null || _themePlatform != platform) {
      _themePlatform = platform;
      _theme = jamDarkTheme(platform: platform);
    }
    return _theme!;
  }

  /// "Try again": the controller keeps this room mounted for the whole
  /// rejoin ([JamSessionController.rejoining]) and, if it fails, lands back
  /// on the same ended screen with [JamSessionController.error] saying why —
  /// so there is nothing to navigate here, in either outcome.
  Future<void> _retry(JamSessionController session) => session.rejoin();

  /// "Start a New Jam" after the OS took the room away: host setup again,
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

  /// "Scan new code" for a jam that restarted under one: out of the dead
  /// room to Home, which opens its own scanner (or Join with Link) as soon
  /// as it is on top — the same way in as from Nearby.
  Future<void> _scanNew(JamSessionController session) async {
    await session.acknowledgeEnd();
    if (!mounted) return;
    context.go('/');
    session.requestScan();
  }

  /// A pop, so the room plays its reverse slide back down. `go` would
  /// replace the stack and skip the exit animation entirely.
  void _minimise() => context.canPop() ? context.pop() : context.go('/');

  bool get _wide => context.jamBreakpoint.hasSidePanel;

  void _toggleQueue() {
    JamHaptics.selection();
    if (_wide) {
      setState(() => _panel = _PanelView.queue);
      return;
    }
    final open = _queue.value < 0.5;
    if (jamReducedMotion(context)) {
      _queue.value = open ? 1 : 0;
    } else if (open) {
      unawaited(_queue.forward());
    } else {
      unawaited(_queue.reverse());
    }
  }

  void _openPeople(JamEngine engine) {
    if (_wide) {
      JamHaptics.selection();
      setState(() => _panel = _PanelView.people);
      return;
    }
    unawaited(
      showRoomSheet(context, engine, selfName: _identity, network: _network),
    );
  }

  void _openInvite(JamEngine engine) => unawaited(
    showInviteSheet(context, engine, selfName: _identity, network: _network),
  );

  void _openSoundOffset(JamEngine engine) =>
      unawaited(showSoundOffsetSheet(context, engine));

  void _openDiagnostics(JamEngine engine) {
    final guest = engine is JamGuestEngine ? engine : null;
    unawaited(
      showDiagnosticsSheet(
        context,
        engine,
        clockOffsetUs: guest == null ? null : () => guest.clockOffsetUs,
      ),
    );
  }

  /// End Jam (host) / Leave Jam (guest), behind the same confirmation the
  /// People sheet uses.
  Future<void> _confirmLeave(JamSessionController session) async {
    final host = session.isHost;
    final confirmed = await JamDialogs.confirmDestructive(
      context,
      title: host ? JamRoomStrings.endTitle : JamRoomStrings.leaveTitle,
      message: host ? JamRoomStrings.endBody : JamRoomStrings.leaveBody,
      confirmLabel: host ? JamRoomStrings.endJam : JamRoomStrings.leave,
      cancelLabel: JamRoomStrings.cancel,
    );
    if (!confirmed || !mounted) return;
    JamHaptics.destructive();
    await session.leave();
    if (mounted) context.go('/');
  }

  /// Who put the playing song on (D6, R3): Now Playing's one quiet credit —
  /// only when it was someone else, and only when the jam has at least two
  /// other people; with one, the footer's "With Mia" already says whose song
  /// it is. Named as the roster names them (two Sams told apart); their face
  /// only when they shared a name.
  _Credit? _creditFor(
    JamEngine engine,
    Map<String, Color> faces,
    Map<String, String> names,
  ) {
    final item = engine.currentItem;
    final adder = item?.addedBy;
    if (item == null || adder == null || adder == engine.selfPeerId) {
      return null;
    }
    if (names.length < 3) return null;
    final label = jamAddedByLabel(engine, item);
    if (label == null) return null;
    final name = label == kJamUnnamedPeer ? label : (names[adder] ?? label);
    return (name: name, color: label == kJamUnnamedPeer ? null : faces[adder]);
  }

  /// Whether the title keeps the credit's line (D6): while the jam is big
  /// enough to credit anyone and someone else's song is queued — so the line
  /// coming and going between songs never moves the controls — and, once
  /// kept, for the rest of the song that is playing (RB-16): someone leaving
  /// mid-song does not fold it away under a thumb.
  bool _reserveCredit(JamEngine engine, Map<String, String> names) {
    final playing = engine.currentItem?.mediaId;
    final wanted =
        names.length >= 3 &&
        engine.playlist.any(
          (song) =>
              song.addedBy != null &&
              song.addedBy != engine.selfPeerId &&
              jamAddedByLabel(engine, song) != null,
        );
    if (wanted) {
      _creditHeldFor = playing;
      return true;
    }
    if (playing != null && playing == _creditHeldFor) return true;
    _creditHeldFor = null;
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final session = JamSession.of(context);
    final engine = session.engine;

    if (session.phase == JamSessionPhase.ended || session.rejoining) {
      final reason = session.endReason;
      final rejoining = session.rejoining;
      // The jam as it ended — its name, its host, the cover that was
      // playing — kept by the controller past the engine a retry tears
      // down. Before it is known, the name the host's restart or the link
      // carried.
      final ended = session.endedJam;
      final link = session.lastJoinUri;
      final cover = ended?.cover;
      final coverPx =
          (JamMarkSize.ended * MediaQuery.devicePixelRatioOf(context)).round();
      return JamSessionEndedView(
        reason: reason,
        rejectReason: session.endRejectReason,
        jamName:
            ended?.name ??
            session.restartArgs?.name ??
            (link == null ? null : joinUriName(link)),
        hostName: ended?.hostName,
        cover: cover == null
            ? null
            : ResizeImage(MemoryImage(cover), width: coverPx, height: coverPx),
        retrying: rejoining,
        // Only a failed "Try again" leaves an error behind on this screen;
        // anything older was cleared when the session started.
        error: rejoining ? null : session.error,
        // Home at any point — mid-retry too: the rejoin is given up on
        // rather than waited out (CR-11).
        onDone: () async {
          await (session.rejoining
              ? session.cancelRejoin()
              : session.acknowledgeEnd());
          if (context.mounted) context.go('/');
        },
        // A host that suspended and came back is the documented
        // graceful-death path (DEVICE_TESTING §11), and the engine kept the
        // URI that gets you back in — the sha-keyed cache means the rejoin
        // re-fetches nothing. Not offered after a kick: §5.6 says never
        // auto-rejoin. (The view also drops it for refusals no retry can
        // fix.)
        onRetry:
            session.lastJoinUri != null && reason != JamSessionEndReason.kicked
            ? () => unawaited(_retry(session))
            : null,
        onStartNew: reason == JamSessionEndReason.listenerFailed
            ? () => unawaited(_startNew(session))
            : null,
        // The view offers it only where a new code is the way back in, and
        // never while a retry runs.
        onScan: () => unawaited(_scanNew(session)),
      );
    }
    if (engine == null) {
      // The room went away under this screen. The router's redirect only
      // guards going TO /room — a room already pushed stays on the stack —
      // and whoever ended it may not be around to send it home. Go home on
      // our own.
      if (!session.hasRoom) _leaveEmptyRoom();
      return const ColoredBox(
        color: JamNowPlayingColors.backdropPlaceholder,
        child: SizedBox.expand(),
      );
    }

    final wide = _wide;
    final guest = engine is JamGuestEngine ? engine : null;
    final isHost = engine is JamHostEngine;
    // Everyone, this device first, and their faces' colours (D3).
    final roster = jamRosterNames(engine, selfName: _identity);
    final faces = jamRosterColors(engine, selfName: _identity);
    final namesById = jamRosterNamesById(engine, selfName: _identity);
    final rosterColors = [
      for (final id in jamRosterPeerIds(engine))
        faces[id] ?? JamNowPlayingColors.tertiary,
    ];
    final canAdd = engine.can(JamCapability.addTracks);
    // A sheet over the player (People, Sound Offset) brings its own grabber;
    // two stacked bars read as one broken one.
    final onTop = ModalRoute.of(context)?.isCurrent ?? true;

    // Every action appears once (§10.1): Invite is the header's, People and
    // Sound Offset are the footer's. The ••• keeps what has no control of
    // its own.
    final menu = JamMenuButton(
      trigger: JamMenuTrigger.glassOnArtwork,
      triggerAlignment: AlignmentDirectional.centerEnd,
      semanticLabel: JamRoomStrings.more,
      // Dark over the backdrop, whatever the app theme says.
      brightness: Brightness.dark,
      // Up over the cover, never down over the scrubber and the play
      // square it would slice (PL-24).
      preferUp: true,
      groups: [
        [
          JamMenuItem(
            title: JamRoomStrings.soundOffset,
            icon: CupertinoIcons.slider_horizontal_3,
            onPressed: () => _openSoundOffset(engine),
          ),
          JamMenuItem(
            title: JamRoomStrings.diagnostics,
            icon: CupertinoIcons.waveform_path_ecg,
            onPressed: () => _openDiagnostics(engine),
          ),
        ],
        [
          JamMenuItem(
            title: isHost ? JamRoomStrings.endJam : JamRoomStrings.leaveJam,
            icon: isHost
                ? CupertinoIcons.xmark_circle
                : CupertinoIcons.square_arrow_right,
            destructive: true,
            onPressed: () => unawaited(_confirmLeave(session)),
          ),
        ],
      ],
    );

    Widget player({required bool showGrabber}) => _Player(
      engine: engine,
      guest: guest,
      session: session,
      identity: _identity,
      queue: _queue,
      wide: wide,
      showGrabber: showGrabber,
      grabberVisible: onTop,
      stageMemo: _stageMemo,
      menu: menu,
      roster: roster,
      rosterColors: rosterColors,
      credit: _creditFor(engine, faces, namesById),
      reserveCredit: _reserveCredit(engine, namesById),
      peopleSelected: wide && _panel == _PanelView.people,
      onClose: _minimise,
      onInvite: () => _openInvite(engine),
      onQueue: _toggleQueue,
      onPeople: () => _openPeople(engine),
      onDiagnostics: () => _openDiagnostics(engine),
      onAdd: canAdd ? () => unawaited(jamAddToQueue(context, engine)) : null,
    );

    return DragToDismiss(
      // A desktop window has no dismiss gesture — the room is a destination
      // beside the sidebar, not a sheet over a phone screen.
      enabled: !wide,
      onDismiss: _minimise,
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: jamOverlayStyleOnDark,
        // Dark all the way down: the Theme for Material-resolved colours,
        // and the Cupertino theme and platform brightness for the dynamic
        // colours Cupertino controls resolve (the segmented control).
        child: MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(platformBrightness: Brightness.dark),
          child: Theme(
            data: _nowPlayingTheme(context),
            child: CupertinoTheme(
              data: MaterialBasedCupertinoThemeData(
                materialTheme: _nowPlayingTheme(context),
              ),
              child: Material(
                type: MaterialType.transparency,
                child: JamBackdropBuilder(
                  engine: engine,
                  // The cover's colours, resolved once per track through the
                  // cache the session holds — so minimising to the mini player
                  // does not decode the cover a second time.
                  cache: session.backdrops,
                  builder: (context, backdrop) => JamBackdropView(
                    backdrop: backdrop,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        const JamPresentationAppearance(
                          brightness: Brightness.dark,
                        ),
                        if (wide)
                          Row(
                            children: [
                              Expanded(child: player(showGrabber: false)),
                              _DockedPanel(
                                engine: engine,
                                view: _panel,
                                selfName: _identity,
                                network: _network,
                                onView: (view) => setState(() => _panel = view),
                              ),
                            ],
                          )
                        else
                          player(showGrabber: true),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The player: header, then the stage (an engine notice, cover, title,
/// queue, scrubber, transport, footer) in whichever shape the window can
/// hold — upright, side-on, or, when the text is too large for a cover to
/// fit beside it, the accessibility layout (R10).
class _Player extends StatelessWidget {
  const _Player({
    required this.engine,
    required this.guest,
    required this.session,
    required this.identity,
    required this.queue,
    required this.wide,
    required this.showGrabber,
    required this.grabberVisible,
    required this.stageMemo,
    required this.menu,
    required this.roster,
    required this.rosterColors,
    required this.credit,
    required this.reserveCredit,
    required this.peopleSelected,
    required this.onClose,
    required this.onInvite,
    required this.onQueue,
    required this.onPeople,
    required this.onDiagnostics,
    required this.onAdd,
  });

  final JamEngine engine;
  final JamGuestEngine? guest;
  final JamSessionController session;
  final String identity;
  final AnimationController queue;
  final bool wide;
  final bool showGrabber;

  /// False while a sheet sits over the player: its slot stays, empty.
  final bool grabberVisible;
  final _StageMemo stageMemo;
  final Widget menu;
  final List<String> roster;

  /// [roster]'s face colours, parallel to it.
  final List<Color> rosterColors;

  /// Who added the song that is playing, when it was someone else and the
  /// jam is big enough for it to say something (R3).
  final _Credit? credit;

  /// Keep the credit's line even when it is empty (see
  /// `_RoomScreenState._reserveCredit`).
  final bool reserveCredit;

  /// Wide only: the docked panel is showing People.
  final bool peopleSelected;

  final VoidCallback onClose;
  final VoidCallback? onInvite;
  final VoidCallback onQueue;
  final VoidCallback onPeople;
  final VoidCallback onDiagnostics;
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    final item = engine.currentItem;
    final canControl = engine.can(JamCapability.controlPlayback);
    // The room lets you, but the host cannot hear you right now (asleep, or
    // the link is down): seeking is as dead as the transport, and says so.
    final canSend = session.canSendCommands;
    final paused = engine.snapshot.status != PlaybackStatus.playing;
    // A phone's cover spans the width; a tablet's grows with the pane
    // (§10.12) up to a poster's size, and the height left after the controls
    // caps both.
    final phone = context.jamBreakpoint == JamBreakpoint.compact;
    final margin = phone ? JamSpace.player : _kArtMarginWide;
    final importing =
        session.hostImport != null &&
        !session.hostImport!.progress.value.isDone;
    // The queue in place, on phones. A wide window docks Up Next beside the
    // player instead, so the stage never opens it there — even if it was
    // left open before the window grew.
    final Animation<double> inPlace = wide ? kAlwaysDismissedAnimation : queue;

    // The song's own words grow with the text size all the way; the room's
    // chrome around it (its name, the times, the footer, a gated line) stops
    // at twice the size, the way the mini player's does — at the largest
    // sizes a footnote at 3× would take the whole page from the song.
    Widget chrome(Widget child) => MediaQuery.withClampedTextScaling(
      maxScaleFactor: _kChromeMaxScale,
      child: child,
    );

    final header = chrome(
      _Header(
        engine: engine,
        guest: guest,
        session: session,
        margin: margin,
        showGrabber: showGrabber,
        grabberVisible: grabberVisible,
        onClose: onClose,
        onInvite: onInvite,
        onDiagnostics: onDiagnostics,
      ),
    );

    Widget title({required bool accessible}) => _TitleBlock(
      engine: engine,
      item: item,
      importing: importing,
      canAdd: onAdd != null,
      menu: menu,
      // The accessibility layout swaps the title for the list rather than
      // shrinking it beside a thumbnail.
      queue: accessible ? kAlwaysDismissedAnimation : inPlace,
      credit: credit,
      reserveCredit: reserveCredit,
      accessible: accessible,
    );

    final scrubber = chrome(
      _Scrubber(
        engine: engine,
        session: session,
        enabled: canControl && canSend && item != null,
      ),
    );

    final gated = _TransportArea.gatedMessageFor(
      session: session,
      canControl: canControl,
    );
    // An empty room's one way forward — not while the host's own files are
    // still coming in, and not once the list opens with its own Add songs
    // row.
    final add = importing ? null : onAdd;
    final roomHasSongs =
        engine.playlist.isNotEmpty || engine.outputSuspension.value != null;
    Widget transportOffering(VoidCallback? add) => chrome(
      _TransportArea(
        engine: engine,
        session: session,
        canControl: canControl,
        hasQueue: engine.playlist.isNotEmpty,
        gatedMessage: gated,
        onAdd: add,
        queue: wide ? null : queue,
      ),
    );
    // Side-on and in the accessibility layout, Add songs stands where play
    // will; upright it sits right under "Nothing playing" (its own slot).
    final transport = transportOffering(add);

    final footer = chrome(
      _Footer(
        roster: roster,
        colors: rosterColors,
        peopleSelected: peopleSelected,
        queue: wide ? null : queue,
        onPeople: onPeople,
        onQueue: onQueue,
      ),
    );

    final notice = _EngineNotice(
      engine: engine,
      guest: guest,
      session: session,
    );

    return SafeArea(
      bottom: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final bottomInset = MediaQuery.paddingOf(context).bottom;
                final w = constraints.maxWidth;
                final h = constraints.maxHeight;
                final column = math.max(
                  0.0,
                  math.min(
                    w - margin * 2,
                    phone ? double.infinity : _kArtMaxWide,
                  ),
                );
                final estimate = _StageEstimate.of(
                  context,
                  width: column,
                  height: h,
                  bottomInset: bottomInset,
                  hasItem: item != null,
                  credit: credit != null || reserveCredit,
                  emptyBody: item == null && !importing && onAdd == null,
                  gatedMessage: gated,
                );
                // Side-on: a page too short to stand the player up (a phone
                // on its side, a short window), or a wide pane where the
                // cover would come out larger beside the controls than above
                // them (RB-6: a 1280×600 window, docked panel and all).
                final sideArt = math.min(
                  h - bottomInset - JamSpace.lg,
                  w * _kSideOnArtShare,
                );
                final sideOn =
                    h < kRoomShortHeight - 120 ||
                    (w > h * 1.25 && (!wide || sideArt > estimate.cover * 1.2));
                if (sideOn) {
                  return _SideOnStage(
                    engine: engine,
                    item: item,
                    paused: paused,
                    queue: inPlace,
                    margin: margin,
                    bottomInset: bottomInset,
                    notice: notice,
                    title: title(accessible: false),
                    scrubber: scrubber,
                    transport: transport,
                    footer: footer,
                    selfName: identity,
                    onCloseQueue: onQueue,
                  );
                }
                // Too little height left for a cover worth showing, or text
                // so large that a one-line title would show a few letters
                // at a time: the song's words come first, wrapped whole.
                final textScale =
                    MediaQuery.textScalerOf(context).scale(17) / 17;
                if (estimate.cover < kRoomArtFloor ||
                    textScale > kRoomAccessibleTextScale) {
                  return _AccessibleStage(
                    engine: engine,
                    queue: inPlace,
                    margin: margin,
                    bottomInset: bottomInset,
                    // Pinned while that leaves the song a real share of the
                    // page; past that everything scrolls together, so no
                    // two controls are ever drawn over each other.
                    scrollAll: estimate.pinned > h - kRoomArtFloor,
                    notice: notice,
                    title: title(accessible: true),
                    scrubber: scrubber,
                    transport: transport,
                    footer: footer,
                    selfName: identity,
                  );
                }
                final uprightTransport = transportOffering(null);
                return AnimatedBuilder(
                  animation: inPlace,
                  builder: (context, _) {
                    final t = JamCurve.standard.transform(inPlace.value);
                    final open = inPlace.value > 0;
                    return _Stage(
                      t: t,
                      margin: margin,
                      maxContent: phone ? double.infinity : _kArtMaxWide,
                      bottomInset: bottomInset,
                      memo: stageMemo,
                      children: [
                        // First, so a screen reader meets it where it is
                        // drawn: under the header.
                        _StageSlot(slot: _Slot.notice, child: notice),
                        _StageSlot(
                          slot: _Slot.art,
                          child: _Art(
                            engine: engine,
                            item: item,
                            paused: paused,
                            t: t,
                            onTap: inPlace.value == 1 ? onQueue : null,
                            // Upright, the empty room's mark stands on the
                            // title's edge, just over it: the jam, "Nothing
                            // playing" and Add songs read as one invitation.
                            markAlignment: AlignmentDirectional.bottomStart,
                          ),
                        ),
                        _StageSlot(
                          slot: _Slot.title,
                          child: title(accessible: false),
                        ),
                        if (add != null)
                          _StageSlot(
                            slot: _Slot.add,
                            child: chrome(
                              _EmptyRoomAdd(
                                offered: !roomHasSongs,
                                onAdd: add,
                                queue: wide ? null : queue,
                              ),
                            ),
                          ),
                        if (open)
                          _StageSlot(
                            slot: _Slot.queue,
                            child: IgnorePointer(
                              ignoring: inPlace.value < 1,
                              child: Opacity(
                                opacity: JamCurve.exit.transform(inPlace.value),
                                // The stage gives the list the column plus
                                // a margin each side: its rows line up with
                                // the cover it replaces, and their press
                                // highlight reaches past them.
                                child: QueuePanel(
                                  engine: engine,
                                  horizontalPadding: margin,
                                  selfName: identity,
                                ),
                              ),
                            ),
                          ),
                        _StageSlot(slot: _Slot.scrubber, child: scrubber),
                        _StageSlot(
                          slot: _Slot.transport,
                          child: uprightTransport,
                        ),
                        _StageSlot(slot: _Slot.footer, child: footer),
                      ],
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// The text scale the room's chrome stops growing at (see `_Player`).
const double _kChromeMaxScale = 2;

/// The smallest cover the upright player shows. Below it the cover goes and
/// the song's words take its place (R10): a stamp-sized cover above a title
/// cut to four letters serves neither.
const double kRoomArtFloor = 120;

/// Past this text scale (beyond Android's largest, from iOS's AX3) the
/// player always takes the accessibility layout, whatever room is left.
const double kRoomAccessibleTextScale = 2.2;

/// The share of a side-on page's width the cover may take.
const double _kSideOnArtShare = 0.4;

/// One line of [style] at [scaler], as laid out — exact under a nonlinear
/// scaler too, where `scale(lineHeight)` is not the line box (RB-10).
double _lineHeight(TextStyle style, TextScaler scaler) {
  final painter = TextPainter(
    text: TextSpan(text: 'Hg', style: style),
    textDirection: TextDirection.ltr,
    textScaler: scaler,
    maxLines: 1,
  )..layout();
  final height = painter.height;
  painter.dispose();
  return height;
}

/// The upright stage's heights before anything is laid out: what decides
/// whether a cover still fits beside the controls (R10), and how big it
/// would be (the side-on choice for wide panes, RB-6). Mirrors what
/// [_RenderStage] measures: the title block on one line, the timeline, the
/// transport and its gated line, the footer, the minimum gaps.
class _StageEstimate {
  const _StageEstimate._(this.cover, this.pinned);

  factory _StageEstimate.of(
    BuildContext context, {
    required double width,
    required double height,
    required double bottomInset,
    required bool hasItem,
    required bool credit,
    required bool emptyBody,
    required String? gatedMessage,
  }) {
    final scaler = MediaQuery.textScalerOf(context);
    final chrome = scaler.clamp(maxScaleFactor: _kChromeMaxScale);
    final styles = _TitleBlock.stylesOf(context);
    final footnote = context.jamFootnote;

    var titleH = _lineHeight(styles.title, scaler);
    if (hasItem) {
      titleH += JamSpace.xs + _lineHeight(styles.artist, scaler);
      if (credit) {
        titleH +=
            _kCreditGap +
            math.max(
              JamAvatarSize.scaled(context, JamAvatarSize.credit),
              _lineHeight(footnote, scaler),
            );
      }
    } else if (emptyBody) {
      titleH += JamSpace.xs + _lineHeight(styles.artist, scaler);
    }

    final large = MediaQuery.sizeOf(context).shortestSide >= 600;
    final times = large ? context.jamFootnote : context.jamCaption1;
    final scrubH = _kScrubberTrackSlot + _lineHeight(times, chrome);

    var transportH = JamMetrics.playSquare;
    if (gatedMessage != null) {
      final painter = TextPainter(
        text: TextSpan(text: gatedMessage, style: footnote),
        textDirection: TextDirection.ltr,
        textScaler: chrome,
        maxLines: 2,
      )..layout(maxWidth: math.max(1, width));
      transportH += JamSpace.md + painter.height;
      painter.dispose();
    }
    final footerH = math.max(
      JamMetrics.hitTarget,
      _lineHeight(footnote, chrome),
    );
    final bottomPad = bottomInset + JamSpace.sm;
    const gaps =
        JamSpace.sm + JamSpace.xl + JamSpace.md + JamSpace.lg + JamSpace.md;
    final cover = math.min(
      width,
      height - titleH - scrubH - transportH - footerH - gaps - bottomPad,
    );
    final pinned =
        JamSpace.md +
        scrubH +
        JamSpace.lg +
        transportH +
        JamSpace.md +
        footerH +
        bottomPad;
    return _StageEstimate._(cover, pinned);
  }

  /// The cover the upright stage would give (negative when it has none).
  final double cover;

  /// The accessibility layout's pinned controls: the timeline, the
  /// transport and the footer, with their gaps.
  final double pinned;
}

/// [JamScrubber]'s height above its times: half its 44 touch area, half the
/// held track, and the gap to the times.
const double _kScrubberTrackSlot = 44 / 2 + 10 / 2 + 4;

/// The accessibility layout (R10): no cover; the song's title, artist and
/// credit at the top, wrapping as long as they need and scrolling when
/// they need more; the timeline, the transport and the footer pinned at the
/// bottom, at their own heights, never drawn over each other. Up Next
/// takes the scrolling part's place.
///
/// When even the pinned controls would leave the song no room
/// ([scrollAll]), the whole page scrolls instead.
class _AccessibleStage extends StatelessWidget {
  const _AccessibleStage({
    required this.engine,
    required this.queue,
    required this.margin,
    required this.bottomInset,
    required this.scrollAll,
    required this.notice,
    required this.title,
    required this.scrubber,
    required this.transport,
    required this.footer,
    required this.selfName,
  });

  final JamEngine engine;
  final Animation<double> queue;
  final double margin;
  final double bottomInset;
  final bool scrollAll;
  final Widget notice;
  final Widget title;
  final Widget scrubber;
  final Widget transport;
  final Widget footer;
  final String selfName;

  @override
  Widget build(BuildContext context) {
    final song = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [notice, title],
    );
    final controls = Padding(
      padding: EdgeInsets.fromLTRB(
        margin,
        JamSpace.md,
        margin,
        bottomInset + JamSpace.sm,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          scrubber,
          const SizedBox(height: JamSpace.lg),
          transport,
          const SizedBox(height: JamSpace.md),
          footer,
        ],
      ),
    );
    final songPadding = EdgeInsets.fromLTRB(
      margin,
      JamSpace.sm,
      margin,
      JamSpace.md,
    );

    return LayoutBuilder(
      builder: (context, constraints) => AnimatedBuilder(
        animation: queue,
        builder: (context, _) {
          final list = queue.value == 0
              ? null
              : Opacity(
                  opacity: queue.value,
                  child: QueuePanel(
                    engine: engine,
                    horizontalPadding: margin,
                    selfName: selfName,
                  ),
                );
          if (scrollAll) {
            return SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (list == null)
                    Padding(padding: songPadding, child: song)
                  else
                    SizedBox(height: constraints.maxHeight * 0.7, child: list),
                  controls,
                ],
              ),
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child:
                    list ??
                    SingleChildScrollView(padding: songPadding, child: song),
              ),
              controls,
            ],
          );
        },
      ),
    );
  }
}

enum _Slot { notice, art, title, add, queue, scrubber, transport, footer }

/// Below this the stage stops narrowing its column to a height-capped
/// cover: the transport and the title need the room more than they need to
/// share the cover's edges.
const double _kMinColumn = 320;

/// The vertical stage (§6.3, §10.12).
///
/// Lays the controls out at their own heights, gives the cover what is left
/// (never more than the width allows), and spreads the slack the way the
/// Music app does — most of it around the transport. When the height, not
/// the width, caps the cover (a desktop window, an empty room on a short
/// phone), the column comes in to the cover: the title, the timeline, the
/// transport and the footer are laid out again at the cover's width, so
/// every row shares its edges.
///
/// [t] runs the queue in place: the cover into a 56 thumbnail at top-left,
/// the title beside it, the list in the middle, the controls pinned low. An
/// engine notice takes its height out of the cover alone — the controls
/// never move for it.
///
/// A render object rather than a layout delegate because of that second
/// pass: a delegate may lay each child out only once.
class _Stage extends MultiChildRenderObjectWidget {
  const _Stage({
    required this.t,
    required this.margin,
    required this.maxContent,
    required this.bottomInset,
    required this.memo,
    required super.children,
  });

  final double t;
  final double margin;
  final double maxContent;
  final double bottomInset;
  final _StageMemo memo;

  @override
  _RenderStage createRenderObject(BuildContext context) => _RenderStage(
    t: t,
    margin: margin,
    maxContent: maxContent,
    bottomInset: bottomInset,
    memo: memo,
  );

  @override
  void updateRenderObject(BuildContext context, _RenderStage renderObject) {
    renderObject
      ..t = t
      ..margin = margin
      ..maxContent = maxContent
      ..bottomInset = bottomInset
      ..memo = memo;
  }
}

/// Which part of the stage a child is.
class _StageSlot extends ParentDataWidget<_StageParentData> {
  _StageSlot({required this.slot, required super.child})
    : super(key: ValueKey<_Slot>(slot));

  final _Slot slot;

  @override
  void applyParentData(RenderObject renderObject) {
    final data = renderObject.parentData! as _StageParentData;
    if (data.slot == slot) return;
    data.slot = slot;
    renderObject.parent?.markNeedsLayout();
  }

  @override
  Type get debugTypicalAncestorWidgetClass => _Stage;
}

class _StageParentData extends ContainerBoxParentData<RenderBox> {
  _Slot? slot;
}

class _RenderStage extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _StageParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _StageParentData> {
  _RenderStage({
    required this._t,
    required this._margin,
    required this._maxContent,
    required this._bottomInset,
    required this.memo,
  });

  double get t => _t;
  double _t;
  set t(double value) {
    if (value == _t) return;
    _t = value;
    markNeedsLayout();
  }

  double get margin => _margin;
  double _margin;
  set margin(double value) {
    if (value == _margin) return;
    _margin = value;
    markNeedsLayout();
  }

  double get maxContent => _maxContent;
  double _maxContent;
  set maxContent(double value) {
    if (value == _maxContent) return;
    _maxContent = value;
    markNeedsLayout();
  }

  double get bottomInset => _bottomInset;
  double _bottomInset;
  set bottomInset(double value) {
    if (value == _bottomInset) return;
    _bottomInset = value;
    markNeedsLayout();
  }

  /// The big layout's title height, kept across the queue's morph: the
  /// title shrinks as the queue opens, and the controls placed under the
  /// big title must not follow it.
  _StageMemo memo;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _StageParentData) {
      child.parentData = _StageParentData();
    }
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  Map<_Slot, RenderBox> _slots() {
    final slots = <_Slot, RenderBox>{};
    var child = firstChild;
    while (child != null) {
      final data = child.parentData! as _StageParentData;
      final slot = data.slot;
      if (slot != null) slots[slot] = child;
      child = data.nextSibling;
    }
    return slots;
  }

  static double _layout(RenderBox? child, BoxConstraints constraints) {
    if (child == null) return 0;
    child.layout(constraints, parentUsesSize: true);
    return child.size.height;
  }

  static void _place(RenderBox? child, Offset offset) {
    if (child == null) return;
    (child.parentData! as _StageParentData).offset = offset;
  }

  @override
  void performLayout() {
    size = constraints.biggest;
    final w = size.width;
    final h = size.height;
    final t = this.t;
    final slots = _slots();
    final bottomPad = bottomInset + JamSpace.sm;
    final widest = math.max(0.0, math.min(w - margin * 2, maxContent));

    final notice = slots[_Slot.notice];

    const minTop = JamSpace.sm;
    const minArtTitle = JamSpace.xl;
    const minTitleScrub = JamSpace.md;
    const minScrubTransport = JamSpace.lg;
    const minTransportFooter = JamSpace.md;

    var footerH = 0.0;
    var transportH = 0.0;
    var scrubH = 0.0;
    var titleH = 0.0;
    void measure(double cw) {
      footerH = _layout(
        slots[_Slot.footer],
        BoxConstraints.tightFor(width: cw),
      );
      transportH = _layout(
        slots[_Slot.transport],
        BoxConstraints.tightFor(width: cw),
      );
      scrubH = _layout(
        slots[_Slot.scrubber],
        BoxConstraints.tightFor(width: cw),
      );
      final titleW = lerpDouble(cw, cw - _kThumb - _kThumbGap, t)!;
      titleH = _layout(
        slots[_Slot.title],
        BoxConstraints.tightFor(width: math.max(0, titleW)),
      );
    }

    double avail() {
      final bigTitleH = t == 0 ? titleH : (memo.bigTitleH ?? titleH);
      final fixed = footerH + transportH + scrubH + bigTitleH + bottomPad;
      return h -
          fixed -
          minTop -
          minArtTitle -
          minTitleScrub -
          minScrubTransport -
          minTransportFooter;
    }

    var cw = widest;
    measure(cw);
    var art = math.max(0.0, math.min(cw, avail()));
    if (art < cw - 0.5) {
      // The height holds the cover below the width it was offered: bring the
      // column in to it, and measure again (a line may wrap).
      cw = math.max(art, math.min(widest, _kMinColumn));
      measure(cw);
      art = math.max(0.0, math.min(cw, avail()));
    }
    if (t == 0) memo.bigTitleH = titleH;
    final bigTitleH = memo.bigTitleH ?? titleH;
    final left = (w - cw) / 2;

    // What the cover leaves, spread over the gaps in Music's proportions
    // (art → title → scrubber → transport → footer) rather than most of it
    // landing between the scrubber and the transport on a tall phone. Each
    // inner gap stops growing at a ceiling, so a tall window whose cover is
    // capped (a tablet) keeps the controls together and centres the group
    // instead of pulling it apart.
    final slack = math.max(0.0, avail() - art);
    double grow(double share, double cap) => math.min(slack * share, cap);
    final addArtTitle = grow(0.14, 28);
    final addTitleScrub = grow(0.10, 24);
    final addScrubTransport = grow(0.28, 64);
    final rest = slack - addArtTitle - addTitleScrub - addScrubTransport;
    // The rest: some above the cover, the larger part between the transport
    // and the footer, where Music keeps its volume. On a phone that puts the
    // footer on the bottom edge. In a tall pane (a tablet, whose cover is
    // capped) that gap stops growing too, and what is still left is split
    // above and below the whole player, so the footer stays with the
    // controls instead of being stranded at the bottom (§10.12).
    final addTransportFooter = math.min(rest * 0.6, _kTransportFooterMaxGap);
    final excess = math.max(0.0, rest * 0.6 - addTransportFooter);
    final gTop = minTop + rest * 0.4 + excess / 2;
    final gArtTitle = minArtTitle + addArtTitle;
    final gTitleScrub = minTitleScrub + addTitleScrub;
    final gScrubTransport = minScrubTransport + addScrubTransport;

    final bigArtY = gTop;
    final bigTitleY = bigArtY + art + gArtTitle;
    final bigScrubY = bigTitleY + bigTitleH + gTitleScrub;
    final bigTransportY = bigScrubY + scrubH + gScrubTransport;
    final bigFooterY = h - bottomPad - footerH - excess / 2;

    // The notice spans the column, its edges the cover's and the title's
    // (CR-15). It sits under the header and takes its room out of the space
    // above the cover first, then out of the gap under the cover down to
    // its minimum, and only then out of the cover itself — and nothing
    // under the cover ever moves.
    final noticeH = _layout(notice, BoxConstraints.tightFor(width: cw));
    const noticeY = JamSpace.xs;
    final noticeBottom = noticeH > 0 ? noticeY + noticeH : 0.0;
    final shownArtY = math.max(bigArtY, noticeBottom);
    final artFloor = noticeH > 0
        ? bigTitleY - minArtTitle
        : bigTitleY - gArtTitle;
    final shownArt = math.max(0.0, math.min(art, artFloor - shownArtY));
    if (notice != null) _place(notice, Offset(left, noticeY));

    // The queue in place: only the cover and the title move. The scrubber,
    // the transport and the footer stay exactly where they were (Music
    // keeps them fixed), so a toggle never moves a control under a thumb.
    final qThumbY = math.max(JamSpace.sm, noticeBottom);
    final qTitleY = math.max(qThumbY, qThumbY + (_kThumb - titleH) / 2);
    final rowBottom = math.max(qThumbY + _kThumb, qTitleY + titleH);

    final artSize = lerpDouble(shownArt, _kThumb, t)!;
    final artBox = slots[_Slot.art];
    _layout(artBox, BoxConstraints.tight(Size.square(artSize)));
    _place(
      artBox,
      Offset(
        lerpDouble(left + (cw - shownArt) / 2, left, t)!,
        lerpDouble(shownArtY, qThumbY, t)!,
      ),
    );

    _place(
      slots[_Slot.title],
      Offset(
        lerpDouble(left, left + _kThumb + _kThumbGap, t)!,
        lerpDouble(bigTitleY, qTitleY, t)!,
      ),
    );

    final queue = slots[_Slot.queue];
    if (queue != null) {
      // Clear of the now-playing row by more than the rows are from each
      // other, so the song and "Up next" read as two things.
      final top = rowBottom + JamSpace.xl;
      final bottom = bigScrubY - JamSpace.xs;
      _layout(
        queue,
        BoxConstraints.tight(
          Size(math.min(w, cw + margin * 2), math.max(0, bottom - top)),
        ),
      );
      _place(queue, Offset(math.max(0, left - margin), top));
    }

    // The empty room's Add songs: right under "Nothing playing", where the
    // timeline will be (it is hidden until a song lands), on the title's
    // edge — the title and its one action read as one invitation. It never
    // moves anything else: the timeline's and the transport's places stay.
    final add = slots[_Slot.add];
    if (add != null) {
      _layout(add, BoxConstraints(maxWidth: cw));
      _place(add, Offset(left, bigScrubY));
    }

    _place(slots[_Slot.scrubber], Offset(left, bigScrubY));
    _place(slots[_Slot.transport], Offset(left, bigTransportY));
    _place(slots[_Slot.footer], Offset(left, bigFooterY));
  }

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}

/// What [_RenderStage] remembers between frames.
class _StageMemo {
  double? bigTitleH;
}

/// The side-on stage: cover (or the queue) on the left, the title and every
/// control on the right. Landscape phones and short windows.
///
/// Nothing is ever scaled down (RB-5): a smaller player shrank its targets
/// under 44 pt and undid the reader's text size. The transport and the
/// footer are pinned at the bottom, whole, at full size; when the column is
/// taller than the window (a gated guest's reason under the transport, a
/// large text size) the song and its timeline above them scroll instead.
class _SideOnStage extends StatelessWidget {
  const _SideOnStage({
    required this.engine,
    required this.item,
    required this.paused,
    required this.queue,
    required this.margin,
    required this.bottomInset,
    required this.notice,
    required this.title,
    required this.scrubber,
    required this.transport,
    required this.footer,
    required this.selfName,
    required this.onCloseQueue,
  });

  final JamEngine engine;
  final MediaItem? item;
  final bool paused;
  final Animation<double> queue;

  /// The player's side margin, the header's too: the cover's edge and the
  /// chevron's line up.
  final double margin;
  final double bottomInset;
  final Widget notice;
  final Widget title;
  final Widget scrubber;
  final Widget transport;
  final Widget footer;
  final String selfName;
  final VoidCallback onCloseQueue;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final art = math.max(
          0.0,
          math.min(
            constraints.maxHeight - bottomInset - JamSpace.lg,
            constraints.maxWidth * _kSideOnArtShare,
          ),
        );
        return Padding(
          padding: EdgeInsets.fromLTRB(
            margin,
            0,
            margin,
            math.max(JamSpace.sm, bottomInset),
          ),
          child: Row(
            children: [
              SizedBox(
                width: art,
                height: art,
                child: AnimatedBuilder(
                  animation: queue,
                  builder: (context, _) => queue.value == 0
                      ? _Art(
                          engine: engine,
                          item: item,
                          paused: paused,
                          t: 0,
                          onTap: null,
                        )
                      : Opacity(
                          opacity: queue.value,
                          child: QueuePanel(
                            engine: engine,
                            horizontalPadding: 0,
                            bottomPadding: 0,
                            selfName: selfName,
                          ),
                        ),
                ),
              ),
              const SizedBox(width: JamSpace.xxxl),
              Expanded(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Flexible(
                        child: SingleChildScrollView(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              notice,
                              title,
                              const SizedBox(height: JamSpace.md),
                              scrubber,
                            ],
                          ),
                        ),
                      ),
                      // The same rhythm as the vertical stage's minimum
                      // gaps: the times clear of the play square, the square
                      // clear of the faces.
                      const SizedBox(height: JamSpace.lg),
                      transport,
                      const SizedBox(height: JamSpace.md),
                      footer,
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Grabber, then: chevron · room name (and its one problem line) · invite,
/// the glyphs on the player's margin.
class _Header extends StatelessWidget {
  const _Header({
    required this.engine,
    required this.guest,
    required this.session,
    required this.margin,
    required this.showGrabber,
    required this.grabberVisible,
    required this.onClose,
    required this.onInvite,
    required this.onDiagnostics,
  });

  final JamEngine engine;
  final JamGuestEngine? guest;
  final JamSessionController session;

  /// The player's side margin: the buttons' glyphs land on it.
  final double margin;
  final bool showGrabber;
  final bool grabberVisible;
  final VoidCallback onClose;
  final VoidCallback? onInvite;
  final VoidCallback onDiagnostics;

  /// The button row: a 44 target plus a little air.
  static const double _rowHeight = JamMetrics.hitTarget + JamSpace.xs * 2;

  /// A nav glyph's inset inside its 44 target.
  static const double _glyphInset =
      (JamMetrics.hitTarget - JamMetrics.navIcon) / 2;

  @override
  Widget build(BuildContext context) {
    final invite = onInvite;
    final scaler = MediaQuery.textScalerOf(context);
    // The name holds one baseline whether or not a status line is showing:
    // centred on the buttons, with the status line's slot reserved under it
    // (empty when all is well), so a line coming or going moves nothing.
    // Measured as laid out, not `scale(lineHeight)`, which under Android's
    // nonlinear scaler is not the line box (RB-10).
    final nameHeight = _lineHeight(context.jamHeadline, scaler);
    final statusHeight = _lineHeight(context.jamFootnote, scaler);
    final nameTop = math.max(0.0, (_rowHeight - nameHeight) / 2);
    final height = math.max(_rowHeight, nameTop + nameHeight + statusHeight);
    final reduced = jamReducedMotion(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showGrabber)
          Padding(
            padding: const EdgeInsets.only(top: JamSpace.xs),
            child: Center(
              child: ExcludeSemantics(
                child: AnimatedOpacity(
                  opacity: grabberVisible ? 1 : 0,
                  duration: reduced ? Duration.zero : JamDuration.fast,
                  child: Container(
                    width: JamMetrics.grabber.width,
                    height: JamMetrics.grabber.height,
                    decoration: const ShapeDecoration(
                      color: JamNowPlayingColors.tertiary,
                      shape: StadiumBorder(),
                    ),
                  ),
                ),
              ),
            ),
          )
        else
          const SizedBox(height: JamSpace.sm),
        Padding(
          // The glyphs' edges land on the player's margin, the cover's.
          padding: EdgeInsets.symmetric(
            horizontal: math.max(0, margin - _glyphInset),
          ),
          // A floor, not a fixed height: the name's real line box decides
          // the rest, so no text size can make it overflow.
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: height),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  height: _rowHeight,
                  child: Center(
                    child: JamIconButton(
                      icon: CupertinoIcons.chevron_down,
                      semanticLabel: JamRoomStrings.close,
                      color: JamNowPlayingColors.text,
                      onPressed: onClose,
                    ),
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(top: nameTop),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          engine.sessionName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: context.jamHeadline.copyWith(
                            color: JamNowPlayingColors.text,
                          ),
                        ),
                        SizedBox(
                          height: statusHeight,
                          child: _StatusLine(
                            engine: engine,
                            guest: guest,
                            session: session,
                            onShowDetails: onDiagnostics,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                SizedBox(
                  height: _rowHeight,
                  child: Center(
                    child: invite != null
                        ? JamIconButton(
                            icon: CupertinoIcons.person_badge_plus,
                            semanticLabel: JamRoomStrings.invite,
                            color: JamNowPlayingColors.text,
                            onPressed: invite,
                          )
                        // Keeps the room's name centred on the window.
                        : const SizedBox.square(
                            dimension: JamMetrics.hitTarget,
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// The one footnote under the room's name: sync's problem first, then the
/// room's other news in order of how much it explains — a song this phone
/// is still getting, a start held for someone's download, songs still
/// coming in. Nothing at all when everything is fine.
class _StatusLine extends StatelessWidget {
  const _StatusLine({
    required this.engine,
    required this.guest,
    required this.session,
    required this.onShowDetails,
  });

  final JamEngine engine;
  final JamGuestEngine? guest;
  final JamSessionController session;
  final VoidCallback onShowDetails;

  @override
  Widget build(BuildContext context) {
    Widget line(JamStatusLine? fallback) => SyncIndicator(
      engine: engine,
      connection: session.connection,
      clockSynced: guest?.clockSynced ?? true,
      hostAway: session.hostAway,
      fallback: fallback,
      onShowDetails: onShowDetails,
    );

    final fetcher = guest;
    final mediaId = engine.snapshot.mediaId;
    if (fetcher != null) {
      if (mediaId == null) return line(null);
      return ValueListenableBuilder<Map<String, JamPrefetchState>>(
        valueListenable: fetcher.prefetchStates,
        builder: (context, states, _) {
          final state = states[mediaId];
          if (jamTrackFetchOf(state) != JamTrackFetch.fetching) {
            return line(null);
          }
          final percent = (state!.progress.clamp(0.0, 1.0) * 100).round();
          return line(
            JamStatusLine(
              JamRoomStrings.fetching(percent),
              progress: state.progress,
            ),
          );
        },
      );
    }

    final host = engine is JamHostEngine ? engine as JamHostEngine : null;
    final import = session.hostImport;
    Widget withImport(JamStatusLine? readiness) {
      if (readiness != null || import == null) return line(readiness);
      return ValueListenableBuilder<JamImportProgress>(
        valueListenable: import.progress,
        builder: (context, progress, _) {
          // One file is in or not; a count only means something for several.
          if (progress.isDone || progress.total < 2) return line(null);
          return line(
            JamStatusLine(
              JamRoomStrings.importingCount(progress.completed, progress.total),
            ),
          );
        },
      );
    }

    if (host == null || mediaId == null) return withImport(null);
    final waiting = host
        .peerMediaStates(mediaId)
        .values
        .where((s) => s != MediaReadiness.ready)
        .length;
    // PROTOCOL.md §6.3: do not start a track people do not have yet. The
    // gate says why a play has not started; the count says who the room is
    // waiting on otherwise. Listened to, not read: a hold a guest's play
    // request began comes with no broadcast to rebuild this screen.
    return ValueListenableBuilder<bool>(
      valueListenable: host.awaitingReadiness,
      builder: (context, awaiting, _) => withImport(
        awaiting
            ? const JamStatusLine(JamRoomStrings.awaitingReadiness)
            : waiting > 0
            ? JamStatusLine(JamRoomStrings.waiting(waiting))
            : null,
      ),
    );
  }
}

/// The engine notice above the cover, for a state that wants something
/// done: this phone's sound suspended ("Resume audio"), or a song it could
/// not get ("Try again"). Nothing (and no height) otherwise; the stage takes
/// its room out of the cover alone, so no control moves when it comes.
class _EngineNotice extends StatelessWidget {
  const _EngineNotice({
    required this.engine,
    required this.guest,
    required this.session,
  });

  final JamEngine engine;
  final JamGuestEngine? guest;
  final JamSessionController session;

  @override
  Widget build(BuildContext context) {
    final reduced = jamReducedMotion(context);
    Widget wrap(Widget? notice) => AnimatedSize(
      duration: reduced ? Duration.zero : JamDuration.base,
      curve: JamCurve.standard,
      alignment: Alignment.topCenter,
      child: notice == null
          ? const SizedBox(width: double.infinity)
          : Padding(
              padding: const EdgeInsets.only(bottom: JamSpace.md),
              child: Center(child: notice),
            ),
    );

    return ValueListenableBuilder<JamOutputSuspension?>(
      valueListenable: engine.outputSuspension,
      builder: (context, suspension, _) {
        if (suspension != null) return wrap(JamOutputBanner(engine: engine));
        final fetcher = guest;
        final mediaId = engine.snapshot.mediaId;
        if (fetcher == null || mediaId == null) return wrap(null);
        return ValueListenableBuilder<Map<String, JamPrefetchState>>(
          valueListenable: fetcher.prefetchStates,
          builder: (context, states, _) {
            if (jamTrackFetchOf(states[mediaId]) != JamTrackFetch.failed) {
              return wrap(null);
            }
            return wrap(
              JamRoomBanner(
                icon: CupertinoIcons.exclamationmark_circle,
                message: JamRoomStrings.fetchFailed,
                actionLabel: JamRoomStrings.retry,
                actionSemanticLabel: JamRoomStrings.retryFetch,
                onAction: () {
                  // False when there is nothing left to retry (it landed, or
                  // is already being fetched again); a tap that did nothing
                  // visible deserves a word.
                  if (!fetcher.retryFetch(mediaId)) {
                    session.notify(
                      kJamIntentFailed,
                      tone: JamNoticeTone.warning,
                    );
                  }
                },
              ),
            );
          },
        );
      },
    );
  }
}

/// The cover: square, the large-cover radius, the one shadow; springs to
/// 0.96 while the room is paused (§6.3), and shrinks into the 56 thumbnail
/// as [t] runs.
class _Art extends StatefulWidget {
  const _Art({
    required this.engine,
    required this.item,
    required this.paused,
    required this.t,
    required this.onTap,
    this.markAlignment = Alignment.center,
  });

  final JamEngine engine;
  final MediaItem? item;
  final bool paused;
  final double t;

  /// Where the empty room's mark sits in the square the first cover will
  /// fill.
  final AlignmentGeometry markAlignment;

  /// Restores the big cover from the thumbnail.
  final VoidCallback? onTap;

  @override
  State<_Art> createState() => _ArtState();
}

class _ArtState extends State<_Art> {
  String? _artworkId;
  Future<Uint8List?>? _bytes;

  /// The same future across frames, so a resize animation never drops the
  /// cover back to the placeholder while it waits on the cache.
  Future<Uint8List?>? _futureFor(MediaItem? item) {
    final id = item?.artworkId;
    if (id != _artworkId) {
      _artworkId = id;
      _bytes = id == null ? null : widget.engine.artworkFor(item!);
    }
    return _bytes;
  }

  @override
  Widget build(BuildContext context) {
    final reduced = jamReducedMotion(context);
    final t = widget.t;
    final empty = widget.item == null;
    final future = _futureFor(widget.item);
    // An empty room's mark is the backdrop's own material, not an object
    // lifted off it: no shadow under a see-through ground.
    final shadow = BoxShadow.lerpList(
      JamShadow.artwork,
      const <BoxShadow>[],
      t,
    );
    final radius = lerpDouble(JamRadius.largeCover, JamRadius.artworkS, t)!;

    // Nothing playing: not a song without art (a music note), and not a
    // cover-sized tile that reads as one missing, but the jam itself — its
    // mark at the size a page draws a jam, on the same see-through ground
    // as a song with no cover, in the open space the first cover will fill
    // (IR-1). As the queue opens it grows to fill the thumbnail, where it
    // is the jam's 56 mark.
    Widget mark(double slot) {
      final size = math.min(
        lerpDouble(slot / 2, slot, t)!,
        lerpDouble(_kEmptyMark, _kThumb, t)!,
      );
      final radius = lerpDouble(
        JamRadius.artwork(_kEmptyMark),
        JamRadius.artwork(_kThumb),
        t,
      )!;
      return JamArtworkHero(
        child: DecoratedBox(
          position: DecorationPosition.foreground,
          // The hairline every cover on the backdrop has (RB-23), on the
          // mark's own outline.
          decoration: ShapeDecoration(
            shape: jamMarkShape(size, radius: radius, side: _kCoverEdge),
          ),
          child: JamMark(
            name: widget.engine.sessionName,
            size: size,
            radius: radius,
            onBackdrop: true,
          ),
        ),
      );
    }

    // The mini player's cover grows into this one (and back).
    Widget tile(double size, Uint8List? bytes) => empty
        ? mark(size)
        : JamArtworkHero(
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(radius),
                boxShadow: shadow,
              ),
              // A hairline on the cover's edge, so a dark sleeve on its own
              // dark wash still has one (RB-23).
              child: DecoratedBox(
                position: DecorationPosition.foreground,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(radius),
                  border: Border.fromBorderSide(_kCoverEdge),
                ),
                child: JamArtworkTile(
                  bytes: bytes,
                  imageKey: _artworkId,
                  size: size,
                  radius: radius,
                  onBackdrop: true,
                ),
              ),
            ),
          );

    final art = LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest.shortestSide;
        final body = future == null
            ? tile(size, null)
            : FutureBuilder<Uint8List?>(
                future: future,
                builder: (context, snapshot) => tile(size, snapshot.data),
              );
        // Paused, the cover settles back a little (§6.3) — a song, not an
        // empty room, whose tile has nothing to pause. Under reduced motion
        // it dims instead of moving (RB-18).
        final rest = widget.paused && !empty;
        final placed = Align(
          alignment: empty ? widget.markAlignment : Alignment.center,
          child: body,
        );
        if (reduced) {
          return AnimatedOpacity(
            opacity: rest ? _kPausedDim : 1,
            duration: JamDuration.fast,
            child: placed,
          );
        }
        return TweenAnimationBuilder<double>(
          tween: Tween<double>(end: rest ? _kPausedScale : 1),
          duration: JamDuration.spring,
          curve: JamCurve.spring,
          builder: (context, scale, child) =>
              Transform.scale(scale: lerpDouble(scale, 1, t)!, child: child),
          child: placed,
        );
      },
    );

    final onTap = widget.onTap;
    if (onTap == null) return art;
    return Semantics(
      button: true,
      label: JamRoomStrings.queue,
      selected: true,
      onTap: onTap,
      child: JamPressable(onTap: onTap, child: art),
    );
  }
}

/// Who added the song that is playing, when it was someone else (D6): their
/// name, and their face's colour when they shared a name.
typedef _Credit = ({String name, Color? color});

/// The gap between the artist and the credit line under it.
const double _kCreditGap = JamSpace.xs + JamSpace.xxs;

/// The song's title (Manrope, white) over its artist (white 70%), and — when
/// someone else put it on — one quiet "Added by Mia" with their face; the
/// glass ••• on the right. The title scales down toward 17 beside the
/// thumbnail as the queue opens, in the same face all the way (SY-8: a lerp
/// across families snaps halfway).
///
/// The title is one line that scrolls when it is longer than the page (R1),
/// so the transport never moves for a long name; in the accessibility
/// layout it wraps instead, as far as it needs.
///
/// An empty room says "Nothing playing" here and nothing else; its Add songs
/// sits right under it upright, and where the play square will be side-on
/// and in the accessibility layout (IR-1, [_EmptyRoomAdd]).
class _TitleBlock extends StatelessWidget {
  const _TitleBlock({
    required this.engine,
    required this.item,
    required this.importing,
    required this.canAdd,
    required this.menu,
    required this.queue,
    required this.credit,
    required this.reserveCredit,
    this.accessible = false,
  });

  final JamEngine engine;
  final MediaItem? item;

  /// The host's starting files are still being added. An empty room in that
  /// moment is not "Nothing playing" — the music is on its way.
  final bool importing;

  /// Whether this device may add songs (`addTracks`): if not, an empty room
  /// says who will.
  final bool canAdd;

  final Widget menu;
  final Animation<double> queue;

  /// Someone else's song: who added it. Null for your own (or theirs, once
  /// they left).
  final _Credit? credit;

  /// Keep the credit's line even when there is none to show (someone else's
  /// song is queued), so their song starting never moves the controls under
  /// the title.
  final bool reserveCredit;

  /// The accessibility layout's title: wrapped, not scrolled.
  final bool accessible;

  /// The title and artist styles at rest: a step up on tablets and desktops,
  /// whose poster-sized cover wants a title that is not a caption under it
  /// (§10.12) — not on a phone turned sideways, whose window is wide but
  /// whose cover is not.
  static ({TextStyle title, TextStyle artist}) stylesOf(BuildContext context) {
    final wideType = MediaQuery.sizeOf(context).shortestSide >= 600;
    return (
      title: wideType ? context.jamLargeTitle : context.jamTitle1,
      artist: wideType
          ? context.jamBody.copyWith(fontSize: 20, height: 25 / 20)
          : context.jamBody,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final styles = stylesOf(context);
    final bigTitle = styles.title;
    final smallTitle = bigTitle.copyWith(
      fontSize: 17,
      height: 22 / 17,
      letterSpacing: -0.3,
      fontWeight: FontWeight.w700,
    );

    return AnimatedBuilder(
      animation: queue,
      builder: (context, _) {
        final t = JamCurve.standard.transform(queue.value);
        final titleStyle = TextStyle.lerp(
          bigTitle,
          smallTitle,
          t,
        )!.copyWith(color: JamNowPlayingColors.text);
        final subtitleStyle = TextStyle.lerp(
          styles.artist,
          context.jamSubheadline,
          t,
        )!.copyWith(color: JamNowPlayingColors.secondary);
        final lines = accessible ? null : 1;
        final overflow = accessible ? null : TextOverflow.ellipsis;

        final current = item;
        final String title;
        Widget? subtitle;
        Widget? creditLine;
        if (current == null) {
          title = importing
              ? JamRoomStrings.importing
              : JamRoomStrings.nothingPlaying;
          // Someone who cannot add songs is told who will; anyone who can
          // has Add Songs where play will be.
          if (!importing && !canAdd) {
            subtitle = Padding(
              padding: const EdgeInsets.only(top: JamSpace.xs),
              child: Text(
                JamRoomStrings.nothingQueuedBody,
                maxLines: lines,
                overflow: overflow,
                style: subtitleStyle,
              ),
            );
          }
        } else {
          title = jamDisplayTitle(current);
          // Artist is the song's identity.
          final artist = current.artist?.trim();
          final byline = artist != null && artist.isNotEmpty
              ? artist
              : artworkByline(current);
          // Its line is kept even for a song without one (RB-16): a
          // recording called "AUD-20261019-WA0003" must not move the
          // transport 7 pt from where the last song had it.
          subtitle = Padding(
            padding: const EdgeInsets.only(top: JamSpace.xs),
            child: byline == null
                ? ExcludeSemantics(child: Text(' ', style: subtitleStyle))
                : Text(
                    byline,
                    maxLines: lines,
                    overflow: overflow,
                    style: subtitleStyle,
                  ),
          );
          if (credit != null || reserveCredit) {
            creditLine = _creditLine(context, scaler, t);
          }
        }

        final titleLine = _lineHeight(titleStyle, scaler);
        return Row(
          crossAxisAlignment: accessible
              ? CrossAxisAlignment.start
              : CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Semantics(
                container: true,
                header: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (accessible)
                      Text(title, style: titleStyle)
                    else
                      JamMarquee(title, style: titleStyle),
                    ?subtitle,
                    ?creditLine,
                  ],
                ),
              ),
            ),
            const SizedBox(width: JamSpace.sm),
            // The menu's 30 circle sits at the end of its 44 target
            // (`triggerAlignment`), so the circle's edge lines up with the
            // cover's. Over a wrapped title it stays on the first line.
            if (accessible)
              Transform.translate(
                offset: Offset(0, (titleLine - JamMetrics.hitTarget) / 2),
                child: menu,
              )
            else
              menu,
          ],
        );
      },
    );
  }

  /// "Added by Mia" with Mia's 18 pt face, a footnote under the artist. It
  /// fades through when the next song is someone else's, and folds away as
  /// the queue opens — the rows below carry every song's credit.
  Widget _creditLine(BuildContext context, TextScaler scaler, double t) {
    final credit = this.credit;
    final reduced = jamReducedMotion(context);
    final style = context.jamFootnote.copyWith(
      color: JamNowPlayingColors.secondary,
    );
    // Grows with the words beside it, to a point (RB-17).
    final face = JamAvatarSize.scaled(context, JamAvatarSize.credit);
    final line = credit == null
        ? const SizedBox.shrink(key: ValueKey<String>('none'))
        : Row(
            key: ValueKey<String>(credit.name),
            mainAxisSize: MainAxisSize.min,
            children: [
              if (credit.color != null) ...[
                ExcludeSemantics(
                  child: JamAvatar(
                    name: credit.name,
                    color: credit.color,
                    size: face,
                    tokenSize: JamAvatarSize.credit,
                  ),
                ),
                const SizedBox(width: JamSpace.xs + JamSpace.xxs),
              ],
              Flexible(
                child: Text(
                  JamRoomStrings.addedBy(credit.name),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: style,
                ),
              ),
            ],
          );
    return ClipRect(
      child: Align(
        alignment: AlignmentDirectional.topStart,
        heightFactor: 1 - t,
        child: Opacity(
          opacity: 1 - t,
          child: Padding(
            padding: const EdgeInsets.only(top: _kCreditGap),
            child: SizedBox(
              // The line's real box, not `scale(18)`: under Android's
              // nonlinear scaler the two differ and the descenders were cut
              // (RB-10).
              height: math.max(face, _lineHeight(style, scaler)),
              child: AnimatedSwitcher(
                duration: reduced ? Duration.zero : JamDuration.fast,
                switchInCurve: jamFadeThroughCurve,
                switchOutCurve: jamFadeThroughCurve,
                layoutBuilder: (current, previous) => Stack(
                  alignment: AlignmentDirectional.centerStart,
                  children: [...previous, ?current],
                ),
                child: line,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The empty room's Add Songs: a large ivory button standing where the play
/// square will (IR-1) — the backdrop's "press this", on the app's
/// soft-rectangle button shape, so the ivory object on the page always means
/// the room's next step.
class _AddSongsButton extends StatelessWidget {
  const _AddSongsButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.jamColors.copyWith(
      tintFilled: JamNowPlayingColors.playSurface,
      onTint: JamNowPlayingColors.playGlyph,
    );
    return Theme(
      data: theme.copyWith(
        extensions: [
          for (final extension in theme.extensions.values)
            if (extension is! JamColors) extension,
          colors,
        ],
      ),
      child: JamButton.filled(
        label: JamRoomStrings.addSongs,
        icon: CupertinoIcons.plus,
        onPressed: onPressed,
      ),
    );
  }
}

/// The timeline, fed by the session's position ticker.
class _Scrubber extends StatelessWidget {
  const _Scrubber({
    required this.engine,
    required this.session,
    required this.enabled,
  });

  final JamEngine engine;
  final JamSessionController session;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final item = engine.currentItem;
    // Nothing playing: no "0:00 … --:--" timeline to a song that is not
    // there. The slot keeps its height so the controls do not move when the
    // first song lands.
    return Visibility(
      visible: item != null,
      maintainSize: true,
      maintainAnimation: true,
      maintainState: true,
      child: _timeline(item),
    );
  }

  Widget _timeline(MediaItem? item) {
    final ticker = session.position;
    void seek(int us) => unawaited(session.act((e) => e.transportSeek(us)));
    // The length follows the loaded file as well as the clock: a track whose
    // file lands while the room is paused (a Retry) has a position that does
    // not move, and the old track's length used to stay on screen until
    // something else redrew it.
    return ValueListenableBuilder<int?>(
      valueListenable: engine.loadedDurationUs,
      builder: (context, loadedUs, _) {
        final duration = item == null ? null : (loadedUs ?? item.durationUs);
        if (ticker == null) {
          return JamScrubber(
            positionUs: 0,
            durationUs: duration,
            enabled: false,
          );
        }
        return ValueListenableBuilder<int?>(
          valueListenable: ticker,
          builder: (context, positionUs, _) => JamScrubber(
            positionUs: item == null ? 0 : (positionUs ?? 0),
            durationUs: duration,
            enabled: enabled,
            onSeek: enabled ? seek : null,
          ),
        );
      },
    );
  }
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
/// gave up on turns into "Couldn't get this song · Try Again".
JamTrackFetch jamTrackFetchOf(JamPrefetchState? state) {
  if (state == null || state.ready) return JamTrackFetch.ready;
  if (state.phase == JamPrefetchPhase.failed && !state.willRetry) {
    return JamTrackFetch.failed;
  }
  return JamTrackFetch.fetching;
}

/// The transport, gated the way the room says.
///
/// Anyone the room lets skip keeps the full transport whatever a fetch is
/// doing: a track that will not come down is exactly when someone wants
/// "next".
///
/// An empty room has nothing to play: the transport steps back, keeping its
/// place, and — side-on and in the accessibility layout, given [onAdd] —
/// Add songs stands in the play square's place, centred on its line (IR-1).
/// When the first song lands, Add songs fades out and the transport fades
/// in, and nothing on the page moves.
class _TransportArea extends StatelessWidget {
  const _TransportArea({
    required this.engine,
    required this.session,
    required this.canControl,
    required this.hasQueue,
    required this.gatedMessage,
    required this.onAdd,
    required this.queue,
  });

  final JamEngine engine;
  final JamSessionController session;
  final bool canControl;
  final bool hasQueue;

  /// The line under a transport you cannot use ([gatedMessageFor]).
  final String? gatedMessage;

  /// Offered in the transport's place while the room is empty.
  final VoidCallback? onAdd;

  /// The queue in place, on phones: once it is open its list has its own Add
  /// Songs row, and this one steps aside.
  final Animation<double>? queue;

  /// The bar is dimmed for different reasons and each needs its own
  /// sentence: a host with an empty room is not being told that somebody
  /// else is in charge, and a guest whose host is asleep is not being told
  /// the rules changed. An empty room says so once, in the title block and
  /// its Add Songs — not again under a dimmed transport.
  static String? gatedMessageFor({
    required JamSessionController session,
    required bool canControl,
  }) => !canControl
      ? jamHostControlsPlayback
      : !session.canSendCommands
      ? (session.hostAway
            ? JamRoomStrings.waitForHost
            : JamRoomStrings.waitForReconnect)
      : null;

  @override
  Widget build(BuildContext context) {
    final canSend = session.canSendCommands;
    final roomPlaying = engine.snapshot.status == PlaybackStatus.playing;
    final reduced = jamReducedMotion(context);
    // While this phone's own sound is suspended (a call, another app,
    // headphones out) the room plays on without it, and the big button is
    // "Resume audio" — for everyone, since it touches only this phone. As
    // "Pause" it stopped the whole room for someone who only wanted their
    // own sound back. Mirrors the mini player.
    final suspended = engine.outputSuspension.value != null;
    final playing = roomPlaying && !suspended;
    final controls = canControl && canSend && hasQueue;
    final shown = hasQueue || suspended;

    final transport = JamTransport(
      state: playing ? JamPlaybackState.playing : JamPlaybackState.paused,
      enabled: suspended || controls,
      playLabel: suspended ? JamRoomBannerStrings.resume : null,
      gatedMessage: gatedMessage,
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

    // Its place kept while hidden, so nothing moves when the first song
    // lands; it fades in when it does.
    final bar = AnimatedOpacity(
      opacity: shown ? 1 : 0,
      duration: reduced ? Duration.zero : JamDuration.fast,
      curve: JamCurve.standard,
      child: Visibility(
        visible: shown,
        maintainSize: true,
        maintainAnimation: true,
        maintainState: true,
        child: transport,
      ),
    );
    final add = onAdd;
    if (add == null) return bar;
    return Stack(
      children: [
        bar,
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          height: JamMetrics.playSquare,
          child: Center(
            child: _EmptyRoomAdd(offered: !shown, onAdd: add, queue: queue),
          ),
        ),
      ],
    );
  }
}

/// The empty room's Add songs, fading in and out where the stage puts it:
/// [offered] while the room has nothing to play, and stepping aside once
/// [queue] opens the list, which has its own Add songs row.
class _EmptyRoomAdd extends StatelessWidget {
  const _EmptyRoomAdd({
    required this.offered,
    required this.onAdd,
    required this.queue,
  });

  final bool offered;
  final VoidCallback onAdd;

  /// The queue in place, on phones.
  final Animation<double>? queue;

  @override
  Widget build(BuildContext context) {
    final reduced = jamReducedMotion(context);
    Widget slot(bool listOpen) => AnimatedSwitcher(
      duration: reduced ? Duration.zero : JamDuration.fast,
      switchInCurve: JamCurve.standard,
      switchOutCurve: JamCurve.standard,
      layoutBuilder: (current, previous) => Stack(
        alignment: AlignmentDirectional.topStart,
        children: [...previous, ?current],
      ),
      child: offered && !listOpen
          ? _AddSongsButton(onPressed: onAdd)
          : const SizedBox.shrink(),
    );
    final animation = queue;
    if (animation == null) return slot(false);
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) => slot(animation.value > 0.5),
    );
  }
}

/// The footer: who you are listening with → People, and Up Next → the queue
/// in place. Apple Music's footer, LocalJam's way: the people are named, not
/// just counted.
class _Footer extends StatelessWidget {
  const _Footer({
    required this.roster,
    required this.colors,
    required this.peopleSelected,
    required this.queue,
    required this.onPeople,
    required this.onQueue,
  });

  /// Everyone in the jam by name, this device first ([jamRosterNames]).
  final List<String> roster;

  /// Their faces' colours, parallel to [roster].
  final List<Color> colors;

  /// Wide windows: the docked panel is showing People.
  final bool peopleSelected;

  /// The queue-in-place animation, on phones. Null on wide windows, where
  /// the docked panel's own switch picks Up Next and the footer does not
  /// repeat it.
  final Animation<double>? queue;

  final VoidCallback onPeople;
  final VoidCallback onQueue;

  @override
  Widget build(BuildContext context) {
    final count = roster.length;
    // Up to three of the *others* — you know you are here — and your own
    // face only when you are alone.
    final faces = count <= 1
        ? (roster, colors)
        : (roster.skip(1).take(3).toList(), colors.skip(1).take(3).toList());
    final style = context.jamFootnote.copyWith(
      color: JamNowPlayingColors.secondary,
    );
    final animation = queue;

    // A floor, not a fixed height: at the largest text sizes the label's
    // line is taller than 44 and must not be clipped (RB-1).
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: JamMetrics.hitTarget),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final pileWidth =
              (faces.$1.length - 1) *
                  JamAvatarSize.strip *
                  (1 - JamAvatarStack.overlap) +
              JamAvatarSize.strip;
          final room =
              constraints.maxWidth -
              pileWidth -
              JamSpace.sm -
              JamSpace.xs -
              JamIconSize.disclosure -
              (animation == null ? 0 : JamMetrics.hitTarget + JamSpace.sm);
          // One phrase for the people, the one every screen uses (R9),
          // with the names cut before the count ever is.
          final fit = JamPeopleFit.of(
            JamPeoplePhrase.summary(roster.skip(1).toList()),
            style: style,
            maxWidth: math.max(0, room),
            textScaler: MediaQuery.textScalerOf(context),
            textDirection: Directionality.of(context),
          );

          final people = Semantics(
            container: true,
            button: true,
            selected: peopleSelected,
            // What it shows is what it is called (RB-9): "With Mia and
            // Theo" can be said to Voice Control as it reads.
            label: fit.spoken,
            hint: JamRoomStrings.peopleHint,
            onTap: onPeople,
            excludeSemantics: true,
            child: JamPressable(
              onTap: onPeople,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  minHeight: JamMetrics.hitTarget,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _FacePile(
                      key: kJamRoomFacesKey,
                      names: faces.$1,
                      colors: faces.$2,
                      people: count,
                    ),
                    const SizedBox(width: JamSpace.sm),
                    Flexible(
                      child: _FadeThrough(
                        id: fit.spoken,
                        child: JamPeopleLine.fitted(fit, style: style),
                      ),
                    ),
                    const SizedBox(width: JamSpace.xs),
                    const JamDisclosureChevron(
                      color: JamNowPlayingColors.secondary,
                    ),
                  ],
                ),
              ),
            ),
          );

          return Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(child: people),
              if (animation != null) ...[
                AnimatedBuilder(
                  animation: animation,
                  builder: (context, _) => _FooterIcon(
                    icon: CupertinoIcons.list_bullet,
                    semanticLabel: JamRoomStrings.queue,
                    selected: animation.value >= 0.5,
                    onPressed: onQueue,
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

/// A line that fades through when it changes, so a new name in the footer
/// reads as the room changing, not a glitch.
class _FadeThrough extends StatelessWidget {
  const _FadeThrough({required this.id, required this.child});

  /// What the line says: a new one fades through.
  final String id;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final reduced = jamReducedMotion(context);
    return AnimatedSwitcher(
      duration: reduced ? Duration.zero : JamDuration.fast,
      switchInCurve: jamFadeThroughCurve,
      switchOutCurve: jamFadeThroughCurve,
      layoutBuilder: (current, previous) => Stack(
        alignment: AlignmentDirectional.centerStart,
        children: [...previous, ?current],
      ),
      child: KeyedSubtree(key: ValueKey<String>(id), child: child),
    );
  }
}

/// The footer's faces: [JamAvatarStack]'s pile — 25% overlap, each face
/// knocked out of the one it covers — that shows a person arriving. When
/// one name joins, the pile widens, the faces make room, and the new face
/// grows in (0.6 → 1, fading up) on the spring a beat later. Several at once
/// (a reconnect replaying the roster), a renamed face and reduced motion
/// just appear.
class _FacePile extends StatefulWidget {
  const _FacePile({
    super.key,
    required this.names,
    required this.colors,
    required this.people,
  });

  final List<String> names;
  final List<Color> colors;

  /// Everyone in the room: an arrival is this growing by one, so a name
  /// that only changed (yours, once it loads) never plays as one.
  final int people;

  static const double size = JamAvatarSize.strip;

  @override
  State<_FacePile> createState() => _FacePileState();
}

class _FacePileState extends State<_FacePile>
    with SingleTickerProviderStateMixin {
  late final AnimationController _arrival = AnimationController(
    vsync: this,
    duration: _kArrivalDelay + JamDuration.slow,
    value: 1,
  );

  /// The face growing in, while it does.
  String? _arriving;

  @override
  void didUpdateWidget(_FacePile oldWidget) {
    super.didUpdateWidget(oldWidget);
    final reduced = jamReducedMotion(context);
    final joined = [
      for (final name in widget.names)
        if (!oldWidget.names.contains(name)) name,
    ];
    final arrival = widget.people == oldWidget.people + 1 && joined.length == 1;
    if (!arrival || reduced) return;
    _arriving = joined.single;
    unawaited(
      _arrival.forward(from: 0).whenComplete(() {
        if (mounted) setState(() => _arriving = null);
      }),
    );
  }

  @override
  void dispose() {
    _arrival.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const size = _FacePile.size;
    const step = size * (1 - JamAvatarStack.overlap);
    final names = widget.names;
    final reduced = jamReducedMotion(context);
    final move = reduced ? Duration.zero : JamDuration.base;
    final width = names.isEmpty ? 0.0 : (names.length - 1) * step + size;
    final grow = CurvedAnimation(
      parent: _arrival,
      curve: Interval(
        _kArrivalDelay.inMilliseconds / _arrival.duration!.inMilliseconds,
        1,
        curve: JamCurve.spring,
      ),
    );

    Widget face(int i) {
      final name = names[i];
      final color = i < widget.colors.length
          ? widget.colors[i]
          : identityColor(name);
      final last = i == names.length - 1;
      Widget face = JamAvatar.inPile(
        name: name,
        size: size,
        color: color,
        // A covered face's letter moves into the part still showing.
        initialsShift: last ? 0 : (step - JamAvatarStack.cutout) / 2 - size / 2,
      );
      if (!last) {
        face = ClipPath(
          clipper: const JamAvatarKnockout(offset: step),
          child: face,
        );
      }
      if (name == _arriving) {
        face = FadeTransition(
          opacity: grow,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.6, end: 1).animate(grow),
            child: face,
          ),
        );
      }
      return AnimatedPositioned(
        key: ValueKey<String>('$i:$name'),
        duration: move,
        curve: JamCurve.standard,
        left: i * step,
        top: 0,
        width: size,
        height: size,
        child: face,
      );
    }

    return Semantics(
      label: names.join(', '),
      image: true,
      child: ExcludeSemantics(
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(end: width),
          duration: move,
          curve: JamCurve.standard,
          builder: (context, w, child) =>
              SizedBox(width: w, height: size, child: child),
          child: Stack(
            clipBehavior: Clip.none,
            children: [for (var i = 0; i < names.length; i++) face(i)],
          ),
        ),
      ),
    );
  }
}

/// How long a new face waits before it grows in: the pile makes room first.
const Duration _kArrivalDelay = Duration(milliseconds: 80);

/// A bare footer glyph (white 70%), or — selected — white on a glass plate,
/// on the backdrop's soft-rectangle shape (CR-14): ivory belongs to the play
/// square alone. The plate's trailing edge lands on the column's.
class _FooterIcon extends StatelessWidget {
  const _FooterIcon({
    required this.icon,
    required this.semanticLabel,
    required this.onPressed,
    this.selected = false,
  });

  final IconData icon;
  final String semanticLabel;
  final VoidCallback onPressed;
  final bool selected;

  /// The selected plate.
  static const double _plate = 34;

  /// The plate's inset inside its 44 box: how far the box overhangs the
  /// column so the plate does not.
  static const double _overhang = (JamMetrics.hitTarget - _plate) / 2;

  @override
  Widget build(BuildContext context) {
    final reduced = jamReducedMotion(context);
    final rtl = Directionality.of(context) == TextDirection.rtl;
    return Transform.translate(
      offset: Offset(rtl ? -_overhang : _overhang, 0),
      child: Semantics(
        container: true,
        button: true,
        selected: selected,
        label: semanticLabel,
        onTap: onPressed,
        excludeSemantics: true,
        child: JamPressable(
          onTap: onPressed,
          child: SizedBox.square(
            dimension: JamMetrics.hitTarget,
            child: Center(
              child: AnimatedContainer(
                duration: reduced ? Duration.zero : JamDuration.fast,
                curve: JamCurve.standard,
                width: _plate,
                height: _plate,
                decoration: ShapeDecoration(
                  color: selected
                      ? JamNowPlayingColors.glass
                      : JamNowPlayingColors.clear,
                  shape: const RoundedRectangleBorder(
                    borderRadius: BorderRadius.all(
                      Radius.circular(JamRadius.md),
                    ),
                  ),
                ),
                child: Icon(
                  icon,
                  size: JamIconSize.row,
                  color: selected
                      ? JamNowPlayingColors.text
                      : JamNowPlayingColors.secondary,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Up Next and People, docked beside the player on wide windows (D7). The
/// same [QueuePanel] a phone opens in place and the same [RoomPanel] its
/// People sheet holds — on the backdrop, under the room's dark theme.
class _DockedPanel extends StatelessWidget {
  const _DockedPanel({
    required this.engine,
    required this.view,
    required this.selfName,
    required this.network,
    required this.onView,
  });

  final JamEngine engine;
  final _PanelView view;
  final String selfName;
  final JamNetworkStatus network;
  final ValueChanged<_PanelView> onView;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: JamContentWidth.panel,
      child: ColoredBox(
        // A shade of the backdrop, not a card: just enough to set the
        // panel apart from the player.
        color: JamNowPlayingColors.panelShade,
        child: SafeArea(
          left: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  JamSpace.lg,
                  JamSpace.lg,
                  JamSpace.lg,
                  JamSpace.md,
                ),
                child: JamSegmentedControl<_PanelView>(
                  segments: const {
                    _PanelView.queue: JamRoomStrings.panelQueue,
                    _PanelView.people: JamRoomStrings.panelRoom,
                  },
                  groupValue: view,
                  onValueChanged: onView,
                  onBackdrop: true,
                ),
              ),
              Expanded(
                child: switch (view) {
                  _PanelView.queue => QueuePanel(
                    engine: engine,
                    showHeader: false,
                    selfName: selfName,
                  ),
                  // On the backdrop by itself (`RoomPanel.onBackdrop`).
                  _PanelView.people => RoomPanel(
                    engine: engine,
                    selfName: selfName,
                    network: network,
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
