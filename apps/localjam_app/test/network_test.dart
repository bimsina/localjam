import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/util/network.dart';

void main() {
  test('offline is the absence of an address', () {
    expect(JamNetworkStatus.offline.connected, isFalse);
    expect(JamNetworkStatus.offline.primaryAddress, isNull);
  });

  test('a bound address means guests can reach a host here', () {
    const status = JamNetworkStatus(
      addresses: ['192.168.1.5'],
      interface: 'en0',
    );
    expect(status.connected, isTrue);
    expect(status.primaryAddress, '192.168.1.5');
    expect(status.isHotspotHost, isFalse);
  });

  test('recognises the interfaces a personal hotspot bridges onto', () {
    // Matters because mDNS does not cross a hotspot: on these, the nearby
    // list stays empty however well things are working, and the QR is the
    // only way in.
    for (final name in ['bridge100', 'ap0', 'swlan0', 'rndis0']) {
      expect(
        JamNetworkStatus(
          addresses: const ['172.20.10.1'],
          interface: name,
        ).isHotspotHost,
        isTrue,
        reason: '$name should read as a hotspot',
      );
    }
    for (final name in ['en0', 'wlan0', 'eth0']) {
      expect(
        JamNetworkStatus(
          addresses: const ['192.168.1.5'],
          interface: name,
        ).isHotspotHost,
        isFalse,
        reason: '$name should not read as a hotspot',
      );
    }
  });
}
