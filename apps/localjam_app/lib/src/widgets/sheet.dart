/// iOS sheets (DESIGN_SPEC v3 §5 Sheets, as amended by §10.2–§10.4).
///
/// **One mechanism.** Every content sheet — People, Invite, Sound Offset,
/// Diagnostics, the library picker, the permission primers — is a
/// [JamSheetRoute]: a 36×5 grabber, a header row, medium (~50%) and large
/// detents, drag to dismiss. How it sits follows iOS 26:
///
/// - at the **medium** detent (and for any sheet sized to its content) it
///   *floats*: inset [JamRadius.sheetFloatingInset] from the window's sides
///   and bottom, all four corners [JamRadius.sheetFloating];
/// - at the **large** detent it is edge-attached with its top corners at
///   [JamRadius.sheet] (the device's corner) and the page behind *recedes* —
///   scales back under the status bar, the way a page sheet stacks;
/// - on a **wide** window (both sides ≥ [kJamFormSheetBreakpoint]) it is a
///   centred *form sheet*, at most [kJamFormSheetMaxSize], all corners
///   rounded, no grabber, nothing receding.
///
/// Start a Jam is a task flow, not a content sheet: on phones it is an iOS
/// page sheet (`CupertinoSheetRoute`, the same recede); on wide windows it
/// is the same centred form sheet as everything else ([JamFormSheetPage]).
///
/// **The header rule (§10.2).** The leading slot holds *Cancel* — only when
/// the sheet edits something — or nothing. The trailing slot holds the
/// sheet's action verb (Start, Join) or, for every other sheet, **Done** —
/// one way to close a sheet, wherever it was opened from (CR-24): a sheet
/// that only shows something (Invite, Diagnostics) closes with the same
/// trailing Done as one that applies its changes as they are made (People,
/// Sound Offset), never an xmark in one and a word in the next. Anything
/// else — Copy, Reset — lives in the content, not the header.
/// [JamSheetActions] can only say legal things, and is the only way to fill
/// the slots: pass one to [showJamSheet], [JamSheetScaffold] or
/// [JamSheetHeader].
///
/// Ground: `elevated`, or for sheets that host grouped rows
/// `elevatedGroupedBackground` with `elevatedGroupedSurface` rows. No
/// shadow.
///
/// Also the one piece of plumbing a hand-rolled sheet gets wrong: a way for
/// reorderable content to stop the sheet dragging itself away while a row is
/// in the air ([JamSheetDragLock]).
library;

import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../design/theme.dart';
import '../design/tokens.dart';
import '../design/typography.dart';
import 'buttons.dart';
import 'list.dart';
import 'progress.dart';
import 'section.dart';

/// Strings the sheet chrome says.
abstract final class JamSheetStrings {
  static const String cancel = 'Cancel';
  static const String done = 'Done';
  static const String dismiss = 'Dismiss';
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

/// The shorter window side from which sheets become centred form sheets
/// (spec §10.4: "wide layouts, ≥ 700 pt"). Both sides must reach it, so a
/// phone on its side keeps phone sheets.
const double kJamFormSheetBreakpoint = 700;

/// The largest a form sheet gets (spec §10.4).
const Size kJamFormSheetMaxSize = Size(540, 620);

/// A phone-style sheet never grows wider than this (a medium window).
const double _kPhoneSheetMaxWidth = 640;

/// Whether sheets presented from [context] are centred form sheets.
bool jamUsesFormSheet(BuildContext context) {
  final size = MediaQuery.sizeOf(context);
  return size.width >= kJamFormSheetBreakpoint &&
      size.height >= kJamFormSheetBreakpoint;
}

/// How many [JamSheetRoute]s are on screen. The notice host reads it: a
/// notice raised while a sheet is open goes to the top of the window, never
/// over the sheet's content (spec §10.5).
final ValueNotifier<int> jamOpenSheets = ValueNotifier<int>(0);

/// The largest fraction of [availableHeight] a sheet may take before its top
/// edge climbs into the status bar.
double jamSheetMaxExtent(double availableHeight, double preferred) {
  if (availableHeight <= kJamSheetTopInset) return preferred;
  final ceiling = (availableHeight - kJamSheetTopInset) / availableHeight;
  return preferred < ceiling ? preferred : ceiling;
}

/// What a sheet's insides know about how it is being presented.
class _JamSheetGeometry extends InheritedWidget {
  const _JamSheetGeometry({
    required this.form,
    required this.available,
    required this.onLargeness,
    required super.child,
  });

