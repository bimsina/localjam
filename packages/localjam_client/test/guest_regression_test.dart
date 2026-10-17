/// [JamGuestEngine] regressions from the adversarial review, against a real
/// loopback [JamHostServer]: cache files that vanish under a "ready" item
/// (evicted, or deleted behind the cache's back) are fetched again instead
/// of silencing the track; a wall-clock step while audibly playing is not a
/// sleep; a wake is caught before a state frame can schedule on the stale
/// mapping; a clock is re-trusted once the wake's ping burst confirms it,
/// and on a timeout only on a live (or fresh) connection; and a host that
/// said it is away is not sent requests.
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_client/localjam_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'engine_test_utils.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => HttpOverrides.global = null);
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => JamGuestEngine.wallClock = DateTime.now);

  Future<JamHostServer> startHost() async {
    final host = JamHostServer(sessionName: 'RegJam', policy: JamPolicy.open);
    await host.start(address: InternetAddress.loopbackIPv4);
    addTearDown(host.close);
    return host;
  }

  Future<({MediaItem item, File file})> addTrack(
    JamHostServer host,
    int seed,
  ) async {
    final file = await writeTempMedia(
      makeMediaBytes(4096, seed: seed),
      name: 't$seed.mp3',
    );
    final item = await JamHostServer.describeFile(
      file,
      kind: MediaKind.audio,
      mime: 'audio/mpeg',
      durationUs: 60000000,
    );
    host.addMedia(item, file);
    return (item: item, file: file);
  }

  JamBackoff fast(int ms) => JamBackoff(
    initialDelay: Duration(milliseconds: ms),
    maxDelay: Duration(milliseconds: ms * 2),
    jitterRatio: 0,
  );

  Future<JamGuestEngine> join(
    JamHostServer host, {
    int cacheMaxBytes = 1 << 30,
    JamPrefetchPolicy prefetchPolicy = const JamPrefetchPolicy(),
    Duration clockWakeTimeout = const Duration(seconds: 8),
    JamBackoff? backoff,
  }) async {
    final engine = await JamGuestEngine.join(
      host.joinUriFor(InternetAddress.loopbackIPv4),
      clientName: 'reg-guest',
      mediaCacheDir: await makeTempDir(),
      cacheMaxBytes: cacheMaxBytes,
      prefetchPolicy: prefetchPolicy,
      clockWakeTimeout: clockWakeTimeout,
      backoff: backoff ?? fast(20),
    );
    addTearDown(engine.close);
    return engine;
  }

  /// The paths the mocked native side was asked to load, in order.
  List<String> loads(List<MethodCall> log) => [
    for (final call in log)
      if (call.method == 'load') (call.arguments as Map)['path'] as String,
  ];

  /// A mocked native side whose `load` fails for a file that is not there
  /// (as every platform's does), and — when [positionFrom] is given — whose
  /// `positionUs` reports audio coming out where the room is. [onCall] sees
  /// every call as it lands.
  List<MethodCall> mockNative({
    int Function()? positionFrom,
    void Function(MethodCall call)? onCall,
  }) {
    final log = <MethodCall>[];
    var nativeNow = 1000000;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(audioChannel, (call) async {
          log.add(call);
          onCall?.call(call);
          switch (call.method) {
            case 'nowUs':
              return nativeNow += 100;
            case 'load':
              final path = (call.arguments as Map)['path'] as String;
              if (!File(path).existsSync()) {
                throw PlatformException(code: 'load_failed', message: 'gone');
              }
              return 60000000;
            case 'probeDuration':
              return 60000000;
            case 'positionUs':
              return positionFrom?.call();
            case 'outputLatencyUs':
              return 0;
            default:
              return null;
          }
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(audioChannel, null),
    );
    return log;
  }

  group('cache files that vanish under a ready item (§6.2, §6.3)', () {
    test(
      'a track LRU-evicted while it stayed "ready" is fetched again when '
      'the room comes back to it, and plays — the host is told meanwhile',
      () async {
        final log = mockNative();
        final host = await startHost();
        final a = await addTrack(host, 1);
        final b = await addTrack(host, 2);
        final reports = <MediaFetchState>[];
        host.events
            .where(
              (e) =>
                  e.kind == JamHostEventKind.peerMediaStatus &&
                  e.mediaId == a.item.mediaId,
            )
            .listen((e) => reports.add(e.mediaState!));
        host.setMedia(a.item.mediaId);
        final guest = await join(
          host,
          cacheMaxBytes: 5000, // Room for one 4 KB track.
          prefetchPolicy: const JamPrefetchPolicy(aheadCount: 0),
        );
        await waitFor(
          () => guest.prefetchStates.value[a.item.mediaId]?.ready ?? false,
          reason: 'A fetched',
        );
        final aPath = guest.prefetchStates.value[a.item.mediaId]!.path!;

        host.setMedia(b.item.mediaId);
        await waitFor(
          () => guest.prefetchStates.value[b.item.mediaId]?.ready ?? false,
          reason: 'B fetched',
        );
        await waitFor(
          () => !File(aPath).existsSync(),
          reason: 'A evicted to make room',
        );
        await waitFor(
          () => guest.prefetchStates.value[a.item.mediaId]?.ready == false,
          reason: 'A no longer claims to be ready',
        );
        await waitFor(
          () => reports.contains(MediaFetchState.none),
          reason: 'the host told A is gone',
        );

        log.clear();
        host.setMedia(a.item.mediaId);
        host.play();
        await waitFor(
          () => log.any((c) => c.method == 'playAt'),
          timeout: const Duration(seconds: 6),
          reason: 'A fetched again and scheduled',
        );
        expect(guest.outputSuspension.value, isNull);
        expect(loads(log).last, aPath);
        expect(File(aPath).existsSync(), isTrue);
      },
    );

    test('a cached file deleted behind the cache\'s back is re-fetched, not '
        'failed as undecodable', () async {
      final log = mockNative();
      final host = await startHost();
      final a = await addTrack(host, 3);
      host.setMedia(a.item.mediaId);
      final guest = await join(host);
      await waitFor(
        () =>
            guest.clockSynced &&
            (guest.prefetchStates.value[a.item.mediaId]?.ready ?? false),
        reason: 'clock sync and A',
      );
      final path = guest.prefetchStates.value[a.item.mediaId]!.path!;
      // The OS cleared the cache directory under storage pressure.
      await File(path).delete();
      // A fresh load is needed: the engine must not trust a preload.
      await guest.sync.invalidateLoadedMedia();
      log.clear();

      host.play();
      await waitFor(
        () => log.any((c) => c.method == 'playAt'),
        timeout: const Duration(seconds: 6),
        reason: 'A fetched again and scheduled',
      );
      expect(guest.outputSuspension.value, isNull);
      expect(File(path).existsSync(), isTrue);
      expect(guest.prefetchStates.value[a.item.mediaId]?.ready, isTrue);
    });
  });

  group('the in-flight fetch is never evicted', () {
    test('its file and .part are protected whatever the window says now', () {
      MediaItem item(String id) => MediaItem(
        mediaId: id,
        kind: MediaKind.audio,
        name: '$id.mp3',
        mime: 'audio/mpeg',
        sizeBytes: 1,
        sha256: id,
      );
      File? fileFor(MediaItem item) => File('/cache/${item.sha256}.mp3');
      final paths = JamGuestEngine.protectedCachePathsFor(
        [item('b')],
        inFlight: item('a'),
        fileFor: fileFor,
      );
      expect(paths, {
        '/cache/b.mp3',
        '/cache/b.mp3.part',
        '/cache/a.mp3',
        '/cache/a.mp3.part',
      });
      expect(
        JamGuestEngine.protectedCachePathsFor([item('b')], fileFor: fileFor),
        {'/cache/b.mp3', '/cache/b.mp3.part'},
      );
    });

    test('a fetch the room moved away from mid-transfer is not evicted the '
        'moment it lands', () async {
      mockNative();
      final host = await startHost();
      final small = await addTrack(host, 31);
      // Big enough that the room can move on while it is still arriving.
      final bigFile = await writeTempMedia(
        Uint8List(24 << 20),
        name: 'big.mp3',
      );
      final big = await JamHostServer.describeFile(
        bigFile,
        kind: MediaKind.audio,
        mime: 'audio/mpeg',
        durationUs: 60000000,
      );
      host
        ..addMedia(big, bigFile)
        ..setMedia(small.item.mediaId);
      final guest = await join(
        host,
        // Both tracks do not fit: whatever is unprotected goes.
        cacheMaxBytes: (24 << 20) + 1024,
        prefetchPolicy: const JamPrefetchPolicy(aheadCount: 0),
      );
      bool ready(MediaItem item) =>
          guest.prefetchStates.value[item.mediaId]?.ready ?? false;
      await waitFor(() => ready(small.item), reason: 'the small one cached');

      var movedOn = false;
      String? currentWhenLanded;
      void watch() {
        final state = guest.prefetchStates.value[big.mediaId];
        if (!movedOn &&
            state?.phase == JamPrefetchPhase.fetching &&
            state!.progress > 0) {
          movedOn = true;
          host.setMedia(small.item.mediaId); // Back, mid-transfer.
        }
        if (state?.ready ?? false) {
          currentWhenLanded ??= guest.snapshot.mediaId;
        }
      }

      guest.prefetchStates.addListener(watch);
      addTearDown(() => guest.prefetchStates.removeListener(watch));
      host.setMedia(big.mediaId);
      await waitFor(
        () => currentWhenLanded != null,
        timeout: const Duration(seconds: 10),
        reason: 'the big one to land',
      );
      expect(
        currentWhenLanded,
        small.item.mediaId,
        reason: 'test premise: it landed after the room had moved on',
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(ready(big), isTrue, reason: 'not thrown away on arrival');
      expect(
        File(guest.prefetchStates.value[big.mediaId]!.path!).existsSync(),
        isTrue,
      );
    });
  });

  test('with prefetchAll the whole playlist is protected from eviction: '
      'nothing is evicted only to be fetched straight back', () async {
    mockNative();
    final host = await startHost();
    final a = await addTrack(host, 21);
    final b = await addTrack(host, 22);
    host.setMedia(a.item.mediaId);
    final guest = await join(
      host,
      cacheMaxBytes: 5000, // One track's worth: the cap cannot hold both.
      prefetchPolicy: const JamPrefetchPolicy(aheadCount: 0, prefetchAll: true),
    );
    bool ready(MediaItem item) =>
        guest.prefetchStates.value[item.mediaId]?.ready ?? false;
    await waitFor(() => ready(a.item) && ready(b.item), reason: 'both');
    final fetches = <String>[];
    host.events
        .where(
          (e) =>
              e.kind == JamHostEventKind.peerMediaStatus &&
              e.mediaState == MediaFetchState.fetching,
        )
        .listen((e) => fetches.add(e.mediaId!));
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(ready(a.item) && ready(b.item), isTrue);
    expect(fetches, isEmpty, reason: 'no evict/re-fetch churn');
    for (final item in [a.item, b.item]) {
      expect(
        File(guest.prefetchStates.value[item.mediaId]!.path!).existsSync(),
        isTrue,
      );
    }
  });

  group('device sleep vs the session clock (§4)', () {
    /// A playing guest. `playAts[call]` says, for each `playAt` call, how
    /// many samples the guest's clock had accepted (`acceptedSampleCount`)
    /// and the monotonic time when it landed.
    Future<
      ({
        JamHostServer host,
        JamGuestEngine guest,
        List<MethodCall> log,
        Expando<({int accepted, int atUs})> playAts,
      })
    >
    playing({
      Duration clockWakeTimeout = const Duration(seconds: 8),
      JamBackoff? backoff,
      bool audible = false,
    }) async {
      late final JamHostServer host;
      JamGuestEngine? joined;
      final playAts = Expando<({int accepted, int atUs})>();
      final log = mockNative(
        positionFrom: audible
            ? () => host.snapshot.positionAt(monotonicNowUs())
            : null,
        onCall: (call) {
          final count = joined?.clock.acceptedSampleCount;
          if (call.method == 'playAt' && count != null) {
            playAts[call] = (accepted: count, atUs: monotonicNowUs());
          }
        },
      );
      host = await startHost();
      final track = await addTrack(host, 7);
      host.setMedia(track.item.mediaId);
      final guest = joined = await join(
        host,
        clockWakeTimeout: clockWakeTimeout,
        backoff: backoff,
      );
      await waitFor(
        () =>
            guest.clockSynced &&
            (guest.prefetchStates.value[track.item.mediaId]?.ready ?? false),
        reason: 'clock sync and the track',
      );
      host.play();
      await waitFor(
        () => log.any((c) => c.method == 'playAt'),
        reason: 'the guest to schedule',
      );
      return (host: host, guest: guest, log: log, playAts: playAts);
    }

    test('a +1 s wall-clock step while audibly playing in the foreground '
        'is not a sleep: no dropout, and a room change right after it is '
        'followed within moments', () async {
      final s = await playing(audible: true); // Default 8 s wake timeout.
      // Let the drift loop confirm audio is coming out.
      await waitFor(
        () => s.guest.sync.confirmedPlayingWithin(const Duration(seconds: 2)),
        timeout: const Duration(seconds: 4),
        reason: 'a live position read',
      );
      s.log.clear();
      // The OS steps the wall clock (NTP, a manual change): no sleep, no
      // lifecycle event.
      JamGuestEngine.wallClock = () =>
          DateTime.now().add(const Duration(seconds: 1));
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expect(
        s.log.where((c) => c.method == 'pause' || c.method == 'stop'),
        isEmpty,
        reason: 'audio never stopped',
      );
      expect(s.guest.outputSuspension.value, isNull);

      // The room seeks meanwhile: followed once the wake's ping burst had
      // its chance to show a jump — not after the whole wake timeout.
      final seekAt = DateTime.now();
      s.host.seek(20000000);
      await waitFor(
        () => s.log.any(
          (c) =>
              c.method == 'playAt' &&
              ((c.arguments as Map)['positionUs'] as int) >= 20000000,
        ),
        timeout: const Duration(seconds: 4),
        reason: 'the seek followed',
      );
      expect(
        DateTime.now().difference(seekAt),
        lessThan(const Duration(seconds: 3)),
      );
    });

    test('a state frame landing right after a wake is not scheduled on the '
        'pre-sleep mapping', () async {
      final s = await playing(
        clockWakeTimeout: const Duration(milliseconds: 1500),
      );
      final acceptedBefore = s.guest.clock.acceptedSampleCount;
      s.log.clear();
      // The device slept 30 s; the room moved on, and its next frame
      // arrives before any periodic look at the clocks.
      JamGuestEngine.wallClock = () =>
          DateTime.now().add(const Duration(seconds: 30));
      final wokeAtUs = monotonicNowUs();
      s.host.seek(10000000);
      await Future<void>.delayed(const Duration(milliseconds: 800));
      expect(
        s.log.where((c) => c.method == 'playAt'),
        isEmpty,
        reason: 'nothing scheduled while the clock is distrusted',
      );
      expect(s.log.map((c) => c.method), contains('pause'));
      // Loopback: no jump ever shows up (the monotonic clock never
      // stopped), so the wake burst's accepted readings re-trust it — or,
      // should the RTT gate turn them away, the timeout does.
      await waitFor(
        () => s.log.any((c) => c.method == 'playAt'),
        timeout: const Duration(seconds: 4),
        reason: 'the re-anchor once trusted',
      );
      final first = s.playAts[s.log.firstWhere((c) => c.method == 'playAt')]!;
      expect(
        first.accepted - acceptedBefore >= 3 ||
            first.atUs - wokeAtUs >= 1500000,
        isTrue,
        reason:
            'scheduled only once post-wake readings or the timeout '
            're-trusted the clock',
      );
      final positionUs =
          (s.log.lastWhere((c) => c.method == 'playAt').arguments
                  as Map)['positionUs']
              as int;
      expect(positionUs, greaterThanOrEqualTo(10000000));
    });

    /// A playing guest whose session clock only ever hears the readings the
    /// test hands it ([reading]): the host's pongs are muted on the way
    /// ([PongMutingProxy]), so neither the machine's load nor a pong landing
    /// a little early or late can move what the clock has accepted. These
    /// tests used to race the wake's real ping burst — loopback round trips
    /// a busy machine stretched past the RTT gate — and lost now and then.
    /// `acceptedAt[call]` is the clock's accepted count when a `playAt` landed.
    Future<
      ({
        JamHostServer host,
        JamGuestEngine guest,
        List<MethodCall> log,
        PongMutingProxy proxy,
        Expando<int> acceptedAt,
        void Function() reading,
      })
    >
    playingOnTestReadings() async {
      late JamGuestEngine guest;
      final acceptedAt = Expando<int>();
      final log = mockNative(
        onCall: (call) {
          if (call.method == 'playAt') {
            acceptedAt[call] = guest.clock.acceptedSampleCount;
          }
        },
      );
      final host = await startHost();
      final track = await addTrack(host, 7);
      host.setMedia(track.item.mediaId);
      final proxy = await PongMutingProxy.start(host.port);
      guest = await JamGuestEngine.join(
        proxy.joinUriFor(host.joinUriFor(InternetAddress.loopbackIPv4)),
        clientName: 'reg-guest',
        mediaCacheDir: await makeTempDir(),
        clockWakeTimeout: const Duration(seconds: 20),
        backoff: fast(20),
      );
      addTearDown(guest.close);

      // One reading of a clock that never jumped: host and guest share this
      // process's monotonic clock (true offset 0); 400 µs round trip.
      void reading() {
        final t3 = monotonicNowUs();
        guest.clock.addSample(
          ClockSample(t0: t3 - 400, t1: t3 - 200, t2: t3 - 200, t3: t3),
        );
      }

      for (var i = 0; i < guest.clock.burstSize; i++) {
        reading(); // The join burst.
      }
      expect(guest.clockSynced, isTrue);
      await waitFor(
        () => guest.prefetchStates.value[track.item.mediaId]?.ready ?? false,
        reason: 'the track',
      );
      host.play();
      await waitFor(
        () => log.any((c) => c.method == 'playAt'),
        reason: 'the guest to schedule',
      );
      expect(proxy.mutedPongs, greaterThan(0), reason: 'test premise');
      return (
        host: host,
        guest: guest,
        log: log,
        proxy: proxy,
        acceptedAt: acceptedAt,
        reading: reading,
      );
    }

    test('a wake whose clock did not jump is trusted again as soon as the '
        "wake's burst confirms it, not after the whole wake timeout "
        '(S3c)', () async {
      // The burst's readings agree with the estimate — the monotonic clock
      // never stopped — and three of them accepted are proof enough. The
      // guest used to stay silent for all of clockWakeTimeout (20 s here)
      // on a connection that was alive the whole time.
      final s = await playingOnTestReadings();
      final acceptedBefore = s.guest.clock.acceptedSampleCount;
      final mutedBefore = s.proxy.mutedPongs;
      s.log.clear();
      JamGuestEngine.wallClock = () =>
          DateTime.now().add(const Duration(seconds: 30));
      final sinceWake = Stopwatch()..start();
      s.host.seek(10000000); // The frame that notices the wake.
      bool scheduled() => s.log.any((c) => c.method == 'playAt');
      await waitFor(
        () => s.log.any((c) => c.method == 'pause'),
        reason: 'held silent',
      );
      expect(scheduled(), isFalse, reason: 'not on the pre-sleep mapping');
      // The wake asked for a fresh §4 burst (8 pings; the steady schedule
      // sends one every 2 s) — its answers are what the readings stand for.
      await waitFor(
        () => s.proxy.mutedPongs >= mutedBefore + 4,
        reason: 'the wake burst',
      );

      for (var i = 0; i < 3; i++) {
        s.reading();
      }
      await s.guest.sync.checkDriftNow();
      await waitFor(
        scheduled,
        timeout: const Duration(seconds: 3),
        reason: 'the re-anchor once the burst confirmed the clock',
      );
      expect(sinceWake.elapsed, lessThan(const Duration(seconds: 10)));
      final playAt = s.log.firstWhere((c) => c.method == 'playAt');
      expect(s.acceptedAt[playAt], acceptedBefore + 3);
      expect(
        (playAt.arguments as Map)['positionUs'] as int,
        greaterThanOrEqualTo(10000000),
        reason: 'the room as it is now: the seek it missed while held',
      );
      expect(s.guest.connectionState, JamConnectionState.connected);
    });

    test('one or two post-wake readings are not enough: a schedule asked '
        'for between the first and the third accepted reading waits for the '
        'third (S3c)', () async {
      // The first reading after a wake can be a pong that was in flight
      // when the device fell asleep — it reads the pre-sleep clock and is
      // accepted without proving anything. A re-schedule asked for right
      // then (here a nudge) must not go out on it.
      final s = await playingOnTestReadings();

      // The wake, noticed on resume: output is held.
      final acceptedBefore = s.guest.clock.acceptedSampleCount;
      s.log.clear();
      JamGuestEngine.wallClock = () =>
          DateTime.now().add(const Duration(seconds: 30));
      await s.guest.handleLifecycleState(AppLifecycleState.resumed);
      await waitFor(
        () => s.log.any((c) => c.method == 'pause'),
        reason: 'output held',
      );
      bool scheduled() => s.log.any((c) => c.method == 'playAt');

      s.reading();
      expect(s.guest.clock.acceptedSampleCount, acceptedBefore + 1);
      await s.guest.setNudgeUs(20000, persist: false);
      await s.guest.sync.checkDriftNow();
      expect(scheduled(), isFalse, reason: 'not on one post-wake reading');

      s.reading();
      expect(s.guest.clock.acceptedSampleCount, acceptedBefore + 2);
      await s.guest.sync.checkDriftNow();
      expect(scheduled(), isFalse, reason: 'nor on two');

      s.reading();
      await s.guest.sync.checkDriftNow();
      await waitFor(
        scheduled,
        timeout: const Duration(seconds: 3),
        reason: 'the re-anchor once three readings confirmed the clock',
      );
      expect(
        s.acceptedAt[s.log.firstWhere((c) => c.method == 'playAt')],
        acceptedBefore + 3,
      );
      expect(s.guest.connectionState, JamConnectionState.connected);
    });

    test('a re-schedule that is not a state frame (a nudge) right after a '
        'wake is not built on the pre-sleep mapping either', () async {
      final s = await playing(
        clockWakeTimeout: const Duration(milliseconds: 1500),
      );
      s.log.clear();
      JamGuestEngine.wallClock = () =>
          DateTime.now().add(const Duration(seconds: 30));
      await s.guest.setNudgeUs(40000, persist: false);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(
        s.log.where((c) => c.method == 'playAt'),
        isEmpty,
        reason: 'nothing scheduled while the clock is distrusted',
      );
      await waitFor(
        () => s.log.any((c) => c.method == 'playAt'),
        timeout: const Duration(seconds: 4),
        reason: 'the re-anchor once trusted',
      );
    });

    test('the wake timeout does not re-trust a clock whose connection is '
        'down; the fresh connection does', () async {
      final s = await playing(
        clockWakeTimeout: const Duration(milliseconds: 600),
        backoff: fast(2500),
      );
      s.host.kickPeer(s.guest.selfPeerId, allowResume: true);
      await waitFor(
        () => s.guest.connectionState == JamConnectionState.reconnecting,
        reason: 'the drop',
      );
      JamGuestEngine.wallClock = () =>
          DateTime.now().add(const Duration(seconds: 30));
      s.log.clear();
      await s.guest.handleLifecycleState(AppLifecycleState.resumed);
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expect(
        s.guest.connectionState,
        JamConnectionState.reconnecting,
        reason: 'still down (test premise)',
      );
      expect(
        s.log.where((c) => c.method == 'playAt'),
        isEmpty,
        reason: 'the timeout passed, but nothing confirmed the clock',
      );
      await waitFor(
        () => s.log.any((c) => c.method == 'playAt'),
        timeout: const Duration(seconds: 6),
        reason: 'the reconnect re-syncs and re-anchors',
      );
      expect(s.guest.connectionState, JamConnectionState.connected);
    });

    test('a replaced connection is trusted at once, long before the wake '
        'timeout', () async {
      final s = await playing(clockWakeTimeout: const Duration(seconds: 20));
      JamGuestEngine.wallClock = () =>
          DateTime.now().add(const Duration(seconds: 30));
      await s.guest.handleLifecycleState(AppLifecycleState.resumed);
      s.log.clear();
      s.host.kickPeer(s.guest.selfPeerId, allowResume: true);
      await waitFor(
        () => s.log.any((c) => c.method == 'playAt'),
        timeout: const Duration(seconds: 5),
        reason: 'the fresh connection re-anchors',
      );
    });
  });

  group('a host that said it is away (§3.5)', () {
    test('is not sent requests; uploads say why; it coming back reopens '
        'both', () async {
      mockAudioChannel();
      final host = await startHost();
      final track = await addTrack(host, 9);
      final guest = await join(host);
      expect(guest.canSendCommands, isTrue);

      await host.announceAway(true);
      await waitFor(() => guest.hostAway.value, reason: 'away');
      expect(guest.canSendCommands, isFalse);
      expect(await guest.requestPause(), isFalse);
      expect(await guest.transportSetMedia(track.item.mediaId), isFalse);
      await expectLater(
        guest.addMedia(await writeTempMedia(makeMediaBytes(64))),
        throwsA(
          isA<JamNotConnectedException>().having(
            (e) => e.hostAway,
            'hostAway',
            isTrue,
          ),
        ),
      );

      await host.announceAway(false);
      await waitFor(() => !guest.hostAway.value, reason: 'back');
      expect(guest.canSendCommands, isTrue);
      expect(await guest.transportSetMedia(track.item.mediaId), isTrue);
      await waitFor(
        () => host.snapshot.mediaId == track.item.mediaId,
        reason: 'the request applied',
      );
    });
  });

  group('intents (one UI for host and guest)', () {
    test('headphones out while the room is paused: someone else\'s play '
        'holds this guest silent ("Headphones disconnected"); its own '
        'play plays where it is now', () async {
      final log = mockAudioChannel(routeId: () => 'wired:abc');
      final push = mockAudioEvents();
      final host = await startHost();
      final track = await addTrack(host, 13);
      host
        ..setMedia(track.item.mediaId)
        ..play()
        ..pause(); // Paused mid-track, not just cued (`loading`).
      expect(host.snapshot.status, PlaybackStatus.paused);
      final guest = await join(host);
      await waitFor(
        () =>
            guest.clockSynced &&
            (guest.prefetchStates.value[track.item.mediaId]?.ready ?? false),
        reason: 'clock sync and the track',
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      push({
        'type': 'routeChanged',
        'routeId': 'speaker',
        'oldDeviceUnavailable': true,
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(guest.outputSuspension.value, isNull, reason: 'nothing played');

      host.play(); // The host — not this guest — starts the room.
      await waitFor(
        () => guest.outputSuspension.value != null,
        reason: 'the start held',
      );
      expect(
        guest.outputSuspension.value!.reason,
        JamOutputSuspendReason.outputLost,
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(log.where((c) => c.method == 'playAt'), isEmpty);

      // Again, paused; and this time it is this guest who presses play.
      host.pause();
      await guest.resumeLocalOutput();
      await waitFor(
        () => guest.snapshot.status == PlaybackStatus.paused,
        reason: 'paused',
      );
      push({
        'type': 'routeChanged',
        'routeId': 'bt:xyz',
        'oldDeviceUnavailable': true,
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      log.clear();
      expect(await guest.transportPlay(), isTrue);
      await waitFor(
        () => log.any((c) => c.method == 'playAt'),
        reason: 'its own play is heard',
      );
      expect(guest.outputSuspension.value, isNull);
    });

    test('an id not in the queue is refused without a request; transportPlay '
        'on a playing room sends nothing and resumes local output', () async {
      final log = mockAudioChannel();
      final push = mockAudioEvents();
      final host = await startHost();
      final track = await addTrack(host, 11);
      host.setMedia(track.item.mediaId);
      final guest = await join(host);
      expect(await guest.transportSetMedia('m_not_here'), isFalse);
      expect(await guest.queueMove('m_not_here', 0), isFalse);
      expect(await guest.queueRemove('m_not_here'), isFalse);

      expect(await guest.transportPlay(), isTrue);
      await waitFor(
        () => host.snapshot.status == PlaybackStatus.playing,
        reason: 'the room playing',
      );
      await waitFor(
        () => log.any((c) => c.method == 'playAt'),
        timeout: const Duration(seconds: 4),
        reason: 'the guest scheduled',
      );
      final rev = host.snapshot.rev;

      // Headphones out: local silence while the room plays on.
      push({'type': 'routeChanged', 'oldDeviceUnavailable': true});
      await waitFor(
        () => guest.outputSuspension.value != null,
        reason: 'output lost',
      );
      log.clear();
      expect(await guest.transportPlay(), isTrue);
      expect(guest.outputSuspension.value, isNull);
      await waitFor(
        () => log.any((c) => c.method == 'playAt'),
        reason: 'local re-anchor',
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(host.snapshot.rev, rev, reason: 'no play re-sent to the room');
    });
  });
}
