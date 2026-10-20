/// Desktop navigation (DESIGN_SPEC v3 §6.11, D7).
///
/// On a wide window the phone chrome stops working: destinations behind
/// nav-bar icons read as leftovers from a smaller screen. The sidebar holds
/// identity and the destinations, permanently visible — a column like
/// Music's on the Mac: rows of icon and title, the selected one on a tinted
/// rounded highlight. Raspberry marks only that selected row (D8): every
/// other icon is `secondaryLabel`, so the tint keeps meaning "you are
/// here". The live jam's mini player is not in here: it floats
/// over the bottom of the content pane (the router shell), where the song's
/// name and both transport buttons have room — in a 260 pt column it cut
/// the title short and dropped Next.
library;

import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:go_router/go_router.dart';

import '../design/breakpoints.dart';
import '../design/tokens.dart';
import '../design/typography.dart';
import 'avatar.dart';
import 'list.dart';
import 'pressable.dart';

/// Everything the sidebar says out loud.
abstract final class AppSidebarStrings {
  static const String nearby = 'Nearby';
  static const String history = 'Past jams';
  static const String settings = 'Settings';
  static const String identityHint = 'Change your name';

  /// Shown in the identity row until the stored name has loaded.
  static const String loadingIdentity = '…';
}

/// A sidebar row's height (macOS / iPadOS sidebars sit at 32–36).
const double kJamSidebarRowHeight = 36;

const double _rowRadius = JamRadius.sm;
const double _rowIcon = JamIconSize.control;

class AppSidebar extends StatelessWidget {
  const AppSidebar({super.key, required this.identity, this.onRename});

  final String identity;
  final VoidCallback? onRename;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final location = GoRouterState.of(context).matchedLocation;
    final light = CupertinoTheme.brightnessOf(context) == Brightness.light;

    return SizedBox(
      width: JamContentWidth.sidebar,
      child: DecoratedBox(
        decoration: BoxDecoration(
          // A step off the content's own ground, as a Mac sidebar is: the
          // grouped grey in light, the raised grey in dark.
          color: light ? colors.groupedBackground : colors.groupedSurface,
          border: Border(
            right: BorderSide(
              color: colors.separator,
              width: JamHairline.thicknessOf(context),
            ),
          ),
        ),
        child: SafeArea(
          right: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: JamSpace.lg),
              _IdentityRow(identity: identity, onTap: onRename),
              const SizedBox(height: JamSpace.lg),
              _NavItem(
                icon: CupertinoIcons.antenna_radiowaves_left_right,
                label: AppSidebarStrings.nearby,
                path: '/',
                current: location,
              ),
              _NavItem(
                icon: CupertinoIcons.clock,
                label: AppSidebarStrings.history,
                path: '/history',
                current: location,
              ),
              _NavItem(
                icon: CupertinoIcons.gear,
                label: AppSidebarStrings.settings,
                path: '/settings',
                current: location,
              ),
              const Spacer(),
            ],
          ),
        ),
      ),
    );
  }
}

/// Your face and name at the top of the sidebar; tap to rename.
class _IdentityRow extends StatelessWidget {
  const _IdentityRow({required this.identity, this.onTap});

  final String identity;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: JamSpace.sm),
      child: Semantics(
        container: true,
        button: onTap != null,
        label: identity.isEmpty
            ? AppSidebarStrings.identityHint
            : '$identity. ${AppSidebarStrings.identityHint}',
        onTap: onTap,
        excludeSemantics: true,
        child: JamPressable(
          onTap: onTap,
          style: JamPressStyle.highlight,
          borderRadius: BorderRadius.circular(_rowRadius),
          child: SizedBox(
            height: JamMetrics.hitTarget,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: JamSpace.sm),
              child: Row(
                children: [
                  if (identity.isNotEmpty) ...[
                    JamAvatar(name: identity, size: JamAvatarSize.identity),
                    const SizedBox(width: JamSpace.md),
                  ],
                  Expanded(
                    child: Text(
                      identity.isEmpty
                          ? AppSidebarStrings.loadingIdentity
                          : identity,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.jamHeadline,
                    ),
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
    final onTap = selected ? null : () => unawaited(_go(context));
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: JamSpace.sm, vertical: 1),
      child: Semantics(
        container: true,
        button: true,
        selected: selected,
        label: label,
        onTap: onTap,
        excludeSemantics: true,
        child: JamPressable(
          onTap: onTap,
          style: JamPressStyle.highlight,
          borderRadius: BorderRadius.circular(_rowRadius),
          child: Container(
            height: kJamSidebarRowHeight,
            padding: const EdgeInsets.symmetric(horizontal: JamSpace.sm),
            decoration: BoxDecoration(
              color: selected ? colors.tintFill : null,
              borderRadius: BorderRadius.circular(_rowRadius),
            ),
            child: Row(
              children: [
                SizedBox(
                  width: JamMetrics.rowIconBox - 6,
                  child: Icon(
                    icon,
                    size: _rowIcon,
                    color: selected ? colors.tint : colors.secondaryLabel,
                  ),
                ),
                const SizedBox(width: JamSpace.sm),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.jamBody.copyWith(
                      color: selected ? colors.tint : colors.label,
                      fontWeight: selected ? FontWeight.w600 : null,
                    ),
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