  /// A centred form sheet (wide windows).
  final bool form;

  /// The height a sheet may grow to: under the status bar on a phone, the
  /// form sheet's own height on a wide window.
  final double available;

  /// Told how far between the medium and large detents the sheet is (0–1).
  final ValueChanged<double>? onLargeness;

  static _JamSheetGeometry? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_JamSheetGeometry>();

  @override
  bool updateShouldNotify(_JamSheetGeometry old) =>
      old.form != form || old.available != available;
}

/// A [DraggableScrollableSheet] clamped by [jamSheetMaxExtent], snapping to
/// the medium detent when it lies between [minChildSize] and the max. In a
/// form sheet there are no detents: the content fills the card.
Widget buildJamDraggableSheet({
  required double initialChildSize,
  required double maxChildSize,
  required double minChildSize,
  required ScrollableWidgetBuilder builder,
}) => Builder(
  builder: (context) {
    final geometry = _JamSheetGeometry.maybeOf(context);
    if (geometry != null && geometry.form) {
      return SizedBox(
        height: geometry.available,
        child: _JamFixedSheet(builder: builder),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final max = jamSheetMaxExtent(constraints.maxHeight, maxChildSize);
        final min = minChildSize.clamp(0.0, max).toDouble();
        final initial = initialChildSize.clamp(0.05, max).toDouble();
        const medium = kJamSheetMediumSize;
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: initial,
          maxChildSize: max,
          minChildSize: min,
          snap: true,
          snapSizes: medium > min && medium < max ? const [medium] : null,
          builder: builder,
        );
      },
    );
  },
);

/// A scrollable sheet's content at a fixed height, with a controller of its
/// own (the form sheet has no extent for one to drive).
class _JamFixedSheet extends StatefulWidget {
  const _JamFixedSheet({required this.builder});

  final ScrollableWidgetBuilder builder;

  @override
  State<_JamFixedSheet> createState() => _JamFixedSheetState();
}

class _JamFixedSheetState extends State<_JamFixedSheet> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _controller);
}

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

enum _JamSheetActionKind { done, confirm }

/// The only header layouts a sheet may have (spec §10.2).
///
/// - [JamSheetActions.done]: every sheet that does not commit with a verb
///   — one that only shows something (Invite, Diagnostics) and one whose
///   changes apply as they are made (People, Sound Offset) alike: a
///   trailing semibold **Done**, never an xmark (CR-24); add [showCancel]
///   only when Done commits something Cancel would throw away.
/// - [JamSheetActions.confirm]: a sheet that edits and then commits with a
///   verb (Start, Join, Add): leading **Cancel**, trailing semibold verb.
///
/// Secondary actions (Copy, Reset) belong in the content.
@immutable
class JamSheetActions {
  /// A trailing semibold **Done** ([label]). [onDone] defaults to popping
  /// the sheet.
  const JamSheetActions.done({
    VoidCallback? onDone,
    this.label = JamSheetStrings.done,
    this.showCancel = false,
    this.onCancel,
  }) : _kind = _JamSheetActionKind.done,
       onConfirm = onDone,
       busy = false,
       busyLabel = null;

  /// Leading **Cancel**, trailing semibold [label] ("Start"). A null
  /// [onConfirm] disables the verb; [busy] swaps it for a turning ring and
  /// disables Cancel (a one-way door is being walked through).
  const JamSheetActions.confirm({
    required this.label,
    required this.onConfirm,
    this.onCancel,
    this.busy = false,
    this.busyLabel,
  }) : _kind = _JamSheetActionKind.confirm,
       showCancel = true;

  final _JamSheetActionKind _kind;

  /// The trailing word.
  final String label;

  /// The trailing word's action (Done defaults to popping).
  final VoidCallback? onConfirm;

  /// Cancel's action; defaults to popping the sheet.
  final VoidCallback? onCancel;

  /// Whether the leading Cancel shows.
  final bool showCancel;

  /// The verb is running: a turning ring in its place, Cancel disabled.
  final bool busy;

  /// What the ring announces ("Starting"); defaults to [label].
  final String? busyLabel;

  /// The leading slot, or null for none.
  Widget? leading(BuildContext context) {
    if (!showCancel) return null;
    return JamTextButton(
      label: JamSheetStrings.cancel,
      onPressed: busy
          ? null
          : (onCancel ?? () => Navigator.of(context).maybePop()),
    );
  }

