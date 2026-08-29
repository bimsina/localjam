/// Desktop navigation.
///
/// On a wide window the phone chrome stops working: destinations hidden
/// behind app-bar icons and a room bar pinned to the bottom of a 1400px
/// window both read as leftovers from a smaller screen. The sidebar holds
/// identity, the destinations, and the live jam, all permanently visible.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../design/breakpoints.dart';
import '../design/tokens.dart';
import '../design/typography.dart';
import '../state/session_controller.dart';
import 'peer_avatar.dart';
import 'room_bar.dart';

class AppSidebar extends StatelessWidget {
  const AppSidebar({super.key, required this.identity, this.onRename});

  final String identity;
  final VoidCallback? onRename;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final session = JamSession.of(context);
    final location = GoRouterState.of(context).matchedLocation;

    return Container(
      width: JamContentWidth.sidebar,
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(right: BorderSide(color: colors.separator, width: 0.5)),
      ),
      child: SafeArea(
        right: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                JamSpace.md,
                JamSpace.lg,
                JamSpace.md,
                JamSpace.xl,
              ),
              child: InkWell(
                onTap: onRename,
                borderRadius: BorderRadius.circular(JamRadius.md),
                child: Padding(
                  padding: const EdgeInsets.all(JamSpace.sm),
                  child: Row(
                    children: [
                      if (identity.isNotEmpty)
                        PeerAvatar(name: identity, size: 32),
                      const SizedBox(width: JamSpace.md),
                      Expanded(
                        child: Text(
                          identity.isEmpty ? '…' : identity,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.jamRowTitle,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            _NavItem(
              icon: Icons.podcasts_rounded,
              label: 'Nearby',
              path: '/',
              current: location,
            ),
            _NavItem(
              icon: Icons.history_rounded,
              label: 'Past jams',
              path: '/history',
              current: location,
            ),
            _NavItem(
              icon: Icons.settings_outlined,
              label: 'Settings',
              path: '/settings',
              current: location,
            ),
            const Spacer(),
            if (session.isLive)
              Padding(
                padding: const EdgeInsets.all(JamSpace.sm),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(JamRadius.md),
                  child: const RoomBar(),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.label,
    required this.path,
    required this.current,
  });

  final IconData icon;
  final String label;
  final String path;
  final String current;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final selected = current == path;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: JamSpace.md,
        vertical: JamSpace.xxs,
      ),
      child: Material(
        color: selected ? colors.accentSoft : Colors.transparent,
        borderRadius: BorderRadius.circular(JamRadius.md),
        child: InkWell(
          borderRadius: BorderRadius.circular(JamRadius.md),
          onTap: selected ? null : () => unawaited(_go(context)),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: JamSpace.md,
              vertical: JamSpace.md,
            ),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 20,
                  color: selected ? colors.accent : colors.textSecondary,
                ),
                const SizedBox(width: JamSpace.md),
                Text(
                  label,
                  style: context.jamBody.copyWith(
                    color: selected ? colors.accent : colors.textPrimary,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _go(BuildContext context) async => context.go(path);
}
