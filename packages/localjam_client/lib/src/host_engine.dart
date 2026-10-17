/// The whole host side of a jam behind one object: a [JamHostServer] plus
/// local synchronized playback, so the host hears its own jam through the
/// same [AudioSyncController] a guest uses — with the identity session→local
/// clock mapping, because the host's monotonic clock IS the session clock
/// (PROTOCOL.md §4).
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:localjam_audio/localjam_audio.dart';
import 'package:localjam_net/localjam_net.dart';

import 'audio_sync_controller.dart';
import 'engine_notifier.dart';
import 'jam_discovery.dart';
import 'jam_engine.dart';
import 'jam_identity.dart';
import 'media_mime.dart';
import 'session_keepalive.dart';

/// Where one background [JamHostEngine.importFiles] run is.
@immutable
class JamImportProgress {
  const JamImportProgress({
    required this.total,
    this.completed = 0,
    this.added = 0,
    this.alreadyQueued = 0,
    this.failed = 0,
    this.cancelled = false,
  });

  /// Files handed to the import.
  final int total;

  /// Files dealt with so far (added + alreadyQueued + failed).
  final int completed;

  /// Files that became new playlist items.
  final int added;

  /// Files whose bytes were already queued (§6.4: content-addressed ids).
  final int alreadyQueued;

  /// Files that could not be added (unreadable, gone, ...).
  final int failed;

  /// The import was cancelled (or the room closed) before every file was
  /// dealt with.
  final bool cancelled;

  /// Whether the import has finished (all files dealt with, or cancelled).
  bool get isDone => cancelled || completed >= total;

  JamImportProgress _next({
    bool added = false,
    bool alreadyQueued = false,
    bool failed = false,
  }) => JamImportProgress(
    total: total,
    completed: completed + 1,
    added: this.added + (added ? 1 : 0),
    alreadyQueued: this.alreadyQueued + (alreadyQueued ? 1 : 0),
    failed: this.failed + (failed ? 1 : 0),
  );

  @override
  String toString() =>
      'JamImportProgress($completed/$total, added: $added, '
      'alreadyQueued: $alreadyQueued, failed: $failed'
      '${cancelled ? ', cancelled' : ''})';
}

/// What happened to one file of a [JamHostEngine.importFiles] run: a
/// [result] when it was added (or already queued), an [error] when not.
typedef JamImportOutcome = ({File file, JamAddResult? result, Object? error});

/// A background import of host files ([JamHostEngine.importFiles]): files
/// are added one at a time while the room is already open, with [progress]
/// for the UI and [done] for whoever wants the per-file outcome.
///
/// Nothing to dispose: [progress] holds no resources beyond its listeners,
/// stays readable (and listenable) after the import finishes, and is
/// garbage once nothing references the job. Remove your listeners as with
/// any listenable. An import ends by itself when the room closes.
class JamImport {
  JamImport._(int total)
    : _progress = ValueNotifier<JamImportProgress>(
        JamImportProgress(total: total),
      );

  final ValueNotifier<JamImportProgress> _progress;

  /// Live progress; ends with [JamImportProgress.isDone] true (cancelled if
  /// [cancel] was called or the room closed first).
  ValueListenable<JamImportProgress> get progress => _progress;

  final Completer<List<JamImportOutcome>> _done =
      Completer<List<JamImportOutcome>>();
  bool _cancelled = false;

  /// Every file's outcome, in order, once the import finished (files not
  /// reached before a cancel are absent). Never completes with an error.
  Future<List<JamImportOutcome>> get done => _done.future;

  /// Stops after the file in flight; the rest are not added.
  void cancel() => _cancelled = true;
}

/// One hosted session: server + registry + local playback.
///
/// Create with [start]; add tracks with [addMediaFile] (or, in the
/// background, [importFiles]); drive the transport with
/// [play]/[pause]/[seek]/[setMedia]/[stop]/[next]/[previous]; release with
/// [close].
///
/// The engine also keeps the room honest about being reachable:
///
/// * [joinUri] / [joinUriListenable] carry the LAN candidates guests can
///   actually reach right now, re-scanned every [addressRefreshInterval] and
///   on resume, so a QR rebuilt from them never points at a network the
///   device left. [hasLanAddress] is false when there is none — no Wi-Fi or
///   hotspot (a cellular link never counts, §9) — and the room is then
///   joinable from this machine only until one appears (the room listens on
///   every interface; the QR follows within [noLanAddressRefreshInterval]):
///   the app should say so meanwhile.
/// * Backgrounded where the OS may suspend it (iOS while not playing,
///   Android without its foreground service), the host tells guests it is
///   away (§3.5) so they wait for it instead of declaring it dead —
///   re-judged on every state change, track end and keep-alive change, so a
///   host that starts or stops producing sound in the background says so at
///   once. On resume it says it is back and checks its listening socket,
///   reopening it if the OS took it ([sessionEnded] =
///   [JamSessionEndReason.listenerFailed] if that fails).
class JamHostEngine extends JamEngine {
  JamHostEngine._(
    this._server, {
    required InternetAddress boundAddress,
    required List<InternetAddress> lan,
    required Set<String> nonLanLocals,
  }) : _boundAddress = boundAddress, // ignore: prefer_initializing_formals
       _nonLanLocals = nonLanLocals, // ignore: prefer_initializing_formals
       _lanAddresses = EngineValueNotifier<List<InternetAddress>>(
         List.unmodifiable(lan),
       ),
       _joinUri = EngineValueNotifier<Uri>(
         _buildCombinedJoinUri(_server, lan),
       ) {
    sync = AudioSyncController(
      player: player,
      sessionNowUs: monotonicNowUs,
      localNowUs: monotonicNowUs,
      sessionToLocalUs: (sessionUs) => sessionUs,
      resolveMediaPath: (mediaId) async => _playablePathFor(mediaId),
    );
    _eventsSub = _server.events.listen(_onHostEvent);
    // §5.5: the host's own player is the end-of-media detector of last
    // resort — the only one for an item whose duration is unknown.
    _finishedSub = sync.playbackFinished.listen(
      (finished) => _server.reportHostPlaybackFinished(
        finished.mediaId,
        snapshotRev: finished.snapshotRev,
      ),
    );
    // A host whose local output stops (a call, unplugged headphones) is a
    // host iOS may now suspend — and one whose output comes back is not.
    _suspensionSub = sync.outputSuspensionChanges.listen(
      (_) => _reconsiderAway(),
    );
    // A track that ran out, or the next one starting: deferred a microtask,
    // so the end-of-media report this same finish triggers (§5.5) has moved
    // the room on before the host judges whether it went quiet.
    sync.trackFinished.addListener(_onTrackFinishedChanged);
    // Android: the foreground service is what keeps a background host up.
    JamKeepAlive.active.addListener(_reconsiderAway);
    _kickedSub = _server.kickedPeersChanges.listen((kicked) {
      if (!_disposed) _kicked.value = kicked;
    });
    _watchListener();
    _scheduleAddressRefresh();
  }

