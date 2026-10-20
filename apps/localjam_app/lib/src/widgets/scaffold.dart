/// The iOS page: a large title that collapses into an inline 17-semibold
/// title in a blurred `material` nav bar on scroll, with the hairline only
/// once content scrolls under it (DESIGN_SPEC v3 §5 JamScaffold).
///
/// Back is a bare chevron everywhere (§10.11): no previous-page labels,
/// whatever a caller passes or a route would imply.
///
/// [JamScaffold.maxContentWidth] holds the content to a reading column
/// centred in the *pane* (a sidebar layout's detail pane, not the window),
/// with the large title on the column's leading edge.
///
/// ```dart
/// JamScaffold(
///   title: 'Nearby',
///   trailing: [
///     JamIconButton(icon: CupertinoIcons.qrcode_viewfinder, semanticLabel: 'Scan', onPressed: _scan),
///   ],
///   slivers: [SliverList.list(children: rows)],
///   bottomBar: JamButton.filled(label: 'Start a Jam', expand: true, onPressed: _start),
/// )
/// ```
library;

import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Scaffold, Theme;

import '../design/tokens.dart';
import 'glass.dart';

/// A LocalJam page.
class JamScaffold extends StatefulWidget {
  const JamScaffold({
    super.key,
    required this.title,
    this.largeTitle = true,
    this.leading,
    this.trailing = const <Widget>[],
    this.previousPageTitle,
    this.automaticallyImplyLeading = true,
    this.slivers,
    this.children,
    this.bottomBar,
    this.grouped = false,
    this.backgroundColor,
    this.controller,
    this.contentPadding,
    this.maxContentWidth,
  }) : assert(
         slivers != null || children != null,
         'A JamScaffold needs slivers or children.',
       );

  /// The page title (sentence case).
  final String title;

  /// Large title that collapses on scroll; false for an inline-only bar.
  final bool largeTitle;

  /// Replaces the automatic back chevron.
  final Widget? leading;

  /// Nav bar items on the right (`JamIconButton`, `JamTextButton`,
  /// `JamMenuButton`, an avatar).
  final List<Widget> trailing;

  /// Ignored: back is a bare chevron everywhere (spec §10.11). Kept so
  /// older call sites compile.
  final String? previousPageTitle;

  /// Shows the back chevron when the route can pop.
  final bool automaticallyImplyLeading;

  /// The page content, as slivers.
  final List<Widget>? slivers;

  /// The page content, as box widgets (wrapped in a sliver list).
  final List<Widget>? children;

  /// A pinned bottom action (one full-width `JamButton`). It sits on a
  /// `material` strip only while content scrolls under it.
  final Widget? bottomBar;

  /// `groupedBackground` instead of `background`.
  final bool grouped;

  /// Overrides the page colour.
  final Color? backgroundColor;

  final ScrollController? controller;

  /// Padding around [children] (default: none — sections bring their own
  /// margins).
  final EdgeInsetsGeometry? contentPadding;

  /// Holds the content (and the large title, and the bottom bar) to a
  /// column this wide, centred in the space the page actually has — use
  /// `JamContentWidth.reading` for lists and forms on wide windows. Null:
  /// edge to edge.
  final double? maxContentWidth;

  @override
  State<JamScaffold> createState() => _JamScaffoldState();
}

class _JamScaffoldState extends State<JamScaffold> {
  bool _contentUnderBottom = false;

  /// Content has scrolled up under the inline bar: only then does the bar
  /// blur what is behind it. At rest it is clear, and a blur there would
  /// smear whatever sits just under its edge (a page's cover and its
  /// shadow) into a hard band.
  bool _contentUnderTop = false;

