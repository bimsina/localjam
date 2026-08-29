/// Nearby-room discovery over mDNS/Bonjour (PROTOCOL.md §1 Discovery):
/// hosts advertise `_localjam._tcp` on the LAN, joiners browse and get
/// one-tap joinable rooms. QR/link stays the first-class path — mDNS is
/// blocked on hotspots, guest-isolated Wi-Fi, and (without the right
/// Info.plist entries) on Apple platforms — so everything here is
/// best-effort and never throws.
library;

import 'dart:async';

import 'package:bonsoir/bonsoir.dart';
import 'package:flutter/foundation.dart';
import 'package:localjam_net/localjam_net.dart';

/// The advertised service type (PROTOCOL.md §1).
const String jamServiceType = '_localjam._tcp';

/// One discoverable room on the local network, resolved to a joinable URI.
@immutable
class JamNearbyRoom {
  const JamNearbyRoom({
    required this.key,
    required this.sessionName,
    required this.joinUri,
  });

  /// Stable identity within one browse (the mDNS service name).
  final String key;

  /// Human-readable room name.
  final String sessionName;

  /// Ready-to-join `localjam://join?...` URI built from the resolved
  /// addresses and TXT attributes.
  final Uri joinUri;

  @override
  String toString() => 'JamNearbyRoom($sessionName, $joinUri)';
}

/// Advertises one hosted room on the LAN. Created by [start]; stopped with
/// [stop]. A room advertised here is joinable by ANYONE on the network —
/// the TXT record carries the session token (possession of the LAN = the
/// invitation, exactly like being handed the QR; see PROTOCOL.md §9) —
/// which is why hosts opt in via `JamHostEngine.start(discoverable:)`.
class JamRoomAdvertiser {
  JamRoomAdvertiser._(this._broadcast);

  final BonsoirBroadcast _broadcast;

  /// Starts advertising; returns null when the platform cannot (no mDNS
  /// implementation, missing OS permission, tests).
  static Future<JamRoomAdvertiser?> start({
    required String sessionName,
    required int port,
    required String token,
  }) async {
    try {
      final broadcast = BonsoirBroadcast(
        service: BonsoirService(
          name: sessionName,
          type: jamServiceType,
          port: port,
          attributes: {
            'v': '${MessageCodec.protocolVersion}',
            'name': sessionName,
            'token': token,
          },
        ),
      );
      await broadcast.initialize();
      await broadcast.start();
      return JamRoomAdvertiser._(broadcast);
    } catch (_) {
      return null; // Best-effort: the QR/link path always remains.
    }
  }

  Future<void> stop() async {
    try {
      await _broadcast.stop();
    } catch (_) {
      // Already stopped / platform gone.
    }
  }
}

/// Browses the LAN for advertised rooms. Create, [start], read/watch
/// [rooms], [stop].
class JamRoomBrowser {
  /// Currently visible resolved rooms, updated in place (the list instance
  /// is replaced on every change, so listeners can compare identity).
  final ValueNotifier<List<JamNearbyRoom>> rooms =
      ValueNotifier<List<JamNearbyRoom>>(const []);

  BonsoirDiscovery? _discovery;
  StreamSubscription<BonsoirDiscoveryEvent>? _sub;
  final Map<String, JamNearbyRoom> _byKey = {};
  bool _disposed = false;

  /// Whether the browser is currently running. Stays false when the
  /// platform has no mDNS support (start is best-effort).
  bool get running => _discovery != null;

  Future<void> start() async {
    if (_disposed || _discovery != null) return;
    try {
      final discovery = BonsoirDiscovery(type: jamServiceType);
      await discovery.initialize();
      _sub = discovery.eventStream?.listen(
        (event) => _onEvent(discovery, event),
        onError: (Object _) {},
      );
      await discovery.start();
      _discovery = discovery;
    } catch (_) {
      unawaited(_sub?.cancel());
      _sub = null;
      _discovery = null; // Best-effort: nearby list just stays empty.
    }
  }

  void _onEvent(BonsoirDiscovery discovery, BonsoirDiscoveryEvent event) {
    switch (event) {
      case BonsoirDiscoveryServiceFoundEvent(:final service):
        // Resolution fills in host addresses; failures surface as a
        // resolve-failed event, which we simply ignore.
        try {
          discovery.serviceResolver.resolveService(service);
        } catch (_) {}
      case BonsoirDiscoveryServiceResolvedEvent(:final service):
      case BonsoirDiscoveryServiceUpdatedEvent(:final service):
        final room = _roomFrom(service);
        if (room == null) {
          _byKey.remove(service.name);
        } else {
          _byKey[room.key] = room;
        }
        _publish();
      case BonsoirDiscoveryServiceLostEvent(:final service):
        _byKey.remove(service.name);
        _publish();
      default:
        break;
    }
  }

  /// Builds a joinable room from a resolved service; null when the record
  /// is unusable (no addresses, no token — e.g. a future version that
  /// stops advertising tokens).
  @visibleForTesting
  static JamNearbyRoom? roomFromService(BonsoirService service) =>
      _roomFrom(service);

  static JamNearbyRoom? _roomFrom(BonsoirService service) {
    final token = service.attributes['token'];
    // Guests try candidates in order (§1): put IPv4 first — link-local IPv6
    // (`fe80::…%en0`) often resolves first on Apple platforms but zone-id
    // URIs are unreliable, so leading with them just burns connect timeouts.
    final addresses = [
      for (final a in service.hostAddresses)
        if (!a.contains(':')) a, // IPv4 first…
      for (final a in service.hostAddresses)
        if (a.contains(':')) a, // …then IPv6, each keeping resolved order.
    ];
    final hosts = [
      ...addresses,
      // The SRV hostname (e.g. `host.local`) as a last-resort candidate.
      if (addresses.isEmpty && service.hostname != null) service.hostname!,
    ];
    if (token == null || token.isEmpty || hosts.isEmpty) return null;
    final sessionName = service.attributes['name'] ?? service.name;
    return JamNearbyRoom(
      key: service.name,
      sessionName: sessionName,
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

  void _publish() {
    if (_disposed) return;
    final sorted = _byKey.values.toList()
      ..sort((a, b) => a.sessionName.compareTo(b.sessionName));
    rooms.value = List.unmodifiable(sorted);
  }

  Future<void> stop() async {
    _disposed = true;
    unawaited(_sub?.cancel());
    _sub = null;
    try {
      await _discovery?.stop();
    } catch (_) {}
    _discovery = null;
    rooms.dispose();
  }
}
