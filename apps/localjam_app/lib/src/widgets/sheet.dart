/// iOS sheets (DESIGN_SPEC v3 §5 Sheets).
///
/// A 36×5 grabber, a header row (centred headline title, optional leading
/// Cancel / trailing Done text buttons or a glass xmark), medium (~50%) and
/// large detents, drag to dismiss. Ground: `elevated`, or for sheets that host
/// grouped rows `elevatedGroupedBackground` with `elevatedGroupedSurface`
/// rows. Top radius [JamRadius.sheet]; no shadow.
///
/// Also the one piece of plumbing a hand-rolled sheet gets wrong: a way for
/// reorderable content to stop the sheet dragging itself away while a row is
/// in the air ([JamSheetDragLock]).
library;

import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' show showModalBottomSheet;

import '../design/tokens.dart';
import '../design/typography.dart';
import 'glass.dart';
import 'list.dart';
import 'section.dart';

/// Strings the sheet chrome says.
abstract final class JamSheetStrings {
  static const String close = 'Close';
  static const String cancel = 'Cancel';
  static const String done = 'Done';
}

/// The medium detent.
const double kJamSheetMediumSize = 0.5;

/// The large detent (clamped under the status bar by [jamSheetMaxExtent]).
const double kJamSheetLargeSize = 1.0;

/// Default open height for a content sheet.
const double kJamSheetInitialSize = kJamSheetLargeSize;

/// Default ceiling for a content sheet.
const double kJamSheetMaxSize = kJamSheetLargeSize;

/// Default floor before a flung sheet dismisses.
const double kJamSheetMinSize = 0.25;

/// How much of the page behind a fully dragged sheet stays visible below the
/// status bar.
const double kJamSheetTopInset = 10;

/// The largest fraction of [availableHeight] a sheet may take before its top
/// edge climbs into the status bar.
double jamSheetMaxExtent(double availableHeight, double preferred) {
  if (availableHeight <= kJamSheetTopInset) return preferred;
  final ceiling = (availableHeight - kJamSheetTopInset) / availableHeight;
  return preferred < ceiling ? preferred : ceiling;
}

/// A [DraggableScrollableSheet] clamped by [jamSheetMaxExtent], snapping to
/// the medium detent when it lies between [minChildSize] and the max.
Widget buildJamDraggableSheet({
  required double initialChildSize,
  required double maxChildSize,
  required double minChildSize,
  required ScrollableWidgetBuilder builder,
}) => LayoutBuilder(
  builder: (context, constraints) {
    final max = jamSheetMaxExtent(constraints.maxHeight, maxChildSize);
    final min = minChildSize.clamp(0.0, max).toDouble();
    final initial = initialChildSize.clamp(0.05, max).toDouble();
    final medium = kJamSheetMediumSize;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: initial,
      maxChildSize: max,
      minChildSize: min,
      snap: true,
      snapSizes: medium > min && medium < max ? [medium] : null,
      builder: builder,
    );
  },
);

/// Counts the reasons a sheet must not drag right now (a reorder in
/// progress). Counted, so two holders cannot unlock each other.
class JamSheetDragLock extends ChangeNotifier {
  int _holders = 0;

  /// Whether something is holding the sheet still.
  bool get isLocked => _holders > 0;

  /// Take a hold. Pair every call with exactly one [unlock].
  void lock() {
    _holders++;
    if (_holders == 1) notifyListeners();
  }

  /// Release a hold. Extra releases are ignored.
  void unlock() {
    if (_holders == 0) return;
    _holders--;
    if (_holders == 0) notifyListeners();
  }

  /// The lock for the enclosing [JamSheetScaffold], or null outside a sheet.
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
/// Content that scrolls must hand it to its own scroll view.
class JamSheetScrollController extends InheritedWidget {
  const JamSheetScrollController({
    super.key,
    required this.controller,
    required super.child,
  });

  final ScrollController? controller;

  static ScrollController? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<JamSheetScrollController>()
      ?.controller;

  @override
  bool updateShouldNotify(JamSheetScrollController old) =>
      old.controller != controller;
}

/// The 36×5 grabber in `tertiaryLabel` (or [color]).
class JamSheetGrabber extends StatelessWidget {
  const JamSheetGrabber({super.key, this.color});

  final Color? color;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Padding(
      padding: const EdgeInsets.only(top: 5),
      child: Center(
        child: Container(
          width: JamMetrics.grabber.width,
          height: JamMetrics.grabber.height,
          decoration: ShapeDecoration(
            color: color ?? context.jamColors.tertiaryLabel,
            shape: const StadiumBorder(),
          ),
        ),
      ),
    ),
  );
}

/// The round glass xmark that closes a sheet.
class JamSheetCloseButton extends StatelessWidget {
  const JamSheetCloseButton({super.key, this.onPressed});

  /// Defaults to popping the sheet's route.
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => JamGlassButton(
    icon: CupertinoIcons.xmark,
    semanticLabel: JamSheetStrings.close,
    visualSize: 30,
    iconSize: 14,
    iconColor: context.jamColors.secondaryLabel,
    onPressed: onPressed ?? () => Navigator.of(context).maybePop(),
  );
}

/// A sheet's header row: [leading] left, centred headline [title],
/// [trailing] right; a hairline under it once [scrolledUnder].
class JamSheetHeader extends StatelessWidget {
  const JamSheetHeader({
    super.key,
    required this.title,
    this.leading,
    this.trailing,
    this.scrolledUnder = false,
  });

  final String title;

  /// "Cancel" (`JamTextButton`), usually.
  final Widget? leading;