  bool _onMetrics(ScrollMetrics metrics, int depth) {
    // The page's own scroll view, not a list nested in it.
    if (depth != 0) return false;
    final under = metrics.extentAfter > 0.5;
    final top = metrics.extentBefore > 0;
    if (under != _contentUnderBottom || top != _contentUnderTop) {
      setState(() {
        _contentUnderBottom = under;
        _contentUnderTop = top;
      });
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final bg =
        widget.backgroundColor ??
        (widget.grouped ? colors.groupedBackground : colors.background);
    final hasBottom = widget.bottomBar != null;
    final maxWidth = widget.maxContentWidth;
    // Read here, above the Scaffold: inside its body (where a reading
    // column's LayoutBuilder builds) the top padding already counts the
    // inline bar, and would push the content down by its height again.
    final topInset = MediaQuery.paddingOf(context).top;

    Widget body = maxWidth == null
        ? _scrollView(context, 0, topInset)
        : LayoutBuilder(
            builder: (context, constraints) => _scrollView(
              context,
              math.max(0, (constraints.maxWidth - maxWidth) / 2),
              topInset,
            ),
          );

    body = NotificationListener<ScrollMetricsNotification>(
      onNotification: (n) => _onMetrics(n.metrics, n.depth),
      child: NotificationListener<ScrollUpdateNotification>(
        onNotification: (n) => _onMetrics(n.metrics, n.depth),
        child: body,
      ),
    );

    Widget? bottomBar = widget.bottomBar;
    if (bottomBar != null && maxWidth != null) {
      final side = JamSpace.pageFor(MediaQuery.sizeOf(context).width);
      bottomBar = Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth - side * 2),
          child: bottomBar,
        ),
      );
    }

    final page = Scaffold(
      backgroundColor: bg,
      extendBodyBehindAppBar: true,
      appBar: widget.largeTitle
          ? null
          : JamNavBar(
              title: widget.title,
              leading: widget.leading,
              trailing: widget.trailing,
              automaticallyImplyLeading: widget.automaticallyImplyLeading,
              blur: _contentUnderTop,
            ),
      body: Stack(
        children: [
          Positioned.fill(child: body),
          if (hasBottom)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: JamBottomBar(
                showMaterial: _contentUnderBottom,
                child: bottomBar!,
              ),
            ),
        ],
      ),
    );

    return CupertinoPageScaffoldBackgroundColor(color: bg, child: page);
  }

  /// The scroll view, its content held [side] in from each edge and, under
  /// an inline bar, started [topInset] (the status bar) plus the bar down.
  Widget _scrollView(BuildContext context, double side, double topInset) {
    final colors = context.jamColors;
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final hasBottom = widget.bottomBar != null;
    final spacer = hasBottom
        ? JamMetrics.buttonHeight + JamSpace.lg + jamBottomBarInset(bottomInset)
        : JamSpace.xxxl + bottomInset;

    final slivers = <Widget>[...?widget.slivers];
    // A last sliver that fills the remaining space (an empty state) takes
    // the bottom clearance inside itself: a spacer after it would make the
    // empty page scroll, and paint the bottom bar's strip under nothing.
    var fills = false;
    final children = widget.children;
    if (children == null && slivers.isNotEmpty) {
      final last = slivers.last;
      if (last is SliverFillRemaining && last.child != null) {
        fills = true;
        slivers[slivers.length - 1] = SliverFillRemaining(
          key: last.key,
          hasScrollBody: last.hasScrollBody,
          fillOverscroll: last.fillOverscroll,
          child: Padding(
            padding: EdgeInsets.only(bottom: spacer),
            child: last.child,
          ),
        );
      }
    }

    Widget column(Widget sliver) => side <= 0
        ? sliver
        : SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: side),
            sliver: sliver,
          );

    final content = <Widget>[
      for (final sliver in slivers) column(sliver),
      if (children != null)
        column(
          SliverPadding(
            padding: widget.contentPadding ?? EdgeInsets.zero,
            sliver: SliverList.list(children: children),
          ),
        ),
      if (!fills) SliverToBoxAdapter(child: SizedBox(height: spacer)),
    ];

    final width = MediaQuery.sizeOf(context).width;
    final navPadding = _navPaddingFor(width, side);
    final leading = widget.leading ?? _backButton(context);

    if (widget.largeTitle) {
      return CustomScrollView(
        controller: widget.controller,
        slivers: [
          CupertinoSliverNavigationBar(
            // Cupertino insets the large title by a fixed 16; the rest of
            // the margin (20 on wide phones, a reading column's side)
            // is ours to add.
            largeTitle: Padding(
              padding: EdgeInsetsDirectional.only(
                start: math.max(0, navPadding.start - _kCupertinoTitleInset),
              ),
              child: Text(widget.title),
            ),
            middle: Text(widget.title),
            alwaysShowMiddle: false,
            leading: leading,
            automaticallyImplyLeading: widget.automaticallyImplyLeading,
            trailing: _trailing(),
            backgroundColor: colors.material,
            border: _border(context),
            transitionBetweenRoutes: false,
            padding: navPadding,
          ),
          ...content,
        ],
      );
    }
    return CustomScrollView(
      controller: widget.controller,
      slivers: [
        // Content starts under the inline bar, not under the status bar:
        // the bar floats over the body (`extendBodyBehindAppBar`), and
        // [topInset] was read above the Scaffold, so it does not include
        // the bar's height.
        SliverToBoxAdapter(
          child: SizedBox(height: topInset + JamMetrics.navBarHeight),
        ),
        ...content,
      ],
    );
  }

  Widget? _backButton(BuildContext context) =>
      widget.automaticallyImplyLeading ? jamBackButtonFor(context) : null;

  Widget? _trailing() => widget.trailing.isEmpty
      ? null
      : Row(mainAxisSize: MainAxisSize.min, children: widget.trailing);
}

