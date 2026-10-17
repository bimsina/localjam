/// The docked room bar — Spotify's mini-player, doing the job that makes the
/// session-controller refactor worth it.
///
/// Whenever a jam is live and you are somewhere else in the app, this shows
/// what is playing and takes you back. It can only exist because the engine
/// now outlives the route: before, navigating away from the room closed it.
///
/// Two widgets live here. [JamRoomBar] is the look — 64 dp over the safe area,
/// blurred translucent `surface`, a hairline on top and a 2 dp accent progress
/// line above that, and slots for artwork, people and a transport button. It
/// knows nothing about engines, so it can be laid out in a test or a gallery.
/// [RoomBar] is the one the router mounts: it subscribes to the session and
/// fills those slots.
library;

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:localjam_client/localjam_client.dart';

import '../design/tokens.dart';
import '../design/typography.dart';
import '../state/session_controller.dart';
import '../util/format.dart';
import 'artwork.dart';
import 'avatar.dart';

/// Strings the bar owns.
abstract final class JamRoomBarStrings {
  static const String ended = 'This jam ended';
  static const String endedAction = 'Details';
  static const String open = 'Open the room';
  static const String play = 'Play';
  static const String pause = 'Pause';

  /// The host, when a guest has not been told their name.
  static const String host = 'Host';
}

/// How many faces the bar carries before the `+N` chip (§4).
const int _kBarFaces = 3;

/// The bar's own height, above whatever the bottom safe area adds.
const double kJamRoomBarHeight = 64;

/// The blur behind the translucent surface, per §2.6.
const double _kBlurSigma = 24;

/// The mini player, as a pure piece of layout.
///
/// Every moving part is a slot so this file never has to know what an avatar
/// or an artwork tile looks like: pass [artwork] (44 dp square), [people] (an
/// avatar stack), and a transport callback. Omitting [onPlayPause] is how a
/// guest without `controlPlayback` renders — the button is simply not there,
/// because a 44 dp target that does nothing is worse than none.
class JamRoomBar extends StatelessWidget {
  const JamRoomBar({
    super.key,
    required this.title,
    required this.subtitle,
    this.artwork,
    this.people,
    this.progress,
    this.playing = false,
    this.onPlayPause,
    this.onOpen,
    this.tint,
    this.floating = false,
    this.borderRadius,
  });

  /// Line one: the track, or the room when nothing is queued. `jamRowTitle`.
  final String title;

  /// Line two: the session's name. `jamFootnote`.
  final String subtitle;

  /// The 44 dp artwork slot. A plain placeholder stands in when null — the
  /// artwork tile is another engineer's widget and drops straight in here.
  final Widget? artwork;

  /// The avatar stack. Omitted on a bar too narrow to carry it.
  final Widget? people;

  /// Playback position as 0..1, or null for no progress line at all.
  final double? progress;

  /// Whether the transport button shows a pause glyph.
  final bool playing;

  /// Play/pause. Null renders no button.
  final VoidCallback? onPlayPause;

  /// Opens the room. Fired by a tap anywhere on the bar and by a swipe up.
  final VoidCallback? onOpen;

  /// The current artwork's ambient tint: 0.08 at the left edge, fading out
  /// across the bar's first two thirds. Never touches text — see
  /// `design/artwork_tint.dart`.
  final Color? tint;

  /// The medium-width form (§5 "Wide layouts"): a pill floating clear of the
  /// window edge rather than a bar welded to it. Drops the top hairline —
  /// which belongs to a bar that meets the content above it — and the bottom
  /// safe-area inset, which the caller's margin has already cleared.
  final bool floating;

  /// The corner the bar is clipped to. The 2 dp progress line is pinned to
  /// the very top edge, so a caller that rounds the bar from *outside* leaves
  /// the line running straight across the corner it just rounded — this is
  /// how the pill and the sidebar dock get it clipped from inside instead.
  final BorderRadius? borderRadius;

  /// Swipe velocity, in dp/s, above which an upward flick opens the room.
  static const double _openVelocity = 240;

