/// The joined room (docs/design/WEB_GUEST.md "Web page behaviour" 5): the
/// cover, title and artist, one line about sync (§3–§6 states in plain
/// language), the transport — only when the room's permission document
/// grants `control_playback` (§5.6) — this page's mute and sync nudge
/// (§7), the queue with the current song marked and songs this browser
/// cannot play marked as such, who's here (named per §3.1 `welcome.host`),
/// "Open in app" and the "keep this page open" hint.
library;

import 'dart:async';

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:localjam_client/localjam_client.dart';

import 'design.dart';
import 'room.dart';
import 'widgets.dart';

class RoomPage extends StatefulWidget {
  const RoomPage({super.key, required this.room, required this.onOpenApp});

  final ListenerRoom room;
  final VoidCallback? onOpenApp;

  static const String hostedBy = 'Hosted by';
  static const String nothingPlaying = 'Nothing playing yet';
  static const String play = 'Play';
  static const String pause = 'Pause';
  static const String previous = 'Previous';
  static const String next = 'Next';
  static const String mute = 'Mute';
  static const String unmute = 'Unmute';
  static const String resume = 'Tap to resume';
  static const String offsetHeader = 'Sound offset';
  static const String offsetFooter =
      "If this page sounds behind everyone else (Bluetooth headphones do "
      "that), move it earlier. It's remembered on this browser.";
  static const String offsetEarlier = 'Earlier';
  static const String offsetLater = 'Later';
  static const String offsetReset = 'Reset';
  static const String queueHeader = 'Queue';
  static const String queueEmpty = 'Nothing in the queue yet';
  static const String cantPlay = "Can't play in this browser";
  static const String tooLong = 'Too long to play in a browser';
  static const String tooBig = 'Too big to play in a browser';
  static const String retry = 'Try again';
  static const String nowPlaying = 'Now playing';
  static const String peopleHeader = "Who's here";
  static const String hostRole = 'Host';
  static const String youRole = 'You';
  static const String guestFallback = 'Guest';
  static const String openApp = 'Open in app';
  static const String keepOpen =
      'Keep this page open while you listen. Closing it, or leaving it in '
      'the background for long, can stop the music.';

  /// Nudge bounds and step (§7: ±500 ms in 10 ms steps).
  static const int maxNudgeUs = 500000;
  static const int nudgeStepUs = 10000;

  /// Every nudge the engine applies re-anchors playback, and on the web
  /// each re-anchor is a ≥ 50 ms gap: a drag goes to the engine at most
  /// this often (and once more where it ends)…
  static const Duration nudgeDragInterval = Duration(milliseconds: 300);

  /// …and a run of ± taps once, this long after the last tap.
  static const Duration nudgeTapSettle = Duration(milliseconds: 400);

  @override
  State<RoomPage> createState() => _RoomPageState();
}

class _RoomPageState extends State<RoomPage> {
  Timer? _tick;

  /// The nudge on screen while a change waits to reach the engine (see
  /// [RoomPage.nudgeDragInterval]); null when there is none.
  int? _pendingNudgeUs;

  /// Whether the waiting change is to be stored (taps, a drag's end) or is
  /// a live drag position.
  bool _pendingNudgePersists = false;
  Timer? _nudgeTimer;

  ListenerRoom get room => widget.room;

