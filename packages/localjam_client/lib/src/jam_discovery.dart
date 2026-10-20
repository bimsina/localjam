/// Nearby-room discovery over mDNS/Bonjour (PROTOCOL.md §1 Discovery):
/// hosts advertise `_localjam._tcp` on the LAN, joiners browse and get
/// one-tap joinable rooms. QR/link stays the first-class path — mDNS is
/// blocked on hotspots, guest-isolated Wi-Fi, and (without the right
/// Info.plist entries) on Apple platforms — so everything here is
/// best-effort and never throws.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bonsoir/bonsoir.dart';
import 'package:flutter/foundation.dart';
// Only for `characters`: a name is cut between graphemes, never inside one.
import 'package:flutter/widgets.dart' show StringCharacters;
import 'package:localjam_net/localjam_net.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'mdns_announcer.dart';

/// The advertised service type (PROTOCOL.md §1).
const String jamServiceType = '_localjam._tcp';

/// The TXT key carrying the host's display name (PROTOCOL.md §1, added in
/// 1.1). Optional and display-only: a 1.0 joiner ignores it like any key it
/// does not know, and nothing here keys or trusts anything by it (§9).
const String jamHostNameTxtKey = 'hname';

/// The most UTF-8 bytes `hname` carries — a DNS label's worth, which keeps
/// the pair far inside a TXT string's 255 and a room's announcement well
/// inside [maxAnnouncementBytes].
const int jamHostNameTxtMaxBytes = 63;

/// Control characters, and runs of whitespace, in a name off the wire.
final RegExp _nameBreaks = RegExp(r'[\p{Cc}\s]+', unicode: true);

/// [name] as the `hname` TXT key carries it (PROTOCOL.md §1), or null when
/// nothing is left to carry.
///
/// Control characters and runs of whitespace become one space, the ends are
/// trimmed, and a name longer than [jamHostNameTxtMaxBytes] of UTF-8 is cut
/// after the last whole character (grapheme cluster) that fits, then trimmed
/// again. The host applies it before advertising and a joiner again to what
/// it reads: the record is unauthenticated (§9), so what arrives is held to
/// the same shape whoever sent it.
String? jamTxtHostName(String? name) {
  if (name == null) return null;
  var text = name.replaceAll(_nameBreaks, ' ').trim();
  if (utf8.encode(text).length > jamHostNameTxtMaxBytes) {
    final kept = StringBuffer();
    var bytes = 0;
    for (final character in text.characters) {
      bytes += utf8.encode(character).length;
      if (bytes > jamHostNameTxtMaxBytes) break;
      kept.write(character);
    }
    text = kept.toString().trimRight();
  }
  return text.isEmpty ? null : text;
}

/// One discoverable room on the local network, resolved to a joinable URI.
@immutable
class JamNearbyRoom {
  JamNearbyRoom({
    required this.key,
    required this.sessionName,
    required this.joinUri,
    this.hostName,
    DateTime? lastSeen,
  }) : lastSeen = lastSeen ?? DateTime.now();

  /// The mDNS instance name this entry was resolved from. Stable for one
  /// advertisement, but one room can be advertised under more than one
  /// (see [JamRoomBrowser]) — [identity] is the room's.
  final String key;

  /// The room's identity: its [token], which every advertisement of one room
  /// shares whatever instance name it went out under, or [key] for a record
  /// without one. What a list of rooms should key its rows by.
  String get identity => token ?? key;

  /// Human-readable room name.
  final String sessionName;

  /// The host's display name, from the record's `hname` (§1, 1.1) — null
  /// when the record has none (a 1.0 host, one hosting anonymously) or only
  /// blanks. Already in [jamTxtHostName]'s shape.
  ///
  /// Unauthenticated, like everything in an mDNS record (§9): anyone on the
  /// network can advertise any name. Text to show, never something to trust
  /// or to key anything by — and it is not part of [joinUri].
  final String? hostName;

  /// Ready-to-join `localjam://join?...` URI built from the resolved
  /// addresses and TXT attributes.
  final Uri joinUri;

  /// When this room was last *confirmed* — an announcement, a resolve, or a
  /// PTR answer to one of [JamRoomBrowser]'s re-queries. Not when it was
  /// first found: a room that stops answering ages out of the list
  /// ([JamRoomBrowser.staleAfter]) instead of sitting there forever.
  final DateTime lastSeen;

  /// The session token from the join URI — the room's identity across
  /// interfaces and across restarts of the browse (a host on Wi-Fi and a
  /// hotspot publishes two address lists and one token).
  String? get token {
    final token = joinUri.queryParameters['token'];
    return (token == null || token.isEmpty) ? null : token;
  }

  /// The `host:port` candidates a join would try, in order (§1).
  List<({String host, int port})> get candidates {
    final port = int.tryParse(joinUri.queryParameters['port'] ?? '');
    if (port == null) return const [];
    return [
      for (final host in (joinUri.queryParameters['host'] ?? '').split(','))
        if (host.isNotEmpty) (host: host, port: port),
    ];
  }

  JamNearbyRoom withLastSeen(DateTime at) => JamNearbyRoom(
    key: key,
    sessionName: sessionName,
    joinUri: joinUri,
    hostName: hostName,
    lastSeen: at,
  );

  @override
  String toString() =>
      'JamNearbyRoom($sessionName, $joinUri'
      '${hostName == null ? '' : ', hosted by $hostName'})';
}