  /// The trailing slot.
  Widget trailing(BuildContext context) => switch (_kind) {
    _JamSheetActionKind.done => JamTextButton(
      label: label,
      bold: true,
      onPressed: onConfirm ?? () => Navigator.of(context).maybePop(),
    ),
    _JamSheetActionKind.confirm =>
      busy
          ? Semantics(
              label: busyLabel ?? label,
              liveRegion: true,
              child: const SizedBox(
                width: JamMetrics.hitTarget,
                height: JamMetrics.hitTarget,
                child: Center(
                  child: JamProgressRing(size: JamProgressRing.controlSize),
                ),
              ),
            )
          : JamTextButton(label: label, bold: true, onPressed: onConfirm),
  };
}

/// A sheet's header row: leading slot left, centred headline [title],
/// trailing slot right; a hairline under it once [scrolledUnder].
///
/// The slots come only from [actions], which can only express the header
/// rule (§10.2).
class JamSheetHeader extends StatelessWidget {
  const JamSheetHeader({
    super.key,
    required this.title,
    this.actions,
    this.scrolledUnder = false,
  });

  final String title;

  /// The header's slots, by the rule. Null: a bare title.
  final JamSheetActions? actions;

  /// Shows the hairline (content is scrolled under the header).
  final bool scrolledUnder;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final actions = this.actions;
    final leading = actions?.leading(context);
    final trailing = actions?.trailing(context);
    // The header buttons' *text* sits on the content's margin: a text
    // button carries 4 of padding inside its hit area.
    final width = MediaQuery.sizeOf(context).width;
    final inset = JamSpace.pageFor(width) - JamSpace.xs;
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
                    padding: EdgeInsetsDirectional.only(start: inset),
                    child: leading,
                  ),
            trailing: trailing == null
                ? null
                : Padding(
                    padding: EdgeInsetsDirectional.only(end: inset),
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
    this.actions,
    this.header,
    required this.child,
    this.scrollController,
    this.showHandle = true,
    this.dragLock,
  });

  /// Title for the default [JamSheetHeader]. Ignored when [header] is given.
  final String? title;

  /// The default header's slots, by the rule.
  final JamSheetActions? actions;

  /// A header of your own, replacing the default one entirely.
  final Widget? header;

  /// The content. Fills the remaining height when [scrollController] is set.
  final Widget child;

  /// The controller a scrollable sheet drives its extent from.
  final ScrollController? scrollController;

  /// Draws the grabber (never on a form sheet, which does not drag).
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
    final form = _JamSheetGeometry.maybeOf(context)?.form ?? false;
    final header =
        widget.header ??
        (widget.title == null
            ? null
            : JamSheetHeader(
                title: widget.title!,
                actions: widget.actions,
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
        if (widget.showHandle && !form)
          const JamSheetGrabber()
        else if (form)
          const SizedBox(height: JamSpace.sm),
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

/// The sheet's ground: `elevated` (or the grouped sheet ground), clipped to
/// the sheet's shape — floating with four rounded corners at the medium
/// detent, edge-attached at the large one, a rounded card on a wide window.
class JamSheetSurface extends StatelessWidget {
  const JamSheetSurface({super.key, required this.child, this.grouped = false});

  final Widget child;

  /// `elevatedGroupedBackground` instead of `elevated`.
  final bool grouped;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final ground = grouped ? colors.elevatedGroupedBackground : colors.elevated;
    final geometry = _JamSheetGeometry.maybeOf(context);
    if (geometry == null) {
      // Outside a JamSheetRoute: the edge-attached shape.
      return ClipRRect(
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(JamRadius.sheet),
        ),
        child: ColoredBox(color: ground, child: child),
      );
    }
    if (geometry.form) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(JamRadius.sheetFloating),
        child: ColoredBox(color: ground, child: child),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        // A detent sheet is laid out at a fixed fraction of the height; a
        // sheet sized to its content is not, and always floats.
        final largeness = constraints.hasTightHeight
            ? _largeness(constraints.maxHeight, geometry.available)
            : 0.0;
        final report = geometry.onLargeness;
        if (report != null) {
          SchedulerBinding.instance.addPostFrameCallback(
            (_) => report(largeness),
          );
        }
        final inset = JamRadius.sheetFloatingInset * (1 - largeness);
        final bottomRadius = JamRadius.sheetFloating * (1 - largeness);
        final media = MediaQuery.of(context);
        return Padding(
          padding: EdgeInsets.fromLTRB(inset, 0, inset, inset),
          child: ClipRRect(
            borderRadius: BorderRadius.vertical(
              top: const Radius.circular(JamRadius.sheet),
              bottom: Radius.circular(bottomRadius),
            ),
            child: ColoredBox(
              color: ground,
              child: MediaQuery(
                // The sheet's bottom already sits [inset] above the edge.
                data: media.copyWith(
                  padding: media.padding.copyWith(
                    bottom: math.max(0, media.padding.bottom - inset),
                  ),
                ),
                child: child,
              ),
            ),
          ),
        );
      },
    );
  }

  static double _largeness(double height, double available) {
    if (available <= 0) return 0;
    final fraction = height / available;
    final max = jamSheetMaxExtent(available, kJamSheetLargeSize);
    if (max <= kJamSheetMediumSize) return 0;
    return ((fraction - kJamSheetMediumSize) / (max - kJamSheetMediumSize))
        .clamp(0.0, 1.0)
        .toDouble();
  }
}

