/// Owns the live jam, above the Navigator.
///
/// Before the overhaul each screen's `State` created its own engine and called
/// `close()` from `dispose`, so backing out of a route silently ended the
/// session. Nothing persistent — a docked room bar, a deep link arriving while
/// a jam runs, settings without leaving the room — was possible while the
/// engine's lifetime was a route's lifetime.
///
/// This controller notifies on *session lifecycle* only: a session started,
/// ended, or changed connection. Playback detail (snapshots, playlist, peers)
/// stays on the engine's own streams, which screens subscribe to directly, so
/// a track change never rebuilds the whole app.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:localjam_client/localjam_client.dart';

import '../design/artwork_tint.dart';
import '../design/tokens.dart';
import '../util/format.dart';
import '../util/network.dart';
import '../util/permissions.dart';
import 'position_ticker.dart';
import 'queue_actions.dart';

/// Which side of the jam this device is on.
enum JamSide {
  /// This device runs the server and owns the authoritative state.
  host,

  /// This device joined someone else's room.
  guest,
}

/// Where the session is in its lifecycle.
enum JamSessionPhase {
  /// No session. Home shows nearby rooms.
  idle,

  /// A start/join is in flight.
  starting,

  /// A session is running.
  live,

  /// The session reached a terminal state and the user has not dismissed it
  /// yet ([JamSessionController.endReason] says why).
  ended,
}

/// A transient, one-shot message for the app shell to surface.
///
/// Emitted rather than stored: these are things that *happened* ("Ana
/// joined", "the host said no"), not state, and every screen showing them
/// itself was how the protocol's error stream ended up with no subscriber at
/// all. One channel, one place that renders it (the router shell).
@immutable
class JamNotice {
  const JamNotice(this.message, {this.actionLabel, this.onAction});

  final String message;

  /// Optional action, e.g. "Open settings" on a permanent permission denial.
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  String toString() => 'JamNotice($message)';
}

/// What the app says when Android takes the foreground service away.
const String kJamKeepAliveLost = 'Background playback may pause';

/// The lead of the receipt a host gets on the way back to home.
const String kJamEnded = 'Jam ended';

/// What a pick that added nothing says, because the room already had exactly
/// those bytes.
const String kJamAlreadyQueued = 'Already in the queue';

/// What the app says when a nearby room turns out to have gone.
const String kJamRoomGone = 'That jam has ended';

/// One file that could not be added to the queue.
@immutable
class JamAddFailure {
  const JamAddFailure(this.name, this.reason);

  /// The file's display name — what the user actually recognises.
  final String name;

  /// Loggable detail. Never shown raw; see [JamSessionController.addFiles].
  final String reason;
}

/// The app's single live-jam owner.
/// A join whose `host` candidates are not all on this network (§9).
///
/// Not a transport failure: nothing was dialled. The link asked the app to
/// open a socket somewhere it has no business going, and it was refused
/// before the first packet.
class JamOffNetworkException implements Exception {
  const JamOffNetworkException();

  @override
  String toString() => 'JamOffNetworkException: the join URI is not local';
}

class JamSessionController extends ChangeNotifier {
  JamSessionController() {
    // Identity can arrive late. `JamIdentity.displayName()` hands out an
    // ephemeral name when `shared_preferences` does not answer inside its
    // timeout, then adopts the stored one in the background — and everything
    // already showing "Neon Walrus" would have gone on showing it for the
    // life of the process. One subscription here rebuilds every screen that
    // depends on the session, which is every screen that puts a name on
    // itself.
    JamIdentity.changes.addListener(_onIdentityChanged);
  }

  JamEngine? _engine;
  JamSide? _side;
  JamSessionPhase _phase = JamSessionPhase.idle;
  String? _error;
  JamSessionEndReason? _endReason;
  JamConnectionState _connection = JamConnectionState.connected;
  JamPositionTicker? _position;
  final List<StreamSubscription<Object?>> _subs = [];
  final StreamController<JamNotice> _notices =
      StreamController<JamNotice>.broadcast();
  Uri? _joiningUri;
  String? _joiningName;
  Uri? _lastJoinUri;
  List<JamAddFailure> _addFailures = const [];

  /// Guest display names by peerId, so a `peerLeft` event (which carries only
  /// an id) can still say who left.
  final Map<String, String> _peerNames = {};