  /// "Done" (`JamTextButton(bold: true)`) or `JamSheetCloseButton`.
  final Widget? trailing;

  /// Shows the hairline (content is scrolled under the header).
  final bool scrolledUnder;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 52,
          child: NavigationToolbar(
            leading: leading == null
                ? null
                : Padding(
                    padding: const EdgeInsetsDirectional.only(
                      start: JamSpace.sm,
                    ),
                    child: leading,
                  ),
            trailing: trailing == null
                ? null
                : Padding(
                    padding: const EdgeInsetsDirectional.only(end: JamSpace.sm),
                    child: trailing,
                  ),
            middle: Semantics(
              header: true,
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.jamHeadline,
              ),
            ),
            middleSpacing: JamSpace.sm,
          ),
        ),
        AnimatedOpacity(
          opacity: scrolledUnder ? 1 : 0,
          duration: JamDuration.fast,
          child: JamHairline(color: colors.separator),
        ),
      ],
    );
  }
}

/// The inside of a sheet: grabber, header, content, and the drag lock.
/// Sections inside use `elevatedGroupedSurface` rows. Usable outside a modal
/// (the docked side panel on desktop).
class JamSheetScaffold extends StatefulWidget {
  const JamSheetScaffold({
    super.key,
    this.title,
    this.leading,
    this.trailing,
    this.header,
    required this.child,
    this.scrollController,
    this.showHandle = true,
    this.dragLock,
  });

  /// Title for the default [JamSheetHeader]. Ignored when [header] is given.
  final String? title;

  /// Leading action for the default header.
  final Widget? leading;

  /// Trailing action for the default header.
  final Widget? trailing;

  /// A header of your own, replacing the default one entirely.
  final Widget? header;

  /// The content. Fills the remaining height when [scrollController] is set.
  final Widget child;

  /// The controller a scrollable sheet drives its extent from.
  final ScrollController? scrollController;

  /// Draws the grabber.
  final bool showHandle;

  /// A caller-owned lock; one is created when omitted.
  final JamSheetDragLock? dragLock;

  @override
  State<JamSheetScaffold> createState() => _JamSheetScaffoldState();
}

class _JamSheetScaffoldState extends State<JamSheetScaffold> {
  JamSheetDragLock? _owned;
  bool _scrolledUnder = false;

  JamSheetDragLock get _lock =>
      widget.dragLock ?? (_owned ??= JamSheetDragLock());

  @override
  void dispose() {
    _owned?.dispose();
    super.dispose();
  }

  bool _onScroll(ScrollNotification n) {
    if (n.metrics.axis != Axis.vertical) return false;
    final under = n.metrics.pixels > n.metrics.minScrollExtent + 0.5;
    if (under != _scrolledUnder) setState(() => _scrolledUnder = under);
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final scrollController = widget.scrollController;
    final header =
        widget.header ??
        (widget.title == null
            ? null
            : JamSheetHeader(
                title: widget.title!,
                leading: widget.leading,
                trailing: widget.trailing,
                scrolledUnder: _scrolledUnder,
              ));

    final content = NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: JamGroupedSurface(elevated: true, child: widget.child),
    );

    final column = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.showHandle) const JamSheetGrabber(),
        ?header,
        if (scrollController == null)
          Flexible(child: content)
        else
          Expanded(child: content),
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

/// The sheet's ground: `elevated` (or the grouped sheet ground), top radius
/// [JamRadius.sheet], clipped.
class JamSheetSurface extends StatelessWidget {
  const JamSheetSurface({super.key, required this.child, this.grouped = false});

  final Widget child;

  /// `elevatedGroupedBackground` instead of `elevated`.
  final bool grouped;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(
        top: Radius.circular(JamRadius.sheet),
      ),
      child: ColoredBox(
        color: grouped ? colors.elevatedGroupedBackground : colors.elevated,
        child: child,
      ),
    );
  }
}

/// Opens a LocalJam sheet.
///
/// [builder] is built inside the sheet, under a [JamSheetScrollController]
/// the content attaches its scroll view to when [scrollable].
///
/// [initialChildSize]: [kJamSheetLargeSize] (default) or
/// [kJamSheetMediumSize]. [grouped] uses the grouped sheet ground for
/// content built from `JamSection`s. Content that is *sometimes* dragging (a
/// reorderable queue) takes a [JamSheetDragLock] on pick-up.
Future<T?> showJamSheet<T>(
  BuildContext context, {
  required String title,
  Widget? leading,
  Widget? trailing,
  required WidgetBuilder builder,
  double initialChildSize = kJamSheetInitialSize,
  double maxChildSize = kJamSheetMaxSize,
  double minChildSize = kJamSheetMinSize,
  bool scrollable = true,
  bool enableDrag = true,
  bool isDismissible = true,
  bool grouped = false,
  RouteSettings? routeSettings,
}) {
  final colors = context.jamColors;
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    enableDrag: enableDrag,
    isDismissible: isDismissible,
    routeSettings: routeSettings,
    barrierColor: colors.scrim,
    backgroundColor: const Color(0x00000000),
    elevation: 0,
    showDragHandle: false,
    constraints: const BoxConstraints(maxWidth: 640),
    builder: (context) {
      final content = Builder(builder: builder);
      if (!scrollable) {
        return JamSheetSurface(
          grouped: grouped,
          child: SafeArea(
            top: false,
            child: JamSheetScaffold(
              title: title,
              leading: leading,
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
        builder: (context, scrollController) => JamSheetSurface(
          grouped: grouped,
          child: JamSheetScaffold(
            title: title,
            leading: leading,
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
