/// Start a Jam, in one tap (DESIGN_SPEC v3 §6.2).
///
/// A grouped sheet with **Cancel** and **Start** in its nav bar, like
/// creating an event in Apple Invites: the room name as a big inline field
/// (its placeholder *is* the default name, so Start works untouched), the
/// songs, who can do what, and whether people nearby can see it. Music is
/// optional — a host can start empty and add songs once live
/// (`JamHostEngine.addMediaFile` works mid-session).
///
/// The network still matters: on a trip there is usually no Wi-Fi, so
/// somebody has to run a hotspot, and the sheet says so in one plain line
/// under the nearby switch before anyone taps Start.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:go_router/go_router.dart';
import 'package:localjam_client/localjam_client.dart';

import '../design/breakpoints.dart';
import '../design/tokens.dart';
import '../design/typography.dart';
import '../state/session_controller.dart';
import '../util/format.dart';
import '../util/media_picking.dart';
import '../util/network.dart';
import '../widgets/buttons.dart';
import '../widgets/guests_can.dart';
import '../widgets/list.dart';
import '../widgets/section.dart';
import '../widgets/session_gate.dart';
import '../widgets/sheet.dart';
import '../widgets/swipe_action.dart';
import '../widgets/track_row.dart';

/// Everything this screen says out loud.
abstract final class HostSetupStrings {
  static const String title = 'Start a Jam';
  static const String cancel = 'Cancel';
  static const String start = 'Start';
  static const String starting = 'Starting the jam';
  static const String nameField = 'Jam name';
  static const String clear = 'Clear';

  /// The default name, and the field's placeholder: "Mia’s Jam".
  static String defaultName(String identity) =>
      identity.isEmpty ? fallbackName : '$identity’s Jam';
  static const String fallbackName = 'Jam';

  static const String songs = 'Songs';

  /// "12 Songs" — the section header once there are some.
  static String songCount(int n) => n == 1 ? '1 Song' : '$n Songs';
  static const String addSongs = 'Add Songs';
  static const String looking = 'Looking for music on this device…';
  static const String songsFooter =
      'Optional. Everyone can add songs once the jam starts.';
  static const String remove = 'Remove';

  static const String discoverable = 'Show to People Nearby';
  static const String discoverableOn =
      'People on this Wi‑Fi can see and join this jam.';
  static const String discoverableOff =
      'Only people with the link or the code can join.';
  static const String offline =
      'You’re not on Wi‑Fi. Turn on your hotspot and have everyone '
      'connect to it, then start the jam.';
  static const String hotspot =
      'Jams don’t show up over a hotspot. Show guests the code once you '
      'start.';

  static const String couldNotStart = 'Couldn’t start the jam.';
}

class HostSetupScreen extends StatefulWidget {
  const HostSetupScreen({
    super.key,
    this.initialPaths,
    this.initialName,
    this.scrollController,
  });

  /// Tracks to preload — the "Host Again" seam from jam history.
  ///
  /// A non-null value is an *exact* set: the Documents sweep below is skipped
  /// for it, or reopening a two-track past jam would quietly hand the host
  /// whatever else happens to be sitting in the app's Documents folder.
  final List<String>? initialPaths;

  /// Room name to preload, also from history.
  final String? initialName;

  /// The sheet's scroll controller, when this is presented as a page sheet:
  /// a downward drag at the top of the list then dismisses the sheet. Null
  /// when it is a plain page.
  final ScrollController? scrollController;

  @override
  State<HostSetupScreen> createState() => _HostSetupScreenState();
}

class _HostSetupScreenState extends State<HostSetupScreen> {
  final TextEditingController _name = TextEditingController();
  final List<String> _paths = [];
  String _defaultName = HostSetupStrings.fallbackName;
  // "Add Music" is the jam: everyone contributes, the host keeps the
  // transport. Open by default handed a stranger on the same Wi-Fi the pause
  // button.
  JamPolicy _policy = JamPolicy.jam;
  bool _discoverable = true;
  bool _starting = false;
  bool _scanning = false;
  bool _scrolledUnder = false;
  JamNetworkStatus _network = JamNetworkStatus.offline;
  Timer? _networkPoll;

