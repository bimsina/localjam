/// Menus: the pull-down behind every "•••" and the queue's long-press
/// context menu draw the **same panel** ([JamMenuPanel]) in LocalJam's own
/// colours — the menu ground is `elevatedGroupedSurface`, red is `danger`,
/// the group gap is `elevatedGroupedBackground`. Nothing here comes from
/// Cupertino's menu chrome.
///
/// - [JamMenuButton]: a "•••" (or any trigger) that opens a pull-down.
/// - [JamMenuAnchor]: the same pull-down, opened from your own
///   [MenuController] (the Guests Can pop-up row).
/// - [JamMenuPanel]: the bare panel, for a host with its own placement (the
///   queue's lifted-row context menu).
///
/// A pull-down is placed the way UIKit places one:
///
/// - from a small trigger (a "•••"), under it, leading- or trailing-aligned
///   by which side of the screen the trigger is on;
/// - from a **row** (a trigger wider than most of the screen), against the
///   row's trailing edge where its value and chevrons are — never centred
///   over the row and the controls below it;
/// - never over what a [JamMenuKeepClear] marks in the same
///   [JamMenuKeepClearScope] (N6): a sheet's header with its Done, the Now
///   Playing title beside its "•••". A region above the trigger is a
///   ceiling the menu stays under; one beside it counts as part of the
///   trigger, so the menu opens past it.
///
/// ```dart
/// JamMenuButton(
///   semanticLabel: 'More',
///   groups: [
///     [
///       JamMenuItem(title: 'Diagnostics', icon: CupertinoIcons.waveform_path_ecg, onPressed: _diag),
///     ],
///     [JamMenuItem(title: 'End Jam', icon: CupertinoIcons.xmark_circle, destructive: true, onPressed: _end)],
///   ],
/// )
/// ```
library;

import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

import '../design/motion.dart';
import '../design/theme.dart';
import '../design/tokens.dart';
import '../design/typography.dart';
import 'glass.dart';
import 'pressable.dart';

/// Strings the menu button says.
abstract final class JamMenuStrings {
  static const String more = 'More';
}

/// One menu action.
@immutable
class JamMenuItem {
  const JamMenuItem({
    required this.title,
    this.icon,
    this.onPressed,
    this.destructive = false,
    this.checked = false,
    this.subtitle,
  });

  /// Sentence case ("Sound offset…").
  final String title;

  /// Drawn on the trailing side, at [JamIconSize.control].
  final IconData? icon;

  /// Null disables the item.
  final VoidCallback? onPressed;

  /// Red (`danger`) title and icon.
  final bool destructive;

  /// A leading checkmark (a choice among options).
  final bool checked;

  /// A secondary line under the title.
  final String? subtitle;
}

/// The gap between two groups in a [JamMenuPanel].
const double kJamMenuGroupGap = JamSpace.sm;

/// The menu's width on a phone at the default text size.
const double kJamMenuWidth = 250;

/// One row of a menu: title (and subtitle) leading, icon trailing, a
/// leading checkmark slot when [showCheckSlot], 44 tall at least.
///
/// Activating it — a tap, or Enter / Space with focus — runs [onSelected]
/// with the item when given (a context menu that closes first and acts
/// after); otherwise it closes the enclosing menu ([MenuController.maybeOf])
/// and runs [JamMenuItem.onPressed].
class JamMenuRow extends StatefulWidget {
  const JamMenuRow({
    super.key,
    required this.item,
    this.onSelected,
    this.showCheckSlot = false,
  });

  final JamMenuItem item;

  /// Takes the choice instead of running it here.
  final ValueChanged<JamMenuItem>? onSelected;

  /// Reserves the leading checkmark's slot, so titles in a menu where any
  /// item can be checked line up.
  final bool showCheckSlot;

  @override
  State<JamMenuRow> createState() => _JamMenuRowState();
}

class _JamMenuRowState extends State<JamMenuRow> {
  bool _focused = false;

  bool get _enabled => widget.item.onPressed != null;

