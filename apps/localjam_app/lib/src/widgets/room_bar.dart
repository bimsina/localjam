/// The mini player (DESIGN_SPEC v3 §6.4): a floating capsule that keeps a
/// live jam one tap away wherever you are in the app.
///
/// 64 tall, 12 from the window's sides and 8 above the home indicator, on
/// the translucent `material` blur with a 0.5 pt edge. Cover 40, title and
/// the room's name (or, when there is one, the problem), play/pause and —
/// when the room lets you — next. No progress line, no faces.
///
/// Two widgets live here. [JamRoomBar] is the look, engine-free, so it can
/// be laid out in a test. [RoomBar] is the one the shell mounts: it
/// subscribes to the session, fills the slots, and paints its own side
/// margins and bottom safe-area inset — the shell just stacks it at the
/// bottom.
library;

import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:go_router/go_router.dart';
import 'package:localjam_client/localjam_client.dart';

import '../design/tokens.dart';
import '../design/typography.dart';
import '../state/session_controller.dart';
import '../util/format.dart';
import 'artwork.dart';
import 'glass.dart';
import 'pressable.dart';
import 'room_banner.dart';

/// Strings the bar owns.
abstract final class JamRoomBarStrings {
  static const String ended = 'This jam ended';
  static const String endedAction = 'Details';
  static const String rejoining = 'Getting back in…';
  static const String open = 'Open Now Playing';
  static const String play = 'Play';
  static const String pause = 'Pause';
  static const String next = 'Next';
}

/// The capsule's own height (§6.4), above the margin under it.
const double kJamRoomBarHeight = JamMetrics.miniPlayerHeight;

/// The capsule's distance from the window's sides.
const double kJamRoomBarSideMargin = 12;

/// The capsule's distance above the home indicator.
const double kJamRoomBarBottomMargin = JamSpace.sm;

/// The space the self-margined [RoomBar] takes above the bottom safe area:
/// what a screen under it has to leave clear.
const double kJamRoomBarFootprint = kJamRoomBarHeight + kJamRoomBarBottomMargin;

/// The cover's edge in the capsule.
const double _kArt = JamArtworkSize.mini;

/// The glyphs (§4: mini player 22) and their touch boxes.
const double _kGlyph = 22;
const double _kButton = 44;

/// Below this width the capsule drops the next button.
const double _kNarrow = 280;

/// The mini player, as a pure piece of layout.
class JamRoomBar extends StatelessWidget {
  const JamRoomBar({
    super.key,
    required this.title,
    required this.subtitle,
    this.artwork,
    this.playing = false,
    this.onPlayPause,
    this.onNext,
    this.onOpen,
    this.alert,
    this.playLabel,
    this.borderRadius,
  });

  /// Line one: the song, or the room when nothing is queued.
  final String title;

  /// Line two: the room's name.
  final String subtitle;

  /// The 40 pt cover slot. A placeholder stands in when null.
  final Widget? artwork;

  /// Whether the transport button shows a pause glyph.
  final bool playing;

  /// Play/pause. Null renders no button — a 44 pt target that does nothing
  /// is worse than none.
  final VoidCallback? onPlayPause;

  /// Next. Null (the room does not let you, or nothing is queued) renders
  /// no button.
  final VoidCallback? onNext;

  /// Opens Now Playing. Fired by a tap anywhere on the capsule and by a
  /// swipe up.
  final VoidCallback? onOpen;

  /// Something about this phone's place in the room that should not wait
  /// for Now Playing to be opened — "Headphones disconnected", "The host’s
  /// phone is asleep". Replaces [subtitle], in the warning colour.
  final String? alert;

  /// The play button's spoken name when it is not plain "Play" — "Resume
  /// Audio", while this phone's output is suspended.
  final String? playLabel;

  /// A rounded rectangle instead of the capsule (the sidebar dock).
  final BorderRadius? borderRadius;

