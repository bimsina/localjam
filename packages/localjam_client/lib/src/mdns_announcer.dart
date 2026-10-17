/// A tiny, non-blocking mDNS announcer (RFC 6762 / RFC 6763) — enough of a
/// responder to make one hosted room discoverable, and nothing more.
///
/// This is the **fallback**, not the primary: [JamRoomAdvertiser] asks the
/// platform's Bonjour daemon first (mDNSResponder / NsdManager / Avahi),
/// which already owns port 5353, probes for name conflicts, and — on Apple
/// platforms — is the only responder that works without the
/// `com.apple.developer.networking.multicast` entitlement, since the packets
/// leave the daemon rather than the app. This announcer takes over only when
/// the daemon fails or does not confirm inside its budget, which on Apple is
/// a real possibility: `bonsoir_darwin` waits for `DNSServiceRegister` with a
/// synchronous `DNSServiceProcessResult` on the platform main thread, so a
/// daemon that never answers wedges the app rather than returning an error.
///
/// Everything here is asynchronous and silent: the socket is bound with a
/// deadline, every failure is swallowed, and the worst case is a room that is
/// QR-only.
///
/// Scope: announce `<instance>.<type>.local` (PTR + SRV + TXT + A) on the
/// multicast group, re-announce on the RFC 6762 §8.3 schedule, answer queries
/// for that name, and send goodbyes (TTL 0) on [MdnsAnnouncer.stop]. No
/// probing, no conflict resolution, no unicast-response handling — the
/// instance name already carries session-token entropy (see
/// `JamRoomAdvertiser.instanceNameFor`).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

/// The IPv4 mDNS group and port (RFC 6762 §3).
final InternetAddress mdnsGroupIPv4 = InternetAddress('224.0.0.251');
const int mdnsPort = 5353;

const int _typeA = 1;
const int _typePtr = 12;
const int _typeTxt = 16;
const int _typeSrv = 33;

/// Class IN, plus the cache-flush bit for the records only we own (§10.2).
const int _classIn = 1;
const int _classInFlush = 0x8001;

/// Every record is short-lived on purpose. RFC 6762 suggests 75 minutes for
/// a shared PTR, but a jam is a transient service and a host that is killed
/// (or crashes, or walks out of range) never gets to send its goodbye — with
/// a long TTL that room haunts every browser's cache for over an hour. Two
/// minutes means a ghost fades on its own, and the re-announce schedule below
/// keeps a live room from ever aging out.
const int _ttlPtr = 120;
const int _ttlHost = 120;

/// Hard cap on one announcement, comfortably inside a 1500-byte Ethernet
/// MTU. A room's record set is a PTR, an SRV, a TXT and a handful of A
/// records — nowhere near this — but the cap is what makes that a property
/// rather than a hope: A records are dropped until the packet fits, and a
/// set that still does not fit is not sent. Multicast is everyone's
/// bandwidth, and an oversized response is the half of an amplification
/// attack the responder controls.
const int maxAnnouncementBytes = 1400;

/// Minimum spacing between announcements (RFC 6762 §6 asks for at least one
/// second between multicast responses; this is also the amplification
/// limit).
const Duration minAnnounceInterval = Duration(seconds: 1);

/// Coalescing rate limit for outgoing announcements.
///
/// A responder that answers every query it hears is a packet amplifier: a
/// query costs the sender a few dozen bytes and costs the room a full record
/// set, multicast to every device on it, as fast as the queries arrive — and
/// the source address of a UDP query is worth nothing. So sends are spaced
/// by at least [minInterval], and requests arriving inside that window do
/// not queue: they collapse into the one send that happens when it closes.
/// That is also the right answer for the honest case, where a browser
/// starting up asks two or three times and one response covers all of it.
@visibleForTesting
class MdnsAnnounceThrottle {
  MdnsAnnounceThrottle({
    required this.send,
    this.minInterval = minAnnounceInterval,
  });

  /// Performs the actual send.
  final void Function() send;

  /// Minimum time between two [send] calls.
  final Duration minInterval;

