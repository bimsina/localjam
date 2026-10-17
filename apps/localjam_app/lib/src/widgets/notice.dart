/// The one way the app says something happened.
///
/// [JamSessionController.notices] is a single channel and the router shell is
/// the single subscriber; this is the single *look*. Floating, radius `md`,
/// a `textPrimary` ground with `canvas` text (so it reads as a piece of the
/// chrome speaking rather than a page element), a 20 dp status glyph, and at
/// most one action.
///
/// It is hosted in the **root navigator's overlay**, not in a
/// `ScaffoldMessenger`. A messenger's snackbar is a child of the messenger's
/// own subtree, which sits *below* every modal route — so "Room code copied",
/// raised from inside the People sheet, was painted behind the sheet and
/// nobody ever saw it. An `OverlayEntry` on the root overlay is above modal
/// routes by construction, and it keeps the messenger's semantics: one at a
/// time, four seconds, at most one action.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../design/tokens.dart';
import '../state/session_controller.dart';

export '../state/session_controller.dart' show JamNotice;

/// How loud a notice is. Only two tints exist by design — apricot for "you
/// should know", red for "that did not work" — because a snackbar that can be
/// five colours stops carrying meaning.
enum JamNoticeKind {
  /// Something happened and it was fine. "Ana joined."
  info,

  /// Something needs attention but nothing broke. A permission was declined,
  /// a file was skipped.
  warning,

  /// An action failed. Usually paired with a retry action.
  error,
}

/// How long a notice stays up before it goes on its own.
const Duration kJamNoticeDuration = Duration(seconds: 4);

/// The default distance a notice keeps from the edges it floats over.
const EdgeInsets kJamNoticeMargin = EdgeInsets.all(JamSpace.lg);

/// How far a notice rises as it arrives.
const double _kNoticeRise = 24;

extension on JamNoticeKind {
  IconData get glyph => switch (this) {
    JamNoticeKind.info => Icons.info_rounded,
    JamNoticeKind.warning => Icons.error_outline_rounded,
    JamNoticeKind.error => Icons.error_rounded,
  };

  Color tint(JamColors colors) => switch (this) {
    JamNoticeKind.info || JamNoticeKind.warning => colors.highlight,
    JamNoticeKind.error => colors.danger,
  };

  String get semanticPrefix => switch (this) {
    JamNoticeKind.info => '',
    JamNoticeKind.warning => 'Warning. ',
    JamNoticeKind.error => 'Error. ',
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
    this.kind = JamNoticeKind.info,
  });

  final String message;
  final JamNoticeKind kind;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final style =
        Theme.of(context).snackBarTheme.contentTextStyle ??
        Theme.of(context).textTheme.bodyMedium!.copyWith(color: colors.canvas);

    return Semantics(
      liveRegion: true,
      label: '${kind.semanticPrefix}$message',
      excludeSemantics: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(kind.glyph, size: 20, color: kind.tint(colors)),
          const SizedBox(width: JamSpace.md),
          Expanded(
            child: Text(
              message,
              style: style,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// The whole floating card: the ground, the body, and at most one action.
///
/// Separate from the overlay plumbing so a test — or a wide layout that wants
/// a docked banner — can render exactly what the app shows without an
/// `Overlay` in the tree.
class JamNoticeCard extends StatelessWidget {
  const JamNoticeCard({
    super.key,
    required this.notice,
    this.kind = JamNoticeKind.info,
    this.onAction,
  });

  final JamNotice notice;
  final JamNoticeKind kind;

  /// Wraps [JamNotice.onAction] so the host can dismiss itself on the way.
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final label = notice.actionLabel;
    final action = onAction ?? notice.onAction;

    return Material(
      color: colors.textPrimary,
      borderRadius: BorderRadius.circular(JamRadius.md),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          JamSpace.lg,
          JamSpace.md,
          JamSpace.sm,
          JamSpace.md,
        ),
        child: Row(
          children: [
            Expanded(
              child: JamNoticeBody(message: notice.message, kind: kind),
            ),
            if (label != null && notice.onAction != null)
              Padding(
                padding: const EdgeInsets.only(left: JamSpace.sm),
                child: TextButton(
                  onPressed: action,
                  style: TextButton.styleFrom(
                    foregroundColor: colors.highlight,
                    minimumSize: const Size(44, 44),
                  ),
                  child: Text(label),
                ),
              )
            else
              const SizedBox(width: JamSpace.sm),
          ],
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
    required JamNoticeKind kind,
    required Duration duration,
    required EdgeInsets margin,
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
        kind: kind,
        duration: duration,
        margin: margin,
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
    required this.kind,
    required this.duration,
    required this.margin,
    required this.onDismissed,
  });

  final JamNotice notice;
  final JamNoticeKind kind;
  final Duration duration;
  final EdgeInsets margin;
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
    final colors = context.jamColors;
    // The overlay is the window, so the notice clears the home indicator
    // itself; the caller's margin is what it keeps clear *on top of* that.
    return SafeArea(
      child: Padding(
        padding: widget.margin,
        child: Align(
          alignment: Alignment.bottomCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: FadeTransition(
              opacity: _controller,
              child: SlideTransition(
                position: _controller.drive(
                  Tween<Offset>(
                    begin: const Offset(0, _kNoticeRise / 56),
                    end: Offset.zero,
                  ).chain(CurveTween(curve: JamCurve.base)),
                ),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(JamRadius.md),
                    boxShadow: JamShadow.floating(colors),
                  ),
                  child: JamNoticeCard(
                    notice: widget.notice,
                    kind: widget.kind,
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
      ),
    );
  }
}

/// Shows [notice] above everything, including modal sheets and dialogs.
///
/// Returns null only when there is no overlay to draw into — a bare widget
/// with no `Navigator` above it.
JamNoticeHandle? showJamNotice(
  BuildContext context,
  JamNotice notice, {
  JamNoticeKind kind = JamNoticeKind.info,
  Duration duration = kJamNoticeDuration,
  EdgeInsets? margin,
}) {
  // Root, not nearest: the nearest overlay inside a modal route is the one
  // the route itself lives in, and an entry there would be clipped by it.
  final overlay =
      Navigator.maybeOf(context, rootNavigator: true)?.overlay ??
      Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return null;
  return _JamNoticeHost.of(overlay).show(
    notice: notice,
    kind: kind,
    duration: duration,
    margin: margin ?? kJamNoticeMargin,
  );
}
