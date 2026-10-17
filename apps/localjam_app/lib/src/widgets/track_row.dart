/// A track in a queue, a history record, or a host's setup list.
///
/// The row is where the jam's social contract shows up: every track carries
/// the face of whoever put it there, so a queue reads as a thing people made
/// together rather than as a playlist. **Including you**: dropping your own
/// face was what emptied a solo-hosted room of people entirely, and a queue
/// of faceless rows is a playlist again. Your own credit is the same 20 dp
/// face as everyone else's, wearing the apricot "you" ring.
///
/// Engine-free: hand it strings, bytes, fractions and callbacks.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../design/tokens.dart';
import '../design/typography.dart';
import 'artwork.dart';
import 'avatar.dart';

/// Strings this row can put in front of a person.
abstract final class JamTrackRowStrings {
  static const String nowPlaying = 'Now playing';
  static const String addedBy = 'Added by';
  static const String addedByYou = 'Added by you';
  static const String failed = 'Could not be loaded';
  static const String fetching = 'Getting the track';
  static const String reorder = 'Reorder';
}

/// The fixed row height. Everything inside centres against it.
const double kJamTrackRowHeight = 68;

const double _artworkSize = 48;
const double _attributionSize = JamAvatarSize.attribution;
const double _dragHandleWidth = 40;
const double _currentBarWidth = 3;
const double _currentBarHeight = 20;
const double _prefetchRing = 16;

/// One track, with its cover, its byline, who added it and where it has got
/// to.
class JamTrackRow extends StatefulWidget {
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
    this.showDragHandle = false,
    this.reserveDragHandle = false,
    this.dragging = false,
    this.dimmed = false,
    this.onTap,
    this.onLongPress,
    this.trailing,
    this.contentPadding = const EdgeInsets.symmetric(horizontal: JamSpace.page),
  });

  /// The track title, already stripped of its file extension.
  final String title;

  /// Artist, album, or whatever the caller wants under the title.
  final String? byline;

  /// Cover bytes, when they are in hand.
  final Uint8List? artworkBytes;

  /// A resolved provider, for callers that hold one instead of bytes.
  final ImageProvider? artworkImage;

  /// Identity of the cover, so a new one cross-fades and a rebuild does not.
  final Object? artworkId;

  /// Whether the cover is still loading.
  final bool artworkLoading;

  /// Drawn over the cover, inside its clip — the queue's equaliser badge, for
  /// instance. Positioning is the caller's; the tile is 48 dp square.
  final Widget? artworkOverlay;

  /// Who added this track. Drives the 20 dp attribution face.
  final String? addedByName;

  /// Whether the adder is this device: the face gains the apricot "you" ring
  /// and announces itself as yours. It is still drawn.
  final bool addedByYou;

  /// The name the face's colour and initials come from, when it differs from
  /// [addedByName].
  ///
  /// Your own rows are credited "You" but should wear *your* face, not a
  /// dark-red "Y" — so a caller that knows this device's display name hands
  /// it over here and leaves the label alone.
  final String? addedByAvatarName;

  /// The track that is playing: accent title and a bar on the left edge.
  final bool isCurrent;

  /// Track length, rendered in tabular figures so a list does not shuffle.
  final Duration? duration;

  /// A guest's fetch progress, 0–1. Shown instead of [duration].
  final double? prefetchProgress;

  /// The track could not be fetched or decoded.
  final bool hasError;

  /// Whether to draw the reorder grip. Independent of [dragging].
  final bool showDragHandle;

  /// Holds the grip's 44 dp of width open without drawing it.
  ///
  /// The queue pins the current track above a reorderable list; only the
  /// reorderable rows carry a handle, so without this the pinned row's
  /// duration sat 44 dp right of everyone else's. A reserved slot keeps the
  /// trailing column on one axis.
  final bool reserveDragHandle;

  /// The picked-up-and-moving state.
  final bool dragging;

  /// Renders faded, for a track no longer on this device.
  final bool dimmed;

  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// Replaces the status slot entirely — a remove button, say.
  final Widget? trailing;

  /// Horizontal insets. The current-track bar sits outside them, flush to
  /// the row's own left edge.
  final EdgeInsets contentPadding;

  @override
  State<JamTrackRow> createState() => _JamTrackRowState();
}

