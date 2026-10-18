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

/// What kind of thing a [JamNotice] says, so the shell can pick its glyph
/// instead of guessing from whether it carries an action.
enum JamNoticeTone {
  /// The room narrating itself, or a neutral confirmation — including one
  /// that carries an Undo. No glyph.
  neutral,

  /// Something the user did, done ("Link copied"): a checkmark.
  done,

  /// Someone arrived, left or was removed: a person glyph.
  people,

  /// Something needs attention but nothing broke (a file skipped, a
  /// permission declined).
  warning,

  /// Something failed.
  error,
}

/// A transient, one-shot message for the app shell to surface.
///
/// Emitted rather than stored: these are things that *happened* ("Ana
/// joined", "the host said no"), not state, and every screen showing them
/// itself was how the protocol's error stream ended up with no subscriber at
/// all. One channel, one place that renders it (the router shell).
@immutable
class JamNotice {
  const JamNotice(this.message, {this.actionLabel, this.onAction, this.tone});

  final String message;

  /// Optional action, e.g. "Open Settings" on a permanent permission denial,
  /// or "Undo".
  final String? actionLabel;
  final VoidCallback? onAction;

  /// What kind of notice this is, when the sender said. Null for senders
  /// that predate it; the shell then falls back to its own guess.
  final JamNoticeTone? tone;

  @override
  String toString() => 'JamNotice($message)';
}

/// What the app says when Android takes the foreground service away.
const String kJamKeepAliveLost = 'Background playback may pause';

/// What a jam that ended is called. The host gets no toast for it any more:
/// the new row at the top of Recent says it (§10.5).
const String kJamEnded = 'Jam ended';

/// What a pick that added nothing says, because the room already had exactly
/// those bytes.
const String kJamAlreadyQueued = 'Already in the queue';

/// What the app says when a nearby room turns out to have gone.
const String kJamRoomGone = 'That jam has ended';

/// What a guest is told when the host said it is going to sleep (§3.5) — the
/// one reason a request cannot go anywhere that is nobody's fault.
const String kJamHostAsleep = 'The host’s phone is asleep';

/// A tap that could not reach a sleeping host.
const String kJamHostAsleepTryLater =
    'The host’s phone is asleep. Try again when it wakes.';

/// A tap that could not reach the host because the link is down.
const String kJamNotConnected =
    'Not connected to the host right now. Try again in a moment.';

/// A tap the room refused for any other reason — an id that left the queue
/// meanwhile, a room that ended under the finger.
const String kJamIntentFailed = 'That didn’t go through. Try again.';

/// A failed rejoin that the controller turned back into the ended screen.
const String kJamRejoinFailed = 'Couldn’t get back into that jam.';

/// What a host is told when a guest it removed is gone: its own action, not
/// "Okon left".
String jamRemovedNotice(String name) => 'Removed $name';

/// This app and the host cannot talk: a different major protocol version
/// (§2) — refused at the door, or reported by the host later.
const String kJamVersionMismatch =
    'This app and the host are on different versions of LocalJam. '
    'One of you needs an update.';

/// Whether asking the same room again could ever let this device back in
/// after the host turned it away with [reason] (§3.1) — what decides whether
/// an ended room offers "Try again".
///
/// A restarted room ([RejectReason.badToken]: the link's token is gone for
/// good) and a version mismatch never let the same link in again, and a
/// kick is the host's to undo (§5.6), not a retry's. A full room may have
/// space once someone leaves; a reason from a newer host
/// ([RejectReason.unknown]), or none at all, is not known to be hopeless —
/// and a retry that fails says why.
bool jamRejectIsRetryable(RejectReason? reason) => switch (reason) {
  RejectReason.badToken || RejectReason.version || RejectReason.kicked => false,
  RejectReason.full || RejectReason.unknown || null => true,
};

/// What [JamSessionController.restartArgs] carries: enough to open host
/// setup on the room that just died, queue and all.
typedef JamRestartArgs = ({String name, List<String> paths});

