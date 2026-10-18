/// The iOS pull-down menu, used for every "•••" (DESIGN_SPEC v3 §5 Menus, as
/// amended by §10.3: iOS 26, radius 22).
///
/// iOS's own items (`CupertinoMenuItem`: 44 rows, title left, icon right,
/// destructive rows red, a thick separator between groups) on a surface of
/// our own — radius [JamRadius.menu], blurred, hairline-edged — placed the
/// way UIKit places a pull-down:
///
/// - from a small trigger (a "•••"), under it, leading- or trailing-aligned
///   by which side of the screen the trigger is on;
/// - from a **row** (a trigger wider than most of the screen), against the
///   row's trailing edge where its value and chevrons are — never centred
///   over the row and the controls below it;
/// - from a **point** ([JamMenuHandle.open] with a position — a long-press
///   on a list row), right at the finger, so it overlaps the row it acts on
///   rather than the next one.
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
import 'dart:ui' show ImageFilter;

import 'package:flutter/cupertino.dart';

import '../design/tokens.dart';
import '../design/typography.dart';
import 'buttons.dart';
import 'glass.dart';

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

  /// Title Case ("Sound Offset…").
  final String title;

  /// Drawn on the right, iOS-style.
  final IconData? icon;

  /// Null disables the item.
  final VoidCallback? onPressed;

  /// Red title and icon.
  final bool destructive;

  /// A leading checkmark (a choice among options).
  final bool checked;

  /// A secondary line under the title.
  final String? subtitle;
}

/// Builds the menu's children from [groups]: items, with a group separator
/// between groups. Public for callers that host their own anchor.
List<Widget> jamMenuChildren(List<List<JamMenuItem>> groups) {
  final hasChecks = groups.any((g) => g.any((i) => i.checked));
  return [
    for (var g = 0; g < groups.length; g++) ...[
      if (g > 0) const CupertinoMenuDivider(),
      for (final item in groups[g])
        CupertinoMenuItem(
          onPressed: item.onPressed,
          isDestructiveAction: item.destructive,
          leading: hasChecks
              ? (item.checked
                    ? const Icon(CupertinoIcons.checkmark, size: 17)
                    : const SizedBox.shrink())
              : null,
          trailing: item.icon == null ? null : Icon(item.icon),
          subtitle: item.subtitle == null ? null : Text(item.subtitle!),
          child: Text(item.title),
        ),
    ],
  ];
}

/// How the menu's trigger looks.
enum JamMenuTrigger {
  /// A bare tint "•••" (`ellipsis_circle`) for nav bars and rows.
  plain,

  /// A round chrome-glass button with "•••" — over ordinary content.
  glass,

  /// A round glass button over artwork / the Now Playing backdrop.
  glassOnArtwork,
}

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

/// What a custom trigger ([JamMenuButton.anchorBuilder]) gets to work with.
class JamMenuHandle {
  const JamMenuHandle._(this._controller, this.isOpen, this._enabled);

  final MenuController _controller;
  final bool _enabled;

  /// Whether the menu is showing (highlight the trigger while it is).
  final bool isOpen;

  /// Opens the menu — at [localPosition] within the trigger when given (the
  /// point a long-press landed), else against the trigger's edge.
  void open([Offset? localPosition]) {
    if (!_enabled) return;
    _controller.open(position: localPosition);
  }

  /// Closes the menu.
  void close() => _controller.close();

  /// Opens a closed menu, closes an open one.
  void toggle() => isOpen ? close() : open();
}

/// A "•••" button that opens a pull-down menu, or any custom trigger.
class JamMenuButton extends StatefulWidget {
  const JamMenuButton({
    super.key,
    required this.groups,
    this.semanticLabel = JamMenuStrings.more,
    this.trigger = JamMenuTrigger.plain,
    this.icon,
    this.visualSize = JamMetrics.glassButton,
    this.iconColor,
    this.builder,
    this.anchorBuilder,
    this.enabled = true,
    this.brightness,
    this.alignment = JamMenuAlignment.automatic,
    this.dimsBackground = false,
    this.onOpenChanged,
  });

  /// Item groups, separated by the thick group divider.
  final List<List<JamMenuItem>> groups;

  final String semanticLabel;
  final JamMenuTrigger trigger;

  /// Overrides the trigger glyph (default: `ellipsis` for glass,
  /// `ellipsis_circle` for plain).
  final IconData? icon;

  /// The glass trigger's circle (30 for the Now Playing title row).
  final double visualSize;

  final Color? iconColor;

  /// A custom trigger: build anything and call `open()` from it.
  final Widget Function(BuildContext context, VoidCallback open)? builder;

  /// A custom trigger that can open at a point (a long-press on a row) and
  /// knows whether the menu is open. Wins over [builder].
  final Widget Function(BuildContext context, JamMenuHandle menu)?
  anchorBuilder;

  final bool enabled;

  /// Forces the menu's light or dark look (Now Playing's menus are always
  /// dark, whatever the app theme). Null follows the ambient theme.
  final Brightness? brightness;