  @override
  void initState() {
    super.initState();
    _paths.addAll(widget.initialPaths ?? const []);
    final preset = widget.initialName;
    if (preset != null && preset.isNotEmpty) _name.text = preset;
    unawaited(_loadDefaultName());
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

  Future<void> _loadDefaultName() async {
    final identity = await JamIdentity.displayName();
    if (!mounted) return;
    setState(() => _defaultName = HostSetupStrings.defaultName(identity));
  }

  /// How long the Documents sweep gets before the row stops spinning.
  ///
  /// The sweep walks a directory that can live on iCloud Drive, and a
  /// spinner that never resolves is worse than an empty list — you can
  /// always add songs by hand.
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

  /// Add Songs: the library or the file picker, whichever this platform has
  /// (both on Android, where the choice comes first).
  Future<void> _addSongs() async {
    _dismissKeyboard();
    final source = await chooseAddSource(context);
    if (source == null || !mounted) return;
    final pick = source == JamAddSource.library
        ? pickLibraryTracks(context)
        : pickAudioFiles(context);
    _addPaths(await pick);
  }

  void _addPaths(List<String> paths) {
    if (!mounted || paths.isEmpty) return;
    setState(() {
      for (final path in paths) {
        if (!_paths.contains(path)) _paths.add(path);
      }
    });
  }

  void _remove(String path) => setState(() => _paths.remove(path));

  /// A picker, a sheet or Start must never open over a live keyboard — and
  /// closing one must not pop it back up over the result.
  void _dismissKeyboard() => FocusManager.instance.primaryFocus?.unfocus();

  void _cancel() {
    _dismissKeyboard();
    context.canPop() ? context.pop() : context.go('/');
  }

  Future<void> _start() async {
    _dismissKeyboard();
    final typed = _name.text.trim();
    final name = typed.isEmpty ? _defaultName : typed;
    final session = JamSession.read(context);
    // Start a Jam is normally reached through the same gate, but a jam can
    // have started (a deep link, the sidebar) while this sheet sat open —
    // and a refused start said only "Couldn't start".
    if (!await jamReadyForNewSession(context, session) || !mounted) return;
    setState(() => _starting = true);
    // Local-network and notification permissions are the controller's job,
    // so the join paths get them too.
    final started = await session.startHost(
      sessionName: name,
      policy: _policy,
      discoverable: _discoverable,
      paths: List.of(_paths),
    );
    if (!mounted) return;
    setState(() => _starting = false);
    if (started) {
      // Replace the sheet rather than stack on it, so dismissing the room
      // lands on home instead of back in the form that created it.
      context.pushReplacement('/room');
    } else {
      session.notify(session.error ?? HostSetupStrings.couldNotStart);
    }
  }

  bool _onScroll(ScrollNotification n) {
    if (n.depth != 0 || n.metrics.axis != Axis.vertical) return false;
    final under = n.metrics.pixels > n.metrics.minScrollExtent + 0.5;
    if (under != _scrolledUnder) setState(() => _scrolledUnder = under);
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final sheet = widget.scrollController != null;
    final background = sheet
        ? colors.elevatedGroupedBackground
        : colors.groupedBackground;

    final header = JamSheetHeader(
      title: HostSetupStrings.title,
      scrolledUnder: _scrolledUnder,
      leading: JamTextButton(
        label: HostSetupStrings.cancel,
        onPressed: _starting ? null : _cancel,
      ),
      trailing: _starting
          ? Semantics(
              label: HostSetupStrings.starting,
              liveRegion: true,
              child: const SizedBox(
                width: JamMetrics.hitTarget,
                height: JamMetrics.hitTarget,
                child: CupertinoActivityIndicator(),
              ),
            )
          : JamTextButton(
              label: HostSetupStrings.start,
              bold: true,
              onPressed: () => unawaited(_start()),
            ),
    );

    final list = ListView(
      controller: widget.scrollController,
      // Dragging the form away is the phone-native way to put the keyboard
      // down; the name field is the only thing that raises one.
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: EdgeInsets.only(
        top: JamSpace.lg,
        bottom: JamSpace.huge + MediaQuery.paddingOf(context).bottom,
      ),
      children: [
        JamSection(
          child: _NameField(
            controller: _name,
            placeholder: _defaultName,
            onSubmitted: _dismissKeyboard,
          ),
        ),
        const SizedBox(height: JamSpace.section),
        _songsSection(),
        const SizedBox(height: JamSpace.section),
        JamSection(
          footer: JamPresetStrings.summary(_policy),
          children: [
            JamGuestsCanRow(
              policy: _policy,
              onChanged: (p) => setState(() => _policy = p),
            ),
          ],
        ),
        const SizedBox(height: JamSpace.section),
        JamSection(
          footer: _discoverableFooter(),
          children: [
            JamRow.toggle(
              title: HostSetupStrings.discoverable,
              value: _discoverable,
              onChanged: (value) => setState(() => _discoverable = value),
            ),
          ],
        ),
      ],
    );

    return ColoredBox(
      color: background,
      child: JamGroupedSurface(
        elevated: sheet,
        child: SafeArea(
          bottom: false,
          // Starting is a one-way door: the form stops taking taps rather
          // than letting a second policy change race the handshake.
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              header,
              Expanded(
                child: IgnorePointer(
                  ignoring: _starting,
                  child: NotificationListener<ScrollNotification>(
                    onNotification: _onScroll,
                    // Held to a readable column on anything wider than a
                    // phone — a form stretched across a desktop window is
                    // hard to read.
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(
                          maxWidth: JamContentWidth.reading,
                        ),
                        child: list,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _discoverableFooter() {
    if (!_network.connected) return HostSetupStrings.offline;
    if (_network.isHotspotHost) return HostSetupStrings.hotspot;
    return _discoverable
        ? HostSetupStrings.discoverableOn
        : HostSetupStrings.discoverableOff;
  }

  Widget _songsSection() {
    return JamSection(
      header: _paths.isEmpty
          ? HostSetupStrings.songs
          : HostSetupStrings.songCount(_paths.length),
      footer: _paths.isEmpty && !_scanning
          ? HostSetupStrings.songsFooter
          : null,
      children: [
        JamRow(
          title: HostSetupStrings.addSongs,
          icon: CupertinoIcons.plus_circle_fill,
          tinted: true,
          onTap: () => unawaited(_addSongs()),
        ),
        if (_scanning && _paths.isEmpty) const _LookingRow(),
        // No duration on these rows: neither the file picker nor the
        // Documents sweep hands one back — only paths — and a dash where a
        // length should be is worse than a clean trailing edge.
        for (final path in _paths)
          JamSwipeAction(
            key: ValueKey(path),
            label: HostSetupStrings.remove,
            onAction: () async => true,
            onRemoved: () => _remove(path),
            child: JamTrackRow(title: stripAudioExtension(_basename(path))),
          ),
      ],
    );
  }
}

String _basename(String path) => path.split(Platform.pathSeparator).last;

/// The room name, as a big inline field in its own grouped cell — Apple
/// Invites' event title. The placeholder is the default name, so leaving it
/// alone is a choice, not an error.
class _NameField extends StatelessWidget {
  const _NameField({
    required this.controller,
    required this.placeholder,
    required this.onSubmitted,
  });

  final TextEditingController controller;
  final String placeholder;
  final VoidCallback onSubmitted;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final style = context.jamTitle2;
    return Semantics(
      textField: true,
      label: HostSetupStrings.nameField,
      child: CupertinoTextField.borderless(
        controller: controller,
        placeholder: placeholder,
        placeholderStyle: style.copyWith(color: colors.tertiaryLabel),
        style: style,
        cursorColor: colors.tint,
        textCapitalization: TextCapitalization.words,
        textInputAction: TextInputAction.done,
        clearButtonMode: OverlayVisibilityMode.editing,
        clearButtonSemanticLabel: HostSetupStrings.clear,
        maxLines: 1,
        padding: const EdgeInsets.symmetric(
          horizontal: kJamRowInset,
          vertical: JamSpace.md,
        ),
        onSubmitted: (_) => onSubmitted(),
      ),
    );
  }
}

/// "Looking for music on this device…" while the Documents sweep runs — a
/// system spinner in the row where the songs will land.
class _LookingRow extends StatelessWidget implements JamSelfSeparatingRow {
  const _LookingRow();

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      label: HostSetupStrings.looking,
      excludeSemantics: true,
      child: JamRow(
        title: HostSetupStrings.looking,
        leading: const SizedBox(
          width: JamMetrics.rowIconBox,
          child: CupertinoActivityIndicator(),
        ),
        leadingWidth: JamMetrics.rowIconBox,
        enabled: false,
      ),
    );
  }
}
