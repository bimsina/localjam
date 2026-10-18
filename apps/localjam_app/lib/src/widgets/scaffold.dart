/// The iOS page: a large title that collapses into an inline 17-semibold
/// title in a blurred `material` nav bar on scroll, with the hairline only
/// once content scrolls under it (DESIGN_SPEC v3 §5 JamScaffold).
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

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Scaffold;

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
  }) : assert(
         slivers != null || children != null,
         'A JamScaffold needs slivers or children.',
       );

  /// The page title (Title Case).
  final String title;

  /// Large title that collapses on scroll; false for an inline-only bar.
  final bool largeTitle;

  /// Replaces the automatic back chevron.
  final Widget? leading;

  /// Nav bar items on the right (`JamIconButton`, `JamTextButton`,
  /// `JamMenuButton`, an avatar).
  final List<Widget> trailing;

  /// "‹ Nearby"-style label beside the back chevron.
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

  @override
  State<JamScaffold> createState() => _JamScaffoldState();
}

class _JamScaffoldState extends State<JamScaffold> {
  bool _contentUnderBottom = false;

  bool _onMetrics(ScrollMetrics metrics) {
    final under = metrics.extentAfter > 0.5;
    if (under != _contentUnderBottom) {
      setState(() => _contentUnderBottom = under);
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final bg =
        widget.backgroundColor ??
        (widget.grouped ? colors.groupedBackground : colors.background);
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final hasBottom = widget.bottomBar != null;

    Widget body;
    final children = widget.children;
    final content = <Widget>[
      ...?widget.slivers,
      if (children != null)
        SliverPadding(
          padding: widget.contentPadding ?? EdgeInsets.zero,
          sliver: SliverList.list(children: children),
        ),
      SliverToBoxAdapter(
        child: SizedBox(
          height: hasBottom
              ? JamMetrics.buttonHeight + JamSpace.lg * 2 + bottomInset
              : JamSpace.xxxl + bottomInset,
        ),
      ),
    ];

    if (widget.largeTitle) {
      body = CustomScrollView(
        controller: widget.controller,
        slivers: [
          CupertinoSliverNavigationBar(
            largeTitle: Text(widget.title),
            middle: Text(widget.title),
            alwaysShowMiddle: false,
            leading: widget.leading,
            automaticallyImplyLeading: widget.automaticallyImplyLeading,
            previousPageTitle: widget.previousPageTitle,
            trailing: _trailing(),
            backgroundColor: colors.material,
            border: _border(context),
            transitionBetweenRoutes: false,
            padding: _navPadding,
          ),
          ...content,
        ],
      );
    } else {
      body = CustomScrollView(
        controller: widget.controller,
        slivers: [
          SliverToBoxAdapter(
            child: SizedBox(height: MediaQuery.paddingOf(context).top),
          ),
          ...content,
        ],
      );
    }

    body = NotificationListener<ScrollMetricsNotification>(
      onNotification: (n) => _onMetrics(n.metrics),
      child: NotificationListener<ScrollUpdateNotification>(
        onNotification: (n) => _onMetrics(n.metrics),
        child: body,
      ),
    );

    final page = Scaffold(
      backgroundColor: bg,
      extendBodyBehindAppBar: true,
      appBar: widget.largeTitle
          ? null
          : JamNavBar(
              title: widget.title,
              leading: widget.leading,
              trailing: widget.trailing,
              previousPageTitle: widget.previousPageTitle,
              automaticallyImplyLeading: widget.automaticallyImplyLeading,
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
                child: widget.bottomBar!,
              ),
            ),
        ],
      ),
    );

    return CupertinoPageScaffoldBackgroundColor(color: bg, child: page);
  }

  Widget? _trailing() => widget.trailing.isEmpty
      ? null
      : Row(mainAxisSize: MainAxisSize.min, children: widget.trailing);
}

const EdgeInsetsDirectional _navPadding = EdgeInsetsDirectional.only(
  start: JamSpace.lg,
  end: JamSpace.xs,
);

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
  });

  final String title;
  final Widget? leading;
  final List<Widget> trailing;
  final String? previousPageTitle;
  final bool automaticallyImplyLeading;

  /// Shows the material and hairline even before anything scrolls under.
  final bool alwaysOpaque;

  @override
  Size get preferredSize => const Size.fromHeight(JamMetrics.navBarHeight);

  @override
  bool shouldFullyObstruct(BuildContext context) => false;

  @override
  Widget build(BuildContext context) => CupertinoNavigationBar(
    middle: Text(title),
    leading: leading,
    automaticallyImplyLeading: automaticallyImplyLeading,
    previousPageTitle: previousPageTitle,
    trailing: trailing.isEmpty
        ? null
        : Row(mainAxisSize: MainAxisSize.min, children: trailing),
    backgroundColor: context.jamColors.material,
    border: _border(context),
    automaticBackgroundVisibility: !alwaysOpaque,
    transitionBetweenRoutes: false,
    padding: _navPadding,
  );
}

/// A pinned bottom action area: page-margin padding, above the home
/// indicator, on a `material` strip (with a top hairline) when
/// [showMaterial].
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
        bottom > 0 ? bottom : JamSpace.lg,
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