  void _activate() {
    if (!_enabled) return;
    final item = widget.item;
    final onSelected = widget.onSelected;
    if (onSelected != null) {
      onSelected(item);
      return;
    }
    MenuController.maybeOf(context)?.close();
    item.onPressed?.call();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final item = widget.item;
    final enabled = _enabled;
    final color = !enabled
        ? colors.tertiaryLabel
        : item.destructive
        ? colors.danger
        : colors.label;
    final subtitle = item.subtitle;
    final icon = item.icon;

    final row = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: JamMetrics.menuRow),
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(
          JamSpace.lg,
          JamSpace.sm,
          JamSpace.lg,
          JamSpace.sm,
        ),
        child: Row(
          children: [
            if (widget.showCheckSlot) ...[
              SizedBox(
                width: JamIconSize.control,
                child: item.checked
                    ? Icon(
                        CupertinoIcons.checkmark,
                        size: JamIconSize.inline,
                        color: color,
                      )
                    : null,
              ),
              const SizedBox(width: JamSpace.sm),
            ],
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    style: context.jamBody.copyWith(color: color),
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle,
                      style: context.jamFootnote.copyWith(
                        color: colors.secondaryLabel,
                      ),
                    ),
                ],
              ),
            ),
            if (icon != null) ...[
              const SizedBox(width: JamSpace.md),
              Icon(icon, size: JamIconSize.control, color: color),
            ],
          ],
        ),
      ),
    );

    return Semantics(
      container: true,
      button: true,
      enabled: enabled,
      selected: item.checked ? true : null,
      label: subtitle == null ? item.title : '${item.title}. $subtitle',
      onTap: enabled ? _activate : null,
      excludeSemantics: true,
      child: FocusableActionDetector(
        enabled: enabled,
        onShowFocusHighlight: (v) => setState(() => _focused = v),
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              _activate();
              return null;
            },
          ),
        },
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        },
        child: JamPressable(
          onTap: enabled ? _activate : null,
          style: JamPressStyle.highlight,
          child: ColoredBox(
            color: _focused ? colors.fillPressed : JamFixedColors.clear,
            child: row,
          ),
        ),
      ),
    );
  }
}

/// The rows for [groups] — a hairline between items, a [kJamMenuGroupGap]
/// band between groups — inside [JamMenuPanel].
List<Widget> _menuChildren(
  List<List<JamMenuItem>> groups, {
  ValueChanged<JamMenuItem>? onSelected,
}) {
  final hasChecks = groups.any((g) => g.any((i) => i.checked));
  return [
    for (var g = 0; g < groups.length; g++) ...[
      if (g > 0) const _JamMenuGroupGap(),
      for (var i = 0; i < groups[g].length; i++) ...[
        if (i > 0) const _JamMenuHairline(),
        JamMenuRow(
          item: groups[g][i],
          onSelected: onSelected,
          showCheckSlot: hasChecks,
        ),
      ],
    ],
  ];
}

class _JamMenuHairline extends StatelessWidget {
  const _JamMenuHairline();

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 1 / MediaQuery.devicePixelRatioOf(context),
    child: ColoredBox(color: context.jamColors.separator),
  );
}

class _JamMenuGroupGap extends StatelessWidget {
  const _JamMenuGroupGap();

  @override
  Widget build(BuildContext context) => SizedBox(
    height: kJamMenuGroupGap,
    // The grouped-sheet ground: a step below the menu's own surface in both
    // themes, so the gap reads as a gap, not a black stripe.
    child: ColoredBox(color: context.jamColors.elevatedGroupedBackground),
  );
}

/// The one menu surface: an opaque `elevatedGroupedSurface` card at
/// [JamRadius.menu] — held under half its height, so a one-row menu is a
/// soft rectangle and not a capsule ([JamRadius.menuFor]) — with a hairline
/// edge (no shadow — only artwork casts one), holding [groups] as
/// [JamMenuRow]s.
///
/// [onSelected] hands the chosen item back instead of running it — the
/// queue's context menu pops its route with it and runs it after. Without
/// it a row closes the enclosing [MenuController] and runs itself.
///
/// ```dart
/// JamMenuPanel(
///   groups: [items],
///   onSelected: (item) => Navigator.of(context).pop(item.onPressed),
/// )
/// ```
class JamMenuPanel extends StatelessWidget {
  const JamMenuPanel({
    super.key,
    required this.groups,
    this.onSelected,
    this.width,
    this.semanticLabel = JamMenuStrings.more,
  });

