/// A song row: queue, history detail, Start a Jam's song list, the library
/// picker (DESIGN_SPEC v3 §6.2/§6.3/§6.7).
///
/// Two lines, always (R3, IR-5): the song's title, then "Artist · 4:10".
/// Who added it is a face at the trailing edge — only when it was someone
/// else, so a face always means a friend's song and your own queue is not
/// your own face seven times over. Rows in a list that credits anyone keep
/// that face's column even when it is empty, so titles end at one x and the
/// faces line up. A song with no artist says "Added by Mia" in words on its
/// second line, so a name never sits where an artist would. A long artist
/// or name is cut before the length ever is. [JamTrackRow.onBackdrop]
/// renders it white for the queue that opens in place on Now Playing.
///
/// Engine-free: hand it strings, bytes, fractions and callbacks.
library;

import 'dart:typed_data';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';

import '../design/tokens.dart';
import '../design/typography.dart';
import 'artwork.dart';
import 'avatar.dart';
import 'list.dart';
import 'pressable.dart';
import 'progress.dart';

/// Strings this row can put in front of a person.
abstract final class JamTrackRowStrings {
  static const String nowPlaying = 'Now playing';
  static const String addedBy = 'Added by';
  static const String addedByYou = 'Added by you';

  static const String failed = 'Couldn’t be loaded';
  static const String fetching = 'Getting the song';
  static const String reorder = 'Reorder';
  static const String separator = ' · ';
}

/// The row height: 8 + cover 44 + 8.
const double kJamTrackRowHeight = 60;

const double _artworkSize = JamArtworkSize.row;

/// The credit column: the adder's face at attribution size, 8 pt clear of
/// the text, in a slot of its own width.
const double _creditSlot = 28;
const double _creditGap = JamSpace.sm;
const double _dragHandleWidth = 44;

/// The text scale from which a long title may take a second line.
const double _kWrapFromScale = 1.5;

/// One song.
class JamTrackRow extends StatelessWidget implements JamSelfSeparatingRow {
  const JamTrackRow({
    super.key,
    required this.title,
    this.byline,
    this.artworkBytes,
    this.artworkImage,
    this.artworkId,
    this.artworkLoading = false,
    this.artworkOverlay,
    this.addedByName,
    this.addedByYou = false,
    this.addedByColor,
    this.reserveCredit,
    this.isCurrent = false,
    this.duration,
    this.prefetchProgress,
    this.hasError = false,
    this.errorText,
    this.showDragHandle = false,
    this.reserveDragHandle = false,
    this.dragging = false,
    this.dimmed = false,
    this.onTap,
    this.onLongPress,
    this.trailing,
    this.contentPadding = const EdgeInsets.symmetric(horizontal: JamSpace.lg),
    this.onBackdrop = false,
    this.separator,
  });

  /// The song title, already stripped of its file extension.
  final String title;

  /// Artist / album, kept visible above the contributor credit.
  final String? byline;

  /// Cover bytes, when in hand.
  final Uint8List? artworkBytes;

  /// A resolved provider, instead of bytes.
  final ImageProvider? artworkImage;

  /// Identity of the cover, so a new one cross-fades and a rebuild does not.
  final Object? artworkId;

  /// The cover is still loading.
  final bool artworkLoading;

  /// Drawn over the cover, inside its clip.
  final Widget? artworkOverlay;

  /// Who added this song: "Added by Mia".
  final String? addedByName;

  /// The adder is this device: "Added by you".
  final bool addedByYou;

  /// The adder's face colour in the jam (`jamRosterColors`). Given for
  /// someone else's song, the credit is their face at the trailing edge;
  /// null draws no face — an unnamed adder ("Guest" is not a face).
  final Color? addedByColor;

  /// Keeps the credit column's width when this row has no face, so the
  /// faces in a list share one column. Null: kept whenever the row knows
  /// who added it (a queue, a past jam), and not otherwise (the library,
  /// Start a Jam's songs).
  final bool? reserveCredit;