  DateTime? _lastSend;
  Timer? _pending;

  /// Whether a coalesced send is waiting for the window to close.
  bool get hasPending => _pending != null;

  /// Sends now, or folds into the send already scheduled for the end of the
  /// current window.
  void request() {
    if (_pending != null) return; // Already coalesced into a pending send.
    final now = DateTime.now();
    final last = _lastSend;
    if (last == null || now.difference(last) >= minInterval) {
      _lastSend = now;
      send();
      return;
    }
    _pending = Timer(minInterval - now.difference(last), () {
      _pending = null;
      _lastSend = DateTime.now();
      send();
    });
  }

  /// Drops any pending send (nothing is flushed).
  void cancel() {
    _pending?.cancel();
    _pending = null;
  }
}

/// One advertised service. Create with [start]; release with [stop].
class MdnsAnnouncer {
  MdnsAnnouncer._(
    this._socket,
    this._instanceLabels,
    this._typeLabels,
    this._hostLabels,
    this._port,
    this._txt,
    this._addresses,
  );

  final RawDatagramSocket _socket;
  final List<String> _instanceLabels;
  final List<String> _typeLabels;
  final List<String> _hostLabels;
  final int _port;
  final Map<String, String> _txt;
  final List<InternetAddress> _addresses;

  Timer? _announceTimer;
  bool _stopped = false;

  late final MdnsAnnounceThrottle _throttle = MdnsAnnounceThrottle(send: _send);

  /// Binds the mDNS socket and starts announcing.
  ///
  /// [serviceName] is the human-readable instance name, [serviceType] the
  /// `_localjam._tcp` style type. [addresses] are the IPv4 addresses guests
  /// should reach this host on; when empty the announcement carries SRV/TXT
  /// only, which still resolves through the host name on most stacks.
  ///
  /// Returns null — never throws, never logs — when the platform will not let
  /// us have the socket: mDNS is a nicety, the join link is the contract, and
  /// a refused 5353 on a locked-down device is the normal case rather than an
  /// incident. Bounded by [timeout]; this is one bind and one sendto, so the
  /// budget is generous by construction.
  static Future<MdnsAnnouncer?> start({
    required String serviceName,
    required String serviceType,
    required int port,
    required Map<String, String> attributes,
    required List<InternetAddress> addresses,
    Duration timeout = const Duration(milliseconds: 300),
  }) async {
    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        mdnsPort,
        reuseAddress: true,
        // SO_REUSEPORT is what lets us share 5353 with the platform's own
        // responder, and Android's libc does not have it: the bind still
        // succeeds, but the VM logs `reusePort not supported on this
        // platform` at error level once per process — an alarming line for
        // a fallback path that worked. SO_REUSEADDR alone is enough there,
        // because Android's daemon binds 5353 with it too.
        reusePort: !Platform.isAndroid,
      ).timeout(timeout);
      socket.multicastHops = 255;
      // Receiving queries is what keeps a room discoverable for a browser
      // that starts after the announcements; a platform that refuses the
      // group (iOS without the multicast entitlement) still gets to send.
      try {
        socket.joinMulticast(mdnsGroupIPv4);
      } catch (_) {}