  /// Below this width there is no room for a title, a session name, faces and
  /// a transport button without all four becoming unreadable. The docked bar
  /// in a 260 dp sidebar is the case this exists for: it collapses to the
  /// cover and the play button, which is all the space honestly holds.
  static const double kCollapseWidth = 320;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final wash = tint;
    final radius = borderRadius ?? BorderRadius.zero;

    return Semantics(
      container: true,
      button: onOpen != null,
      label: '$title. $subtitle',
      hint: onOpen == null ? null : JamRoomBarStrings.open,
      // The tap lives on this node rather than on the GestureDetector below,
      // which `excludeSemantics` deliberately silences: one bar, one thing
      // to activate.
      onTap: onOpen,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // Up opens the room; down is deliberately inert. A mini player that
        // dismisses itself downward is a mini player people lose.
        onVerticalDragEnd: (details) {
          final velocity = details.primaryVelocity ?? 0;
          if (velocity < -_openVelocity) onOpen?.call();
        },
        onTap: onOpen,
        child: ClipRRect(
          borderRadius: radius,
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(
              sigmaX: _kBlurSigma,
              sigmaY: _kBlurSigma,
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: colors.surface.withValues(alpha: isDark ? 0.86 : 0.82),
                border: floating
                    ? null
                    : Border(
                        top: BorderSide(color: colors.separator, width: 0.5),
                      ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _ProgressLine(progress: progress),
                  SafeArea(
                    top: false,
                    bottom: !floating,
                    child: SizedBox(
                      height: kJamRoomBarHeight,
                      child: Stack(
                        children: [
                          if (wash != null)
                            Positioned.fill(
                              child: ExcludeSemantics(
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    // Across the whole bar, not a 40 %-wide
                                    // box: a gradient that runs out mid-bar
                                    // draws a seam exactly where it stops,
                                    // however soft its own last stop is.
                                    // Same wash, no edge.
                                    gradient: LinearGradient(
                                      begin: Alignment.centerLeft,
                                      end: Alignment.centerRight,
                                      stops: const [0, 0.3, 0.62],
                                      colors: [
                                        wash.withValues(alpha: 0.08),
                                        wash.withValues(alpha: 0.035),
                                        wash.withValues(alpha: 0),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          LayoutBuilder(
                            builder: (context, constraints) => Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: JamSpace.md,
                              ),
                              child: _BarRow(
                                title: title,
                                subtitle: subtitle,
                                artwork: artwork,
                                people: people,
                                playing: playing,
                                onPlayPause: onPlayPause,
                                collapsed:
                                    constraints.maxWidth < kCollapseWidth,
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
          ),
        ),
      ),
    );
  }
}

/// The bar's contents, in one of two forms.
///
/// Wide: cover, title and session name, faces, transport. Narrow (a 260 dp
/// sidebar dock): cover and transport only. The middle ground — a 40 dp
/// ellipsised title beside a face beside a button — was the review's
/// unreadable case, so the layout skips it rather than squeezing.
class _BarRow extends StatelessWidget {
  const _BarRow({
    required this.title,
    required this.subtitle,
    required this.artwork,
    required this.people,
    required this.playing,
    required this.onPlayPause,
    required this.collapsed,
  });

  final String title;
  final String subtitle;
  final Widget? artwork;
  final Widget? people;
  final bool playing;
  final VoidCallback? onPlayPause;
  final bool collapsed;

  @override
  Widget build(BuildContext context) {
    final cover = SizedBox.square(
      dimension: JamArtworkSize.bar,
      child: artwork ?? const JamRoomBarArtworkPlaceholder(),
    );
    final transport = onPlayPause == null
        ? null
        : _TransportButton(playing: playing, onPressed: onPlayPause!);

    if (collapsed) {
      return Row(children: [cover, const Spacer(), ?transport]);
    }

    return Row(
      children: [
        cover,
        const SizedBox(width: JamSpace.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.jamRowTitle,
              ),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.jamFootnote,
              ),
            ],
          ),
        ),
        if (people != null) ...[const SizedBox(width: JamSpace.sm), people!],
        if (transport != null) ...[
          const SizedBox(width: JamSpace.xs),
          transport,
        ],
      ],
    );
  }
}

/// The 2 dp accent line pinned to the bar's top edge.
class _ProgressLine extends StatelessWidget {
  const _ProgressLine({required this.progress});

  final double? progress;

  @override
  Widget build(BuildContext context) {
    final value = progress;
    if (value == null) return const SizedBox(height: 2);
    final colors = context.jamColors;
    return ExcludeSemantics(
      child: SizedBox(
        height: 2,
        child: Align(
          alignment: Alignment.centerLeft,
          child: FractionallySizedBox(
            widthFactor: value.clamp(0.0, 1.0),
            heightFactor: 1,
            child: ColoredBox(color: colors.accent),
          ),
        ),
      ),
    );
  }
}

/// A 44 dp play/pause target. The glyph cross-fades rather than swapping, so
/// a tap reads as one control changing state.
class _TransportButton extends StatelessWidget {
  const _TransportButton({required this.playing, required this.onPressed});

  final bool playing;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final noMotion = MediaQuery.disableAnimationsOf(context);
    return Semantics(
      button: true,
      label: playing ? JamRoomBarStrings.pause : JamRoomBarStrings.play,
      excludeSemantics: true,
      child: SizedBox.square(
        dimension: 44,
        child: IconButton(
          padding: EdgeInsets.zero,
          tooltip: playing ? JamRoomBarStrings.pause : JamRoomBarStrings.play,
          onPressed: onPressed,
          icon: AnimatedSwitcher(
            duration: noMotion ? JamDuration.instant : JamDuration.fast,
            switchInCurve: JamCurve.fast,
            child: Icon(
              playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
              key: ValueKey<bool>(playing),
              size: 30,
              color: colors.textPrimary,
            ),
          ),
        ),
      ),
    );
  }
}

/// What sits in the artwork slot until a real cover is handed to the bar.
///
/// Deliberately plain: the placeholder gradient belongs to the artwork tile,
/// and duplicating it here would be a second copy to keep in step.
class JamRoomBarArtworkPlaceholder extends StatelessWidget {
  const JamRoomBarArtworkPlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    return ExcludeSemantics(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surfaceMuted,
          borderRadius: BorderRadius.circular(
            JamRadius.artwork(JamArtworkSize.bar),
          ),
        ),
        child: Icon(
          Icons.music_note_rounded,
          size: 20,
          color: colors.textTertiary,
        ),
      ),
    );
  }
}

