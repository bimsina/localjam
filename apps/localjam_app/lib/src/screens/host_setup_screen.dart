/// Start a Jam, in one tap (DESIGN_SPEC v3 §6.2).
///
/// A grouped sheet with **Cancel** and **Start** in its nav bar, like
/// creating an event in Apple Invites: the room name as a big inline field
/// (filled in with the default name, in ink rather than a grey placeholder,
/// so Start works untouched and the name never looks unset), the songs —
/// under the app's one Add Songs row — who can do what, and whether people
/// nearby can see it. Music is
/// optional — a host can start empty and add songs once live
/// (`JamHostEngine.addMediaFile` works mid-session).
///
/// The network still matters: on a trip there is usually no Wi-Fi, so
/// somebody has to run a hotspot, and the sheet says so in one plain line
/// under the nearby switch before anyone taps Start.
library;

import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:go_router/go_router.dart';
import 'package:localjam_client/localjam_client.dart';

import '../design/breakpoints.dart';
import '../design/theme.dart';
import '../design/tokens.dart';
import '../design/typography.dart';
import '../state/session_controller.dart';
import '../util/media_picking.dart';
import '../util/network.dart';
import '../widgets/guests_can.dart';
import '../widgets/list.dart';
import '../widgets/progress.dart';
import '../widgets/section.dart';
import '../widgets/session_gate.dart';
import '../widgets/sheet.dart';
import '../widgets/swipe_action.dart';
import '../widgets/text_field.dart';
import '../widgets/track_row.dart';

/// Everything this screen says out loud.
abstract final class HostSetupStrings {
  static const String title = 'Start a jam';
  static const String cancel = 'Cancel';
  static const String start = 'Start';
  static const String starting = 'Starting the jam';
  static const String nameField = 'Jam name';

  /// The default name, the field's starting text and its placeholder once
  /// cleared: "Mia’s Jam".
  static String defaultName(String identity) =>
      identity.isEmpty ? fallbackName : '$identity’s Jam';
  static const String fallbackName = 'Jam';

  static const String songs = 'Songs';

  /// "12 songs" — the section header once there are some (sentence case,
  /// §10.9).
  static String songCount(int n) => n == 1 ? '1 song' : '$n songs';
  static const String addSongs = 'Add songs';
  static const String looking = 'Looking for music on this device…';

  /// The Songs footer, true to the chosen preset: under Listen Only nobody
  /// but the host adds anything.
  static const String songsFooterGuests =
      'Optional. Guests can add songs once the jam starts.';
  static const String songsFooterHost =
      'Optional. You can add songs once the jam starts.';
  static String songsFooter(JamPolicy policy) =>
      policy.addTracks ? songsFooterGuests : songsFooterHost;
  static const String remove = 'Remove';

  static const String discoverable = 'Show to people nearby';
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

  /// Tracks to preload — the "Host again" seam from jam history.
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
  final FocusNode _nameFocus = FocusNode();

  /// Whether the field has been given the default name yet — once only, so
  /// a name the host cleared is not filled back in under them.
  bool _prefilled = false;

  /// Whether the field still holds the default name nobody has touched:
  /// the first tap then selects it all, so typing replaces it.
  bool _defaultUntouched = false;

  /// The songs, in order, each with whatever is known about it so far: a
  /// library pick arrives with title, artist and length, a file with only
  /// its path until its tags have been read ([readPickedTrack]).
  final List<JamPickedTrack> _tracks = [];
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
    _addTracks([
      for (final path in widget.initialPaths ?? const <String>[])
        JamPickedTrack(path: path),
    ], rebuild: false);
    final preset = widget.initialName;
    if (preset != null && preset.isNotEmpty) {
      _name.text = preset;
      _prefilled = true;
    }
    _nameFocus.addListener(_onNameFocus);
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
    _nameFocus
      ..removeListener(_onNameFocus)
      ..dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _loadDefaultName() async {
    final identity = await JamIdentity.displayName();
    if (!mounted) return;
    setState(() {
      _defaultName = HostSetupStrings.defaultName(identity);
      // The default as real text, not a grey placeholder that reads as
      // empty or disabled — unless someone has typed already.
      if (!_prefilled && _name.text.isEmpty) {
        _name.text = _defaultName;
        _defaultUntouched = true;
      }
      _prefilled = true;
    });
  }

