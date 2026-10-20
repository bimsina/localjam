/// List rows (DESIGN_SPEC v3 §5 "Grouped list" / "Plain list rows", in v4's
/// colours).
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
///
/// [JamAddSongsRow] is the app's one "Add Songs" affordance — Start a Jam's
/// song list and the queue both use it. [JamDisclosureChevron] is the one
/// chevron.
library;

import 'package:flutter/cupertino.dart';

import '../design/tokens.dart';
import '../design/typography.dart';
import 'artwork.dart';
import 'avatar.dart';
import 'pressable.dart';
import 'progress.dart';
import 'switch.dart';

/// Strings the shared rows say.
abstract final class JamListStrings {
  /// [JamAddSongsRow]'s default title.
  static const String addSongs = 'Add Songs';
}

/// Where a row sits, published by `JamSection` to each child.
class JamRowScope extends InheritedWidget {
  const JamRowScope({
    super.key,
    required this.isLast,
    this.plain = false,
    required super.child,
  });

  /// The last row in its group draws no separator.
  final bool isLast;

  /// The section is a plain list (`JamSection.plain`), not a block.
  final bool plain;

  static JamRowScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<JamRowScope>();

  @override
  bool updateShouldNotify(JamRowScope old) =>
      old.isLast != isLast || old.plain != plain;
}

/// Where a row's hairline ends, as an inset from its trailing edge: at the
/// block's edge inside an inset-grouped section, and where the row's
/// content ends ([inset]) in a plain list (CR-18) — the one rule every
/// self-separating row follows.
double jamHairlineEndInset(BuildContext context, double inset) {
  final scope = JamRowScope.maybeOf(context);
  return scope == null || scope.plain ? inset : 0;
}

/// A 0.5 pt (one physical pixel) hairline in `separator`.
class JamHairline extends StatelessWidget {
  const JamHairline({
    super.key,
    this.indent = 0,
    this.endIndent = 0,
    this.color,
  });

  /// Leading inset.
  final double indent;

  /// Trailing inset: a plain list's hairline stops where its content does,
  /// not at the screen's edge (CR-18).
  final double endIndent;

  /// Overrides `separator`.
  final Color? color;

  /// One physical pixel for [context].
  static double thicknessOf(BuildContext context) =>
      1 / MediaQuery.devicePixelRatioOf(context);

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsetsDirectional.only(start: indent, end: endIndent),
    child: SizedBox(
      height: thicknessOf(context),
      width: double.infinity,
      child: ColoredBox(color: color ?? context.jamColors.separator),
    ),
  );
}

/// A row that draws its own inset hairline inside a `JamSection` (so the
/// section does not add one). [JamRow], [JamAddSongsRow] and `JamTrackRow`
/// implement it; implement it on a custom row that reads [JamRowScope].
abstract interface class JamSelfSeparatingRow implements Widget {}

/// The row's leading-edge inset (16) — exposed so custom rows line up.
const double kJamRowInset = JamSpace.lg;

/// The gap between a row's leading widget and its title.
const double kJamRowLeadingGap = JamSpace.md;

/// How far inside its box the chevron's stroke ends: its glyph's side
/// bearing.
const double kJamChevronBearing = 4;

/// The one disclosure chevron: `chevron_forward` at
/// [JamIconSize.disclosure] in `tertiaryLabel` (or [color]) — on rows, the
/// Now Playing footer's "With Mia and Theo", the ended mini player. A row
/// says "this goes somewhere" exactly one way.
class JamDisclosureChevron extends StatelessWidget {
  const JamDisclosureChevron({super.key, this.color, this.endAligned = false});

  /// Overrides `tertiaryLabel` (the backdrop's secondary white, say).
  final Color? color;

  /// Moves the glyph [kJamChevronBearing] toward the end, so its *stroke*
  /// — not its box — ends on the trailing edge, where values and other
  /// rows' controls end (CR-13). Give it [kJamChevronBearing] less room
  /// before it to keep the gap.
  final bool endAligned;

  @override
  Widget build(BuildContext context) {
    final glyph = Icon(
      CupertinoIcons.chevron_forward,
      size: JamIconSize.disclosure,
      color: color ?? context.jamColors.tertiaryLabel,
    );
    if (!endAligned) return glyph;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    return Transform.translate(
      offset: Offset(rtl ? -kJamChevronBearing : kJamChevronBearing, 0),
      child: glyph,
    );
  }
}

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
    this.external = false,
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
       external = false,
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

  /// A 22 glyph in a 30 box, in [iconColor]. By default it follows the
  /// title: `danger` when [destructive], tint when [tinted], and otherwise
  /// `secondaryLabel` — raspberry is for what you tap and what is selected
  /// (D8), and a row's icon is neither.
  final IconData? icon;
  final Color? iconColor;

  /// Trailing value text in `secondaryLabel` ("System", "Everyone").
  final String? value;

  /// A trailing chevron (navigates).
  final bool chevron;

  /// A trailing ↗ instead of a chevron: the row leaves the app (a web
  /// page, the share sheet). Never both.
  final bool external;

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
              : row.iconColor ?? accent ?? colors.secondaryLabel,
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
          // The heavier glyph: SF's checkmark at body weight, not a hairline.
          child: Icon(
            CupertinoIcons.checkmark_alt,
            size: JamIconSize.row,
            color: colors.tint,
          ),
        ),
      // Both trailing glyphs end their *stroke* on the row's trailing
      // inset, where a value without one ends (CR-13).
      if (row.external && !row.chevron)
        Padding(
          padding: const EdgeInsetsDirectional.only(
            start: JamSpace.sm - _kArrowBearing,
          ),
          child: Transform.translate(
            offset: Offset(
              Directionality.of(context) == TextDirection.rtl
                  ? -_kArrowBearing
                  : _kArrowBearing,
              0,
            ),
            child: Icon(
              CupertinoIcons.arrow_up_right,
              size: JamIconSize.disclosure,
              color: colors.tertiaryLabel,
            ),
          ),
        ),
      if (row.chevron)
        const Padding(
          padding: EdgeInsetsDirectional.only(
            start: JamSpace.sm - kJamChevronBearing,
          ),
          child: JamDisclosureChevron(endAligned: true),
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
            end: jamHairlineEndInset(context, kJamRowInset),
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
    // One node: the merge sits outside the row's own flags, so the button
    // (or toggle) flag, its action and the title's text land together
    // rather than as a flagged parent over an unlabelled child.
    return MergeSemantics(
      child: Semantics(
        button: row.onTap != null && toggled == null,
        toggled: toggled,
        selected: row.checked ? true : null,
        enabled: enabled,
        label: row.semanticLabel,
        onTap: tap,
        excludeSemantics: row.semanticLabel != null,
        child: content,
      ),
    );
  }
}

