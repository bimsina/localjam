/// [JamMediaSessionController] against real engines on loopback, with the
/// `localjam_audio/media_session` channel mocked: verifies the OS media
/// card is fed (metadata, artwork, §5.6-gated controls) and that remote
/// transport commands route back into the right side of the jam.
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_client/localjam_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'engine_test_utils.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => HttpOverrides.global = null);
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  /// Installs a mock for the media-session channel; returns the recorded
  /// update/clear payloads.
  List<({String method, Map<Object?, Object?>? args})> mockMediaSession() {
    final log = <({String method, Map<Object?, Object?>? args})>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(JamMediaSession.channel, (call) async {
          log.add((
            method: call.method,
            args: call.arguments as Map<Object?, Object?>?,
          ));
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(JamMediaSession.channel, null);
      JamMediaSession.onCommand = null;
    });
    return log;
  }

  /// Injects one native→Dart `remoteCommand` platform message.
  Future<void> injectCommand(String command, {int? positionUs}) async {
    const codec = StandardMethodCodec();
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          JamMediaSession.channel.name,
          codec.encodeMethodCall(
            MethodCall('remoteCommand', {
              'command': command,
              'positionUs': ?positionUs,
            }),
          ),
          null,
        );
  }

  test('host: card follows state, carries tags + artwork, commands mutate '
      'the jam directly', () async {
    mockAudioChannel(durationUs: 42_000_000);
    final log = mockMediaSession();

    final engine = await JamHostEngine.start(
      sessionName: 'CardJam',
      address: InternetAddress.loopbackIPv4,
    );
    addTearDown(engine.close);
    final item = await engine.addMediaFile(await makeTaggedMp3());
    engine.setMedia(item.mediaId);
    engine.play();

    await waitFor(
      () => log.any(
        (e) =>
            e.method == 'update' &&
            e.args?['playing'] == true &&
            e.args?['title'] == 'Night Drive',
      ),
      reason: 'a playing card push with tag metadata',
    );
    // Artwork lands (possibly on a later push once resolved).
    await waitFor(
      () => log.any(
        (e) => e.method == 'update' && e.args?['artworkBytes'] != null,
      ),
      reason: 'a card push carrying artwork bytes',
    );
    final last = log.lastWhere((e) => e.method == 'update').args!;
    expect(last['artist'], 'The Localhosts');
    expect(last['album'], 'Loopback Sessions');
    expect(last['durationUs'], 42_000_000);
    // The host always controls playback.
    expect(last['canPlayPause'], isTrue);
    expect(last['canSeek'], isTrue);

    // A lock-screen pause reaches the authoritative state directly.
    await injectCommand('pause');
    await waitFor(
      () => engine.snapshot.status == PlaybackStatus.paused,
      reason: 'remote pause to apply',
    );
    // And a seek.
    await injectCommand('seek', positionUs: 10_000_000);
    await waitFor(
      () => engine.snapshot.positionUs == 10_000_000,
      reason: 'remote seek to apply',
    );

    // Closing the engine clears the card.
    await engine.close();
    expect(log.last.method, 'clear');
  });

  test('guest: controls are §5.6-gated on the card and commands are dropped '
      'without controlPlayback', () async {
    mockAudioChannel();
    final log = mockMediaSession();

    final host = JamHostServer(
      sessionName: 'GateJam',
      policy: JamPolicy.listenOnly,
    );
    await host.start(address: InternetAddress.loopbackIPv4);
    addTearDown(host.close);
    final file = await writeTempMedia(makeMediaBytes(2048));
    final item = await JamHostServer.describeFile(
      file,
      kind: MediaKind.audio,
      mime: 'audio/mpeg',
      title: 'Locked Track',
      durationUs: 30_000_000,
    );
    host.addMedia(item, file);
    host.setMedia(item.mediaId);

    final engine = await JamGuestEngine.join(
      host.joinUriFor(InternetAddress.loopbackIPv4),
      mediaCacheDir: await makeTempDir(),
    );
    addTearDown(engine.close);

    await waitFor(
      () => log.any(
        (e) => e.method == 'update' && e.args?['title'] == 'Locked Track',
      ),
      reason: 'guest card push',
    );
    final card = log.lastWhere((e) => e.method == 'update').args!;
    expect(card['canPlayPause'], isFalse);
    expect(card['canNext'], isFalse);
    expect(card['canSeek'], isFalse);

    // A racing remote play is dropped client-side: no request reaches the
    // host, state stays put.
    final revBefore = host.snapshot.rev;
    await injectCommand('play');
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(host.snapshot.rev, revBefore);
    expect(host.snapshot.status, isNot(PlaybackStatus.playing));

    // Promotion re-pushes the card with controls enabled, and commands now
    // flow as §5.2 requests.
    host.promotePeer(engine.selfPeerId);
    await waitFor(
      () => log.any(
        (e) => e.method == 'update' && e.args?['canPlayPause'] == true,
      ),
      reason: 'card re-push after promotion',
    );
    await injectCommand('play');
    await waitFor(
      () => host.snapshot.status == PlaybackStatus.playing,
      reason: 'remote play to arrive as a validated request',
    );
  });

  test('joinUri is kept for rejoin flows', () async {
    mockAudioChannel();
    mockMediaSession();
    final host = JamHostServer(sessionName: 'RejoinJam');
    await host.start(address: InternetAddress.loopbackIPv4);
    addTearDown(host.close);
    final joinUri = host.joinUriFor(InternetAddress.loopbackIPv4);
    final engine = await JamGuestEngine.join(
      joinUri,
      mediaCacheDir: await makeTempDir(),
    );
    addTearDown(engine.close);
    expect(engine.joinUri, joinUri);
  });
}
