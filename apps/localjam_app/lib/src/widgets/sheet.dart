/// Modal sheets, in one place.
///
/// Queue, People, Diagnostics and the library picker all reached for
/// `showModalBottomSheet` and then each re-invented the same header: a title,
/// an action, a rule underneath. This is that header, plus the sheet around
/// it, plus the one piece of plumbing a hand-rolled sheet always gets wrong —
/// a way for reorderable content to stop the sheet from dragging itself off
/// the screen while a row is in the air.
///
/// Sizes come from §4 of the design spec: `surfaceElevated`, a top radius of
/// [JamRadius.xl], the `overlay` shadow, a 36×4 handle, and a header padded
/// 20/12/16/12 over a 0.5 dp rule.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../design/tokens.dart';
import '../design/typography.dart';

/// Default open height for a content sheet (Queue, People).
const double kJamSheetInitialSize = 0.82;

/// Default ceiling for a content sheet.
const double kJamSheetMaxSize = 0.96;

/// Default floor before a flung sheet dismisses.
const double kJamSheetMinSize = 0.32;

/// How much of the status bar a fully dragged sheet leaves showing.
///
/// `useSafeArea` already stops the sheet at the bottom of the status bar; ten
/// dp more is what keeps the grabber clear of the clock rather than tucked
/// under it, and it is what says "there is a screen behind this".
const double kJamSheetTopInset = 10;

/// The largest fraction of [availableHeight] a sheet may take before its top
/// edge starts climbing into the status bar.
///
/// [availableHeight] is the height a [DraggableScrollableSheet] is given —
/// under `useSafeArea` that is the window minus the top inset — so the only
/// thing left to reserve is [kJamSheetTopInset].
double jamSheetMaxExtent(double availableHeight, double preferred) {
  if (availableHeight <= kJamSheetTopInset) return preferred;
  final ceiling = (availableHeight - kJamSheetTopInset) / availableHeight;
  return preferred < ceiling ? preferred : ceiling;
}

/// Builds a [DraggableScrollableSheet] whose extents are already clamped to
/// [jamSheetMaxExtent], so no sheet in the app can slide under the clock.
///
/// Shared with `room_sheet.dart`, which builds its own surface because its
/// title counts the people in the room and has to stay live.
Widget buildJamDraggableSheet({
  required double initialChildSize,
  required double maxChildSize,
  required double minChildSize,
  required ScrollableWidgetBuilder builder,
}) => LayoutBuilder(
  builder: (context, constraints) {
    final max = jamSheetMaxExtent(constraints.maxHeight, maxChildSize);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: initialChildSize.clamp(0.05, max),
      maxChildSize: max,
      minChildSize: minChildSize.clamp(0.0, max),
      snap: true,
      builder: builder,
    );
  },
);

/// Height of the fade that carries content under a sheet's header rule.
///
/// Without it a scrolled row is sliced clean in half by the hairline, which
/// reads as a rendering fault rather than as "there is more above". Twelve
/// logical pixels is enough for the eye to read a dissolve and short enough
/// that a stationary list looks untouched.
const double kJamSheetHeaderFade = 12;

/// Counts the reasons a sheet must not drag right now.
///
/// A `ReorderableListView` inside a modal sheet is two vertical drags fighting
/// over one finger: on Android, picking a queue row up and moving it drags the
/// whole sheet down instead. The list takes a lock while a row is in the air
/// and releases it on drop, and the sheet swallows its own drag for as long as
/// the count is above zero.
///
/// Counted rather than boolean so two independent children (a reorderable list
/// and a scrubbing slider, say) cannot unlock each other.
class JamSheetDragLock extends ChangeNotifier {
  int _holders = 0;

  /// Whether something is currently holding the sheet still.
  bool get isLocked => _holders > 0;

  /// Take a hold. Pair every call with exactly one [unlock].
  void lock() {
    _holders++;
    if (_holders == 1) notifyListeners();
  }

  /// Release a hold taken with [lock]. Extra releases are ignored rather than
  /// throwing: a drag cancelled by a route change should not crash the app.
  void unlock() {
    if (_holders == 0) return;
    _holders--;
    if (_holders == 0) notifyListeners();
  }

  /// The lock for the enclosing [JamSheetScaffold], if there is one.
  ///
  /// Returns null outside a sheet, which is what lets the same list widget be
  /// used inside a sheet and on a full page without branching.
  static JamSheetDragLock? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<_JamSheetDragScope>()
      ?.notifier;
}