  /// The first focus on an untouched default selects it all, so a new name
  /// is typed straight over it — and keeping it is still zero taps.
  void _onNameFocus() {
    if (!_nameFocus.hasFocus || !_defaultUntouched) return;
    _defaultUntouched = false;
    if (_name.text != _defaultName) return;
    void selectAll() => _name.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _name.text.length,
    );
    selectAll();
    // The tap that focused the field places its caret after this listener
    // runs; select again once it has.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _nameFocus.hasFocus && _name.text == _defaultName) {
        selectAll();
      }
    });
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
    setState(() => _scanning = false);
    _addTracks([for (final path in found) JamPickedTrack(path: path)]);
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
    final picked = source == JamAddSource.library
        ? await pickLibraryTrackDetails(context)
        : [
            for (final path in await pickAudioFiles(context))
              JamPickedTrack(path: path),
          ];
    _addTracks(picked);
  }

  /// Appends [picked] (skipping files already in the list) and reads each
  /// one's tags and cover in the background — off the UI isolate, two at a
  /// time — so the rows fill in with real titles, artists, lengths and
  /// covers instead of file names.
  void _addTracks(List<JamPickedTrack> picked, {bool rebuild = true}) {
    if (!mounted || picked.isEmpty) return;
    final fresh = <JamPickedTrack>[
      for (final track in picked)
        if (!_tracks.any((t) => t.path == track.path)) track,
    ];
    if (fresh.isEmpty) return;
    void add() => _tracks.addAll(fresh);
    rebuild ? setState(add) : add();
    for (final track in fresh) {
      unawaited(readPickedTrack(track).then(_onTagsRead));
    }
  }

  void _onTagsRead(JamPickedTrack read) {
    if (!mounted) return;
    final index = _tracks.indexWhere((t) => t.path == read.path);
    if (index < 0) return; // Removed while its tags were being read.
    setState(() => _tracks[index] = read);
  }

  void _remove(String path) =>
      setState(() => _tracks.removeWhere((t) => t.path == path));

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
      paths: [for (final track in _tracks) track.path],
    );
    if (!mounted) return;
    setState(() => _starting = false);
    if (started) {
      // Replace the sheet rather than stack on it, so dismissing the room
      // lands on home instead of back in the form that created it.
      context.pushReplacement('/room');
    } else {
      session.notify(
        session.error ?? HostSetupStrings.couldNotStart,
        tone: JamNoticeTone.error,
      );
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
      actions: JamSheetActions.confirm(
        label: HostSetupStrings.start,
        onConfirm: () => unawaited(_start()),
        onCancel: _cancel,
        busy: _starting,
        busyLabel: HostSetupStrings.starting,
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
            focusNode: _nameFocus,
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
    final hasSongs = _tracks.isNotEmpty;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final coverPx = (JamArtworkSize.row * dpr).round();
    return JamSection(
      header: hasSongs
          ? HostSetupStrings.songCount(_tracks.length)
          : HostSetupStrings.songs,
      footer: !hasSongs && !_scanning
          ? HostSetupStrings.songsFooter(_policy)
          : null,
      children: [
        // The app's one Add Songs — the same row the queue has once the jam
        // is live — and always on the songs' grid, so it does not move when
        // the first song lands under it.
        JamAddSongsRow(
          onTap: () => unawaited(_addSongs()),
          title: HostSetupStrings.addSongs,
        ),
        if (_scanning && !hasSongs) const _LookingRow(),
        for (final track in _tracks)
          JamSwipeAction(
            key: ValueKey(track.path),
            label: HostSetupStrings.remove,
            onAction: () async => true,
            onRemoved: () => _remove(track.path),
            child: JamTrackRow(
              title: track.displayTitle,
              byline: track.artist,
              duration: track.duration,
              // Decoded at the size it is drawn, not at the file's 1400 px.
              artworkImage: track.artworkBytes == null
                  ? null
                  : ResizeImage(
                      MemoryImage(track.artworkBytes!),
                      width: coverPx,
                      height: coverPx,
                    ),
              artworkId: track.artworkBytes == null
                  ? null
                  : identityHashCode(track.artworkBytes),
              artworkLoading: !track.tagsRead,
            ),
          ),
      ],
    );
  }
}

/// The room name, as a big inline field in its own grouped cell — Apple
/// Invites' event title: the one field that is its section's cell rather
/// than a filled [JamTextField], with the same clear button
/// ([JamFieldClearButton]). It starts filled with the default name;
/// cleared, the placeholder says the same name, so leaving it is a choice,
/// not an error.
class _NameField extends StatelessWidget {
  const _NameField({
    required this.controller,
    required this.focusNode,
    required this.placeholder,
    required this.onSubmitted,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
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
        focusNode: focusNode,
        // The in-app appearance, not the device's (§10.8).
        keyboardAppearance: jamKeyboardAppearance(context),
        placeholder: placeholder,
        placeholderStyle: style.copyWith(color: colors.secondaryLabel),
        style: style,
        cursorColor: colors.tint,
        textCapitalization: TextCapitalization.words,
        textInputAction: TextInputAction.done,
        // The app's one clear button, as in every other field (CR-16) —
        // its circle, not its box, ending on the row's trailing inset.
        suffix: Padding(
          padding: const EdgeInsetsDirectional.only(
            end: kJamRowInset - (kJamFieldClearHit - kJamFieldClearSize) / 2,
          ),
          child: JamFieldClearButton(controller: controller),
        ),
        suffixMode: OverlayVisibilityMode.editing,
        clearButtonMode: OverlayVisibilityMode.never,
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
/// waiting ring in a cover's slot, on the songs' grid, where they will
/// land.
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
        leading: const SizedBox.square(
          dimension: JamArtworkSize.row,
          child: Center(
            child: JamProgressRing(size: JamProgressRing.controlSize),
          ),
        ),
        leadingWidth: JamArtworkSize.row,
        enabled: false,
      ),
    );
  }
}