/// What "Start a new jam" re-hosts after a room died: the [queue] as it
/// stood (its order, its additions), then whatever of the original pick
/// ([picked]) never made it into the queue — the import had not reached it,
/// or it would not add — so nothing the host chose is silently dropped.
/// Files that were queued once and removed ([everQueued] but not in
/// [queue]) stay removed: that was the room's decision.
List<String> jamRestartPaths({
  required List<String> queue,
  required List<String> picked,
  required Iterable<String> everQueued,
}) {
  final seen = {...queue, ...everQueued};
  return [
    ...queue,
    for (final path in picked)
      if (seen.add(path)) path,
  ];
}

/// One file that could not be added to the queue.
@immutable
class JamAddFailure {
  const JamAddFailure(this.name, this.reason, {this.why});

  /// [error] from an add, as a failure for the file at [path].
  factory JamAddFailure.of(String path, Object error) =>
      JamAddFailure(_basename(path), '$error', why: jamAddFailureWhy(error));

  /// The file's display name — what the user actually recognises.
  final String name;

  /// Loggable detail. Never shown raw; see [JamSessionController.addFiles].
  final String reason;

  /// Why, in a sentence a person can act on — or null when there is nothing
  /// more useful to say than "could not add".
  final String? why;
}

/// What an upload the host refused means for the person who picked the file
/// (§6.4), by HTTP status ([JamHttpStatusException]).
///
/// Everything else — a stall, a body the host cut off (anything over its
/// 64 MB read limit arrives as a reset, not a 413), a socket error — is "could
/// not add that track", and nothing more: none of them means the host is
/// gone, and saying so would send people to rejoin a room that is fine.
String? jamAddFailureWhy(Object error) => switch (error) {
  JamHttpStatusException(statusCode: 507) =>
    'The jam\u2019s upload space is full.',
  JamHttpStatusException(statusCode: 429) =>
    'Wait for your other uploads to finish, then try again.',
  JamHttpStatusException(statusCode: 403) =>
    'This jam is listen-only, or the host hasn\u2019t let you add songs.',
  JamHttpStatusException(statusCode: 413) => 'It\u2019s too big for the jam.',
  JamHttpStatusException(statusCode: 401) =>
    'The invite is no longer valid. Ask the host for a fresh code.',
  _ => null,
};

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

