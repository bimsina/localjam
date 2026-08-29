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

/// The app's single live-jam owner.
class JamSessionController extends ChangeNotifier {
  JamEngine? _engine;
  JamSide? _side;
  JamSessionPhase _phase = JamSessionPhase.idle;
  String? _error;
  JamSessionEndReason? _endReason;
  JamConnectionState _connection = JamConnectionState.connected;
  JamPositionTicker? _position;
  final List<StreamSubscription<Object?>> _subs = [];

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

  /// The last start/join failure, for the screen that attempted it.
  String? get error => _error;

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

  // --- Discovery ------------------------------------------------------------

  /// Starts the nearby browse. Best-effort and idempotent; the home screen
  /// drives this so the radio is not running for the whole app's life.
  Future<void> startBrowsing() async {
    if (isLive || _browser != null) return; // Never browse while in a room.
    final browser = JamRoomBrowser();
    _browser = browser;
    browser.rooms.addListener(_onRoomsChanged);
    await browser.start();
    notifyListeners();
  }

  /// Stops the nearby browse.
  Future<void> stopBrowsing() async {
    await _stopBrowsing();
    notifyListeners();
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
    JamPolicy policy = JamPolicy.open,
    bool discoverable = true,
    List<String> paths = const [],
  }) async {
    if (_phase != JamSessionPhase.idle) return false;
    _error = null;
    _phase = JamSessionPhase.starting;
    notifyListeners();
    try {
      await _stopBrowsing();
      final engine = await JamHostEngine.start(
        sessionName: sessionName,
        policy: policy,
        discoverable: discoverable,
      );
      _attach(engine, JamSide.host);
      for (final path in paths) {
        try {
          await engine.addMediaFile(File(path));
        } catch (_) {
          // One unreadable or unsupported file must not sink the session.
        }
      }
      // Cue the first track. Without this the room reports "Nothing queued"
      // while holding a full playlist, because nothing has been selected —
      // the host has a queue but no current media.
      if (engine.snapshot.mediaId == null && engine.playlist.isNotEmpty) {
        engine.setMedia(engine.playlist.first.mediaId);
      }
      return true;
    } catch (e) {
      _error = _describe(e);
      _phase = JamSessionPhase.idle;
      notifyListeners();
      return false;
    }
  }

  /// Joins the room in [joinUri]. Returns true when the session went live;
  /// on failure [error] carries the reason and the phase returns to idle.
  Future<bool> join(Uri joinUri, {String? clientName}) async {
    if (_phase != JamSessionPhase.idle) return false;
    _error = null;
    _phase = JamSessionPhase.starting;
    notifyListeners();
    try {
      await _stopBrowsing();
      final engine = await JamGuestEngine.join(joinUri, clientName: clientName);
      _attach(engine, JamSide.guest);
      return true;
    } catch (e) {
      _error = _describe(e);
      _phase = JamSessionPhase.idle;
      notifyListeners();
      return false;
    }
  }

  /// Ends the session on purpose — the only way out. A host closing the room
  /// ends it for everyone (PROTOCOL.md §10: host death ends the room).
  Future<void> leave() async {
    final engine = _engine;
    if (engine == null) {
      _phase = JamSessionPhase.idle;
      notifyListeners();
      return;
    }
    await _detach();
    try {
      await engine.close();
    } catch (_) {
      // Already torn down.
    }
    _phase = JamSessionPhase.idle;
    _endReason = null;
    notifyListeners();
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

    final guest = guestEngine;
    if (guest != null) {
      _subs.add(guest.connectionStates.listen(_onConnection));
      guest.sessionEnded.addListener(_onSessionEnded);
    }
    notifyListeners();
  }

  Future<void> _detach() async {
    final guest = guestEngine;
    if (guest != null) {
      guest.sessionEnded.removeListener(_onSessionEnded);
    }
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    _subs.clear();
    _position?.dispose();
    _position = null;
    _engine = null;
    _side = null;
    _connection = JamConnectionState.connected;
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

  static String _describe(Object error) => switch (error) {
    JamRejectedException(:final reason) =>
      'The host turned down the join '
          '($reason). Ask them to share the code again.',
    SocketException() =>
      'Could not reach that room. Check you are both on '
          'the same network or hotspot.',
    _ => error.toString(),
  };

  @override
  void dispose() {
    unawaited(_detach());
    unawaited(_stopBrowsing());
    _nearby.dispose();
    super.dispose();
  }
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
