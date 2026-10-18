/// Now Playing — one player for both sides of a jam (DESIGN_SPEC v3 §6.3).
///
/// Written against the abstract [JamEngine] and gated on
/// `engine.can(JamCapability…)`, so a host and a guest render the same screen
/// and the difference is what you may touch.
///
/// Immersive in both themes (D4): the current cover, blurred, fills the
/// window behind white text — the only gradient-like surface in the app. The
/// subtree is themed dark so every shared component on it (menus, glass
/// buttons, the docked People panel) resolves its dark, white-on-colour
/// variant whatever the app's appearance. The queue opens in place (D5): the
/// cover shrinks into a thumbnail beside the title and the list takes the
/// middle of the page, with the scrubber and transport pinned.
///
/// Quiet when correct: nothing says "in sync". A problem is one footnote
/// under the room's name; a state that wants something done is a glass
/// capsule under the header with its one action.
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
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:localjam_client/localjam_client.dart';

import '../design/breakpoints.dart';
import '../design/theme.dart';
import '../design/tokens.dart';
import '../design/typography.dart';
import '../router.dart' show HostSetupArgs;
import '../state/session_controller.dart';
import '../util/format.dart';
import '../util/network.dart';
import '../widgets/artwork.dart';
import '../widgets/avatar.dart';
import '../widgets/peer_row.dart';
import '../widgets/buttons.dart';
import '../widgets/diagnostics_sheet.dart';
import '../widgets/dialogs.dart';
import '../widgets/drag_to_dismiss.dart';
import '../widgets/empty_state.dart';
import '../widgets/glass.dart';
import '../widgets/menu.dart';
import '../widgets/nudge_slider.dart';
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
  static const String close = 'Close Now Playing';
  static const String invite = 'Invite People';
  static const String people = 'People';
  static const String soundOffset = 'Sound Offset';
  static const String queue = 'Up Next';
  static const String more = 'More';

  // The ••• menu (spec §10.1): only what has no control of its own.
  static const String diagnostics = 'Diagnostics';
  static const String endJam = 'End Jam';
  static const String leaveJam = 'Leave Jam';
  // The same confirmation the People sheet asks, word for word.
  static const String endTitle = RoomSheetStrings.endTitle;
  static const String endBody = RoomSheetStrings.endDetail;
  static const String leaveTitle = RoomSheetStrings.leaveTitle;
  static const String leaveBody = RoomSheetStrings.leaveDetail;
  static const String leave = RoomSheetStrings.leave;
  static const String cancel = 'Cancel';

  // The title block.
  static const String nothingPlaying = 'Nothing Playing';
  static const String addSongs = 'Add Songs';
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
  static const String retry = 'Try Again';

  /// What "Try Again" says to a screen reader, which hears it apart from
  /// the sentence before it.
  static const String retryFetch = 'Try getting this song again';
  static String importingCount(int done, int total) =>
      'Adding your music… $done of $total';

  /// The host's play is held until every guest has the track (§6.3).
  static const String awaitingReadiness = 'Waiting for everyone’s download…';
  static String waiting(int n) => n == 1
      ? 'Waiting for 1 person to get this song'
      : 'Waiting for $n people to get this song';

  // Terminal states (spec §10.9: "jam", never "room"; plain reasons).
  static const String hostGoneTitle = 'The Host Left';
  static const String hostGoneBody = 'Their phone may have gone to sleep.';

  static const String kickedTitle = 'You Were Removed';
  static const String kickedBody = 'The host removed you from this jam.';
  // `rejected`, by the host's reason (JamSessionController.endRejectReason).
  // A reason this version does not know — or none — keeps the generic pair,
  // which names the likeliest cause without promising it.
  static const String rejectedTitle = 'Couldn’t Get Back In';
  static const String rejectedBody =
      'The jam turned this phone away. It may have restarted, so ask the '
      'host for a new code.';

  /// `bad_token`: the room restarted under a new code. The old link can
  /// never work again, so there is no "Try Again".
  static const String restartedTitle = 'The Jam Restarted';
  static const String restartedBody =
      'The code this phone joined with doesn’t work any more. Ask the host '
      'for the new one.';

  /// `version`: no retry fixes this; an update does.
  static const String versionTitle = 'Update Needed';
  static const String versionBody = kJamVersionMismatch;

  /// `full`: the one refusal that can turn into a yes on its own.
  static const String fullTitle = 'This Jam Is Full';
  static const String fullBody =
      'Someone has to leave before this phone can get back in.';

  /// Host only: the OS took the room's listening socket while the app was
  /// away and it could not be reopened (listenerFailed).
  static const String listenerFailedTitle = 'New Guests Can’t Join';
  static const String listenerFailedBody =
      'Start a new jam to keep going. Your queue comes with you.';
  static const String startNew = 'Start a New Jam';
  static const String hostEndedTitle = 'The Host Ended the Jam';
  static const String hostEndedBody = 'This jam is over for everyone.';
  static const String endedTitle = 'Jam Ended';
  static const String endedBody = 'This jam is over.';
  static const String tryAgain = 'Try Again';
  static const String back = 'Back to Nearby';
  static const String rejoinFailed = kJamRejoinFailed;

  /// The docked panel's two views (wide windows).
  static const String panelQueue = 'Up Next';
  static const String panelRoom = 'People';
}