/// Advertises one hosted room on the LAN. Created by [start]; stopped with
/// [stop]. A room advertised here is joinable by ANYONE on the network —
/// the TXT record carries the session token (possession of the LAN = the
/// invitation, exactly like being handed the QR; see PROTOCOL.md §9) —
/// which is why hosts opt in via `JamHostEngine.start(discoverable:)`.
class JamRoomAdvertiser {
  JamRoomAdvertiser._(this._broadcast, this._announcer)
    : _testTransport = null,
      _onStop = null;

  /// An advertiser with nothing on the wire, for tests that need to count
  /// starts and stops: it reports [transport] and runs [onStop] on [stop].
  @visibleForTesting
  JamRoomAdvertiser.fake({
    String transport = 'builtin',
    Future<void> Function()? onStop,
  }) : _broadcast = null,
       _announcer = null,
       _testTransport = transport,
       // ignore: prefer_initializing_formals
       _onStop = onStop;

  final BonsoirBroadcast? _broadcast;
  final MdnsAnnouncer? _announcer;
  final String? _testTransport;
  final Future<void> Function()? _onStop;

  /// How long a room start will wait for the system Bonjour daemon before
  /// giving up on it and falling back. Hosting must never be held hostage by
  /// mDNS.
  static const Duration defaultTimeout = Duration(milliseconds: 700);

  /// How long the built-in responder gets to bind its socket once the daemon
  /// path has been abandoned. It is a bind and two sendto calls, so this is
  /// generous.
  static const Duration fallbackTimeout = Duration(milliseconds: 300);

  /// The whole of [start], worst case: the daemon's budget, then the
  /// fallback's, plus slack for the hop between them. What a caller must
  /// allow if it wants advertising to actually get its chance.
  static const Duration totalTimeout = Duration(milliseconds: 1200);

  /// Which responder is carrying this advertisement — for diagnostics.
  /// `'bonjour'` when the OS daemon took it, `'builtin'` when our own
  /// responder did.
  String get transport =>
      _testTransport ?? (_broadcast != null ? 'bonjour' : 'builtin');

  /// Set once the platform side of `bonsoir` has stopped answering at all in
  /// this process.
  ///
  /// Upstream `bonsoir_darwin`'s `broadcast.start` handed `DNSServiceRegister`
  /// a callback and then waited for it with a **synchronous**
  /// `DNSServiceProcessResult` on the platform MAIN thread. Our `await` was
  /// rescued by the budget below, but the main thread was not: a daemon that
  /// never confirmed wedged the UI for good. The vendored plugin in
  /// `packages/third_party/bonsoir_darwin` schedules that read on a background
  /// queue instead, so the method call now always comes back — but a method
  /// call that still does not is the signature of a platform thread that has
  /// gone away, and one offence is all it gets. Every later room in this
  /// process then goes straight to [MdnsAnnouncer].
  ///
  /// A daemon that answers the call and simply never *confirms* the
  /// registration is a different thing, and does not set this: nothing is
  /// stuck, and the next room deserves its own try (the Local Network prompt
  /// the user has not answered yet is exactly that case).
  static bool _daemonWedged = false;

  /// Whether this process is an app running in an Apple **Simulator**, where
  /// the daemon accepts a registration and then never confirms it.
  ///
  /// `DNSServiceRegister` succeeds there and the daemon even puts a PTR on the
  /// wire, but the register reply never comes back. That used to be fatal:
  /// upstream waited for it with a synchronous `DNSServiceProcessResult`, and
  /// sampling a wedged app showed exactly where, on the thread that matters:
  ///
  /// ```text
  /// Thread_987308  DispatchQueue_1: com.apple.main-thread
  ///   … FlutterMethodChannel setMethodCallHandler _block_invoke
  ///     SwiftBonsoirPlugin.handle           SwiftBonsoirPlugin.swift:56
  ///       BonsoirServiceBroadcast.start()   BonsoirServiceBroadcast.swift:35
  ///         DNSServiceProcessResult → read_all → __recvfrom_nocancel
  /// ```
  ///
  /// No budget could rescue that: since Flutter merged the UI thread onto the
  /// platform thread on iOS, Dart *is* the main thread — the sample has no
  /// `io.flutter.1.ui` at all — so the blocked read stopped every timer in the
  /// isolate, `Future.timeout` included. The app did not get a slow room; it
  /// stopped existing.
  ///
  /// The vendored plugin reads that socket on a background queue, so the
  /// registration is now just unconfirmed rather than fatal, the budget below
  /// does what it says, and the built-in responder picks the room up. This
  /// flag survives only to explain that in the log.
  static final bool _appleSimulator = _detectAppleSimulator();

  static bool _detectAppleSimulator() {
    if (!Platform.isIOS && !Platform.isMacOS) return false;
    try {
      // A simulated app's bundle lives under the device's CoreSimulator
      // directory; `Platform.environment` is not a reliable signal here —
      // `SIMULATOR_UDID` and friends are set for the launcher, not for the
      // app process Dart runs in.
      return Platform.resolvedExecutable.contains('/CoreSimulator/Devices/') ||
          Platform.environment.containsKey('SIMULATOR_UDID');
    } catch (_) {
      return false;
    }
  }

  /// Prefs key holding "a Bonjour registration was started and never came
  /// back". See [_startDaemonBroadcast].
  static const String _daemonBreadcrumbKey = 'localjam.bonjourRegisterInFlight';