      final typeLabels = [
        ...serviceType.split('.').where((l) => l.isNotEmpty),
        'local',
      ];
      final announcer = MdnsAnnouncer._(
        socket,
        [serviceName, ...typeLabels],
        typeLabels,
        ['localjam-${_hostSuffix(port, serviceName)}', 'local'],
        port,
        attributes,
        [
          for (final a in addresses)
            if (a.type == InternetAddressType.IPv4) a,
        ],
      );
      socket.listen(
        announcer._onEvent,
        onError: (Object _) {},
        cancelOnError: false,
      );
      announcer._announce();
      // RFC 6762 §8.3: a couple of repeats, a second apart, then a slow
      // refresh so a browser started later still sees the room even if its
      // own query is lost.
      var burst = 0;
      announcer._announceTimer = Timer.periodic(const Duration(seconds: 1), (
        timer,
      ) {
        burst++;
        if (burst <= 2 || burst % 60 == 0) announcer._announce();
      });
      return announcer;
    } catch (_) {
      try {
        socket?.close();
      } catch (_) {}
      return null;
    }
  }

  /// A stable-ish per-room host label; uniqueness only has to hold within one
  /// LAN, and the port already differs per host process.
  static String _hostSuffix(int port, String name) =>
      '${port.toRadixString(16)}${name.hashCode.toUnsigned(16).toRadixString(16)}';

  void _onEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read || _stopped) return;
    final datagram = _socket.receive();
    if (datagram == null) return;
    // RFC 6762 §5.1: a multicast query is sent FROM port 5353. Anything from
    // an ephemeral port is a one-shot query (§5.4) — which wants a unicast
    // answer, not a multicast one — or a stray packet aimed at this socket,
    // and answering either with a full multicast record set is a reflection
    // the room does not owe anyone.
    //
    // The other half of the check is not available: `RawDatagramSocket`
    // reports a datagram's source, never its destination, so "was this even
    // addressed to the group?" cannot be asked here. The source port plus
    // the rate limit below is what is enforceable.
    if (datagram.port != mdnsPort) return;
    try {
      if (_asksForUs(datagram.data)) _announce();
    } catch (_) {
      // A malformed or unsupported packet is not our problem.
    }
  }

  /// Whether [packet] is a query naming this service, its type, or its host.
  bool _asksForUs(Uint8List packet) {
    if (packet.length < 12) return false;
    final flags = (packet[2] << 8) | packet[3];
    if (flags & 0x8000 != 0) return false; // A response, not a question.
    final questions = (packet[4] << 8) | packet[5];
    var offset = 12;
    final wanted = {
      _key(_instanceLabels),
      _key(_typeLabels),
      _key(_hostLabels),
      _key(const ['_services', '_dns-sd', '_udp', 'local']),
    };
    for (var i = 0; i < questions; i++) {
      final name = _readName(packet, offset);
      if (name == null) return false;
      offset = name.end + 4; // qtype + qclass
      if (offset > packet.length) return false;
      if (wanted.contains(name.key)) return true;
    }
    return false;
  }

  /// Requests an announcement, rate-limited and coalesced (see
  /// [MdnsAnnounceThrottle]) — the entry point for anything a *remote* can
  /// trigger, and for the re-announce schedule.
  void _announce() {
    if (_stopped) return;
    _throttle.request();
  }

  /// Sends the full record set for this service to the group, subject to
  /// [maxAnnouncementBytes]. Not rate-limited: [_announce] is the door.
  void _send({int ttlScale = 1}) {
    if (_stopped && ttlScale != 0) return;
    // A response that does not fit the cap sheds A records (SRV still names
    // the host, which most stacks resolve on their own) and, failing that,
    // is not sent at all.
    Uint8List? packet;
    for (var count = _addresses.length; count >= 0; count--) {
      final candidate = _buildAnnouncement(ttlScale, addressCount: count);
      if (candidate.length <= maxAnnouncementBytes) {
        packet = candidate;
        break;
      }
    }
    if (packet == null) return;
    try {
      _socket.send(packet, mdnsGroupIPv4, mdnsPort);
    } catch (_) {
      // Interface came and went; the next announcement can try again.
    }
  }

  Uint8List _buildAnnouncement(int ttlScale, {int? addressCount}) {
    final records = <_Record>[
      _Record(
        _typeLabels,
        _typePtr,
        _classIn,
        _ttlPtr * ttlScale,
        _encodeName(_instanceLabels),
      ),
      _Record(
        _instanceLabels,
        _typeSrv,
        _classInFlush,
        _ttlHost * ttlScale,
        _srvData(),
      ),
      _Record(
        _instanceLabels,
        _typeTxt,
        _classInFlush,
        _ttlPtr * ttlScale,
        _txtData(),
      ),
      for (final address in _addresses.take(addressCount ?? _addresses.length))
        _Record(
          _hostLabels,
          _typeA,
          _classInFlush,
          _ttlHost * ttlScale,
          Uint8List.fromList(address.rawAddress),
        ),
    ];
    final builder = BytesBuilder();
    builder.add(const [0, 0, 0x84, 0, 0, 0]); // id, flags (AA response), qd=0
    builder.add([records.length >> 8, records.length & 0xff]); // ancount
    builder.add(const [0, 0, 0, 0]); // nscount, arcount
    for (final record in records) {
      builder.add(_encodeName(record.labels));
      builder.add([
        record.type >> 8,
        record.type & 0xff,
        record.klass >> 8,
        record.klass & 0xff,
        (record.ttl >> 24) & 0xff,
        (record.ttl >> 16) & 0xff,
        (record.ttl >> 8) & 0xff,
        record.ttl & 0xff,
        record.data.length >> 8,
        record.data.length & 0xff,
      ]);
      builder.add(record.data);
    }
    return builder.toBytes();
  }

  Uint8List _srvData() {
    final target = _encodeName(_hostLabels);
    final out = Uint8List(6 + target.length);
    out[4] = _port >> 8;
    out[5] = _port & 0xff;
    out.setRange(6, out.length, target);
    return out;
  }

  Uint8List _txtData() {
    final builder = BytesBuilder();
    for (final entry in _txt.entries) {
      final pair = utf8.encode('${entry.key}=${entry.value}');
      if (pair.isEmpty || pair.length > 255) continue;
      builder.addByte(pair.length);
      builder.add(pair);
    }
    if (builder.length == 0) builder.addByte(0);
    return builder.toBytes();
  }

  /// Stops advertising: goodbye records (TTL 0, §10.1) then the socket.
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    _announceTimer?.cancel();
    _announceTimer = null;
    _throttle.cancel();
    try {
      // The goodbye is not rate-limited: it is the last packet, and a room
      // that skipped it would haunt every browser's cache until the TTL.
      _send(ttlScale: 0);
    } catch (_) {}
    try {
      _socket.close();
    } catch (_) {}
  }
}