  /// Swipe velocity, in pt/s, above which an upward flick opens the room.
  static const double _openVelocity = 240;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final line = alert ?? subtitle;
    final radius = borderRadius;
    final open = onOpen;
    final play = onPlayPause;
    final next = onNext;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // Up opens the room; down is deliberately inert. A mini player that
      // dismisses itself downward is a mini player people lose.
      onVerticalDragEnd: (details) {
        final velocity = details.primaryVelocity ?? 0;
        if (velocity < -_openVelocity) open?.call();
      },
      child: JamBlurSurface(
        shape: radius == null
            ? const StadiumBorder()
            : RoundedRectangleBorder(borderRadius: radius),
        border: BorderSide(color: colors.separator, width: 0.5),
        child: SizedBox(
          height: kJamRoomBarHeight,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final narrow = constraints.maxWidth < _kNarrow;
              return Row(
                children: [
                  Expanded(
                    child: Semantics(
                      container: true,
                      button: open != null,
                      label: '$title. $line',
                      hint: open == null ? null : JamRoomBarStrings.open,
                      onTap: open,
                      excludeSemantics: true,
                      child: JamPressable(
                        onTap: open,
                        pressedOpacity: 0.7,
                        child: Padding(
                          padding: const EdgeInsets.only(
                            left: (kJamRoomBarHeight - _kArt) / 2,
                          ),
                          child: Row(
                            children: [
                              SizedBox.square(
                                dimension: _kArt,
                                child:
                                    artwork ??
                                    const JamArtworkTile(size: _kArt),
                              ),
                              const SizedBox(width: JamSpace.md),
                              Expanded(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: context.jamSubheadline.copyWith(
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    Text(
                                      line,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: context.jamFootnote.copyWith(
                                        color: alert != null
                                            ? colors.warning
                                            : colors.secondaryLabel,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (play != null)
                    _BarButton(
                      icon: playing
                          ? CupertinoIcons.pause_fill
                          : CupertinoIcons.play_fill,
                      label: playing
                          ? JamRoomBarStrings.pause
                          : (playLabel ?? JamRoomBarStrings.play),
                      onPressed: () {
                        JamHaptics.transport();
                        play();
                      },
                    ),
                  if (next != null && !narrow)
                    _BarButton(
                      icon: CupertinoIcons.forward_fill,
                      label: JamRoomBarStrings.next,
                      onPressed: () {
                        JamHaptics.skip();
                        next();
                      },
                    ),
                  SizedBox(
                    width: play == null && next == null
                        ? JamSpace.lg
                        : JamSpace.sm,
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// A 44 pt glyph button in the capsule. The glyph cross-fades rather than
/// swapping, so a tap reads as one control changing state.
class _BarButton extends StatelessWidget {
  const _BarButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return Semantics(
      container: true,
      button: true,
      label: label,
      onTap: onPressed,
      excludeSemantics: true,
      child: JamPressable(
        onTap: onPressed,
        child: SizedBox.square(
          dimension: _kButton,
          child: Center(
            child: AnimatedSwitcher(
              duration: reduced ? Duration.zero : JamDuration.fast,
              switchInCurve: JamCurve.standard,
              child: Icon(
                icon,
                key: ValueKey<IconData>(icon),
                size: _kGlyph,
                color: context.jamColors.label,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The session-bound mini player the shell mounts.
///
/// By default it paints its own margins — 12 from the sides, 8 above the
/// home indicator — so the shell only has to stack it at the bottom. A
/// caller that places it itself (a [floating] pill in a centred column, the
/// sidebar dock with its [borderRadius]) gets the bare capsule.
class RoomBar extends StatefulWidget {
  const RoomBar({super.key, this.floating = false, this.borderRadius});

  /// The caller owns the margins: paint the capsule only.
  final bool floating;

  /// A rounded rectangle instead of the capsule (the sidebar dock). Implies
  /// the caller owns the margins.
  final BorderRadius? borderRadius;

  @override
  State<RoomBar> createState() => _RoomBarState();
}

class _RoomBarState extends State<RoomBar> {
  final List<StreamSubscription<Object?>> _subs = [];
  JamEngine? _bound;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bind(JamSession.of(context).engine);
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
      ..add(engine.playlistUpdates.listen(refresh))
      ..add(engine.permissionUpdates.listen(refresh))
      // "Headphones disconnected" belongs on the bar too: the user is
      // usually on Home when they pull them out.
      ..add(engine.outputSuspensionChanges.listen(refresh));
  }

  @override
  void dispose() {
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    super.dispose();
  }

  Widget _place(Widget capsule) {
    if (widget.floating || widget.borderRadius != null) return capsule;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        kJamRoomBarSideMargin,
        0,
        kJamRoomBarSideMargin,
        kJamRoomBarBottomMargin + MediaQuery.paddingOf(context).bottom,
      ),
      child: capsule,
    );
  }

  @override
  Widget build(BuildContext context) {
    final session = JamSession.of(context);
    final engine = session.engine;
    // A session that ended while the user was elsewhere still needs somewhere
    // to be acknowledged from, so the bar survives into the terminal phase
    // and carries them to the room screen that explains it.
    if (session.phase == JamSessionPhase.ended || session.rejoining) {
      return _place(
        _EndedBar(
          borderRadius: widget.borderRadius,
          rejoining: session.rejoining,
        ),
      );
    }
    if (engine == null || !session.isLive) return const SizedBox.shrink();

    final item = engine.currentItem;
    final roomPlaying = engine.snapshot.status == PlaybackStatus.playing;
    final canControl = engine.can(JamCapability.controlPlayback);
    final canSend = session.canSendCommands;
    final suspension = engine.outputSuspension.value;
    // While this phone's sound is suspended the button is "Resume Audio" —
    // for everyone, since it touches only this phone. Showing "pause" there
    // offered to stop the whole room for someone who just wanted their own
    // sound back.
    final suspended = suspension != null;
    final playing = roomPlaying && !suspended;
    final VoidCallback? onPlayPause = suspended
        ? () => unawaited(engine.resumeLocalOutput())
        : canControl
        ? () => unawaited(
            session.act(
              (e) => roomPlaying ? e.transportPause() : e.transportPlay(),
            ),
          )
        : null;
    final VoidCallback? onNext =
        canControl && canSend && engine.playlist.length > 1
        ? () => unawaited(session.act((e) => e.transportNext()))
        : null;
    final alert = suspension != null
        ? jamOutputSuspensionCopy(suspension)
        : session.hostAway
        ? JamRoomBannerStrings.hostAsleep
        : session.connection != JamConnectionState.connected
        ? JamRoomBannerStrings.reconnecting
        : null;

    return _place(
      JamRoomBar(
        title: item == null ? engine.sessionName : jamDisplayTitle(item),
        subtitle: engine.sessionName,
        artwork: JamArtwork(engine: engine, item: item, size: _kArt),
        playing: playing,
        onPlayPause: onPlayPause,
        onNext: onNext,
        alert: alert,
        playLabel: suspended ? JamRoomBannerStrings.resume : null,
        borderRadius: widget.borderRadius,
        onOpen: () => context.push('/room'),
      ),
    );
  }
}

/// The same capsule in the terminal phase: what happened, and the way to
/// the screen that explains it.
class _EndedBar extends StatelessWidget {
  const _EndedBar({this.borderRadius, this.rejoining = false});

  final BorderRadius? borderRadius;

  /// A "Try Again" is in flight from the room screen.
  final bool rejoining;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final radius = borderRadius;
    void open() => context.push('/room');
    final label = rejoining
        ? JamRoomBarStrings.rejoining
        : JamRoomBarStrings.ended;

    return Semantics(
      container: true,
      button: true,
      label: label,
      hint: JamRoomBarStrings.endedAction,
      onTap: open,
      excludeSemantics: true,
      child: JamPressable(
        onTap: open,
        pressedOpacity: 0.7,
        child: JamBlurSurface(
          shape: radius == null
              ? const StadiumBorder()
              : RoundedRectangleBorder(borderRadius: radius),
          border: BorderSide(color: colors.separator, width: 0.5),
          child: SizedBox(
            height: kJamRoomBarHeight,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: JamSpace.xl),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.jamSubheadline.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (!rejoining) ...[
                    Text(
                      JamRoomBarStrings.endedAction,
                      style: context.jamFootnote.copyWith(
                        color: colors.secondaryLabel,
                      ),
                    ),
                    const SizedBox(width: JamSpace.xs),
                    Icon(
                      CupertinoIcons.chevron_right,
                      size: 14,
                      color: colors.tertiaryLabel,
                    ),
                  ] else
                    const CupertinoActivityIndicator(radius: 8),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