  /// The song that is playing: semibold title (tint off the backdrop).
  final bool isCurrent;

  /// Length, appended to the subtitle in tabular figures.
  final Duration? duration;

  /// A guest's fetch progress, 0–1: a filling activity indicator trailing.
  final double? prefetchProgress;

  /// The song could not be fetched or decoded.
  final bool hasError;

  /// The reason, shown in `danger` — [JamNowPlayingColors.destructive] on
  /// the backdrop (default "Couldn’t be loaded").
  final String? errorText;

  /// Draws the reorder handle.
  final bool showDragHandle;

  /// Keeps the handle's width without drawing it, so trailing columns align.
  final bool reserveDragHandle;

  /// Picked up and moving.
  final bool dragging;

  /// Faded: a song no longer on this device.
  final bool dimmed;

  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// Replaces the status slot — a remove button, a checkmark.
  final Widget? trailing;

  /// Horizontal insets (default 16).
  final EdgeInsets contentPadding;

  /// White text for the Now Playing backdrop.
  final bool onBackdrop;

  /// Forces the bottom hairline; null follows the enclosing section.
  final bool? separator;

  /// Someone else added it, and said who: the credit is about them.
  bool get _bySomeoneElse => !addedByYou && (addedByName?.isNotEmpty ?? false);

  /// Whether the row wears the adder's face (R3: someone else's song).
  bool get _faced => addedByColor != null && _bySomeoneElse;

  /// Whether the row keeps the credit column.
  bool get _creditColumn =>
      _faced || (reserveCredit ?? (addedByYou || addedByName != null));

