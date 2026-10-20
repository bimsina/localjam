/// Reproducible captures of production widgets with fixture media and native
/// channels stubbed. Run from apps/localjam_app:
/// flutter test tool/capture_design.dart --reporter expanded
/// PNGs and a manifest are written to docs/screenshots/identity-v4.
// This capture harness intentionally uses test-only engine seams.
// ignore_for_file: invalid_use_of_visible_for_testing_member, use_build_context_synchronously
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:localjam_app/src/design/theme.dart';
import 'package:localjam_app/src/router.dart';
import 'package:localjam_app/src/screens/history_screen.dart';
import 'package:localjam_app/src/screens/home_screen.dart';
import 'package:localjam_app/src/screens/host_setup_screen.dart';
import 'package:localjam_app/src/screens/onboarding_screen.dart';
import 'package:localjam_app/src/screens/room_screen.dart';
import 'package:localjam_app/src/screens/session_ended_view.dart';
import 'package:localjam_app/src/screens/scan_screen.dart';
import 'package:localjam_app/src/screens/settings_screen.dart';
import 'package:localjam_app/src/screens/licenses_screen.dart';
import 'package:localjam_app/src/state/app_settings.dart';
import 'package:localjam_app/src/state/session_controller.dart';
import 'package:localjam_app/src/util/network.dart';
import 'package:localjam_app/src/widgets/diagnostics_sheet.dart';
import 'package:localjam_app/src/widgets/artwork.dart';
import 'package:localjam_app/src/widgets/dialogs.dart';
import 'package:localjam_app/src/widgets/join_link_dialog.dart';
import 'package:localjam_app/src/widgets/library_sheet.dart';
import 'package:localjam_app/src/widgets/permission_sheet.dart';
import 'package:localjam_app/src/widgets/room_sheet.dart';
import 'package:localjam_client/localjam_client.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../test/fixtures.dart';
import '../test/harness.dart';

const lan = JamNetworkStatus(addresses: ['192.168.1.12'], interface: 'en0');
final output = Directory('../../docs/screenshots/identity-v4');
final manifest = <Map<String, Object>>[];
const songs = [
  ('Sunroom', 'The Sunday Club'),
  ('Slow Morning', 'Mira Sol'),
  ('A Little Longer', 'Paper Planes'),
  ('Soft Focus', 'Olive & June'),
  ('After the Rain', 'Northbound'),
  ('Stay a While', 'The Sunday Club'),
];

Future<void> loadFonts() async {
  Future<void> font(String name, ByteData bytes) async {
    await (FontLoader(name)..addFont(Future.value(bytes))).load();
  }

  await font('Manrope', await rootBundle.load('assets/fonts/Manrope.ttf'));
  final sf = File('/System/Library/Fonts/SFNS.ttf');
  // SF remains local to this machine; no Apple font is copied into the repo.
  if (!sf.existsSync()) {
    throw StateError('Capture on macOS for system SF fonts.');
  }
  final data = ByteData.sublistView(await sf.readAsBytes());
  for (final name in [
    'CupertinoSystemText',
    'CupertinoSystemDisplay',
    '.AppleSystemUIFont',
  ]) {
    await font(name, data);
  }
  await font(
    'packages/cupertino_icons/CupertinoIcons',
    await rootBundle.load('packages/cupertino_icons/assets/CupertinoIcons.ttf'),
  );
  await font(
    'MaterialIcons',
    await rootBundle.load('fonts/MaterialIcons-Regular.otf'),
  );
}

/// Original vector cover fixtures, drawn to PNG for the real artwork pipeline.
Future<Uint8List> cover(int index) async {
  const palette = [
    Color(0xFFCA6B43),
    Color(0xFF698B78),
    Color(0xFFB8A0BB),
    Color(0xFF5D798B),
    Color(0xFFBE9B5A),
    Color(0xFF8A594D),
  ];
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawColor(palette[index % palette.length], BlendMode.src);
  final cream = Paint()..color = const Color(0xFFF1D7AD);
  canvas.drawCircle(const Offset(350, 180), 118, cream);
  canvas.drawRect(
    const Rect.fromLTWH(0, 340, 512, 172),
    Paint()..color = const Color(0xFF303E35),
  );
  for (var i = 0; i < 5; i++) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(48 + i * 93, 220, 54, 340),
        const Radius.circular(28),
      ),
      Paint()..color = palette[index % palette.length].withValues(alpha: 0.9),
    );
  }
  void text(String label, double y, double size, FontWeight weight) {
    final painter = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          fontFamily: 'Manrope',
          fontSize: size,
          fontWeight: weight,
          color: const Color(0xFFFFF3DE),
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: 420);
    painter.paint(canvas, Offset(34, y));
  }

  text(songs[index].$2, 34, 18, FontWeight.w500);
  text(songs[index].$1, 65, 46, FontWeight.w700);
  final picture = recorder.endRecording();
  final image = await picture.toImage(512, 512);
  final png = (await image.toByteData(
    format: ui.ImageByteFormat.png,
  ))!.buffer.asUint8List();
  image.dispose();
  picture.dispose();
  return png;
}

