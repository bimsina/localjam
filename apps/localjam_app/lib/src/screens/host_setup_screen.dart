/// Starting a room, in one tap.
///
/// The name is already filled in and music is optional — a host can start
/// empty and add tracks once live (`JamHostEngine.addMediaFile` has always
/// worked mid-session; only the old UI hid the button after setup). What this
/// screen adds over the old one is the network: on a trip there is usually no
/// Wi-Fi, so somebody has to run a hotspot, and the screen says which network
/// guests must be on before anyone taps Start.
///
/// Design spec §5 "Host setup": the name is an *editable heading*, not a form
/// field; the policy is three cards rather than a `SegmentedButton`; the
/// chosen tracks are real [JamTrackRow]s rather than file paths; and the one
/// primary action lives in a blurred bar at the bottom.
library;

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:localjam_client/localjam_client.dart';

import '../design/theme.dart';
import '../design/breakpoints.dart';
import '../design/tokens.dart';
import '../design/typography.dart';
import '../state/session_controller.dart';
import '../util/format.dart';
import '../util/media_picking.dart';
import '../util/network.dart';
import '../widgets/buttons.dart';
import '../widgets/section.dart';
import '../widgets/session_gate.dart';
import '../widgets/track_row.dart';

/// Everything this screen says out loud.
abstract final class HostSetupStrings {
  static const String title = 'Start a jam';
  static const String nameHint = 'Room name';
  static const String nameField = 'Room name';
  static const String editName = 'Edit the room name';
  static const String back = 'Back';

  static const String noNetworkTitle = 'No network';
  static const String noNetworkDetail =
      'Turn on your hotspot and have everyone connect to it, then start the '
      'room.';
  static const String hotspotTitle = 'Sharing your hotspot';
  static const String hotspotDetail =
      'Rooms do not announce themselves across a hotspot — show guests the '
      'code once you start.';

  static const String guests = 'Guests';
  static const String presetEverything = 'Everything';
  static const String presetAddMusic = 'Add music';
  static const String presetListen = 'Listen';
  static const String presetEverythingDetail =
      'Everyone can add music, run playback and reshape the queue.';
  static const String presetAddMusicDetail =
      'Everyone can add music and reshape the queue. Playback stays yours.';
  static const String presetListenDetail =
      'Everyone listens along. You run the room.';

  static const String discoverable = 'Discoverable';
  static const String discoverableDetail =
      'Anyone on this network can join without the code.';

  static const String music = 'Music';
  static const String musicOptional = 'Optional';

  /// "3 tracks" — a bare "3" beside the heading was a number with no noun.
  static String trackCount(int n) => '$n ${n == 1 ? 'track' : 'tracks'}';
  static const String addFiles = 'Add files';
  static const String library = 'Library';
  static const String musicEmpty =
      'You can add music once the room is up — and so can everyone else.';
  static const String looking = 'Looking for music on this device…';
  static const String remove = 'Remove';

  static const String start = 'Start the jam';
  static const String starting = 'Starting the jam';
  static const String needsName = 'Give the room a name.';
  static const String couldNotStart = 'Could not start the room.';

  /// The one-liner under the preset cards.
  static String detailFor(JamPolicy policy) => switch (policy) {
    JamPolicy.open => presetEverythingDetail,
    JamPolicy.listenOnly => presetListenDetail,
    _ => presetAddMusicDetail,
  };
}

/// Two lines of `jamFootnote`, so the page does not reflow when a preset with
/// a shorter sentence is chosen.
///
/// Measured rather than fixed at 36: that literal was two lines at the
/// default text size and one and a half at XXL, where the second line was
/// sliced through the middle.
double jamPresetDetailHeight(BuildContext context) {
  final style = context.jamFootnote;
  return (MediaQuery.textScalerOf(context).scale(style.fontSize ?? 13) *
              (style.height ?? 1.35) *
              2)
          .ceilToDouble() +
      JamSpace.xxs;
}

