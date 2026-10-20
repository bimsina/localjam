/// Grouped sections (DESIGN_SPEC v3 §5 "Grouped list").
///
/// ```dart
/// JamSection(
///   header: 'Appearance',
///   footer: 'Follows your device unless you pick one.',
///   children: [
///     JamRow(title: 'System', checked: mode == system, onTap: …),
///     JamRow(title: 'Light', checked: mode == light, onTap: …),
///   ],
/// )
/// ```
///
/// Inset grouped by default: a rounded [JamRadius.section] block in
/// `groupedSurface` (or `elevatedGroupedSurface` inside a grouped sheet,
/// whose ground is the grouped paper so the block stands off it), 16 from
/// the screen edge, rows separated by hairlines inset to their text.
/// [JamSection.plain] drops the block for Apple-Music-style plain lists.
library;

import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../design/tokens.dart';
import '../design/typography.dart';
import 'buttons.dart';
import 'list.dart';

/// Tells sections below it which surface their rows sit on. Grouped sheets
/// publish [JamColors.elevatedGroupedSurface]; screens need not publish
/// anything.
class JamGroupedSurface extends InheritedWidget {
  const JamGroupedSurface({
    super.key,
    required this.elevated,
    required super.child,
  });

  /// Whether sections should use the elevated (sheet) surface.
  final bool elevated;

  static bool elevatedOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<JamGroupedSurface>()
          ?.elevated ??
      false;

  @override
  bool updateShouldNotify(JamGroupedSurface old) => old.elevated != elevated;
}

/// A titled group of rows.
class JamSection extends StatelessWidget {
  const JamSection({
    super.key,
    this.header,
    this.headerTrailing,
    this.prominentHeader = false,
    this.footer,
    this.children,
    this.child,
    this.margin,
    this.elevated,
    this.bordered = false,
  }) : plain = false,
       assert(
         child != null || children != null,
         'A JamSection needs either a child or children.',
       );

  /// A plain (ungrouped) section: no rounded block, no side margin — rows
  /// run edge to edge on the screen's `background`.
  const JamSection.plain({
    super.key,
    this.header,
    this.headerTrailing,
    this.prominentHeader = true,
    this.footer,
    this.children,
    this.child,
    this.margin,
  }) : plain = true,
       elevated = false,
       bordered = false,
       assert(
         child != null || children != null,
         'A JamSection needs either a child or children.',
       );

  /// Sentence case. Footnote `secondaryLabel` by default; title3 `label`
  /// when [prominentHeader] ("Recent", "Up next").
  final String? header;

  /// Right-aligned beside the header: a count, a `JamButton.plain`
  /// ("See all").
  final Widget? headerTrailing;

  /// Title3 header in `label` instead of footnote `secondaryLabel`.
  final bool prominentHeader;

  /// One sentence under the block, footnote `secondaryLabel`.
  final String? footer;

  /// Rows. `JamRow`s draw their own inset hairlines; anything else gets a
  /// 16-inset hairline between it and the next child.
  final List<Widget>? children;

  /// Custom content instead of rows.
  final Widget? child;

  /// Overrides the outer margin (default: the page margin left/right).
  final EdgeInsetsGeometry? margin;

  /// Forces the elevated (sheet) row surface. Null reads [JamGroupedSurface].
  final bool? elevated;

  /// A 0.5 `separator` edge around the block, like Nearby's cards — for a
  /// section on a page's `background` (paper), where the block would
  /// otherwise have no edge in light mode.
  final bool bordered;

  final bool plain;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final width = MediaQuery.sizeOf(context).width;
    final side = plain ? 0.0 : JamSpace.pageFor(width);
    final rows = children;

