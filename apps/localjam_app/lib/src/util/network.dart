/// Whether this device is on a network at all, and which one.
///
/// "Nothing nearby" means two opposite things on a trip: *you are on a network
/// and nobody is hosting* (start one) or *you are on no network at all* (turn
/// on a hotspot). Telling them apart is the difference between a session and a
/// dead end, so the empty states ask this rather than guessing.
///
/// Note the discovery caveat this exists to soften: mDNS is blocked on
/// hotspots and guest-isolated Wi-Fi, which is exactly the trip case — so a
/// device can be perfectly well connected and still see an empty nearby list.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:localjam_client/localjam_client.dart' show JoinLink;

/// A usable IPv4 attachment, or the absence of one.
@immutable
class JamNetworkStatus {
  const JamNetworkStatus({required this.addresses, required this.interface});

  /// Non-loopback IPv4 addresses this device holds.
  final List<String> addresses;

  /// The interface the first address sits on ("en0", "wlan0", "bridge100").
  final String? interface;

  /// Nothing to host or join over.
  static const JamNetworkStatus offline = JamNetworkStatus(
    addresses: [],
    interface: null,
  );

  /// Whether guests could reach a host on this device.
  bool get connected => addresses.isNotEmpty;

  /// The address to tell guests about, if any.
  String? get primaryAddress => addresses.isEmpty ? null : addresses.first;

  /// Whether this looks like a phone sharing its own hotspot. Apple bridges
  /// personal hotspots on `bridge*`, Android on `ap*`/`swlan*`/`rndis*` —
  /// worth knowing, because mDNS discovery does not cross a hotspot and the
  /// QR path becomes the only way in.
  bool get isHotspotHost {
    final name = interface;
    if (name == null) return false;
    return name.startsWith('bridge') ||
        name.startsWith('ap') ||
        name.startsWith('swlan') ||
        name.startsWith('rndis');
  }
}

/// Reads the current IPv4 attachment. Never throws — a locked-down system
/// that refuses the enumeration reads as offline.
Future<JamNetworkStatus> currentNetwork() async {
  try {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    final addresses = <String>[];
    String? name;
    for (final iface in interfaces) {
      for (final address in iface.addresses) {
        addresses.add(address.address);
        name ??= iface.name;
      }
    }
    return JamNetworkStatus(addresses: addresses, interface: name);
  } catch (_) {
    return JamNetworkStatus.offline;
  }
}

// --- Join-link safety --------------------------------------------------------

/// Whether [address] is an IP literal that can only mean "on this network":
/// RFC1918 private space, IPv4/IPv6 link-local, loopback, or an IPv6
/// unique-local address.
///
/// A `localjam://` link is a bare instruction to open a socket, and links
/// arrive from anywhere — a chat message, a web page, a QR sticker on a wall.
/// LocalJam is a LAN product by construction, so a link pointing at a routable
/// public address is never a jam; it is the app being used as someone else's
/// HTTP client. Hostnames are refused for the same reason: what a name
/// resolves to is not knowable from the link.
bool isLocalNetworkAddress(String address) {
  // A zone id (`fe80::1%en0`) names the interface, not the host, and is not
  // part of the address the rule is about — mDNS hands them out routinely.
  final trimmed = address.trim().split('%').first;
  if (trimmed.isEmpty) return false;
  final InternetAddress parsed;
  try {
    parsed = InternetAddress(trimmed);
  } catch (_) {
    return false; // Not an IP literal — a hostname could resolve anywhere.
  }
  if (parsed.isLoopback) return true;
  if (parsed.type == InternetAddressType.IPv4) {
    final octets = parsed.rawAddress;
    if (octets.length != 4) return false;
    final [a, b, ...] = octets;
    if (a == 10) return true; // 10.0.0.0/8
    if (a == 172 && b >= 16 && b <= 31) return true; // 172.16.0.0/12
    if (a == 192 && b == 168) return true; // 192.168.0.0/16
    if (a == 169 && b == 254) return true; // 169.254.0.0/16 link-local
    return false;
  }
  final bytes = parsed.rawAddress;
  if (bytes.length != 16) return false;
  if ((bytes[0] & 0xfe) == 0xfc) return true; // fc00::/7 unique-local
  if (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80) return true; // fe80::/10
  return false;
}

/// Resolves a host name to addresses. Injectable so tests never touch DNS.
typedef JamHostLookup = Future<List<InternetAddress>> Function(String host);

