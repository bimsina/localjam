/// Everything about the room's people, on one page: the code that lets them
/// in, who is here, and what they may do.
///
/// Kept off the player deliberately. The now-playing screen should read as a
/// music player; presence lives in the chrome and opens into this.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:localjam_client/localjam_client.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../design/tokens.dart';
import '../design/typography.dart';
import '../util/network.dart';
import 'peer_avatar.dart';

/// Opens the room page.
Future<void> showRoomSheet(
  BuildContext context,
  JamEngine engine, {
  required String selfName,
  required JamNetworkStatus network,
  Uri? joinUri,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => RoomSheet(
      engine: engine,
      selfName: selfName,
      network: network,
      joinUri: joinUri,
    ),
  );
}

class RoomSheet extends StatefulWidget {
  const RoomSheet({
    super.key,
    required this.engine,
    required this.selfName,
    required this.network,
    this.joinUri,
  });

  final JamEngine engine;

  /// This device's display name — the engine knows peers, not itself.
  final String selfName;

  final JamNetworkStatus network;

  /// Host only: the room's join URI.
  final Uri? joinUri;

  @override
  State<RoomSheet> createState() => _RoomSheetState();
}

class _RoomSheetState extends State<RoomSheet> {
  final List<StreamSubscription<Object?>> _subs = [];

  JamEngine get _engine => widget.engine;
  JamHostEngine? get _host =>
      _engine is JamHostEngine ? _engine as JamHostEngine : null;

  @override
  void initState() {
    super.initState();
    void refresh(Object? _) {
      if (mounted) setState(() {});
    }

    _subs
      ..add(_engine.permissionUpdates.listen(refresh))
      ..add(_engine.states.listen(refresh));
    final guest = _engine;
    if (guest is JamGuestEngine) {
      _subs.add(guest.peerEvents.listen(refresh));
    } else {
      _subs.add(_host!.events.listen(refresh));
    }
  }

  @override
  void dispose() {
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    super.dispose();
  }

  void _guarded(void Function() action) {
    try {
      action();
      if (mounted) setState(() {});
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final host = _host;
    final peers = _engine.peers;
    final permissions = _engine.permissions;
    final isHost = host != null;
    final joinUri = widget.joinUri;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      maxChildSize: 0.95,
      builder: (context, scrollController) => ListView(
        controller: scrollController,
        padding: const EdgeInsets.only(bottom: JamSpace.huge),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              JamSpace.page,
              JamSpace.sm,
              JamSpace.page,
              JamSpace.md,
            ),
            child: Text(
              '${peers.length + 1} in the room',
              style: context.jamTitle,
            ),
          ),

          // This device first, so you can see your own standing.
          _PersonRow(
            name: widget.selfName,
            isHost: isHost,
            detail: isHost ? 'You · host' : 'You',
          ),
          for (final peer in peers)
            _PeerRow(
              engine: _engine,
              peer: peer,
              isCohost: permissions.roleOf(peer.peerId) == JamRole.cohost,
              onAction: isHost
                  ? (action) => _guarded(() => _apply(host, peer, action))
                  : null,
            ),

          if (joinUri != null) ...[
            const SizedBox(height: JamSpace.section),
            _Invite(joinUri: joinUri, network: widget.network),
          ],

          if (isHost) ...[
            const SizedBox(height: JamSpace.section),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                JamSpace.page,
                0,
                JamSpace.page,
                JamSpace.sm,
              ),
              child: Text('Everyone can', style: context.jamTitle),
            ),
            Divider(height: 0.5, color: colors.separator),
            _PolicySwitch(
              label: 'Add music',
              value: permissions.policy.addTracks,
              onChanged: (v) => _guarded(
                () => host.setPolicy(permissions.policy.copyWith(addTracks: v)),
              ),
            ),
            _PolicySwitch(
              label: 'Play, pause, and skip',
              value: permissions.policy.controlPlayback,
              onChanged: (v) => _guarded(
                () => host.setPolicy(
                  permissions.policy.copyWith(controlPlayback: v),
                ),
              ),
            ),
            _PolicySwitch(
              label: 'Reorder the queue',
              value: permissions.policy.editQueue,
              onChanged: (v) => _guarded(
                () => host.setPolicy(permissions.policy.copyWith(editQueue: v)),
              ),
            ),
          ],
        ],
      ),
    );
  }

  void _apply(JamHostEngine host, PeerInfo peer, _PeerAction action) {
    switch (action) {
      case _PeerAction.promote:
        host.promotePeer(peer.peerId);
      case _PeerAction.demote:
        host.demotePeer(peer.peerId);
      case _PeerAction.blockAdds:
        host.setCapabilityOverride(
          peer.peerId,
          JamCapability.addTracks,
          allowed: false,
        );
      case _PeerAction.allowAdds:
        host.setCapabilityOverride(
          peer.peerId,
          JamCapability.addTracks,
          allowed: null,
        );
      case _PeerAction.kick:
        host.kickPeer(peer.peerId);
    }
  }
}