class Capture {
  Capture(this.tester, this.session, this.dark);
  final WidgetTester tester;
  final JamSessionController session;
  final bool dark;
  final boundary = GlobalKey();
  final navigator = GlobalKey<NavigatorState>();
  final settings = JamAppSettings();
  GoRouter? router;
  Size size = const Size(402, 874);
  double scale = 1;
  BuildContext get context => navigator.currentContext!;
  ThemeData get theme => dark
      ? jamDarkTheme(platform: TargetPlatform.iOS)
      : jamLightTheme(platform: TargetPlatform.iOS);

  Future<void> mount(Widget page, {bool routed = false}) async {
    await tester.pumpWidget(const SizedBox());
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    Widget builder(BuildContext context, Widget? child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        padding: const EdgeInsets.only(top: 24, bottom: 24),
        viewPadding: const EdgeInsets.only(top: 24, bottom: 24),
        textScaler: TextScaler.linear(scale),
      ),
      child: child!,
    );
    router?.dispose();
    router = null;
    if (routed) router = buildRouter(session);
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: JamSettings(
          settings: settings,
          child: JamSession(
            controller: session,
            child: routed
                ? MaterialApp.router(
                    debugShowCheckedModeBanner: false,
                    theme: theme,
                    routerConfig: router,
                    builder: builder,
                  )
                : MaterialApp(
                    debugShowCheckedModeBanner: false,
                    theme: theme,
                    navigatorKey: navigator,
                    home: page,
                    builder: builder,
                  ),
          ),
        ),
      ),
    );
    await settle();
  }

  Future<void> settle() async {
    // Drain file reads, image decoding and backdrop sampling between frames.
    for (var cycle = 0; cycle < 12; cycle++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  Future<void> snap(
    String name, {
    String note =
        'Production widgets; fixture content and mocked native services.',
  }) async {
    await settle();
    expect(tester.takeException(), isNull, reason: name);
    (boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary)
        .markNeedsPaint();
    await tester.pump();
    if (name == '17-queue') {
      expect(
        tester
            .widgetList<JamArtworkTile>(find.byType(JamArtworkTile))
            .where((tile) => tile.bytes != null)
            .length,
        greaterThan(1),
        reason: 'Queue covers must load before the screenshot',
      );
    }
    final filename = '${dark ? 'dark' : 'light'}-$name.png';
    await tester.runAsync(() async {
      final render =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await render.toImage(pixelRatio: 2);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      await File(
        '${output.path}/$filename',
      ).writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    });
    manifest.add({
      'file': filename,
      'name': name,
      'theme': dark ? 'dark' : 'light',
      'width': size.width.toInt(),
      'height': size.height.toInt(),
      'note': note,
    });
    // Visible progress while the capture suite runs.
    debugPrint('Captured $filename');
  }

  Future<void> dismiss() async {
    Navigator.of(tester.element(find.byType(RoomScreen))).pop();
    await settle();
  }
}

class DesignBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  bool get disableShadows => false;
}

