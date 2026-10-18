/// Full-screen QR scanner for `localjam://join?...` codes. Pops with the
/// scanned URI string, or null when dismissed (DESIGN_SPEC v3 §6.10).
///
/// Camera-first, like the system Code Scanner: the feed fills the screen on
/// black, a rounded white viewfinder outline sits in the middle with the
/// rest of the feed dimmed, a caption under it says what to do, a glass
/// xmark closes, and **Enter Link** at the bottom is the way through when
/// there is nothing to scan.
///
/// The camera is the one part of joining that can simply not be available —
/// denied, missing, or busy — so this screen carries its own dead ends on
/// the same black page: it says which one happened, offers Settings or
/// another go where that can help, and always offers the link.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Scaffold;
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../design/theme.dart';
import '../design/tokens.dart';
import '../design/typography.dart';
import '../util/network.dart';
import '../util/permissions.dart';
import '../widgets/buttons.dart';
import '../widgets/empty_state.dart';
import '../widgets/glass.dart';
import '../widgets/join_link_dialog.dart';

/// Every user-facing string this screen can show.
abstract final class JamScanStrings {
  /// Announced for the viewfinder.
  static const String title = 'Scan a Code';
  static const String hint = 'Point at a LocalJam code';
  static const String wrongCode = 'That isn’t a LocalJam code.';
  static const String found = 'Joining…';
  static const String enterLink = 'Enter Link';
  static const String close = 'Close';
  static const String torchOn = 'Turn On Flashlight';
  static const String torchOff = 'Turn Off Flashlight';

  static const String deniedTitle = 'No Camera Access';
  static const String deniedBody = JamPermissionCopy.cameraDenied;
  static const String openSettings = 'Open Settings';

  /// The rationale sheet was answered with Back or "Not now", so the OS was
  /// never asked and there is nothing in Settings to turn on. Telling this
  /// user to "turn on camera access in Settings" sends them to a switch that
  /// is already where it should be, to fix a permission they never denied.
  static const String declinedTitle = 'Camera Access Needed';
  static const String declinedBody =
      'Try Again to allow camera access, or enter a link instead.';
  static const String unsupportedTitle = 'Camera Unavailable';
  static const String unsupportedBody =
      'This device can’t scan codes. Enter a link instead.';
  static const String failedTitle = 'The Camera Didn’t Start';
  static const String failedBody =
      'Something else may be using it. Try again, or enter a link.';
  static const String retry = 'Try Again';
}

/// The viewfinder's share of the screen's shorter side…
const double kScanWindowFraction = 0.7;

/// …held to this on tablets and desktops.
const double kScanWindowMax = 320;

/// The viewfinder's corner radius and outline (§6.10).
const double kScanWindowRadius = 24;
const double _outlineWidth = 2;

/// How much the feed outside the viewfinder is dimmed.
const double _dimOpacity = 0.5;

/// The viewfinder side for a screen of [size].
double scanWindowFor(Size size) =>
    math.min(size.shortestSide * kScanWindowFraction, kScanWindowMax);