  /// Starts a [JamHostServer] for [sessionName] and the host's own playback
  /// engine.
  ///
  /// Binds [port] (default: ephemeral) on [address], or — when no address is
  /// given — on every IPv4 interface (`anyIPv4`): one [HttpServer] binds one
  /// address, and a room has to be reachable across whatever LAN appears
  /// (including a hotspot that only gets its interface once the first
  /// device joins it — iOS's `bridge100`) and on the machine itself (two
  /// simulators, two emulators, the CLI beside the app). §9 is carried by
  /// two filters in the server: its remote-address filter
  /// ([JamHostServer.restrictToLanRemotes], on by default) refuses every
  /// off-LAN request on both planes, whichever interface it arrived on; and
  /// because a carrier hands out RFC1918 addresses too, connections that
  /// arrive on one of this device's cellular or tunnel addresses are
  /// refused by that local address ([JamHostServer.admitLocalAddress], fed
  /// from every interface re-scan). The IPv4 interfaces are enumerated for
  /// the join link ([lanCandidates]: private/link-local addresses on
  /// LAN-type interfaces; cellular and tunnel links never count); with none
  /// yet the room is already listening, [hasLanAddress] is false, and the
  /// link gains the address as soon as a re-scan finds one.
  ///
  /// [endPolicy] is applied when the current item reaches its end (§5.5); the
  /// engine defaults to advancing through the playlist.
  ///
  /// [maxPeers], [maxUploadBytes], [uploadBudgetBytes] and
  /// [maxPlaylistLength] forward the server's room-size and guest-upload
  /// caps (§6.4) so a host UI can offer a smaller room or a tighter disk
  /// budget than the defaults.
  ///
  /// Advertising, identity, the saved nudge and the OS session guards are all
  /// best-effort and time-boxed; a room appears even when every one of them
  /// is unavailable.
  ///
  /// With [discoverable] (the default) the room is advertised over mDNS so
  /// nearby devices list it for one-tap join — which means ANYONE on the
  /// network can join without the QR (the advertisement carries the token,
  /// §1/§9). Pass false for invite-only rooms. Best-effort: platforms
  /// without mDNS just stay QR-only.
  ///
  /// [hostName] is how guests see the person hosting — in the room roster and
  /// in "added by" bylines. It defaults to this device's persistent
  /// [JamIdentity.displayName] ("Silky Puffin"), the same identity a guest
  /// announces, so the host is a person in the room rather than the word
  /// "Host". Pass an empty string to host anonymously.
  ///
  /// Tracks are added afterwards: [addMediaFile] one at a time, or
  /// [importFiles] to open the room at once and fill the queue in the
  /// background.
  static Future<JamHostEngine> start({
    required String sessionName,
    String? hostName,
    JamEndPolicy endPolicy = JamEndPolicy.advance,
    JamPolicy policy = JamPolicy.jam,
    bool discoverable = true,
    int port = 0,
    InternetAddress? address,
    int maxPeers = JamHostServer.defaultMaxPeers,
    int maxUploadBytes = JamHostServer.defaultMaxUploadBytes,
    int uploadBudgetBytes = JamHostServer.defaultUploadBudgetBytes,
    int maxPlaylistLength = JamHostServer.defaultMaxPlaylistLength,
  }) async {
    // Nothing on the way to a room may be unbounded: every step below either
    // finishes inside its own budget or is abandoned for a working fallback,
    // so start() returns in well under two seconds on every platform —
    // including one whose prefs, interface list or mDNS stack has stopped
    // answering. Only the socket bind is allowed to fail the call: a host
    // without a server is not a host.
    final displayName =
        hostName ??
        await _bounded<String>(
          JamIdentity.displayName(),
          _identityBudget,
          () => generateJamName(),
        );
    // The server's predicate holds this very set; the engine refills it in
    // place on every re-scan ([_nonLanLocals]).
    final nonLanLocals = <String>{};
    final server = JamHostServer(
      sessionName: sessionName,
      hostName: displayName,
      hostKind: 'flutter',
      endPolicy: endPolicy,
      policy: policy,
      maxPeers: maxPeers,
      maxUploadBytes: maxUploadBytes,
      uploadBudgetBytes: uploadBudgetBytes,
      maxPlaylistLength: maxPlaylistLength,
      admitLocalAddress: (local) =>
          !nonLanLocals.contains(localAddressSeen(local).address),
    );
    final scan = await _scanLan();
    nonLanLocals.addAll(scan.nonLanLocals);
    try {
      final bindAddress = address ?? InternetAddress.anyIPv4;
      await server.start(address: bindAddress, port: port);
      final engine = JamHostEngine._(
        server,
        boundAddress: bindAddress,
        lan: _reachableLan(bindAddress, scan.addresses),
        nonLanLocals: nonLanLocals,
      );
      // Neither the saved nudge nor the OS-level guards are worth a room:
      // both are bounded and both are allowed to fail.
      await _bounded<void>(engine.restorePersistedNudge(), _guardBudget, () {});
      await _bounded<void>(engine.startSessionGuards(), _guardBudget, () {});
      if (discoverable) {
        final advertiser = await _bounded<JamRoomAdvertiser?>(
          roomAdvertiserStarter(
            sessionName: sessionName,
            port: server.port,
            token: server.token,
            addresses: engine.lanAddresses.value,
            timeout: _advertiseBudget,
          ),
          // The outer bound has to cover BOTH responders, or a daemon that
          // eats its whole slice would take the fallback down with it.
          JamRoomAdvertiser.totalTimeout,
          () => null,
        );
        // The room may already be over by the time mDNS answered.
        if (engine._closed) {
          await advertiser?.stop();
        } else {
          engine._advertiser = advertiser;
        }
      }
      // Preload whatever the (idle) snapshot says — a no-op until setMedia.
      unawaited(engine.sync.onSnapshot(server.snapshot));
      return engine;
    } catch (_) {
      await server.close();
      rethrow;
    }
  }

  /// Time each optional step of [start] is given before the fallback wins.
  static const Duration _identityBudget = Duration(milliseconds: 400);
  static const Duration _lanScanBudget = Duration(milliseconds: 400);
  static const Duration _guardBudget = Duration(milliseconds: 500);

  /// The Bonjour daemon's own slice; [JamRoomAdvertiser.totalTimeout] is the
  /// whole step, daemon plus built-in-responder fallback.
  static const Duration _advertiseBudget = JamRoomAdvertiser.defaultTimeout;

  /// [future] with a deadline: on timeout OR on error the [fallback] value is
  /// used and the room still happens. A timed-out future is abandoned, not
  /// cancelled — Dart cannot cancel one — so its own error, if it ever
  /// arrives, is swallowed rather than left to reach the zone.
  static Future<T> _bounded<T>(
    Future<T> future,
    Duration budget,
    T Function() fallback,
  ) async {
    // The abandoned future keeps running — Dart cannot cancel one — so it is
    // given a listener of its own; without it a late failure would surface as
    // an unhandled error long after the room opened.
    unawaited(future.then((_) {}, onError: (Object _) {}));
    try {
      return await future.timeout(budget);
    } catch (error) {
      debugPrint('localjam: host start step gave up after $budget ($error)');
      return fallback();
    }
  }

  /// Starts the room advertisement. A seam so tests can make advertising
  /// hang, fail, or succeed without an mDNS stack.
  @visibleForTesting
  static Future<JamRoomAdvertiser?> Function({
    required String sessionName,
    required int port,
    required String token,
    List<InternetAddress> addresses,
    Duration timeout,
  })
  roomAdvertiserStarter = JamRoomAdvertiser.start;

  /// The local address the §9 filter takes a connection to have arrived on,
  /// given the one its socket reports — the identity. A seam: a test machine
  /// cannot make a real connection arrive on a cellular address, so a test
  /// maps loopback onto an address whose link its fake interface list
  /// decides ([networkInterfaceLister]), and the real socket, the real
  /// guard and the real re-scan do the rest.
  @visibleForTesting
  static InternetAddress Function(InternetAddress local) localAddressSeen =
      defaultLocalAddressSeen;

  /// The real mapping (none), and what [localAddressSeen] must be put back
  /// to after a test replaces it.
  @visibleForTesting
  static InternetAddress defaultLocalAddressSeen(InternetAddress local) =>
      local;