  /// Nearby rooms over mDNS. Owned here rather than by a screen so the home
  /// screen can show live discovery the moment the app opens, and so a
  /// rebuild never restarts the browse.
  ///
  /// [JamRoomBrowser] is single-use — its `stop()` disposes the notifier it
  /// publishes on and latches the browser closed — so each browse gets a
  /// fresh one and the controller mirrors it onto a notifier of its own that
  /// outlives them all. Otherwise the first hosted jam would leave the nearby
  /// list permanently dead.
  final ValueNotifier<List<JamNearbyRoom>> _nearby =
      ValueNotifier<List<JamNearbyRoom>>(const []);
  JamRoomBrowser? _browser;

  /// The session token of the room this device is in, held here rather than
  /// only on the browser because the browser is torn down and rebuilt around
  /// a session and the token has to outlive it.
  ///
  /// This is the filter home used to apply itself: a host's own daemon
  /// answers its own browse, so without it the one room you cannot join is
  /// offered to you with "Tap to join" under it. [JamRoomBrowser] filters by
  /// token because a host on Wi-Fi *and* a hotspot publishes two address
  /// lists and one token.
  String? _excludedToken;

  /// Whether discovery is wanted whenever this device is out of a room.
  ///
  /// Joining or hosting stops the browse; nothing used to start it again, so
  /// one jam left the nearby list permanently empty for the rest of the app's
  /// life. Latched by [startBrowsing] and released only by an explicit
  /// [stopBrowsing], so returning to idle resumes what the user last asked
  /// for.
  bool _browseWanted = false;

  /// Ambient artwork tints (§2.2), shared across the app.
  ///
  /// The room screen and the docked room bar are looking at the same cover,
  /// and deriving a tint decodes and quantises an image — one cache above
  /// both means one derivation per track for the life of the jam. Cleared
  /// when the session goes.
  final JamTintCache tints = JamTintCache();

  /// The mediaId the last snapshot carried, for spotting a queue that wrapped.
  String? _lastMediaId;

  /// Whether the OS keep-alive was held the last time we looked, so the
  /// warning is raised on the *transition* rather than every rebuild.
  bool _keepAliveHeld = true;

  /// When the last "somebody joined" buzz fired, and the minimum gap between
  /// two of them.
  DateTime? _lastPeerBuzz;
  static const Duration _peerBuzzGap = Duration(milliseconds: 900);

  /// The live engine, or null when idle. Host and guest behind one type —
  /// UI written against this works on either side.
  JamEngine? get engine => _engine;

  /// The live engine as a host, or null when guesting or idle.
  JamHostEngine? get hostEngine =>
      _engine is JamHostEngine ? _engine! as JamHostEngine : null;

  /// The live engine as a guest, or null when hosting or idle.
  JamGuestEngine? get guestEngine =>
      _engine is JamGuestEngine ? _engine! as JamGuestEngine : null;

  /// Which side this device is on, or null when idle.
  JamSide? get side => _side;

  /// Whether this device owns the room.
  bool get isHost => _side == JamSide.host;

  JamSessionPhase get phase => _phase;

  /// Whether a session is running right now.
  bool get isLive => _phase == JamSessionPhase.live && _engine != null;

  /// Whether there is a room to show — live, or ended and not yet dismissed.
  /// The docked bar keys off this rather than [isLive] so a terminal state is
  /// reachable from wherever the user happened to be standing.
  bool get hasRoom => isLive || _phase == JamSessionPhase.ended;

  /// The last start/join failure, for the screen that attempted it.
  String? get error => _error;

  /// Transient messages for the shell to surface — protocol errors the host
  /// reported, people coming and going, permission dead ends. Broadcast, so
  /// late subscribers simply miss what already happened, which is correct for
  /// something this ephemeral.
  Stream<JamNotice> get notices => _notices.stream;

  /// The room this device is joining right now, or null. A join runs a
  /// handshake, a clock burst and a prefetch decision — long enough that a
  /// tap with no feedback reads as a dead button.
  Uri? get joiningUri => _joiningUri;

  /// The name of the room being joined, when the caller knew one.
  String? get joiningName => _joiningName;

  /// Whether a start or join is in flight. Callers use this to disable the
  /// *other* ways in while one is running.
  bool get isBusy => _phase == JamSessionPhase.starting;

  /// The last URI this device joined with, kept past the engine's disposal so
  /// a terminal "session ended" screen can offer a rejoin.
  Uri? get lastJoinUri => _lastJoinUri;

  /// Files the last add attempt could not take, newest attempt only.
  List<JamAddFailure> get addFailures => List.unmodifiable(_addFailures);

  /// Publishes a transient message. Public so screens that own a flow the
  /// controller cannot see (pickers, permissions, the scanner) can use the
  /// same channel rather than each growing a SnackBar.
  void notify(String message, {String? actionLabel, VoidCallback? onAction}) {
    if (_notices.isClosed) return;
    _notices.add(
      JamNotice(message, actionLabel: actionLabel, onAction: onAction),
    );
  }