  /// Prefs, or null — bounded, because this sits on the way to a room.
  static Future<SharedPreferences?> _prefs() async {
    try {
      return await SharedPreferences.getInstance().timeout(_prefsBudget);
    } catch (_) {
      return null;
    }
  }

  static const Duration _prefsBudget = Duration(milliseconds: 150);

  /// Whether this process may hand a room to the platform's Bonjour daemon.
  ///
  /// The Simulator is no longer excluded: with the vendored plugin, asking
  /// there costs the budget below and nothing else.
  @visibleForTesting
  static bool get daemonRegistrationIsSafe => !_daemonWedged;

  /// Whether a previous [start] found the platform side of `bonsoir` not
  /// answering at all.
  @visibleForTesting
  static bool get daemonWedged => _daemonWedged;

  /// Puts the process-wide daemon state back; for tests.
  @visibleForTesting
  static void resetDaemonState() => _daemonWedged = false;

  /// Starts advertising; returns null when neither responder could (no mDNS
  /// implementation, missing OS permission, a socket the platform refuses,
  /// tests). Never throws: the QR/link path is always there.
  ///
  /// Order matters. The **system daemon** goes first, on every platform:
  /// mDNSResponder / NsdManager / Avahi already owns port 5353, probes for
  /// name conflicts, answers queries we never see, and — the part that
  /// decides it on Apple hardware — needs no
  /// `com.apple.developer.networking.multicast` entitlement, because the
  /// packets leave the daemon rather than the app. Our [MdnsAnnouncer] is
  /// the fallback for when the daemon does not answer inside [timeout]:
  /// correct enough to be found, but it sends its own multicast, which a
  /// real iOS device will not do unentitled.
  ///
  /// The instance name registered is [sessionName] plus a short suffix drawn
  /// from [token] — see [instanceNameFor]. Guests never see it (the room
  /// name they display comes from the `name` TXT attribute), and it means two
  /// hosts with the same room name, or a host restarted while the LAN still
  /// remembers its last registration, never collide. A collision is not
  /// cosmetic here: DNS-SD resolves it by probing and renaming, which delays
  /// the register confirmation that the Apple plugin is blocking the main
  /// thread to wait for.
  ///
  /// [hostName] is the host's display name, advertised as `hname`
  /// ([attributesFor]); null or blank leaves it out.
  static Future<JamRoomAdvertiser?> start({
    required String sessionName,
    required int port,
    required String token,
    String? hostName,
    List<InternetAddress> addresses = const [],
    Duration timeout = defaultTimeout,
  }) async {
    // One map for both responders, so the daemon and the fallback always
    // carry the same record.
    final attributes = attributesFor(
      sessionName: sessionName,
      token: token,
      hostName: hostName,
    );
    final instanceName = instanceNameFor(sessionName, token);
    final broadcast = await _startDaemonBroadcast(
      instanceName: instanceName,
      port: port,
      attributes: attributes,
      timeout: timeout,
    );
    if (broadcast != null) return JamRoomAdvertiser._(broadcast, null);

    final announcer = await MdnsAnnouncer.start(
      // Not the daemon's name: see [instanceNameFor]'s `builtin`.
      serviceName: instanceNameFor(sessionName, token, builtin: true),
      serviceType: jamServiceType,
      port: port,
      attributes: attributes,
      addresses: addresses,
      timeout: fallbackTimeout,
    );
    if (announcer == null) {
      debugPrint('localjam: mDNS advertising unavailable; room is QR-only.');
      return null;
    }
    debugPrint(
      'localjam: advertising "${instanceNameFor(sessionName, token, builtin: true)}" '
      'via the built-in responder '
      '(${_appleSimulator ? 'Apple Simulator: the daemon never confirms a '
                'registration there' : 'the OS daemon did not take it'}).',
    );
    return JamRoomAdvertiser._(null, announcer);
  }

  /// A room's TXT record (PROTOCOL.md §1): `v`, `name` and `token`, plus
  /// `hname` — [hostName] in [jamTxtHostName]'s shape — when there is a
  /// name to carry. Whatever advertises a room builds its record here.
  static Map<String, String> attributesFor({
    required String sessionName,
    required String token,
    String? hostName,
  }) {
    final host = jamTxtHostName(hostName);
    return {
      'v': '${MessageCodec.protocolVersion}',
      'name': sessionName,
      'token': token,
      jamHostNameTxtKey: ?host,
    };
  }

  /// The mDNS instance name for a room: the session name, trimmed to leave
  /// room, plus four hex digits of the session token. Purely a uniqueness
  /// device — the human-readable name travels in the `name` TXT attribute,
  /// which is what [JamRoomBrowser] displays.
  ///
  /// With [builtin] the name the built-in responder announces, which ends in
  /// `b` ("Van Jam 6537b") so it is never the name the OS daemon was asked
  /// to register. The daemon's registration is the one [start] gives up on
  /// before the fallback starts, and it does not always leave quietly: one
  /// still probing when the built-in responder announces the same name
  /// treats it as a conflict and auto-renames itself ("Van Jam 6537 (2)",
  /// one room listed twice), and the goodbye it sends on its way out names
  /// the very PTR record the fallback is announcing, so every browser drops
  /// the live room a few seconds after it appeared (both seen on the iOS 27
  /// Simulator). Under its own name the fallback shares neither.
  @visibleForTesting
  static String instanceNameFor(
    String sessionName,
    String token, {
    bool builtin = false,
  }) {
    // A DNS-SD instance label is at most 63 BYTES; room names are free-form
    // UTF-8, so trim on encoded length, not characters.
    const suffixBytes = 7; // ' ' + 4 hex + 'b' + one byte of headroom.
    var name = sessionName.trim();
    while (utf8.encode(name).length > 63 - suffixBytes) {
      name = name.substring(0, name.length - 1);
    }
    final hex = token.isEmpty
        ? '0000'
        : token.substring(0, token.length < 4 ? token.length : 4);
    final suffix = builtin ? '${hex}b' : hex;
    return name.isEmpty ? 'Jam $suffix' : '$name $suffix';
  }

  /// Registers with the platform Bonjour daemon, or returns null when it
  /// fails or outruns [timeout]. Never throws.
  ///
  /// [timeout] is the budget for the whole daemon path, not for each step:
  /// the method calls and the wait for confirmation share one deadline, so a
  /// slow registration cannot eat the fallback's slice of [totalTimeout].
  ///
  /// What counts as confirmation matters here. `broadcast.start()` returns as
  /// soon as the plugin has *asked* the daemon to register — that is the whole
  /// point of the vendored `bonsoir_darwin` — so it says nothing about whether
  /// the room is on the wire. `broadcastStarted` does, and it is what the
  /// daemon on an Apple Simulator never sends.
  static Future<BonsoirBroadcast?> _startDaemonBroadcast({
    required String instanceName,
    required int port,
    required Map<String, String> attributes,
    required Duration timeout,
  }) async {
    if (!daemonRegistrationIsSafe) return null;
    // A breadcrumb across process lifetimes, because the in-process latch
    // below can only be read by a process that survived. A platform thread
    // that stops answering takes the app with it, and the app that asked is
    // then unkillable-by-us dead. So the attempt is written down first: a run
    // that finds the note still there knows the last registration never
    // returned, and never asks again. Belt and braces now that the plugin
    // does not block, and cheap enough to keep.
    final prefs = await _prefs();
    if (prefs?.getBool(_daemonBreadcrumbKey) ?? false) {
      _daemonWedged = true;
      debugPrint(
        'localjam: a previous Bonjour registration never came back; '
        'advertising through the built-in responder from now on.',
      );
      return null;
    }
    try {
      await prefs?.setBool(_daemonBreadcrumbKey, true).timeout(_prefsBudget);
    } catch (_) {
      // No note is better than no room; the in-process latch still applies.
    }
    final deadline = DateTime.now().add(timeout);
    Duration remaining() {
      final left = deadline.difference(DateTime.now());
      return left.isNegative ? Duration.zero : left;
    }

    BonsoirBroadcast? broadcast;
    // The daemon's confirmation, once asked for — watched past a give-up too,
    // because a registration can still land after it ([_withdraw]).
    Future<BonsoirBroadcastEvent>? started;
    // Whether the platform side answered at all. Everything after this point
    // is a daemon that is merely slow or unwilling, not a wedged thread.
    var platformAnswered = false;
    try {
      broadcast = BonsoirBroadcast(
        service: BonsoirService(
          name: instanceName,
          type: jamServiceType,
          port: port,
          // No `host`: let the daemon advertise whatever hostname and
          // addresses it currently owns. Pinning one interface address here
          // is how a host disappears the moment Wi-Fi changes.
          attributes: attributes,
        ),
      );
      await broadcast.initialize().timeout(remaining());
      final events = broadcast.eventStream;
      if (events == null) {
        throw StateError('bonsoir produced no event stream');
      }
      // Subscribed BEFORE start, or the confirmation for a daemon that is
      // quick about it lands before anyone is listening.
      final confirmation = started = events.firstWhere(
        (event) => event is BonsoirBroadcastStartedEvent,
      );
      // It may end up unawaited (a failing start below); a broadcast that
      // errors or ends must not then reach the zone as an unhandled error.
      unawaited(confirmation.then((_) {}, onError: (Object _) {}));
      await broadcast.start().timeout(remaining());
      platformAnswered = true;
      unawaited(_clearBreadcrumb(prefs));
      await confirmation.timeout(remaining());
      return broadcast;
    } on TimeoutException {
      if (platformAnswered) {
        // Registered but not confirmed — the Simulator always, a device whose
        // Local Network prompt is still up, a LAN where Bonjour is filtered.
        // Nothing is stuck, so the next room gets its own try.
        debugPrint(
          'localjam: the Bonjour daemon took the registration but did not '
          'confirm it inside $timeout; falling back to the built-in '
          'responder.',
        );
      } else {
        // The method channel itself never came back: the platform thread is
        // gone. Do not ask twice, and leave the breadcrumb for the next run.
        _daemonWedged = true;
        debugPrint(
          'localjam: the bonsoir platform channel did not answer inside '
          '$timeout; advertising through the built-in responder from now on.',
        );
      }
      unawaited(_withdraw(broadcast, confirmed: started));
      return null;
    } catch (error) {
      // The daemon answered — it just said no. Nothing was left in flight, so
      // the breadcrumb comes back off.
      unawaited(_clearBreadcrumb(prefs));
      debugPrint(
        'localjam: Bonjour registration failed ($error); '
        'falling back to the built-in responder.',
      );
      unawaited(_withdraw(broadcast, confirmed: started));
      return null;
    }
  }

  /// How long an abandoned registration is watched for a late confirmation.
  /// A slow daemon (an emulator, a busy phone) can take seconds; one that has
  /// not answered in this long is not going to.
  @visibleForTesting
  static Duration lateConfirmationWindow = const Duration(minutes: 2);

  /// Takes back a registration this process gave up waiting for.
  ///
  /// A stop sent while the registration is still in flight is not enough on
  /// every platform: Android's `NsdManager` (through bonsoir) only
  /// unregisters what it has already confirmed, so a stop that overtakes the
  /// confirmation is dropped, the confirmation lands anyway, and the room
  /// stays on the network after it has closed — this device even lists its
  /// own ended jam under Nearby. So the stop is sent now (enough where the
  /// daemon honours it) and sent again if [confirmed] arrives late.
  static Future<void> _withdraw(
    BonsoirBroadcast? broadcast, {
    Future<BonsoirBroadcastEvent>? confirmed,
  }) async {
    if (broadcast == null) return;
    await _stopQuietly(broadcast);
    if (confirmed == null) return;
    try {
      await confirmed.timeout(lateConfirmationWindow);
    } catch (_) {
      return; // Never confirmed: nothing went on the wire.
    }
    debugPrint(
      'localjam: an abandoned Bonjour registration was confirmed late; '
      'withdrawing it.',
    );
    await _stopQuietly(broadcast);
  }

  static Future<void> _clearBreadcrumb(SharedPreferences? prefs) async {
    try {
      await prefs?.remove(_daemonBreadcrumbKey);
    } catch (_) {}
  }

  static Future<void> _stopQuietly(BonsoirBroadcast? broadcast) async {
    try {
      await broadcast?.stop();
    } catch (_) {
      // Never started, or the platform is gone.
    }
  }

  Future<void> stop() async {
    await _onStop?.call();
    await _announcer?.stop();
    await _stopQuietly(_broadcast);
  }
}