class _Record {
  _Record(this.labels, this.type, this.klass, this.ttl, this.data);
  final List<String> labels;
  final int type;
  final int klass;
  final int ttl;
  final Uint8List data;
}

/// Wire form of a domain name: length-prefixed labels, a zero terminator, no
/// compression (legal everywhere, and a room's packet is tiny).
Uint8List encodeDnsName(List<String> labels) => _encodeName(labels);

Uint8List _encodeName(List<String> labels) {
  final builder = BytesBuilder();
  for (final label in labels) {
    final bytes = utf8.encode(label);
    final capped = bytes.length > 63 ? bytes.sublist(0, 63) : bytes;
    builder.addByte(capped.length);
    builder.add(capped);
  }
  builder.addByte(0);
  return builder.toBytes();
}

String _key(List<String> labels) => labels.join('.').toLowerCase();

/// A name read off the wire plus where the reader ended up (compression
/// pointers move the cursor without advancing past the pointer).
class _Name {
  _Name(this.key, this.labels, this.end);

  /// Lower-cased dotted form, for comparisons.
  final String key;

  /// The labels exactly as they came off the wire — a DNS-SD instance label
  /// may itself contain a dot ("DJ's Jam. 2"), so [key] cannot be split.
  final List<String> labels;

  final int end;
}

_Name? _readName(Uint8List packet, int start) {
  final labels = <String>[];
  var offset = start;
  var end = -1;
  var hops = 0;
  while (offset < packet.length) {
    final length = packet[offset];
    if (length == 0) {
      offset++;
      return _Name(
        labels.join('.').toLowerCase(),
        labels,
        end == -1 ? offset : end,
      );
    }
    if (length & 0xc0 == 0xc0) {
      if (offset + 1 >= packet.length || ++hops > 8) return null;
      if (end == -1) end = offset + 2;
      offset = ((length & 0x3f) << 8) | packet[offset + 1];
      continue;
    }
    if (offset + 1 + length > packet.length) return null;
    labels.add(
      const Utf8Codec(
        allowMalformed: true,
      ).decode(packet.sublist(offset + 1, offset + 1 + length)),
    );
    offset += 1 + length;
  }
  return null;
}