class HostSetupScreen extends StatefulWidget {
  const HostSetupScreen({super.key, this.initialPaths, this.initialName});

  /// Tracks to preload — the "host it again" seam from jam history.
  ///
  /// A non-null value is an *exact* set: the Documents sweep below is skipped
  /// for it, or reopening a two-track past jam would quietly hand the host
  /// whatever else happens to be sitting in the app's Documents folder.
  final List<String>? initialPaths;

  /// Room name to preload, also from history.
  final String? initialName;

  @override
  State<HostSetupScreen> createState() => _HostSetupScreenState();
}

class _HostSetupScreenState extends State<HostSetupScreen> {
  final TextEditingController _name = TextEditingController();
  final List<String> _paths = [];
  // "Add music" is the jam: everyone contributes, the host keeps the
  // transport. Open by default handed a stranger on the same Wi-Fi the pause
  // button.
  JamPolicy _policy = JamPolicy.jam;
  bool _discoverable = true;
  bool _starting = false;
  bool _scanning = false;
  JamNetworkStatus _network = JamNetworkStatus.offline;
  Timer? _networkPoll;

  @override
  void initState() {
    super.initState();
    _paths.addAll(widget.initialPaths ?? const []);
    unawaited(_prefillName());
    if (widget.initialPaths == null) {
      _scanning = true;
      unawaited(_scanDocuments());
    }
    unawaited(_refreshNetwork());
    _networkPoll = Timer.periodic(
      const Duration(seconds: 3),
      (_) => unawaited(_refreshNetwork()),
    );
  }

  @override
  void dispose() {
    _networkPoll?.cancel();
    _name.dispose();
    super.dispose();
  }

  Future<void> _prefillName() async {
    final preset = widget.initialName;
    if (preset != null && preset.isNotEmpty) {
      _name.text = preset;
      return;
    }
    final identity = await JamIdentity.displayName();
    // A typographic apostrophe: the room name is the biggest piece of type
    // on the screen and a straight quote reads as a code artefact at 26 dp.
    if (mounted && _name.text.isEmpty) _name.text = '$identity\u2019s Jam';
  }

  /// How long the Documents sweep gets before the section stops shimmering.
  ///
  /// The sweep walks a directory that can live on iCloud Drive, and a
  /// placeholder that never resolves is worse than an empty list — you can
  /// always add files by hand.
  static const Duration _scanBudget = Duration(seconds: 4);

  /// Files pushed into the app's Documents folder (iOS Files, `simctl push`)
  /// show up without a trip through the picker.
  Future<void> _scanDocuments() async {
    final found = await findAudioFilesInDocuments().timeout(
      _scanBudget,
      onTimeout: () => const <String>[],
    );
    if (!mounted) return;
    setState(() {
      _scanning = false;
      for (final path in found) {
        if (!_paths.contains(path)) _paths.add(path);
      }
    });
  }

  Future<void> _refreshNetwork() async {
    final status = await currentNetwork();
    if (mounted && status.addresses.join() != _network.addresses.join()) {
      setState(() => _network = status);
    }
  }

  Future<void> _pickFiles() async {
    _dismissKeyboard();
    _addPaths(await pickAudioFiles(context));
  }

  Future<void> _pickFromLibrary() async {
    _dismissKeyboard();
    _addPaths(await pickLibraryTracks(context));
  }

  void _addPaths(List<String> paths) {
    if (!mounted || paths.isEmpty) return;
    setState(() {
      for (final path in paths) {
        if (!_paths.contains(path)) _paths.add(path);
      }
    });
  }

  /// A picker, a sheet or the Start button must never open over a live
  /// keyboard — and closing one must not pop it back up over the result.
  void _dismissKeyboard() => FocusManager.instance.primaryFocus?.unfocus();