  /// Why the session ended, once [phase] is [JamSessionPhase.ended].
  JamSessionEndReason? get endReason => _endReason;

  /// Transport connection state. Always [JamConnectionState.connected] on a
  /// host — its own clock and state are the session.
  JamConnectionState get connection => _connection;

  /// Frame-synced playback position for the live session, or null when idle.
  JamPositionTicker? get position => _position;

  /// The `localjam://join?...` URI for the room this device hosts.
  Uri? get joinUri => hostEngine?.joinUri;

  /// Live nearby rooms; empty while not browsing or where mDNS is blocked.
  ValueListenable<List<JamNearbyRoom>> get nearbyRooms => _nearby;

  /// Whether the mDNS browse is actually running (it silently does not start
  /// on platforms without mDNS).
  bool get browsing => _browser?.running ?? false;

  /// Whether a browse is attached right now — true even where the platform
  /// has no mDNS for it to run on, which [browsing] deliberately is not.
  /// This is the "is discovery up?" the UI and the tests mean.
  bool get discovering => _browser != null;

  /// The live browse, or null when none is attached.
  ///
  /// Exposed so the screen that draws a nearby room can also verify one
  /// ([JamRoomBrowser.probe]) and drop it ([JamRoomBrowser.remove]) — an mDNS
  /// record outlives its room by up to two TTLs, and a tap on a ghost should
  /// fail in a tenth of a second with a sentence rather than as a join
  /// timeout.
  JamRoomBrowser? get browser => _browser;

  /// The token of the room this device is in; null when idle. Rooms carrying
  /// it are filtered out of [nearbyRooms].
  String? get excludedToken => _excludedToken;

  // --- Discovery ------------------------------------------------------------

  /// Starts the nearby browse. Best-effort and idempotent; the home screen
  /// drives this so the radio is not running for the whole app's life.
  ///
  /// The request is remembered: a browse stopped by joining or hosting comes
  /// back by itself once the session ends.
  Future<void> startBrowsing({
    /// A browser wired to injected sources, so a test can drive discovery
    /// (and [JamRoomBrowser.probe]) without an mDNS daemon.
    @visibleForTesting JamRoomBrowser? browser,
  }) async {
    _browseWanted = true;
    // Never browse while in a room — nor while getting into one. A start
    // awaits the OS permission prompts, and a screen rebuilding behind that
    // dialog saw `isLive` still false and restarted the browse the start had
    // just stopped, so the host ended up discovering its own room.
    if (isLive || isBusy || _browser != null) return;
    final next = browser ?? JamRoomBrowser();
    _browser = next;
    // Set before the first event can land: a browse that starts while a
    // session is coming up must never publish this device's own room, not
    // even for the frame before the filter is applied.
    next.excludedToken = _excludedToken;
    next.rooms.addListener(_onRoomsChanged);
    await next.start();
    notifyListeners();
  }

  /// Points the browse away from the room this device is in.
  void _setExcludedToken(String? token) {
    final next = (token == null || token.isEmpty) ? null : token;
    if (next == _excludedToken) return;
    _excludedToken = next;
    _browser?.excludedToken = next;
  }

  static String? _tokenOf(Uri? uri) => uri?.queryParameters['token'];

  /// Stops the nearby browse, and stops wanting one.
  Future<void> stopBrowsing() async {
    _browseWanted = false;
    await _stopBrowsing();
    notifyListeners();
  }

  /// Brings discovery back once the controller is idle again — the other half
  /// of the stop that [startHost] and [join] perform.
  Future<void> _resumeBrowsing() async {
    if (!_browseWanted || _phase != JamSessionPhase.idle) return;
    await startBrowsing();
  }

  void _onRoomsChanged() {
    final browser = _browser;
    if (browser != null) _nearby.value = browser.rooms.value;
  }

  Future<void> _stopBrowsing() async {
    final browser = _browser;
    _browser = null;
    if (browser == null) return;
    // Detach first: stop() disposes the notifier we are listening to.
    browser.rooms.removeListener(_onRoomsChanged);
    await browser.stop();
    _nearby.value = const [];
  }

  // --- Session lifecycle ----------------------------------------------------