  final List<List<JamMenuItem>> groups;
  final ValueChanged<JamMenuItem>? onSelected;

  /// A fixed width; null takes the incoming constraints.
  final double? width;

  /// Names the menu for a screen reader.
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    const shape = JamMenuBorder();
    final edge = JamMenuBorder(
      side: BorderSide(
        color: colors.separator,
        width: 1 / MediaQuery.devicePixelRatioOf(context),
      ),
    );
    Widget panel = ClipPath(
      clipper: const ShapeBorderClipper(shape: shape),
      child: DecoratedBox(
        decoration: ShapeDecoration(
          color: colors.elevatedGroupedSurface,
          shape: shape,
        ),
        // The panel is often drawn in the root overlay: a complete ambient
        // text style keeps its titles off the framework's fallback.
        child: DefaultTextStyle(
          style: context.jamBody.copyWith(
            color: colors.label,
            decoration: TextDecoration.none,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: _menuChildren(groups, onSelected: onSelected),
            ),
          ),
        ),
      ),
    );
    // The hairline edge is drawn in front of the rows, so a group's gap
    // band cannot paint over it (CR-12).
    panel = DecoratedBox(
      position: DecorationPosition.foreground,
      decoration: ShapeDecoration(shape: edge),
      child: panel,
    );
    final w = width;
    if (w != null) panel = SizedBox(width: w, child: panel);
    return Semantics(
      explicitChildNodes: true,
      scopesRoute: true,
      namesRoute: true,
      label: semanticLabel,
      child: panel,
    );
  }
}

/// A menu panel's outline: a rounded rectangle at [JamRadius.menuFor] its
/// own height — [JamRadius.menu] for a menu of two rows or more, less for
/// one, so it never reads as a capsule (D9).
class JamMenuBorder extends OutlinedBorder {
  const JamMenuBorder({super.side});

  RoundedRectangleBorder _at(Rect rect) => RoundedRectangleBorder(
    side: side,
    borderRadius: BorderRadius.circular(JamRadius.menuFor(rect.height)),
  );

  @override
  JamMenuBorder copyWith({BorderSide? side}) =>
      JamMenuBorder(side: side ?? this.side);

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.all(side.strokeInset);

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      _at(rect).getInnerPath(rect, textDirection: textDirection);

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) =>
      _at(rect).getOuterPath(rect, textDirection: textDirection);

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) =>
      _at(rect).paint(canvas, rect, textDirection: textDirection);

  @override
  ShapeBorder scale(double t) => JamMenuBorder(side: side.scale(t));

  @override
  bool operator ==(Object other) =>
      other is JamMenuBorder && other.side == side;

  @override
  int get hashCode => side.hashCode;
}

/// How the menu's trigger looks.
///
/// Both draw the app's one "more" button: a [kJamMoreButtonSize] circle
/// with "•••" in it — never a bare glyph, never an outlined circle — so a
/// menu looks the same on a page, a row and the player.
enum JamMenuTrigger {
  /// On paper and in sheets: a flat `fill` circle, its dots in `tint` (in
  /// a nav bar, with the bar's other actions) or as the caller colours
  /// them (`secondaryLabel` in a list of rows, where a column of raspberry
  /// would outshout the names).
  plain,

  /// Over artwork / the Now Playing backdrop: the same circle in glass,
  /// its dots white.
  glassOnArtwork,
}

/// The "more" button's circle: the one size it is drawn at everywhere.
const double kJamMoreButtonSize = 30;

/// Which edge of its trigger a menu lines up with.
enum JamMenuAlignment {
  /// UIKit's rule: a trigger on the left third opens leading-aligned, on the
  /// right third trailing-aligned, in the middle centred — and a trigger
  /// that spans most of the screen (a row) opens trailing-aligned.
  automatic,

  /// The menu's leading edge on the trigger's.
  leading,

  /// The menu's trailing edge on the trigger's (a Settings-style pop-up row).
  trailing,
}