/// Browses the LAN for advertised rooms. Create, [start], read/watch
/// [rooms], [stop].
///
/// **Discovery is not the same problem as un-discovery.** Every platform
/// browser is announcement-driven and generous about arrivals: bonsoir's
/// service-found/resolved events (and the `NsdManager` / `mDNSResponder`
/// callbacks underneath them) fire the moment a room appears. Departures are
/// the unreliable half — the host has to *send* a goodbye for a
/// service-lost event to exist at all, and a host that is force-quit, walks
/// out of range, loses Wi-Fi or has its process killed by the OS sends
/// nothing. Worse, both platform daemons cache what they have heard across
/// our process lifetime, so a relaunched app is handed the ghosts again on
/// its first browse and never hears them leave.
///
/// So arrivals are trusted and presence is verified. Every entry carries a
/// [JamNearbyRoom.lastSeen]; every [sweepInterval] the browser re-resolves
/// what it holds through the platform and sends its own PTR query
/// ([MdnsQuerier]); anything not confirmed within [staleAfter] — two record
/// TTLs — is dropped. A goodbye, when one does arrive, is still honoured
/// immediately.
///
/// **One room, one row.** A room is its token, not its mDNS instance name,
/// and the same room can be on the wire under two names at once: the OS
/// daemon auto-renames a registration whose name another responder already
/// answers for ("Van Jam 6537 (2)" — a registration the host had given up
/// on, meeting the built-in responder that took over), and a re-advertise
/// can go out under a new name while the old one is still cached. So every
/// instance is tracked, but [rooms] lists one per token: the advertisement
/// that arrived last, which is the one carrying the host's current
/// addresses. A goodbye from that newest one hides the room's older ones
/// until one of them is confirmed again — a re-query is sent at once — so
/// the instance a re-advertise left behind cannot resurface as a ghost of a
/// room that just left.
class JamRoomBrowser {
  JamRoomBrowser({
    Duration? staleAfter,
    Duration? sweepInterval,
    Duration? probeTimeout,
  }) : staleAfter = staleAfter ?? defaultStaleAfter,
       sweepInterval = sweepInterval ?? defaultSweepInterval,
       probeTimeout = probeTimeout ?? defaultProbeTimeout,
       _clock = DateTime.now,
       _events = null,
       _answers = null,
       _connect = _tcpConnect;