  /// The second line's two halves: what may be cut short (the artist, or
  /// "Added by Mia" for a song without one) and what never is (the length,
  /// with its separator when it follows something).
  ({String? lead, String? tail}) _subtitleParts() {
    String? lead = byline != null && byline!.isNotEmpty ? byline : null;
    // No artist: the adder in words, so their name is never read as the
    // artist's (RB-24). Your own songs carry no credit at all (R3).
    if (lead == null && _bySomeoneElse) {
      lead = '${JamTrackRowStrings.addedBy} $addedByName';
    }
    final d = duration;
    final length = d != null && prefetchProgress == null
        ? formatTrackDuration(d)
        : null;
    final tail = length == null
        ? null
        : lead == null
        ? length
        : '${JamTrackRowStrings.separator}$length';
    return (lead: lead, tail: tail);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final primary = onBackdrop ? JamNowPlayingColors.text : colors.label;
    final secondary = onBackdrop
        ? JamNowPlayingColors.secondary
        : colors.secondaryLabel;
    final tertiary = onBackdrop
        ? JamNowPlayingColors.tertiary
        : colors.tertiaryLabel;
    final parts = _subtitleParts();
    final hasSubtitle = hasError || parts.lead != null || parts.tail != null;

    final titleStyle = context.jamBody.copyWith(
      color: isCurrent && !onBackdrop ? colors.tint : primary,
      fontWeight: isCurrent ? FontWeight.w600 : null,
    );
    final subtitleStyle = context.jamSubheadline;

    final status = trailing ?? _status(tertiary);

    final scaler = MediaQuery.textScalerOf(context);
    final textHeight =
        _lineOf(titleStyle, scaler) +
        (hasSubtitle ? _lineOf(subtitleStyle, scaler) : 0);
    // The face grows with the words beside it, to a point, so it stays a
    // face rather than a dot next to large text (RB-17).
    final faceSize = JamAvatarSize.scaled(context, JamAvatarSize.attribution);
    final adder = addedByName;

    // At large text sizes a long title may take a second line, and the
    // rows grow to hold what they say rather than clip it.
    final large = scaler.scale(1) >= _kWrapFromScale;

    Widget row = ConstrainedBox(
      constraints: BoxConstraints(
        minHeight: math.max(kJamTrackRowHeight, textHeight + 16),
      ),
      child: Padding(
        padding: contentPadding,
        child: Row(
          children: [
            JamArtworkTile(
              bytes: artworkBytes,
              image: artworkImage,
              imageKey: artworkId,
              size: _artworkSize,
              isLoading: artworkLoading,
              hasError: hasError && artworkBytes == null,
              overlay: artworkOverlay,
              onBackdrop: onBackdrop,
            ),
            const SizedBox(width: kJamRowLeadingGap),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: JamSpace.sm),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: large ? 2 : 1,
                      overflow: TextOverflow.ellipsis,
                      style: titleStyle,
                    ),
                    if (hasError)
                      Text(
                        errorText ?? JamTrackRowStrings.failed,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: subtitleStyle.copyWith(
                          // On the backdrop, the pale red tuned for the art
                          // (system red on a dark cover is ~3:1).
                          color: onBackdrop
                              ? JamNowPlayingColors.destructive
                              : colors.danger,
                        ),
                      )
                    else if (hasSubtitle)
                      _QuietLine(
                        lead: parts.lead,
                        tail: parts.tail,
                        style: jamTabular(
                          subtitleStyle,
                        ).copyWith(color: secondary),
                      ),
                  ],
                ),
              ),
            ),
            if (_creditColumn)
              Padding(
                padding: const EdgeInsetsDirectional.only(start: _creditGap),
                child: SizedBox(
                  width: math.max(_creditSlot, faceSize + JamSpace.sm),
                  // The face ends on the row's trailing edge, where its
                  // hairline and the page's other columns end (CR-13).
                  child: _faced && adder != null
                      ? Align(
                          alignment: AlignmentDirectional.centerEnd,
                          heightFactor: 1,
                          child: JamAvatar(
                            name: adder,
                            color: addedByColor,
                            size: faceSize,
                          ),
                        )
                      : null,
                ),
              ),
            if (status != null) ...[const SizedBox(width: JamSpace.sm), status],
            if (showDragHandle || reserveDragHandle)
              SizedBox(
                width: _dragHandleWidth,
                height: kJamTrackRowHeight,
                child: showDragHandle
                    ? Icon(
                        CupertinoIcons.line_horizontal_3,
                        size: 20,
                        color: tertiary,
                      )
                    : null,
              ),
          ],
        ),
      ),
    );

    final scope = JamRowScope.maybeOf(context);
    final showSeparator = separator ?? (scope != null && !scope.isLast);
    if (showSeparator && !dragging) {
      row = Stack(
        children: [
          row,
          Positioned(
            left: contentPadding.left + _artworkSize + kJamRowLeadingGap,
            right: jamHairlineEndInset(context, contentPadding.right),
            bottom: 0,
            child: JamHairline(
              color: onBackdrop ? JamNowPlayingColors.track : null,
            ),
          ),
        ],
      );
    }

    if (dragging) {
      row = AnimatedScale(
        scale: reduceMotion ? 1 : 1.02,
        duration: reduceMotion ? Duration.zero : JamDuration.fast,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: onBackdrop
                ? JamNowPlayingColors.placeholderGround
                : colors.elevated,
            borderRadius: BorderRadius.circular(JamRadius.md),
          ),
          child: row,
        ),
      );
    }
    if (dimmed) row = Opacity(opacity: 0.5, child: row);

    if (onTap != null || onLongPress != null) {
      row = JamPressable(
        onTap: onTap,
        onLongPress: onLongPress,
        style: JamPressStyle.highlight,
        highlightColor: onBackdrop ? JamNowPlayingColors.pressed : null,
        child: row,
      );
    }

    return Semantics(
      button: onTap != null,
      label: _semanticLabel(),
      child: ExcludeSemantics(child: row),
    );
  }

  /// The status slot: a fetch in progress, a failure glyph, or nothing.
  Widget? _status(Color tertiary) {
    final progress = prefetchProgress;
    if (progress != null) {
      return JamProgressRing(value: progress.clamp(0.0, 1.0), color: tertiary);
    }
    return null;
  }

  String _semanticLabel() {
    final parts = <String>[];
    if (isCurrent) parts.add(JamTrackRowStrings.nowPlaying);
    parts.add(title);
    final byline = this.byline;
    if (byline != null && byline.isNotEmpty) parts.add(byline);
    final adder = addedByName;
    if (addedByYou) {
      parts.add(JamTrackRowStrings.addedByYou);
    } else if (adder != null && adder.isNotEmpty) {
      parts.add('${JamTrackRowStrings.addedBy} $adder');
    }
    if (hasError) parts.add(errorText ?? JamTrackRowStrings.failed);
    final progress = prefetchProgress;
    if (progress != null) {
      final percent = (progress.clamp(0.0, 1.0) * 100).round();
      parts.add('${JamTrackRowStrings.fetching} — $percent%');
    }
    return parts.join(', ');
  }
}

