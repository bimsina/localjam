/// The one way the app says something happened: the toast / HUD.
///
/// [JamSessionController.notices] is a single channel and the router shell is
/// the single subscriber; this is the single *look*: a soft rectangle
/// ([JamNoticeSurface], radius [JamRadius.notice]) of `material` with a
/// hairline edge — a glyph only when the news is good or bad, one or two
/// lines of subheadline text, at most one tint action — that dismisses
/// itself. No full-width snackbars, no capsules. The player's banner
/// (`JamRoomBanner`) is the same surface on the backdrop.
///
/// **Never over a control (§10.5).** Where it floats is the caller's call
/// ([JamNoticePosition]): the router shell puts it at the *top* (under the
/// status bar) on Now Playing and whenever a sheet is open — the bottom
/// there is all transport and sheet content — and at the bottom, above the
/// mini player or the pinned button, everywhere else. Copy actions do not
/// use a notice at all: they confirm in place (`JamCopyButton`).
///
/// It is hosted in the **root navigator's overlay**, not a
/// `ScaffoldMessenger`, so a notice raised from inside a sheet is drawn above
/// the sheet rather than behind it. One at a time, four seconds.
library;

import 'dart:async';

import 'package:flutter/cupertino.dart';

import '../design/tokens.dart';
import '../design/typography.dart';
import '../state/session_controller.dart';
import 'glass.dart';
import 'pressable.dart';

export '../state/session_controller.dart' show JamNotice, JamNoticeTone;

/// Which edge of the window a notice floats at.
enum JamNoticePosition {
  /// Under the status bar (Now Playing, any open sheet).
  top,

  /// Above the bottom chrome (the default).
  bottom,
}

/// How long a notice stays up before it goes on its own.
const Duration kJamNoticeDuration = Duration(seconds: 4);

/// The default distance a notice keeps from the edges it floats over.
const EdgeInsets kJamNoticeMargin = EdgeInsets.all(JamSpace.lg);

/// How far a notice rises as it arrives.
const double _kNoticeRise = 24;

/// How loud a notice is ([JamNotice.tone]): the glyph and its colour
/// change, nothing else.
extension on JamNoticeTone {
  IconData? get glyph => switch (this) {
    // A plain confirmation of something the user just did — usually with
    // its Undo — gets no glyph at all: the user meant it.
    JamNoticeTone.neutral => null,
    JamNoticeTone.done => CupertinoIcons.checkmark_circle_fill,
    JamNoticeTone.people => CupertinoIcons.person_fill,
    JamNoticeTone.warning => CupertinoIcons.exclamationmark_triangle_fill,
    JamNoticeTone.error => CupertinoIcons.xmark_octagon_fill,
  };

  Color tint(JamColors colors) => switch (this) {
    JamNoticeTone.neutral || JamNoticeTone.people => colors.secondaryLabel,
    JamNoticeTone.done => colors.success,
    JamNoticeTone.warning => colors.warning,
    JamNoticeTone.error => colors.danger,
  };

  String get semanticPrefix => switch (this) {
    JamNoticeTone.neutral || JamNoticeTone.done || JamNoticeTone.people => '',
    JamNoticeTone.warning => 'Warning. ',
    JamNoticeTone.error => 'Error. ',
  };
}

/// A notice's inside: glyph, then the message.
///
/// Public so a host that is not the overlay — an inline banner on a wide
/// layout, a test — can render the same thing.
class JamNoticeBody extends StatelessWidget {
  const JamNoticeBody({
    super.key,
    required this.message,
    this.tone = JamNoticeTone.neutral,
  });