  @override
  void initState() {
    super.initState();
    room.addListener(_onRoom);
    // The progress line moves on its own between broadcasts.
    _tick = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted && room.snapshot.status == PlaybackStatus.playing) {
        setState(() {});
      }
    });
  }

  @override
  void didUpdateWidget(RoomPage old) {
    super.didUpdateWidget(old);
    if (!identical(old.room, room)) {
      old.room.removeListener(_onRoom);
      room.addListener(_onRoom);
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    // A change still waiting is the person's choice: it lands anyway.
    if (_pendingNudgeUs != null) _applyNudge(persist: true, rebuild: false);
    room.removeListener(_onRoom);
    super.dispose();
  }

  int get _nudgeShown => _pendingNudgeUs ?? room.nudgeUs;

  /// Shows [us] at once and sends it on after [delay]: a drag
  /// ([persist] false) keeps its first timer, so it is sent at most once
  /// per [delay]; taps restart theirs, so a run of them is sent once.
  void _queueNudge(int us, {required bool persist, required Duration delay}) {
    setState(() {
      _pendingNudgeUs = us.clamp(-RoomPage.maxNudgeUs, RoomPage.maxNudgeUs);
      _pendingNudgePersists = _pendingNudgePersists || persist;
    });
    if (persist) _nudgeTimer?.cancel();
    if (persist || _nudgeTimer == null) {
      _nudgeTimer = Timer(delay, () => _applyNudge(persist: false));
    }
  }

  /// Sends the waiting nudge now ([persist] forces it stored).
  void _applyNudge({required bool persist, bool rebuild = true}) {
    _nudgeTimer?.cancel();
    _nudgeTimer = null;
    final us = _pendingNudgeUs;
    if (us == null) return;
    final store = persist || _pendingNudgePersists;
    _pendingNudgePersists = false;
    final applied = room.setNudgeUs(us, persist: store);
    unawaited(
      applied.whenComplete(() {
        // Hand the screen back to the room, unless a newer change waits.
        if (!mounted || _pendingNudgeUs != us || _nudgeTimer != null) return;
        setState(() => _pendingNudgeUs = null);
      }),
    );
    if (rebuild && mounted) setState(() {});
  }

  void _setNudgeNow(int us) {
    _nudgeTimer?.cancel();
    _nudgeTimer = null;
    _pendingNudgeUs = us.clamp(-RoomPage.maxNudgeUs, RoomPage.maxNudgeUs);
    _applyNudge(persist: true);
  }

  void _onRoom() {
    if (mounted) setState(() {});
  }

  MediaItem? get _current {
    final id = room.snapshot.mediaId;
    if (id == null) return null;
    for (final item in room.queue) {
      if (item.mediaId == id) return item;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final c = colorsOf(context);
    final current = _current;
    final status = RoomStatus.of(room);
    return PageColumn(
      children: [
        _header(c),
        const SizedBox(height: 20),
        LayoutBuilder(
          builder: (context, constraints) {
            final size = constraints.maxWidth.clamp(0.0, 320.0);
            return Center(
              child: AsyncCover(
                itemKey: current?.mediaId,
                size: size,
                load: current == null ? null : () => room.artworkFor(current),
              ),
            );
          },
        ),
        const SizedBox(height: 20),
        _titleBlock(c, current),
        const SizedBox(height: 12),
        _statusLine(c, status),
        if (current != null) ...[const SizedBox(height: 12), _progress(c)],
        if (room.canControl) ...[const SizedBox(height: 8), _transport(c)],
        _offsetSection(c),
        _queueSection(c),
        _peopleSection(c),
        const SizedBox(height: 24),
        if (widget.onOpenApp != null)
          Center(
            child: IntrinsicWidth(
              child: PageButton(
                label: RoomPage.openApp,
                style: PageButtonStyle.plain,
                icon: CupertinoIcons.arrow_up_right_square,
                onPressed: widget.onOpenApp,
              ),
            ),
          ),
        const SizedBox(height: 8),
        Text(
          RoomPage.keepOpen,
          textAlign: TextAlign.center,
          style: PageType.footnote.copyWith(color: c.secondaryLabel),
        ),
      ],
    );
  }

  Widget _header(PageColors c) => Row(
    children: [
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              header: true,
              child: Text(
                room.jamName,
                style: PageType.title3.copyWith(color: c.label),
              ),
            ),
            Text(
              '${RoomPage.hostedBy} ${hostDisplayName(room.hostPeer)}',
              style: PageType.footnote.copyWith(color: c.secondaryLabel),
            ),
          ],
        ),
      ),
      PageIconButton(
        icon: room.muted
            ? CupertinoIcons.speaker_slash_fill
            : CupertinoIcons.speaker_2_fill,
        label: room.muted ? RoomPage.unmute : RoomPage.mute,
        size: 24,
        onPressed: () => unawaited(room.setMuted(!room.muted)),
      ),
    ],
  );

  Widget _titleBlock(PageColors c, MediaItem? current) {
    final title = current == null ? RoomPage.nothingPlaying : _titleOf(current);
    final artist = current?.artist?.trim();
    final addedBy = current == null ? null : room.addedByLabel(current);
    final subtitle = [
      if (artist != null && artist.isNotEmpty) artist,
      if (addedBy != null) 'Added by $addedBy',
    ].join(' · ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: PageType.title2.copyWith(color: c.label),
        ),
        if (subtitle.isNotEmpty)
          Text(
            subtitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: PageType.body.copyWith(color: c.secondaryLabel),
          ),
      ],
    );
  }

  Widget _statusLine(PageColors c, RoomStatus status) {
    final (IconData icon, Color color) = switch (status.kind) {
      RoomStatusKind.synced => (CupertinoIcons.waveform, c.secondaryLabel),
      RoomStatusKind.waitingForHost => (
        CupertinoIcons.pause_circle,
        c.secondaryLabel,
      ),
      RoomStatusKind.fetching => (
        CupertinoIcons.arrow_down_circle,
        c.secondaryLabel,
      ),
      RoomStatusKind.syncing => (CupertinoIcons.time, c.secondaryLabel),
      RoomStatusKind.cantPlay => (
        CupertinoIcons.exclamationmark_circle,
        c.danger,
      ),
      RoomStatusKind.fetchFailed => (
        CupertinoIcons.exclamationmark_triangle,
        c.warning,
      ),
      RoomStatusKind.audioHeld => (CupertinoIcons.speaker_slash, c.warning),
      RoomStatusKind.reconnecting => (CupertinoIcons.wifi_slash, c.warning),
      RoomStatusKind.hostAsleep => (CupertinoIcons.moon, c.warning),
    };
    final progress = status.progress;
    final text = progress == null
        ? status.text
        : '${status.text} ${(progress * 100).floor()}%';
    final current = room.snapshot.mediaId;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Announced when the state changes, not at every percent: the live
        // region's label is the state's text alone.
        Semantics(
          liveRegion: true,
          label: status.text,
          excludeSemantics: true,
          child: Row(
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  text,
                  style: PageType.subheadline.copyWith(color: color),
                ),
              ),
            ],
          ),
        ),
        if (status.kind == RoomStatusKind.audioHeld) ...[
          const SizedBox(height: 8),
          PageButton(
            label: RoomPage.resume,
            style: PageButtonStyle.tinted,
            icon: CupertinoIcons.play_fill,
            onPressed: () => unawaited(room.resumeAudio()),
          ),
        ],
        if (status.retryable && current != null) ...[
          const SizedBox(height: 8),
          PageButton(
            label: RoomPage.retry,
            style: PageButtonStyle.tinted,
            icon: CupertinoIcons.arrow_clockwise,
            onPressed: () => room.retryFetch(current),
          ),
        ],
      ],
    );
  }

  Widget _progress(PageColors c) {
    final position = room.positionUsNow() ?? 0;
    final duration = room.durationUs;
    final fraction = duration == null || duration <= 0
        ? 0.0
        : (position / duration).clamp(0.0, 1.0);
    final times = PageType.tabular(
      PageType.caption.copyWith(color: c.secondaryLabel),
    );
    return ExcludeSemantics(
      child: Column(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: SizedBox(
              height: 6,
              child: Stack(
                children: [
                  Positioned.fill(child: ColoredBox(color: c.fill)),
                  FractionallySizedBox(
                    widthFactor: fraction,
                    child: ColoredBox(color: c.secondaryLabel),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Text(_clock(position), style: times),
              const Spacer(),
              if (duration != null)
                Text('−${_clock(duration - position)}', style: times),
            ],
          ),
        ],
      ),
    );
  }

  Widget _transport(PageColors c) {
    final playing = room.snapshot.status == PlaybackStatus.playing;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        PageIconButton(
          icon: CupertinoIcons.backward_fill,
          label: RoomPage.previous,
          size: 30,
          color: c.label,
          onPressed: () => unawaited(room.previous()),
        ),
        PageIconButton(
          icon: playing ? CupertinoIcons.pause_fill : CupertinoIcons.play_fill,
          label: playing ? RoomPage.pause : RoomPage.play,
          size: 44,
          color: c.label,
          onPressed: () => unawaited(playing ? room.pause() : room.play()),
        ),
        PageIconButton(
          icon: CupertinoIcons.forward_fill,
          label: RoomPage.next,
          size: 30,
          color: c.label,
          onPressed: () => unawaited(room.next()),
        ),
      ],
    );
  }

  Widget _offsetSection(PageColors c) {
    final nudge = _nudgeShown;
    final ms = (nudge / 1000).round();
    final value = ms == 0
        ? '0 ms'
        : ms > 0
        ? '$ms ms ${RoomPage.offsetEarlier.toLowerCase()}'
        : '${-ms} ms ${RoomPage.offsetLater.toLowerCase()}';
    void tap(int us) =>
        _queueNudge(us, persist: true, delay: RoomPage.nudgeTapSettle);
    return PageSection(
      header: RoomPage.offsetHeader,
      footer: RoomPage.offsetFooter,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
          child: Row(
            children: [
              PageIconButton(
                icon: CupertinoIcons.minus,
                label: RoomPage.offsetLater,
                size: 20,
                onPressed: nudge <= -RoomPage.maxNudgeUs
                    ? null
                    : () => tap(nudge - RoomPage.nudgeStepUs),
              ),
              Expanded(
                child: Column(
                  children: [
                    Text(
                      value,
                      style: PageType.tabular(
                        PageType.headline.copyWith(color: c.label),
                      ),
                    ),
                    Semantics(
                      label: RoomPage.offsetHeader,
                      value: value,
                      child: Slider(
                        min: -RoomPage.maxNudgeUs.toDouble(),
                        max: RoomPage.maxNudgeUs.toDouble(),
                        divisions:
                            2 * RoomPage.maxNudgeUs ~/ RoomPage.nudgeStepUs,
                        value: nudge
                            .clamp(-RoomPage.maxNudgeUs, RoomPage.maxNudgeUs)
                            .toDouble(),
                        onChanged: (v) => _queueNudge(
                          v.round(),
                          persist: false,
                          delay: RoomPage.nudgeDragInterval,
                        ),
                        onChangeEnd: (v) => _setNudgeNow(v.round()),
                      ),
                    ),
                  ],
                ),
              ),
              PageIconButton(
                icon: CupertinoIcons.plus,
                label: RoomPage.offsetEarlier,
                size: 20,
                onPressed: nudge >= RoomPage.maxNudgeUs
                    ? null
                    : () => tap(nudge + RoomPage.nudgeStepUs),
              ),
            ],
          ),
        ),
        if (nudge != 0)
          PageRow(
            title: RoomPage.offsetReset,
            titleStyle: PageType.body.copyWith(color: c.tint),
            onTap: () => _setNudgeNow(0),
          ),
      ],
    );
  }

  Widget _queueSection(PageColors c) {
    final queue = room.queue;
    final currentId = room.snapshot.mediaId;
    if (queue.isEmpty) {
      return PageSection(
        header: RoomPage.queueHeader,
        children: [
          PageRow(
            title: RoomPage.queueEmpty,
            titleStyle: PageType.body.copyWith(color: c.secondaryLabel),
          ),
        ],
      );
    }
    return PageSection(
      header: RoomPage.queueHeader,
      trailing: queue.length == 1 ? '1 song' : '${queue.length} songs',
      children: [
        for (final item in queue)
          _queueRow(c, item, current: item.mediaId == currentId),
      ],
    );
  }

  Widget _queueRow(PageColors c, MediaItem item, {required bool current}) {
    final state = room.prefetch[item.mediaId];
    final unplayable = state?.phase == JamPrefetchPhase.unplayable;
    final artist = item.artist?.trim();
    final duration = item.durationUs;
    final String subtitle;
    if (unplayable) {
      subtitle = switch (state!.error) {
        JamMediaStore.tooLong => RoomPage.tooLong,
        JamMediaStore.tooLarge => RoomPage.tooBig,
        _ => RoomPage.cantPlay,
      };
    } else {
      subtitle = [
        if (artist != null && artist.isNotEmpty) artist,
        if (duration != null && duration > 0) _clock(duration),
      ].join(' · ');
    }
    final canSelect = room.canControl && !current && !unplayable;
    return PageRow(
      leading: AsyncCover(
        itemKey: item.mediaId,
        size: 40,
        radius: Metrics.artworkSmall,
        load: item.artworkId == null ? null : () => room.artworkFor(item),
      ),
      title: _titleOf(item),
      titleStyle: PageType.body.copyWith(
        color: unplayable
            ? c.tertiaryLabel
            : current
            ? c.tint
            : c.label,
        fontWeight: current ? FontWeight.w600 : FontWeight.w400,
      ),
      subtitle: subtitle.isEmpty ? null : subtitle,
      subtitleColor: unplayable ? c.danger : null,
      semanticsLabel: current ? RoomPage.nowPlaying : null,
      trailing: current
          ? Icon(CupertinoIcons.speaker_2_fill, size: 18, color: c.tint)
          : null,
      onTap: canSelect ? () => unawaited(room.select(item.mediaId)) : null,
    );
  }

  Widget _peopleSection(PageColors c) {
    final host = room.hostPeer;
    final hostName = hostDisplayName(host);
    final rows = <Widget>[
      PageRow(
        leading: Avatar(name: hostName),
        title: hostName,
        subtitle: RoomPage.hostRole,
      ),
      PageRow(
        leading: Avatar(name: room.myName),
        title: room.myName,
        subtitle: RoomPage.youRole,
      ),
      for (final peer in room.peers)
        PageRow(
          leading: Avatar(
            name: peer.clientName.trim().isEmpty
                ? RoomPage.guestFallback
                : peer.clientName.trim(),
          ),
          title: peer.clientName.trim().isEmpty
              ? RoomPage.guestFallback
              : peer.clientName.trim(),
        ),
    ];
    return PageSection(
      header: RoomPage.peopleHeader,
      trailing: '${rows.length}',
      children: rows,
    );
  }

  /// A song's title as the app shows it: its tag title, else its file name
  /// without the audio extension. A "title" that is just the file name (a
  /// host that filled the tag from it) gets the same treatment — "track1.m4a"
  /// reads as a bug — while a real title is never touched.
  static String _titleOf(MediaItem item) {
    final title = item.title?.trim();
    if (title != null && title.isNotEmpty && title != item.name) return title;
    return stripAudioExtension(item.name);
  }

  static String _clock(int us) {
    final total = (us < 0 ? 0 : us) ~/ 1000000;
    final minutes = total ~/ 60;
    final seconds = (total % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}

const Set<String> _audioExtensions = {
  'mp3',
  'm4a',
  'aac',
  'wav',
  'wave',
  'flac',
  'ogg',
  'oga',
  'opus',
  'aiff',
  'aif',
  'alac',
  'wma',
};

/// [name] without a trailing audio extension ("track1.m4a" is "track1");
/// anything else is returned whole.
@visibleForTesting
String stripAudioExtension(String name) {
  final dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) return name;
  final ext = name.substring(dot + 1).toLowerCase();
  return _audioExtensions.contains(ext) ? name.substring(0, dot) : name;
}
