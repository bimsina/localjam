/// Desktop navigation.
///
/// On a wide window the phone chrome stops working: destinations hidden
/// behind app-bar icons and a room bar pinned to the bottom of a 1400px
/// window both read as leftovers from a smaller screen. The sidebar holds
/// the brand, identity, the destinations, and the live jam, all permanently
/// visible.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';

import '../design/breakpoints.dart';
import '../design/tokens.dart';
import '../design/typography.dart';
import '../state/session_controller.dart';
import 'avatar.dart';
import 'room_bar.dart';

/// Everything the sidebar says out loud.
abstract final class AppSidebarStrings {
  static const String wordmark = 'LocalJam';
  static const String nearby = 'Nearby';
  static const String history = 'Past jams';
  static const String settings = 'Settings';
  static const String identityHint = 'Change how you appear in rooms';

  /// Shown in the identity row until the stored name has loaded.
  static const String loadingIdentity = '…';
}

const String _logoAsset = 'assets/brand/logo.svg';

/// The brand lockup's mark size, and the 3×20 bar on the selected nav item.
const double _markSize = 24;
const double _selectedBarWidth = 3;
const double _selectedBarHeight = 20;

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
            // The brand, 20 above the identity row (§5 "Wide layouts"): a
            // window this size has room to say whose app this is.
            const Padding(
              padding: EdgeInsets.fromLTRB(
                JamSpace.xl,
                JamSpace.xl,
                JamSpace.md,
                JamSpace.xl,
              ),
              child: _Wordmark(),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                JamSpace.md,
                0,
                JamSpace.md,
                JamSpace.xl,
              ),
              child: Semantics(
                button: onRename != null,
                label: identity.isEmpty
                    ? AppSidebarStrings.identityHint
                    : '$identity. ${AppSidebarStrings.identityHint}',
                excludeSemantics: true,
                child: InkWell(
                  onTap: onRename,
                  borderRadius: BorderRadius.circular(JamRadius.md),
                  child: Padding(
                    padding: const EdgeInsets.all(JamSpace.sm),
                    child: Row(
                      children: [
                        if (identity.isNotEmpty)
                          JamAvatar(
                            name: identity,
                            size: JamAvatarSize.identity,
                          ),
                        const SizedBox(width: JamSpace.md),
                        Expanded(
                          child: Text(
                            identity.isEmpty
                                ? AppSidebarStrings.loadingIdentity
                                : identity,
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
            ),
            _NavItem(
              icon: Icons.podcasts_rounded,
              label: AppSidebarStrings.nearby,
              path: '/',
              current: location,
            ),
            _NavItem(
              icon: Icons.history_rounded,
              label: AppSidebarStrings.history,
              path: '/history',
              current: location,
            ),
            _NavItem(
              icon: Icons.settings_rounded,
              label: AppSidebarStrings.settings,
              path: '/settings',
              current: location,
            ),
            const Spacer(),
            if (session.hasRoom)
              Padding(
                padding: const EdgeInsets.all(JamSpace.sm),
                // The bar clips itself: an outer ClipRRect alone leaves the
                // 2 dp progress line pinned to its top edge running across
                // the rounded corner. At 260 dp the bar also collapses to
                // cover + transport, which is all this width honestly holds.
                child: RoomBar(
                  borderRadius: BorderRadius.circular(JamRadius.md),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The white mark on the raspberry gradient plus the wordmark beside it.
class _Wordmark extends StatelessWidget {
  const _Wordmark();

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    return Semantics(
      label: AppSidebarStrings.wordmark,
      header: true,
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: _markSize + JamSpace.sm,
            height: _markSize + JamSpace.sm,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(JamRadius.sm),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [JamColors.brandRaspberry, colors.accentDeep],
              ),
            ),
            child: SvgPicture.asset(
              _logoAsset,
              width: _markSize * 0.72,
              height: _markSize * 0.72,
              fit: BoxFit.contain,
              colorFilter: const ColorFilter.mode(
                Colors.white,
                BlendMode.srcIn,
              ),
            ),
          ),
          const SizedBox(width: JamSpace.md),
          Text(AppSidebarStrings.wordmark, style: context.jamTitle),
        ],
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
          child: Stack(
            children: [
              // The 3×20 accent bar the spec asks for, flush to the item's
              // own left edge rather than inside its padding.
              if (selected)
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: Container(
                      width: _selectedBarWidth,
                      height: _selectedBarHeight,
                      decoration: BoxDecoration(
                        color: colors.accent,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
              Padding(
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
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _go(BuildContext context) async => context.go(path);
}