/// One `.local` label set: `phone.local`, `Bibeks-iPhone.local`.
final RegExp _mdnsName = RegExp(
  r'^([a-z0-9]([a-z0-9\-]{0,61}[a-z0-9])?\.)+local$',
);

/// Whether [host] — an IP literal *or* a name — can only mean "on this
/// network", resolving it when that is the only way to know.
///
/// The literal case is [isLocalNetworkAddress] and needs no network. A name
/// is refused outright, with one exception: `*.local` is multicast DNS, which
/// by definition only ever answers from the local link, and it is what mDNS
/// discovery and Apple platforms hand out. Even then the answer is checked —
/// a resolver can be lied to, and a `.local` name that comes back pointing at
/// a routable address is exactly the trick this gate exists to catch. Every
/// resolved address must be local; no addresses at all is a refusal, and so
/// is a lookup that throws.
Future<bool> isLocalNetworkHost(String host, {JamHostLookup? lookup}) async {
  final trimmed = host.trim();
  if (trimmed.isEmpty) return false;
  if (isLocalNetworkAddress(trimmed)) return true;
  // A literal that failed the rule stays failed — never resolved as a name.
  if (_isIpLiteral(trimmed)) return false;
  final name = trimmed.endsWith('.')
      ? trimmed.substring(0, trimmed.length - 1)
      : trimmed;
  if (name.length > 255 || !_mdnsName.hasMatch(name.toLowerCase())) {
    return false;
  }
  try {
    final resolved = await (lookup ?? InternetAddress.lookup)(name);
    return resolved.isNotEmpty &&
        resolved.every((a) => isLocalNetworkAddress(a.address));
  } catch (_) {
    return false; // Unresolvable is unvouchable.
  }
}

bool _isIpLiteral(String value) {
  try {
    InternetAddress(value.split('%').first);
    return true;
  } catch (_) {
    return false;
  }
}

/// The `host` candidates a join URI carries, in order — either form
/// (§1): `localjam://join?…` or the 1.2 `http://…/join#…`, whose own host is
/// the sole candidate when its fragment lists none. Empty when [uri] is not
/// a join link at all.
List<String> joinUriHosts(Uri uri) => JoinLink.fromUri(uri)?.hosts ?? const [];

/// The room name a join URI advertises, if any.
String? joinUriName(Uri uri) => JoinLink.fromUri(uri)?.displayName;

/// Whether every candidate in [uri] is a local-network address — the check a
/// link-sourced join must pass before it is offered to the user.
///
/// A URI with no candidates at all fails: there is nothing to vouch for.
bool joinUriIsLocalOnly(Uri uri) {
  final hosts = joinUriHosts(uri);
  return hosts.isNotEmpty && hosts.every(isLocalNetworkAddress);
}

/// [joinUriIsLocalOnly], with `*.local` names resolved and re-checked — the
/// gate every join passes through, whatever door it came in by. It lives in
/// `JamSessionController.join`, so scans, pastes, deep links and nearby
/// rooms all pass it and none of them can forget to.
///
/// Synchronous [joinUriIsLocalOnly] is the same rule minus the resolution: it
/// refuses every name, including the `.local` ones mDNS deals in, so it is a
/// pre-check and not the check.
Future<bool> joinUriIsLocalOnlyResolved(
  Uri uri, {
  JamHostLookup? lookup,
}) async {
  final hosts = joinUriHosts(uri);
  if (hosts.isEmpty) return false; // Nothing to vouch for.
  for (final host in hosts) {
    if (!await isLocalNetworkHost(host, lookup: lookup)) return false;
  }
  return true;
}

/// Parses text a user pasted, scanned or was deep-linked into a join URI —
/// either form (§1): `localjam://join?…` or the 1.2 `http://…/join#…` the
/// host's QR carries — or null when it is neither. Tolerates surrounding
/// whitespace and the wrapping some chat apps add ("<localjam://…>").
///
/// The one parser is [JoinLink]; this keeps the URI in the form it came in
/// (a guest's own invite shows what it was given). Whatever the form, the
/// on-LAN gate ([joinUriIsLocalOnlyResolved]) judges every candidate.
Uri? parseJoinUri(String text) {
  final link = JoinLink.parse(text);
  if (link == null) return null;
  return _schemeOf(text) == 'http' ? link.toHttpUri() : link.toLocaljamUri();
}

String _schemeOf(String text) {
  var raw = text.trim();
  if (raw.startsWith('<')) raw = raw.substring(1).trimLeft();
  final colon = raw.indexOf(':');
  return colon < 0 ? '' : raw.substring(0, colon).toLowerCase();
}