enum _PeerAction { promote, demote, blockAdds, allowAdds, kick }

/// The code that gets people in.
///
/// This matters more than mDNS discovery on a trip: a personal hotspot does
/// not carry Bonjour, so the nearby list stays empty and the QR is the way in.
class _Invite extends StatelessWidget {
  const _Invite({required this.joinUri, required this.network});

  final Uri joinUri;
  final JamNetworkStatus network;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final link = joinUri.toString();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            JamSpace.page,
            0,
            JamSpace.page,
            JamSpace.sm,
          ),
          child: Text('Let people in', style: context.jamTitle),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: JamSpace.page),
          child: Text(
            network.isHotspotHost
                ? 'Everyone joins your hotspot first, then scans this.'
                : 'Anyone on this network can scan this to join.',
            style: context.jamByline,
          ),
        ),
        const SizedBox(height: JamSpace.lg),
        Center(
          child: Container(
            padding: const EdgeInsets.all(JamSpace.lg),
            decoration: BoxDecoration(
              // QR needs a light ground to scan. In light mode that is simply
              // the sheet; in dark mode it stays an explicit white plate.
              color: Colors.white,
              borderRadius: BorderRadius.circular(JamRadius.lg),
            ),
            child: QrImageView(
              data: link,
              size: 200,
              backgroundColor: Colors.white,
              // The scanning phone is often across a vehicle; a denser code
              // at lower error correction reads better at distance.
              errorCorrectionLevel: QrErrorCorrectLevel.M,
            ),
          ),
        ),
        const SizedBox(height: JamSpace.lg),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: JamSpace.page),
          child: Container(
            padding: const EdgeInsets.only(left: JamSpace.lg),
            decoration: BoxDecoration(
              color: colors.surfaceMuted,
              borderRadius: BorderRadius.circular(JamRadius.md),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    link,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.jamFootnote,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.copy_rounded, size: 18),
                  tooltip: 'Copy link',
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: link));
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Link copied')),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _PersonRow extends StatelessWidget {
  const _PersonRow({
    required this.name,
    required this.detail,
    this.isHost = false,
    this.trailing,
  });

  final String name;
  final String detail;
  final bool isHost;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: PeerAvatar(name: name, size: 44, isHost: isHost),
      title: Text(name, style: context.jamRowTitle),
      subtitle: Text(detail),
      trailing: trailing,
    );
  }
}

class _PeerRow extends StatelessWidget {
  const _PeerRow({
    required this.engine,
    required this.peer,
    required this.isCohost,
    required this.onAction,
  });

  final JamEngine engine;
  final PeerInfo peer;
  final bool isCohost;
  final void Function(_PeerAction action)? onAction;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final host = engine is JamHostEngine ? engine as JamHostEngine : null;
    final addsBlocked =
        engine.permissions.overrides[peer.peerId]?[JamCapability.addTracks] ==
        false;

    final detail = [
      if (isCohost) 'Co-host',
      if (addsBlocked) 'Cannot add',
      if (host != null) ?_readiness(host),
    ].join(' · ');

    return _PersonRow(
      name: peer.clientName.isEmpty ? peer.peerId : peer.clientName,
      detail: detail.isEmpty ? 'Listening' : detail,
      trailing: onAction == null
          ? null
          : PopupMenuButton<_PeerAction>(
              icon: Icon(Icons.more_horiz_rounded, color: colors.textTertiary),
              onSelected: onAction,
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: isCohost ? _PeerAction.demote : _PeerAction.promote,
                  child: Text(isCohost ? 'Demote to guest' : 'Make co-host'),
                ),
                PopupMenuItem(
                  value: addsBlocked
                      ? _PeerAction.allowAdds
                      : _PeerAction.blockAdds,
                  child: Text(
                    addsBlocked ? 'Allow adding music' : 'Block adding music',
                  ),
                ),
                const PopupMenuItem(
                  value: _PeerAction.kick,
                  child: Text('Remove from the room'),
                ),
              ],
            ),
    );
  }

  /// Whether this peer has the current track yet (§6.3).
  String? _readiness(JamHostEngine host) {
    final mediaId = engine.snapshot.mediaId;
    if (mediaId == null) return null;
    return switch (host.peerMediaStates(mediaId)[peer.peerId]) {
      MediaReadiness.ready || null => null,
      MediaReadiness.fetching => 'Getting the track',
      MediaReadiness.none => 'Missing the track',
    };
  }
}

class _PolicySwitch extends StatelessWidget {
  const _PolicySwitch({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      value: value,
      onChanged: onChanged,
      title: Text(label, style: context.jamBody),
    );
  }
}