/// Parses a query packet's question names (testing seam for [_readName]).
List<String> parseDnsQuestions(Uint8List packet) {
  if (packet.length < 12) return const [];
  final questions = (packet[4] << 8) | packet[5];
  final names = <String>[];
  var offset = 12;
  for (var i = 0; i < questions; i++) {
    final name = _readName(packet, offset);
    if (name == null) break;
    names.add(name.key);
    offset = name.end + 4;
    if (offset > packet.length) break;
  }
  return names;
}

/// One `PTR` answer read off the wire: "this service type has this instance".
///
/// The two facts a browser needs from a periodic re-query — the instance is
/// still there ([ttl] > 0), or it has just left ([isGoodbye], RFC 6762 §10.1).
@immutable
class MdnsPtrAnswer {
  const MdnsPtrAnswer({
    required this.serviceType,
    required this.instanceName,
    required this.ttl,
  });

  /// The queried type, lower-cased and dotted (`_localjam._tcp.local`).
  final String serviceType;

  /// The instance label, in the case the responder sent it.
  final String instanceName;

  /// Record TTL in seconds; 0 is a goodbye.
  final int ttl;

  /// Whether this answer retires the instance rather than refreshing it.
  bool get isGoodbye => ttl == 0;

  @override
  String toString() => 'MdnsPtrAnswer($instanceName, $serviceType, ttl=$ttl)';
}

/// Reads the `PTR` answers out of an mDNS response packet. Questions are
/// skipped, non-PTR records are ignored, and a packet that stops making sense
/// simply ends the walk — everything on this socket is unauthenticated input.
List<MdnsPtrAnswer> parseMdnsPtrAnswers(Uint8List packet) {
  if (packet.length < 12) return const [];
  final flags = (packet[2] << 8) | packet[3];
  if (flags & 0x8000 == 0) return const []; // A question, not an answer.
  final questions = (packet[4] << 8) | packet[5];
  final answers = (packet[6] << 8) | packet[7];
  // Authority + additional records carry answers too on some responders, but
  // the answer section is the contract; stick to it.
  var offset = 12;
  for (var i = 0; i < questions; i++) {
    final name = _readName(packet, offset);
    if (name == null) return const [];
    offset = name.end + 4;
    if (offset > packet.length) return const [];
  }
  final out = <MdnsPtrAnswer>[];
  for (var i = 0; i < answers; i++) {
    final name = _readName(packet, offset);
    if (name == null) break;
    offset = name.end;
    if (offset + 10 > packet.length) break;
    final type = (packet[offset] << 8) | packet[offset + 1];
    final ttl =
        (packet[offset + 4] << 24) |
        (packet[offset + 5] << 16) |
        (packet[offset + 6] << 8) |
        packet[offset + 7];
    final rdLength = (packet[offset + 8] << 8) | packet[offset + 9];
    final rdStart = offset + 10;
    if (rdStart + rdLength > packet.length) break;
    if (type == _typePtr) {
      final target = _readName(packet, rdStart);
      // The instance label is the first one; the rest is the type it lives
      // under, which we already know from the owner name.
      if (target != null && target.labels.isNotEmpty) {
        out.add(
          MdnsPtrAnswer(
            serviceType: name.key,
            instanceName: target.labels.first,
            ttl: ttl,
          ),
        );
      }
    }
    offset = rdStart + rdLength;
  }
  return out;
}

/// Builds a one-shot `PTR` query for [serviceType] (`_localjam._tcp`).
///
/// The QU bit (RFC 6762 §5.4) is set: this querier lives on an ephemeral
/// port, so a unicast answer is both what responders should send and the only
/// one we can count on receiving.
@visibleForTesting
Uint8List buildPtrQuery(String serviceType) {
  final labels = [
    ...serviceType.split('.').where((l) => l.isNotEmpty),
    'local',
  ];
  final builder = BytesBuilder();
  builder.add(const [0, 0, 0, 0, 0, 1]); // id, flags (query), qdcount = 1
  builder.add(const [0, 0, 0, 0, 0, 0]); // an, ns, ar counts
  builder.add(_encodeName(labels));
  builder.add([_typePtr >> 8, _typePtr & 0xff, 0x80, 0x01]); // qtype, QU|IN
  return builder.toBytes();
}

