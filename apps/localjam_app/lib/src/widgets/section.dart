/// A titled group of rows — the Apple Music / iOS Settings idiom the old
/// screens spelled out by hand eight times ("a Card wrapping a bare Column of
/// ListTiles").
library;

import 'package:flutter/material.dart';

import '../design/tokens.dart';
import '../design/typography.dart';

class JamSection extends StatelessWidget {
  const JamSection({super.key, this.title, this.trailing, required this.child});

  /// Section heading, above the group.
  final String? title;

  /// Optional right-aligned adornment for the heading (a count, an action).
  final Widget? trailing;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final heading = title;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (heading != null)
          Padding(
            padding: const EdgeInsets.only(
              left: JamSpace.xs,
              bottom: JamSpace.sm,
            ),
            child: Row(
              children: [
                Expanded(child: Text(heading, style: context.jamTitle)),
                ?trailing,
              ],
            ),
          ),
        DecoratedBox(
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: BorderRadius.circular(JamRadius.lg),
            border: Border.all(color: colors.separator, width: 0.5),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(JamRadius.lg),
            child: child,
          ),
        ),
      ],
    );
  }
}