/// "Add Songs": a plus in a cover-sized tile, then the title, both in tint —
/// the app's single most important collaborative action, drawn one way
/// wherever it appears (Start a Jam's songs, the queue).
///
/// [kJamAddSongsRowHeight] tall — a song row's height — so it sits on the
/// songs' grid: the plus where the covers are, "Add Songs" where the titles
/// start. On the Now Playing backdrop ([onBackdrop]) the tile is white 12%
/// and the plus and title white, like every other control there.
///
/// ```dart
/// JamAddSongsRow(onTap: _addSongs)
/// JamAddSongsRow(onTap: _add, busy: importing, onBackdrop: true, horizontalPadding: 28)
/// ```
class JamAddSongsRow extends StatelessWidget implements JamSelfSeparatingRow {
  const JamAddSongsRow({
    super.key,
    required this.onTap,
    this.title = JamListStrings.addSongs,
    this.busy = false,
    this.onBackdrop = false,
    this.horizontalPadding = kJamRowInset,
    this.separator,
  });

  /// Null disables the row (the tertiary ink, as a disabled button).
  final VoidCallback? onTap;

  /// Title Case; also what a screen reader hears.
  final String title;

  /// Something is being added: a spinner replaces the plus and taps are
  /// ignored.
  final bool busy;

  /// White on the Now Playing backdrop.
  final bool onBackdrop;

  /// The row's side insets (a section's 16, the player's margin).
  final double horizontalPadding;

  /// Forces the bottom hairline on or off; null follows [JamRowScope] like
  /// [JamRow].
  final bool? separator;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final enabled = onTap != null && !busy;
    final disabled = onTap == null;
    // Disabled is the one disabled look (R8): the tertiary ink, not the
    // whole row at 35%.
    final accent = disabled
        ? (onBackdrop ? JamNowPlayingColors.tertiary : colors.tertiaryLabel)
        : onBackdrop
        ? JamNowPlayingColors.text
        : colors.tint;
    final ground = onBackdrop
        ? JamNowPlayingColors.placeholderGround
        : colors.fillSecondary;
    final scope = JamRowScope.maybeOf(context);
    final showSeparator = separator ?? (scope != null && !scope.isLast);

    // A song row's height at the default text size — a minimum, so a large
    // title grows the row rather than clipping (RB-3).
    Widget content = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: kJamAddSongsRowHeight),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: horizontalPadding,
          vertical: (kJamAddSongsRowHeight - JamArtworkSize.row) / 2,
        ),
        child: Row(
          children: [
            Container(
              width: JamArtworkSize.row,
              height: JamArtworkSize.row,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: ground,
                borderRadius: BorderRadius.circular(
                  JamRadius.artwork(JamArtworkSize.row),
                ),
              ),
              child: busy
                  ? JamProgressRing(color: accent)
                  : Icon(
                      CupertinoIcons.plus,
                      size: JamIconSize.row,
                      color: accent,
                    ),
            ),
            const SizedBox(width: kJamRowLeadingGap),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.jamBody.copyWith(color: accent),
              ),
            ),
          ],
        ),
      ),
    );

    if (showSeparator) {
      content = Stack(
        children: [
          content,
          PositionedDirectional(
            start: horizontalPadding + JamArtworkSize.row + kJamRowLeadingGap,
            end: jamHairlineEndInset(context, horizontalPadding),
            bottom: 0,
            child: JamHairline(
              color: onBackdrop ? JamNowPlayingColors.separator : null,
            ),
          ),
        ],
      );
    }

    return Semantics(
      container: true,
      button: true,
      enabled: enabled,
      label: title,
      onTap: enabled ? onTap : null,
      excludeSemantics: true,
      child: JamPressable(
        onTap: enabled ? onTap : null,
        style: JamPressStyle.highlight,
        highlightColor: onBackdrop ? JamNowPlayingColors.pressed : null,
        child: content,
      ),
    );
  }
}

/// The ↗'s side bearing: how far inside its box its stroke ends.
const double _kArrowBearing = 2.5;

/// [JamAddSongsRow]'s height: a song row's (8 + cover 44 + 8).
const double kJamAddSongsRowHeight = 60;