  /// Hosts a room. Returns true when the session went live; on failure
  /// [error] carries the reason and the phase returns to idle.
  ///
  /// [paths] are added after the room is up, so a host can start instantly
  /// and let the queue fill in — and can keep adding once live.
  Future<bool> startHost({
    required String sessionName,
    // The engine's own default, and the one the setup screen preselects:
    // guests may add music but not seize the transport. `open` here was a
    // second, louder default that nothing in the UI ever asked for.
    JamPolicy policy = JamPolicy.jam,
    bool discoverable = true,
    List<String> paths = const [],
  }) async {
    if (!_claimStart()) return false;
    try {
      // An `ended` session still holding an engine is closed on the way past,
      // so a terminal state never blocks the next one.
      await _teardown();
      await _stopBrowsing();
      // Normally a no-op by now: the screen that got the user here calls
      // [prepareForSession] first, so the prompts land before any spinner.
      // Kept as the backstop for entry points that did not.
      await _requestSessionPermissions();
      final engine = await JamHostEngine.start(
        sessionName: sessionName,
        policy: policy,
        discoverable: discoverable,
      );
      _attach(engine, JamSide.host);
      await addFiles(paths.map(File.new));
      // Cue the first track. Without this the room reports "Nothing queued"
      // while holding a full playlist, because nothing has been selected —
      // the host has a queue but no current media.
      if (engine.snapshot.mediaId == null && engine.playlist.isNotEmpty) {
        engine.setMedia(engine.playlist.first.mediaId);
      }
      // ...and then start it. "Start the jam" (and "Host it again", which
      // arrives down this same path with the old queue in `paths`) landed in
      // a room paused at 00:00, so the promise of one tap to sound cost two
      // taps and a hunt for the play button. Only the host does this: a
      // guest's transport follows the host's authoritative state, and the
      // room is silent until it says otherwise.
      if (engine.playlist.isNotEmpty &&
          engine.snapshot.status != PlaybackStatus.playing) {
        engine.play();
      }
      return true;
    } catch (e) {
      _error = _describe(e);
      _phase = JamSessionPhase.idle;
      unawaited(_resumeBrowsing());
      notifyListeners();
      return false;
    }
  }

  /// Joins the room in [joinUri]. Returns true when the session went live;
  /// on failure [error] carries the reason and the phase returns to idle.
  ///
  /// [roomName] is what the tapped row (or the link) called the room, used
  /// only for the `Joining <name>…` state — the authoritative name arrives in
  /// the welcome frame.
  Future<bool> join(
    Uri joinUri, {
    String? clientName,
    String? roomName,
    @visibleForTesting Directory? mediaCacheDir,
  }) async {
    if (!_claimStart()) return false;
    _joiningUri = joinUri;
    _joiningName = roomName ?? joinUri.queryParameters['name'];
    notifyListeners();
    try {
      // §9, and the reason this lives here rather than at each door: a
      // `localjam://` URI is a bare instruction to open a socket, and it
      // reaches this method from a QR scan, a pasted link, a deep link and a
      // nearby-room tap. Checked per entry point, the check is one new
      // caller away from being missed; checked here, every join has passed
      // it. `.local` names — what mDNS and Apple platforms deal in — are
      // resolved and the answer re-checked, so this is awaited, not cheap.
      if (!await joinUriIsLocalOnlyResolved(joinUri)) {
        throw const JamOffNetworkException();
      }
      await _teardown();
      await _stopBrowsing();
      // See [startHost]: the backstop, not the usual path.
      await _requestSessionPermissions();
      final engine = await JamGuestEngine.join(
        joinUri,
        clientName: clientName,
        mediaCacheDir: mediaCacheDir,
      );
      _lastJoinUri = joinUri;
      _attach(engine, JamSide.guest);
      return true;
    } catch (e) {
      _error = _describe(e);
      _phase = JamSessionPhase.idle;
      unawaited(_resumeBrowsing());
      notifyListeners();
      return false;
    } finally {
      if (_joiningUri != null) {
        _joiningUri = null;
        _joiningName = null;
        notifyListeners();
      }
    }
  }

  /// Rejoins the room this device last joined — the "try again" out of a
  /// terminal end. The engine's retained `joinUri` is mirrored here so it
  /// survives the engine being torn down.
  ///
  /// Returns false when there is nothing to rejoin.
  Future<bool> rejoin({
    String? clientName,
    @visibleForTesting Directory? mediaCacheDir,
  }) async {
    final uri = _lastJoinUri;
    if (uri == null) return false;
    return join(
      uri,
      clientName: clientName,
      roomName: _lastJoinName,
      mediaCacheDir: mediaCacheDir,
    );
  }

  String? get _lastJoinName => _lastJoinUri?.queryParameters['name'];

