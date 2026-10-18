/// iOS list rows (DESIGN_SPEC v3 §5 "Grouped list" / "Plain list rows").
///
/// [JamRow] is one row: optional leading (an icon in a 30 box, an avatar, a
/// cover), a body-sized title, an optional subheadline subtitle, and a
/// trailing accessory (value + chevron, chevron, checkmark, switch, small
/// button, menu). It paints no ground of its own — a `JamSection` paints the
/// grouped surface, a plain list sits on `background` — only the press
/// highlight and its own bottom hairline, inset to the title's leading edge.
///
/// Inside a `JamSection` the hairline is automatic (every row but the last).
/// In a plain list, pass `separator: true` to every row but the last.
library;

import 'package:flutter/cupertino.dart';

import '../design/tokens.dart';
import '../design/typography.dart';
import 'artwork.dart';
import 'avatar.dart';
import 'pressable.dart';
import 'switch.dart';

/// Where a row sits, published by `JamSection` to each child.
class JamRowScope extends InheritedWidget {
  const JamRowScope({super.key, required this.isLast, required super.child});

  /// The last row in its group draws no separator.
  final bool isLast;

  static JamRowScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<JamRowScope>();

  @override
  bool updateShouldNotify(JamRowScope old) => old.isLast != isLast;
}

/// A 0.5 pt (one physical pixel) hairline in `separator`.
class JamHairline extends StatelessWidget {
  const JamHairline({super.key, this.indent = 0, this.color});

  /// Leading inset.
  final double indent;

  /// Overrides `separator`.
  final Color? color;

  /// One physical pixel for [context].
  static double thicknessOf(BuildContext context) =>
      1 / MediaQuery.devicePixelRatioOf(context);

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsetsDirectional.only(start: indent),
    child: SizedBox(
      height: thicknessOf(context),
      width: double.infinity,
      child: ColoredBox(color: color ?? context.jamColors.separator),
    ),
  );
}

/// A row that draws its own inset hairline inside a `JamSection` (so the
/// section does not add one). [JamRow], [JamSwitchRow] and `JamTrackRow`
/// implement it; implement it on a custom row that reads [JamRowScope].
abstract interface class JamSelfSeparatingRow implements Widget {}

/// The row's leading-edge inset (16) — exposed so custom rows line up.
const double kJamRowInset = JamSpace.lg;

/// The gap between a row's leading widget and its title.
const double kJamRowLeadingGap = JamSpace.md;

/// One iOS list row.
class JamRow extends StatelessWidget implements JamSelfSeparatingRow {
  const JamRow({
    super.key,
    required this.title,
    this.subtitle,
    this.subtitleColor,
    this.leading,
    this.leadingWidth,
    this.icon,
    this.iconColor,
    this.value,
    this.chevron = false,
    this.checked = false,
    this.trailing,
    this.onTap,
    this.onLongPress,
    this.destructive = false,
    this.tinted = false,
    this.centered = false,
    this.enabled = true,
    this.separator,
    this.titleMaxLines = 1,
    this.subtitleMaxLines = 2,
    this.semanticLabel,
  }) : toggled = null,
       onToggle = null;

  /// A switch row: the iOS layout for a boolean setting. The switch is the
  /// control; tapping the rest of the row also flips it (no highlight).
  JamRow.toggle({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.leading,
    this.separator,
    required bool value,
    required ValueChanged<bool>? onChanged,
  }) : toggled = value,
       onToggle = onChanged == null ? null : (() => onChanged(!value)),
       enabled = onChanged != null,
       trailing = ExcludeSemantics(
         child: JamSwitch(value: value, onChanged: onChanged),
       ),
       semanticLabel = subtitle == null ? title : '$title. $subtitle',
       subtitleColor = null,
       leadingWidth = null,
       iconColor = null,
       value = null,
       chevron = false,
       checked = false,
       onTap = null,
       onLongPress = null,
       destructive = false,
       tinted = false,
       centered = false,
       titleMaxLines = 1,
       subtitleMaxLines = 2;

  /// Body, Title Case.
  final String title;

  /// Subheadline, `secondaryLabel` unless [subtitleColor] says otherwise
  /// (e.g. `warning` for "Still loading songs…").
  final String? subtitle;
  final Color? subtitleColor;

  /// An avatar, a cover, any widget. For a glyph use [icon].
  final Widget? leading;

  /// The width of [leading], for the separator inset. Read from a
  /// `JamAvatar` / `JamArtworkTile` / `JamArtwork` automatically; 40 for
  /// anything else.
  final double? leadingWidth;

  /// A 22 glyph in a 30 box, in [iconColor] (default tint).
  final IconData? icon;
  final Color? iconColor;

  /// Trailing value text in `secondaryLabel` ("System", "Everyone").
  final String? value;

  /// A trailing chevron (navigates).
  final bool chevron;

  /// A trailing tint checkmark (selected choice).
  final bool checked;

  /// Any trailing control (small button, menu), before [value].
  final Widget? trailing;

  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// Title (and icon) in `danger`.
  final bool destructive;

  /// Title (and icon) in tint — an action row like "Add Songs".
  final bool tinted;

  /// Centres the title (the lone destructive row at the end of a sheet).
  final bool centered;

  /// Disabled rows dim their title and ignore taps.
  final bool enabled;

  /// Forces the bottom hairline on or off. Null: on inside a section except
  /// for the last row, off elsewhere.
  final bool? separator;

  final int titleMaxLines;
  final int subtitleMaxLines;

  /// Overrides the announced label.
  final String? semanticLabel;

  /// A switch row's state; null for ordinary rows.
  final bool? toggled;

  /// A switch row's flip; null for ordinary rows.
  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context) => _JamRowBody(row: this);
}