/// A pull-down [JamMenuPanel] anchored to whatever [builder] draws, opened
/// and closed through [controller] (or the one handed to [builder]).
///
/// [JamMenuButton] is this with a "•••" trigger. Use the anchor directly
/// when something else opens the menu — a row's tap, a keyboard shortcut:
///
/// ```dart
/// JamMenuAnchor(
///   controller: _menu,
///   alignment: JamMenuAlignment.trailing,
///   groups: [presetItems],
///   builder: (context, controller) => const IgnorePointer(child: SizedBox.expand()),
/// )
/// // …elsewhere: _menu.open();
/// ```
class JamMenuAnchor extends StatefulWidget {
  const JamMenuAnchor({
    super.key,
    required this.groups,
    required this.builder,
    this.controller,
    this.alignment = JamMenuAlignment.automatic,
    this.preferUp = false,
    this.brightness,
    this.semanticLabel = JamMenuStrings.more,
  });

  /// Item groups, separated by the group gap.
  final List<List<JamMenuItem>> groups;

  /// Opens above the trigger whenever there is room there, rather than
  /// below it — for a trigger with the controls that matter under it (Now
  /// Playing's ••• over the transport). Without room above it opens down.
  final bool preferUp;

  /// The trigger (or an invisible anchor). Call `controller.open()` from it.
  final Widget Function(BuildContext context, MenuController controller)
  builder;

  /// Opens and closes the menu from outside. Null: the anchor owns one.
  final MenuController? controller;

  /// Which edge of the trigger the menu lines up with.
  final JamMenuAlignment alignment;

  /// Forces the menu's light or dark palette. Null: the appearance of
  /// where the menu was opened from ([jamPresentationBrightness]) — the
  /// room's dark inside the room, otherwise the app's.
  final Brightness? brightness;

  /// Names the open menu for a screen reader.
  final String semanticLabel;

  @override
  State<JamMenuAnchor> createState() => _JamMenuAnchorState();
}

class _JamMenuAnchorState extends State<JamMenuAnchor>
    with SingleTickerProviderStateMixin {
  MenuController? _ownController;
  MenuController get _controller =>
      widget.controller ?? (_ownController ??= MenuController());

  late final AnimationController _animation = AnimationController(
    vsync: this,
    duration: JamDuration.base,
    reverseDuration: JamDuration.fast,
  );

  @override
  void dispose() {
    _animation.dispose();
    super.dispose();
  }

  /// What this menu must not cover, in the root overlay's coordinates.
  List<Rect> _keepClearRects() {
    final regions = JamMenuKeepClearScope._regionsOf(context);
    if (regions.isEmpty) return const [];
    final overlay = Overlay.maybeOf(
      context,
      rootOverlay: true,
    )?.context.findRenderObject();
    if (overlay is! RenderBox || !overlay.attached) return const [];
    return [
      for (final region in regions)
        if (region.findRenderObject() case final RenderBox box
            when box.attached && box.hasSize)
          MatrixUtils.transformRect(
            box.getTransformTo(overlay),
            Offset.zero & box.size,
          ),
    ];
  }

  void _onOpenRequested(Offset? position, VoidCallback showOverlay) {
    showOverlay();
    if (jamReducedMotion(context)) {
      _animation.value = 1;
    } else {
      _animation.forward();
    }
  }

  void _onCloseRequested(VoidCallback hideOverlay) {
    if (!mounted || jamReducedMotion(context)) {
      _animation.value = 0;
      hideOverlay();
      return;
    }
    _animation.reverse().whenComplete(() {
      if (_animation.isDismissed) hideOverlay();
    });
  }

  @override
  Widget build(BuildContext context) => RawMenuAnchor(
    controller: _controller,
    useRootOverlay: true,
    consumeOutsideTaps: true,
    onOpenRequested: _onOpenRequested,
    onCloseRequested: _onCloseRequested,
    overlayBuilder: (context, info) {
      Widget overlay = _JamMenuOverlay(
        info: info,
        animation: _animation,
        alignment: widget.alignment,
        preferUp: widget.preferUp,
        groups: widget.groups,
        semanticLabel: widget.semanticLabel,
        keepClear: _keepClearRects(),
      );
      // Inside the room (or on its backdrop) the menu is the room's dark,
      // in its solid palette (R2), unless told otherwise.
      final forced = widget.brightness ?? jamPresentationBrightness(context);
      if (forced != null) {
        overlay = JamForcedAppearance(brightness: forced, child: overlay);
      }
      return overlay;
    },
    builder: (context, controller, _) => widget.builder(context, controller),
  );
}