  /// Claims the `starting` phase for a new session, or refuses.
  ///
  /// Synchronous on purpose: it is what makes "one start at a time" true for
  /// two taps in the same frame, and it lets the UI see the in-flight state
  /// the moment the call is made rather than a turn of the event loop later.
  ///
  /// A terminal `ended` phase is claimable — that is the soft-lock fix. An
  /// end that landed while the user was anywhere but the room used to leave
  /// the app permanently unable to host or join, because the phase never
  /// returned to idle and every entry point early-returned false forever.
  /// Whether a start could be claimed right now — the guard
  /// [prepareForSession] reads before spending the user's attention on a
  /// permission prompt for a session that cannot begin.
  bool get canStart =>
      _phase != JamSessionPhase.starting && _phase != JamSessionPhase.live;

  bool _claimStart() {
    if (!canStart) return false;
    _error = null;
    _phase = JamSessionPhase.starting;
    notifyListeners();
    return true;
  }

  /// Asks for what a session needs *before* the screen commits to starting
  /// one.
  ///
  /// The OS prompts (and the rationale sheets in front of them) used to fire
  /// from inside [startHost], which is to say from behind the "Start the jam"
  /// spinner: the button sat there spinning while a system dialog waited for
  /// an answer. Called from the screen that offers the way in — home, before
  /// it opens host setup or a join — the same asks land on a calm screen and
  /// the spinner, when it comes, means only what it says.
  ///
  /// Safe to call any number of times: everything under it is idempotent.
  Future<void> prepareForSession() async {
    if (!canStart) return;
    await _requestSessionPermissions();
  }

  /// The OS permissions a session needs, asked for once, right before the
  /// sockets and the audio card come up. Both are non-fatal — the local
  /// network one because the socket layer reports the real failure, the
  /// notification one because it only costs the lock-screen card.
  Future<void> _requestSessionPermissions() async {
    await ensureLocalNetworkPermission();
    await ensureNotificationPermission();
  }

  /// Adds [files] to the live room, collecting what failed instead of
  /// swallowing it. Returns the failures; [addFailures] holds the same list
  /// until the next attempt.
  ///
  /// One unreadable or unsupported file must not sink the session — but it
  /// must not vanish either, which is what the old silent `catch` did on the
  /// host-setup path.
  Future<List<JamAddFailure>> addFiles(Iterable<File> files) async {
    final engine = _engine;
    final failures = <JamAddFailure>[];
    if (engine == null) return failures;
    var attempted = 0;
    var duplicates = 0;
    for (final file in files) {
      attempted++;
      try {
        final result = await jamAddFile(engine, file);
        if (result != null && result.alreadyQueued) duplicates++;
      } catch (e) {
        debugPrint('localjam: could not add ${file.path}: $e');
        failures.add(JamAddFailure(_basename(file.path), '$e'));
      }
    }
    _addFailures = List.unmodifiable(failures);
    // §2.8: a track landing in the queue is the small confirmation that the
    // pick worked. Only when at least one actually landed.
    if (failures.length < attempted) JamHaptics.queued();
    if (failures.isNotEmpty) {
      notify(describeAddFailures(failures));
    } else if (duplicates > 0 && duplicates == attempted) {
      // Nothing failed and nothing changed: the room already had these exact
      // bytes (§6.4). Without this the queue simply does not move and the
      // pick reads as a button that did nothing.
      notify(kJamAlreadyQueued);
    }
    return _addFailures;
  }

  // --- Queue undo ------------------------------------------------------------

  /// Source paths for items this device has seen in the queue, kept past the
  /// removal that forgets them.
  ///
  /// [JamEngine.localPathFor] takes a [MediaItem], and an undo is by
  /// definition asked for once the item is out of the playlist — there is no
  /// item left to ask about. So the mapping is remembered here, from the
  /// playlist broadcasts, while the item still exists.
  final Map<String, String> _sourcePaths = {};

  void _rememberPaths(List<MediaItem> playlist) {
    final engine = _engine;
    if (engine == null) return;
    for (final item in playlist) {
      final path = engine.localPathFor(item);
      if (path != null) _sourcePaths[item.mediaId] = path;
    }
  }

  /// Whether [mediaId] can be put back where it was.
  ///
  /// Host only. The host engine has no re-insert API — nothing does — so an
  /// undo is a re-add of the same file, which works because media ids are
  /// content hashes (§6.1): the same bytes come back as the same id, in the
  /// same place in every other device's queue. That needs the file, which
  /// means it needs the path the host registered it from and that file still
  /// being there.
  ///
  /// A guest would have to re-upload from its prefetch cache and then ask
  /// the host to move it — two round trips, either of which the host may
  /// refuse on capability grounds, ending in a queue that is neither the old
  /// one nor the new one. Undo has to be certain to be worth offering, so on
  /// a guest this answers false and the UI offers no undo at all.
  bool canReinsert(String mediaId) {
    if (!isLive || !isHost) return false;
    final path = _sourcePaths[mediaId];
    if (path == null) return false;
    return File(path).existsSync();
  }