  /// Which edge of the trigger the menu lines up with.
  final JamMenuAlignment alignment;

  /// Dims everything behind the menu — for a context menu on a list row,
  /// so the row it acts on is unmistakable.
  final bool dimsBackground;

  /// Told when the menu opens and closes.
  final ValueChanged<bool>? onOpenChanged;

  @override
  State<JamMenuButton> createState() => _JamMenuButtonState();
}

class _JamMenuButtonState extends State<JamMenuButton>
    with SingleTickerProviderStateMixin {
  final MenuController _controller = MenuController();
  late final AnimationController _animation = AnimationController(
    vsync: this,
    duration: JamDuration.base,
    reverseDuration: JamDuration.fast,
  );
  bool _open = false;

  @override
  void dispose() {
    _animation.dispose();
    super.dispose();
  }

  void _setOpen(bool open) {
    if (_open == open) return;
    if (mounted) setState(() => _open = open);
    widget.onOpenChanged?.call(open);
  }

  void _onOpenRequested(Offset? position, VoidCallback showOverlay) {
    showOverlay();
    _setOpen(true);
    if (MediaQuery.disableAnimationsOf(context)) {
      _animation.value = 1;
    } else {
      _animation.forward();
    }
  }

  void _onCloseRequested(VoidCallback hideOverlay) {
    if (!mounted || MediaQuery.disableAnimationsOf(context)) {
      _animation.value = 0;
      hideOverlay();
      return;
    }
    _animation.reverse().whenComplete(() {
      if (_animation.isDismissed) hideOverlay();
    });
  }

  @override
  Widget build(BuildContext context) {
    // The menu is drawn in the root overlay but inherits from here. A
    // complete ambient text style keeps its titles off the framework's
    // fallback (the debug yellow underline) wherever the anchor sits.
    Widget menu = DefaultTextStyle(
      style: context.jamBody.copyWith(
        color: context.jamColors.label,
        decoration: TextDecoration.none,
      ),
      child: _anchor(context),
    );
    final forced = widget.brightness;
    if (forced != null) {
      // Cupertino's dynamic colours resolve against the Cupertino theme
      // first and the platform brightness second; set both.
      menu = MediaQuery(
        data: MediaQuery.of(context).copyWith(platformBrightness: forced),
        child: CupertinoTheme(
          data: CupertinoTheme.of(context).copyWith(brightness: forced),
          child: menu,
        ),
      );
    }
    return menu;
  }

  Widget _anchor(BuildContext context) => RawMenuAnchor(
    controller: _controller,
    useRootOverlay: true,
    consumeOutsideTaps: true,
    onOpenRequested: _onOpenRequested,
    onCloseRequested: _onCloseRequested,
    onClose: () => _setOpen(false),
    overlayBuilder: (context, info) => _JamMenuOverlay(
      info: info,
      animation: _animation,
      alignment: widget.alignment,
      dimsBackground: widget.dimsBackground,
      children: jamMenuChildren(widget.groups),
    ),
    builder: (context, controller, _) {
      final handle = JamMenuHandle._(controller, _open, widget.enabled);
      final anchor = widget.anchorBuilder;
      if (anchor != null) return anchor(context, handle);
      final open = widget.enabled ? handle.toggle : null;
      final custom = widget.builder;
      if (custom != null) return custom(context, open ?? () {});
      return switch (widget.trigger) {
        JamMenuTrigger.plain => JamIconButton(
          icon: widget.icon ?? CupertinoIcons.ellipsis_circle,
          semanticLabel: widget.semanticLabel,
          color: widget.iconColor,
          onPressed: open,
        ),
        JamMenuTrigger.glass || JamMenuTrigger.glassOnArtwork => JamGlassButton(
          icon: widget.icon ?? CupertinoIcons.ellipsis,
          semanticLabel: widget.semanticLabel,
          onArtwork: widget.trigger == JamMenuTrigger.glassOnArtwork,
          visualSize: widget.visualSize,
          iconSize: widget.visualSize <= 30 ? 15 : 18,
          iconColor: widget.iconColor,
          onPressed: open,
        ),
      };
    },
  );
}

/// The menu's width on a phone at the default text size.
const double _kMenuWidth = 250;

/// The gap between a menu and its trigger.
const double _kMenuGap = 6;

/// The open menu: placed, animated, clipped, blurred.
class _JamMenuOverlay extends StatelessWidget {
  const _JamMenuOverlay({
    required this.info,
    required this.animation,
    required this.alignment,
    required this.dimsBackground,
    required this.children,
  });

  final RawMenuOverlayInfo info;
  final Animation<double> animation;
  final JamMenuAlignment alignment;
  final bool dimsBackground;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final dark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    final colors = context.jamColors;
    final overlay = info.overlaySize;
    final scale = media.textScaler.scale(17) / 17;
    final width = math.min(
      overlay.width - JamSpace.lg,
      _kMenuWidth * math.max(1.0, math.min(scale, 1.4)),
    );
    final safe = media.padding + const EdgeInsets.all(JamSpace.sm);
    final placement = _placeMenu(
      anchor: info.anchorRect,
      overlay: overlay,
      safe: safe,
      width: width,
      point: info.position,
      alignment: alignment,
    );