  /// A browser wired to injected event sources instead of the platform —
  /// bonsoir discovery events, PTR answers, a clock and a TCP probe. Lets the
  /// staleness policy be tested without a network.
  @visibleForTesting
  JamRoomBrowser.withSources({
    required Stream<BonsoirDiscoveryEvent> events,
    Stream<MdnsPtrAnswer>? answers,
    DateTime Function()? clock,
    Future<bool> Function(String host, int port, Duration timeout)? connect,
    Duration? staleAfter,
    Duration? sweepInterval,
    Duration? probeTimeout,
  }) : staleAfter = staleAfter ?? defaultStaleAfter,
       sweepInterval = sweepInterval ?? defaultSweepInterval,
       probeTimeout = probeTimeout ?? defaultProbeTimeout,
       _clock = clock ?? DateTime.now,
       // ignore: prefer_initializing_formals
       _events = events,
       // ignore: prefer_initializing_formals
       _answers = answers,
       _connect = connect ?? _tcpConnect;

  /// The PTR TTL the built-in responder advertises (`mdns_announcer.dart`),
  /// and what the platform daemons use for a service like this one.
  static const Duration recordTtl = Duration(seconds: 120);

  /// How long a room may go unconfirmed before it is dropped: two TTLs, so a
  /// single lost re-announcement or a dropped query never blinks a live room
  /// out of the list.
  static const Duration defaultStaleAfter = Duration(seconds: 240);