  /// Puts [mediaId] back into the queue at [index] — the Undo behind a
  /// removal. Returns false when it could not be done, leaving the queue
  /// exactly as it was.
  ///
  /// Already in the playlist is a success: an undo that races the removal it
  /// undoes should be a no-op, not an error.
  Future<bool> reinsertItem(String mediaId, int index) async {
    final host = hostEngine;
    if (host == null || !isLive) return false;
    if (host.playlist.any((i) => i.mediaId == mediaId)) {
      _moveWithin(host, mediaId, index);
      return true;
    }
    if (!canReinsert(mediaId)) return false;
    try {
      final item = await host.addMediaFile(File(_sourcePaths[mediaId]!));
      // Content addressing is what makes this an undo rather than a second
      // copy. If the bytes ever came back under a different id, putting them
      // at the old index would be a lie about what was restored.
      if (item.mediaId != mediaId) return false;
      _moveWithin(host, mediaId, index);
      return true;
    } catch (e) {
      debugPrint('localjam: could not restore $mediaId: $e');
      return false;
    }
  }

  static void _moveWithin(JamHostEngine host, String mediaId, int index) {
    final target = index.clamp(0, host.playlist.length - 1);
    host.moveMediaItem(mediaId, target);
  }

  /// Ends the session on purpose — the only way out. A host closing the room
  /// ends it for everyone (PROTOCOL.md §10: host death ends the room).
  Future<void> leave() async {
    // A host who ends the jam is dropped straight back on home, and the
    // terminal "this jam ended" screen is for guests — it explains something
    // that happened *to* them. So the host gets the one thing that screen
    // would have told them that they do not already know: how big it was.
    final farewell = _endSummary();
    await _teardown();
    _phase = JamSessionPhase.idle;
    _endReason = null;
    _joiningUri = null;
    _joiningName = null;
    // Back to idle is back to looking around: the browse the session stopped
    // comes up again here, on every way out — leave, end, kick, acknowledge.
    // Never awaited: mDNS start-up is best-effort and can sit there for as
    // long as the platform likes, and leaving must not wait on the radio.
    unawaited(_resumeBrowsing());
    notifyListeners();
    if (farewell != null) notify(farewell);
  }

  /// "Jam ended · 12 tracks, 3 people", or null when this is not a host
  /// closing a live room (a guest leaving needs no receipt, and an already
  /// terminal session has had its say on the ended screen).
  String? _endSummary() {
    final engine = _engine;
    if (engine == null || !isHost || _phase != JamSessionPhase.live) {
      return null;
    }
    final tracks = engine.playlist.length;
    // The host is in the room too, and never appears in `peers`.
    final people = engine.peers.length + 1;
    return '$kJamEnded · ${_plural(tracks, 'track')}, '
        '${_plural(people, 'person', 'people')}';
  }

  static String _plural(int count, String one, [String? many]) =>
      '$count ${count == 1 ? one : (many ?? '${one}s')}';

  /// Closes whatever engine is attached, leaving [phase] to the caller.
  Future<void> _teardown() async {
    final engine = _engine;
    if (engine == null) return;
    await _detach();
    try {
      await engine.close();
    } catch (_) {
      // Already torn down.
    }
    _endReason = null;
  }

  /// Dismisses a terminal session-ended state back to idle.
  Future<void> acknowledgeEnd() async {
    if (_phase != JamSessionPhase.ended) return;
    await leave();
  }

  // --- Wiring ---------------------------------------------------------------