/// A "•••" button that opens a pull-down menu, or any custom trigger.
class JamMenuButton extends StatelessWidget {
  const JamMenuButton({
    super.key,
    required this.groups,
    this.semanticLabel = JamMenuStrings.more,
    this.trigger = JamMenuTrigger.plain,
    this.icon,
    this.visualSize = kJamMoreButtonSize,
    this.iconColor,
    this.builder,
    this.enabled = true,
    this.brightness,
    this.alignment = JamMenuAlignment.automatic,
    this.preferUp = false,
    this.triggerAlignment = Alignment.center,
  });

  /// Item groups, separated by the group gap.
  final List<List<JamMenuItem>> groups;

  final String semanticLabel;
  final JamMenuTrigger trigger;

  /// Overrides the trigger glyph (default: `ellipsis`).
  final IconData? icon;

  /// The trigger's circle ([kJamMoreButtonSize]).
  final double visualSize;

  final Color? iconColor;

  /// A custom trigger: build anything and call `open()` from it (it toggles).
  final Widget Function(BuildContext context, VoidCallback open)? builder;

  final bool enabled;

  /// Forces the menu's light or dark palette. Null: the appearance of
  /// where the menu was opened from — the room's dark inside the room.
  final Brightness? brightness;

  /// Which edge of the trigger the menu lines up with.
  final JamMenuAlignment alignment;

  /// Opens above the trigger when there is room (see
  /// [JamMenuAnchor.preferUp]).
  final bool preferUp;

  /// Where the trigger's circle sits in its 44 hit box (see
  /// `JamGlassButton.alignment`) — `centerEnd` to put the circle's edge on
  /// the content's trailing edge.
  final AlignmentGeometry triggerAlignment;

  @override
  Widget build(BuildContext context) => JamMenuAnchor(
    groups: groups,
    alignment: alignment,
    preferUp: preferUp,
    brightness: brightness,
    semanticLabel: semanticLabel,
    builder: (context, controller) {
      final VoidCallback? open = enabled
          ? () => controller.isOpen ? controller.close() : controller.open()
          : null;
      final custom = builder;
      if (custom != null) return custom(context, open ?? () {});
      final onArtwork = trigger == JamMenuTrigger.glassOnArtwork;
      final colors = context.jamColors;
      return JamGlassButton(
        icon: icon ?? CupertinoIcons.ellipsis,
        semanticLabel: semanticLabel,
        onArtwork: onArtwork,
        // Flat on paper, where the blurred chrome would vanish into the
        // page in light mode.
        fillColor: onArtwork ? null : colors.fill,
        visualSize: visualSize,
        iconSize: visualSize <= 30 ? JamIconSize.inline : 18,
        iconColor: iconColor ?? (onArtwork ? null : colors.tint),
        alignment: triggerAlignment,
        onPressed: open,
      );
    },
  );
}

/// The gap between a menu and its trigger.
const double _kMenuGap = 6;

/// The open pull-down: placed, animated, the panel.
class _JamMenuOverlay extends StatelessWidget {
  const _JamMenuOverlay({
    required this.info,
    required this.animation,
    required this.alignment,
    required this.preferUp,
    required this.groups,
    required this.semanticLabel,
    required this.keepClear,
  });

  final RawMenuOverlayInfo info;

  /// Regions the menu must not cover ([JamMenuKeepClear]).
  final List<Rect> keepClear;
  final Animation<double> animation;
  final JamMenuAlignment alignment;
  final bool preferUp;
  final List<List<JamMenuItem>> groups;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final overlay = info.overlaySize;
    final scale = media.textScaler.scale(17) / 17;
    final width = math.min(
      overlay.width - JamSpace.lg,
      kJamMenuWidth * math.max(1.0, math.min(scale, 1.4)),
    );
    final safe = media.padding + const EdgeInsets.all(JamSpace.sm);
    final placement = _placeMenu(
      anchor: info.anchorRect,
      overlay: overlay,
      safe: safe,
      width: width,
      alignment: alignment,
      preferUp: preferUp,
      keepClear: keepClear,
    );

