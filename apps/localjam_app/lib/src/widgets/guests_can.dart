/// What guests can do: the three presets, said the same way everywhere
/// (DESIGN_SPEC v3 §6.2, §6.5, §10.9).
///
/// Start a Jam and the People sheet both show a **Guests Can** row whose
/// value is the preset's name and whose pull-down lists the presets with a
/// checkmark on the current one. Both read their words from
/// [JamPresetStrings] and draw the row with [JamGuestsCanRow], so the same
/// policy is never called two different things.
///
/// One vocabulary: the three capabilities are **Add Songs**, **Control
/// Playback** and **Edit the Queue** — the People sheet's switches, the
/// per-guest menu, the footer sentence and the presets' descriptions all
/// use exactly those words. The presets are named so that no preset shares
/// a name with a capability.
library;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:localjam_client/localjam_client.dart';

import '../design/tokens.dart';
import 'list.dart';
import 'menu.dart';

/// The presets' names and descriptions — the one source for them.
abstract final class JamPresetStrings {
  static const String guestsCan = 'Guests can';

  /// Preset names. None of them is a capability's name.
  static const String everything = 'Everything';
  static const String songsOnly = 'Songs & queue';
  static const String listenOnly = 'Listen only';

  /// The `JamPolicy.jam` preset's name, under its older constant.
  static const String addMusic = songsOnly;

  /// Once a switch (People sheet) diverges from every preset.
  static const String custom = 'Custom';

  /// The capabilities — the switches' titles and the per-guest menu items.
  static const String addSongs = 'Add songs';
  static const String controlPlayback = 'Control playback';
  static const String editQueue = 'Edit the queue';

  /// The presets' pull-down subtitles, in the capabilities' own words.
  static const String everythingDetail =
      'Add songs, control playback and edit the queue';
  static const String songsOnlyDetail = 'Add songs and edit the queue';
  static const String listenOnlyDetail = 'Only the host changes the music';

  /// Kept for older call sites.
  static const String addMusicDetail = songsOnlyDetail;

  /// The preset [policy] matches, or [custom].
  static String name(JamPolicy policy) => switch (policy) {
    JamPolicy.open => everything,
    JamPolicy.jam => songsOnly,
    JamPolicy.listenOnly => listenOnly,
    _ => custom,
  };

  /// The preset's short description (the pull-down's subtitle), or null
  /// for a custom policy.
  static String? detail(JamPolicy policy) => switch (policy) {
    JamPolicy.open => everythingDetail,
    JamPolicy.jam => songsOnlyDetail,
    JamPolicy.listenOnly => listenOnlyDetail,
    _ => null,
  };

  /// What [policy] lets guests do, as one sentence — the footer under the
  /// Guests Can row, and the line a guest reads in the People sheet. Said
  /// in the third person so it reads true from either side.
  static String summary(JamPolicy policy) {
    final allowed = [
      if (policy.addTracks) 'add songs',
      if (policy.controlPlayback) 'control playback',
      if (policy.editQueue) 'edit the queue',
    ];
    if (allowed.isEmpty) {
      return 'Only the host adds songs and controls playback.';
    }
    final last = allowed.removeLast();
    return allowed.isEmpty
        ? 'Guests can $last.'
        : 'Guests can ${allowed.join(', ')} and $last.';
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
///
/// The pull-down hangs from the row's trailing value, iOS's pop-up button
/// placement — never centred on the full-width row. With [controls] (the
/// People sheet's three switches) the rows sit under the preset row and the
/// menu opens above or below the whole group, so it never covers the
/// switches it is about to change.
class JamGuestsCanRow extends StatefulWidget implements JamSelfSeparatingRow {
  const JamGuestsCanRow({
    super.key,
    required this.policy,
    required this.onChanged,
    this.separator,
    this.controls = const [],
  });

  final JamPolicy policy;

  /// Called with a preset other than the current one.
  final ValueChanged<JamPolicy> onChanged;

  /// Overrides the preset row's hairline. Null: drawn when anything follows
  /// it ([controls], or a later row in the section).
  final bool? separator;

  /// Rows that belong with the preset (switches), drawn under it inside the
  /// same section and kept clear of the pull-down.
  final List<Widget> controls;

  @override
  State<JamGuestsCanRow> createState() => _JamGuestsCanRowState();
}

class _JamGuestsCanRowState extends State<JamGuestsCanRow> {
  final MenuController _menu = MenuController();

  void _toggle() => _menu.isOpen ? _menu.close() : _menu.open();

  @override
  Widget build(BuildContext context) {
    final policy = widget.policy;
    final name = JamPresetStrings.name(policy);
    final controls = widget.controls;
    final scope = JamRowScope.maybeOf(context);
    final groupIsLast = scope?.isLast ?? true;

    final head = JamRowScope(
      isLast: controls.isEmpty && groupIsLast,
      child: JamRow(
        title: JamPresetStrings.guestsCan,
        separator: widget.separator,
        semanticLabel: '${JamPresetStrings.guestsCan}, $name',
        // A value row like any other: the value, then the app's one
        // disclosure chevron — not iOS's pop-up chevrons.
        value: name,
        chevron: true,
        onTap: _toggle,
      ),
    );

    final group = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        head,
        for (var i = 0; i < controls.length; i++)
          JamRowScope(
            isLast: i == controls.length - 1 && groupIsLast,
            child: controls[i],
          ),
      ],
    );

    // The anchor is an invisible sliver on the trailing edge, as tall as
    // the whole group: the menu lines its trailing edge up with the value's
    // chevrons, and opens past the group's top or bottom edge rather than
    // over any row in it.
    final anchor = JamMenuAnchor(
      controller: _menu,
      alignment: JamMenuAlignment.trailing,
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
                widget.onChanged(preset);
              },
            ),
        ],
      ],
      builder: (context, controller) =>
          const IgnorePointer(child: SizedBox.expand()),
    );

    return Stack(
      children: [
        group,
        PositionedDirectional(
          top: 0,
          bottom: 0,
          end: kJamRowInset,
          width: 1,
          child: anchor,
        ),
      ],
    );
  }
}
