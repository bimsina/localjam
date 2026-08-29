/// The room — one player for both sides of a jam.
///
/// Written against the abstract [JamEngine] and gated on
/// `engine.can(JamCapability…)`, so a host and a guest render the same screen
/// and the difference is what you may touch. Replaces two ~250-line
/// near-duplicates (`host_screen._buildLive`, `join_screen._buildSession`).
///
/// Shaped like a music player, not a control panel: artwork, title, scrubber,
/// transport. Who is in the room, the join code, and the queue live behind
/// the two icons in the utility row. Sync sits in the small label above the
/// room name and stays colourless unless something is wrong.
///
/// Leaving is explicit. The chevron minimises back to Home with the session
/// still running — before the overhaul, popping the route ended the jam.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:localjam_client/localjam_client.dart';

import '../design/breakpoints.dart';
import '../design/tokens.dart';
import '../design/typography.dart';
import '../state/session_controller.dart';
import '../util/network.dart';
import '../widgets/artwork.dart';
import '../widgets/diagnostics_sheet.dart';
import '../widgets/drag_to_dismiss.dart';
import '../widgets/now_playing.dart';
import '../widgets/peer_avatar.dart';
import '../widgets/queue_sheet.dart';
import '../widgets/room_sheet.dart';
import '../widgets/sync_indicator.dart';

class RoomScreen extends StatefulWidget {
  const RoomScreen({super.key});

  @override
  State<RoomScreen> createState() => _RoomScreenState();
}

enum _RoomMenu { people, diagnostics, leave }