  /// How often presence is re-verified. Cheap — one PTR question and a
  /// re-resolve per known room.
  static const Duration defaultSweepInterval = Duration(seconds: 20);

  /// How long [probe] waits for a TCP handshake before calling a candidate
  /// dead. A LAN connect is single-digit milliseconds; this is the budget for
  /// a host that has gone away without saying so, and it sits on a tap.
  static const Duration defaultProbeTimeout = Duration(milliseconds: 900);

  /// Currently visible resolved rooms, updated in place (the list instance
  /// is replaced on every change, so listeners can compare identity).
  final ValueNotifier<List<JamNearbyRoom>> rooms =
      ValueNotifier<List<JamNearbyRoom>>(const []);

  /// See [defaultStaleAfter].
  final Duration staleAfter;

  /// See [defaultSweepInterval].
  final Duration sweepInterval;

  /// See [defaultProbeTimeout].
  final Duration probeTimeout;

  final DateTime Function() _clock;
  final Stream<BonsoirDiscoveryEvent>? _events;
  final Stream<MdnsPtrAnswer>? _answers;
  final Future<bool> Function(String host, int port, Duration timeout) _connect;

  BonsoirDiscovery? _discovery;
  StreamSubscription<BonsoirDiscoveryEvent>? _sub;
  StreamSubscription<MdnsPtrAnswer>? _answerSub;
  MdnsQuerier? _querier;
  Timer? _sweepTimer;
  final Map<String, JamNearbyRoom> _byKey = {};

  /// The last resolved service per key, so a sweep can ask the platform to
  /// resolve it again — a resolve that succeeds is a room that is still
  /// there.
  final Map<String, BonsoirService> _services = {};

  /// A counter that orders everything below: arrivals, confirmations and
  /// goodbyes. A clock cannot — two events often share an instant.
  int _seq = 0;

  /// key → when that instance entered [_byKey] ([_seq]). The newest arrival
  /// is the advertisement a room's row shows.
  final Map<String, int> _arrived = {};

  /// key → when that instance was last confirmed ([_seq]).
  final Map<String, int> _confirmed = {};

  /// token → when a goodbye (or a lost event) last retired one of that
  /// room's instances ([_seq]). The room's other instances stay hidden
  /// until confirmed after it.
  final Map<String, int> _retired = {};

  String? _excludedToken;
  bool _started = false;
  bool _disposed = false;

  /// Whether the browser is currently running. Stays false when the
  /// platform has no mDNS support (start is best-effort).
  bool get running => _discovery != null || (_started && _events != null);

  /// The session token of the room this device is *in*, which is never a
  /// room it can join.
  ///
  /// A host discovers its own advertisement (its own daemon answers its own
  /// browse), and so does a guest whose host is on the same segment. Filtered
  /// here rather than in the UI so every consumer gets it — and by token,
  /// because the token is the room's identity across interfaces, while the
  /// join URI differs per address list.
  String? get excludedToken => _excludedToken;

  set excludedToken(String? token) {
    final next = (token == null || token.isEmpty) ? null : token;
    if (next == _excludedToken) return;
    _excludedToken = next;
    _publish();
  }

  Future<void> start() async {
    if (_disposed || _started) return;
    _started = true;
    final injected = _events;
    if (injected != null) {
      _sub = injected.listen(
        (event) => _onEvent(event),
        onError: (Object _) {},
      );
      _listenForAnswers(_answers);
      _startSweeping();
      return;
    }
    try {
      final discovery = BonsoirDiscovery(type: jamServiceType);
      await discovery.initialize();
      _sub = discovery.eventStream?.listen(
        (event) => _onEvent(event),
        onError: (Object _) {},
      );
      await discovery.start();
      _discovery = discovery;
    } catch (error) {
      debugPrint('localjam: nearby-room browsing unavailable ($error).');
      unawaited(_sub?.cancel());
      _sub = null;
      _discovery = null; // Best-effort: nearby list just stays empty.
    }
    // The querier runs even when bonsoir did not start: its PTR answers
    // cannot fill the list (no TXT, no addresses) but they are what expires
    // one, and a browser that only ever adds is the bug this exists for.
    _querier ??= await MdnsQuerier.start(serviceType: jamServiceType);
    if (_disposed) {
      await _querier?.stop();
      _querier = null;
      return;
    }
    _listenForAnswers(_querier?.answers);
    _startSweeping();
    _querier?.query();
  }

  void _listenForAnswers(Stream<MdnsPtrAnswer>? answers) {
    if (answers == null) return;
    _answerSub = answers.listen(_onAnswer, onError: (Object _) {});
  }

  void _startSweeping() {
    _sweepTimer?.cancel();
    _sweepTimer = Timer.periodic(sweepInterval, (_) => sweep());
  }