  Future<void> _start() async {
    _dismissKeyboard();
    final name = _name.text.trim();
    if (name.isEmpty) {
      JamSession.read(context).notify(HostSetupStrings.needsName);
      return;
    }
    final session = JamSession.read(context);
    // Setup is normally reached through the same gate, but a jam can have
    // started (a deep link, the sidebar) while this form sat open — and a
    // refused start said only "Could not start the room".
    if (!await jamReadyForNewSession(context, session) || !mounted) return;
    setState(() => _starting = true);
    // Local-network and notification permissions are the controller's job
    // now, so the join paths get them too.
    final started = await session.startHost(
      sessionName: name,
      policy: _policy,
      discoverable: _discoverable,
      paths: List.of(_paths),
    );
    if (!mounted) return;
    setState(() => _starting = false);
    if (started) {
      // Replace setup rather than stack on it, so dismissing the room lands
      // on home instead of back in the form that created it.
      context.pushReplacement('/room');
    } else {
      session.notify(session.error ?? HostSetupStrings.couldNotStart);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          tooltip: HostSetupStrings.back,
          onPressed: () => context.canPop() ? context.pop() : context.go('/'),
        ),
      ),
      body: SafeArea(
        top: false,
        // Starting is a one-way door: the form goes quiet and stops taking
        // taps rather than letting a second policy change race the handshake.
        child: IgnorePointer(
          ignoring: _starting,
          child: AnimatedOpacity(
            opacity: _starting ? 0.5 : 1,
            duration: reduceMotion ? Duration.zero : JamDuration.base,
            curve: JamCurve.base,
            // Held to a readable column and centred on anything wider than a
            // phone (§5 "Medium"), the same as Home, Settings and history —
            // an editable heading stretched across a tablet is a form again.
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: JamContentWidth.reading,
                ),
                child: ListView(
                  // Dragging the form away is the phone-native way to put the
                  // keyboard down; the name field is the only thing that raises
                  // one and it sits at the very top.
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  padding: const EdgeInsets.fromLTRB(
                    JamSpace.page,
                    JamSpace.sm,
                    JamSpace.page,
                    JamSpace.huge,
                  ),
                  children: [
                    Semantics(
                      header: true,
                      child: Text(
                        HostSetupStrings.title,
                        style: context.jamLargeTitle,
                      ),
                    ),
                    const SizedBox(height: JamSpace.md),
                    _NameField(
                      controller: _name,
                      onSubmitted: _dismissKeyboard,
                    ),
                    const SizedBox(height: JamSpace.section),

                    _NetworkNotice(network: _network),

                    // Cards inside a card. In dark the group's surface and
                    // the preset cards' surface are one lightness step apart,
                    // so the whole block collapsed into a single blob. The
                    // presets sit straight on the canvas now and carry their
                    // own edges.
                    Semantics(
                      header: true,
                      child: Text(
                        HostSetupStrings.guests,
                        style: context.jamTitle,
                      ),
                    ),
                    const SizedBox(height: JamSpace.md),
                    _PresetRow(
                      policy: _policy,
                      onChanged: (p) => setState(() => _policy = p),
                    ),
                    const SizedBox(height: JamSpace.md),
                    // A fixed two-line box: the description used to be one
                    // line for "Listen" and two for the others, so the whole
                    // page jumped every time a preset was tapped.
                    SizedBox(
                      height: jamPresetDetailHeight(context),
                      child: Text(
                        HostSetupStrings.detailFor(_policy),
                        maxLines: 2,
                        style: context.jamFootnote,
                      ),
                    ),
                    const SizedBox(height: JamSpace.section),

                    JamSection(
                      children: [
                        JamSwitchRow(
                          label: HostSetupStrings.discoverable,
                          detail: HostSetupStrings.discoverableDetail,
                          value: _discoverable,
                          onChanged: (value) =>
                              setState(() => _discoverable = value),
                          padding: const EdgeInsets.all(JamSpace.card),
                        ),
                      ],
                    ),
                    const SizedBox(height: JamSpace.section),

                    // Heading, then the two ways to add, then the card of
                    // what has been added. Inside the card the buttons read as
                    // the first *row* of the track list — a track called "Add
                    // files" — which is exactly how the review read them.
                    Semantics(
                      header: true,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Expanded(
                            child: Text(
                              HostSetupStrings.music,
                              style: context.jamTitle,
                            ),
                          ),
                          Text(
                            _paths.isEmpty
                                ? HostSetupStrings.musicOptional
                                : HostSetupStrings.trackCount(_paths.length),
                            style: context.jamFootnote,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: JamSpace.md),
                    Row(
                      children: [
                        Expanded(
                          child: JamButton.secondary(
                            label: HostSetupStrings.addFiles,
                            icon: Icons.folder_open_rounded,
                            expand: true,
                            onPressed: () => unawaited(_pickFiles()),
                          ),
                        ),
                        if (jamLibraryAvailable) ...[
                          const SizedBox(width: JamSpace.md),
                          Expanded(
                            child: JamButton.secondary(
                              label: HostSetupStrings.library,
                              icon: Icons.library_music_outlined,
                              expand: true,
                              onPressed: () => unawaited(_pickFromLibrary()),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: JamSpace.md),
                    if (_scanning && _paths.isEmpty)
                      const JamSection(child: _ScanShimmer())
                    else if (_paths.isNotEmpty)
                      JamSection(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: _trackRows(colors),
                        ),
                      )
                    else
                      Text(
                        HostSetupStrings.musicEmpty,
                        style: context.jamFootnote,
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
      bottomNavigationBar: _StartBar(
        loading: _starting,
        onStart: () => unawaited(_start()),
      ),
    );
  }

  List<Widget> _trackRows(JamColors colors) => [
    // No duration on these rows: neither the file picker nor the Documents
    // sweep hands one back — only paths — and a dash where a length should be
    // is worse than a clean trailing edge.
    for (final path in _paths)
      JamTrackRow(
        key: ValueKey(path),
        title: stripAudioExtension(_basename(path)),
        addedByYou: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: JamSpace.card),
        trailing: IconButton(
          // textTertiary on surface is under 3:1; the control a host needs to
          // undo a mis-pick should not be the faintest thing on the row.
          icon: const Icon(Icons.close_rounded, size: 18),
          color: colors.textSecondary,
          tooltip: HostSetupStrings.remove,
          onPressed: () => setState(() => _paths.remove(path)),
        ),
      ),
  ];
}

String _basename(String path) => path.split(Platform.pathSeparator).last;

/// The room name, as an editable heading rather than a form field (§5).
///
/// Borderless was too borderless: with the name already filled in, nothing on
/// screen said it could be changed — reviewers read it as the page's subtitle.
/// A trailing pencil and a hairline that lights up on focus are the smallest
/// pair of hints that still say "this is yours to type in".
class _NameField extends StatefulWidget {
  const _NameField({required this.controller, required this.onSubmitted});

  final TextEditingController controller;
  final VoidCallback onSubmitted;

  @override
  State<_NameField> createState() => _NameFieldState();
}

class _NameFieldState extends State<_NameField> {
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocus);
  }

  void _onFocus() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _focus
      ..removeListener(_onFocus)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.jamColors;
    final focused = _focus.hasFocus;
    return Theme(
      data: theme.copyWith(
        inputDecorationTheme: jamBorderlessInput(colors, theme.textTheme),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Semantics(
                  textField: true,
                  label: HostSetupStrings.nameField,
                  child: TextField(
                    controller: widget.controller,
                    focusNode: _focus,
                    textCapitalization: TextCapitalization.words,
                    textInputAction: TextInputAction.done,
                    maxLines: 1,
                    style: theme.textTheme.headlineMedium,
                    decoration: const InputDecoration(
                      hintText: HostSetupStrings.nameHint,
                    ),
                    onSubmitted: (_) => widget.onSubmitted(),
                  ),
                ),
              ),
              const SizedBox(width: JamSpace.sm),
              Semantics(
                container: true,
                button: true,
                label: HostSetupStrings.editName,
                onTap: () => _focus.requestFocus(),
                excludeSemantics: true,
                child: IconButton(
                  icon: const Icon(Icons.edit_rounded, size: 20),
                  color: focused ? colors.accent : colors.textTertiary,
                  tooltip: HostSetupStrings.editName,
                  onPressed: () => _focus.requestFocus(),
                ),
              ),
            ],
          ),
          AnimatedContainer(
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : JamDuration.fast,
            curve: JamCurve.fast,
            height: focused ? 1.5 : 1,
            color: focused ? colors.accent : colors.separator,
          ),
        ],
      ),
    );
  }
}