class _RoomScreenState extends State<RoomScreen> {
  final List<StreamSubscription<Object?>> _subs = [];
  JamEngine? _bound;
  String _identity = '';
  JamNetworkStatus _network = JamNetworkStatus.offline;

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
      ..add(engine.permissionUpdates.listen(refresh));
    final guest = engine;
    if (guest is JamGuestEngine) {
      _subs.add(guest.peerEvents.listen(refresh));
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

  Future<void> _loadIdentity() async {
    final name = await JamIdentity.displayName();
    if (mounted) setState(() => _identity = name);
  }

  Future<void> _refreshNetwork() async {
    final status = await currentNetwork();
    if (mounted) setState(() => _network = status);
  }

  Future<void> _confirmLeave(JamSessionController session) async {
    final isHost = session.isHost;
    final leave = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(isHost ? 'End this jam?' : 'Leave this jam?'),
        content: Text(
          isHost
              ? 'Everyone listening will be disconnected.'
              : 'You can rejoin as long as the room is still up.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Stay'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(isHost ? 'End jam' : 'Leave'),
          ),
        ],
      ),
    );
    if (leave != true) return;
    await session.leave();
    if (mounted) context.go('/');
  }

  @override
  Widget build(BuildContext context) {
    final session = JamSession.of(context);
    final engine = session.engine;

    if (session.phase == JamSessionPhase.ended) {
      return _SessionEnded(
        reason: session.endReason,
        onDone: () async {
          await session.acknowledgeEnd();
          if (context.mounted) context.go('/');
        },
      );
    }
    if (engine == null) {
      // Router redirects cover this; the guard keeps a race from crashing.
      return const Scaffold(body: SizedBox.shrink());
    }

    final guest = engine is JamGuestEngine ? engine : null;
    final playlist = engine.playlist;
    final canControl = engine.can(JamCapability.controlPlayback);
    final peers = engine.peers;
    // The host holds the reserved peer id "host" and is never in `peers`, so
    // a guest has to add it back or the room looks a person short.
    final roster = <String>[
      if (_identity.isNotEmpty) _identity,
      if (guest != null) 'Host',
      for (final peer in peers)
        peer.clientName.isEmpty ? peer.peerId : peer.clientName,
    ];

    void minimise() => context.canPop() ? context.pop() : context.go('/');

    void openRoom() => unawaited(
      showRoomSheet(
        context,
        engine,
        selfName: _identity,
        network: _network,
        joinUri: session.joinUri,
      ),
    );

    final wide = context.jamBreakpoint.hasSidePanel;

    return DragToDismiss(
      // A desktop window has no dismiss gesture — the room is a destination
      // beside the sidebar, not a sheet over a phone screen.
      enabled: !wide,
      onDismiss: minimise,
      child: Scaffold(
        appBar: AppBar(
          centerTitle: true,
          leading: IconButton(
            icon: const Icon(Icons.keyboard_arrow_down_rounded),
            tooltip: 'Back to nearby',
            // A pop, so the room plays its reverse slide back down. `go` would
            // replace the stack and skip the exit animation entirely.
            onPressed: () => context.canPop() ? context.pop() : context.go('/'),
          ),
          title: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SyncIndicator(
                engine: engine,
                connection: session.connection,
                clockSynced: guest?.clockSynced ?? true,
              ),
              Text(
                engine.sessionName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.jamRowTitle,
              ),
            ],
          ),
          actions: [
            PopupMenuButton<_RoomMenu>(
              icon: const Icon(Icons.more_horiz_rounded),
              onSelected: (choice) => switch (choice) {
                _RoomMenu.people => openRoom(),
                _RoomMenu.diagnostics => unawaited(
                  showDiagnosticsSheet(
                    context,
                    engine,
                    clockOffsetUs: guest == null
                        ? null
                        : () => guest.clockOffsetUs,
                  ),
                ),
                _RoomMenu.leave => unawaited(_confirmLeave(session)),
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: _RoomMenu.people,
                  child: Text(session.isHost ? 'Room & invites' : 'Who’s here'),
                ),
                const PopupMenuItem(
                  value: _RoomMenu.diagnostics,
                  child: Text('Sync details'),
                ),
                PopupMenuItem(
                  value: _RoomMenu.leave,
                  child: Text(session.isHost ? 'End jam' : 'Leave jam'),
                ),
              ],
            ),
            const SizedBox(width: JamSpace.xs),
          ],
        ),
        body: SafeArea(
          // The app bar covers the top; this is about the home indicator, which
          // the utility row sits right on top of otherwise.
          top: false,
          child: Column(
            children: [
              if (session.connection != JamConnectionState.connected)
                _ReconnectBanner(connection: session.connection),
              Expanded(
                child: Row(
                  children: [
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          // Whichever bounds first: the page width, a share of the
                          // height, or the hero cap (so tablets and desktop do not
                          // blow the cover up absurdly).
                          final artSize = [
                            constraints.maxWidth - JamSpace.xxxl * 2,
                            constraints.maxHeight * 0.46,
                            JamArtworkSize.hero,
                          ].reduce((a, b) => a < b ? a : b);
                          return Padding(
                            padding: const EdgeInsets.fromLTRB(
                              JamSpace.xxxl,
                              JamSpace.sm,
                              JamSpace.xxxl,
                              JamSpace.lg,
                            ),
                            child: Column(
                              children: [
                                // Weighted, not even: the cover belongs in the upper
                                // half with the controls gathered below it.
                                const Spacer(),
                                JamArtwork(
                                  engine: engine,
                                  item: engine.currentItem,
                                  size: artSize,
                                ),
                                const Spacer(flex: 2),
                                SizedBox(
                                  width: double.infinity,
                                  child: NowPlayingTitle(
                                    engine: engine,
                                    item: engine.currentItem,
                                    peers: peers,
                                  ),
                                ),
                                const SizedBox(height: JamSpace.xl),
                                if (session.position case final ticker?)
                                  PlaybackTimeline(
                                    engine: engine,
                                    position: ticker,
                                    canControl: canControl,
                                  ),
                                const SizedBox(height: JamSpace.sm),
                                TransportBar(
                                  engine: engine,
                                  canControl: canControl,
                                  hasQueue: playlist.isNotEmpty,
                                ),
                                const SizedBox(height: JamSpace.lg),
                                _ReadinessNote(engine: engine),
                                const SizedBox(height: JamSpace.lg),
                                _UtilityRow(
                                  roster: roster,
                                  isHost: session.isHost,
                                  selfName: _identity,
                                  queueCount: playlist.length,
                                  onPeople: openRoom,
                                  onQueue: () => unawaited(
                                    showQueueSheet(context, engine),
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                    if (wide)
                      _SidePanel(
                        engine: engine,
                        selfName: _identity,
                        network: _network,
                        joinUri: session.joinUri,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The secondary actions, in the position Spotify puts devices and queue:
/// out of the player's way, one tap from everything.
class _UtilityRow extends StatelessWidget {
  const _UtilityRow({
    required this.roster,
    required this.isHost,
    required this.selfName,
    required this.queueCount,
    required this.onPeople,
    required this.onQueue,
  });

  final List<String> roster;
  final bool isHost;
  final String selfName;
  final int queueCount;
  final VoidCallback onPeople;
  final VoidCallback onQueue;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        InkWell(
          onTap: onPeople,
          borderRadius: BorderRadius.circular(JamRadius.pill),
          child: Padding(
            padding: const EdgeInsets.all(JamSpace.xs),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                PeerAvatarRow(
                  names: roster,
                  hostName: isHost ? selfName : 'Host',
                  size: 24,
                  maxVisible: 3,
                ),
                const SizedBox(width: JamSpace.xs),
                Text('${roster.length}', style: context.jamFootnote),
              ],
            ),
          ),
        ),
        InkWell(
          onTap: onQueue,
          borderRadius: BorderRadius.circular(JamRadius.pill),
          child: Padding(
            padding: const EdgeInsets.all(JamSpace.xs),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('$queueCount', style: context.jamFootnote),
                const SizedBox(width: JamSpace.xs),
                Icon(Icons.queue_music_rounded, color: colors.textSecondary),
              ],
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
    if (waiting == 0) return const SizedBox.shrink();

    return Text(
      waiting == 1
          ? 'Waiting for 1 person to get this track'
          : 'Waiting for $waiting people to get this track',
      style: context.jamCaption.copyWith(color: colors.warning),
    );
  }
}

/// The transport dropped. Playback keeps running from cache, so this is
/// informational, not an error — it says so.
class _ReconnectBanner extends StatelessWidget {
  const _ReconnectBanner({required this.connection});

  final JamConnectionState connection;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    return Container(
      width: double.infinity,
      color: colors.warning.withValues(alpha: 0.12),
      padding: const EdgeInsets.symmetric(
        horizontal: JamSpace.page,
        vertical: JamSpace.md,
      ),
      child: Row(
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: colors.warning,
            ),
          ),
          const SizedBox(width: JamSpace.md),
          Expanded(
            child: Text(
              'Lost the host — still playing what you have.',
              style: context.jamFootnote.copyWith(color: colors.warning),
            ),
          ),
        ],
      ),
    );
  }
}

/// The terminal states. Each says what happened and what to do about it —
/// never "check your connection", because there is no connection by design.
class _SessionEnded extends StatelessWidget {
  const _SessionEnded({required this.reason, required this.onDone});

  final JamSessionEndReason? reason;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final (icon, title, detail) = switch (reason) {
      JamSessionEndReason.hostGone => (
        Icons.podcasts_rounded,
        'The room closed',
        'The host left or went out of range.',
      ),
      JamSessionEndReason.kicked => (
        Icons.person_remove_rounded,
        'You were removed',
        'The host removed you from this room.',
      ),
      JamSessionEndReason.rejected => (
        Icons.lock_outline_rounded,
        'Could not rejoin',
        'The room restarted, so the old code no longer works. Scan a fresh '
            'one.',
      ),
      _ => (Icons.check_circle_outline_rounded, 'Jam ended', ''),
    };

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(JamSpace.xxxl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 44, color: colors.textTertiary),
                const SizedBox(height: JamSpace.xl),
                Text(
                  title,
                  style: context.jamLargeTitle.copyWith(fontSize: 24),
                ),
                if (detail.isNotEmpty) ...[
                  const SizedBox(height: JamSpace.sm),
                  Text(
                    detail,
                    textAlign: TextAlign.center,
                    style: context.jamByline,
                  ),
                ],
                const SizedBox(height: JamSpace.xxxl),
                FilledButton(
                  onPressed: onDone,
                  child: const Text('Back to nearby'),
                ),
              ],
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
    required this.joinUri,
  });

  final JamEngine engine;
  final String selfName;
  final JamNetworkStatus network;
  final Uri? joinUri;

  @override
  State<_SidePanel> createState() => _SidePanelState();
}

enum _PanelTab { queue, room }

class _SidePanelState extends State<_SidePanel> {
  _PanelTab _tab = _PanelTab.queue;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    return Container(
      width: JamContentWidth.panel,
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(left: BorderSide(color: colors.separator, width: 0.5)),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(JamSpace.md),
            child: SegmentedButton<_PanelTab>(
              segments: const [
                ButtonSegment(value: _PanelTab.queue, label: Text('Queue')),
                ButtonSegment(value: _PanelTab.room, label: Text('Room')),
              ],
              selected: {_tab},
              showSelectedIcon: false,
              onSelectionChanged: (selection) =>
                  setState(() => _tab = selection.first),
            ),
          ),
          Divider(height: 0.5, color: colors.separator),
          Expanded(
            child: switch (_tab) {
              _PanelTab.queue => QueuePanel(engine: widget.engine),
              _PanelTab.room => RoomPanel(
                engine: widget.engine,
                selfName: widget.selfName,
                network: widget.network,
                joinUri: widget.joinUri,
              ),
            },
          ),
        ],
      ),
    );
  }
}
