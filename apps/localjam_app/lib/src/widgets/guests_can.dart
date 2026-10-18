/// What guests can do: the three presets, said the same way everywhere
/// (DESIGN_SPEC v3 §6.2, §6.5).
///
/// Start a Jam and the People sheet both show a **Guests Can** row whose
/// value is the preset's name and whose pull-down lists the presets with a
/// checkmark on the current one. Both read their words from
/// [JamPresetStrings] and draw the row with [JamGuestsCanRow], so the same
/// policy is never called two different things.
library;

import 'package:flutter/cupertino.dart';
import 'package:localjam_client/localjam_client.dart';

import '../design/tokens.dart';
import '../design/typography.dart';
import 'list.dart';
import 'menu.dart';

/// The presets' names and descriptions — the one source for them.
abstract final class JamPresetStrings {
  static const String guestsCan = 'Guests Can';

  static const String everything = 'Everything';
  static const String addMusic = 'Add Music';
  static const String listenOnly = 'Listen Only';

  /// Once a switch (People sheet) diverges from every preset.
  static const String custom = 'Custom';

  static const String everythingDetail =
      'Add music, control playback and edit the queue';
  static const String addMusicDetail = 'Add music and edit the queue';
  static const String listenOnlyDetail = 'Only you control the music';

  /// The preset [policy] matches, or [custom].
  static String name(JamPolicy policy) => switch (policy) {
    JamPolicy.open => everything,
    JamPolicy.jam => addMusic,
    JamPolicy.listenOnly => listenOnly,
    _ => custom,
  };

  /// The preset's short description (the pull-down's subtitle), or null
  /// for a custom policy.
  static String? detail(JamPolicy policy) => switch (policy) {
    JamPolicy.open => everythingDetail,
    JamPolicy.jam => addMusicDetail,
    JamPolicy.listenOnly => listenOnlyDetail,
    _ => null,
  };

  /// What [policy] lets guests do, as one sentence — the footer under the
  /// Guests Can row, and the line a guest reads in the People sheet.
  static String summary(JamPolicy policy) {
    final allowed = [
      if (policy.addTracks) 'add music',
      if (policy.controlPlayback) 'play, pause and skip',
      if (policy.editQueue) 'edit the queue',
    ];
    if (allowed.isEmpty) {
      return 'The host runs this jam. Everyone else listens along.';
    }
    final last = allowed.removeLast();
    return allowed.isEmpty
        ? 'Everyone can $last.'
        : 'Everyone can ${allowed.join(', ')} and $last.';
  }
}

/// The presets, in menu order.
const List<JamPolicy> kJamPresets = [
  JamPolicy.open,
  JamPolicy.jam,
  JamPolicy.listenOnly,
];

/// The **Guests Can** row: the preset's name and the pop-up chevrons, and a
/// pull-down of [kJamPresets] (name, description, checkmark) on tap.
class JamGuestsCanRow extends StatelessWidget {
  const JamGuestsCanRow({
    super.key,
    required this.policy,
    required this.onChanged,
    this.separator,
  });

  final JamPolicy policy;

  /// Called with a preset other than the current one.
  final ValueChanged<JamPolicy> onChanged;

  /// Passed to the row (a `JamSection` draws no hairline under a non-row
  /// child, so a row followed by switches says `false` and lets the section
  /// add it).
  final bool? separator;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final name = JamPresetStrings.name(policy);
    return JamMenuButton(
      semanticLabel: JamPresetStrings.guestsCan,
      groups: [
        [
          for (final preset in kJamPresets)
            JamMenuItem(
              title: JamPresetStrings.name(preset),
              subtitle: JamPresetStrings.detail(preset),
              checked: preset == policy,
              onPressed: () {
                if (preset == policy) return;
                JamHaptics.selection();
                onChanged(preset);
              },
            ),
        ],
      ],
      builder: (context, open) => JamRow(
        title: JamPresetStrings.guestsCan,
        separator: separator,
        semanticLabel: '${JamPresetStrings.guestsCan}, $name',
        // The value, then iOS's pop-up chevrons.
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              name,
              maxLines: 1,
              style: context.jamBody.copyWith(color: colors.secondaryLabel),
            ),
            const SizedBox(width: JamSpace.xs),
            Icon(
              CupertinoIcons.chevron_up_chevron_down,
              size: JamMetrics.disclosureIcon,
              color: colors.tertiaryLabel,
            ),
          ],
        ),
        onTap: open,
      ),
    );
  }
}