  void _attach(JamEngine engine, JamSide side) {
    _engine = engine;
    _side = side;
    _phase = JamSessionPhase.live;
    _connection = JamConnectionState.connected;
    _endReason = null;
    _position = JamPositionTicker(engine);
    _lastMediaId = engine.snapshot.mediaId;
    // The room we are in is the one room we can never join. A host reads its
    // own advertisement, and a guest reads the host's.
    _setExcludedToken(_tokenOf(hostEngine?.joinUri ?? _lastJoinUri));
    // §2.8: the jam started, or you got in. One buzz, on both sides — the
    // room's own celebration overlay does not fire on desktop or under
    // reduced motion, and this moment should be felt regardless.
    JamHaptics.jamStarted();
    _watchKeepAlive();
    // Both sides watch the same broadcast state, so the wrap is announced
    // once on the host and once on every guest without either needing a
    // side-specific signal.
    _subs.add(engine.states.listen(_onSnapshot));
    // Remember where each item's bytes came from while the item is still
    // around to ask — see [_sourcePaths].
    _rememberPaths(engine.playlist);
    _subs.add(engine.playlistUpdates.listen(_rememberPaths));

    final guest = guestEngine;
    if (guest != null) {
      _subs
        ..add(guest.peerEvents.listen(_onGuestPeerEvent))
        ..add(guest.connectionStates.listen(_onConnection))
        // §8 host error reports. Nothing subscribed to these before, so a
        // denied request or a vanished file was simply a button that did
        // nothing.
        ..add(guest.errors.listen(_onGuestError));
      guest.sessionEnded.addListener(_onSessionEnded);
    }
    final host = hostEngine;
    if (host != null) {
      _subs
        ..add(host.events.listen(_onHostEvent))
        ..add(host.mediaUploads.listen(_onUpload));
    }
    notifyListeners();
  }

  Future<void> _detach() async {
    // Out of the room is back to being able to join it.
    _setExcludedToken(null);
    JamKeepAlive.active.removeListener(_onKeepAlive);
    _keepAliveHeld = true;
    _lastPeerBuzz = null;
    final guest = guestEngine;
    if (guest != null) {
      guest.sessionEnded.removeListener(_onSessionEnded);
    }
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    _subs.clear();
    _peerNames.clear();
    _sourcePaths.clear();
    tints.clear();
    _lastMediaId = null;
    _position?.dispose();
    _position = null;
    _engine = null;
    _side = null;
    _connection = JamConnectionState.connected;
  }

  /// Watches the platform keep-alive for the life of the session.
  ///
  /// [JamEngine.keepAliveActive] is a snapshot; the notifier behind it is
  /// what says when the foreground service actually goes. On Android that is
  /// the difference between a jam that survives a locked screen and one that
  /// stops the moment the phone goes in a pocket, so it is worth a sentence.
  void _watchKeepAlive() {
    if (!_keepAliveMatters) return;
    _keepAliveHeld = JamKeepAlive.active.value;
    JamKeepAlive.active.addListener(_onKeepAlive);
    // A keep-alive that was refused outright never "flips" — check once.
    _onKeepAlive();
  }

  void _onKeepAlive() {
    final held = JamKeepAlive.active.value;
    if (held == _keepAliveHeld) return;
    _keepAliveHeld = held;
    if (!held) notify(kJamKeepAliveLost);
  }

  /// Only Android has a keep-alive to lose. Everywhere else the notifier
  /// stays false for the whole session and the warning would be a lie.
  bool get _keepAliveMatters =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Presence, from a guest's side. Same buzz the host gets — the room
  /// gaining a person is the same event whichever end you are on.
  ///
  /// Throttled, because the reconnect layer replays a resumed connection's
  /// whole roster as `joined` deltas: a five-person room coming back would
  /// otherwise buzz five times in one frame.
  void _onGuestPeerEvent(JamPeerEvent event) {
    if (event.kind != JamPeerEventKind.joined) return;
    final now = DateTime.now();
    final last = _lastPeerBuzz;
    if (last != null && now.difference(last) < _peerBuzzGap) return;
    _lastPeerBuzz = now;
    JamHaptics.peerJoined();
  }

  /// A host-reported protocol error (§8). Fatal codes are left alone: the
  /// terminal screen driven by [sessionEnded] already says what happened, and
  /// a SnackBar over it would only compete.
  void _onGuestError(ErrorMessage error) {
    debugPrint('localjam: host error ${error.code.wire} — ${error.message}');
    final copy = switch (error.code) {
      ErrorCode.notAllowed => 'The host has not given you that yet.',
      ErrorCode.mediaGone => 'That track is no longer in the room.',
      ErrorCode.internal => 'The host hit a problem with that.',
      ErrorCode.sessionFull => 'The room is full.',
      ErrorCode.versionUnsupported =>
        'This app and the host disagree on '
            'versions. One of you needs an update.',
      // kicked and badToken are fatal; sessionEnded owns the message.
      ErrorCode.kicked || ErrorCode.badToken => null,
    };
    if (copy != null) notify(copy);
  }

  /// Presence, from the host's side. A host is usually looking at the queue
  /// or their phone's lock screen, not at the roster, so arrivals and
  /// departures come to them.
  void _onHostEvent(JamHostEvent event) {
    switch (event.kind) {
      case JamHostEventKind.peerJoined:
        final peer = event.peer;
        if (peer == null) return;
        final name = peer.clientName.isEmpty ? 'Someone' : peer.clientName;
        _peerNames[peer.peerId] = name;
        JamHaptics.peerJoined();
        notify('$name joined');
      case JamHostEventKind.peerLeft:
        final name = _peerNames.remove(event.peerId) ?? 'Someone';
        notify('$name left');
      case _:
        return;
    }
  }