/// The app's single live-jam owner.
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

  /// The host's reason when [_endReason] is a refusal — kept apart from the
  /// engine, which a rejoin tears down, so the screen can keep saying it.
  RejectReason? _endRejectReason;
  JamConnectionState _connection = JamConnectionState.connected;
  JamPositionTicker? _position;
  final List<StreamSubscription<Object?>> _subs = [];
  final StreamController<JamNotice> _notices =
      StreamController<JamNotice>.broadcast();
  Uri? _joiningUri;
  String? _joiningName;
  Uri? _lastJoinUri;
  List<JamAddFailure> _addFailures = const [];

  /// The last start/join failure itself, so a failed rejoin can tell a kick
  /// (never retry) from a room that simply was not there.
  Object? _lastFailure;

  /// Set for the whole of a [rejoin] that started from the terminal screen:
  /// the end it is trying to undo. While it is set the room stays mounted —
  /// [hasRoom] holds — so "Try again" spins in place instead of the router
  /// bouncing the user to home the moment the phase leaves `ended`.
  JamSessionEndReason? _rejoinReason;

  /// The host's background import of the files it started with.
  JamImport? _import;

  /// The room a host lost to [JamSessionEndReason.listenerFailed], for
  /// "Start a new jam".
  JamRestartArgs? _restartArgs;

  /// Every file the hosted room was started with, in the order picked — so
  /// "Start a new jam" can bring back what the import had not reached yet,
  /// not only what made it into the queue.
  List<String> _hostPick = const [];

  /// Guest display names by peerId, so a `peerLeft` event (which carries only
  /// an id) can still say who left.
  final Map<String, String> _peerNames = {};

  /// Guests this host removed ([removePeer]) whose departure has not been
  /// heard yet — so the host is told "Removed Okon", not "Okon left".
  final Set<String> _removing = {};

  /// Every room this device has hosted since the app started.
  ///
  /// Never cleared: a host's own advertisement can outlive its room (a
  /// daemon that confirmed a registration late, a record still cached two
  /// TTLs on), and the one jam a device must never offer itself is its own —
  /// least of all with "Join" under a room it just ended.
  final Set<String> _ownRoomTokens = {};

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

  /// Now Playing backdrops (D4), shared across the app.
  ///
  /// The room screen and the docked room bar are looking at the same cover,
  /// and deriving a tint decodes and quantises an image — one cache above
  /// both means one derivation per track for the life of the jam. Cleared
  /// when the session goes.
  final JamBackdropCache backdrops = JamBackdropCache();

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
  ///
  /// A "Try again" in flight counts: the rejoin passes through `starting`,
  /// and a room that vanished for that moment was unmounted by the router's
  /// redirect — the button bounced the user to home instead of spinning.
  bool get hasRoom =>
      isLive || _phase == JamSessionPhase.ended || _rejoinReason != null;

  /// Whether a "Try again" from the terminal screen is in flight.
  bool get rejoining => _rejoinReason != null;

  /// Whether the host said it is going to sleep (§3.5). Always false on a
  /// host. Notifies when it changes.
  bool get hostAway => guestEngine?.hostAway.value ?? false;

  /// Whether a transport or queue intent can reach the room right now: a
  /// host always can while live; a guest needs a live connection to a host
  /// that is awake ([JamGuestEngine.canSendCommands]). Controls that send
  /// should be disabled — with a reason — while this is false.
  bool get canSendCommands => isLive && (guestEngine?.canSendCommands ?? true);

  /// The host's background import of the files the room started with, or
  /// null. Its [JamImport.progress] is live; the room is already open.
  JamImport? get hostImport => _import;

  /// Enough to reopen host setup on a room the OS took away
  /// ([JamSessionEndReason.listenerFailed]); null otherwise.
  JamRestartArgs? get restartArgs => _restartArgs;

  /// What host setup opens with — "Host it again", "Start a new jam" — or
  /// null for a blank one. Held here rather than only in the route's
  /// `extra`, which is in-memory route state the router does not promise to
  /// keep: a rebuild that lost it opened setup empty, the old queue gone.
  /// Whoever pushes host setup sets it (null for a fresh start) first; a
  /// start consumes it.
  JamRestartArgs? hostSetupDraft;

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
  void notify(
    String message, {
    String? actionLabel,
    VoidCallback? onAction,
    JamNoticeTone? tone,
  }) {
    if (_notices.isClosed) return;
    _notices.add(
      JamNotice(
        message,
        actionLabel: actionLabel,
        onAction: onAction,
        tone: tone,
      ),
    );
  }

  /// Why the session ended, once [phase] is [JamSessionPhase.ended] — and,
  /// while a "Try again" runs, the end it is trying to undo.
  JamSessionEndReason? get endReason => _endReason ?? _rejoinReason;

  /// When [endReason] is [JamSessionEndReason.rejected], what the host said
  /// (§3.1; [JamGuestEngine.lastRejectReason]) — a restarted room, a full
  /// one, a version mismatch. It decides the copy, and whether "Try again"
  /// is worth offering at all ([jamRejectIsRetryable]). Null for every
  /// other end, and when the host gave no reason this app knows.
  RejectReason? get endRejectReason =>
      endReason == JamSessionEndReason.rejected ? _endRejectReason : null;

  /// Runs one user-initiated transport or queue intent, and says so when it
  /// did not land.
  ///
  /// The engine intents answer `false` instead of throwing — a guest whose
  /// host is asleep, a link mid-reconnect, an id that left the queue — and a
  /// button whose tap went nowhere with nothing said is the one failure mode
  /// a person cannot tell from a broken app. Every control that acts on the
  /// room goes through here so none of them can be silent.
  Future<bool> act(Future<bool> Function(JamEngine engine) intent) async {
    final engine = _engine;
    if (engine == null || !isLive) return false;
    bool ok;
    try {
      ok = await intent(engine);
    } catch (e) {
      // The intents are documented never to throw; one that does is a bug
      // worth a log line, not a stack trace on screen.
      debugPrint('localjam: intent failed: $e');
      ok = false;
    }
    // A room that ended under the finger has its own screen saying so.
    if (!ok && identical(engine, _engine) && isLive) {
      notify(_whyNot(), tone: JamNoticeTone.warning);
    }
    return ok;
  }

  /// Why an intent did not land, in the room's own words.
  String _whyNot() {
    final guest = guestEngine;
    if (guest != null && guest.hostAway.value) return kJamHostAsleepTryLater;
    if (guest != null && !guest.canSendCommands) return kJamNotConnected;
    return kJamIntentFailed;
  }

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
    if (browser == null) return;
    final rooms = browser.rooms.value;
    _nearby.value = _ownRoomTokens.isEmpty
        ? rooms
        : List.unmodifiable([
            for (final room in rooms)
              if (!_ownRoomTokens.contains(room.token)) room,
          ]);
  }

  /// Whether [room] is one this device hosted since the app started — never
  /// listed under Nearby.
  bool isOwnRoom(JamNearbyRoom room) => _ownRoomTokens.contains(room.token);

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
  /// [paths] are imported in the background once the room is up
  /// ([JamHostEngine.importFiles]): the room opens at once and the first
  /// track to land starts playing, rather than "Start the jam" spinning
  /// through a probe, a tag read and a full sha256 of every file first.
  /// Progress is on [hostImport]; files that would not add are reported as
  /// one notice when the import finishes.
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
    // A new room of this device's own: the old one's way back (a guest's
    // rejoin link, a dead room's restart) is not this one's, and a draft
    // for host setup has been used.
    _restartArgs = null;
    _lastJoinUri = null;
    hostSetupDraft = null;
    _hostPick = List.unmodifiable(paths);
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
      // Cued and started by the import itself (cueFirst + autoPlay): "Start
      // the jam" — and "Host it again", which arrives down this same path
      // with the old queue in `paths` — used to land in a room paused at
      // 00:00 holding a full playlist. Only the host does this: a guest's
      // transport follows the host's authoritative state.
      if (paths.isNotEmpty) _startImport(engine, paths);
      return true;
    } catch (e) {
      _lastFailure = e;
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

    /// The engine's own default; a test sets 0 to reach "gave up" at once.
    @visibleForTesting int maxFetchRetries = 5,
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
      _restartArgs = null; // Not a host's room to restart any more.
      // See [startHost]: the backstop, not the usual path.
      await _requestSessionPermissions();
      final engine = await JamGuestEngine.join(
        joinUri,
        clientName: clientName,
        mediaCacheDir: mediaCacheDir,
        maxFetchRetries: maxFetchRetries,
      );
      _lastJoinUri = joinUri;
      _attach(engine, JamSide.guest);
      return true;
    } catch (e) {
      _lastFailure = e;
      _error = _describe(e);
      // A join from an `ended` screen refused before the teardown above (the
      // §9 check) must not leave the dead engine attached to an idle phase:
      // it would hold the old room's token out of discovery and answer for
      // a session nothing shows. A "Try again" is the exception — it lands
      // back on that ended screen, which still reads the engine.
      if (_rejoinReason == null) await _teardown();
      _phase = JamSessionPhase.idle;
      // Likewise only when idle is where this ends: a failed "Try again"
      // goes back to the ended screen, not to browsing behind it.
      if (_rejoinReason == null) unawaited(_resumeBrowsing());
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
  /// Returns false when there is nothing to rejoin, or the rejoin failed.
  ///
  /// From the terminal screen the room stays on screen throughout ([hasRoom],
  /// [rejoining]) and a failure lands back on it — same end, [error] saying
  /// why — rather than in idle, which the router answered by unmounting the
  /// room and dropping the user on home with a snackbar.
  Future<bool> rejoin({
    String? clientName,
    @visibleForTesting Directory? mediaCacheDir,
  }) async {
    final uri = _lastJoinUri;
    if (uri == null || !canStart) return false;
    final from = _phase == JamSessionPhase.ended ? _endReason : null;
    _rejoinReason = from;
    try {
      final joined = await join(
        uri,
        clientName: clientName,
        roomName: _lastJoinName,
        mediaCacheDir: mediaCacheDir,
      );
      if (!joined && from != null && _phase == JamSessionPhase.idle) {
        _phase = JamSessionPhase.ended;
        final failure = _lastFailure;
        if (failure is JamRejectedException) {
          // The host answered, and said no (§3.1): that is the end now,
          // whatever it was before. A device kicked meanwhile is out until
          // it is let back in (§5.6); any other reason is a refusal, and
          // its own copy says which — so the error line only has to say the
          // retry did not work, and the screen stops offering one that
          // never can ([jamRejectIsRetryable]).
          _endReason = failure.reason == RejectReason.kicked
              ? JamSessionEndReason.kicked
              : JamSessionEndReason.rejected;
          _endRejectReason = failure.reason;
          _error = kJamRejoinFailed;
        } else {
          _endReason = from;
          _error ??= kJamRejoinFailed;
        }
      }
      return joined;
    } finally {
      _rejoinReason = null;
      notifyListeners();
    }
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
    _lastFailure = null;
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
    // A guest that cannot reach the host would fail every file the same way
    // and report "Could not add a, b, c" — true, and no help at all. Say
    // why once instead, before reading a byte.
    if (!canSendCommands) {
      notify(_whyNot(), tone: JamNoticeTone.warning);
      return failures;
    }
    var attempted = 0;
    var duplicates = 0;
    for (final file in files) {
      attempted++;
      try {
        final result = await engine.addMedia(file);
        if (result.alreadyQueued) duplicates++;
      } on JamNotConnectedException catch (e) {
        // The link went (or the host went to sleep) mid-pick: the rest would
        // fail identically, so stop and say why.
        debugPrint('localjam: add stopped, host unreachable: $e');
        _addFailures = const [];
        notify(
          e.hostAway ? kJamHostAsleepTryLater : kJamNotConnected,
          tone: JamNoticeTone.warning,
        );
        return failures;
      } catch (e) {
        debugPrint('localjam: could not add ${file.path}: $e');
        failures.add(JamAddFailure.of(file.path, e));
      }
    }
    _addFailures = List.unmodifiable(failures);
    // §2.8: a track landing in the queue is the small confirmation that the
    // pick worked. Only when at least one actually landed.
    if (failures.length < attempted) JamHaptics.queued();
    if (failures.isNotEmpty) {
      notify(describeAddFailures(failures), tone: JamNoticeTone.warning);
    } else if (duplicates > 0 && duplicates == attempted) {
      // Nothing failed and nothing changed: the room already had these exact
      // bytes (§6.4). Without this the queue simply does not move and the
      // pick reads as a button that did nothing.
      notify(kJamAlreadyQueued, tone: JamNoticeTone.neutral);
    }
    return _addFailures;
  }

  /// Starts the host's background import of [paths] — see [startHost].
  void _startImport(JamHostEngine engine, List<String> paths) {
    final job = engine.importFiles(paths.map(File.new), autoPlay: true);
    _import = job;
    unawaited(job.done.then((outcomes) => _onImportDone(job, outcomes)));
  }

  /// One notice for whatever would not add, once, when the import is done —
  /// the host-setup path's equivalent of [addFiles]' summary.
  void _onImportDone(JamImport job, List<JamImportOutcome> outcomes) {
    // A newer session (or none) has nothing to do with this job any more.
    if (!identical(job, _import) || !isLive) return;
    final failures = <JamAddFailure>[
      for (final outcome in outcomes)
        if (outcome.error case final error?)
          JamAddFailure.of(outcome.file.path, error),
    ];
    for (final failure in failures) {
      debugPrint('localjam: could not add ${failure.name}: ${failure.reason}');
    }
    _addFailures = List.unmodifiable(failures);
    if (failures.isNotEmpty) {
      notify(describeAddFailures(failures), tone: JamNoticeTone.warning);
    }
    // The room's "adding your music" state hangs off this.
    notifyListeners();
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
    // No "Jam ended" toast on the way out (§10.5): a host who ends the jam
    // lands on home, where the jam is already the newest Recent row, and a
    // guest's ended screen says it in full.
    await _teardown();
    _phase = JamSessionPhase.idle;
    _endReason = null;
    _endRejectReason = null;
    _restartArgs = null;
    _hostPick = const [];
    _joiningUri = null;
    _joiningName = null;
    // Back to idle is back to looking around: the browse the session stopped
    // comes up again here, on every way out — leave, end, kick, acknowledge.
    // Never awaited: mDNS start-up is best-effort and can sit there for as
    // long as the platform likes, and leaving must not wait on the radio.
    unawaited(_resumeBrowsing());
    notifyListeners();
  }

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
    _endRejectReason = null;
    _position = JamPositionTicker(engine);
    _lastMediaId = engine.snapshot.mediaId;
    // The room we are in is the one room we can never join. A host reads its
    // own advertisement, and a guest reads the host's.
    _setExcludedToken(_tokenOf(hostEngine?.joinUri ?? _lastJoinUri));
    // A room of our own stays out of Nearby for good, not just while we are
    // in it — see [_ownRoomTokens].
    final own = _tokenOf(hostEngine?.joinUri);
    if (own != null && own.isNotEmpty && _ownRoomTokens.add(own)) {
      _onRoomsChanged();
    }
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
    // Both sides: a guest's room can end in four ways, and a host's can end
    // without anyone pressing "End jam" — the OS reclaimed its listening
    // socket and it could not be reopened (listenerFailed). A host that only
    // a guest-side listener watched kept showing a QR nobody could use.
    engine.sessionEnded.addListener(_onSessionEnded);

    final guest = guestEngine;
    if (guest != null) {
      _subs
        ..add(guest.peerEvents.listen(_onGuestPeerEvent))
        ..add(guest.connectionStates.listen(_onConnection))
        // §8 host error reports. Nothing subscribed to these before, so a
        // denied request or a vanished file was simply a button that did
        // nothing.
        ..add(guest.errors.listen(_onGuestError));
      // "The host's phone is asleep" is a lifecycle fact about the room —
      // it disables controls everywhere — so it rides this notifier.
      guest.hostAway.addListener(_onHostAway);
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
    // Before close(): the engine disposes these listenables on its way out.
    _engine?.sessionEnded.removeListener(_onSessionEnded);
    guestEngine?.hostAway.removeListener(_onHostAway);
    // An import still running belongs to the room being left.
    _import?.cancel();
    _import = null;
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    _subs.clear();
    _peerNames.clear();
    _removing.clear();
    _sourcePaths.clear();
    backdrops.clear();
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
    if (!held) notify(kJamKeepAliveLost, tone: JamNoticeTone.warning);
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
      ErrorCode.notAllowed => 'The host hasn’t given you that yet.',
      ErrorCode.mediaGone => 'That song is no longer in the jam.',
      ErrorCode.internal => 'The host hit a problem with that.',
      ErrorCode.sessionFull => 'The jam is full.',
      ErrorCode.versionUnsupported => kJamVersionMismatch,
      // A code from a newer host (§2 tolerant decoding): nothing specific
      // to say about it, and nothing to retry automatically either.
      ErrorCode.unknown => 'The host couldn’t do that right now.',
      // kicked and badToken are fatal; sessionEnded owns the message.
      ErrorCode.kicked || ErrorCode.badToken => null,
    };
    if (copy != null) notify(copy, tone: JamNoticeTone.warning);
  }

  /// Removes [peerId] from the jam this device hosts (§5.6) — what People's
  /// "Remove from Jam" should call, so the departure that follows is told
  /// as the host's own action ("Removed Okon"), even for a guest the engine
  /// cannot keep out (one that sent no device id). Throws what
  /// [JamHostEngine.kickPeer] throws.
  void removePeer(String peerId) {
    final host = hostEngine;
    if (host == null) return;
    _removing.add(peerId);
    try {
      host.kickPeer(peerId);
    } catch (_) {
      _removing.remove(peerId);
      rethrow;
    }
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
        notify('$name joined', tone: JamNoticeTone.people);
      case JamHostEventKind.peerLeft:
        final id = event.peerId;
        final name = _peerNames.remove(id) ?? 'Someone';
        // A kick drops the connection like any departure, but it is the
        // host's own doing, and "Okon left" tells it as theirs. The engine
        // lists a kicked device before it drops it, so a removal made
        // anywhere (not only through [removePeer]) reads right.
        final removed =
            _removing.remove(id) ||
            (hostEngine?.kickedPeers.any((p) => p.peerId == id) ?? false);
        notify(
          removed ? jamRemovedNotice(name) : '$name left',
          tone: JamNoticeTone.people,
        );
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
          ? '$who added a song'
          : '$who added ${jamDisplayTitle(item)}',
      tone: JamNoticeTone.people,
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
      notify('Starting the queue over', tone: JamNoticeTone.neutral);
    }
  }

  void _onConnection(JamConnectionState state) {
    if (_connection == state) return;
    _connection = state;
    notifyListeners();
  }

  void _onSessionEnded() {
    final engine = _engine;
    final reason = engine?.sessionEnded.value;
    // closedLocally is our own leave() unwinding; it is not a state to show.
    if (engine == null ||
        reason == null ||
        reason == JamSessionEndReason.closedLocally) {
      return;
    }
    // The engine let go of the keep-alive on its way out: that is the end,
    // already on screen, not "background playback may pause".
    JamKeepAlive.active.removeListener(_onKeepAlive);
    if (engine is JamHostEngine) {
      // The room died under the host, not by their hand: keep what it took
      // to start it, so "Start a new jam" is one tap and not a re-pick.
      _restartArgs = (
        name: engine.sessionName,
        paths: jamRestartPaths(
          queue: [
            for (final item in engine.playlist) ?engine.localPathFor(item),
          ],
          picked: _hostPick,
          everQueued: _sourcePaths.values,
        ),
      );
    }
    _endReason = reason;
    // Read before anything tears the engine down: which refusal it was is
    // the difference between "ask for the new code" and "try again later".
    _endRejectReason = engine is JamGuestEngine
        ? engine.lastRejectReason
        : null;
    _phase = JamSessionPhase.ended;
    notifyListeners();
  }

  void _onHostAway() => notifyListeners();

  /// What to put in front of the user when a start or join fails.
  ///
  /// Never `error.toString()`: that leaked `RejectReason.version` and raw
  /// exception text into the UI. Anything unrecognised is generic on screen
  /// and detailed in the log.
  static String _describe(Object error) => switch (error) {
    JamRejectedException(:final reason) => switch (reason) {
      RejectReason.version => kJamVersionMismatch,
      RejectReason.full => 'That jam is full right now.',
      RejectReason.badToken =>
        'That code no longer works because the jam restarted. Ask for a '
            'fresh one.',
      // §5.6: the device stays out until the host lets it back in, so the
      // sentence says whose call that is rather than inviting a retry.
      RejectReason.kicked =>
        'The host removed you from this jam. They can let you back in.',
      // A reason from a newer host: still a no, and still final.
      RejectReason.unknown =>
        'The jam didn’t let you in. Ask the host for a fresh code.',
    },
    JamOffNetworkException() =>
      'That link points outside your network. A jam only runs between '
          'devices on it.',
    SocketException() =>
      'Couldn’t reach that jam. Check you’re both on '
          'the same network or hotspot.',
    FormatException() => 'That link isn’t a jam invite.',
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
///
/// When every file failed for the same nameable reason (the room's upload
/// space is full, the file is too big) that reason follows as a sentence;
/// mixed or unexplained failures stay at the names.
String describeAddFailures(List<JamAddFailure> failures) {
  if (failures.isEmpty) return '';
  final names = failures.take(3).map((f) => f.name).join(', ');
  final rest = failures.length - 3;
  final tail = rest > 0 ? '$names and $rest more' : names;
  final lead = failures.length == 1
      ? 'Couldn’t add $tail'
      : '${failures.length} songs couldn’t be added: $tail';
  final why = failures.first.why;
  if (why == null || failures.any((f) => f.why != why)) return lead;
  return '$lead. $why';
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