    final curved = CurvedAnimation(
      parent: animation,
      curve: JamCurve.standard,
      reverseCurve: JamCurve.exit,
    );

    final panel = TapRegion(
      groupId: info.tapRegionGroupId,
      // A touch anywhere but the menu (or its trigger) puts it away.
      onTapOutside: (_) => MenuController.maybeOf(context)?.close(),
      child: JamMenuPanel(
        groups: groups,
        width: width,
        semanticLabel: semanticLabel,
      ),
    );

    return Stack(
      children: [
        CustomSingleChildLayout(
          delegate: _MenuLayout(placement: placement),
          child: FadeTransition(
            opacity: curved,
            child: ScaleTransition(
              scale: curved.drive(Tween<double>(begin: 0.85, end: 1)),
              alignment: placement.growFrom,
              child: panel,
            ),
          ),
        ),
      ],
    );
  }
}

/// Where a menu goes: its leading x, and either its top (opening down) or
/// its bottom (opening up), plus the corner it grows from.
@immutable
class _Placement {
  const _Placement({
    required this.left,
    required this.top,
    required this.bottom,
    required this.growFrom,
    required this.minY,
    required this.maxY,
    this.narrowed = false,
  });

  final double left;

  /// The band the menu stays inside: the safe area, less whatever it must
  /// keep clear above and below its trigger.
  final double minY;
  final double maxY;

  /// Whether a kept-clear region narrowed the band. A menu then gets the
  /// whole band and, if it must, slides back over its own trigger, rather
  /// than shrinking to the sliver left on its side.
  final bool narrowed;

  /// Opening downward: the menu's top. Null when opening upward.
  final double? top;

  /// Opening upward: the menu's bottom. Null when opening downward.
  final double? bottom;

  final Alignment growFrom;
}

_Placement _placeMenu({
  required Rect anchor,
  required Size overlay,
  required EdgeInsets safe,
  required double width,
  required JamMenuAlignment alignment,
  bool preferUp = false,
  List<Rect> keepClear = const [],
}) {
  final ratio = anchor.center.dx / overlay.width;

  // Horizontal: which edge lines up.
  double left;
  double growX;
  final rowLike = anchor.width > overlay.width * 0.6;
  final side = switch (alignment) {
    JamMenuAlignment.leading => -1,
    JamMenuAlignment.trailing => 1,
    JamMenuAlignment.automatic when rowLike => 1,
    JamMenuAlignment.automatic =>
      ratio < 0.4
          ? -1
          : ratio > 0.6
          ? 1
          : 0,
  };
  // A row's trailing edge is its last control, a little inside the row.
  final trailingEdge = rowLike ? anchor.right - JamSpace.lg : anchor.right;
  left = switch (side) {
    -1 => anchor.left,
    1 => trailingEdge - width,
    _ => anchor.center.dx - width / 2,
  };
  left = left.clamp(
    safe.left,
    math.max(safe.left, overlay.width - safe.right - width),
  );
  growX = side.toDouble();

  // What it keeps clear (N6). A region wholly above the trigger (a sheet's
  // header and its Done) is a ceiling; one wholly below, a floor; one
  // beside it (the title next to Now Playing's "•••") is treated as part
  // of the trigger, so the menu opens past its top or its bottom.
  var anchorTop = anchor.top;
  var anchorBottom = anchor.bottom;
  var minY = safe.top;
  var maxY = overlay.height - safe.bottom;
  for (final region in keepClear) {
    if (region.bottom <= anchor.top + 1) {
      minY = math.max(minY, region.bottom + _kMenuGap);
    } else if (region.top >= anchor.bottom - 1) {
      maxY = math.min(maxY, region.top - _kMenuGap);
    } else {
      anchorTop = math.min(anchorTop, region.top);
      anchorBottom = math.max(anchorBottom, region.bottom);
    }
  }
  // A band too thin for a menu is no band: fall back to the safe area.
  if (maxY - minY < JamMetrics.menuRow * 2) {
    minY = safe.top;
    maxY = overlay.height - safe.bottom;
  }
  final narrowed = minY > safe.top || maxY < overlay.height - safe.bottom;

  // Vertical: on the preferred side (below, unless [preferUp]) when there
  // is room there for a typical menu, else wherever there is more room.
  final belowY = anchorBottom + _kMenuGap;
  final aboveY = anchorTop - _kMenuGap;
  final roomBelow = maxY - belowY;
  final roomAbove = aboveY - minY;
  const typical = 220.0;
  final down = preferUp
      ? !(roomAbove >= typical || roomAbove > roomBelow)
      : roomBelow >= typical || roomBelow >= roomAbove;
  return _Placement(
    left: left,
    top: down ? belowY : null,
    bottom: down ? null : aboveY,
    growFrom: Alignment(growX, down ? -1 : 1),
    minY: minY,
    maxY: maxY,
    narrowed: narrowed,
  );
}