/// The session-bound bar the router mounts.
class RoomBar extends StatefulWidget {
  const RoomBar({super.key, this.floating = false, this.borderRadius});

  /// Renders the medium-width floating pill — see [JamRoomBar.floating]. The
  /// shell owns the margin and the shadow around it.
  final bool floating;

  /// The corner the bar clips itself to — see [JamRoomBar.borderRadius].
  final BorderRadius? borderRadius;

  @override
  State<RoomBar> createState() => _RoomBarState();
}

class _RoomBarState extends State<RoomBar> {
  final List<StreamSubscription<Object?>> _subs = [];
  JamEngine? _bound;
  String _identity = '';

  @override
  void initState() {
    super.initState();
    unawaited(_loadIdentity());
    JamIdentity.changes.addListener(_onIdentityChanged);
  }

  /// A stored name adopted after a prefs timeout has to reach the roster
  /// too, or the bar keeps calling you by a name nobody else is using.
  void _onIdentityChanged() => unawaited(_loadIdentity());

  Future<void> _loadIdentity() async {
    final name = await JamIdentity.displayName();
    if (mounted && name != _identity) setState(() => _identity = name);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bind(JamSession.of(context).engine);
  }

  /// The host holds a reserved peer id and never appears in `peers`, so a
  /// guest has to put them back or the bar is a face short.
  List<String> _roster(JamEngine engine, JamSessionController session) => [
    if (_identity.isNotEmpty) _identity,
    if (!session.isHost) _hostName(engine, session),
    for (final peer in engine.peers)
      peer.clientName.isEmpty ? peer.peerId : peer.clientName,
  ];