class _JamRowBody extends StatelessWidget {
  const _JamRowBody({required this.row});

  final JamRow row;

  double? _leadingWidth() {
    if (row.icon != null) return JamMetrics.rowIconBox;
    final leading = row.leading;
    if (leading == null) return null;
    if (row.leadingWidth != null) return row.leadingWidth;
    if (leading is JamAvatar) return leading.size;
    if (leading is JamArtworkTile) return leading.size;
    if (leading is JamArtwork) return leading.size;
    return 40;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final enabled = row.enabled;
    final accent = row.destructive
        ? colors.danger
        : row.tinted
        ? colors.tint
        : null;
    final titleColor = !enabled
        ? colors.tertiaryLabel
        : (accent ?? colors.label);
    final subtitle = row.subtitle;
    final leadingWidth = row.centered ? null : _leadingWidth();
    final scope = JamRowScope.maybeOf(context);
    final showSeparator = row.separator ?? (scope != null && !scope.isLast);
    final inset =
        kJamRowInset +
        (leadingWidth == null ? 0 : leadingWidth + kJamRowLeadingGap);

    Widget? leading;
    if (row.icon != null) {
      leading = SizedBox(
        width: JamMetrics.rowIconBox,
        height: JamMetrics.rowIconBox,
        child: Icon(
          row.icon,
          size: JamMetrics.rowIcon,
          color: !enabled
              ? colors.tertiaryLabel
              : row.iconColor ?? accent ?? colors.tint,
        ),
      );
    } else if (!row.centered) {
      leading = row.leading;
    }

    final text = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: row.centered
          ? CrossAxisAlignment.center
          : CrossAxisAlignment.start,
      children: [
        Text(
          row.title,
          maxLines: row.titleMaxLines,
          overflow: TextOverflow.ellipsis,
          textAlign: row.centered ? TextAlign.center : TextAlign.start,
          style: context.jamBody.copyWith(color: titleColor),
        ),
        if (subtitle != null && subtitle.isNotEmpty) ...[
          const SizedBox(height: JamSpace.xxs),
          Text(
            subtitle,
            maxLines: row.subtitleMaxLines,
            overflow: TextOverflow.ellipsis,
            textAlign: row.centered ? TextAlign.center : TextAlign.start,
            style: context.jamSubheadline.copyWith(
              color: row.subtitleColor ?? colors.secondaryLabel,
            ),
          ),
        ],
      ],
    );

    final trailingParts = <Widget>[
      if (row.trailing != null) row.trailing!,
      if (row.value != null)
        Flexible(
          child: Padding(
            padding: const EdgeInsetsDirectional.only(start: JamSpace.sm),
            child: Text(
              row.value!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.end,
              style: context.jamBody.copyWith(color: colors.secondaryLabel),
            ),
          ),
        ),
      if (row.checked)
        Padding(
          padding: const EdgeInsetsDirectional.only(start: JamSpace.sm),
          child: Icon(CupertinoIcons.checkmark, size: 20, color: colors.tint),
        ),
      if (row.chevron)
        Padding(
          padding: const EdgeInsetsDirectional.only(start: JamSpace.sm),
          child: Icon(
            CupertinoIcons.chevron_forward,
            size: 17,
            color: colors.tertiaryLabel,
          ),
        ),
    ];

    final minHeight = subtitle == null || subtitle.isEmpty
        ? JamMetrics.rowHeight
        : JamMetrics.rowHeightSubtitle;

    Widget content = ConstrainedBox(
      constraints: BoxConstraints(minHeight: minHeight),
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(
          kJamRowInset,
          JamSpace.sm,
          kJamRowInset,
          JamSpace.sm,
        ),
        child: Row(
          children: [
            if (leading != null) ...[
              leading,
              const SizedBox(width: kJamRowLeadingGap),
            ],
            Expanded(child: text),
            if (trailingParts.isNotEmpty) ...[
              const SizedBox(width: JamSpace.sm),
              // Values may shrink; controls keep their size.
              Flexible(
                flex: 0,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: trailingParts,
                ),
              ),
            ],
          ],
        ),
      ),
    );

    if (showSeparator) {
      content = Stack(
        children: [
          content,
          PositionedDirectional(
            start: inset,
            end: 0,
            bottom: 0,
            child: const JamHairline(),
          ),
        ],
      );
    }

    final onToggle = row.onToggle;
    final tap = !enabled ? null : (row.onTap ?? onToggle);
    final interactive = tap != null || (enabled && row.onLongPress != null);
    if (interactive) {
      content = JamPressable(
        onTap: tap,
        onLongPress: enabled ? row.onLongPress : null,
        style: onToggle != null ? JamPressStyle.none : JamPressStyle.highlight,
        child: content,
      );
    }

    final toggled = row.toggled;
    return Semantics(
      container: true,
      button: row.onTap != null && toggled == null,
      toggled: toggled,
      selected: row.checked ? true : null,
      enabled: enabled,
      label: row.semanticLabel,
      onTap: tap,
      excludeSemantics: row.semanticLabel != null && toggled != null,
      child: MergeSemantics(child: content),
    );
  }
}

/// A switch row, kept for screens built before `JamRow.toggle`. Same look.
class JamSwitchRow extends StatelessWidget implements JamSelfSeparatingRow {
  const JamSwitchRow({
    super.key,
    required this.label,
    this.detail,
    required this.value,
    required this.onChanged,
    this.icon,
  });

  final String label;

  /// A subtitle under the label.
  final String? detail;

  final bool value;
  final ValueChanged<bool>? onChanged;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => JamRow.toggle(
    title: label,
    subtitle: detail,
    icon: icon,
    value: value,
    onChanged: onChanged,
  );
}