/// Asks the LAN "who is still hosting?" — the other half of discovery.
///
/// Platform browsers are announcement-driven: `NsdManager` and `bonsoir` tell
/// you when a service appears, and are unreliable-to-silent about when it
/// goes away (a host that is force-quit, loses Wi-Fi, or is simply out of
/// range never sends the goodbye, and Android's own service-lost callback can
/// take minutes or never fire at all). A room that is only ever *added* to a
/// list stays in it forever. So [JamRoomBrowser] re-asks on a schedule and
/// keeps only what answers.
///
/// Deliberately tiny: one PTR question, and PTR answers back out. Addresses
/// and TXT still come from the platform resolver — this is a liveness signal,
/// not a second discovery stack.
class MdnsQuerier {
  MdnsQuerier._(this._socket, this._serviceType, this._typeKey);

  final RawDatagramSocket _socket;
  final String _serviceType;
  final String _typeKey;
  final StreamController<MdnsPtrAnswer> _answers =
      StreamController<MdnsPtrAnswer>.broadcast();
  bool _stopped = false;
  DateTime? _lastQuery;

  /// PTR answers for the queried type, as they arrive.
  Stream<MdnsPtrAnswer> get answers => _answers.stream;

  /// Binds an ephemeral-port querier, or returns null when the platform will
  /// not give us a socket. Never throws — a browser without a querier just
  /// falls back to the staleness deadline.
  ///
  /// Port 0, not 5353: a one-shot querier has no records to defend, and not
  /// contending for the responder port is what keeps this working next to the
  /// system daemon on every platform (and sidesteps Android's missing
  /// `SO_REUSEPORT` entirely).
  static Future<MdnsQuerier?> start({
    required String serviceType,
    Duration timeout = const Duration(milliseconds: 300),
  }) async {
    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        0,
        reuseAddress: true,
      ).timeout(timeout);
      socket.multicastHops = 255;
      // Responders that answer a QU query with a multicast response are
      // legal too, so join the group when the platform allows it.
      try {
        socket.joinMulticast(mdnsGroupIPv4);
      } catch (_) {}
      final typeKey = [
        ...serviceType.split('.').where((l) => l.isNotEmpty),
        'local',
      ].join('.').toLowerCase();
      final querier = MdnsQuerier._(socket, serviceType, typeKey);
      socket.listen(
        querier._onEvent,
        onError: (Object _) {},
        cancelOnError: false,
      );
      return querier;
    } catch (_) {
      try {
        socket?.close();
      } catch (_) {}
      return null;
    }
  }

  /// Sends a PTR question for the type, at most once per
  /// [minAnnounceInterval] (RFC 6762 §6 spacing — a querier is as capable of
  /// flooding a segment as a responder).
  void query() {
    if (_stopped) return;
    final now = DateTime.now();
    final last = _lastQuery;
    if (last != null && now.difference(last) < minAnnounceInterval) return;
    _lastQuery = now;
    try {
      _socket.send(buildPtrQuery(_serviceType), mdnsGroupIPv4, mdnsPort);
    } catch (_) {
      // Interface came and went; the next sweep tries again.
    }
  }

  void _onEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read || _stopped) return;
    final datagram = _socket.receive();
    if (datagram == null) return;
    try {
      for (final answer in parseMdnsPtrAnswers(datagram.data)) {
        if (answer.serviceType != _typeKey) continue;
        if (!_answers.isClosed) _answers.add(answer);
      }
    } catch (_) {
      // Malformed packet: not our problem.
    }
  }

  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    try {
      _socket.close();
    } catch (_) {}
    await _answers.close();
  }
}