/// The route every LocalJam sheet is presented with (see the library
/// comment): detents and a floating medium shape on phones, the page behind
/// receding at the large detent, a centred form sheet on wide windows, drag
/// to dismiss, the `scrim` barrier.
///
/// A [PageRoute] rather than a popup so that the page under it — a go_router
/// page, the room — takes its [delegatedTransition] and recedes.
class JamSheetRoute<T> extends PageRoute<T> {
  JamSheetRoute({
    required this.builder,
    required this.formSheet,
    required this._barrierColor,
    this.enableDrag = true,
    this._isDismissible = true,
    super.settings,
  });

  /// The sheet: a [JamSheetSurface] around its content, or a
  /// [buildJamDraggableSheet] of one.
  final WidgetBuilder builder;

  /// A centred form sheet rather than a bottom sheet.
  final bool formSheet;

  /// Whether a downward drag dismisses it.
  final bool enableDrag;

  final Color _barrierColor;
  final bool _isDismissible;

  /// How far the page behind has receded, 0–1: the sheet's largeness, less
  /// whatever a dismissing drag has taken back.
  final ValueNotifier<double> _recede = ValueNotifier<double>(0);

  @override
  bool get opaque => false;

  @override
  bool get maintainState => true;

  @override
  bool get fullscreenDialog => false;

  @override
  bool get popGestureEnabled => false;

  @override
  Color? get barrierColor => _barrierColor;

  @override
  bool get barrierDismissible => _isDismissible;

  @override
  String? get barrierLabel => JamSheetStrings.dismiss;

  @override
  Duration get transitionDuration => JamDuration.sheet;

  @override
  Duration get reverseTransitionDuration => JamDuration.base;

  @override
  void install() {
    super.install();
    jamOpenSheets.value++;
  }