/// The fixed leading inset Cupertino gives a large title.
const double _kCupertinoTitleInset = 16;

/// The nav bar's insets: the large title on the page margin (plus a reading
/// column's [side]); trailing icon buttons' glyphs on the same margin.
EdgeInsetsDirectional _navPaddingFor(double width, [double side = 0]) {
  final margin = JamSpace.pageFor(width);
  return EdgeInsetsDirectional.only(
    start: side + margin,
    // A 44 icon button carries ~11 of air around a 22 glyph.
    end: side + math.max(JamSpace.xs, margin - kJamNavTrailingAir),
  );
}

/// How far inside the page margin the nav bar's trailing edge stops: the
/// air a 44 icon button carries around its 22 glyph, so the glyph — not its
/// box — ends on the margin. A trailing item drawn to its box's edge (the
/// "more" circle) gives this much back to land on the margin too.
const double kJamNavTrailingAir = 12;

/// The bare back chevron (spec §10.11), when [context]'s route can go back
/// — never a "‹ Settings" label, whatever route the page sits in. Null when
/// there is nothing to go back to, or the route is a full-screen cover
/// (which closes with its own button).
Widget? jamBackButtonFor(BuildContext context) {
  final route = ModalRoute.of(context);
  if (route == null || !route.canPop) return null;
  if (route is PageRoute && route.fullscreenDialog) return null;
  // An empty title is how Cupertino's own back button is told "chevron
  // only": it otherwise reads the previous route's title off a
  // CupertinoPageRoute.
  return const CupertinoNavigationBarBackButton(previousPageTitle: '');
}

/// Where a pinned bottom action sits above the window's bottom edge, given
/// the bottom safe area [bottomInset]: on the home indicator's inset on
/// iOS (≈ 34, which already leaves ~20 of air above the indicator); a small
/// gesture inset (Android's ≈ 24) gets air added so the button does not sit
/// on the handle; no inset at all gets 16.
double jamBottomBarInset(double bottomInset) {
  if (bottomInset >= 30) return bottomInset;
  if (bottomInset > 0) return bottomInset + JamSpace.md;
  return JamSpace.lg;
}

Border _border(BuildContext context) => Border(
  bottom: BorderSide(
    color: context.jamColors.separator,
    width: 1 / MediaQuery.devicePixelRatioOf(context),
  ),
);

