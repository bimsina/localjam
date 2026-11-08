/// End-to-end smoke test: a real [JamHostServer] and [JamGuestClient] talk
/// over 127.0.0.1 in-process while a [SimPlayer] follows the authoritative
/// anchor, exactly like the `join` command's tick loop.
@Timeout(Duration(seconds: 30))
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:localjam_cli/src/join_command.dart';
import 'package:localjam_cli/src/sim_player.dart';
import 'package:localjam_net/localjam_net.dart';
import 'package:test/test.dart';

const _leadTimeUs = 200_000; // Short scheduled-start lead keeps tests fast.

class _Rig {
  _Rig(this.host, this.guest, this.item);

  final JamHostServer host;
  final JamGuestClient guest;
  final MediaItem item;

  Future<void> close() async {
    await guest.close();
    await host.close();
  }
}

Future<_Rig> _startRig(Directory tmp) async {
  final file = File('${tmp.path}/tone.bin');
  file.writeAsBytesSync(
    List<int>.generate(16 * 1024, (i) => (i * 31 + 7) & 0xff),
  );

  final host = JamHostServer(sessionName: 'smoke', leadTimeUs: _leadTimeUs);
  await host.start(); // Loopback, ephemeral port.
  final item = await JamHostServer.describeFile(
    file,
    kind: MediaKind.audio,
    mime: 'audio/wav',
  );
  host.addMedia(item, file);
  host.setMedia(item.mediaId);

  final guest = await JamGuestClient.connect(
    host.joinUriFor(InternetAddress.loopbackIPv4),
    clientName: 'smoke-guest',
    clientKind: 'test',
  );
  await guest.fetchMedia(item.mediaId); // Prefetch before playing (§6.2).

  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!guest.clock.isSynchronized) {
    if (DateTime.now().isAfter(deadline)) {
      fail('clock never synchronized');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  return _Rig(host, guest, item);
}

/// Plays for [playFor] (after the scheduled lead-in) while ticking [sim]
/// every 25 ms, returning the largest |drift| observed once playback is
/// comfortably past the anchor start.
Future<int> _playAndMeasure(
  _Rig rig,
  SimPlayer sim, {
  required Duration playFor,
}) async {
  rig.host.play();
  final guest = rig.guest;

  var lastUs = guest.localNowUs;
  final endLocalUs = lastUs + _leadTimeUs + playFor.inMicroseconds;
  var maxAbsDriftUs = 0;

  while (guest.localNowUs < endLocalUs) {
    await Future<void>.delayed(const Duration(milliseconds: 25));
    final nowUs = guest.localNowUs;
    final elapsedUs = nowUs - lastUs;
    lastUs = nowUs;

    final snapshot = guest.snapshot;
    final sessionNowUs = guest.sessionNowUs;
    sim.tick(
      snapshot: snapshot,
      sessionNowUs: sessionNowUs,
      elapsedUs: elapsedUs,
    );

    final anchor = snapshot.anchor;
    final started =
        snapshot.status == PlaybackStatus.playing &&
        anchor != null &&
        sessionNowUs > anchor.hostTimeUs + 100_000;
    if (started) {
      maxAbsDriftUs = math.max(maxAbsDriftUs, sim.lastDriftUs.abs());
    }
  }
  return maxAbsDriftUs;
}

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('localjam_cli_smoke');
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  test('a host that ends the jam is reported as ending it, not as a '
      'closed connection', () async {
    final rig = await _startRig(tmp);
    await rig.host.close();
    await rig.guest.done.timeout(const Duration(seconds: 5));
    expect(describeHostClose(rig.guest.sessionEnded), 'The host ended the jam');
    await rig.guest.close();
    // A host that just vanished said nothing: that is still a dropped link.
    expect(describeHostClose(null), 'connection closed by host');
  });

  test('zero skew: drift stays under 1 ms over ~2 s of playback', () async {
    final rig = await _startRig(tmp);
    addTearDown(rig.close);

    final sim = SimPlayer(); // skewPpm: 0
    final maxAbsDriftUs = await _playAndMeasure(
      rig,
      sim,
      playFor: const Duration(seconds: 2),
    );

    expect(
      maxAbsDriftUs,
      lessThan(1000),
      reason: 'with no skew the sim player should track the anchor',
    );
    expect(sim.hardResyncs, 0);
    expect(sim.slews, 0);
  });

  test('0.5% skew: at least one slew, drift bounded under 50 ms', () async {
    final rig = await _startRig(tmp);
    addTearDown(rig.close);

    // +5000 ppm accumulates 5 ms of drift per second; the 15 ms slew
    // threshold trips after ~3 s, so play for 4.5 s to see it corrected.
    final sim = SimPlayer(skewPpm: 5000);
    final maxAbsDriftUs = await _playAndMeasure(
      rig,
      sim,
      playFor: const Duration(milliseconds: 4500),
    );

    expect(
      sim.slews,
      greaterThanOrEqualTo(1),
      reason: 'skew-induced drift must trigger a slew',
    );
    expect(
      maxAbsDriftUs,
      lessThan(50_000),
      reason: 'slewing must keep drift bounded below the hard-resync line',
    );
    expect(sim.hardResyncs, 0);
  });
}