  final String message;
  final JamNoticeTone tone;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    return Semantics(
      liveRegion: true,
      label: '${tone.semanticPrefix}$message',
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (tone.glyph case final glyph?) ...[
            Icon(glyph, size: JamIconSize.control, color: tone.tint(colors)),
            const SizedBox(width: JamSpace.sm),
          ],
          Flexible(
            child: Text(
              message,
              style: context.jamSubheadline.copyWith(
                color: colors.label,
                fontWeight: FontWeight.w500,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// The one shape for "something happened" or "this needs you": a soft
/// rectangle at [JamRadius.notice] — `material` with a hairline edge on
/// ordinary screens, glass ([JamNowPlayingColors.glass]) on the Now Playing
/// backdrop ([onBackdrop]). The toast ([JamNoticeCard]) and the player's
/// banner draw their content inside it.
///
/// ```dart
/// JamNoticeSurface(onBackdrop: true, child: Padding(padding: …, child: row))
/// ```
class JamNoticeSurface extends StatelessWidget {
  const JamNoticeSurface({
    super.key,
    required this.child,
    this.onBackdrop = false,
  });

  final Widget child;

  /// Glass over the backdrop instead of `material`.
  final bool onBackdrop;

  @override
  Widget build(BuildContext context) {
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(JamRadius.notice),
    );
    if (onBackdrop) {
      return JamBlurSurface(
        kind: JamMaterialKind.glass,
        color: JamNowPlayingColors.glass,
        shape: shape,
        child: child,
      );
    }
    return JamBlurSurface(
      shape: shape,
      border: BorderSide(
        color: context.jamColors.separator,
        width: 1 / MediaQuery.devicePixelRatioOf(context),
      ),
      child: child,
    );
  }
}

/// The toast: [JamNoticeSurface], the body, and at most one tint action.
///
/// Separate from the overlay plumbing so a test, or a wide layout that wants
/// it docked, can render exactly what the app shows.
class JamNoticeCard extends StatelessWidget {
  const JamNoticeCard({super.key, required this.notice, this.onAction});

  /// What to say, and how loud ([JamNotice.tone]).
  final JamNotice notice;

  /// Wraps [JamNotice.onAction] so the host can dismiss itself on the way.
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final label = notice.actionLabel;
    final action = onAction ?? notice.onAction;
    final hasAction = label != null && notice.onAction != null;

    return JamNoticeSurface(
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: JamMetrics.hitTarget),
        child: Padding(
          padding: EdgeInsetsDirectional.fromSTEB(
            JamSpace.lg,
            JamSpace.sm,
            hasAction ? JamSpace.xs : JamSpace.lg,
            JamSpace.sm,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: JamNoticeBody(
                  message: notice.message,
                  tone: notice.tone,
                ),
              ),
              if (hasAction) ...[
                const SizedBox(width: JamSpace.xs),
                Semantics(
                  button: true,
                  label: label,
                  onTap: action,
                  excludeSemantics: true,
                  child: JamPressable(
                    onTap: action,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        minWidth: JamMetrics.hitTarget,
                        minHeight: JamMetrics.hitTarget,
                      ),
                      // Both factors: a Center without a height factor
                      // grows to the overlay's full height, and the notice
                      // with it.
                      child: Center(
                        widthFactor: 1,
                        heightFactor: 1,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: JamSpace.md,
                          ),
                          child: Text(
                            label,
                            style: context.jamSubheadline.copyWith(
                              color: colors.tint,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A live notice, so a caller that raised one can take it back down.
class JamNoticeHandle {
  JamNoticeHandle._(this._host);

  final _JamNoticeHost _host;

  /// Whether this notice is the one currently on screen.
  bool get isCurrent => identical(_host._current, this);

  /// Takes this notice down early. A no-op once it has gone on its own.
  void close() {
    if (isCurrent) _host._dismiss();
  }
}

/// Owns the single overlay entry every notice is drawn into.
///
/// One per [OverlayState]: an app has one root overlay, so in practice one
/// per app — but keying off the overlay rather than a global means a test
/// that pumps two apps in a row does not inherit the first one's entry.
class _JamNoticeHost {
  _JamNoticeHost._(this._overlay);

  static final Map<OverlayState, _JamNoticeHost> _hosts = {};

  static _JamNoticeHost of(OverlayState overlay) =>
      _hosts.putIfAbsent(overlay, () => _JamNoticeHost._(overlay));

  final OverlayState _overlay;
  OverlayEntry? _entry;
  final GlobalKey<_JamNoticeOverlayState> _key =
      GlobalKey<_JamNoticeOverlayState>();
  JamNoticeHandle? _current;

  JamNoticeHandle show({
    required JamNotice notice,
    required Duration duration,
    required EdgeInsets margin,
    required JamNoticePosition position,
  }) {
    // Replacing rather than queueing is deliberate: three stacked notices
    // about a network that dropped is three chances to miss the current one.
    _remove();
    final handle = JamNoticeHandle._(this);
    _current = handle;
    final entry = OverlayEntry(
      builder: (context) => _JamNoticeOverlay(
        key: _key,
        notice: notice,
        duration: duration,
        margin: margin,
        position: position,
        onDismissed: () {
          if (identical(_current, handle)) _remove();
        },
      ),
    );
    _entry = entry;
    _overlay.insert(entry);
    return handle;
  }

  /// Plays the exit and then removes the entry.
  void _dismiss() {
    final state = _key.currentState;
    if (state == null) {
      _remove();
      return;
    }
    state.dismiss();
  }

  void _remove() {
    _entry?.remove();
    _entry = null;
    _current = null;
    if (!_overlay.mounted) _hosts.remove(_overlay);
  }
}

/// The entry's widget: a rise-and-fade, a lifetime, and the card.
class _JamNoticeOverlay extends StatefulWidget {
  const _JamNoticeOverlay({
    super.key,
    required this.notice,
    required this.duration,
    required this.margin,
    required this.position,
    required this.onDismissed,
  });

  final JamNotice notice;
  final Duration duration;
  final EdgeInsets margin;
  final JamNoticePosition position;
  final VoidCallback onDismissed;

  @override
  State<_JamNoticeOverlay> createState() => _JamNoticeOverlayState();
}

class _JamNoticeOverlayState extends State<_JamNoticeOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: JamDuration.base,
    reverseDuration: JamDuration.fast,
  );
  Timer? _timer;
  bool _leaving = false;

  @override
  void initState() {
    super.initState();
    _controller.forward();
    _timer = Timer(widget.duration, dismiss);
  }

  /// Plays the exit, then hands the entry back to the host.
  void dismiss() {
    if (_leaving) return;
    _leaving = true;
    _timer?.cancel();
    _timer = null;
    if (!mounted) {
      widget.onDismissed();
      return;
    }
    _controller.reverse().whenComplete(widget.onDismissed);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The overlay is the window, so the notice clears the home indicator
    // (or the status bar) itself; the caller's margin is what it keeps clear
    // *on top of* that.
    final top = widget.position == JamNoticePosition.top;
    // Only the notice takes touches: the space around it is the screen.
    return SafeArea(
      child: Padding(
        padding: widget.margin,
        child: Align(
          alignment: top ? Alignment.topCenter : Alignment.bottomCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: FadeTransition(
              opacity: _controller,
              child: SlideTransition(
                position: _controller.drive(
                  Tween<Offset>(
                    begin: Offset(0, (top ? -_kNoticeRise : _kNoticeRise) / 56),
                    end: Offset.zero,
                  ).chain(CurveTween(curve: JamCurve.standard)),
                ),
                child: JamNoticeCard(
                  notice: widget.notice,
                  onAction: () {
                    widget.notice.onAction?.call();
                    dismiss();
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Shows [notice] above everything, including modal sheets and dialogs,
/// with the glyph its [JamNotice.tone] calls for.
///
/// Returns null only when there is no overlay to draw into — a bare widget
/// with no `Navigator` above it.
JamNoticeHandle? showJamNotice(
  BuildContext context,
  JamNotice notice, {
  Duration duration = kJamNoticeDuration,
  EdgeInsets? margin,
  JamNoticePosition position = JamNoticePosition.bottom,
}) {
  // Root, not nearest: the nearest overlay inside a modal route is the one
  // the route itself lives in, and an entry there would be clipped by it.
  final overlay =
      Navigator.maybeOf(context, rootNavigator: true)?.overlay ??
      Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return null;
  return _JamNoticeHost.of(overlay).show(
    notice: notice,
    duration: duration,
    margin: margin ?? kJamNoticeMargin,
    position: position,
  );
}