  void _onUpload(({String mediaId, String? peerId}) upload) {
    final who = _peerNames[upload.peerId] ?? 'Someone';
    final item = _engine?.playlist
        .where((i) => i.mediaId == upload.mediaId)
        .firstOrNull;
    notify(
      item == null
          ? '$who added a track'
          : '$who added ${jamDisplayTitle(item)}',
    );
  }

  /// The queue reaching its end and starting over is the one playback event
  /// that looks like a bug: the last track finishes and the first one comes
  /// back, with nothing saying the loop was deliberate. One line, once.
  void _onSnapshot(PlaybackSnapshot snapshot) {
    final previous = _lastMediaId;
    final current = snapshot.mediaId;
    if (current == previous) return;
    _lastMediaId = current;
    if (previous == null || current == null) return;
    final playlist = _engine?.playlist ?? const <MediaItem>[];
    if (playlist.length < 2) return;
    if (previous == playlist.last.mediaId &&
        current == playlist.first.mediaId) {
      notify('Starting the queue over');
    }
  }

  void _onConnection(JamConnectionState state) {
    if (_connection == state) return;
    _connection = state;
    notifyListeners();
  }

  void _onSessionEnded() {
    final reason = guestEngine?.sessionEnded.value;
    // closedLocally is our own leave() unwinding; it is not a state to show.
    if (reason == null || reason == JamSessionEndReason.closedLocally) return;
    _endReason = reason;
    _phase = JamSessionPhase.ended;
    notifyListeners();
  }

  /// What to put in front of the user when a start or join fails.
  ///
  /// Never `error.toString()`: that leaked `RejectReason.version` and raw
  /// exception text into the UI. Anything unrecognised is generic on screen
  /// and detailed in the log.
  static String _describe(Object error) => switch (error) {
    JamRejectedException(:final reason) => switch (reason) {
      RejectReason.version =>
        'This app and the host are on different versions of LocalJam. '
            'One of you needs an update.',
      RejectReason.full => 'That room is full right now.',
      RejectReason.badToken =>
        'That code no longer works — the room was restarted. Ask for a '
            'fresh one.',
    },
    JamOffNetworkException() =>
      'That link points outside your network. A jam only runs between '
          'devices on it.',
    SocketException() =>
      'Could not reach that room. Check you are both on '
          'the same network or hotspot.',
    FormatException() => 'That link is not a jam invite.',
    _ => _generic(error),
  };

  static String _generic(Object error) {
    debugPrint('localjam: session failure: $error');
    return 'Something went wrong. Try again.';
  }

  /// The stored identity was adopted over the ephemeral one; whoever is
  /// showing a name should read it again.
  void _onIdentityChanged() => notifyListeners();

  @override
  void dispose() {
    JamIdentity.changes.removeListener(_onIdentityChanged);
    unawaited(_detach());
    unawaited(_stopBrowsing());
    unawaited(_notices.close());
    _nearby.dispose();
    super.dispose();
  }
}

String _basename(String path) => path.split(Platform.pathSeparator).last;

/// One line for however many files failed to be added, naming the first few.
///
/// Shared with the queue sheet's picker so both paths report the same way.
String describeAddFailures(List<JamAddFailure> failures) {
  if (failures.isEmpty) return '';
  final names = failures.take(3).map((f) => f.name).join(', ');
  final rest = failures.length - 3;
  final tail = rest > 0 ? '$names and $rest more' : names;
  return failures.length == 1
      ? 'Could not add $tail'
      : "${failures.length} files couldn't be added: $tail";
}

/// Provides the [JamSessionController] to the widget tree.
///
/// An [InheritedNotifier] so `JamSession.of(context)` both reads the
/// controller and subscribes the caller to lifecycle changes.
class JamSession extends InheritedNotifier<JamSessionController> {
  const JamSession({
    super.key,
    required JamSessionController controller,
    required super.child,
  }) : super(notifier: controller);

  /// The controller, subscribing this context to lifecycle changes.
  static JamSessionController of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<JamSession>();
    assert(scope != null, 'No JamSession above this context.');
    return scope!.notifier!;
  }

  /// The controller without subscribing — for event handlers.
  static JamSessionController read(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<JamSession>();
    assert(scope != null, 'No JamSession above this context.');
    return scope!.notifier!;
  }
}