  /// Enumerates the device's network interfaces. A seam so tests can make
  /// enumeration slow, huge, or broken.
  @visibleForTesting
  static Future<List<NetworkInterface>> Function() networkInterfaceLister =
      defaultNetworkInterfaceLister;

  /// The real enumeration, and what [networkInterfaceLister] must be put back
  /// to after a test replaces it.
  @visibleForTesting
  static Future<List<NetworkInterface>> defaultNetworkInterfaceLister() =>
      NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );

  /// How often a live room re-scans its interfaces for [joinUri] — there is
  /// no portable interface-change notification, and a phone that hops
  /// between Wi-Fi networks or starts a hotspot must not keep handing out a
  /// stale QR. Also re-scanned on every resume from the background.
  static Duration addressRefreshInterval = const Duration(seconds: 10);

  /// The re-scan interval while there is no LAN address at all
  /// ([hasLanAddress] false): someone is about to switch Wi-Fi on or join
  /// this phone's hotspot, and the QR should appear within moments of it.
  static Duration noLanAddressRefreshInterval = const Duration(seconds: 2);

  /// Whether the OS may suspend this host while its app is in the
  /// background, in its current state — when true, backgrounding announces
  /// the host away (§3.5). A seam for tests; [defaultBackgroundSuspendPolicy]
  /// is the real rule.
  @visibleForTesting
  static bool Function(JamHostEngine engine) backgroundSuspendPolicy =
      defaultBackgroundSuspendPolicy;

  /// iOS suspends a backgrounded app shortly after it stops producing audio
  /// (`UIBackgroundModes: audio` only covers playback), so a paused,
  /// finished, or locally silenced host is going to sleep. Android keeps the
  /// process for as long as the `mediaPlayback` foreground service holds
  /// ([JamKeepAlive.active]); without it the app is a cached process the OS
  /// freezes. Desktop apps are not suspended.
  static bool defaultBackgroundSuspendPolicy(JamHostEngine engine) {
    if (kIsWeb) return false;
    return switch (defaultTargetPlatform) {
      TargetPlatform.iOS => !engine._producingAudio,
      TargetPlatform.android => !JamKeepAlive.active.value,
      _ => false,
    };
  }

  /// Interface-name prefixes of links that are never the room's network
  /// (§9): cellular data — whose addresses can be RFC1918 behind a carrier
  /// NAT and so pass the address test — and point-to-point tunnels, which
  /// no guest shares and which would only cost every joiner a connect
  /// timeout before the real candidate. (Carrier-grade NAT space, 100.64/10,
  /// is already off-LAN by address — [JamHostServer.isLanAddress].)
  static const List<String> _nonLanInterfacePrefixes = [
    'rmnet', // Qualcomm cellular (Android): rmnet0, rmnet_data0, rmnet_ipa0
    'ccmni', // MediaTek cellular (Android)
    'pdp_ip', // iOS cellular
    'wwan', // mobile broadband (Linux, Windows)
    'seth_', // Spreadtrum/Unisoc cellular (seth_lte0)
    'sipa_', // Unisoc cellular
    'v4-', // Android CLAT (464XLAT) stacked on cellular: v4-rmnet_data0
    'clat', // CLAT on other builds
    'ppp', // modem PPP links
    'tun', // VPNs (Android, Linux)
    'utun', // VPNs and system tunnels (Apple)
    'ipsec', // IPsec VPNs (Apple)
    'wg', // WireGuard
  ];

  /// Whether an interface named [name] can carry the room (§9): false for
  /// cellular links and tunnels, true for Wi-Fi, Ethernet, hotspot and USB
  /// tethering interfaces.
  @visibleForTesting
  static bool isLanInterface(String name) {
    final lower = name.toLowerCase();
    for (final prefix in _nonLanInterfacePrefixes) {
      if (lower.startsWith(prefix)) return false;
    }
    return true;
  }

  /// The LAN candidates among [interfaces]: addresses [JamHostServer.isLanAddress]
  /// accepts, on interfaces [isLanInterface] accepts, never loopback.
  @visibleForTesting
  static List<InternetAddress> lanAddressesOf(
    Iterable<NetworkInterface> interfaces,
  ) => [
    for (final iface in interfaces)
      if (isLanInterface(iface.name))
        for (final address in iface.addresses)
          if (!address.isLoopback && JamHostServer.isLanAddress(address))
            address,
  ];

  /// This device's own addresses on interfaces [isLanInterface] rejects —
  /// cellular links and tunnels — which the room refuses connections on
  /// (§9, [JamHostServer.admitLocalAddress]). Never loopback: the resume
  /// self-probe and same-machine guests come in that way. An address a LAN
  /// interface also carries stays out too — it cannot say which link a
  /// connection used, and refusing it would lock the room's own network out.
  @visibleForTesting
  static Set<String> nonLanLocalAddressesOf(
    Iterable<NetworkInterface> interfaces,
  ) {
    final lan = <String>{};
    final nonLan = <String>{};
    for (final iface in interfaces) {
      final into = isLanInterface(iface.name) ? lan : nonLan;
      for (final address in iface.addresses) {
        if (!address.isLoopback) into.add(address.address);
      }
    }
    return nonLan.difference(lan);
  }

  /// The LAN scan plus whether it actually finished: a device whose interface
  /// list is slow or refused is NOT a device without a LAN, and must not be
  /// demoted to a loopback room of one.
  static Future<
    ({
      List<InternetAddress> addresses,
      Set<String> nonLanLocals,
      bool enumerated,
    })
  >
  _scanLan() async {
    try {
      final interfaces = await networkInterfaceLister().timeout(_lanScanBudget);
      return (
        addresses: lanAddressesOf(interfaces),
        nonLanLocals: nonLanLocalAddressesOf(interfaces),
        enumerated: true,
      );
    } catch (error) {
      // NetworkInterface.list can fail on locked-down systems, and can hang
      // on a device whose network stack is mid-transition.
      debugPrint(
        'localjam: interface enumeration failed ($error); '
        'keeping the previous LAN candidates.',
      );
      return (
        addresses: const <InternetAddress>[],
        nonLanLocals: const <String>{},
        enumerated: false,
      );
    }
  }

  /// The device's own LAN-facing IPv4 addresses (§9): every non-loopback
  /// interface address that [JamHostServer.isLanAddress] accepts — private
  /// RFC1918, link-local, or hotspot-range — on an interface that is not a
  /// cellular link or a tunnel ([isLanInterface]). A machine with a public
  /// IPv4 on an interface contributes nothing: a jam is never hosted on the
  /// internet, nor on a carrier's network.
  ///
  /// Empty when the device has no LAN at all (airplane mode, cellular only)
  /// or when the platform refuses to enumerate interfaces.
  @visibleForTesting
  static Future<List<InternetAddress>> lanCandidates() async =>
      (await _scanLan()).addresses;

  /// The candidates a guest can reach given what the server is bound to: all
  /// of [lan] behind a wildcard bind, only the bound address behind a
  /// specific one, nothing behind loopback.
  static List<InternetAddress> _reachableLan(
    InternetAddress bound,
    List<InternetAddress> lan,
  ) {
    if (bound.isLoopback) return const [];
    if (bound.address == InternetAddress.anyIPv4.address) return lan;
    return JamHostServer.isLanAddress(bound) ? [bound] : const [];
  }

  /// One `localjam://join?...` URI carrying every candidate a guest may try,
  /// comma-joined (§1: guests try them in order): the LAN addresses first,
  /// then loopback, which is the only path that works for a guest running on
  /// this same machine (two simulators, two emulators, the CLI beside the
  /// app). Off-machine guests spend nothing on it — a connect to their own
  /// loopback is refused at once.
  static Uri _buildCombinedJoinUri(
    JamHostServer server,
    List<InternetAddress> lan,
  ) {
    final addresses = [...lan, InternetAddress.loopbackIPv4];
    return Uri(
      scheme: 'localjam',
      host: 'join',
      queryParameters: {
        'v': '${MessageCodec.protocolVersion}',
        'host': addresses.map((a) => a.address).join(','),
        'port': '${server.port}',
        'token': server.token,
        'name': server.sessionName,
      },
    );
  }

  final JamHostServer _server;
  final InternetAddress _boundAddress;

  /// This device's cellular and tunnel addresses ([nonLanLocalAddressesOf]),
  /// refilled in place on every re-scan: the server's
  /// [JamHostServer.admitLocalAddress] holds this very set and refuses a
  /// connection that arrived on one of them before parsing it (§9). Behind
  /// the wildcard bind the room listens on those links too, and the remote
  /// filter alone cannot tell a stranger behind the carrier's NAT — RFC1918
  /// like a neighbour on the Wi-Fi — from that neighbour.
  ///
  /// Caveat: dart:io gives an accepted socket its listener's address, so
  /// behind the wildcard bind the server is told `0.0.0.0` for every
  /// connection and this set refuses nothing until localjam_net learns the
  /// real local address (the skipped test in host_regression_test.dart).
  final Set<String> _nonLanLocals;
  final ValueNotifier<List<InternetAddress>> _lanAddresses;
  final ValueNotifier<Uri> _joinUri;

  /// The combined multi-interface join URI for QR codes and copy/paste:
  /// the LAN candidates guests can reach right now, then loopback. Changes
  /// when the device's networks do — listen on [joinUriListenable] and
  /// rebuild the QR. While [hasLanAddress] is false it names loopback only
  /// and must not be presented as a way in.
  Uri get joinUri => _joinUri.value;

  /// [joinUri], listenable: updated after a network change (re-scanned every
  /// [addressRefreshInterval] and on resume).
  ValueListenable<Uri> get joinUriListenable => _joinUri;

  /// The LAN addresses in [joinUri] (no loopback), listenable. Empty when
  /// the device has no Wi-Fi/Ethernet/hotspot network guests could reach —
  /// see [hasLanAddress].
  ValueListenable<List<InternetAddress>> get lanAddresses => _lanAddresses;

  /// Whether another device can reach this room at all: a LAN address the
  /// server is listening on. False with no Wi-Fi or hotspot (cellular never
  /// counts, §9) — the app should warn "connect to Wi-Fi or start a
  /// hotspot" rather than show a QR. The room listens on every interface
  /// regardless, so this turns true by itself (re-scanned every
  /// [noLanAddressRefreshInterval] while false) once Wi-Fi comes back or a
  /// device joins this phone's hotspot; listen on [lanAddresses] or
  /// [joinUriListenable].
  bool get hasLanAddress => _lanAddresses.value.isNotEmpty;

  /// The address the server was bound to (`anyIPv4` unless [start] was
  /// given one).
  @visibleForTesting
  InternetAddress get boundAddress => _boundAddress;

  @override
  final LocaljamAudio player = LocaljamAudio();

  @override
  late final AudioSyncController sync;

  StreamSubscription<JamHostEvent>? _eventsSub;
  StreamSubscription<JamPlaybackFinished>? _finishedSub;
  StreamSubscription<JamOutputSuspension?>? _suspensionSub;
  StreamSubscription<List<PeerInfo>>? _kickedSub;
  JamRoomAdvertiser? _advertiser;
  Timer? _addressTimer;
  Future<void>? _refreshing;

  /// Set while the built-in mDNS responder should be advertising the room
  /// but is not — its restart after an address change failed — so every
  /// re-scan tries again until it is back.
  bool _readvertisePending = false;
  bool _closed = false;
  bool _disposed = false;
  bool _backgrounded = false;
  Future<void>? _repairing;
  Future<void>? _teardownDone;

  final ValueNotifier<bool> _away = EngineValueNotifier<bool>(false);
  final ValueNotifier<List<PeerInfo>> _kicked =
      EngineValueNotifier<List<PeerInfo>>(const []);

  /// Whether the room is currently advertised over mDNS (§1).
  bool get discoverable => _advertiser != null;

  /// Whether guests have been told this host is away (§3.5): true while the
  /// app is in the background in a state the OS may suspend.
  ValueListenable<bool> get announcedAway => _away;

  /// mediaId → absolute local path of the host's own adds ([addMedia]).
  final Map<String, String> _mediaPaths = {};

  /// Where the host's own player reads [mediaId] from: a guest's upload from
  /// the file the server stored for it (§6.4) — the host never fetches its
  /// own media plane, and the bytes are already on its disk — and the
  /// host's own adds from the file it registered. Uploads used to resolve
  /// to nothing at all: the host's controller parked waiting for a path
  /// that never came, and the host was silent for every guest's track
  /// while the room played on (2026-10-17 run).
  String? _playablePathFor(String mediaId) =>
      _server.storedUploadFile(mediaId)?.path ?? _mediaPaths[mediaId];

  /// Latest in-flight fetch progress per peer (§6.3); entries are removed
  /// when the peer's report leaves `fetching` or the peer drops.
  final Map<String, ({String mediaId, double progress})> _fetchProgress = {};

  final StreamController<PlaybackSnapshot> _states =
      StreamController<PlaybackSnapshot>.broadcast();
  final StreamController<List<MediaItem>> _playlists =
      StreamController<List<MediaItem>>.broadcast();
  final StreamController<String?> _mediaEnded =
      StreamController<String?>.broadcast();
  final StreamController<({String mediaId, String? peerId})> _mediaUploads =
      StreamController<({String mediaId, String? peerId})>.broadcast();

  // --- Server mirror -----------------------------------------------------------

  /// Human-readable session name (also in [joinUri]).
  @override
  String get sessionName => _server.sessionName;

  /// Random session id sent in `welcome` (§3.1).
  @override
  String get sessionId => _server.sessionId;

  /// The bound port.
  int get port => _server.port;

  /// Session token gating both planes (§9).
  String get token => _server.token;

  /// The join URI for one specific interface (e.g. loopback in tests).
  Uri joinUriFor(InternetAddress iface) => _server.joinUriFor(iface);

  @override
  PlaybackSnapshot get snapshot => _server.snapshot;

  @override
  Stream<PlaybackSnapshot> get states => _states.stream;

  @override
  List<MediaItem> get playlist => _server.playlist;

  @override
  Stream<List<MediaItem>> get playlistUpdates => _playlists.stream;

  /// Currently joined peers (never this host — see [hostPeer]).
  @override
  List<PeerInfo> get peers => _server.peers;

  /// This host as a person: the reserved host peer id plus the display name
  /// [start] was given, which is what every guest sees in `welcome.host`.
  @override
  PeerInfo get hostPeer => _server.hostPeer;

  @override
  String get selfPeerId => JamPermissions.hostPeerId;

  /// The file this host added [item] from; null for a guest's upload.
  ///
  /// An upload is played from the server's own upload store, but that store
  /// is the room's: it is deleted when the room closes. Reporting it here
  /// would hand jam history (and a "start a new jam" restart) a path that
  /// is gone by the time anyone uses it, so a guest's track is recorded as
  /// not replayable on the host — its bytes go with the room, as on every
  /// other device that did not keep a copy.
  @override
  String? localPathFor(MediaItem item) => _mediaPaths[item.mediaId];

  @override
  JamPermissions get permissions => _server.permissions;

  @override
  Stream<JamPermissions> get permissionUpdates => _server.events
      .where((e) => e.kind == JamHostEventKind.permissionsBroadcast)
      .map((e) => e.permissions!);

  /// Raw host observability events (peer joins/leaves, media status,
  /// broadcasts) — everything a host UI needs to repaint on.
  Stream<JamHostEvent> get events => _server.events;

  /// The ended item's mediaId each time the current track reaches its end
  /// (§5.5), before the [JamEndPolicy]'s resulting state broadcast.
  Stream<String?> get mediaEnded => _mediaEnded.stream;

  /// Each guest upload that added a new item (§6.4): the new mediaId plus
  /// the peerId the item is credited to. By the time an event is delivered
  /// the item is already in [playlist], and its file is what this host's
  /// own player plays (idempotent re-uploads of existing content do not
  /// fire).
  Stream<({String mediaId, String? peerId})> get mediaUploads =>
      _mediaUploads.stream;

  /// Readiness for [mediaId] across all joined peers (§6.3).
  Map<String, MediaReadiness> peerMediaStates(String mediaId) =>
      _server.peerMediaStates(mediaId);

  /// Whether every joined peer has reported `ready` for [mediaId] (§6.3).
  bool allPeersReady(String mediaId) => _server.allPeersReady(mediaId);

  /// Whether a [play] is currently held by the §6.3 readiness gate: the
  /// room is `loading` and starts on its own within the server's
  /// `readinessWait` (2.5 s) — "waiting for everyone's download". The
  /// instantaneous answer; [awaitingReadiness] is the same, listenable.
  bool get isAwaitingReadiness => _server.isAwaitingReadiness;

  /// [isAwaitingReadiness], listenable — what a "waiting for everyone's
  /// download" line should be built from.
  ///
  /// The server announces no event when a start is held: the room just stays
  /// `loading`. The release always comes with a state broadcast, and so does
  /// a hold that a skip, a removal or a track end causes; this engine's own
  /// [play] is followed at once. The one silent case is a guest's `play`
  /// request (§5.2) — so while a hold is possible at all (the room is
  /// `loading` a track some guest reports `fetching`) or held, the server is
  /// re-read every [readinessPollInterval]. Outside that window nothing
  /// polls.
  ValueListenable<bool> get awaitingReadiness => _awaitingReadiness;

  /// How often [awaitingReadiness] re-reads the server while a hold is
  /// possible (see there): a bool read, for a hold that lasts at most 2.5 s.
  @visibleForTesting
  static Duration readinessPollInterval = const Duration(milliseconds: 200);

  final ValueNotifier<bool> _awaitingReadiness = EngineValueNotifier<bool>(
    false,
  );
  Timer? _readinessPoll;

  /// Brings [awaitingReadiness] up to date with the server, and starts or
  /// stops the poll that covers holds nothing announces.
  void _syncAwaitingReadiness() {
    if (_disposed) return;
    final awaiting = !_closed && _server.isAwaitingReadiness;
    final watch = !_closed && (awaiting || _readinessHoldPossible);
    if (!watch) {
      _readinessPoll?.cancel();
      _readinessPoll = null;
    } else {
      _readinessPoll ??= Timer.periodic(
        readinessPollInterval,
        (_) => _syncAwaitingReadiness(),
      );
    }
    if (_awaitingReadiness.value == awaiting) return;
    _awaitingReadiness.value = awaiting;
    // A held start counts as producing sound (§3.5): a guest's play held in
    // the background is as much a reason to stay awake as one of ours.
    _reconsiderAway();
  }

  /// Whether the server's gate could hold a start right now: it only ever
  /// holds a freshly selected (`loading`) track somebody is mid-transfer of.
  bool get _readinessHoldPossible {
    final current = snapshot;
    final mediaId = current.mediaId;
    return current.status == PlaybackStatus.loading &&
        mediaId != null &&
        _server.peerMediaStates(mediaId).containsValue(MediaReadiness.fetching);
  }

  /// Latest in-flight fetch progress per peerId (§6.3).
  Map<String, ({String mediaId, double progress})> get peerFetchProgress =>
      Map.unmodifiable(_fetchProgress);

  /// Whether the listening socket is believed alive (see
  /// [JamHostServer.isListening]).
  bool get isListening => _server.isListening;

  /// Reopens a dead listening socket ([JamHostServer.restartListener]). A
  /// seam so tests can make the reopen fail (the port taken meanwhile).
  @visibleForTesting
  static Future<void> Function(JamHostServer server) listenerRestarter =
      defaultListenerRestarter;

  /// The real reopen, and what [listenerRestarter] must be put back to.
  @visibleForTesting
  static Future<void> defaultListenerRestarter(JamHostServer server) =>
      server.restartListener();

  /// Asks the listening socket whether it still accepts connections
  /// ([JamHostServer.selfProbe]) on resume. A seam so tests can stand in an
  /// OS that took the socket without a word — the case only the probe
  /// catches, since nothing completes [JamHostServer.listenerDone] for it.
  @visibleForTesting
  static Future<bool> Function(JamHostServer server) listenerProber =
      defaultListenerProber;

  /// The real probe, and what [listenerProber] must be put back to.
  @visibleForTesting
  static Future<bool> defaultListenerProber(JamHostServer server) =>
      server.selfProbe();

  /// The server behind this engine, for tests that need to reach under the
  /// engine (e.g. to kill its listening socket the way an OS would).
  @visibleForTesting
  JamHostServer get debugServer => _server;

  @override
  int? get sessionNowUsOrNull => monotonicNowUs();

  /// Whether this host is producing (or about to produce) sound — what keeps
  /// a backgrounded iOS app running. A track that ran out only counts as
  /// silence while the room still sits on it: once the room has moved on
  /// (a newer rev — the next track loading) the host is about to play.
  bool get _producingAudio =>
      (snapshot.status == PlaybackStatus.playing || isAwaitingReadiness) &&
      !sync.isOutputSuspended &&
      sync.finishedSnapshotRev != snapshot.rev;

  // --- Media registry (§6.1) ------------------------------------------------

  /// Registers [file] as an audio playlist item and broadcasts the updated
  /// playlist (§6.1). Returns the new item.
  ///
  /// The host must supply durations (§5.5): the native engine reads the
  /// file's headers ([LocaljamAudio.probeDurationUs]) without touching what
  /// is loaded or playing. When the native side cannot tell, the
  /// tag-declared duration is the fallback; without either, end of media
  /// comes from the host's own player instead (§5.5).
  ///
  /// Tags and embedded artwork are extracted here (§6.1/§6.5) — same
  /// best-effort path guest uploads go through on the server — so the
  /// broadcast item carries title/artist/album/artworkId when the file has
  /// them.
  Future<MediaItem> addMediaFile(File file, {String? name}) async =>
      (await addMedia(file, name: name)).item;

  /// [addMediaFile], plus what the add did — the host's half of the same
  /// answer [JamGuestEngine.addMedia] gives, so one app call site serves both
  /// sides. Media ids are content-derived, so re-adding a file that is
  /// already in the queue changes nothing and reports
  /// [JamAddOutcome.alreadyQueued] rather than silently succeeding.
  @override
  Future<JamAddResult> addMedia(File file, {String? name}) async {
    final knownBefore = {for (final item in playlist) item.mediaId};
    final durationUs = await _probeDurationUs(file.path);
    final tags = await readAudioTags(file);
    String? artworkId;
    final artworkBytes = tags.artworkBytes;
    if (tags.hasArtwork) {
      artworkId = await _server.addArtwork(
        artworkBytes!,
        mime: tags.artworkMime!,
      );
    }
    final item = await JamHostServer.describeFile(
      file,
      kind: MediaKind.audio,
      name: name,
      mime: mimeForPath(file.path),
      durationUs: durationUs ?? tags.durationUs,
      title: tags.title,
      artist: tags.artist,
      album: tags.album,
      artworkId: artworkId,
      addedBy: JamPermissions.hostPeerId,
    );
    if (knownBefore.contains(item.mediaId) ||
        playlist.any((i) => i.mediaId == item.mediaId)) {
      // Same bytes, same id: the registry already points at a copy, and
      // re-adding would broadcast a playlist that did not change.
      return JamAddResult(item, JamAddOutcome.alreadyQueued);
    }
    _mediaPaths[item.mediaId] = file.path;
    _server.addMedia(item, file);
    return JamAddResult(item, JamAddOutcome.added);
  }

  /// Adds [files] in the background, one at a time, while the room is
  /// already open — the alternative to awaiting [addMedia] for each before
  /// the room is shown, which on a big pick holds "Start the jam" for a
  /// probe, a tag read and a full sha256 per file.
  ///
  /// With [cueFirst] (the default) the first file to land is selected when
  /// nothing is; with [autoPlay] it is also started, so a fresh room makes
  /// sound as soon as one track is in rather than when all of them are.
  /// Per-file failures are recorded in the outcome, never thrown.
  JamImport importFiles(
    Iterable<File> files, {
    bool cueFirst = true,
    bool autoPlay = false,
  }) {
    final queue = files.toList();
    final job = JamImport._(queue.length);
    unawaited(() async {
      final outcomes = <JamImportOutcome>[];
      for (final file in queue) {
        if (job._cancelled || _closed) break;
        final JamAddResult result;
        try {
          result = await addMedia(file);
        } catch (error) {
          outcomes.add((file: file, result: null, error: error));
          job._progress.value = job.progress.value._next(failed: true);
          continue;
        }
        outcomes.add((file: file, result: result, error: null));
        if (_closed) break;
        job._progress.value = job.progress.value._next(
          added: !result.alreadyQueued,
          alreadyQueued: result.alreadyQueued,
        );
        try {
          if (cueFirst && snapshot.mediaId == null) {
            setMedia(result.item.mediaId);
          }
          if (autoPlay && snapshot.mediaId != null) {
            // Only the first landing starts the room; a host who paused
            // meanwhile is not overruled by the next file.
            autoPlay = false;
            if (snapshot.status != PlaybackStatus.playing &&
                !isAwaitingReadiness) {
              play();
            }
          }
        } catch (error) {
          // Removed from under us (a host edit racing the import): the file
          // is in or it is not; cueing is best-effort.
          debugPrint('localjam: could not cue the imported track ($error)');
        }
      }
      final last = job.progress.value;
      if (!last.isDone) {
        job._progress.value = JamImportProgress(
          total: last.total,
          completed: last.completed,
          added: last.added,
          alreadyQueued: last.alreadyQueued,
          failed: last.failed,
          cancelled: true,
        );
      }
      job._done.complete(outcomes);
    }());
    return job;
  }

  /// Artwork bytes for [item], read straight from the server's registry
  /// (§6.5) — the host never fetches over HTTP. Null when the item has no
  /// artwork or the backing file went away.
  @override
  Future<Uint8List?> artworkFor(MediaItem item) async {
    final artworkId = item.artworkId;
    if (artworkId == null) return null;
    final file = _server.artworkFile(artworkId);
    if (file == null) return null;
    try {
      return await file.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  /// The §5.5 duration from the file's headers. Never loads the file into
  /// the shared engine — that used to replace (and, with a snapshot landing
  /// mid-probe, even play) the current track.
  Future<int?> _probeDurationUs(String path) async {
    try {
      return await player.probeDurationUs(path);
    } catch (_) {
      return null; // Native side unavailable; register without a duration.
    }
  }

  // --- Transport (§5) ----------------------------------------------------------
  //
  // The raw room mutations, synchronous, throwing for what cannot be done.
  // The [JamEngine] intents below (transportPlay, queueMove, ...) wrap them
  // for UI code: they never throw and answer whether anything happened.

  /// Starts (or resumes) playback with a scheduled anchor (§5.3) — or, for
  /// a fresh track a guest is still fetching, holds the start for the §6.3
  /// readiness gate ([awaitingReadiness]). Throws [StateError] if no media
  /// is selected.
  void play() {
    _server.play();
    _syncAwaitingReadiness();
  }

  /// Pauses playback, freezing the position (§5.1). Also drops a start held
  /// by the readiness gate.
  void pause() {
    _server.pause();
    _syncAwaitingReadiness();
  }

  /// Seeks to [positionUs], clamped to the current item's duration (§5.5).
  void seek(int positionUs) => _server.seek(positionUs);

  /// Selects [mediaId] (§5.1, §5.2 `set_media`) and keeps the room doing
  /// what it was doing: a room playing (or holding a start) plays it from
  /// its start, through the §6.3 readiness gate like any new track — so the
  /// start may now be held ([awaitingReadiness]); a paused or idle room cues
  /// it. Selecting the current item changes nothing (starting it over is a
  /// [seek] to 0). Throws [ArgumentError] for unknown ids.
  void setMedia(String mediaId) {
    _server.setMedia(mediaId);
    _syncAwaitingReadiness();
  }

  /// Stops playback: back to idle with no media selected (§5.5).
  void stop() {
    _server.stop();
    _syncAwaitingReadiness();
  }

  /// Selects the next playlist item, wrapping at the end.
  void next() {
    _server.next();
    _syncAwaitingReadiness();
  }

  /// Selects the previous playlist item, wrapping at the start.
  void previous() {
    _server.previous();
    _syncAwaitingReadiness();
  }

  // --- Queue ops (§5.6) ------------------------------------------------------

  /// Moves [mediaId] to queue position [toIndex] (clamped) and broadcasts.
  /// Throws [ArgumentError] for an unknown id.
  void moveMediaItem(String mediaId, int toIndex) =>
      _server.moveMediaItem(mediaId, toIndex);

  /// Removes [mediaId] from the queue and broadcasts; removing the current
  /// item advances (see [JamHostServer.removeMediaItem]). Throws
  /// [ArgumentError] for an id not in the playlist.
  void removeMediaItem(String mediaId) {
    _server.removeMediaItem(mediaId);
    _syncAwaitingReadiness();
  }

  // --- Permissions & moderation (§5.6) ---------------------------------------

  /// Replaces the guest-role policy and broadcasts.
  void setPolicy(JamPolicy policy) => _server.setPolicy(policy);

  /// Promotes [peerId] to co-host and broadcasts.
  void promotePeer(String peerId) => _server.promotePeer(peerId);

  /// Demotes [peerId] back to guest and broadcasts.
  void demotePeer(String peerId) => _server.demotePeer(peerId);

  /// Sets (or clears, with `allowed: null`) one per-peer capability override
  /// and broadcasts.
  void setCapabilityOverride(
    String peerId,
    JamCapability capability, {
    required bool? allowed,
  }) => _server.setCapabilityOverride(peerId, capability, allowed: allowed);

  /// Kicks [peerId] from the session (§5.6): fatal `kicked` error, socket
  /// close, no resume, role forgotten — and the DEVICE stays out
  /// (`reject { reason: kicked }`) until [unkickPeer]. Throws
  /// [ArgumentError] if not joined.
  void kickPeer(String peerId) {
    _server.kickPeer(peerId);
    _kicked.value = _server.kickedPeers;
  }

  /// Devices kicked this session and not let back in (§5.6), as they were
  /// known when kicked (peerId then, display name).
  List<PeerInfo> get kickedPeers => _server.kickedPeers;

  /// [kickedPeers], listenable: changes on every kick and unkick, whoever
  /// made it (this engine, or a layer reaching the server directly).
  ValueListenable<List<PeerInfo>> get kickedPeersListenable => _kicked;

  /// Lets a device kicked earlier this session join again (§5.6). [peerId]
  /// is the id it had when kicked, as listed in [kickedPeers]. Returns
  /// whether there was such a device. It comes back through a fresh join of
  /// its own — nothing reconnects it automatically.
  bool unkickPeer(String peerId) {
    final found = _server.unkickPeer(peerId);
    _kicked.value = _server.kickedPeers;
    return found;
  }

  // --- Intents (host = direct mutation) -----------------------------------

  /// Runs one room mutation for an intent: false, instead of a throw, when
  /// the room has ended or the mutation was refused (no media selected, an
  /// id not in the queue).
  Future<bool> _intent(void Function() mutate) async {
    if (_closed) return false;
    try {
      mutate();
      return true;
    } on ArgumentError {
      return false;
    } on StateError {
      return false;
    }
  }

  /// Plays the room — unless it already is (or a start is already held by
  /// the readiness gate), which would only re-anchor every guest — and ends
  /// a local output suspension.
  @override
  Future<bool> transportPlay() async {
    if (_closed) return false;
    // This device asked to hear the room: wherever its sound goes now is
    // where it wants it, even if its headphones came out while paused.
    sync.acceptCurrentRoute();
    final played =
        snapshot.status == PlaybackStatus.playing ||
        isAwaitingReadiness ||
        await _intent(play);
    if (!_closed) await resumeLocalOutput();
    return played;
  }

  @override
  Future<bool> transportPause() => _intent(pause);

  @override
  Future<bool> transportNext() => _intent(next);

  @override
  Future<bool> transportPrevious() => _intent(previous);

  @override
  Future<bool> transportSeek(int positionUs) => _intent(() => seek(positionUs));

  @override
  Future<bool> transportSetMedia(String mediaId) =>
      _intent(() => setMedia(mediaId));

  @override
  Future<bool> queueMove(String mediaId, int toIndex) =>
      _intent(() => moveMediaItem(mediaId, toIndex));

  @override
  Future<bool> queueRemove(String mediaId) =>
      _intent(() => removeMediaItem(mediaId));

  // --- Event plumbing --------------------------------------------------------

  void _onHostEvent(JamHostEvent event) {
    switch (event.kind) {
      case JamHostEventKind.stateBroadcast:
        final snapshot = event.snapshot!;
        unawaited(sync.onSnapshot(snapshot));
        if (!_states.isClosed) _states.add(snapshot);
        // Paused in the background: iOS is about to suspend us (§3.5) — and
        // playing again: it is not. (The player catching up later — a track
        // finishing or starting — re-judges through trackFinished.)
        _reconsiderAway();
      case JamHostEventKind.playlistBroadcast:
        if (!_playlists.isClosed) _playlists.add(event.playlist!);
      case JamHostEventKind.peerMediaStatus:
        final progress = event.progress;
        if (event.mediaState == MediaFetchState.fetching && progress != null) {
          _fetchProgress[event.peerId!] = (
            mediaId: event.mediaId!,
            progress: progress,
          );
        } else {
          _fetchProgress.remove(event.peerId);
        }
      case JamHostEventKind.peerLeft:
        _fetchProgress.remove(event.peerId);
      case JamHostEventKind.mediaEnded:
        // The end policy's own state broadcast follows and drives the sync
        // controller; this stream just surfaces the moment.
        if (!_mediaEnded.isClosed) _mediaEnded.add(event.mediaId);
      case JamHostEventKind.mediaUploaded:
        final mediaId = event.mediaId!;
        // Stored by now: if the room had already picked this id (its bytes
        // first arrived another way), the host's player can load it.
        unawaited(sync.notifyMediaAvailable(mediaId));
        if (!_mediaUploads.isClosed) {
          _mediaUploads.add((mediaId: mediaId, peerId: event.peerId));
        }
      case JamHostEventKind.peerJoined:
      case JamHostEventKind.permissionsBroadcast:
      case JamHostEventKind.requestDenied:
        // Surfaced via permissionUpdates / the raw events stream.
        break;
    }
    // Any of these can start, release or make possible a readiness hold
    // (§6.3): a state broadcast (a release, or a skip that held the next
    // track), a fetch report, a fetching guest leaving.
    _syncAwaitingReadiness();
  }

  // --- App lifecycle, host availability (§3.5) ---------------------------------

  @override
  Future<void> onAppBackgrounded() async {
    await super.onAppBackgrounded();
    _backgrounded = true;
    await _updateAway();
  }

  /// Back in the foreground: tell guests the host is back (§3.5), make sure
  /// the listening socket survived the nap (the OS may reclaim a suspended
  /// app's sockets without a word), re-verify local playback, and re-scan
  /// the networks — the device may have changed Wi-Fi meanwhile.
  @override
  Future<void> onAppResumed() async {
    final wasBackgrounded = _backgrounded;
    _backgrounded = false;
    await _updateAway();
    // The probe can take its whole timeout on a dead socket; the host's own
    // audio is re-verified meanwhile rather than after it.
    final listener = wasBackgrounded ? _checkListener() : Future<void>.value();
    await super.onAppResumed();
    await listener;
    if (wasBackgrounded) unawaited(refreshLanAddresses());
  }

  /// Announces away exactly while the app is in the background in a state
  /// [backgroundSuspendPolicy] says the OS may suspend — so guests wait for
  /// a napping host instead of calling it dead (§3.5) — and back as soon as
  /// that stops being true.
  Future<void> _updateAway() async {
    if (_closed) return;
    final away = _backgrounded && backgroundSuspendPolicy(this);
    if (away == _server.isAway) return;
    _away.value = away;
    await _server.announceAway(away);
  }

  /// Re-judges [_updateAway] after anything the suspend policy reads
  /// changed — only in the background; the foreground is never away.
  void _reconsiderAway() {
    if (_backgrounded && !_closed) unawaited(_updateAway());
  }

  void _onTrackFinishedChanged() {
    if (!_backgrounded) return;
    // A natural end reaches here before the end-of-media report it also
    // triggers (§5.5) has advanced the room: judge once that has run.
    scheduleMicrotask(_reconsiderAway);
  }

  /// Watches the listening socket: when it dies underneath the live room,
  /// it is reopened once ([_repairListener]); after a successful reopen the
  /// new socket is watched in turn.
  void _watchListener() {
    final done = _server.listenerDone;
    unawaited(
      done.then((error) {
        if (_closed || error == null) return;
        // A deliberate restart retires the old future too; only the current
        // listener's death matters.
        if (!identical(done, _server.listenerDone)) return;
        unawaited(_repairListener(error));
      }),
    );
  }

  /// Asks the server whether it still accepts connections — cheap, a
  /// loopback round trip — and reopens the socket when it does not.
  Future<void> _checkListener() async {
    if (_closed) return;
    bool alive;
    try {
      alive = await listenerProber(_server);
    } catch (_) {
      alive = false;
    }
    if (!alive && !_closed) {
      await _repairListener(StateError('self-probe failed'));
    }
  }

  /// Reopens the listening socket on the same address and port, so the QR
  /// still works and dropped guests resume (§3.3). One attempt per death,
  /// shared by everyone who noticed it; when the port cannot be bound
  /// again the room is ended ([JamSessionEndReason.listenerFailed]).
  Future<void> _repairListener(Object why) {
    final inFlight = _repairing;
    if (inFlight != null) return inFlight;
    final repair = _reopenListener(why);
    _repairing = repair;
    unawaited(
      repair.whenComplete(() {
        if (identical(_repairing, repair)) _repairing = null;
      }),
    );
    return repair;
  }

  Future<void> _reopenListener(Object why) async {
    if (_closed) return;
    debugPrint('localjam: the room stopped listening ($why); reopening it');
    try {
      await listenerRestarter(_server);
    } catch (error) {
      debugPrint('localjam: could not reopen the room ($error); ending it');
      await _teardown(JamSessionEndReason.listenerFailed);
      return;
    }
    if (!_closed) _watchListener();
  }

  // --- Reachability (§1, §9) ----------------------------------------------------

  /// Re-scans the device's networks and, when the reachable LAN candidates
  /// changed, publishes a new [joinUri] (and [lanAddresses]) and refreshes
  /// the built-in mDNS responder's addresses; every scan also refreshes the
  /// cellular and tunnel addresses the room refuses connections on
  /// ([_nonLanLocals]). Runs every
  /// [addressRefreshInterval] ([noLanAddressRefreshInterval] while there is
  /// no LAN) and on resume; call it after anything the app knows changed the
  /// network. A scan that fails keeps the previous candidates — an unknown
  /// LAN is not an absent one. Concurrent calls share one scan.
  Future<void> refreshLanAddresses() {
    if (_closed) return Future<void>.value();
    final running = _refreshing;
    if (running != null) return running;
    final refresh = _refreshLan();
    _refreshing = refresh;
    return refresh.whenComplete(() {
      if (identical(_refreshing, refresh)) _refreshing = null;
    });
  }

  Future<void> _refreshLan() async {
    final scan = await _scanLan();
    if (_closed || !scan.enumerated) return;
    // Unconditionally, and before anything below awaits: a cellular link
    // that came up (or a Wi-Fi address that moved) counts from this scan on.
    _nonLanLocals
      ..clear()
      ..addAll(scan.nonLanLocals);
    final reachable = _reachableLan(_boundAddress, scan.addresses);
    // The same networks listed in another order are the same networks: a
    // reshuffled interface list must not churn the QR or the responder.
    final before = {for (final a in _lanAddresses.value) a.address};
    final after = {for (final a in reachable) a.address};
    final changed = !setEquals(before, after);
    if (changed) {
      _lanAddresses.value = List.unmodifiable(reachable);
      _joinUri.value = _buildCombinedJoinUri(_server, reachable);
    }
    if (changed || _readvertisePending) await _readvertise();
  }

  /// Re-arms the periodic re-scan, faster while there is no LAN at all.
  void _scheduleAddressRefresh() {
    _addressTimer?.cancel();
    if (_closed) return;
    _addressTimer = Timer(
      hasLanAddress ? addressRefreshInterval : noLanAddressRefreshInterval,
      () async {
        try {
          await refreshLanAddresses();
        } catch (error) {
          debugPrint('localjam: network re-scan failed ($error)');
        }
        _scheduleAddressRefresh();
      },
    );
  }

  /// The built-in responder answers with the addresses it was started with,
  /// so it is restarted with the new ones; the OS daemon follows interface
  /// changes by itself. A restart that fails leaves [_readvertisePending]
  /// set, and the next re-scan tries again — a failed restart must not leave
  /// the room undiscoverable for the rest of its life.
  Future<void> _readvertise() async {
    final current = _advertiser;
    if (current != null && current.transport != 'builtin') return;
    if (current == null && !_readvertisePending) return; // Never advertised.
    _advertiser = null;
    _readvertisePending = true;
    try {
      await current?.stop();
    } catch (error) {
      debugPrint('localjam: stopping the mDNS responder failed ($error)');
    }
    if (_closed) return;
    final next = await _bounded<JamRoomAdvertiser?>(
      roomAdvertiserStarter(
        sessionName: sessionName,
        port: port,
        token: token,
        addresses: _lanAddresses.value,
        timeout: _advertiseBudget,
      ),
      JamRoomAdvertiser.totalTimeout,
      () => null,
    );
    if (_closed) {
      await next?.stop();
      return;
    }
    _advertiser = next;
    _readvertisePending = next == null;
  }

  // --- Teardown ------------------------------------------------------------------

  /// Tears the session down: server, sockets, local playback.
  ///
  /// Session-end contract for guests: this is a DELIBERATE end, so the
  /// server says so (§3.4). Every guest is sent
  /// `session_ended { reason: host_ended }` and its socket is then closed
  /// with `normalClosure`; each guest engine publishes
  /// [JamSessionEndReason.hostEnded] on the spot — no "Reconnecting…"
  /// banner, no waiting out a host-gone timeout for a host that is never
  /// coming back. Guests fall silent and release their own guards too:
  /// the music was this room's, and the room is over.
  ///
  /// The server goes first, so that goodbye is sent whatever happens after
  /// it; every later step (advertiser, OS guards, audio) runs in its own
  /// try/catch so one failure cannot skip the rest.
  ///
  /// Silence still means the same thing it always did: a host that crashes,
  /// runs out of battery or leaves the network sends nothing, and guests
  /// fall back to [JamSessionEndReason.hostGone] after their timeout
  /// (PROTOCOL.md §10: host death ends the room).
  @override
  Future<void> close() async {
    await _teardown(JamSessionEndReason.closedLocally);
    if (_disposed) return;
    _disposed = true;
    _readinessPoll?.cancel();
    _readinessPoll = null;
    _away.dispose();
    _awaitingReadiness.dispose();
    _kicked.dispose();
    _lanAddresses.dispose();
    _joinUri.dispose();
    disposeEngineState();
  }

  /// Ends the room (once): publishes [reason], then releases everything but
  /// the listenables, which [close] disposes. Re-entrant: a [sessionEnded]
  /// listener that calls [close] gets the teardown already under way.
  Future<void> _teardown(JamSessionEndReason reason) {
    final running = _teardownDone;
    if (running != null) return running;
    final done = Completer<void>();
    _teardownDone = done.future;
    unawaited(
      _runTeardown(
        reason,
      ).then((_) {}, onError: (Object _) {}).whenComplete(done.complete),
    );
    return done.future;
  }

  Future<void> _runTeardown(JamSessionEndReason reason) async {
    _closed = true;
    publishSessionEnd(reason);
    _syncAwaitingReadiness(); // Nothing is held by a room that is over.
    _addressTimer?.cancel();
    _addressTimer = null;
    JamKeepAlive.active.removeListener(_reconsiderAway);
    sync.trackFinished.removeListener(_onTrackFinishedChanged);
    await _step('server', _server.close);
    await _step('advertiser', () async {
      final advertiser = _advertiser;
      _advertiser = null;
      await advertiser?.stop();
    });
    await _step('session guards', stopSessionGuards);
    await _step('subscriptions', () async {
      await _eventsSub?.cancel();
      _eventsSub = null;
      await _finishedSub?.cancel();
      _finishedSub = null;
      await _suspensionSub?.cancel();
      _suspensionSub = null;
      await _kickedSub?.cancel();
      _kickedSub = null;
    });
    await _step('sync', sync.dispose);
    // Native side may not be up (tests, stub platforms).
    await _step('player', player.dispose);
    await _step('streams', () async {
      await _states.close();
      await _playlists.close();
      await _mediaEnded.close();
      await _mediaUploads.close();
    });
  }

  static Future<void> _step(String what, Future<void> Function() run) async {
    try {
      await run();
    } catch (error) {
      debugPrint('localjam: closing the room: $what failed ($error)');
    }
  }
}
