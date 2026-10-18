/// A song row: queue, history detail, Start a Jam's song list, the library
/// picker (DESIGN_SPEC v3 §6.2/§6.3/§6.7).
///
/// Apple Music's list row: cover 44, title (body), a subheadline line —
/// "Added by Mia · 3:42", or the artist — and an optional drag handle. The
/// jam's social contract is in the words ("Added by you"), not in a face.
/// [JamTrackRow.onBackdrop] renders it white for the queue that opens in
/// place on Now Playing.
///
/// Engine-free: hand it strings, bytes, fractions and callbacks.
library;

import 'dart:typed_data';

import 'package:flutter/cupertino.dart';

import '../design/tokens.dart';
import '../design/typography.dart';
import 'artwork.dart';
import 'list.dart';
import 'pressable.dart';

/// Strings this row can put in front of a person.
abstract final class JamTrackRowStrings {
  static const String nowPlaying = 'Now playing';
  static const String addedBy = 'Added by';
  static const String addedByYou = 'Added by you';
  static const String failed = 'Could not be loaded';
  static const String fetching = 'Getting the song';
  static const String reorder = 'Reorder';
  static const String separator = ' · ';
}

/// The row height: 8 + cover 44 + 8.
const double kJamTrackRowHeight = 60;

const double _artworkSize = JamArtworkSize.row;
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
    this.addedByAvatarName,
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

  /// Artist / album. Shown when there is no [addedByName].
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

  /// Kept for older call sites; faces are no longer drawn on rows.
  final String? addedByAvatarName;

  /// The song that is playing: semibold title (tint off the backdrop).
  final bool isCurrent;

  /// Length, appended to the subtitle in tabular figures.
  final Duration? duration;

  /// A guest's fetch progress, 0–1: a filling activity indicator trailing.
  final double? prefetchProgress;

  /// The song could not be fetched or decoded.
  final bool hasError;

  /// The reason, shown in `danger` (default "Could not be loaded").
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

  String? _subtitle() {
    final parts = <String>[];
    final adder = addedByName;
    if (addedByYou) {
      parts.add(JamTrackRowStrings.addedByYou);
    } else if (adder != null && adder.isNotEmpty) {
      parts.add('${JamTrackRowStrings.addedBy} $adder');
    } else if (byline != null && byline!.isNotEmpty) {
      parts.add(byline!);
    }
    final d = duration;
    if (d != null && prefetchProgress == null) {
      parts.add(formatTrackDuration(d));
    }
    return parts.isEmpty ? null : parts.join(JamTrackRowStrings.separator);
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
    final subtitle = hasError
        ? (errorText ?? JamTrackRowStrings.failed)
        : _subtitle();

    final titleStyle = context.jamBody.copyWith(
      color: isCurrent && !onBackdrop ? colors.tint : primary,
      fontWeight: isCurrent ? FontWeight.w600 : null,
    );

    final status = trailing ?? _status(tertiary);

    Widget row = SizedBox(
      height: kJamTrackRowHeight,
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
                  if (subtitle != null)
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: jamTabular(
                        context.jamSubheadline,
                      ).copyWith(color: hasError ? colors.danger : secondary),
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
        highlightColor: onBackdrop ? const Color(0x1AFFFFFF) : null,
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
      return CupertinoActivityIndicator.partiallyRevealed(
        progress: progress.clamp(0.0, 1.0),
        color: tertiary,
      );
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