class _JamSheetDragScope extends InheritedNotifier<JamSheetDragLock> {
  const _JamSheetDragScope({
    required JamSheetDragLock super.notifier,
    required super.child,
  });
}

/// Exposes the scroll controller a scrollable sheet drives its extent from.
///
/// Content that scrolls must hand this to its own `ListView`/`CustomScrollView`
/// or the sheet will not grow when the list is flung.
class JamSheetScrollController extends InheritedWidget {
  const JamSheetScrollController({
    super.key,
    required this.controller,
    required super.child,
  });

  /// The sheet's controller, or null when the sheet is not scrollable.
  final ScrollController? controller;

  /// The enclosing sheet's scroll controller, or null when there is none.
  static ScrollController? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<JamSheetScrollController>()
      ?.controller;

  @override
  bool updateShouldNotify(JamSheetScrollController old) =>
      old.controller != controller;
}

/// A sheet's title bar: title left, one action right, a hairline underneath.
class JamSheetHeader extends StatelessWidget {
  const JamSheetHeader({super.key, required this.title, this.trailing});

  /// The sheet's title, in `jamSheetTitle`.
  final String title;

  /// One optional action, right-aligned. A tertiary button, a count, a chip —
  /// never a row of three.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            JamSpace.xl,
            JamSpace.md,
            JamSpace.lg,
            JamSpace.md,
          ),
          child: Row(
            children: [
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(
                    title,
                    style: context.jamSheetTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              ?trailing,
            ],
          ),
        ),
        Divider(height: 0.5, thickness: 0.5, color: colors.separator),
      ],
    );
  }
}

/// The inside of a sheet: handle, header, content — and the drag lock.
///
/// Usable on its own for content that is not presented modally (the docked
/// side panel on desktop reuses it), which is why it is a widget rather than
/// something [showJamSheet] builds inline.
class JamSheetScaffold extends StatefulWidget {
  const JamSheetScaffold({
    super.key,
    this.title,
    this.trailing,
    this.header,
    required this.child,
    this.scrollController,
    this.showHandle = true,
    this.dragLock,
  });

  /// Title for the default [JamSheetHeader]. Ignored when [header] is given.
  final String? title;

  /// Trailing action for the default header.
  final Widget? trailing;

  /// A header of your own, replacing the default one entirely.
  final Widget? header;

  /// The sheet's content. Fills the remaining height when [scrollController]
  /// is non-null, and sizes itself otherwise.
  final Widget child;

  /// The controller a scrollable sheet drives its extent from. Published to
  /// descendants through [JamSheetScrollController].
  final ScrollController? scrollController;

  /// Whether to draw the 36×4 grab handle.
  final bool showHandle;

  /// A lock owned by the caller. One is created here when omitted, which is
  /// the usual case.
  final JamSheetDragLock? dragLock;

  @override
  State<JamSheetScaffold> createState() => _JamSheetScaffoldState();
}

class _JamSheetScaffoldState extends State<JamSheetScaffold> {
  JamSheetDragLock? _owned;

  /// Only content that actually passes under a header needs the dissolve.
  Widget _faded(bool hasHeader, Widget child) =>
      hasHeader ? JamSheetHeaderFade(child: child) : child;

  JamSheetDragLock get _lock =>
      widget.dragLock ?? (_owned ??= JamSheetDragLock());

  @override
  void dispose() {
    _owned?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final scrollController = widget.scrollController;
    final header =
        widget.header ??
        (widget.title == null
            ? null
            : JamSheetHeader(title: widget.title!, trailing: widget.trailing));

    final column = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.showHandle)
          Padding(
            padding: const EdgeInsets.only(top: JamSpace.sm),
            child: Center(
              child: ExcludeSemantics(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: colors.textTertiary.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(JamRadius.pill),
                  ),
                ),
              ),
            ),
          ),
        ?header,
        if (scrollController == null)
          Flexible(child: _faded(header != null, widget.child))
        else
          Expanded(child: _faded(header != null, widget.child)),
      ],
    );

    return JamSheetScrollController(
      controller: scrollController,
      child: _JamSheetDragScope(
        notifier: _lock,
        child: JamSheetDragGuard(lock: _lock, child: column),
      ),
    );
  }
}

/// Swallows vertical drags while a [JamSheetDragLock] is held.
///
/// A descendant recognizer joins the gesture arena ahead of the modal route's
/// own, so accepting here is what keeps a reorder drag from becoming a sheet
/// dismissal. When unlocked this adds no recognizer at all and costs nothing.
class JamSheetDragGuard extends StatelessWidget {
  const JamSheetDragGuard({super.key, required this.lock, required this.child});