class _JamTrackRowState extends State<JamTrackRow> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed == value) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);

    final fill = widget.dragging
        ? colors.surfaceElevated
        : _pressed
        ? colors.surfaceMuted
        : Colors.transparent;

    Widget row = AnimatedContainer(
      duration: reduceMotion ? Duration.zero : JamDuration.fast,
      curve: JamCurve.fast,
      height: kJamTrackRowHeight,
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(JamRadius.md),
        boxShadow: widget.dragging ? JamShadow.raised(colors) : null,
      ),
      child: Stack(
        children: [
          if (widget.isCurrent)
            Positioned(
              left: 0,
              top: (kJamTrackRowHeight - _currentBarHeight) / 2,
              child: Container(
                width: _currentBarWidth,
                height: _currentBarHeight,
                decoration: BoxDecoration(
                  color: colors.accent,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          Padding(
            padding: widget.contentPadding,
            child: Row(children: _content(context, colors)),
          ),
        ],
      ),
    );

    if (widget.dimmed) row = Opacity(opacity: 0.5, child: row);
    if (widget.dragging && !reduceMotion) {
      row = Transform.scale(scale: 1.02, child: row);
    }

    return Semantics(
      button: widget.onTap != null,
      label: _semanticLabel(),
      child: ExcludeSemantics(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          onLongPress: widget.onLongPress,
          onTapDown: widget.onTap == null ? null : (_) => _setPressed(true),
          onTapUp: (_) => _setPressed(false),
          onTapCancel: () => _setPressed(false),
          child: row,
        ),
      ),
    );
  }

  List<Widget> _content(BuildContext context, JamColors colors) {
    final byline = widget.byline;
    final adder = widget.addedByName;
    final face = widget.addedByAvatarName ?? adder;
    final showAdder =
        adder != null && adder.isNotEmpty && face != null && face.isNotEmpty;
    final trailing = widget.trailing ?? _status(context, colors);

    return [
      JamArtworkTile(
        bytes: widget.artworkBytes,
        image: widget.artworkImage,
        imageKey: widget.artworkId,
        size: _artworkSize,
        isLoading: widget.artworkLoading,
        hasError: widget.hasError,
        overlay: widget.artworkOverlay,
      ),
      const SizedBox(width: JamSpace.md),
      Expanded(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: widget.isCurrent
                  ? context.jamRowTitle.copyWith(color: colors.accent)
                  : context.jamRowTitle,
            ),
            if (byline != null && byline.isNotEmpty) ...[
              const SizedBox(height: JamSpace.xxs),
              Text(
                byline,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.jamFootnote.copyWith(
                  color: colors.textSecondary,
                ),
              ),
            ],
          ],
        ),
      ),
      if (showAdder) ...[
        const SizedBox(width: JamSpace.sm),
        JamAvatar(
          name: face,
          size: _attributionSize,
          ring: widget.addedByYou ? JamAvatarRing.you : JamAvatarRing.none,
          semanticLabel: widget.addedByYou
              ? JamTrackRowStrings.addedByYou
              : '${JamTrackRowStrings.addedBy} $adder',
        ),
      ],
      if (trailing != null) ...[const SizedBox(width: JamSpace.md), trailing],
      if (widget.showDragHandle || widget.reserveDragHandle) ...[
        const SizedBox(width: JamSpace.xs),
        SizedBox(
          width: _dragHandleWidth,
          height: kJamTrackRowHeight,
          child: widget.showDragHandle
              ? Icon(
                  Icons.drag_handle_rounded,
                  size: 20,
                  color: colors.textTertiary,
                )
              : null,
        ),
      ],
    ];
  }

  /// The trailing slot: a length, a fetch in progress, or a failure.
  Widget? _status(BuildContext context, JamColors colors) {
    if (widget.hasError) {
      return Icon(Icons.error_outline_rounded, size: 20, color: colors.danger);
    }
    final progress = widget.prefetchProgress;
    if (progress != null) {
      return SizedBox(
        width: _prefetchRing,
        height: _prefetchRing,
        child: CircularProgressIndicator(
          value: progress.clamp(0.0, 1.0),
          strokeWidth: 2,
          backgroundColor: colors.surfaceMuted,
          valueColor: AlwaysStoppedAnimation<Color>(colors.accent),
        ),
      );
    }
    final duration = widget.duration;
    if (duration == null) return null;
    return Text(
      formatTrackDuration(duration),
      style: jamNumericStyle(colors.textTertiary),
    );
  }

  String _semanticLabel() {
    final parts = <String>[];
    if (widget.isCurrent) parts.add(JamTrackRowStrings.nowPlaying);
    parts.add(widget.title);
    final byline = widget.byline;
    if (byline != null && byline.isNotEmpty) parts.add(byline);
    final adder = widget.addedByName;
    if (adder != null && adder.isNotEmpty) {
      parts.add(
        widget.addedByYou
            ? JamTrackRowStrings.addedByYou
            : '${JamTrackRowStrings.addedBy} $adder',
      );
    }
    if (widget.hasError) parts.add(JamTrackRowStrings.failed);
    final progress = widget.prefetchProgress;
    if (progress != null) {
      final percent = (progress.clamp(0.0, 1.0) * 100).round();
      parts.add('${JamTrackRowStrings.fetching} — $percent%');
    }
    return parts.join(', ');
  }
}

/// `mm:ss` (or `h:mm:ss`) for a track length.
///
/// Deliberately local rather than reaching for `util/format.dart`: that file
/// imports the engine, and these widgets stay free of it.
String formatTrackDuration(Duration duration) {
  final seconds = duration.inSeconds.remainder(60).abs();
  final minutes = duration.inMinutes.remainder(60).abs();
  final hours = duration.inHours.abs();
  final mmss =
      '${minutes.toString().padLeft(2, '0')}:'
      '${seconds.toString().padLeft(2, '0')}';
  return hours > 0 ? '$hours:$mmss' : mmss;
}