    Widget? body = child;
    if (rows != null) {
      body = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < rows.length; i++)
            JamRowScope(
              isLast: i == rows.length - 1,
              plain: plain,
              child: rows[i] is JamSelfSeparatingRow
                  ? rows[i]
                  : (i == rows.length - 1
                        ? rows[i]
                        : Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              rows[i],
                              JamHairline(
                                indent: kJamRowInset,
                                endIndent: plain ? kJamRowInset : 0,
                              ),
                            ],
                          )),
            ),
        ],
      );
    }

    if (!plain) {
      final elevated = this.elevated ?? JamGroupedSurface.elevatedOf(context);
      // A block of one row (or of one custom cell) is a lone row: 12,
      // whatever its height. More rows: 20, held under half the block's
      // height.
      final lone = rows == null || rows.length == 1;
      body = ClipRRect(
        clipper: _SectionClipper(lone: lone),
        child: ColoredBox(
          color: elevated
              ? colors.elevatedGroupedSurface
              : colors.groupedSurface,
          child: body,
        ),
      );
      if (bordered) {
        body = CustomPaint(
          foregroundPainter: _SectionEdge(colors.separator, lone: lone),
          child: body,
        );
      }
    }

    final header = this.header;
    final footer = this.footer;
    const textInset = kJamRowInset;
    // A plain trailing button carries its own padding; its *text* lands on
    // the rows' trailing inset, not the button's edge.
    final trailing = headerTrailing;
    final trailingInset = trailing == null
        ? textInset
        : trailing is JamButton &&
              trailing.variant == JamButtonVariant.plain &&
              !trailing.expand
        ? textInset - jamPlainButtonPadding(trailing.size)
        : textInset;

    return Padding(
      padding: margin ?? EdgeInsets.symmetric(horizontal: side),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (header != null || headerTrailing != null)
            Padding(
              padding: EdgeInsetsDirectional.fromSTEB(
                textInset,
                0,
                trailingInset,
                prominentHeader ? JamSpace.xs : JamSpace.sectionHeader,
              ),
              child: _HeaderBar(
                // A plain button's text, not its padding, lines up with the
                // header's when it wraps under it.
                wrapIndent: trailingInset == textInset
                    ? 0
                    : textInset - trailingInset,
                header: header == null
                    ? const SizedBox.shrink()
                    : Semantics(
                        header: true,
                        child: JamWholeWords(
                          child: Text(
                            header,
                            style: prominentHeader
                                ? context.jamTitle3
                                : context.jamFootnote.copyWith(
                                    color: colors.secondaryLabel,
                                  ),
                          ),
                        ),
                      ),
                trailing: headerTrailing,
              ),
            ),
          body!,
          if (footer != null)
            Padding(
              padding: EdgeInsetsDirectional.fromSTEB(
                textInset,
                JamSpace.sectionHeader,
                textInset,
                0,
              ),
              child: Text(
                footer,
                style: context.jamFootnote.copyWith(
                  color: colors.secondaryLabel,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A section block's corner: [JamRadius.loneRow] for a [lone] row,
/// otherwise [JamRadius.sectionFor] its height.
double _blockRadius(Size size, {required bool lone}) =>
    lone ? JamRadius.loneRow : JamRadius.sectionFor(size.height);

/// Rounds a section's block ([_blockRadius]).
class _SectionClipper extends CustomClipper<RRect> {
  const _SectionClipper({required this.lone});

  final bool lone;

  @override
  RRect getClip(Size size) => RRect.fromRectAndRadius(
    Offset.zero & size,
    Radius.circular(_blockRadius(size, lone: lone)),
  );

  @override
  bool shouldReclip(_SectionClipper oldClipper) => oldClipper.lone != lone;
}

/// A [JamSection.bordered] block's edge, on the block's own radius.
class _SectionEdge extends CustomPainter {
  const _SectionEdge(this.color, {required this.lone});

  final Color color;
  final bool lone;

  static const double _width = 0.5;

  @override
  void paint(Canvas canvas, Size size) {
    const inset = _width / 2;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        (Offset.zero & size).deflate(inset),
        Radius.circular(_blockRadius(size, lone: lone) - inset),
      ),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = _width
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_SectionEdge old) =>
      old.color != color || old.lone != lone;
}

/// Stacks sections with the standard [JamSpace.section] gap.
class JamSectionList extends StatelessWidget {
  const JamSectionList({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      for (var i = 0; i < children.length; i++) ...[
        if (i > 0) const SizedBox(height: JamSpace.section),
        children[i],
      ],
    ],
  );
}

/// A section header and its trailing action ("Recent" and See all): side by
/// side when both fit on one line, else the action wraps under the header
/// (N3) — at the largest text sizes "Recent" beside See all left the header
/// too narrow for its own word, and it broke as "Recen / t".
class _HeaderBar extends MultiChildRenderObjectWidget {
  _HeaderBar({
    required Widget header,
    required Widget? trailing,
    required this.wrapIndent,
  }) : super(children: [header, ?trailing]);

  /// How far the trailing action moves toward the start once it wraps, so
  /// its text — not its tap padding — sits on the header's edge.
  final double wrapIndent;

  @override
  _RenderHeaderBar createRenderObject(BuildContext context) =>
      _RenderHeaderBar(wrapIndent, Directionality.of(context));

  @override
  void updateRenderObject(BuildContext context, _RenderHeaderBar renderObject) {
    renderObject
      ..wrapIndent = wrapIndent
      ..textDirection = Directionality.of(context);
  }
}

class _HeaderBarParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderHeaderBar extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _HeaderBarParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _HeaderBarParentData> {
  _RenderHeaderBar(this._wrapIndent, this._textDirection);

  double _wrapIndent;
  set wrapIndent(double value) {
    if (value == _wrapIndent) return;
    _wrapIndent = value;
    markNeedsLayout();
  }

  TextDirection _textDirection;
  set textDirection(TextDirection value) {
    if (value == _textDirection) return;
    _textDirection = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _HeaderBarParentData) {
      child.parentData = _HeaderBarParentData();
    }
  }

  /// Lays out (or, [dry], measures) both and places them: the header's and
  /// the action's sizes, and whether the action wrapped.
  Size _layout(BoxConstraints constraints, {required bool dry}) {
    final header = firstChild!;
    final trailing = childAfter(header);
    final loose = constraints.loosen();
    Size sizeOf(RenderBox child) {
      if (dry) return child.getDryLayout(loose);
      child.layout(loose, parentUsesSize: true);
      return child.size;
    }

    final headerSize = sizeOf(header);
    if (trailing == null) {
      return constraints.constrain(
        Size(constraints.maxWidth, headerSize.height),
      );
    }
    final trailingSize = sizeOf(trailing);
    final width = constraints.maxWidth;
    final rtl = _textDirection == TextDirection.rtl;
    double startX(double childWidth, double x) =>
        rtl ? width - childWidth - x : x;
    final beside = headerSize.width + trailingSize.width <= width;
    final Size size;
    if (beside) {
      final height = math.max(headerSize.height, trailingSize.height);
      size = constraints.constrain(Size(width, height));
      if (!dry) {
        (header.parentData! as _HeaderBarParentData).offset = Offset(
          startX(headerSize.width, 0),
          (height - headerSize.height) / 2,
        );
        (trailing.parentData! as _HeaderBarParentData).offset = Offset(
          startX(trailingSize.width, width - trailingSize.width),
          (height - trailingSize.height) / 2,
        );
      }
    } else {
      size = constraints.constrain(
        Size(width, headerSize.height + trailingSize.height),
      );
      if (!dry) {
        (header.parentData! as _HeaderBarParentData).offset = Offset(
          startX(headerSize.width, 0),
          0,
        );
        (trailing.parentData! as _HeaderBarParentData).offset = Offset(
          startX(trailingSize.width, -_wrapIndent),
          headerSize.height,
        );
      }
    }
    return size;
  }

  @override
  void performLayout() {
    size = _layout(constraints, dry: false);
  }

  @override
  Size computeDryLayout(covariant BoxConstraints constraints) =>
      _layout(constraints, dry: true);

  @override
  double computeMinIntrinsicWidth(double height) {
    var widest = 0.0;
    for (var c = firstChild; c != null; c = childAfter(c)) {
      widest = math.max(widest, c.getMinIntrinsicWidth(height));
    }
    return widest;
  }

  @override
  double computeMaxIntrinsicWidth(double height) {
    var sum = 0.0;
    for (var c = firstChild; c != null; c = childAfter(c)) {
      sum += c.getMaxIntrinsicWidth(height);
    }
    return sum;
  }

  @override
  double computeMinIntrinsicHeight(double width) =>
      _layout(BoxConstraints(maxWidth: width), dry: true).height;

  @override
  double computeMaxIntrinsicHeight(double width) =>
      computeMinIntrinsicHeight(width);

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) =>
      defaultComputeDistanceToFirstActualBaseline(baseline);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);
}
