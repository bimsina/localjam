/// `localjam join` announces a `hello.clientId` (PROTOCOL.md §3.3), so a host
/// that removes a CLI guest can keep it out for the rest of the jam (§5.6).
@Timeout(Duration(seconds: 30))
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:localjam_cli/src/join_command.dart';
import 'package:localjam_net/localjam_net.dart';
import 'package:test/test.dart';

void main() {
  test('every run gets its own random id unless one is pinned', () {
    final a = cliClientId(null);
    final b = cliClientId(null);
    expect(a, startsWith('cli-'));
    expect(a, hasLength('cli-'.length + 32));
    expect(a, isNot(b), reason: 'two terminals are two devices');
    expect(cliClientId('  '), startsWith('cli-'), reason: 'blank is unset');
    expect(cliClientId(' van-laptop '), 'van-laptop');
    expect(
      cliClientId(null, random: math.Random(1)),
      cliClientId(null, random: math.Random(1)),
    );
  });

  test('a kicked CLI guest is held until the host lets it back in', () async {
    final host = JamHostServer(sessionName: 'cli-kick');
    await host.start(address: InternetAddress.loopbackIPv4);
    addTearDown(host.close);
    final uri = host.joinUriFor(InternetAddress.loopbackIPv4);
    final id = cliClientId(null);

    final guest = await JamGuestClient.connect(
      uri,
      clientName: 'terminal',
      clientKind: 'cli',
      clientId: id,
    );
    addTearDown(guest.close);
    expect(host.kickKeepsOut(guest.selfPeerId), isTrue);
    host.kickPeer(guest.selfPeerId);

    await expectLater(
      JamGuestClient.connect(
        uri,
        clientName: 'terminal',
        clientKind: 'cli',
        clientId: id,
      ),
      throwsA(
        isA<JamRejectedException>().having(
          (e) => e.reason,
          'reason',
          RejectReason.kicked,
        ),
      ),
    );

    expect(host.unkickPeer(guest.selfPeerId), isTrue);
    final back = await JamGuestClient.connect(
      uri,
      clientName: 'terminal',
      clientKind: 'cli',
      clientId: id,
    );
    addTearDown(back.close);
    expect(host.peers.single.peerId, back.selfPeerId);
  });
}