  /// Identifies the swallowing recognizer, which exists only while locked.
  static const Key blockerKey = Key('jam-sheet-drag-blocker');

  final JamSheetDragLock lock;
  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: lock,
    builder: (context, child) => lock.isLocked
        ? RawGestureDetector(
            key: blockerKey,
            behavior: HitTestBehavior.translucent,
            gestures: <Type, GestureRecognizerFactory>{
              VerticalDragGestureRecognizer:
                  GestureRecognizerFactoryWithHandlers<
                    VerticalDragGestureRecognizer
                  >(
                    VerticalDragGestureRecognizer.new,
                    (recognizer) => recognizer
                      ..onStart = _swallow
                      ..onUpdate = _swallow
                      ..onEnd = _swallow,
                  ),
            },
            child: child,
          )
        : child!,
    child: child,
  );

  static void _swallow(Object? _) {}
}

/// Content under a [kJamSheetHeaderFade] dissolve, so nothing is sliced by
/// the header's hairline on the way past it.
class JamSheetHeaderFade extends StatelessWidget {
  const JamSheetHeaderFade({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    // `child` is the Stack's only unpositioned child, so the Stack takes its
    // size — the dissolve must not turn a min-height sheet into a zero one.
    return Stack(
      // Passthrough, not loose: the content must keep the exact constraints
      // it had before the fade was slipped over it.
      fit: StackFit.passthrough,
      children: [
        child,
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: kJamSheetHeaderFade,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    colors.surfaceElevated,
                    colors.surfaceElevated.withValues(alpha: 0),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Opens a LocalJam modal sheet.
///
/// [builder] is built inside the sheet, under a [JamSheetScrollController] the
/// content should attach its scroll view to when [scrollable] is true.
///
/// [enableDrag] turns the sheet's drag-to-dismiss off for the whole life of
/// the route — pass false only for a sheet whose content is one big gesture
/// surface. For content that is *sometimes* dragging (a reorderable queue),
/// leave it on and have the child take a [JamSheetDragLock] on pick-up:
///
/// ```dart
/// onReorderStart: (_) => JamSheetDragLock.maybeOf(context)?.lock(),
/// onReorderEnd: (_) => JamSheetDragLock.maybeOf(context)?.unlock(),
/// ```
Future<T?> showJamSheet<T>(
  BuildContext context, {
  required String title,
  Widget? trailing,
  required WidgetBuilder builder,
  double initialChildSize = kJamSheetInitialSize,
  double maxChildSize = kJamSheetMaxSize,
  double minChildSize = kJamSheetMinSize,
  bool scrollable = true,
  bool enableDrag = true,
  bool isDismissible = true,
  RouteSettings? routeSettings,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    // Without it the sheet's own 0.96 is 0.96 of the *window*, which on a
    // notched phone puts its top edge — grabber and all — behind the clock.
    useSafeArea: true,
    enableDrag: enableDrag,
    isDismissible: isDismissible,
    routeSettings: routeSettings,
    // The shadow and the fill are painted by [_JamSheetSurface] so the
    // `overlay` shadow lands outside the sheet's own clip.
    backgroundColor: Colors.transparent,
    elevation: 0,
    showDragHandle: false,
    constraints: const BoxConstraints(maxWidth: 640),
    builder: (context) {
      final content = Builder(builder: builder);
      if (!scrollable) {
        return _JamSheetSurface(
          child: SafeArea(
            top: false,
            child: JamSheetScaffold(
              title: title,
              trailing: trailing,
              showHandle: enableDrag,
              child: content,
            ),
          ),
        );
      }
      return buildJamDraggableSheet(
        initialChildSize: initialChildSize,
        maxChildSize: maxChildSize,
        minChildSize: minChildSize,
        builder: (context, scrollController) => _JamSheetSurface(
          child: JamSheetScaffold(
            title: title,
            trailing: trailing,
            showHandle: enableDrag,
            scrollController: scrollController,
            child: content,
          ),
        ),
      );
    },
  );
}

/// The sheet's ground: `surfaceElevated`, top radius `xl`, `overlay` shadow.
class _JamSheetSurface extends StatelessWidget {
  const _JamSheetSurface({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    const radius = BorderRadius.vertical(top: Radius.circular(JamRadius.xl));
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceElevated,
        borderRadius: radius,
        boxShadow: JamShadow.overlay(colors),
      ),
      child: Material(
        color: Colors.transparent,
        clipBehavior: Clip.antiAlias,
        shape: const RoundedRectangleBorder(borderRadius: radius),
        child: child,
      ),
    );
  }
}
