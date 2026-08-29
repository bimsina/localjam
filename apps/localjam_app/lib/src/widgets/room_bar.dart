/// The docked room bar — Spotify's mini-player, doing the job that makes the
/// session-controller refactor worth it.
///
/// Whenever a jam is live and you are somewhere else in the app, this shows
/// what is playing and takes you back. It can only exist because the engine
/// now outlives the route: before, navigating away from the room closed it.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:localjam_client/localjam_client.dart';

import '../design/tokens.dart';
import '../design/typography.dart';
import '../state/session_controller.dart';
import 'artwork.dart';

class RoomBar extends StatefulWidget {
  const RoomBar({super.key});

  @override
  State<RoomBar> createState() => _RoomBarState();
}

class _RoomBarState extends State<RoomBar> {
  final List<StreamSubscription<Object?>> _subs = [];
  JamEngine? _bound;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bind(JamSession.of(context).engine);
  }

  void _bind(JamEngine? engine) {
    if (identical(engine, _bound)) return;
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    _subs.clear();
    _bound = engine;
    if (engine == null) return;
    void refresh(Object? _) {
      if (mounted) setState(() {});
    }

    _subs
      ..add(engine.states.listen(refresh))
      ..add(engine.playlistUpdates.listen(refresh));
  }

  @override
  void dispose() {
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = JamSession.of(context);
    final engine = session.engine;
    if (engine == null || !session.isLive) return const SizedBox.shrink();

    final colors = context.jamColors;
    final item = engine.currentItem;
    final playing = engine.snapshot.status == PlaybackStatus.playing;
    final canControl = engine.can(JamCapability.controlPlayback);

    return Material(
      color: colors.surface,
      child: InkWell(
        onTap: () => context.go('/room'),
        child: Container(
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(color: colors.separator, width: 0.5),
            ),
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: JamSpace.md,
                vertical: JamSpace.sm,
              ),
              child: Row(
                children: [
                  JamArtwork(
                    engine: engine,
                    item: item,
                    size: JamArtworkSize.bar,
                  ),
                  const SizedBox(width: JamSpace.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          item?.displayTitle ?? engine.sessionName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.jamRowTitle,
                        ),
                        Text(
                          engine.sessionName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.jamFootnote,
                        ),
                      ],
                    ),
                  ),
                  if (canControl)
                    IconButton(
                      iconSize: 30,
                      icon: Icon(
                        playing
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                      ),
                      onPressed: () => playing
                          ? engine.transportPause()
                          : engine.transportPlay(),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
