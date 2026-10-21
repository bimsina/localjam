/// The guest engine compiled for the browser, against a real host
/// (docs/design/WEB_GUEST.md test plan; PROTOCOL.md §3.1, §5.3–§5.4, §6.2,
/// §6.3): it joins over the browser transport as `clientKind: "web"`, keeps
/// media in memory (the platform-default store on the web), reports `ready`
/// only for an item that decoded — an undecodable one is unplayable and
/// reported `none` — and plays the room's anchor through real Web Audio
/// within the §5.4 bands.
///
/// Needs the host and a Chrome that lets Web Audio run without a gesture
/// and talk to another origin; run it through the wrapper:
///
///     tool/web_engine_test.sh
///
/// A plain `flutter test` skips it (browser only), and a plain
/// `flutter test --platform chrome` skips it visibly (no host).
@TestOn('browser')
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_client/localjam_client.dart';

import 'web_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  if (webTestHostInfo.isEmpty) {
    test('the guest engine in a browser', () {
      markTestSkipped('needs a host: run tool/web_engine_test.sh');
    });
    return;
  }
  final info = (jsonDecode(webTestHostInfo) as Map).cast<String, Object?>();
  final control = info['control']! as String;
  final wavId = info['wav']! as String;
  final junkId = info['junk']! as String;

  setUpAll(routeChannelsLikeThePage);

  tearDownAll(() async {
    try {
      await webTestControl('$control/quit');
    } catch (_) {}
  });

  test('joins as a web guest, readies only what decodes, and plays the anchor '
      'in sync', () async {
    final engine = await JamGuestEngine.join(
      Uri.parse(info['joinUri']! as String),
      clientName: 'Browser Test',
      clientKind: 'web',
      clientId: 'c_web_engine_test',
      prefetchPolicy: const JamPrefetchPolicy(aheadCount: 1),
    );
    addTearDown(engine.close);
    expect(engine.sessionName, 'Web Engine');
    expect(
      engine.mediaStore,
      isA<JamMemoryMediaStore>(),
      reason: 'the platform default in a browser: memory, no files',
    );

    // §6.2 + §3.1: the WAV decodes and is ready; the junk arrives whole and
    // verified, then fails to decode and is unplayable.
    await waitFor(
      () => engine.prefetchStates.value[wavId]?.ready ?? false,
      reason: 'the WAV to be ready',
    );
    await waitFor(
      () =>
          engine.prefetchStates.value[junkId]?.phase ==
          JamPrefetchPhase.unplayable,
      reason: 'the junk to be unplayable',
    );
    expect(engine.prefetchStates.value[wavId]!.path, startsWith('memory:'));

    // §6.3: the host heard `ready` for the one that decoded and `none` for
    // the other — whose bytes were complete and sha256-verified, so only
    // the decode gate kept it from `ready`.
    Future<String?> hostSays(String id) async {
      final states =
          (await webTestControl('$control/ready/$id'))['states']! as Map;
      return states[engine.selfPeerId] as String?;
    }

    var wavState = await hostSays(wavId);
    for (var i = 0; i < 50 && wavState != 'ready'; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      wavState = await hostSays(wavId);
    }
    expect(wavState, 'ready');
    expect(await hostSays(junkId), 'none');

    // §5.3: the host schedules a start; the page plays it through Web
    // Audio and its 1 Hz drift check (§5.4) measures the heard position
    // against the anchor.
    final samples = <DriftSample>[];
    final sub = engine.driftSamples.listen(samples.add);
    addTearDown(sub.cancel);
    final started = await webTestControl('$control/play', method: 'POST');
    expect(started['status'], 'playing');
    await waitFor(
      () => samples.length >= 6,
      timeout: const Duration(seconds: 20),
      reason: 'six drift checks while playing',
    );
    final position = await engine.player.positionUs();
    expect(position, isNotNull, reason: 'the player is playing');
    expect(position, greaterThan(0));

    // The first check can land on the start itself; judge the rest.
    final settled = samples.skip(2).toList();
    final errorsMs = [for (final s in settled) s.errorUs / 1000];
    // ignore: avoid_print
    print('drift errors (ms): ${errorsMs.map((e) => e.toStringAsFixed(2))}');
    for (final s in settled) {
      expect(
        s.errorUs.abs(),
        lessThan(50000),
        reason: 'never a §5.4 hard-resync error: $errorsMs',
      );
    }
    final sorted = [...errorsMs.map((e) => e.abs())]..sort();
    expect(
      sorted[sorted.length ~/ 2],
      lessThan(15),
      reason: 'the median check is inside the §5.4 ignore band: $errorsMs',
    );
    expect(engine.lastPlayerError.value, isNull);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