/// Below this page height the vertical player cannot hold its own shape, so
/// the room turns side-on: cover left, controls right. Landscape phones live
/// here, and so does a short desktop window.
const double kRoomShortHeight = 560;

/// The cover's side margin on a phone (§6.3: 28–32).
const double _kArtMargin = 28;

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

/// How far the paused cover springs back (§6.3).
const double _kPausedScale = 0.86;

/// The paused spring's length — long enough for its settle to read.
const Duration _kPauseSpring = Duration(milliseconds: 550);

/// The docked panel's width on wide windows.
const double _kPanelWidth = 360;

class RoomScreen extends StatefulWidget {
  const RoomScreen({super.key});

  @override
  State<RoomScreen> createState() => _RoomScreenState();
}

enum _PanelView { queue, people }

class _RoomScreenState extends State<RoomScreen>
    with SingleTickerProviderStateMixin {
  final List<StreamSubscription<Object?>> _subs = [];
  JamEngine? _bound;
  String _identity = '';
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
    unawaited(_loadIdentity());
    unawaited(_refreshNetwork());
  }

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
      // The big button is "Resume Audio" while this phone is silenced.
      ..add(engine.outputSuspensionChanges.listen(refresh));
    if (engine is JamGuestEngine) {
      _subs.add(engine.peerEvents.listen(refresh));
    } else if (engine is JamHostEngine) {
      _subs.add(engine.events.listen(refresh));
    }
  }

  @override
  void dispose() {
    _queue.dispose();
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

  ThemeData _nowPlayingTheme(BuildContext context) {
    final platform = Theme.of(context).platform;
    if (_theme == null || _themePlatform != platform) {
      _themePlatform = platform;
      _theme = jamDarkTheme(platform: platform);
    }
    return _theme!;
  }

  /// "Try Again": the controller keeps this room mounted for the whole
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
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
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

  /// The host holds the reserved peer id "host" and is never in `peers`, so
  /// a guest has to add it back or the room looks a person short.
  List<String> _roster(JamEngine engine) => <String>[
    _identity.isNotEmpty ? _identity : JamPeerRowStrings.you,
    if (engine is JamGuestEngine) _hostName(engine),
    for (final peer in engine.peers) jamPeerName(peer),
  ];

  /// The host, by name: the one the welcome frame carried, and the role
  /// word only when they shared none.
  String _hostName(JamEngine engine) {
    final name = engine.hostPeer?.clientName.trim() ?? '';
    return name.isEmpty ? JamRoomStrings.host : name;
  }

  @override
  Widget build(BuildContext context) {
    final session = JamSession.of(context);
    final engine = session.engine;

    if (session.phase == JamSessionPhase.ended || session.rejoining) {
      final reason = session.endReason;
      final rejoining = session.rejoining;
      return JamSessionEndedView(
        reason: reason,
        rejectReason: session.endRejectReason,
        retrying: rejoining,
        // Only a failed "Try Again" leaves an error behind on this screen;
        // anything older was cleared when the session started.
        error: rejoining ? null : session.error,
        onDone: rejoining
            ? null
            : () async {
                await session.acknowledgeEnd();
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
    final roster = _roster(engine);
    // Parallel to [roster]: the ids its faces are coloured over (§10.10).
    final rosterKeys = jamRosterPeerIds(engine);
    final canAdd = engine.can(JamCapability.addTracks);
    // A sheet over the player (People, Sound Offset) brings its own grabber;
    // two stacked bars read as one broken one.
    final onTop = ModalRoute.of(context)?.isCurrent ?? true;

    // Every action appears once (§10.1): Invite is the header's, People and
    // Sound Offset are the footer's. The ••• keeps what has no control of
    // its own.
    final menu = JamMenuButton(
      trigger: JamMenuTrigger.glassOnArtwork,
      visualSize: 30,
      triggerAlignment: AlignmentDirectional.centerEnd,
      semanticLabel: JamRoomStrings.more,
      // Dark over the backdrop, whatever the app theme says.
      brightness: Brightness.dark,
      groups: [
        [
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
      rosterKeys: rosterKeys,
      queueSelected: wide && _panel == _PanelView.queue,
      peopleSelected: wide && _panel == _PanelView.people,
      onClose: _minimise,
      onInvite: () => _openInvite(engine),
      onQueue: _toggleQueue,
      onPeople: () => _openPeople(engine),
      onSoundOffset: () => _openSoundOffset(engine),
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

/// The player: header, engine capsule, and the stage (cover, title, queue,
/// scrubber, transport, footer) in whichever shape the window can hold.
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
    required this.rosterKeys,
    required this.queueSelected,
    required this.peopleSelected,
    required this.onClose,
    required this.onInvite,
    required this.onQueue,
    required this.onPeople,
    required this.onSoundOffset,
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

  /// [roster]'s colour keys (peer ids), parallel to it.
  final List<String> rosterKeys;

  /// Wide only: which docked view the footer's buttons are showing.
  final bool queueSelected;
  final bool peopleSelected;

  final VoidCallback onClose;
  final VoidCallback? onInvite;
  final VoidCallback onQueue;
  final VoidCallback onPeople;
  final VoidCallback onSoundOffset;
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

    final header = _Header(
      engine: engine,
      guest: guest,
      session: session,
      showGrabber: showGrabber,
      grabberVisible: grabberVisible,
      onClose: onClose,
      onInvite: onInvite,
      onDiagnostics: onDiagnostics,
    );

    final title = _TitleBlock(
      engine: engine,
      item: item,
      importing:
          session.hostImport != null &&
          !session.hostImport!.progress.value.isDone,
      onAdd: onAdd,
      menu: menu,
      queue: queue,
    );

    final scrubber = _Scrubber(
      engine: engine,
      session: session,
      enabled: canControl && canSend && item != null,
    );

    final transport = _TransportArea(
      engine: engine,
      session: session,
      canControl: canControl,
      hasQueue: engine.playlist.isNotEmpty,
    );

    final footer = _Footer(
      roster: roster,
      rosterKeys: rosterKeys,
      queueSelected: queueSelected,
      peopleSelected: peopleSelected,
      queue: wide ? null : queue,
      onPeople: onPeople,
      onSoundOffset: onSoundOffset,
      onQueue: onQueue,
    );

    return SafeArea(
      bottom: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          _EngineCapsule(engine: engine, guest: guest, session: session),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final bottomInset = MediaQuery.paddingOf(context).bottom;
                if (constraints.maxHeight < kRoomShortHeight - 120 ||
                    (constraints.maxWidth > constraints.maxHeight * 1.25 &&
                        !wide)) {
                  return _SideOnStage(
                    engine: engine,
                    item: item,
                    paused: paused,
                    queue: queue,
                    bottomInset: bottomInset,
                    title: title,
                    scrubber: scrubber,
                    transport: transport,
                    footer: footer,
                    onCloseQueue: onQueue,
                  );
                }
                return AnimatedBuilder(
                  animation: queue,
                  builder: (context, _) {
                    final t = JamCurve.standard.transform(queue.value);
                    final open = queue.value > 0;
                    // A phone's cover spans the width; a tablet's grows with
                    // the pane (§10.12) up to a poster's size, and the height
                    // left after the controls caps both.
                    final phone =
                        context.jamBreakpoint == JamBreakpoint.compact;
                    final margin = phone ? _kArtMargin : _kArtMarginWide;
                    final maxContent = phone ? double.infinity : _kArtMaxWide;
                    // The list lines up with the cover it replaces.
                    final listPad = math.max(
                      margin,
                      (constraints.maxWidth - maxContent) / 2,
                    );
                    return CustomMultiChildLayout(
                      delegate: _StageLayout(
                        t: t,
                        margin: margin,
                        maxContent: maxContent,
                        bottomInset: bottomInset,
                        memo: stageMemo,
                      ),
                      children: [
                        LayoutId(
                          id: _Slot.art,
                          child: _Art(
                            engine: engine,
                            item: item,
                            paused: paused,
                            t: t,
                            onTap: queue.value == 1 ? onQueue : null,
                          ),
                        ),
                        LayoutId(id: _Slot.title, child: title),
                        if (open)
                          LayoutId(
                            id: _Slot.queue,
                            child: IgnorePointer(
                              ignoring: queue.value < 1,
                              child: Opacity(
                                opacity: Curves.easeIn.transform(queue.value),
                                child: QueuePanel(
                                  engine: engine,
                                  horizontalPadding: listPad,
                                ),
                              ),
                            ),
                          ),
                        LayoutId(id: _Slot.scrubber, child: scrubber),
                        LayoutId(id: _Slot.transport, child: transport),
                        LayoutId(id: _Slot.footer, child: footer),
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

enum _Slot { art, title, queue, scrubber, transport, footer }

/// The vertical stage. Lays the controls out at their own heights, gives
/// the cover what is left (never more than the width allows), and spreads
/// the slack the way the Music app does — most of it around the transport.
/// [t] runs the queue in place: the cover into a 56 thumbnail at top-left,
/// the title beside it, the list in the middle, the controls pinned low.
class _StageLayout extends MultiChildLayoutDelegate {
  _StageLayout({
    required this.t,
    required this.margin,
    required this.maxContent,
    required this.bottomInset,
    required this.memo,
  });

  final double t;
  final double margin;
  final double maxContent;
  final double bottomInset;

  /// The big layout's title height, kept across the queue's morph: the
  /// title shrinks as the queue opens, and the controls placed under the
  /// big title must not follow it.
  final _StageMemo memo;

  @override
  void performLayout(Size size) {
    final w = size.width;
    final h = size.height;
    final cw = math.max(0.0, math.min(w - margin * 2, maxContent));
    final left = (w - cw) / 2;
    final bottomPad = bottomInset + JamSpace.sm;

    final footerH = layoutChild(
      _Slot.footer,
      BoxConstraints.tightFor(width: math.min(w, cw + margin * 2)),
    ).height;
    final transportH = layoutChild(
      _Slot.transport,
      BoxConstraints.tightFor(width: cw),
    ).height;
    final scrubH = layoutChild(
      _Slot.scrubber,
      BoxConstraints.tightFor(width: cw),
    ).height;
    final titleW = lerpDouble(cw, cw - _kThumb - _kThumbGap, t)!;
    final titleH = layoutChild(
      _Slot.title,
      BoxConstraints.tightFor(width: math.max(0, titleW)),
    ).height;
    if (t == 0) memo.bigTitleH = titleH;
    final bigTitleH = memo.bigTitleH ?? titleH;

    // The big cover.
    const minTop = JamSpace.sm;
    const minArtTitle = JamSpace.xl;
    const minTitleScrub = JamSpace.md;
    const minScrubTransport = 0.0;
    const minTransportFooter = 0.0;
    final fixed = footerH + transportH + scrubH + bigTitleH + bottomPad;
    final avail =
        h -
        fixed -
        minTop -
        minArtTitle -
        minTitleScrub -
        minScrubTransport -
        minTransportFooter;
    final art = math.max(0.0, math.min(cw, avail));
    // What the cover leaves, spread over the gaps in Music's proportions
    // (art → title → scrubber → transport → footer) rather than most of it
    // landing between the scrubber and the transport on a tall phone. Each
    // inner gap stops growing at a ceiling, so a tall window whose cover is
    // capped (a tablet) keeps the controls together and centres the group
    // instead of pulling it apart.
    final slack = math.max(0.0, avail - art);
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

    // The queue in place: only the cover and the title move. The scrubber,
    // the transport and the footer stay exactly where they were (Music
    // keeps them fixed), so a toggle never moves a control under a thumb.
    final qFooterY = bigFooterY;
    final qTransportY = bigTransportY;
    final qScrubY = bigScrubY;
    const qThumbY = JamSpace.sm;
    final qTitleY = math.max(qThumbY, qThumbY + (_kThumb - titleH) / 2);
    final rowBottom = math.max(qThumbY + _kThumb, qTitleY + titleH);

    final artSize = lerpDouble(art, _kThumb, t)!;
    positionChild(
      _Slot.art,
      Offset(
        lerpDouble(left + (cw - art) / 2, left, t)!,
        lerpDouble(bigArtY, qThumbY, t)!,
      ),
    );
    layoutChild(_Slot.art, BoxConstraints.tight(Size.square(artSize)));

    positionChild(
      _Slot.title,
      Offset(
        lerpDouble(left, left + _kThumb + _kThumbGap, t)!,
        lerpDouble(bigTitleY, qTitleY, t)!,
      ),
    );

    if (hasChild(_Slot.queue)) {
      final top = rowBottom + JamSpace.md;
      final bottom = qScrubY - JamSpace.xs;
      layoutChild(
        _Slot.queue,
        BoxConstraints.tight(Size(w, math.max(0, bottom - top))),
      );
      positionChild(_Slot.queue, Offset(0, top));
    }

    positionChild(
      _Slot.scrubber,
      Offset(left, lerpDouble(bigScrubY, qScrubY, t)!),
    );
    positionChild(
      _Slot.transport,
      Offset(left, lerpDouble(bigTransportY, qTransportY, t)!),
    );
    positionChild(
      _Slot.footer,
      Offset(math.max(0, left - margin), lerpDouble(bigFooterY, qFooterY, t)!),
    );
  }

  @override
  bool shouldRelayout(_StageLayout old) =>
      old.t != t ||
      old.margin != margin ||
      old.maxContent != maxContent ||
      old.bottomInset != bottomInset;
}

/// What [_StageLayout] remembers between frames.
class _StageMemo {
  double? bigTitleH;
}

/// The side-on stage: cover (or the queue) on the left, the title and every
/// control on the right. Landscape phones and short windows.
///
/// Nothing scrolls: when the column is too tall for the window (a gated
/// guest's reason under the transport, a large text size) it is scaled down
/// to fit — a play button cut in half by a scroll edge is worse than the
/// whole player a little smaller.
class _SideOnStage extends StatelessWidget {
  const _SideOnStage({
    required this.engine,
    required this.item,
    required this.paused,
    required this.queue,
    required this.bottomInset,
    required this.title,
    required this.scrubber,
    required this.transport,
    required this.footer,
    required this.onCloseQueue,
  });

  final JamEngine engine;
  final MediaItem? item;
  final bool paused;
  final AnimationController queue;
  final double bottomInset;
  final Widget title;
  final Widget scrubber;
  final Widget transport;
  final Widget footer;
  final VoidCallback onCloseQueue;

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.paddingOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final side = math.max(padding.left, padding.right);
        final art = math.max(
          0.0,
          math.min(
            constraints.maxHeight - bottomInset - JamSpace.lg,
            constraints.maxWidth * 0.4,
          ),
        );
        return Padding(
          padding: EdgeInsets.fromLTRB(
            math.max(JamSpace.xxl, side),
            0,
            math.max(JamSpace.xxl, side),
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
                          ),
                        ),
                ),
              ),
              const SizedBox(width: JamSpace.xxxl),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, box) => Center(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: SizedBox(
                        width: box.maxWidth,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            title,
                            const SizedBox(height: JamSpace.md),
                            scrubber,
                            transport,
                            footer,
                          ],
                        ),
                      ),
                    ),
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

/// Grabber, then: glass chevron · room name (and its one problem line) ·
/// glass invite.
class _Header extends StatelessWidget {
  const _Header({
    required this.engine,
    required this.guest,
    required this.session,
    required this.showGrabber,
    required this.grabberVisible,
    required this.onClose,
    required this.onInvite,
    required this.onDiagnostics,
  });

  final JamEngine engine;
  final JamGuestEngine? guest;
  final JamSessionController session;
  final bool showGrabber;
  final bool grabberVisible;
  final VoidCallback onClose;
  final VoidCallback? onInvite;
  final VoidCallback onDiagnostics;

  /// The button row: a 44 target plus a little air.
  static const double _rowHeight = JamMetrics.hitTarget + JamSpace.xs * 2;

  /// The glass circles' inset inside their 44 targets.
  static const double _glassInset =
      (JamMetrics.hitTarget - JamMetrics.glassButton) / 2;

  @override
  Widget build(BuildContext context) {
    final invite = onInvite;
    final scaler = MediaQuery.textScalerOf(context);
    // The name holds one baseline whether or not a status line is showing:
    // centred on the buttons, with the status line's slot reserved under it
    // (empty when all is well), so a line coming or going moves nothing.
    final nameHeight = scaler.scale(22); // headline: 17 / 22
    final statusHeight = scaler.scale(18); // footnote: 13 / 18
    final nameTop = math.max(0.0, (_rowHeight - nameHeight) / 2);
    final height = math.max(_rowHeight, nameTop + nameHeight + statusHeight);
    final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;

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
          // The glass circles' visible edges land on the page margin.
          padding: const EdgeInsets.symmetric(
            horizontal: JamSpace.page - _glassInset,
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
                    child: JamGlassButton(
                      icon: CupertinoIcons.chevron_down,
                      semanticLabel: JamRoomStrings.close,
                      onArtwork: true,
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
                        ? JamGlassButton(
                            icon: CupertinoIcons.person_badge_plus,
                            semanticLabel: JamRoomStrings.invite,
                            onArtwork: true,
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
          return line(JamStatusLine(JamRoomStrings.fetching(percent)));
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

/// The glass capsule under the header, for a state that wants something
/// done: this phone's sound suspended ("Resume Audio"), or a song it could
/// not get ("Try Again"). Empty otherwise.
class _EngineCapsule extends StatelessWidget {
  const _EngineCapsule({
    required this.engine,
    required this.guest,
    required this.session,
  });

  final JamEngine engine;
  final JamGuestEngine? guest;
  final JamSessionController session;

  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    Widget wrap(Widget? capsule) => AnimatedSize(
      duration: reduced ? Duration.zero : JamDuration.base,
      curve: JamCurve.standard,
      alignment: Alignment.topCenter,
      child: capsule == null
          ? const SizedBox(width: double.infinity)
          : Padding(
              padding: const EdgeInsets.fromLTRB(
                JamSpace.page,
                JamSpace.xs,
                JamSpace.page,
                JamSpace.xs,
              ),
              child: Center(child: capsule),
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

/// The cover: square, radius 12, the one shadow; springs to 0.86 while the
/// room is paused (§6.3), and shrinks into the 56 thumbnail as [t] runs.
class _Art extends StatefulWidget {
  const _Art({
    required this.engine,
    required this.item,
    required this.paused,
    required this.t,
    required this.onTap,
  });

  final JamEngine engine;
  final MediaItem? item;
  final bool paused;
  final double t;

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
    final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final t = widget.t;
    final future = _futureFor(widget.item);
    final shadow = BoxShadow.lerpList(
      JamShadow.artwork,
      const <BoxShadow>[],
      t,
    );
    final radius = lerpDouble(JamRadius.nowPlaying, JamRadius.artworkS, t)!;

    // The mini player's cover grows into this one (and back).
    Widget tile(double size, Uint8List? bytes) => JamArtworkHero(
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          boxShadow: shadow,
        ),
        child: JamArtworkTile(
          bytes: bytes,
          imageKey: _artworkId,
          size: size,
          radius: radius,
          onBackdrop: true,
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
        return TweenAnimationBuilder<double>(
          tween: Tween<double>(end: widget.paused ? _kPausedScale : 1),
          duration: reduced ? Duration.zero : _kPauseSpring,
          curve: JamCurve.spring,
          builder: (context, scale, child) =>
              Transform.scale(scale: lerpDouble(scale, 1, t)!, child: child),
          child: Center(child: body),
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

/// Title (title3, white) over "Added by Mia" (title3 regular, white 60%),
/// with the glass ••• on the right. Shrinks toward headline/subheadline as
/// the queue opens, beside the thumbnail.
class _TitleBlock extends StatelessWidget {
  const _TitleBlock({
    required this.engine,
    required this.item,
    required this.importing,
    required this.onAdd,
    required this.menu,
    required this.queue,
  });

  final JamEngine engine;
  final MediaItem? item;

  /// The host's starting files are still being added. An empty room in that
  /// moment is not "Nothing Playing" — the music is on its way.
  final bool importing;

  /// Offered under the title when the room is empty (`addTracks`).
  final VoidCallback? onAdd;

  final Widget menu;
  final Animation<double> queue;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: queue,
      builder: (context, _) {
        final t = JamCurve.standard.transform(queue.value);
        final titleStyle = TextStyle.lerp(
          context.jamTitle3,
          context.jamHeadline,
          t,
        )!.copyWith(color: JamNowPlayingColors.text);
        final subtitleStyle = TextStyle.lerp(
          context.jamTitle3.copyWith(fontWeight: FontWeight.w400),
          context.jamSubheadline,
          t,
        )!.copyWith(color: JamNowPlayingColors.secondary);

        final current = item;
        final String title;
        Widget? subtitle;
        if (current == null) {
          title = importing
              ? JamRoomStrings.importing
              : JamRoomStrings.nothingPlaying;
          final add = onAdd;
          if (importing) {
            subtitle = null;
          } else if (add != null && t > 0.5) {
            // The list right below opens with its own Add Songs row.
            subtitle = null;
          } else if (add != null) {
            // The one call to action of an empty room: a real button, not a
            // tinted link where the artist would go, and nothing else on
            // the page repeats it.
            subtitle = Padding(
              padding: const EdgeInsets.only(top: JamSpace.md),
              // A Row, so the capsule hugs its label rather than filling
              // the width a loose box would hand it.
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  JamButton(
                    label: JamRoomStrings.addSongs,
                    icon: CupertinoIcons.plus,
                    variant: JamButtonVariant.gray,
                    size: JamButtonSize.small,
                    // White on the glass-grey ground, like every other control
                    // on the backdrop.
                    color: JamNowPlayingColors.text,
                    onPressed: add,
                  ),
                ],
              ),
            );
          } else {
            subtitle = Text(
              JamRoomStrings.nothingQueuedBody,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: subtitleStyle,
            );
          }
        } else {
          title = jamDisplayTitle(current);
          // The credit is always shown, yours included: who put this on is
          // the room's own news, and a solo-hosted room with no people on it
          // at all read as a music player.
          final addedBy = jamAddedByLabel(engine, current);
          final credit = addedBy == null
              ? artworkByline(current)
              : addedBy == 'You'
              ? JamRoomStrings.addedByYou
              : JamRoomStrings.addedBy(addedBy);
          subtitle = credit == null
              ? null
              : Text(
                  credit,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: subtitleStyle,
                );
        }

        return Row(
          children: [
            Expanded(
              child: Semantics(
                container: true,
                header: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: titleStyle,
                    ),
                    ?subtitle,
                  ],
                ),
              ),
            ),
            const SizedBox(width: JamSpace.sm),
            // The menu's 30 circle sits at the end of its 44 target
            // (`triggerAlignment`), so the circle's edge lines up with the
            // cover's.
            menu,
          ],
        );
      },
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
class _TransportArea extends StatelessWidget {
  const _TransportArea({
    required this.engine,
    required this.session,
    required this.canControl,
    required this.hasQueue,
  });

  final JamEngine engine;
  final JamSessionController session;
  final bool canControl;
  final bool hasQueue;

  @override
  Widget build(BuildContext context) {
    final canSend = session.canSendCommands;
    final roomPlaying = engine.snapshot.status == PlaybackStatus.playing;
    // While this phone's own sound is suspended (a call, another app,
    // headphones out) the room plays on without it, and the big button is
    // "Resume Audio" — for everyone, since it touches only this phone. As
    // "Pause" it stopped the whole room for someone who only wanted their
    // own sound back. Mirrors the mini player.
    final suspended = engine.outputSuspension.value != null;
    final playing = roomPlaying && !suspended;
    final controls = canControl && canSend && hasQueue;

    return JamTransport(
      state: playing ? JamPlaybackState.playing : JamPlaybackState.paused,
      enabled: suspended || controls,
      playLabel: suspended ? JamRoomBannerStrings.resume : null,
      // The bar is dimmed for different reasons and each needs its own
      // sentence: a host with an empty room is not being told that somebody
      // else is in charge, and a guest whose host is asleep is not being
      // told the rules changed.
      // An empty room says so once, in the title block ("Nothing Playing"
      // and its Add Songs) — not again under a dimmed transport.
      gatedMessage: !canControl
          ? jamHostControlsPlayback
          : !canSend
          ? (session.hostAway
                ? JamRoomStrings.waitForHost
                : JamRoomStrings.waitForReconnect)
          : null,
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
  }
}

/// Apple Music's three footer icons, LocalJam's way: the people in the room
/// (their faces) → People; Sound Offset; Up Next → the queue in place.
class _Footer extends StatelessWidget {
  const _Footer({
    required this.roster,
    required this.rosterKeys,
    required this.queueSelected,
    required this.peopleSelected,
    required this.queue,
    required this.onPeople,
    required this.onSoundOffset,
    required this.onQueue,
  });

  final List<String> roster;

  /// [roster]'s colour keys (peer ids), parallel to it.
  final List<String> rosterKeys;

  /// Wide windows: the docked panel's view. Phones follow [queue] instead.
  final bool queueSelected;
  final bool peopleSelected;

  /// The queue-in-place animation, on phones.
  final Animation<double>? queue;

  final VoidCallback onPeople;
  final VoidCallback onSoundOffset;
  final VoidCallback onQueue;

  @override
  Widget build(BuildContext context) {
    final count = roster.length;
    final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    // The faces are the count (§10.1): no number beside a lone avatar, and
    // past three the pile's own "+N".
    final people = Semantics(
      container: true,
      button: true,
      selected: peopleSelected,
      label: '${JamRoomStrings.people}, $count',
      onTap: onPeople,
      excludeSemantics: true,
      child: JamPressable(
        onTap: onPeople,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: JamMetrics.hitTarget),
          child: Center(
            widthFactor: 1,
            child: AnimatedContainer(
              duration: reduced ? Duration.zero : JamDuration.fast,
              curve: JamCurve.standard,
              padding: const EdgeInsets.symmetric(
                horizontal: JamSpace.sm,
                vertical: JamSpace.xs,
              ),
              // Wide windows: the docked panel is showing People.
              decoration: ShapeDecoration(
                color: peopleSelected
                    ? JamNowPlayingColors.placeholderGround
                    : JamNowPlayingColors.clear,
                shape: const StadiumBorder(),
              ),
              child: JamAvatarStack(
                names: roster,
                colorKeys: rosterKeys,
                size: JamAvatarSize.strip,
                maxVisible: 3,
                overflowColor: JamNowPlayingColors.secondary,
              ),
            ),
          ),
        ),
      ),
    );

    Widget queueButton(bool selected) => _FooterIcon(
      icon: CupertinoIcons.list_bullet,
      semanticLabel: JamRoomStrings.queue,
      selected: selected,
      onPressed: onQueue,
    );

    final animation = queue;
    return SizedBox(
      height: JamMetrics.hitTarget,
      child: Row(
        children: [
          Expanded(child: Center(child: people)),
          Expanded(
            child: Center(
              // Not a speaker: in that slot a speaker reads as volume
              // (§10.1).
              child: _FooterIcon(
                icon: CupertinoIcons.slider_horizontal_3,
                semanticLabel: JamRoomStrings.soundOffset,
                onPressed: onSoundOffset,
              ),
            ),
          ),
          Expanded(
            child: Center(
              child: animation == null
                  ? queueButton(queueSelected)
                  : AnimatedBuilder(
                      animation: animation,
                      builder: (context, _) =>
                          queueButton(animation.value >= 0.5),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A bare footer glyph (white 60%), or — selected — a white circle behind a
/// dark glyph.
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

  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return Semantics(
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
              width: 34,
              height: 34,
              decoration: ShapeDecoration(
                color: selected
                    ? JamNowPlayingColors.fill
                    : JamNowPlayingColors.clear,
                shape: const CircleBorder(),
              ),
              child: Icon(
                icon,
                size: 22,
                color: selected
                    ? JamNowPlayingColors.selectedGlyph
                    : JamNowPlayingColors.secondary,
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
      width: _kPanelWidth,
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
                ),
              ),
              Expanded(
                child: switch (view) {
                  _PanelView.queue => QueuePanel(
                    engine: engine,
                    showHeader: false,
                  ),
                  _PanelView.people => _OnBackdrop(
                    child: RoomPanel(
                      engine: engine,
                      selfName: selfName,
                      network: network,
                    ),
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

/// The terminal states: the immersive look is gone, and a plain page says
/// what happened and what to do about it — never "check your connection",
/// because there is no connection by design.
///
/// Getting back in is the primary action wherever it is a real possibility:
/// the room that closed was probably a host whose phone went to sleep, and
/// the sha-keyed cache means a rejoin costs nothing.
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

  /// Back to Nearby. Null while a retry is in flight.
  final VoidCallback? onDone;

  /// Rejoin the room this device came from, when there is one to rejoin.
  final VoidCallback? onRetry;

  /// Host only: open host setup again on the room the OS took away.
  final VoidCallback? onStartNew;

  /// A "Try Again" is running: its button spins in place.
  final bool retrying;

  /// Why the last "Try Again" failed, said here rather than in a notice
  /// over a screen that is about to be read anyway.
  final String? error;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final (icon, title, detail) = switch (reason) {
      JamSessionEndReason.hostGone => (
        CupertinoIcons.wifi_slash,
        JamRoomStrings.hostGoneTitle,
        JamRoomStrings.hostGoneBody,
      ),
      JamSessionEndReason.kicked => (
        CupertinoIcons.person_crop_circle_badge_xmark,
        JamRoomStrings.kickedTitle,
        JamRoomStrings.kickedBody,
      ),
      JamSessionEndReason.rejected => switch (rejectReason) {
        RejectReason.badToken => (
          CupertinoIcons.lock_rotation,
          JamRoomStrings.restartedTitle,
          JamRoomStrings.restartedBody,
        ),
        RejectReason.version => (
          CupertinoIcons.arrow_up_circle,
          JamRoomStrings.versionTitle,
          JamRoomStrings.versionBody,
        ),
        RejectReason.full => (
          CupertinoIcons.person_3,
          JamRoomStrings.fullTitle,
          JamRoomStrings.fullBody,
        ),
        // `kicked` arrives as its own end reason; it is here only so the
        // switch is total.
        RejectReason.kicked => (
          CupertinoIcons.person_crop_circle_badge_xmark,
          JamRoomStrings.kickedTitle,
          JamRoomStrings.kickedBody,
        ),
        RejectReason.unknown || null => (
          CupertinoIcons.lock,
          JamRoomStrings.rejectedTitle,
          JamRoomStrings.rejectedBody,
        ),
      },
      // The host said goodbye on purpose (§3.4). Nothing to try again for —
      // the room they would rejoin does not exist any more.
      JamSessionEndReason.hostEnded => (
        CupertinoIcons.stop_circle,
        JamRoomStrings.hostEndedTitle,
        JamRoomStrings.hostEndedBody,
      ),
      // The host's own room, gone without "End Jam" being pressed.
      JamSessionEndReason.listenerFailed => (
        CupertinoIcons.antenna_radiowaves_left_right,
        JamRoomStrings.listenerFailedTitle,
        JamRoomStrings.listenerFailedBody,
      ),
      _ => (
        CupertinoIcons.checkmark_circle,
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

    // One primary per screen: getting back in, or starting again, when
    // either is possible — with the way home as the plain second; otherwise
    // the way home alone, as a quiet grey button (leaving is not the loud
    // action on a screen that just told you something ended).
    final String actionLabel;
    final VoidCallback? action;
    final JamButtonVariant variant;
    String? secondaryLabel = JamRoomStrings.back;
    if (retry != null || retrying) {
      actionLabel = JamRoomStrings.tryAgain;
      // Kept non-null while the retry spins, so the button stays in place
      // (the spinner swallows taps).
      action = retry ?? _busy;
      variant = JamButtonVariant.filled;
    } else if (startNew != null) {
      actionLabel = JamRoomStrings.startNew;
      action = startNew;
      variant = JamButtonVariant.filled;
    } else {
      actionLabel = JamRoomStrings.back;
      action = onDone;
      variant = JamButtonVariant.gray;
      secondaryLabel = null;
    }

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: jamOverlayStyle(Theme.of(context).brightness),
      child: ColoredBox(
        color: colors.background,
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(vertical: JamSpace.xxl),
              // Why a "Try Again" failed replaces the reason it was offered
              // for: it is the newer news, and said out loud.
              child: Semantics(
                liveRegion: message != null,
                child: JamEmptyState(
                  icon: icon,
                  title: title,
                  body: message ?? detail,
                  actionLabel: actionLabel,
                  onAction: action,
                  actionVariant: variant,
                  actionLoading: retrying,
                  secondaryActionLabel: secondaryLabel,
                  onSecondaryAction: secondaryLabel == null ? null : onDone,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  static void _busy() {}
}

/// The docked People panel's content on the immersive backdrop (wide
/// windows): its grouped rows become translucent white over the cover's
/// colours instead of opaque dark cards pasted onto it, with the backdrop's
/// own secondary and hairline colours — and white, not raspberry, for what
/// can be tapped, like every other control on Now Playing.
class _OnBackdrop extends StatelessWidget {
  const _OnBackdrop({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.jamColors;
    final onBackdrop = colors.copyWith(
      background: JamNowPlayingColors.clear,
      groupedBackground: JamNowPlayingColors.clear,
      elevatedGroupedBackground: JamNowPlayingColors.clear,
      groupedSurface: JamNowPlayingColors.groupedRow,
      elevatedGroupedSurface: JamNowPlayingColors.groupedRow,
      separator: JamNowPlayingColors.separator,
      label: JamNowPlayingColors.text,
      secondaryLabel: JamNowPlayingColors.secondary,
      tertiaryLabel: JamNowPlayingColors.tertiary,
      fillPressed: JamNowPlayingColors.pressed,
      tint: JamNowPlayingColors.text,
      tintPressed: JamNowPlayingColors.secondary,
      danger: JamNowPlayingColors.destructive,
      warning: JamNowPlayingColors.warning,
    );
    return Theme(
      data: theme.copyWith(
        extensions: [
          for (final extension in theme.extensions.values)
            if (extension is! JamColors) extension,
          onBackdrop,
        ],
      ),
      child: child,
    );
  }
}
