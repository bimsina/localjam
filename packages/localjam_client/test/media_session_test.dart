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
    // Room identity: the card says which jam, so the platform can use it as
    // the subtitle when tags carry no artist and as a third line when they do.
    expect(last['sessionName'], 'CardJam');
    // Artwork is content-addressed, so the platform decodes one bitmap per
    // cover instead of re-decoding on every position push.
    expect(last['artworkId'], isNotNull);
    expect(last['artworkId'], item.artworkId);
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

  test('a suspended guest shows paused on the card, and its play button '
      'resumes this device without any §5.6 capability', () async {
    final audio = mockAudioChannel();
    final push = mockAudioEvents();
    final log = mockMediaSession();

    final host = JamHostServer(
      sessionName: 'CallJam',
      policy: JamPolicy.listenOnly,
    );
    await host.start(address: InternetAddress.loopbackIPv4);
    addTearDown(host.close);
    final file = await writeTempMedia(makeMediaBytes(2048));
    final item = await JamHostServer.describeFile(
      file,
      kind: MediaKind.audio,
      mime: 'audio/mpeg',
      title: 'Call Track',
      durationUs: 30_000_000,
    );
    host.addMedia(item, file);
    host.setMedia(item.mediaId);
    host.play();

    final engine = await JamGuestEngine.join(
      host.joinUriFor(InternetAddress.loopbackIPv4),
      mediaCacheDir: await makeTempDir(),
    );
    addTearDown(engine.close);
    await waitFor(
      () => audio.any((c) => c.method == 'playAt'),
      reason: 'the guest to play along',
    );

    // A phone call takes the audio.
    push({'type': 'interruptionBegan'});
    await waitFor(
      () => engine.outputSuspension.value != null,
      reason: 'suspension',
    );
    await waitFor(
      () => log.any(
        (e) =>
            e.method == 'update' &&
            e.args?['playing'] == false &&
            e.args?['canPlayPause'] == true,
      ),
      reason: 'the card to say paused, with a play button',
    );

    // Play on the lock screen after the call: a local resume.
    audio.clear();
    final revBefore = host.snapshot.rev;
    await injectCommand('play');
    await waitFor(
      () => audio.any((c) => c.method == 'playAt'),
      reason: 're-anchor on resume',
    );
    expect(engine.outputSuspension.value, isNull);
    expect(host.snapshot.rev, revBefore, reason: 'nothing sent to the room');
  });

  test('an artless track gets the app-supplied placeholder cover, decoded '
      'once', () async {
    // Most files people add to a jam carry no embedded art, and an empty
    // square is what the OS shows for one. The engine has no widget tree to
    // draw the brand placeholder with, so the app hands it over as bytes.
    mockAudioChannel();
    final log = mockMediaSession();
    var renders = 0;
    JamMediaSessionController.resetPlaceholderForTesting();
    addTearDown(JamMediaSessionController.resetPlaceholderForTesting);
    JamMediaSessionController.placeholderArtworkProvider = () async {
      renders++;
      return tinyPngBytes;
    };

    final engine = await JamHostEngine.start(
      sessionName: 'ArtlessJam',
      address: InternetAddress.loopbackIPv4,
    );
    addTearDown(engine.close);
    final a = await engine.addMediaFile(
      await writeTempMedia(makeMediaBytes(4096)),
      name: 'A.mp3',
    );
    expect(a.artworkId, isNull, reason: 'the fixture has no embedded cover');
    engine.setMedia(a.mediaId);

    await waitFor(
      () => log.any(
        (e) => e.method == 'update' && e.args?['artworkBytes'] != null,
      ),
      reason: 'the placeholder to reach the card',
    );
    var last = log.lastWhere((e) => e.method == 'update').args!;
    expect(last['artworkBytes'], tinyPngBytes);
    expect(
      last['artworkId'],
      JamMediaSessionController.placeholderArtworkId,
      reason:
          'a stable key, so the platform decodes one bitmap for all of '
          'them',
    );

    // A second artless track reuses the resolved bytes rather than asking
    // the app to render again.
    final b = await engine.addMediaFile(
      await writeTempMedia(makeMediaBytes(4096, seed: 7)),
      name: 'B.mp3',
    );
    engine.setMedia(b.mediaId);
    await waitFor(
      () => log.any(
        (e) =>
            e.method == 'update' &&
            e.args?['title'] == 'B' &&
            e.args?['artworkBytes'] != null,
      ),
      reason: "the second track's card",
    );
    expect(renders, 1);

    // A track with its own cover still wins.
    final tagged = await engine.addMediaFile(await makeTaggedMp3());
    engine.setMedia(tagged.mediaId);
    await waitFor(
      () => log.any(
        (e) => e.method == 'update' && e.args?['artworkId'] == tagged.artworkId,
      ),
      reason: 'the embedded cover to take over',
    );
    last = log.lastWhere((e) => e.method == 'update').args!;
    expect(
      last['artworkId'],
      isNot(JamMediaSessionController.placeholderArtworkId),
    );
  });

  test(
    'no placeholder configured leaves an artless card exactly as it was',
    () async {
      mockAudioChannel();
      final log = mockMediaSession();
      JamMediaSessionController.resetPlaceholderForTesting();
      addTearDown(JamMediaSessionController.resetPlaceholderForTesting);

      final engine = await JamHostEngine.start(
        sessionName: 'BareJam',
        address: InternetAddress.loopbackIPv4,
      );
      addTearDown(engine.close);
      final item = await engine.addMediaFile(
        await writeTempMedia(makeMediaBytes(4096)),
        name: 'A.mp3',
      );
      engine.setMedia(item.mediaId);
      await waitFor(
        () => log.any((e) => e.method == 'update' && e.args?['title'] == 'A'),
        reason: 'a card push',
      );
      final last = log.lastWhere((e) => e.method == 'update').args!;
      expect(last['artworkBytes'], isNull);
      expect(last['artworkId'], isNull);
    },
  );

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
