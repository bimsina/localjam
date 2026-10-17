/// A titled group of rows — the Apple Music / iOS Settings idiom the old
/// screens spelled out by hand eight times ("a Card wrapping a bare Column of
/// ListTiles").
///
/// Restyled to §4: the heading is `jamTitle` on the canvas, the group under it
/// is `flat` — no shadow at all, just a 0.5 dp hairline around it and between
/// its rows — and consecutive sections are separated by [JamSpace.section].
library;

import 'package:flutter/material.dart';

import '../design/tokens.dart';
import '../design/typography.dart';

class JamSection extends StatelessWidget {
  const JamSection({
    super.key,
    this.title,
    this.trailing,
    this.child,
    this.children,
  }) : assert(
         child != null || children != null,
         'A JamSection needs either a child or children.',
       );

  /// Section heading, above the group.
  final String? title;

  /// Optional right-aligned adornment for the heading (a count, an action).
  final Widget? trailing;

  /// The group's content, laid out by the caller.
  final Widget? child;

  /// Rows to lay out as a list group, separated by 0.5 dp hairlines. Use this
  /// instead of building a `Column` with `Divider`s by hand — the hairlines
  /// go *between* rows only, never above the first or below the last, which
  /// is what stops a group from growing a double rule against its own border.
  final List<Widget>? children;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final heading = title;
    final rows = children;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (heading != null)
          Padding(
            padding: const EdgeInsets.only(
              left: JamSpace.xs,
              bottom: JamSpace.md,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text(heading, style: context.jamTitle),
                  ),
                ),
                ?trailing,
              ],
            ),
          ),
        // Material, not a DecoratedBox: ListTile paints its background and
        // ink on the nearest Material ancestor, so a coloured box in between
        // hides every splash (Flutter asserts on exactly this).
        Material(
          color: colors.surface,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(JamRadius.lg),
            side: BorderSide(color: colors.separator, width: 0.5),
          ),
          child:
              child ??
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < rows!.length; i++) ...[
                    if (i > 0)
                      Divider(
                        height: 0.5,
                        thickness: 0.5,
                        indent: JamSpace.lg,
                        color: colors.separator,
                      ),
                    rows[i],
                  ],
                ],
              ),
        ),
      ],
    );
  }
}

/// Stacks [JamSection]s with the standard [JamSpace.section] gap between them,
/// so a screen never has to remember the number.
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