/// The three policy presets, as cards.
class _PresetRow extends StatelessWidget {
  const _PresetRow({required this.policy, required this.onChanged});

  final JamPolicy policy;
  final ValueChanged<JamPolicy> onChanged;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: _PresetCard(
          label: HostSetupStrings.presetEverything,
          icon: Icons.groups_rounded,
          idleIcon: Icons.groups_outlined,
          selected: policy == JamPolicy.open,
          onTap: () => onChanged(JamPolicy.open),
        ),
      ),
      const SizedBox(width: JamSpace.md),
      Expanded(
        child: _PresetCard(
          label: HostSetupStrings.presetAddMusic,
          icon: Icons.queue_music_rounded,
          idleIcon: Icons.queue_music_outlined,
          selected: policy == JamPolicy.jam,
          onTap: () => onChanged(JamPolicy.jam),
        ),
      ),
      const SizedBox(width: JamSpace.md),
      Expanded(
        child: _PresetCard(
          label: HostSetupStrings.presetListen,
          icon: Icons.headphones_rounded,
          idleIcon: Icons.headphones_outlined,
          selected: policy == JamPolicy.listenOnly,
          onTap: () => onChanged(JamPolicy.listenOnly),
        ),
      ),
    ],
  );
}

class _PresetCard extends StatelessWidget {
  const _PresetCard({
    required this.label,
    required this.icon,
    required this.idleIcon,
    required this.selected,
    required this.onTap,
  });

