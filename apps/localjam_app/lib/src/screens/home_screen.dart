/// Home: a live view of what is around you.
///
/// Not a landing page. The app is already installed, so nothing here explains
/// the product — no wordmark, no icon hero, no "no internet, no accounts".
/// The screen's whole job is to answer "is there a jam here?" before you tap
/// anything, which is why the mDNS browse runs here rather than one screen
/// deeper.
///
/// The two empty states are the important part. On a trip, "nothing nearby"
/// usually means either *no network at all* (turn on a hotspot) or *you are on
/// a hotspot, where mDNS does not travel* (scan the code). Those need opposite
/// actions, so the screen reads the network instead of showing one shrug.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:localjam_client/localjam_client.dart';

import '../design/breakpoints.dart';
import '../design/tokens.dart';
import '../design/typography.dart';
import '../state/session_controller.dart';
import '../util/capabilities.dart';
import '../util/network.dart';
import '../widgets/peer_avatar.dart';
import '../widgets/rename_dialog.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String _identity = '';
  JamNetworkStatus _network = JamNetworkStatus.offline;
  Timer? _networkPoll;

  @override
  void initState() {
    super.initState();
    unawaited(_loadIdentity());
    unawaited(_refreshNetwork());
    // Wi-Fi and hotspots come and go on the road; re-read rather than making
    // the user pull to refresh a fact the OS already knows.
    _networkPoll = Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(_refreshNetwork()),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(JamSession.read(context).startBrowsing());
    });
  }

  @override
  void dispose() {
    _networkPoll?.cancel();
    super.dispose();
  }

  Future<void> _loadIdentity() async {
    final name = await JamIdentity.displayName();
    if (mounted) setState(() => _identity = name);
  }

  Future<void> _refreshNetwork() async {
    final status = await currentNetwork();
    if (mounted && status.addresses.join() != _network.addresses.join()) {
      setState(() => _network = status);
    }
  }

  Future<void> _rename() async {
    final name = await promptForName(context, current: _identity);
    if (name == null) return;
    await JamIdentity.setDisplayName(name);
    if (mounted) setState(() => _identity = name);
  }

  Future<void> _join(JamNearbyRoom room) async {
    final session = JamSession.read(context);
    final joined = await session.join(room.joinUri);
    if (!mounted) return;
    if (joined) {
      context.push('/room');
    } else {
      _showError(session.error);
    }
  }

  void _showError(String? message) {
    if (message == null) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final session = JamSession.of(context);
    // On a wide window the sidebar already carries identity and the
    // destinations, so repeating them in an app bar is noise.
    final wide = context.jamBreakpoint.hasSidebar;

    return Scaffold(
      appBar: wide
          ? null
          : AppBar(
              titleSpacing: JamSpace.page,
              title: _IdentityButton(name: _identity, onTap: _rename),
              actions: [
                IconButton(
                  icon: const Icon(Icons.history_rounded),
                  tooltip: 'Past jams',
                  onPressed: () => context.push('/history'),
                ),
                IconButton(
                  icon: const Icon(Icons.settings_outlined),
                  tooltip: 'Settings',
                  onPressed: () => context.push('/settings'),
                ),
                const SizedBox(width: JamSpace.sm),
              ],
            ),
      body: SafeArea(
        top: false,
        // Rows stretched across a 1300px window are unreadable; hold the
        // content to a column and centre it in the detail pane.
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: JamContentWidth.reading,
            ),
            child: ValueListenableBuilder<List<JamNearbyRoom>>(
              valueListenable: session.nearbyRooms,
              builder: (context, rooms, _) => CustomScrollView(
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(
                      JamSpace.page,
                      JamSpace.sm,
                      JamSpace.page,
                      JamSpace.lg,
                    ),
                    sliver: SliverToBoxAdapter(
                      child: Row(
                        children: [
                          Expanded(
                            child: Text('Nearby', style: context.jamLargeTitle),
                          ),
                          // Wide layouts have no bottom bar, so the two ways in
                          // sit beside the title instead.
                          if (wide)
                            _HomeActions(
                              onScan: () => unawaited(_scan()),
                              onHost: () => context.push('/host'),
                              inline: true,
                            ),
                        ],
                      ),
                    ),
                  ),
                  if (rooms.isEmpty)
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: _EmptyNearby(
                        network: _network,
                        onScan: () => unawaited(_scan()),
                      ),
                    )
                  else
                    SliverList.separated(
                      itemCount: rooms.length,
                      separatorBuilder: (_, _) => Divider(
                        height: 0.5,
                        indent: JamSpace.page,
                        color: colors.separator,
                      ),
                      itemBuilder: (context, index) => _RoomRow(
                        room: rooms[index],
                        onTap: () => unawaited(_join(rooms[index])),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
      // While a jam is live the docked room bar takes this slot — and both
      // of these actions would be no-ops, since a session can only start
      // from idle.
      bottomNavigationBar: session.isLive || wide
          ? null
          : _HomeActions(
              onScan: () => unawaited(_scan()),
              onHost: () => context.push('/host'),
            ),
    );
  }

  Future<void> _scan() async {
    final uri = await context.push<String>('/scan');
    if (uri == null || !mounted) return;
    final session = JamSession.read(context);
    final joined = await session.join(Uri.parse(uri));
    if (!mounted) return;
    if (joined) {
      context.push('/room');
    } else {
      _showError(session.error);
    }
  }
}

/// Your face and name, tappable to rename. `JamIdentity.setDisplayName` has
/// existed since v1 with no caller — this is it.
class _IdentityButton extends StatelessWidget {
  const _IdentityButton({required this.name, required this.onTap});

  final String name;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    if (name.isEmpty) return const SizedBox.shrink();
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(JamRadius.pill),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: JamSpace.xs,
          vertical: JamSpace.xs,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            PeerAvatar(name: name, size: 28),
            const SizedBox(width: JamSpace.sm),
            // Flexible, not fixed: the app bar's title slot is narrow once
            // the two action icons take their share, and a long identity
            // should truncate rather than overflow.
            Flexible(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.jamRowTitle,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One discoverable room.
class _RoomRow extends StatelessWidget {
  const _RoomRow({required this.room, required this.onTap});

  final JamNearbyRoom room;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    return ListTile(
      onTap: onTap,
      leading: PeerAvatar(name: room.sessionName, size: 44),
      title: Text(room.sessionName, style: context.jamRowTitle),
      subtitle: Text('Tap to join', style: context.jamByline),
      trailing: Icon(Icons.chevron_right_rounded, color: colors.textTertiary),
    );
  }
}

/// The two "nothing nearby" situations, which need opposite actions.
class _EmptyNearby extends StatelessWidget {
  const _EmptyNearby({required this.network, required this.onScan});

  final JamNetworkStatus network;
  final VoidCallback onScan;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;

    final (icon, headline, detail, showScan) = switch (network) {
      JamNetworkStatus(connected: false) => (
        Icons.wifi_off_rounded,
        'No network',
        'Join a Wi-Fi network, or turn on your hotspot and let everyone '
            'connect to it.',
        false,
      ),
      JamNetworkStatus(isHotspotHost: true) => (
        Icons.qr_code_scanner_rounded,
        'Nothing nearby',
        'Rooms do not announce themselves across a hotspot. Scan the '
            'host’s code to get in.',
        true,
      ),
      _ => (
        Icons.podcasts_rounded,
        'Nothing nearby',
        'Nobody on this network is hosting yet.',
        false,
      ),
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        JamSpace.xxxl,
        JamSpace.huge,
        JamSpace.xxxl,
        JamSpace.huge,
      ),
      child: Column(
        children: [
          Icon(icon, size: 40, color: colors.textTertiary),
          const SizedBox(height: JamSpace.lg),
          Text(headline, style: context.jamTitle),
          const SizedBox(height: JamSpace.sm),
          Text(detail, textAlign: TextAlign.center, style: context.jamByline),
          if (showScan) ...[
            const SizedBox(height: JamSpace.xl),
            OutlinedButton.icon(
              onPressed: onScan,
              icon: const Icon(Icons.qr_code_scanner_rounded, size: 20),
              label: const Text('Scan code'),
            ),
          ],
        ],
      ),
    );
  }
}