    // A near-opaque ground and a hairline instead of a shadow (only artwork
    // casts one): it has to stand off a white page without help.
    final ground = dark ? const Color(0xF22C2C2E) : const Color(0xF2F9F9F9);
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeIn,
    );

    final panel = TapRegion(
      groupId: info.tapRegionGroupId,
      // A touch anywhere but the menu (or its trigger) puts it away.
      onTapOutside: (_) => MenuController.maybeOf(context)?.close(),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(JamRadius.menu),
        child: BackdropFilter(
          filter: ImageFilter.blur(
            sigmaX: JamBlur.material,
            sigmaY: JamBlur.material,
          ),
          child: DecoratedBox(
            decoration: ShapeDecoration(
              color: ground,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(JamRadius.menu),
                side: BorderSide(
                  color: colors.separator,
                  width: 1 / media.devicePixelRatio,
                ),
              ),
            ),
            child: SizedBox(
              width: width,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: children,
                ),
              ),
            ),
          ),
        ),
      ),
    );

    return Stack(
      children: [
        if (dimsBackground)
          Positioned.fill(
            child: IgnorePointer(
              child: FadeTransition(
                opacity: curved,
                child: const ColoredBox(color: Color(0x33000000)),
              ),
            ),
          ),
        CustomSingleChildLayout(
          delegate: _MenuLayout(placement: placement, safe: safe),
          child: FadeTransition(
            opacity: curved,
            child: ScaleTransition(
              scale: curved.drive(Tween<double>(begin: 0.85, end: 1)),
              alignment: placement.growFrom,
              child: Semantics(
                explicitChildNodes: true,
                scopesRoute: true,
                namesRoute: true,
                label: JamMenuStrings.more,
                child: panel,
              ),
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
  });

  final double left;

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
  required Offset? point,
  required JamMenuAlignment alignment,
}) {
  final at = point == null ? null : anchor.topLeft + point;
  final focusX = at?.dx ?? anchor.center.dx;
  final ratio = focusX / overlay.width;

  // Horizontal: which edge lines up.
  double left;
  double growX;
  final rowLike = anchor.width > overlay.width * 0.6;
  final side = switch (alignment) {
    JamMenuAlignment.leading => -1,
    JamMenuAlignment.trailing => 1,
    JamMenuAlignment.automatic when at == null && rowLike => 1,
    JamMenuAlignment.automatic =>
      ratio < 0.4
          ? -1
          : ratio > 0.6
          ? 1
          : 0,
  };
  if (at != null) {
    left = switch (side) {
      -1 => at.dx,
      1 => at.dx - width,
      _ => at.dx - width / 2,
    };
  } else {
    // A row's trailing edge is its last control, a little inside the row.
    final trailingEdge = rowLike ? anchor.right - JamSpace.lg : anchor.right;
    left = switch (side) {
      -1 => anchor.left,
      1 => trailingEdge - width,
      _ => anchor.center.dx - width / 2,
    };
  }
  left = left.clamp(
    safe.left,
    math.max(safe.left, overlay.width - safe.right - width),
  );
  growX = side.toDouble();

  // Vertical: below the trigger (or the finger) when there is room for a
  // typical menu, else above it.
  final belowY = (at?.dy ?? anchor.bottom) + _kMenuGap;
  final aboveY = (at?.dy ?? anchor.top) - _kMenuGap;
  final roomBelow = overlay.height - safe.bottom - belowY;
  final roomAbove = aboveY - safe.top;
  const typical = 220.0;
  final down = roomBelow >= typical || roomBelow >= roomAbove;
  return _Placement(
    left: left,
    top: down ? belowY : null,
    bottom: down ? null : aboveY,
    growFrom: Alignment(growX, down ? -1 : 1),
  );
}

class _MenuLayout extends SingleChildLayoutDelegate {
  const _MenuLayout({required this.placement, required this.safe});

  final _Placement placement;
  final EdgeInsets safe;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final top = placement.top;
    final bottom = placement.bottom;
    final maxHeight = top != null
        ? constraints.maxHeight - safe.bottom - top
        : bottom! - safe.top;
    return BoxConstraints.loose(
      Size(constraints.maxWidth, math.max(maxHeight, JamMetrics.menuRow * 2)),
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final top = placement.top;
    final y = top ?? (placement.bottom! - childSize.height);
    final clampedY = y
        .clamp(
          safe.top,
          math.max(safe.top, size.height - safe.bottom - childSize.height),
        )
        .toDouble();
    return Offset(placement.left, clampedY);
  }

  @override
  bool shouldRelayout(_MenuLayout oldDelegate) =>
      oldDelegate.placement != placement || oldDelegate.safe != safe;
}
