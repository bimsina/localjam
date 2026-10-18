/// The iOS pull-down menu, used for every "•••" (DESIGN_SPEC v3 §5 Menus).
///
/// Built on Flutter's `CupertinoMenuAnchor`: blurred material, radius 14,
/// 44 rows with the title left and the icon right, destructive rows red, a
/// thick separator between groups.
///
/// ```dart
/// JamMenuButton(
///   semanticLabel: 'More',
///   groups: [
///     [
///       JamMenuItem(title: 'Invite People', icon: CupertinoIcons.person_badge_plus, onPressed: _invite),
///       JamMenuItem(title: 'Diagnostics', icon: CupertinoIcons.waveform_path_ecg, onPressed: _diag),
///     ],
///     [JamMenuItem(title: 'End Jam', icon: CupertinoIcons.xmark_circle, destructive: true, onPressed: _end)],
///   ],
/// )
/// ```
library;

import 'package:flutter/cupertino.dart';

import '../design/tokens.dart';
import 'buttons.dart';
import 'glass.dart';

/// Strings the menu button says.
abstract final class JamMenuStrings {
  static const String more = 'More';
}

/// One menu action.
@immutable
class JamMenuItem {
  const JamMenuItem({
    required this.title,
    this.icon,
    this.onPressed,
    this.destructive = false,
    this.checked = false,
    this.subtitle,
  });

  /// Title Case ("Sound Offset…").
  final String title;

  /// Drawn on the right, iOS-style.
  final IconData? icon;

  /// Null disables the item.
  final VoidCallback? onPressed;

  /// Red title and icon.
  final bool destructive;

  /// A leading checkmark (a choice among options).
  final bool checked;

  /// A secondary line under the title.
  final String? subtitle;
}

/// Builds the menu's children from [groups]: items, with a group separator
/// between groups. Public for callers that host their own anchor.
List<Widget> jamMenuChildren(List<List<JamMenuItem>> groups) {
  final hasChecks = groups.any((g) => g.any((i) => i.checked));
  return [
    for (var g = 0; g < groups.length; g++) ...[
      if (g > 0) const CupertinoMenuDivider(),
      for (final item in groups[g])
        CupertinoMenuItem(
          onPressed: item.onPressed,
          isDestructiveAction: item.destructive,
          leading: hasChecks
              ? (item.checked
                    ? const Icon(CupertinoIcons.checkmark, size: 17)
                    : const SizedBox.shrink())
              : null,
          trailing: item.icon == null ? null : Icon(item.icon),
          subtitle: item.subtitle == null ? null : Text(item.subtitle!),
          child: Text(item.title),
        ),
    ],
  ];
}

/// How the menu's trigger looks.
enum JamMenuTrigger {
  /// A bare tint "•••" (`ellipsis_circle`) for nav bars and rows.
  plain,

  /// A round chrome-glass button with "•••" — over ordinary content.
  glass,

  /// A round glass button over artwork / the Now Playing backdrop.
  glassOnArtwork,
}

/// A "•••" button that opens a pull-down menu, or any [child] trigger.
class JamMenuButton extends StatelessWidget {
  const JamMenuButton({
    super.key,
    required this.groups,
    this.semanticLabel = JamMenuStrings.more,
    this.trigger = JamMenuTrigger.plain,
    this.icon,
    this.visualSize = JamMetrics.glassButton,
    this.iconColor,
    this.builder,
    this.enabled = true,
  });

  /// Item groups, separated by the thick group divider.
  final List<List<JamMenuItem>> groups;

  final String semanticLabel;
  final JamMenuTrigger trigger;

  /// Overrides the trigger glyph (default: `ellipsis` for glass,
  /// `ellipsis_circle` for plain).
  final IconData? icon;

  /// The glass trigger's circle (30 for the Now Playing title row).
  final double visualSize;

  final Color? iconColor;

  /// A custom trigger: build anything and call `open()` from it.
  final Widget Function(BuildContext context, VoidCallback open)? builder;

  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return CupertinoMenuAnchor(
      useRootOverlay: true,
      consumeOutsideTaps: true,
      menuChildren: jamMenuChildren(groups),
      builder: (context, MenuController controller, _) {
        void toggle() =>
            controller.isOpen ? controller.close() : controller.open();
        final open = enabled ? toggle : null;
        final custom = builder;
        if (custom != null) return custom(context, open ?? () {});
        return switch (trigger) {
          JamMenuTrigger.plain => JamIconButton(
            icon: icon ?? CupertinoIcons.ellipsis_circle,
            semanticLabel: semanticLabel,
            color: iconColor,
            onPressed: open,
          ),
          JamMenuTrigger.glass ||
          JamMenuTrigger.glassOnArtwork => JamGlassButton(
            icon: icon ?? CupertinoIcons.ellipsis,
            semanticLabel: semanticLabel,
            onArtwork: trigger == JamMenuTrigger.glassOnArtwork,
            visualSize: visualSize,
            iconSize: visualSize <= 30 ? 15 : 18,
            iconColor: iconColor,
            onPressed: open,
          ),
        };
      },
    );
  }
}
