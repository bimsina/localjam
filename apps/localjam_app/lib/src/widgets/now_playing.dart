/// The now-playing pieces, written once against [JamEngine] so a host and a
/// guest render the same player — the difference is what the room lets you
/// touch, not which class you are.
///
/// Shaped after Spotify's and SiriusXM's now-playing screens: big artwork,
/// left-aligned title and artist, a thin scrubber with elapsed and remaining,
/// a centred transport, and everything else pushed to a utility row. The room
/// (who is here, the join code) and the queue live behind icons — a player
/// should look like a player.
///
/// Position comes from a [JamPositionTicker], so the scrubber moves at frame
/// rate while the rest of the room stays still.
library;

import 'package:flutter/material.dart';
import 'package:localjam_client/localjam_client.dart';

import '../design/tokens.dart';
import '../design/typography.dart';
import '../state/position_ticker.dart';
import '../util/format.dart';
import 'artwork.dart';

/// Title, artist, and — only when it was somebody else — who queued it.
/// Left-aligned to the artwork's edge, the way a player reads.
class NowPlayingTitle extends StatelessWidget {
  const NowPlayingTitle({
    super.key,
    required this.engine,
    required this.item,
    required this.peers,
  });

  final JamEngine engine;
  final MediaItem? item;
  final List<PeerInfo> peers;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final current = item;
    // "added by You" is noise on your own screen.
    final addedBy = current == null
        ? null
        : engine.addedByLabel(current, peers);
    final credit = addedBy == null || addedBy == 'You' ? null : addedBy;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          current?.displayTitle ?? 'Nothing queued',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: context.jamLargeTitle.copyWith(fontSize: 26),
        ),
        const SizedBox(height: JamSpace.xxs),
        Text(
          current == null
              ? 'Add something to get the room going'
              : artworkByline(current) ?? 'Unknown artist',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: context.jamBody.copyWith(color: colors.textSecondary),
        ),
        if (credit != null) ...[
          const SizedBox(height: JamSpace.xxs),
          Text(
            'added by $credit',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.jamCaption.copyWith(color: colors.textTertiary),
          ),
        ],
      ],
    );
  }
}

/// The timeline. A scrubber for anyone who may control playback, a plain
/// track for everyone else — seeking is a room-wide act, so it is gated
/// exactly like the transport.
class PlaybackTimeline extends StatefulWidget {
  const PlaybackTimeline({
    super.key,
    required this.engine,
    required this.position,
    required this.canControl,
  });

  final JamEngine engine;
  final JamPositionTicker position;
  final bool canControl;

  @override
  State<PlaybackTimeline> createState() => _PlaybackTimelineState();
}

class _PlaybackTimelineState extends State<PlaybackTimeline> {
  /// Set while a drag is in flight, so the thumb follows the finger rather
  /// than snapping back to the anchor between frames.
  int? _dragUs;

  int? get _durationUs =>
      widget.engine.loadedDurationUs.value ??
      widget.engine.currentItem?.durationUs;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    return ValueListenableBuilder<int?>(
      valueListenable: widget.position,
      builder: (context, positionUs, _) {
        final duration = _durationUs;
        final shown = _dragUs ?? positionUs ?? 0;
        final max = (duration ?? 0).toDouble();
        final value = max <= 0 ? 0.0 : shown.clamp(0, duration!).toDouble();
        final remaining = duration == null ? null : duration - value.round();

        return Column(
          children: [
            SizedBox(
              height: 20,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 4,
                  trackShape: const RoundedRectSliderTrackShape(),
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 6,
                    disabledThumbRadius: 0,
                  ),
                  overlayShape: const RoundSliderOverlayShape(
                    overlayRadius: 14,
                  ),
                  disabledActiveTrackColor: colors.accent,
                  disabledInactiveTrackColor: colors.surfaceMuted,
                ),
                child: Slider(
                  value: value,
                  max: max <= 0 ? 1 : max,
                  // Disabled rather than swapped for a progress bar: the
                  // track reads identically, so a guest without playback
                  // control sees the same timeline, just inert.
                  onChanged: widget.canControl && max > 0
                      ? (v) => setState(() => _dragUs = v.round())
                      : null,
                  onChangeEnd: (v) {
                    setState(() => _dragUs = null);
                    widget.engine.transportSeek(v.round());
                  },
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: JamSpace.sm),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    formatPositionUs(shown),
                    style: context.jamNumeric.copyWith(
                      fontSize: 13,
                      color: colors.textSecondary,
                    ),
                  ),
                  Text(
                    remaining == null
                        ? '--:--'
                        : '-${formatPositionUs(remaining)}',
                    style: context.jamNumeric.copyWith(
                      fontSize: 13,
                      color: colors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Previous / play-pause / next. Rendered disabled rather than hidden when
/// the room does not grant playback control, so a guest can see the controls
/// exist and grow into them when the host promotes them.
class TransportBar extends StatelessWidget {
  const TransportBar({
    super.key,
    required this.engine,
    required this.canControl,
    required this.hasQueue,
  });

  final JamEngine engine;
  final bool canControl;
  final bool hasQueue;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final playing = engine.snapshot.status == PlaybackStatus.playing;
    final enabled = canControl && hasQueue;

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          iconSize: 36,
          color: colors.textPrimary,
          disabledColor: colors.textTertiary,
          onPressed: enabled ? () => engine.transportPrevious() : null,
          icon: const Icon(Icons.skip_previous_rounded),
        ),
        const SizedBox(width: JamSpace.xxl),
        _PlayButton(
          playing: playing,
          enabled: enabled,
          onPressed: () =>
              playing ? engine.transportPause() : engine.transportPlay(),
        ),
        const SizedBox(width: JamSpace.xxl),
        IconButton(
          iconSize: 36,
          color: colors.textPrimary,
          disabledColor: colors.textTertiary,
          onPressed: enabled ? () => engine.transportNext() : null,
          icon: const Icon(Icons.skip_next_rounded),
        ),
      ],
    );
  }
}

class _PlayButton extends StatelessWidget {
  const _PlayButton({
    required this.playing,
    required this.enabled,
    required this.onPressed,
  });

  final bool playing;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    return Semantics(
      button: true,
      label: playing ? 'Pause' : 'Play',
      child: Material(
        color: enabled ? colors.accent : colors.surfaceMuted,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: enabled ? onPressed : null,
          child: SizedBox(
            width: 64,
            height: 64,
            child: Icon(
              playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
              size: 36,
              color: enabled ? colors.onAccent : colors.textTertiary,
            ),
          ),
        ),
      ),
    );
  }
}