class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  /// Not `final`: "Try again" builds a fresh one, because a
  /// [MobileScannerController] is single-use — once disposed (or once its
  /// camera session has gone) it only ever throws `controllerDisposed`.
  ///
  /// `autoStart: false` so the *start* is ours. Left to the widget, it runs
  /// as `unawaited(controller.start())` inside `MobileScanner.initState`, and
  /// anything it throws that is not a `MobileScannerException` — a raw
  /// `PlatformException` off the channel — lands in the zone with nobody
  /// holding it. That was one of the paths still reaching the global handler.
  MobileScannerController _controller = MobileScannerController(
    autoStart: false,
  );
  bool _done = false;

  /// Whether the camera has been asked for yet. Until it has, the screen
  /// shows nothing rather than a viewfinder that is about to be replaced.
  bool _checkedCamera = false;

  /// True once the user has answered the camera prompt with a yes. The
  /// scanner is not built until then, which is the whole point: leaving
  /// `mobile_scanner` to ask meant its denial arrived as an `errorBuilder`
  /// widget *inside* the viewfinder stack, so the dead-end page rendered
  /// under the scrim, inside the viewfinder cut-out, with the
  /// scanner's own close button stacked on top of its own. The permission is
  /// this screen's state now, not the camera widget's error.
  bool _cameraAllowed = false;

  /// The user backed out of *our* rationale sheet, so the OS prompt never
  /// fired. A different dead end from a denial: nothing was refused, and the
  /// way out is to ask again rather than to open Settings.
  bool _cameraDeclined = false;

  /// Set when a code scanned cleanly but was not a jam invite. Silence here
  /// read as a broken scanner: the code is right there in frame and nothing
  /// happens.
  String? _wrongCode;
  Timer? _wrongCodeTimer;

  /// The first failure anything about the scanner reported, if any.
  ///
  /// There are four ways one can arrive — the permission answer, the
  /// `start()` future, the barcode stream's error events (`onDetectError`),
  /// and the controller's own error state (`errorBuilder`) — and the
  /// simulator's vision stack fails *per frame*
  /// (`MOBILE_SCANNER_BARCODE_ERROR, Could not create inference context`), so
  /// a two-minute visit logged 496 of them. All four now land in [_fail],
  /// which latches the first: it swaps in the dead-end UI, logs one line, and
  /// drops every one after it.
  MobileScannerException? _scanFailure;

  @override
  void initState() {
    super.initState();
    unawaited(_askForCamera());
  }

  /// Explains the camera, asks for it, and starts the scanner if allowed.
  ///
  /// A refusal is not an error state — it is the denied page, reached the
  /// same way whether the OS said no or the rationale sheet did.
  Future<void> _askForCamera() async {
    final outcome = await requestCameraPermission();
    if (!mounted) return;
    final allowed =
        outcome == JamPermissionOutcome.granted ||
        outcome == JamPermissionOutcome.unsupported;
    setState(() {
      _checkedCamera = true;
      _cameraAllowed = allowed;
      _cameraDeclined = outcome == JamPermissionOutcome.dismissed;
    });
    if (!allowed) {
      _fail(
        const MobileScannerException(
          errorCode: MobileScannerErrorCode.permissionDenied,
        ),
      );
      return;
    }
    await _start();
  }

  /// Starts the camera, holding everything it can throw.
  ///
  /// `start()` waits for the widget to attach the controller, so this runs
  /// after the frame that mounts [MobileScanner] — otherwise a perfectly
  /// good camera reports `controllerNotAttached`.
  Future<void> _start() async {
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || _scanFailure != null) return;
    try {
      await _controller.start();
    } catch (error) {
      _fail(error);
    }
  }

  @override
  void dispose() {
    _wrongCodeTimer?.cancel();
    _disposeController(_controller);
    super.dispose();
  }

  /// Disposing a controller can throw off the platform channel too, and a
  /// screen being popped is the last place that should take the app down.
  static void _disposeController(MobileScannerController controller) {
    unawaited(
      controller.dispose().catchError(
        (Object e) => debugPrint('localjam: scanner dispose failed: $e'),
      ),
    );
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      if (value == null || value.trim().isEmpty) continue;
      final uri = parseJoinUri(value);
      if (uri == null) {
        _flagWrongCode();
        continue;
      }
      // The caption says "Joining…" for a beat before the route pops, so the
      // scan is something you *saw* happen rather than a screen that
      // vanished. One frame is not enough to read; 220 ms is.
      setState(() => _done = true);
      JamHaptics.jamStarted();
      Timer(JamDuration.base, () {
        if (mounted) context.pop('$uri');
      });
      return;
    }
  }

  /// Every scanner failure, from every source, funnelled into one latch.
  ///
  /// One `debugPrint` for the one that lands, and nothing at all for the 495
  /// after it — a per-frame failure must not turn the log into a wall.
  void _fail(Object error) {
    if (_scanFailure != null || _done || !mounted) return;
    debugPrint('localjam: scanner unavailable: ${_describe(error)}');
    final failure = error is MobileScannerException
        ? error
        : const MobileScannerException(
            errorCode: MobileScannerErrorCode.genericError,
          );
    // `errorBuilder` reports from inside a build; a `setState` there is
    // illegal, so the latch waits for the frame to finish.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scanFailure == null) {
          setState(() => _scanFailure = failure);
        }
      });
      return;
    }
    setState(() => _scanFailure = failure);
  }

  /// One line, never a stack: these are expected on a simulator.
  static String _describe(Object error) => switch (error) {
    MobileScannerException(:final errorCode, :final errorDetails) =>
      '${errorCode.name}${errorDetails?.code == null ? '' : ' (${errorDetails!.code})'}',
    PlatformException(:final code) => code,
    _ => '$error',
  };

  /// Re-init after a failure: a fresh controller, the permission asked again
  /// (it may have been granted in Settings since), and the viewfinder back.
  Future<void> _retry() async {
    final old = _controller;
    setState(() {
      _scanFailure = null;
      _checkedCamera = false;
      _cameraAllowed = false;
      _cameraDeclined = false;
      _controller = MobileScannerController(autoStart: false);
    });
    _disposeController(old);
    await _askForCamera();
  }

  void _flagWrongCode() {
    if (_wrongCode != null) return;
    setState(() => _wrongCode = JamScanStrings.wrongCode);
    // Clears itself: the user will point the camera somewhere else, and a
    // stuck banner would then be lying.
    _wrongCodeTimer?.cancel();
    _wrongCodeTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _wrongCode = null);
    });
  }

  Future<void> _joinWithLink() async {
    // On the dark palette, like everything else on the black camera page:
    // a light alert over pure black is a flat mid-grey with 2–3:1 text.
    final uri = await promptForJoinLink(context, brightness: Brightness.dark);
    if (uri == null || !mounted) return;
    _done = true;
    context.pop('$uri');
  }

  void _close() => context.canPop() ? context.pop() : context.go('/');

  @override
  Widget build(BuildContext context) {
    final failure = _scanFailure;
    if (failure != null) {
      return AnnotatedRegion<SystemUiOverlayStyle>(
        value: jamOverlayStyleOnDark,
        child: ScannerUnavailableView(
          error: failure,
          declined: _cameraDeclined,
          onLink: _joinWithLink,
          onRetry: () => unawaited(_retry()),
          onClose: _close,
        ),
      );
    }
    final scanning = _checkedCamera && _cameraAllowed;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: jamOverlayStyleOnDark,
      child: JamForcedAppearance(
        brightness: Brightness.dark,

        child: Scaffold(
          backgroundColor: JamFixedColors.black,
          // No app bar: the camera is the screen, and everything else floats.
          body: Stack(
            fit: StackFit.expand,
            children: [
              if (scanning) ...[
                MobileScanner(
                  // A retry swaps the controller; the key makes the widget
                  // rebuild its own state around the new one instead of
                  // holding the disposed one.
                  key: ValueKey<MobileScannerController>(_controller),
                  controller: _controller,
                  onDetect: _onDetect,
                  // The barcode stream's error events, which the package
                  // otherwise rethrows into the zone frame after frame.
                  onDetectError: (error, _) => _fail(error),
                  errorBuilder: (context, error) {
                    _fail(error);
                    return const SizedBox.shrink();
                  },
                ),
                IgnorePointer(
                  child: Semantics(
                    label: JamScanStrings.title,
                    image: true,
                    child: CustomPaint(
                      painter: _ViewfinderPainter(),
                      size: Size.infinite,
                    ),
                  ),
                ),
                _Caption(
                  text: _done
                      ? JamScanStrings.found
                      : _wrongCode ?? JamScanStrings.hint,
                ),
              ],
              _ScanChrome(
                controller: scanning ? _controller : null,
                onClose: _close,
                onLink: () => unawaited(_joinWithLink()),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The line under the viewfinder: what to do, or what just happened.
class _Caption extends StatelessWidget {
  const _Caption({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        final top = size.height / 2 + scanWindowFor(size) / 2 + JamSpace.xxl;
        return Stack(
          children: [
            Positioned(
              top: top,
              left: JamSpace.xxl,
              right: JamSpace.xxl,
              child: Semantics(
                liveRegion: true,
                child: AnimatedSwitcher(
                  duration: reduceMotion ? Duration.zero : JamDuration.fast,
                  child: Text(
                    text,
                    key: ValueKey<String>(text),
                    textAlign: TextAlign.center,
                    style: context.jamSubheadline.copyWith(
                      color: JamNowPlayingColors.text,
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// The floating controls over the feed: the glass xmark, the flashlight
/// when there is one, and Enter Link at the bottom — on every scan page,
/// live or dead end, in the same place.
class _ScanChrome extends StatelessWidget {
  const _ScanChrome({
    required this.controller,
    required this.onClose,
    required this.onLink,
  });

  /// Null until the camera is running (no flashlight to offer yet).
  final MobileScannerController? controller;
  final VoidCallback onClose;
  final VoidCallback onLink;

  @override
  Widget build(BuildContext context) {
    final controller = this.controller;
    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: JamSpace.sm,
              vertical: JamSpace.xs,
            ),
            child: Row(
              children: [
                JamGlassButton(
                  icon: CupertinoIcons.xmark,
                  semanticLabel: JamScanStrings.close,
                  onArtwork: true,
                  onPressed: onClose,
                ),
                const Spacer(),
                if (controller != null)
                  ValueListenableBuilder<MobileScannerState>(
                    valueListenable: controller,
                    builder: (context, state, _) {
                      if (state.torchState == TorchState.unavailable) {
                        return const SizedBox.shrink();
                      }
                      final on = state.torchState == TorchState.on;
                      return JamGlassButton(
                        icon: on
                            ? CupertinoIcons.bolt_fill
                            : CupertinoIcons.bolt_slash_fill,
                        semanticLabel: on
                            ? JamScanStrings.torchOff
                            : JamScanStrings.torchOn,
                        onArtwork: true,
                        selected: on,
                        // The torch is a platform call like any other, and an
                        // unhandled rejection here reached the global handler.
                        onPressed: () => unawaited(
                          controller.toggleTorch().catchError(
                            (Object e) =>
                                debugPrint('localjam: torch failed: $e'),
                          ),
                        ),
                      );
                    },
                  ),
              ],
            ),
          ),
          const Spacer(),
          Padding(
            padding: const EdgeInsets.only(bottom: JamSpace.lg),
            child: JamButton.plain(
              label: JamScanStrings.enterLink,
              color: JamNowPlayingColors.text,
              onPressed: onLink,
            ),
          ),
        ],
      ),
    );
  }
}

/// The dim outside the viewfinder and its rounded white outline, in one
/// paint: the dim is even-odd filled around the hole, so the feed stays
/// bright exactly where the code goes.
class _ViewfinderPainter extends CustomPainter {
  const _ViewfinderPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final side = scanWindowFor(size);
    final window = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: size.center(Offset.zero),
        width: side,
        height: side,
      ),
      const Radius.circular(kScanWindowRadius),
    );
    canvas
      ..drawPath(
        Path.combine(
          PathOperation.difference,
          Path()..addRect(Offset.zero & size),
          Path()..addRRect(window),
        ),
        Paint()..color = JamFixedColors.black.withValues(alpha: _dimOpacity),
      )
      ..drawRRect(
        window,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = _outlineWidth
          ..color = JamFixedColors.white,
      );
  }

  @override
  bool shouldRepaint(_ViewfinderPainter old) => false;
}

/// What to do when there is no camera to scan with. A denial and a device
/// without a camera need different sentences and only one of them can be
/// fixed in Settings.
///
/// The same black page as the viewfinder (§6.10), with the same xmark and
/// **Enter Link always at the bottom, where the live scanner has it** — so a
/// dead end reads as the scanner saying why, not as a different screen, and
/// the way through never moves. The empty state carries at most one other
/// action, the fix for this dead end, as a neutral capsule that hugs its
/// label (a tinted fill on black read as a disabled maroon slab). It is
/// mounted *instead of* the viewfinder stack, never inside it.
class ScannerUnavailableView extends StatelessWidget {
  const ScannerUnavailableView({
    super.key,
    required this.error,
    required this.onLink,
    this.onRetry,
    this.onClose,
    this.declined = false,
  });

  final MobileScannerException error;
  final Future<void> Function() onLink;

  /// The rationale sheet was dismissed, so the OS was never asked.
  ///
  /// `mobile_scanner` has one code for "no camera" and the app used to reuse
  /// it for both, which meant backing out of our own explanation with the
  /// Back gesture read as a hard denial and sent the user to a Settings
  /// switch that was never flipped. Asking again is what actually works
  /// here, so that is the button.
  final bool declined;

  /// Re-initialises the scanner. Offered only where trying again could
  /// actually work: a camera that would not start (something else had it, a
  /// vision stack that failed once) recovers on a second attempt, while a
  /// device with no scanner never will and a denial needs Settings first.
  final VoidCallback? onRetry;

  /// The xmark. Defaults to popping the route (or going home).
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final denied =
        !declined && error.errorCode == MobileScannerErrorCode.permissionDenied;
    final unsupported = error.errorCode == MobileScannerErrorCode.unsupported;
    final (title, body) = declined
        ? (JamScanStrings.declinedTitle, JamScanStrings.declinedBody)
        : denied
        ? (JamScanStrings.deniedTitle, JamScanStrings.deniedBody)
        : unsupported
        ? (JamScanStrings.unsupportedTitle, JamScanStrings.unsupportedBody)
        : (JamScanStrings.failedTitle, JamScanStrings.failedBody);
    final canRetry = onRetry != null && !denied && !unsupported;
    // The fix for this dead end, where there is one: Settings where Settings
    // can fix it, another go at the camera where that is most likely to
    // work. A device with no camera has none — the link is the way.
    final (String? actionLabel, VoidCallback? onAction) = denied
        ? (JamScanStrings.openSettings, () => unawaited(openAppSettings()))
        : canRetry
        ? (JamScanStrings.retry, onRetry)
        : (null, null);

    return JamForcedAppearance(
      brightness: Brightness.dark,
      child: ColoredBox(
        color: JamFixedColors.black,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Center(
              child: JamEmptyState(
                icon: denied || declined
                    ? CupertinoIcons.camera
                    : CupertinoIcons.qrcode_viewfinder,
                title: title,
                body: body,
                foregroundColor: JamNowPlayingColors.text,
                secondaryColor: JamNowPlayingColors.secondary,
                // Neutral on black: the dark `fill` capsule with a
                // white label.
                actionLabel: actionLabel,
                onAction: onAction,
                actionVariant: JamButtonVariant.gray,
              ),
            ),
            _ScanChrome(
              controller: null,
              onClose:
                  onClose ??
                  () => context.canPop() ? context.pop() : context.go('/'),
              onLink: () => unawaited(onLink()),
            ),
          ],
        ),
      ),
    );
  }
}
