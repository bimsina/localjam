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
  /// when [prominentHeader] ("Recent", "Up Next").
  final String? header;

  /// Right-aligned beside the header: a count, a `JamButton.plain`
  /// ("See All").
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
              child: rows[i] is JamSelfSeparatingRow
                  ? rows[i]
                  : (i == rows.length - 1
                        ? rows[i]
                        : Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              rows[i],
                              const JamHairline(indent: kJamRowInset),
                            ],
                          )),
            ),
        ],
      );
    }

    if (!plain) {
      final elevated = this.elevated ?? JamGroupedSurface.elevatedOf(context);
      body = ClipRRect(
        // 20, but a block of one 44 row would be a pill at 20: the radius
        // is held under half the block's height.
        clipper: const _SectionClipper(),
        child: ColoredBox(
          color: elevated
              ? colors.elevatedGroupedSurface
              : colors.groupedSurface,
          child: body,
        ),
      );
      if (bordered) {
        body = CustomPaint(
          foregroundPainter: _SectionEdge(colors.separator),
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
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: header == null
                        ? const SizedBox.shrink()
                        : Semantics(
                            header: true,
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
                  ?headerTrailing,
                ],
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

/// Rounds a section's block by [JamRadius.sectionFor] its height.
class _SectionClipper extends CustomClipper<RRect> {
  const _SectionClipper();

  @override
  RRect getClip(Size size) => RRect.fromRectAndRadius(
    Offset.zero & size,
    Radius.circular(JamRadius.sectionFor(size.height)),
  );

  @override
  bool shouldReclip(_SectionClipper oldClipper) => false;
}

/// A [JamSection.bordered] block's edge, on the block's own radius.
class _SectionEdge extends CustomPainter {
  const _SectionEdge(this.color);

  final Color color;

  static const double _width = 0.5;

  @override
  void paint(Canvas canvas, Size size) {
    const inset = _width / 2;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        (Offset.zero & size).deflate(inset),
        Radius.circular(JamRadius.sectionFor(size.height) - inset),
      ),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = _width
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_SectionEdge old) => old.color != color;
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