  String _hostName(JamEngine engine, JamSessionController session) {
    if (session.isHost) return _identity;
    final name = engine.hostPeer?.clientName.trim() ?? '';
    return name.isEmpty ? JamRoomBarStrings.host : name;
  }

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
      ..add(engine.playlistUpdates.listen(refresh));
    // The avatar stack is only honest if it repaints when the room's
    // membership changes.
    if (engine is JamGuestEngine) {
      _subs.add(engine.peerEvents.listen(refresh));
    } else if (engine is JamHostEngine) {
      _subs.add(engine.events.listen(refresh));
    }
  }

  @override
  void dispose() {
    JamIdentity.changes.removeListener(_onIdentityChanged);
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = JamSession.of(context);
    final engine = session.engine;
    // A session that ended while the user was elsewhere still needs somewhere
    // to be acknowledged from, so the bar survives into the terminal phase
    // and carries them to the room screen that explains it.
    if (session.phase == JamSessionPhase.ended) {
      return _EndedBar(
        floating: widget.floating,
        borderRadius: widget.borderRadius,
      );
    }
    if (engine == null || !session.isLive) return const SizedBox.shrink();

    final item = engine.currentItem;
    final playing = engine.snapshot.status == PlaybackStatus.playing;
    final canControl = engine.can(JamCapability.controlPlayback);
    final position = session.position;

    Widget bar(double? progress) => JamTintBuilder(
      engine: engine,
      // The same cache the room screen reads, so minimising the player does
      // not pay for the current cover's tint a second time.
      cache: session.tints,
      builder: (context, tint) => JamRoomBar(
        title: item == null ? engine.sessionName : jamDisplayTitle(item),
        subtitle: engine.sessionName,
        artwork: JamArtwork(
          engine: engine,
          item: item,
          size: JamArtworkSize.bar,
        ),
        people: JamAvatarStack(
          names: _roster(engine, session),
          size: JamAvatarSize.attribution,
          maxVisible: _kBarFaces,
          hostName: _hostName(engine, session),
          youName: _identity,
        ),
        tint: tint.base,
        floating: widget.floating,
        borderRadius: widget.borderRadius,
        progress: progress,
        playing: playing,
        onPlayPause: canControl
            ? () => playing ? engine.transportPause() : engine.transportPlay()
            : null,
        onOpen: () => context.push('/room'),
      ),
    );

    if (position == null) return bar(null);
    // Only the 2 dp line rebuilds per frame; the rest of the bar is built
    // once per state change, which is the whole reason the ticker exists.
    return ValueListenableBuilder<int?>(
      valueListenable: position,
      builder: (context, positionUs, _) {
        final durationUs =
            engine.loadedDurationUs.value ?? item?.durationUs ?? 0;
        final progress = (positionUs == null || durationUs <= 0)
            ? null
            : (positionUs / durationUs).clamp(0.0, 1.0);
        return bar(progress);
      },
    );
  }
}

/// The same dock, in the terminal phase: what happened, and the way out.
class _EndedBar extends StatelessWidget {
  const _EndedBar({this.floating = false, this.borderRadius});

  final bool floating;
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Semantics(
      container: true,
      button: true,
      label: JamRoomBarStrings.ended,
      hint: JamRoomBarStrings.endedAction,
      excludeSemantics: true,
      child: ClipRRect(
        borderRadius: borderRadius ?? BorderRadius.zero,
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: _kBlurSigma, sigmaY: _kBlurSigma),
          child: Material(
            color: colors.surface.withValues(alpha: isDark ? 0.86 : 0.82),
            child: InkWell(
              onTap: () => context.push('/room'),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: floating
                      ? null
                      : Border(
                          top: BorderSide(color: colors.separator, width: 0.5),
                        ),
                ),
                child: SafeArea(
                  top: false,
                  bottom: !floating,
                  child: SizedBox(
                    height: kJamRoomBarHeight,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: JamSpace.lg,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.info_outline_rounded,
                            size: 20,
                            color: colors.textSecondary,
                          ),
                          const SizedBox(width: JamSpace.md),
                          Expanded(
                            child: Text(
                              JamRoomBarStrings.ended,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: context.jamRowTitle,
                            ),
                          ),
                          Text(
                            JamRoomBarStrings.endedAction,
                            style: context.jamFootnote,
                          ),
                          const SizedBox(width: JamSpace.xs),
                          Icon(
                            Icons.chevron_right_rounded,
                            color: colors.textTertiary,
                          ),
                        ],
                      ),
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