  /// One round of presence verification: expire what has gone quiet, then ask
  /// everything that is left to prove it is still there. Runs on
  /// [sweepInterval]; exposed so tests (and an app that wants a pull-to-
  /// refresh) can drive it directly.
  void sweep() {
    if (_disposed) return;
    final cutoff = _clock().subtract(staleAfter);
    final expired = [
      for (final entry in _byKey.entries)
        if (entry.value.lastSeen.isBefore(cutoff)) entry.key,
    ];
    expired.forEach(_drop);
    if (expired.isNotEmpty) _publish();
    // Re-resolving is how the platform half of this gets re-confirmed: a
    // resolve that succeeds lands as a resolved event and refreshes lastSeen,
    // one that fails is silent and lets the deadline do its work.
    final discovery = _discovery;
    if (discovery != null) {
      for (final service in _services.values.toList()) {
        try {
          discovery.serviceResolver.resolveService(service);
        } catch (_) {}
      }
    }
    _querier?.query();
  }

  void _onEvent(BonsoirDiscoveryEvent event) {
    switch (event) {
      case BonsoirDiscoveryServiceFoundEvent(:final service):
        // Resolution fills in host addresses; failures surface as a
        // resolve-failed event, which we simply ignore.
        try {
          _discovery?.serviceResolver.resolveService(service);
        } catch (_) {}
      case BonsoirDiscoveryServiceResolvedEvent(:final service):
      case BonsoirDiscoveryServiceUpdatedEvent(:final service):
        final room = _roomFrom(service, _clock());
        if (room == null) {
          _drop(service.name);
        } else {
          _confirm(room, service);
        }
        _publish();
      case BonsoirDiscoveryServiceLostEvent(:final service):
        _retire(service.name);
        _publish();
      default:
        break;
    }
  }

  /// A PTR answer from our own re-query: a live record refreshes the entry it
  /// names, a goodbye (TTL 0, RFC 6762 §10.1) retires it at once.
  ///
  /// A PTR alone can never *add* a room — it carries no token and no address,
  /// and this browser only ever offers records it could check (§9).
  void _onAnswer(MdnsPtrAnswer answer) {
    if (_disposed) return;
    final key = _keyFor(answer.instanceName);
    if (key == null) return;
    if (answer.isGoodbye) {
      _retire(key);
      _publish();
      return;
    }
    _touch(key);
  }

  /// Matches a wire instance label to a held key. DNS names are
  /// case-insensitive, and responders are free to change the case.
  String? _keyFor(String instanceName) {
    if (_byKey.containsKey(instanceName)) return instanceName;
    final wanted = instanceName.toLowerCase();
    for (final key in _byKey.keys) {
      if (key.toLowerCase() == wanted) return key;
    }
    return null;
  }

  void _touch(String key) {
    final room = _byKey[key];
    if (room == null) return;
    _confirmed[key] = ++_seq;
    _byKey[key] = room.withLastSeen(_clock());
    _publish();
  }

  /// Records [room] as just resolved: a new instance arrives, a known one is
  /// confirmed (and keeps its place in the arrival order).
  void _confirm(JamNearbyRoom room, BonsoirService service) {
    _seq++;
    _arrived.putIfAbsent(room.key, () => _seq);
    _confirmed[room.key] = _seq;
    _byKey[room.key] = room;
    _services[room.key] = service;
  }

  /// Forgets one instance. Other instances of its room are untouched.
  JamNearbyRoom? _drop(String key) {
    _services.remove(key);
    _arrived.remove(key);
    _confirmed.remove(key);
    final room = _byKey.remove(key);
    final token = room?.token;
    if (token != null && !_byKey.values.any((r) => r.token == token)) {
      _retired.remove(token);
    }
    return room;
  }

  /// [key] has left — a goodbye, a lost event, a probe that found nobody.
  ///
  /// When it was its room's newest advertisement, every older one of the
  /// room is hidden too until it is confirmed again (what a re-advertise
  /// left behind is a ghost until it proves otherwise), and the survivors
  /// are asked to prove it right away. An older advertisement leaving
  /// changes nothing for a newer one: the room re-advertised after it.
  void _retire(String key) {
    final arrived = _arrived[key] ?? 0;
    final room = _drop(key);
    final token = room?.token;
    if (token == null) return;
    final survivors = [
      for (final entry in _byKey.entries)
        if (entry.value.token == token) entry.key,
    ];
    if (survivors.isEmpty) return;
    if (survivors.any((k) => (_arrived[k] ?? 0) > arrived)) return;
    _retired[token] = ++_seq;
    final discovery = _discovery;
    if (discovery != null) {
      for (final survivor in survivors) {
        final service = _services[survivor];
        if (service == null) continue;
        try {
          discovery.serviceResolver.resolveService(service);
        } catch (_) {}
      }
    }
    _querier?.query();
  }

  // --- Verify and prune (the app's half) --------------------------------

  /// Whether [room] actually answers right now: a TCP connect to each join
  /// candidate in turn, [probeTimeout] each, closed immediately.
  ///
  /// mDNS says a room *was* advertised; only a socket says it is there. Call
  /// this before joining (on the tap, behind the spinner the join already
  /// shows) so a ghost fails in a tenth of a second with a reason, instead of
  /// as a join timeout. A room that answers has its [JamNearbyRoom.lastSeen]
  /// refreshed; one that does not is left in place for the caller to
  /// [remove] — probing is a question, not a policy.
  Future<bool> probe(JamNearbyRoom room, {Duration? timeout}) async {
    final budget = timeout ?? probeTimeout;
    for (final candidate in room.candidates) {
      if (_disposed) return false;
      if (await _connect(candidate.host, candidate.port, budget)) {
        _touch(room.key);
        return true;
      }
    }
    return false;
  }

