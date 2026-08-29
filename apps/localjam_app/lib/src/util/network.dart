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
