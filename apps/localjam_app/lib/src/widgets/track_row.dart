/// A song row: queue, history detail, Start a Jam's song list, the library
/// picker (DESIGN_SPEC v3 §6.2/§6.3/§6.7).
///
/// Cover, song title and artist lead. Contributor and duration sit on a
/// quieter third line when both artist and contributor are available — in
/// the queue as the adder's face and name ("● Mia · 4:10", D6), elsewhere in
/// words ("Added by Mia · 4:10"). A long name is cut before the length ever
/// is. [JamTrackRow.onBackdrop] renders it white for the queue that opens in
/// place on Now Playing.
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

  /// The adder, when it is this device and their face says the rest.
  static const String you = 'You';
  static const String failed = 'Couldn’t be loaded';
  static const String fetching = 'Getting the song';
  static const String reorder = 'Reorder';
  static const String separator = ' · ';
}

/// The row height: 8 + cover 44 + 8.
const double kJamTrackRowHeight = 60;

const double _artworkSize = JamArtworkSize.row;

/// The adder's face on a three-line row's 12 pt credit line: a step under
/// Now Playing's 16, so it never competes with the cover beside it.
const double _creditFaceSmall = 14;
const double _dragHandleWidth = 44;

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
    this.addedByFaceName,
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

  /// The adder's face colour in the jam (`jamRosterColors`). Given, the
  /// credit is their face and name ("● Mia · 4:10") instead of the words;
  /// null keeps the words — an unnamed adder, a past jam.
  final Color? addedByColor;

  /// Whose initial the face shows when it is not [addedByName]'s — this
  /// device's own name for "You".
  final String? addedByFaceName;

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

  /// Whether the credit is a face and a name rather than words.
  bool get _faced =>
      addedByColor != null &&
      (addedByYou || (addedByName?.isNotEmpty ?? false));

  /// The quiet line's two halves: what may be cut short (a name, an artist)
  /// and what never is (the length, with its separator when it follows
  /// something).
  ({String? lead, String? tail}) _subtitleParts() {
    final faced = _faced;
    String? lead;
    final adder = addedByName;
    if (addedByYou) {
      lead = faced ? JamTrackRowStrings.you : JamTrackRowStrings.addedByYou;
    } else if (adder != null && adder.isNotEmpty) {
      lead = faced ? adder : '${JamTrackRowStrings.addedBy} $adder';
    }
    if (lead == null && byline != null && byline!.isNotEmpty) lead = byline;
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
    final hasArtistAndCredit =
        !hasError &&
        byline != null &&
        byline!.isNotEmpty &&
        (addedByYou || (addedByName?.isNotEmpty ?? false));
    final parts = _subtitleParts();
    final hasSubtitle = hasError || parts.lead != null || parts.tail != null;

    final titleStyle = context.jamBody.copyWith(
      color: isCurrent && !onBackdrop ? colors.tint : primary,
      fontWeight: isCurrent ? FontWeight.w600 : null,
    );

    final status = trailing ?? _status(tertiary);

    final scaler = MediaQuery.textScalerOf(context);
    final textHeight =
        scaler.scale(17) * (22 / 17) +
        (hasArtistAndCredit ? scaler.scale(15) * (20 / 15) : 0) +
        (!hasSubtitle
            ? 0
            : hasArtistAndCredit
            ? scaler.scale(12) * (16 / 12)
            : scaler.scale(15) * (20 / 15));
    Widget row = SizedBox(
      height: math.max(
        hasArtistAndCredit ? 80 : kJamTrackRowHeight,
        textHeight + 16,
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
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: titleStyle,
                  ),
                  if (hasArtistAndCredit)
                    Text(
                      byline!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.jamSubheadline.copyWith(color: secondary),
                    ),
                  if (hasError)
                    Text(
                      errorText ?? JamTrackRowStrings.failed,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          (hasArtistAndCredit
                                  ? context.jamCaption1
                                  : context.jamSubheadline)
                              .copyWith(
                                // On the backdrop, the pale red tuned for
                                // the art (system red on a dark cover is
                                // ~3:1).
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
                        hasArtistAndCredit
                            ? context.jamCaption1
                            : context.jamSubheadline,
                      ).copyWith(color: secondary),
                      face: _faced
                          ? JamAvatar(
                              name: addedByFaceName?.trim().isNotEmpty == true
                                  ? addedByFaceName!
                                  : (addedByYou
                                        ? JamTrackRowStrings.you
                                        : addedByName!),
                              color: addedByColor,
                              size: hasArtistAndCredit
                                  ? _creditFaceSmall
                                  : JamAvatarSize.credit,
                            )
                          : null,
                    ),
                ],
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
            right: 0,
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

/// A row's quiet line: [lead] (a name, an artist) cut short before [tail]
/// (the length) ever is, behind the adder's [face] when there is one.
///
/// One text while the whole line fits; split only when it would not, so the
/// length survives a long name ("Electric Mongoose · 4:10").
class _QuietLine extends StatelessWidget {
  const _QuietLine({
    required this.lead,
    required this.tail,
    required this.style,
    this.face,
  });

  final String? lead;
  final String? tail;
  final TextStyle style;
  final Widget? face;

  @override
  Widget build(BuildContext context) {
    final lead = this.lead;
    final tail = this.tail;
    final face = this.face;
    Widget text(String value) =>
        Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: style);

    final Widget words = lead == null || tail == null
        ? text(lead ?? tail!)
        : LayoutBuilder(
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
              return Row(
                children: [
                  Flexible(child: text(lead)),
                  Text(tail, maxLines: 1, style: style),
                ],
              );
            },
          );
    if (face == null) return words;
    return Row(
      children: [
        face,
        const SizedBox(width: JamSpace.xs),
        Expanded(child: words),
      ],
    );
  }
}

/// `m:ss` (or `h:mm:ss`) for a song length, Apple-style (no leading zero on
/// minutes).
///
/// Local rather than `util/format.dart`, which imports the engine.
String formatTrackDuration(Duration duration) {
  final seconds = duration.inSeconds.remainder(60).abs();
  final minutes = duration.inMinutes.remainder(60).abs();
  final hours = duration.inHours.abs();
  final ss = seconds.toString().padLeft(2, '0');
  if (hours > 0) {
    return '$hours:${minutes.toString().padLeft(2, '0')}:$ss';
  }
  return '$minutes:$ss';
}