  @override
  void dispose() {
    jamOpenSheets.value = math.max(0, jamOpenSheets.value - 1);
    _recede.dispose();
    super.dispose();
  }

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => _JamSheetPage<T>(route: this);

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (MediaQuery.disableAnimationsOf(context)) {
      return FadeTransition(opacity: animation, child: child);
    }
    return SlideTransition(
      position: animation.drive(
        Tween<Offset>(
          begin: const Offset(0, 1),
          end: Offset.zero,
        ).chain(CurveTween(curve: JamCurve.emphasized)),
      ),
      child: child,
    );
  }

  @override
  DelegatedTransitionBuilder? get delegatedTransition =>
      formSheet ? null : _recedeBehind;

  /// What the page (or sheet) under a large sheet does: scale back under
  /// the status bar on black, its corners rounding — iOS's card stack.
  Widget? _recedeBehind(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    bool allowSnapshotting,
    Widget? child,
  ) {
    if (child == null) return null;
    final belowIsSheet = ModalRoute.of(context) is JamSheetRoute;
    final media = MediaQuery.of(context);
    final topInset = media.padding.top;
    final cornerFrom = media.viewPadding.top * 0.9 > 20
        ? media.viewPadding.top * 0.9
        : 0.0;
    return AnimatedBuilder(
      animation: Listenable.merge([secondaryAnimation, _recede]),
      child: child,
      builder: (context, child) {
        final t =
            Curves.easeOut.transform(secondaryAnimation.value.clamp(0.0, 1.0)) *
            _recede.value;
        if (t <= 0.001) return child!;
        if (belowIsSheet) {
          // A sheet under a sheet steps back and peeks out above it.
          return Transform(
            alignment: Alignment.topCenter,
            transform: Matrix4.translationValues(0, -kJamSheetTopInset * t, 0)
              ..scaleByDouble(1 - 0.06 * t, 1 - 0.06 * t, 1, 1),
            child: child,
          );
        }
        final radius = cornerFrom + (12 - cornerFrom) * t;
        final page = Transform(
          alignment: Alignment.topCenter,
          transform: Matrix4.translationValues(0, topInset * 0.6 * t, 0)
            ..scaleByDouble(1 - 0.08 * t, 1 - 0.08 * t, 1, 1),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(radius),
            child: child,
          ),
        );
        return Stack(
          children: [
            const Positioned.fill(
              child: ColoredBox(color: JamFixedColors.black),
            ),
            page,
            // The status bar now sits on black, whatever the theme says.
            if (t > 0.5)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: topInset,
                child: AnnotatedRegion<SystemUiOverlayStyle>(
                  value: const SystemUiOverlayStyle(
                    statusBarBrightness: Brightness.dark,
                    statusBarIconBrightness: Brightness.light,
                  ),
                  child: const SizedBox.expand(),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _JamSheetPage<T> extends StatefulWidget {
  const _JamSheetPage({super.key, required this.route});

  final JamSheetRoute<T> route;

  @override
  State<_JamSheetPage<T>> createState() => _JamSheetPageState<T>();
}

class _JamSheetPageState<T> extends State<_JamSheetPage<T>>
    with SingleTickerProviderStateMixin {
  /// How far a dismissing drag has pulled the sheet down.
  double _drag = 0;
  double _dragFrom = 0;
  double _height = 1;
  double _largeness = 0;
  bool _popped = false;

  late final AnimationController _settle = AnimationController(
    vsync: this,
    duration: JamDuration.base,
  )..addListener(_onSettle);

  /// A downward fling dismisses regardless of distance (pt/s).
  static const double _flingVelocity = 700;

  /// Past this share of the sheet, letting go dismisses.
  static const double _distance = 0.3;

  @override
  void dispose() {
    _settle.dispose();
    super.dispose();
  }

  void _onSettle() {
    setState(() => _drag = _dragFrom * (1 - _settle.value));
    _updateRecede();
  }

  void _onLargeness(double value) {
    if (!mounted || (value - _largeness).abs() < 0.001) return;
    _largeness = value;
    _updateRecede();
  }

  void _updateRecede() {
    final pulled = (_drag / math.max(_height, 1)).clamp(0.0, 1.0);
    widget.route._recede.value = _largeness * (1 - pulled);
  }

  void _pop() {
    if (_popped) return;
    _popped = true;
    Navigator.of(context).maybePop();
  }

  void _onDragUpdate(DragUpdateDetails details) {
    if (_popped) return;
    _settle.stop();
    setState(() => _drag = math.max(0, _drag + (details.primaryDelta ?? 0)));
    _updateRecede();
  }

  void _onDragEnd(DragEndDetails details) {
    if (_popped) return;
    final velocity = details.primaryVelocity ?? 0;
    if (velocity > _flingVelocity || _drag > _height * _distance) {
      _pop();
      return;
    }
    _dragFrom = _drag;
    _settle.forward(from: 0);
  }

  bool _onExtent(DraggableScrollableNotification n) {
    if (n.extent <= n.minExtent + 0.001 && n.shouldCloseOnMinExtent) _pop();
    return false;
  }

  Widget _draggable(Widget sheet) {
    if (!widget.route.enableDrag) return sheet;
    return GestureDetector(
      onVerticalDragUpdate: _onDragUpdate,
      onVerticalDragEnd: _onDragEnd,
      child: sheet,
    );
  }

  @override
  Widget build(BuildContext context) {
    final route = widget.route;
    final media = MediaQuery.of(context);

    if (route.formSheet) {
      final size = media.size;
      final width = math.min(
        kJamFormSheetMaxSize.width,
        size.width - JamSpace.xxl * 2,
      );
      final height = math.min(
        kJamFormSheetMaxSize.height,
        size.height - media.viewInsets.bottom - JamSpace.xxl * 2,
      );
      return Padding(
        padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
        child: Center(
          child: SizedBox(
            width: width,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: height),
              child: _JamSheetGeometry(
                form: true,
                available: height,
                onLargeness: null,
                child: MediaQuery.removePadding(
                  context: context,
                  removeLeft: true,
                  removeTop: true,
                  removeRight: true,
                  removeBottom: true,
                  child: Builder(builder: route.builder),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Align(
      alignment: Alignment.bottomCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _kPhoneSheetMaxWidth),
        child: SafeArea(
          bottom: false,
          child: LayoutBuilder(
            builder: (context, constraints) {
              _height = constraints.maxHeight;
              return _JamSheetGeometry(
                form: false,
                available: constraints.maxHeight,
                onLargeness: _onLargeness,
                child: NotificationListener<DraggableScrollableNotification>(
                  onNotification: _onExtent,
                  child: Transform.translate(
                    offset: Offset(0, _drag),
                    child: _draggable(Builder(builder: route.builder)),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Presents [builder] as a LocalJam sheet ([JamSheetRoute]): the `scrim`
/// barrier, a clear ground (the sheet paints its own [JamSheetSurface]),
/// floating at the medium detent and receding the page at the large one, or
/// a centred form sheet on a wide window. [showJamSheet] builds its header
/// on top of this; a sheet that owns its header (the library picker, whose
/// title follows the selection) or has none (a permission primer) calls it
/// directly — never a bare `showModalBottomSheet`.
///
/// It takes the appearance of where it was opened from
/// ([jamPresentationBrightness]): anything opened inside the room is the
/// room's dark, in both appearances (R2), scrim included.
Future<T?> showJamModalSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool enableDrag = true,
  bool isDismissible = true,
  RouteSettings? routeSettings,
}) {
  final appearance = jamPresentationBrightness(context);
  return Navigator.of(context, rootNavigator: true).push<T>(
    JamSheetRoute<T>(
      builder: jamPresentedIn(appearance, builder),
      formSheet: jamUsesFormSheet(context),
      barrierColor: jamPresentationColors(context, appearance).scrim,
      enableDrag: enableDrag,
      isDismissible: isDismissible,
      settings: routeSettings,
    ),
  );
}

/// Opens a LocalJam sheet.
///
/// [builder] is built inside the sheet, under a [JamSheetScrollController]
/// the content attaches its scroll view to when [scrollable].
///
/// [actions] lays out the header by the rule (§10.2).
///
/// [initialChildSize]: [kJamSheetLargeSize] (default) or
/// [kJamSheetMediumSize]. [grouped] uses the grouped sheet ground for
/// content built from `JamSection`s. Content that is *sometimes* dragging (a
/// reorderable queue) takes a [JamSheetDragLock] on pick-up.
Future<T?> showJamSheet<T>(
  BuildContext context, {
  required String title,
  JamSheetActions? actions,
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
  return showJamModalSheet<T>(
    context,
    enableDrag: enableDrag,
    isDismissible: isDismissible,
    routeSettings: routeSettings,
    builder: (context) {
      final content = Builder(builder: builder);
      if (!scrollable) {
        return JamSheetSurface(
          grouped: grouped,
          child: SafeArea(
            top: false,
            child: JamSheetScaffold(
              title: title,
              actions: actions,
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
            actions: actions,
            showHandle: enableDrag,
            scrollController: scrollController,
            child: content,
          ),
        ),
      );
    },
  );
}

/// A go_router page presenting its screen as a centred form sheet — Start a
/// Jam on a wide window. [builder] gets a scroll controller for the
/// screen's list.
class JamFormSheetPage<T> extends Page<T> {
  const JamFormSheetPage({
    super.key,
    super.name,
    super.arguments,
    super.restorationId,
    required this.builder,
    this.grouped = true,
  });

  final Widget Function(BuildContext context, ScrollController controller)
  builder;

  /// The grouped sheet ground.
  final bool grouped;

  @override
  Route<T> createRoute(BuildContext context) => JamSheetRoute<T>(
    settings: this,
    formSheet: true,
    enableDrag: false,
    barrierColor: context.jamColors.scrim,
    builder: (context) => JamSheetSurface(
      grouped: grouped,
      child: SizedBox(
        height: _JamSheetGeometry.maybeOf(context)?.available,
        child: _JamFixedSheet(builder: builder),
      ),
    ),
  );
}