void main() {
  DesignBinding();
  setUpAll(() async {
    await output.create(recursive: true);
    await loadFonts();
  });
  tearDownAll(() async {
    await File(
      '${output.path}/manifest.json',
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(manifest));
  });

  for (final dark in [false, true]) {
    testWidgets('capture ${dark ? 'dark' : 'light'} pages and states', (
      tester,
    ) async {
      LicenseRegistry.reset();
      LicenseRegistry.addLicense(() async* {
        yield LicenseEntryWithLineBreaks([
          'Manrope',
        ], File('assets/fonts/OFL.txt').readAsStringSync());
      });
      final session = testSession(identity: 'Bibek');
      mockNativeChannels(durationUs: 240000000);
      final cap = Capture(tester, session, dark);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('dev.fluttercommunity.plus/package_info'),
        (_) async => {
          'appName': 'LocalJam',
          'packageName': 'app.localjam',
          'version': '1.0.0',
          'buildNumber': '1',
          'buildSignature': '',
        },
      );

      await cap.mount(const OnboardingScreen());
      await cap.snap('01-onboarding');
      await cap.mount(
        HomeScreen(networkReader: () async => lan, loadRecords: () async => []),
      );
      await cap.snap('02-nearby-empty');
      await cap.mount(
        HomeScreen(
          key: UniqueKey(),
          networkReader: () async => JamNetworkStatus.offline,
          loadRecords: () async => [],
        ),
      );
      await cap.snap('03-nearby-offline');
      await cap.mount(
        HomeScreen(
          key: UniqueKey(),
          networkReader: () async => const JamNetworkStatus(
            addresses: ['172.20.10.1'],
            interface: 'bridge100',
          ),
          loadRecords: () async => [],
        ),
      );
      await cap.snap('04-nearby-hotspot');
      (session.nearbyRooms as ValueNotifier<List<JamNearbyRoom>>).value = [
        for (final name in ['Sunday at home', 'Mia’s Jam', 'The late shift'])
          JamNearbyRoom(
            key: name,
            sessionName: name,
            joinUri: Uri.parse(
              'localjam://join?host=192.168.1.14&port=4242&token=preview&name=${Uri.encodeComponent(name)}',
            ),
          ),
      ];
      await cap.mount(
        HomeScreen(
          key: UniqueKey(),
          networkReader: () async => lan,
          loadRecords: () async => [],
        ),
      );
      await cap.snap('05-nearby-available');
      unawaited(promptForJoinLink(cap.context));
      await cap.snap('06-join-link');
      await tester.enterText(
        find.byType(CupertinoTextField).last,
        'not-a-jam-link',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await cap.snap('07-join-link-invalid');
      Navigator.of(tester.element(find.byType(JoinLinkDialog))).pop();
      await cap.settle();
      await cap.mount(
        const HostSetupScreen(initialPaths: [], initialName: 'Sunday at home'),
      );
      await cap.snap('08-start-jam-empty');
      await cap.mount(const SettingsScreen());
      await cap.snap('09-settings');
      await tester.tap(find.text('Bibek'));
      await cap.snap('09-settings-rename');
      await tester.tap(find.text('Cancel'));
      await cap.settle();
      await cap.mount(
        const JamLicensesScreen(
          applicationName: 'LocalJam',
          applicationVersion: '1.0.0',
        ),
      );
      await cap.snap('10-licenses');
      expect(find.text('Manrope'), findsOneWidget);
      if (find.text('Manrope').evaluate().isNotEmpty) {
        await tester.tap(find.text('Manrope'));
        await cap.snap('10-license-detail');
      }
      await cap.mount(HistoryScreen(loadRecords: () async => []));
      await cap.snap('11-history-empty');

      // Real engine + real queue, with native audio mocked by the test harness.
      await tester.runAsync(
        () => session.startHost(
          sessionName: 'Sunday at home',
          discoverable: false,
        ),
      );
      final host = session.hostEngine!;
      final paths = makeTestTracks(count: songs.length);
      final items = <MediaItem>[];
      await tester.runAsync(() async {
        for (var i = 0; i < songs.length; i++) {
          final artId = await host.debugServer.addArtwork(
            await cover(i),
            mime: 'image/png',
          );
          final file = File(paths[i]);
          final item = await JamHostServer.describeFile(
            file,
            kind: MediaKind.audio,
            mime: 'audio/wav',
            title: songs[i].$1,
            artist: songs[i].$2,
            album: 'Sunday sessions',
            durationUs: 240000000 + i * 10000000,
            artworkId: artId,
            addedBy: 'host',
          );
          host.debugServer.addMedia(item, file);
          items.add(item);
        }
        host.setMedia(items.first.mediaId);
        host.seek(83000000);
      });
      final record = JamHistoryRecord(
        sessionId: 'sunday-preview',
        sessionName: 'Sunday at home',
        wasHost: true,
        startedAt: DateTime(2026, 10, 18, 16),
        updatedAt: DateTime(2026, 10, 18, 17),
        peerNames: ['Mia', 'Theo'],
        tracks: [
          for (var i = 0; i < items.length; i++)
            JamHistoryTrack(
              item: items[i],
              addedByName: i.isEven ? 'You' : 'Mia',
              localPath: paths[i],
            ),
        ],
      );
      await cap.mount(
        HistoryScreen(
          loadRecords: () async => [record],
          forgetRecord: (_) async {},
          restoreRecord: (_) async {},
        ),
      );
      await cap.snap('12-history-populated');
      await cap.mount(
        HistoryDetailScreen(record: record, forgetRecord: (_) async {}),
      );
      await cap.snap('13-history-detail');
      await cap.mount(
        HostSetupScreen(initialName: 'Sunday at home', initialPaths: paths),
      );
      await cap.snap('14-start-jam-songs');
      final previousHttp = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = previousHttp);
      final guest = JamSessionController();
      final cache = Directory.systemTemp.createTempSync(
        'localjam_gallery_guest',
      );
      addTearDown(() async {
        await guest.leave();
        guest.dispose();
        cache.deleteSync(recursive: true);
      });
      await tester.runAsync(() async {
        expect(
          await guest.join(
            host.joinUriFor(InternetAddress.loopbackIPv4),
            clientName: 'Mia',
            mediaCacheDir: cache,
          ),
          isTrue,
        );
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (!(guest
                    .guestEngine!
                    .prefetchStates
                    .value[items.first.mediaId]
                    ?.ready ??
                false) &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 30));
        }
      });
      await cap.mount(const RoomScreen());
      await cap.snap('15-player-paused');
      await tester.runAsync(() async {
        host.play();
      });
      await cap.snap('16-player-playing');
      await tester.tap(find.bySemanticsLabel(JamRoomStrings.queue));
      await cap.snap('17-queue');
      await tester.longPress(find.text('Slow Morning'));
      await cap.snap('17-queue-song-menu');
      await tester.tapAt(const Offset(20, 100));
      await cap.settle();
      await tester.tap(find.bySemanticsLabel(JamRoomStrings.queue));
      await cap.settle();
      await tester.tap(find.bySemanticsLabel(JamRoomStrings.more));
      await cap.snap('18-player-menu');
      await tester.tap(find.text(JamRoomStrings.soundOffset));
      await cap.snap('19-sound-offset');
      await cap.dismiss();
      unawaited(
        showDiagnosticsSheet(tester.element(find.byType(RoomScreen)), host),
      );
      await cap.snap('20-diagnostics');
      await cap.dismiss();
      unawaited(
        showRoomSheet(
          tester.element(find.byType(RoomScreen)),
          host,
          selfName: 'Bibek',
          network: lan,
        ),
      );
      await cap.snap('21-people-host');
      await tester.drag(find.byType(RoomPanel), const Offset(0, -280));
      await cap.snap('21-people-host-expanded');
      await cap.dismiss();
      // Shareable address is a deterministic fixture, never published.
      (host.lanAddresses as ValueNotifier<List<InternetAddress>>).value = [
        InternetAddress('192.168.1.12'),
      ];
      (host.joinUriListenable as ValueNotifier<Uri>).value = Uri.parse(
        'localjam://join?host=192.168.1.12&port=4242&token=preview&name=Sunday',
      );
      unawaited(
        showInviteSheet(
          tester.element(find.byType(RoomScreen)),
          host,
          selfName: 'Bibek',
          network: lan,
        ),
      );
      await cap.snap('22-invite');
      await tester.tap(find.text(RoomSheetStrings.copyLink));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 80)),
      );
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text(RoomSheetStrings.copied), findsOneWidget);
      // Capture the transient confirmation before its 1.5s timer resets.
      final render =
          cap.boundary.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      render.markNeedsPaint();
      await tester.pump();
      await tester.runAsync(() async {
        final image = await render.toImage(pixelRatio: 2);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        final name = '${dark ? 'dark' : 'light'}-22-invite-copied.png';
        await File(
          '${output.path}/$name',
        ).writeAsBytes(data!.buffer.asUint8List());
        manifest.add({
          'file': name,
          'name': '22-invite-copied',
          'theme': dark ? 'dark' : 'light',
          'width': 402,
          'height': 874,
          'note': 'In-place copy confirmation.',
        });
        image.dispose();
      });
      await cap.dismiss();
      (host.lanAddresses as ValueNotifier<List<InternetAddress>>).value = [];
      unawaited(
        showInviteSheet(
          tester.element(find.byType(RoomScreen)),
          host,
          selfName: 'Bibek',
          network: JamNetworkStatus.offline,
        ),
      );
      await cap.snap('23-invite-offline');
      await cap.dismiss();
      unawaited(
        JamDialogs.confirmDestructive(
          tester.element(find.byType(RoomScreen)),
          title: 'End Jam?',
          message: 'The music stops for everyone.',
          confirmLabel: 'End Jam',
        ),
      );
      await cap.snap('24-end-confirmation');
      await cap.dismiss();

      await cap.mount(const SizedBox(), routed: true);
      await cap.snap('25-nearby-mini-player');
      cap.router!.push('/room');
      await cap.settle();
      cap.size = const Size(1280, 900);
      tester.view.physicalSize = cap.size;
      await cap.snap('26-desktop-player');
      cap.size = const Size(834, 1194);
      tester.view.physicalSize = cap.size;
      await cap.snap('27-tablet-player');
      cap.size = const Size(874, 402);
      tester.view.physicalSize = cap.size;
      await cap.snap('28-landscape-player');
      cap.size = const Size(375, 812);
      cap.scale = 1.3;
      await cap.mount(const RoomScreen());
      await cap.snap('29-player-large-text');
      cap.size = const Size(402, 874);
      cap.scale = 1;
      await cap.mount(const RoomScreen());
      // Native output interruption, fed through the same channel as a device.
      await tester.runAsync(() async {
        await messenger.handlePlatformMessage(
          'localjam_audio/events',
          const StandardMethodCodec().encodeSuccessEnvelope({
            'type': 'interruptionBegan',
            'shouldResume': false,
          }),
          (_) {},
        );
      });

      await tester.runAsync(host.resumeLocalOutput);

      // The guest sees the same player with capability-gated controls.
      await tester.runAsync(() => JamIdentity.setDisplayName('Mia'));
      final guestCap = Capture(tester, guest, dark);
      await guestCap.mount(const RoomScreen());
      expect(guest.guestEngine!.outputSuspension.value, isNotNull);
      await guestCap.snap('29-player-audio-interrupted');
      await tester.runAsync(guest.guestEngine!.resumeLocalOutput);
      await guestCap.snap('38-guest-add-music');
      await tester.runAsync(() async {
        host.setPolicy(JamPolicy.listenOnly);
      });
      await guestCap.snap('39-guest-listen-only');
      await tester.tap(find.bySemanticsLabel(JamRoomStrings.queue));
      await guestCap.snap('40-guest-queue-read-only');
      await tester.tap(find.bySemanticsLabel(JamRoomStrings.queue));
      await guestCap.settle();
      unawaited(
        showRoomSheet(
          tester.element(find.byType(RoomScreen)),
          guest.engine!,
          selfName: 'Mia',
          network: lan,
        ),
      );
      await guestCap.snap('41-people-guest');
      await guestCap.dismiss();
      await tester.runAsync(() async {
        host.setPolicy(JamPolicy.open);
      });
      await guestCap.snap('42-guest-playback-control');
      (guest.guestEngine!.hostAway as ValueNotifier<bool>).value = true;
      await guestCap.snap(
        '43-guest-host-asleep',
        note: 'Production guest UI with deterministic host-away state.',
      );
      (guest.guestEngine!.hostAway as ValueNotifier<bool>).value = false;
      final prefetch =
          guest.guestEngine!.prefetchStates
              as ValueNotifier<Map<String, JamPrefetchState>>;
      final saved = prefetch.value;
      prefetch.value = {
        ...saved,
        items.first.mediaId: const JamPrefetchState(
          phase: JamPrefetchPhase.fetching,
          progress: 0.35,
        ),
      };
      await guestCap.snap(
        '44-guest-downloading',
        note: 'Production guest UI with deterministic transfer progress.',
      );
      prefetch.value = {
        ...saved,
        items.first.mediaId: const JamPrefetchState(
          phase: JamPrefetchPhase.failed,
          failures: 6,
          willRetry: false,
        ),
      };
      await guestCap.snap(
        '45-guest-download-failed',
        note: 'Production guest UI with deterministic failed transfer.',
      );
      prefetch.value = saved;
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(guest.leave);
      guestCap.settings.dispose();
      await tester.runAsync(() => JamIdentity.setDisplayName('Bibek'));
      await cap.mount(const RoomScreen());
      await tester.runAsync(() async {
        host.pause();
        host.stop();
        for (final item in items) {
          host.removeMediaItem(item.mediaId);
        }
      });
      await cap.snap('30-player-empty');
      await tester.tap(find.bySemanticsLabel(JamRoomStrings.queue));
      await cap.snap('31-queue-empty');
      await cap.mount(
        JamSessionEndedView(
          reason: JamSessionEndReason.hostGone,
          onDone: () {},
          onRetry: () {},
          retrying: true,
        ),
      );
      await cap.snap('32-session-retrying');
      await cap.mount(
        JamSessionEndedView(
          reason: JamSessionEndReason.hostGone,
          onDone: () {},
          onRetry: () {},
          error: 'Couldn’t get back into that jam.',
        ),
      );
      await cap.snap('32-session-retry-failed');
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(session.leave);

      for (final (label, reason, reject) in [
        ('ended', JamSessionEndReason.hostEnded, null),
        ('removed', JamSessionEndReason.kicked, null),
        ('host-gone', JamSessionEndReason.hostGone, null),
        ('restarted', JamSessionEndReason.rejected, RejectReason.badToken),
        ('full', JamSessionEndReason.rejected, RejectReason.full),
        ('update-needed', JamSessionEndReason.rejected, RejectReason.version),
        ('rejected', JamSessionEndReason.rejected, RejectReason.unknown),
        ('listener-failed', JamSessionEndReason.listenerFailed, null),
      ]) {
        await cap.mount(
          JamSessionEndedView(
            reason: reason,
            rejectReason: reject,
            onDone: () {},
            onRetry:
                reason == JamSessionEndReason.hostGone ||
                    (reason == JamSessionEndReason.rejected &&
                        jamRejectIsRetryable(reject))
                ? () {}
                : null,
            onStartNew: reason == JamSessionEndReason.listenerFailed
                ? () {}
                : null,
          ),
        );
        await cap.snap('32-session-$label');
      }
      for (final (label, code, declined) in [
        ('denied', MobileScannerErrorCode.permissionDenied, false),
        ('declined', MobileScannerErrorCode.permissionDenied, true),
        ('unavailable', MobileScannerErrorCode.unsupported, false),
        ('failed', MobileScannerErrorCode.genericError, false),
      ]) {
        await cap.mount(
          Scaffold(
            body: ScannerUnavailableView(
              error: MobileScannerException(errorCode: code),
              declined: declined,
              onClose: () {},
              onLink: () async {},
              onRetry: () {},
            ),
          ),
        );
        await cap.snap(
          '33-scanner-$label',
          note:
              'Actual scanner error view; live camera feed requires a device.',
        );
      }
      for (final (label, rationale) in [
        ('network', JamPermissionRationale.localNetwork),
        ('camera', JamPermissionRationale.camera),
        ('notifications', JamPermissionRationale.notifications),
        ('library', JamPermissionRationale.audioLibrary),
      ]) {
        await cap.mount(
          HomeScreen(
            networkReader: () async => lan,
            loadRecords: () async => [],
          ),
        );
        unawaited(showJamPermissionSheet(cap.context, rationale));
        await cap.snap('34-permission-$label');
        Navigator.of(tester.element(find.byType(JamPermissionSheet))).pop();
        await cap.settle();
      }
      final library = [
        for (var i = 0; i < songs.length; i++)
          JamLibraryTrack(
            id: i,
            title: songs[i].$1,
            artist: songs[i].$2,
            durationMs: 240000,
            sizeBytes: 1000,
            contentUri: 'content://preview/$i',
          ),
      ];
      await cap.mount(
        HomeScreen(networkReader: () async => lan, loadRecords: () async => []),
      );
      unawaited(showJamLibrarySheet(cap.context, library));
      await cap.snap('35-library');
      await tester.tap(find.text('Sunroom'));
      await tester.tap(find.text('Slow Morning'));
      await cap.snap('36-library-selected');
      await tester.enterText(
        find.byType(CupertinoSearchTextField),
        'missing song',
      );
      await cap.snap('37-library-no-results');
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await session.leave();
        await session.stopBrowsing();
      });
      cap.router?.dispose();
      cap.settings.dispose();
    }, timeout: const Timeout(Duration(minutes: 4)));
  }
}