class _MenuLayout extends SingleChildLayoutDelegate {
  const _MenuLayout({required this.placement});

  final _Placement placement;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final top = placement.top;
    final bottom = placement.bottom;
    final maxHeight = placement.narrowed
        ? placement.maxY - placement.minY
        : top != null
        ? placement.maxY - top
        : bottom! - placement.minY;
    return BoxConstraints.loose(
      Size(constraints.maxWidth, math.max(maxHeight, JamMetrics.menuRow * 2)),
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final top = placement.top;
    final y = top ?? (placement.bottom! - childSize.height);
    // Inside the band; a menu taller than the room on its side slides back
    // over its trigger rather than over what it keeps clear.
    final clampedY = y
        .clamp(
          placement.minY,
          math.max(placement.minY, placement.maxY - childSize.height),
        )
        .toDouble();
    return Offset(placement.left, clampedY);
  }

  @override
  bool shouldRelayout(_MenuLayout oldDelegate) =>
      oldDelegate.placement != placement;
}

/// Marks where menus opened nearby keep clear of (N6): the regions
/// registered by [JamMenuKeepClear]s under it, for menus opened under it.
///
/// A sheet is one (its header and Done are kept clear); so is the Now
/// Playing title row (its title is).
class JamMenuKeepClearScope extends StatefulWidget {
  const JamMenuKeepClearScope({super.key, required this.child});

  final Widget child;

  /// The regions in force for a menu opened at [context]: those of every
  /// scope above it.
  static List<BuildContext> _regionsOf(BuildContext context) {
    final out = <BuildContext>[];
    context.visitAncestorElements((element) {
      if (element.widget is _KeepClearRegistry) {
        final registry = element.widget as _KeepClearRegistry;
        out.addAll(registry.state._regions.where((r) => r.mounted));
      }
      return true;
    });
    return out;
  }

  @override
  State<JamMenuKeepClearScope> createState() => _JamMenuKeepClearScopeState();
}

class _JamMenuKeepClearScopeState extends State<JamMenuKeepClearScope> {
  final Set<BuildContext> _regions = {};

  @override
  Widget build(BuildContext context) =>
      _KeepClearRegistry(state: this, child: widget.child);
}

class _KeepClearRegistry extends InheritedWidget {
  const _KeepClearRegistry({required this.state, required super.child});

  final _JamMenuKeepClearScopeState state;

  @override
  bool updateShouldNotify(_KeepClearRegistry old) => false;
}

/// A region no menu in the same [JamMenuKeepClearScope] may cover: a
/// sheet's header with its Done, the title beside Now Playing's "•••".
class JamMenuKeepClear extends StatefulWidget {
  const JamMenuKeepClear({super.key, required this.child});

  final Widget child;

  @override
  State<JamMenuKeepClear> createState() => _JamMenuKeepClearState();
}

class _JamMenuKeepClearState extends State<JamMenuKeepClear> {
  _JamMenuKeepClearScopeState? _scope;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scope = context
        .getInheritedWidgetOfExactType<_KeepClearRegistry>()
        ?.state;
    if (scope == _scope) return;
    _scope?._regions.remove(context);
    _scope = scope?.._regions.add(context);
  }

  @override
  void dispose() {
    _scope?._regions.remove(context);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