  /// Drops [room] from the list. For the app to call when a [probe] or a join
  /// proved it dead — the record can outlive the room by two TTLs, and a user
  /// who has just been told "that jam has ended" should not still see it.
  ///
  /// The room goes as a whole: another advertisement of it (same token,
  /// another instance name) stays hidden until it is confirmed again.
  void remove(JamNearbyRoom room) {
    if (!_byKey.containsKey(room.key)) return;
    _retire(room.key);
    _publish();
  }

  /// Forgets the one instance named [key], whatever else its room is
  /// advertised as.
  void removeKey(String key) {
    if (_drop(key) == null) return;
    _publish();
  }

  static Future<bool> _tcpConnect(
    String host,
    int port,
    Duration timeout,
  ) async {
    Socket? socket;
    try {
      // A zone id (`fe80::1%en0`) is not something `Socket.connect` accepts on
      // every platform; the candidate list is ordered IPv4-first precisely so
      // this is the rare path.
      socket = await Socket.connect(host, port, timeout: timeout);
      return true;
    } catch (_) {
      return false;
    } finally {
      try {
        socket?.destroy();
      } catch (_) {}
    }
  }

  /// Builds a joinable room from a resolved service; null when the record
  /// is unusable (no addresses, no token — e.g. a future version that
  /// stops advertising tokens).
  @visibleForTesting
  static JamNearbyRoom? roomFromService(BonsoirService service) =>
      _roomFrom(service, DateTime.now());

  /// Whether a resolved mDNS address is one a room may live on (§9).
  ///
  /// mDNS records are unauthenticated: anyone on the segment can answer, and
  /// a `_localjam._tcp` record whose A record points at a public address
  /// turns every browsing app on the network into a client of that address.
  /// So candidates are held to the same LAN rule the host enforces on its
  /// own remotes — a zone suffix (`fe80::1%en0`) is stripped for the test and
  /// kept in the candidate.
  static bool _isLocalCandidate(String address) {
    try {
      return JamHostServer.isLanAddress(
        InternetAddress(address.split('%').first),
      );
    } catch (_) {
      return false; // Not an IP literal at all.
    }
  }

  static JamNearbyRoom? _roomFrom(BonsoirService service, DateTime seenAt) {
    final token = service.attributes['token'];
    // Guests try candidates in order (§1): put IPv4 first — link-local IPv6
    // (`fe80::…%en0`) often resolves first on Apple platforms but zone-id
    // URIs are unreliable, so leading with them just burns connect timeouts.
    //
    // Only the numeric addresses mDNS actually resolved are offered, and only
    // the local ones. The SRV hostname used to ride along as a last-resort
    // candidate, but a name is a promise about what some resolver will return
    // later — and a discovery path that hands the join layer something it
    // cannot check has decided nothing. A record with no usable address is
    // simply not a joinable room.
    final hosts = [
      for (final a in service.hostAddresses)
        if (!a.contains(':') && _isLocalCandidate(a)) a, // IPv4 first…
      for (final a in service.hostAddresses)
        if (a.contains(':') && _isLocalCandidate(a))
          a, // …then IPv6, each keeping resolved order.
    ];
    if (token == null || token.isEmpty || hosts.isEmpty) return null;
    final sessionName = service.attributes['name'] ?? service.name;
    return JamNearbyRoom(
      key: service.name,
      sessionName: sessionName,
      // Display only (§9), held to the shape a host sends whatever arrived;
      // every other key this browser does not know is ignored.
      hostName: jamTxtHostName(service.attributes[jamHostNameTxtKey]),
      lastSeen: seenAt,
      joinUri: Uri(
        scheme: 'localjam',
        host: 'join',
        queryParameters: {
          'v': service.attributes['v'] ?? '${MessageCodec.protocolVersion}',
          'host': hosts.join(','),
          'port': '${service.port}',
          'token': token,
          'name': sessionName,
        },
      ),
    );
  }

  /// One row per room ([JamNearbyRoom.identity]): of its instances that are
  /// not hidden behind a goodbye, the one that arrived last.
  void _publish() {
    if (_disposed) return;
    final excluded = _excludedToken;
    final shown = <String, JamNearbyRoom>{};
    final shownArrival = <String, int>{};
    for (final MapEntry(:key, value: room) in _byKey.entries) {
      final token = room.token;
      if (excluded != null && token == excluded) continue;
      final retired = token == null ? null : _retired[token];
      if (retired != null && (_confirmed[key] ?? 0) <= retired) continue;
      final arrived = _arrived[key] ?? 0;
      final id = room.identity;
      if ((shownArrival[id] ?? -1) < arrived) {
        shown[id] = room;
        shownArrival[id] = arrived;
      }
    }
    final sorted = shown.values.toList()
      ..sort((a, b) {
        final byName = a.sessionName.compareTo(b.sessionName);
        return byName != 0 ? byName : a.identity.compareTo(b.identity);
      });
    rooms.value = List.unmodifiable(sorted);
  }

  Future<void> stop() async {
    _disposed = true;
    _sweepTimer?.cancel();
    _sweepTimer = null;
    unawaited(_sub?.cancel());
    _sub = null;
    unawaited(_answerSub?.cancel());
    _answerSub = null;
    final querier = _querier;
    _querier = null;
    await querier?.stop();
    try {
      await _discovery?.stop();
    } catch (_) {}
    _discovery = null;
    _byKey.clear();
    _services.clear();
    _arrived.clear();
    _confirmed.clear();
    _retired.clear();
    rooms.dispose();
  }
}