/// A row's quiet line: [lead] (an artist, or who added it) cut short
/// before [tail] (the length) ever is.
///
/// One text while the whole line fits; split only when it would not, so the
/// length survives a long name ("Electric Mongoose · 4:10").
class _QuietLine extends StatelessWidget {
  const _QuietLine({
    required this.lead,
    required this.tail,
    required this.style,
  });

  final String? lead;
  final String? tail;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final lead = this.lead;
    final tail = this.tail;
    Widget text(String value) =>
        Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: style);

    if (lead == null || tail == null) return text(lead ?? tail!);
    return LayoutBuilder(
      builder: (context, constraints) {
        final whole = '$lead$tail';
        final painter = TextPainter(
          text: TextSpan(text: whole, style: style),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
          maxLines: 1,
        )..layout();
        final fits = painter.width <= constraints.maxWidth;
        painter.dispose();
        if (fits) return text(whole);
        // So large that the length would leave the artist a few letters at
        // most: the line wraps once instead, so it is not cut to nothing.
        final tailPainter = TextPainter(
          text: TextSpan(text: tail, style: style),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
          maxLines: 1,
        )..layout();
        final tailWidth = tailPainter.width;
        tailPainter.dispose();
        final room = constraints.maxWidth - tailWidth;
        final letters = MediaQuery.textScalerOf(
          context,
        ).scale((style.fontSize ?? 15) * 3);
        if (room < letters) {
          return Text(
            whole,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: style,
          );
        }
        return Row(
          children: [
            Flexible(child: text(lead)),
            Text(tail, maxLines: 1, style: style),
          ],
        );
      },
    );
  }
}

/// One line of [style] at [scaler], as laid out.
double _lineOf(TextStyle style, TextScaler scaler) {
  final painter = TextPainter(
    text: TextSpan(text: 'Hg', style: style),
    textDirection: TextDirection.ltr,
    textScaler: scaler,
    maxLines: 1,
  )..layout();
  final height = painter.height;
  painter.dispose();
  return height;
}

/// `m:ss` (or `h:mm:ss`) for a song length, Apple-style (no leading zero on
/// minutes). A clip shorter than a second is "0:01", not "0:00": it has a
/// length, and "0:00" reads as broken (RB-24).
///
/// Local rather than `util/format.dart`, which imports the engine.
String formatTrackDuration(Duration duration) {
  if (duration > Duration.zero && duration < const Duration(seconds: 1)) {
    duration = const Duration(seconds: 1);
  }
  final seconds = duration.inSeconds.remainder(60).abs();
  final minutes = duration.inMinutes.remainder(60).abs();
  final hours = duration.inHours.abs();
  final ss = seconds.toString().padLeft(2, '0');
  if (hours > 0) {
    return '$hours:${minutes.toString().padLeft(2, '0')}:$ss';
  }
  return '$minutes:$ss';
}