/// The two ways into music, always reachable.
class _HomeActions extends StatelessWidget {
  const _HomeActions({
    required this.onScan,
    required this.onHost,
    this.inline = false,
  });

  final VoidCallback onScan;
  final VoidCallback onHost;

  /// True when the actions sit beside the page title (wide layouts) rather
  /// than in a bar pinned to the bottom of the window, where they would look
  /// stranded.
  final bool inline;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    if (inline) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (canScanQrCodes) ...[
            OutlinedButton.icon(
              onPressed: onScan,
              icon: const Icon(Icons.qr_code_scanner_rounded, size: 20),
              label: const Text('Scan code'),
            ),
            const SizedBox(width: JamSpace.md),
          ],
          FilledButton.icon(
            onPressed: onHost,
            icon: const Icon(Icons.graphic_eq_rounded, size: 20),
            label: const Text('Start a jam'),
          ),
        ],
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: colors.canvas,
        border: Border(top: BorderSide(color: colors.separator, width: 0.5)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            JamSpace.page,
            JamSpace.md,
            JamSpace.page,
            JamSpace.md,
          ),
          child: Row(
            children: [
              if (canScanQrCodes) ...[
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: onScan,
                    icon: const Icon(Icons.qr_code_scanner_rounded, size: 20),
                    label: const Text('Scan code'),
                  ),
                ),
                const SizedBox(width: JamSpace.md),
              ],
              Expanded(
                child: FilledButton.icon(
                  onPressed: onHost,
                  icon: const Icon(Icons.graphic_eq_rounded, size: 20),
                  label: const Text('Start a jam'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