/// The inline nav bar on its own: 17-semibold centred title, blurred
/// `material` that (and the hairline) appears once content scrolls under
/// it. Use as a `Scaffold.appBar` with `extendBodyBehindAppBar: true`, under
/// a `CupertinoPageScaffoldBackgroundColor` (JamScaffold does both).
class JamNavBar extends StatelessWidget
    implements ObstructingPreferredSizeWidget {
  const JamNavBar({
    super.key,
    required this.title,
    this.leading,
    this.trailing = const <Widget>[],
    this.previousPageTitle,
    this.automaticallyImplyLeading = true,
    this.alwaysOpaque = false,
    this.blur = true,
  });

  final String title;
  final Widget? leading;
  final List<Widget> trailing;

  /// Ignored: back is a bare chevron everywhere (spec §10.11).
  final String? previousPageTitle;
  final bool automaticallyImplyLeading;

  /// Shows the material and hairline even before anything scrolls under.
  final bool alwaysOpaque;

  /// Blurs what is behind the bar. [JamScaffold] turns it on only once
  /// content scrolls under: a clear bar at rest that still blurred would
  /// smear what sits just under its edge into a band.
  final bool blur;

  @override
  Size get preferredSize => const Size.fromHeight(JamMetrics.navBarHeight);

  @override
  bool shouldFullyObstruct(BuildContext context) => false;

  @override
  Widget build(BuildContext context) {
    final bar = CupertinoNavigationBar(
      middle: Text(title),
      leading:
          leading ??
          (automaticallyImplyLeading ? jamBackButtonFor(context) : null),
      automaticallyImplyLeading: automaticallyImplyLeading,
      trailing: trailing.isEmpty
          ? null
          : Row(mainAxisSize: MainAxisSize.min, children: trailing),
      backgroundColor: context.jamColors.material,
      border: _border(context),
      // Status bar icons follow the theme, not the (clear) bar at rest.
      brightness: Theme.of(context).brightness,
      automaticBackgroundVisibility: !alwaysOpaque,
      enableBackgroundFilterBlur: alwaysOpaque || blur,
      transitionBetweenRoutes: false,
      padding: _navPaddingFor(MediaQuery.sizeOf(context).width),
    );
    if (alwaysOpaque) return bar;
    // At rest Cupertino paints the page colour it finds here, which hides
    // whatever reaches up under the bar (a large cover's shadow). A clear
    // page colour makes the bar clear until content scrolls under it.
    final page = CupertinoPageScaffoldBackgroundColor.maybeOf(context);
    return CupertinoPageScaffoldBackgroundColor(
      color: (page ?? context.jamColors.background).withValues(alpha: 0),
      child: bar,
    );
  }
}

/// A pinned bottom action area: page-margin padding, above the home
/// indicator (see [jamBottomBarInset]), on a `material` strip (with a top
/// hairline) when [showMaterial].
class JamBottomBar extends StatelessWidget {
  const JamBottomBar({
    super.key,
    required this.child,
    this.showMaterial = false,
  });

  final Widget child;
  final bool showMaterial;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final width = MediaQuery.sizeOf(context).width;
    final bottom = MediaQuery.paddingOf(context).bottom;
    final padded = Padding(
      padding: EdgeInsets.fromLTRB(
        JamSpace.pageFor(width),
        JamSpace.lg,
        JamSpace.pageFor(width),
        jamBottomBarInset(bottom),
      ),
      child: child,
    );
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return Stack(
      children: [
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedOpacity(
              opacity: showMaterial ? 1 : 0,
              duration: reduceMotion ? Duration.zero : JamDuration.fast,
              curve: JamCurve.standard,
              child: JamBlurSurface(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border(
                      top: BorderSide(
                        color: colors.separator,
                        width: 1 / MediaQuery.devicePixelRatioOf(context),
                      ),
                    ),
                  ),
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          ),
        ),
        padded,
      ],
    );
  }
}