  final String label;

  /// The filled glyph, shown while selected.
  final IconData icon;

  /// The outlined glyph, shown while not. The pair cross-fades (§5).
  final IconData idleIcon;

  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final tint = selected ? colors.accent : colors.textSecondary;

    return Semantics(
      button: true,
      selected: selected,
      label: label,
      onTap: onTap,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: reduceMotion ? Duration.zero : JamDuration.fast,
          curve: JamCurve.fast,
          height: 88,
          decoration: BoxDecoration(
            color: selected ? colors.accentSoft : colors.surfaceMuted,
            borderRadius: BorderRadius.circular(JamRadius.lg),
            border: Border.all(
              color: selected ? colors.accent : Colors.transparent,
              width: 1.5,
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AnimatedSwitcher(
                duration: reduceMotion ? Duration.zero : JamDuration.fast,
                switchInCurve: JamCurve.fast,
                child: Icon(
                  selected ? icon : idleIcon,
                  key: ValueKey(selected),
                  size: 20,
                  color: tint,
                ),
              ),
              const SizedBox(height: JamSpace.sm),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: JamSpace.xs),
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: Theme.of(
                    context,
                  ).textTheme.titleSmall!.copyWith(color: tint),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The blurred bottom bar holding the screen's one primary action (§5).
class _StartBar extends StatelessWidget {
  const _StartBar({required this.loading, required this.onStart});

  final bool loading;
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    return ClipRect(
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colors.surface.withValues(alpha: 0.86),
            border: Border(
              top: BorderSide(color: colors.separator, width: 0.5),
            ),
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
              child: JamButton.primary(
                label: HostSetupStrings.start,
                semanticLabel: loading
                    ? HostSetupStrings.starting
                    : HostSetupStrings.start,
                expand: true,
                loading: loading,
                onPressed: onStart,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Two placeholder rows while the Documents sweep runs (§6.11 — a page-level
/// spinner tells you nothing about what is coming).
class _ScanShimmer extends StatefulWidget {
  const _ScanShimmer();

  @override
  State<_ScanShimmer> createState() => _ScanShimmerState();
}

class _ScanShimmerState extends State<_ScanShimmer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _sweep = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _sweep.stop();
    } else if (!_sweep.isAnimating) {
      _sweep.repeat();
    }
  }

  @override
  void dispose() {
    _sweep.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    return Semantics(
      liveRegion: true,
      label: HostSetupStrings.looking,
      child: ExcludeSemantics(
        child: AnimatedBuilder(
          animation: _sweep,
          builder: (context, _) => Column(
            children: [
              Divider(height: 0.5, thickness: 0.5, color: colors.separator),
              for (var row = 0; row < 2; row++)
                SizedBox(
                  height: kJamTrackRowHeight,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: JamSpace.card,
                    ),
                    child: Row(
                      children: [
                        _Block(
                          width: 48,
                          height: 48,
                          radius: JamRadius.sm,
                          t: _sweep.value,
                          colors: colors,
                        ),
                        const SizedBox(width: JamSpace.md),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              _Block(
                                width: row == 0 ? 180 : 132,
                                height: 13,
                                radius: JamRadius.xs,
                                t: _sweep.value,
                                colors: colors,
                              ),
                              const SizedBox(height: JamSpace.sm),
                              _Block(
                                width: 92,
                                height: 11,
                                radius: JamRadius.xs,
                                t: _sweep.value,
                                colors: colors,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One shimmering placeholder block.
class _Block extends StatelessWidget {
  const _Block({
    required this.width,
    required this.height,
    required this.radius,
    required this.t,
    required this.colors,
  });

  final double width;
  final double height;
  final double radius;

  /// The sweep's phase, 0–1.
  final double t;

  final JamColors colors;

  @override
  Widget build(BuildContext context) => Container(
    width: width,
    height: height,
    decoration: BoxDecoration(
      color: colors.surfaceMuted,
      borderRadius: BorderRadius.circular(radius),
      gradient: LinearGradient(
        begin: Alignment(-1 + 3 * t, 0),
        end: Alignment(-0.4 + 3 * t, 0),
        colors: [
          colors.surfaceMuted,
          Color.lerp(colors.surfaceMuted, colors.canvas, 0.7)!,
          colors.surfaceMuted,
        ],
        stops: const [0, 0.5, 1],
      ),
    ),
  );
}

/// What guests have to be on. Silent when everything is normal; the point is
/// the off-network case, where nobody can join no matter how the room is set
/// up.
class _NetworkNotice extends StatelessWidget {
  const _NetworkNotice({required this.network});

  final JamNetworkStatus network;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    if (!network.connected) {
      return Padding(
        padding: const EdgeInsets.only(bottom: JamSpace.section),
        child: _Notice(
          icon: Icons.wifi_off_rounded,
          color: colors.warning,
          fill: colors.highlightSoft,
          title: HostSetupStrings.noNetworkTitle,
          detail: HostSetupStrings.noNetworkDetail,
        ),
      );
    }
    if (network.isHotspotHost) {
      return Padding(
        padding: const EdgeInsets.only(bottom: JamSpace.section),
        child: _Notice(
          icon: Icons.wifi_tethering_rounded,
          color: colors.textSecondary,
          fill: colors.surfaceMuted,
          title: HostSetupStrings.hotspotTitle,
          detail: HostSetupStrings.hotspotDetail,
        ),
      );
    }
    return const SizedBox.shrink();
  }
}

class _Notice extends StatelessWidget {
  const _Notice({
    required this.icon,
    required this.color,
    required this.fill,
    required this.title,
    required this.detail,
  });

  final IconData icon;
  final Color color;
  final Color fill;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '$title. $detail',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.all(JamSpace.card),
        decoration: BoxDecoration(
          color: fill,
          borderRadius: BorderRadius.circular(JamRadius.md),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(width: JamSpace.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: context.jamRowTitle.copyWith(color: color),
                  ),
                  const SizedBox(height: JamSpace.xxs),
                  Text(detail, style: context.jamFootnote),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
