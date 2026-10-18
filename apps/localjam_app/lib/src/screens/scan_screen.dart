/// Full-screen QR scanner for `localjam://join?...` codes. Pops with the
/// scanned URI string, or null when dismissed.
///
/// Camera-first: no app bar, no chrome, nothing between you and the code. A
/// 60% scrim with a 260 dp hole punched in it does the aiming, four raspberry
/// L-brackets say where to point, and the moment a code lands they snap
/// apricot and the phone taps your hand. Everything else — the title, the
/// hint, the close button, the way through when there is no camera — floats
/// over the feed.
///
/// The camera is the one part of joining that can simply not be available —
/// denied, missing, or busy — so this screen carries its own dead ends: it
/// says which one happened, offers Settings, and always offers the paste
/// field as a way through.
library;

import 'dart:async';

import 'package:flutter/material.dart';
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
import '../widgets/join_link_dialog.dart';

/// Every user-facing string this screen can show.
abstract final class JamScanStrings {
  static const String title = 'Scan to join';
  static const String hint = 'Point at the host’s code';
  static const String wrongCode = 'That isn’t a jam code.';
  static const String found = 'Got it — joining…';
  static const String enterLink = 'Enter link instead';
  static const String close = 'Close';
  static const String torchOn = 'Turn on the torch';
  static const String torchOff = 'Turn off the torch';

  static const String deniedTitle = 'No camera access';
  static const String deniedBody = JamPermissionCopy.cameraDenied;

  /// The rationale sheet was answered with Back or "Not now", so the OS was
  /// never asked and there is nothing in Settings to turn on. Telling this
  /// user to "turn on camera access in Settings" sends them to a switch that
  /// is already where it should be, to fix a permission they never denied.
  static const String declinedTitle = 'Camera is off for now';
  static const String declinedBody =
      'You haven’t let LocalJam use the camera yet. Try again to see the '
      'system’s ask, or join with a link instead.';
  static const String unsupportedTitle = 'No scanner here';
  static const String unsupportedBody =
      'This device cannot scan QR codes. Join with a link instead.';
  static const String failedTitle = 'The camera didn’t start';
  static const String failedBody =
      'Something else may be using it. Try again, or join with a link.';
  static const String retry = 'Try again';
}

/// The side of the clear square the camera aims through.
const double kScanWindow = 260;

/// How much of the feed the scrim eats.
const double _scrimOpacity = 0.6;

/// Bracket geometry: a 32 dp arm, 3 dp thick, on a 14 dp corner radius.
const double _bracketArm = 32;
const double _bracketWidth = 3;
const double _bracketRadius = 14;

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
  /// under the scrim, behind the brackets, inside a 260 dp cut-out, with the
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
      // The brackets go apricot for a beat before the route pops, so the
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
    final uri = await promptForJoinLink(context);
    if (uri == null || !mounted) return;
    _done = true;
    context.pop('$uri');
  }

  void _close() => context.canPop() ? context.pop() : context.go('/');

  @override
  Widget build(BuildContext context) {
    final failure = _scanFailure;
    // The dead-end page is an ordinary screen on the app's own canvas, so it
    // keeps the app's own status-bar treatment; the viewfinder is a dark
    // surface and needs light glyphs over it.
    if (failure != null || !_checkedCamera || !_cameraAllowed) {
      return Scaffold(
        body: failure == null
            ? const SizedBox.shrink()
            : ScannerUnavailableView(
                error: failure,
                declined: _cameraDeclined,
                onLink: _joinWithLink,
                onRetry: () => unawaited(_retry()),
              ),
      );
    }

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: jamOverlayStyleOnDark,
      child: Scaffold(
        backgroundColor: Colors.black,
        // No app bar: the camera is the screen, and everything else floats.
        body: Stack(
          fit: StackFit.expand,
          children: [
            MobileScanner(
              // A retry swaps the controller; the key makes the widget
              // rebuild its own state around the new one instead of holding
              // the disposed one.
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
            // The aiming mask: one scrim with a hole in it, so the feed
            // stays bright exactly where the code goes.
            IgnorePointer(
              child: CustomPaint(
                painter: const _ScrimPainter(window: kScanWindow),
                size: Size.infinite,
              ),
            ),
            Center(
              child: _Brackets(size: kScanWindow, found: _done),
            ),
            _ScanChrome(
              hint: _wrongCode ?? JamScanStrings.hint,
              found: _done,
              controller: _controller,
              onClose: _close,
              onLink: () => unawaited(_joinWithLink()),
            ),
          ],
        ),
      ),
    );
  }
}

/// The floating controls and copy over the feed. White on a dark scrim, so
/// none of the palette's cream/plum text lands here — it would be unreadable
/// over a camera.
class _ScanChrome extends StatelessWidget {
  const _ScanChrome({
    required this.hint,
    required this.found,
    required this.controller,
    required this.onClose,
    required this.onLink,
  });

  final String hint;
  final bool found;
  final MobileScannerController controller;
  final VoidCallback onClose;
  final VoidCallback onLink;

  @override
  Widget build(BuildContext context) {
    const white = Colors.white;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(JamSpace.page),
        child: Column(
          children: [
            Row(
              children: [
                _GlassButton(
                  icon: Icons.close_rounded,
                  label: JamScanStrings.close,
                  onPressed: onClose,
                ),
                const Spacer(),
                ValueListenableBuilder<MobileScannerState>(
                  valueListenable: controller,
                  builder: (context, state, _) {
                    if (state.torchState == TorchState.unavailable) {
                      return const SizedBox.shrink();
                    }
                    final on = state.torchState == TorchState.on;
                    return _GlassButton(
                      icon: on
                          ? Icons.flash_on_rounded
                          : Icons.flash_off_rounded,
                      label: on
                          ? JamScanStrings.torchOff
                          : JamScanStrings.torchOn,
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
            const SizedBox(height: JamSpace.xxl),
            Text(
              JamScanStrings.title,
              textAlign: TextAlign.center,
              style: context.jamTitle2.copyWith(
                color: white,
                shadows: const [Shadow(blurRadius: 12, color: Colors.black54)],
              ),
            ),
            const Spacer(),
            // Below the cut-out: the hint, then the way through when the
            // camera is not going to work out.
            SizedBox(
              height: 44,
              child: Center(
                child: AnimatedSwitcher(
                  duration: JamDuration.fast,
                  child: Text(
                    found ? JamScanStrings.found : hint,
                    key: ValueKey<String>(found ? JamScanStrings.found : hint),
                    textAlign: TextAlign.center,
                    style: context.jamSubheadline.copyWith(
                      color: white.withValues(alpha: 0.8),
                      shadows: const [
                        Shadow(blurRadius: 10, color: Colors.black54),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: JamSpace.sm),
            // Tertiary, in white rather than the accent: raspberry on a live
            // camera feed reads as an alert.
            TextButton(
              onPressed: onLink,
              style: TextButton.styleFrom(
                foregroundColor: white,
                textStyle: context.jamHeadline,
                minimumSize: const Size(0, 44),
              ),
              child: const Text(JamScanStrings.enterLink),
            ),
          ],
        ),
      ),
    );
  }
}

/// A 44 dp circular control that stays legible over anything the camera sees.
class _GlassButton extends StatelessWidget {
  const _GlassButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: Material(
        color: const Color(0x66000000),
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: SizedBox(
            width: 44,
            height: 44,
            child: Icon(icon, size: 22, color: Colors.white),
          ),
        ),
      ),
    );
  }
}

/// The scrim with the cut-out. One paint, even-odd filled, rather than four
/// rectangles that never quite meet at the corners.
class _ScrimPainter extends CustomPainter {
  const _ScrimPainter({required this.window});

  final double window;

  @override
  void paint(Canvas canvas, Size size) {
    final side = window.clamp(0.0, size.shortestSide);
    final hole = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: size.center(Offset.zero),
        width: side,
        height: side,
      ),
      const Radius.circular(_bracketRadius),
    );
    final path = Path.combine(
      PathOperation.difference,
      Path()..addRect(Offset.zero & size),
      Path()..addRRect(hole),
    );
    canvas.drawPath(
      path,
      Paint()..color = Colors.black.withValues(alpha: _scrimOpacity),
    );
  }

  @override
  bool shouldRepaint(_ScrimPainter old) => old.window != window;
}

/// Four L-brackets around the cut-out. Raspberry while hunting; they snap to
/// apricot and thicken the instant a jam code lands.
class _Brackets extends StatelessWidget {
  const _Brackets({required this.size, required this.found});

  final double size;
  final bool found;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    return Semantics(
      label: JamScanStrings.title,
      excludeSemantics: true,
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(end: found ? 1 : 0),
        duration: JamDuration.fast,
        curve: JamCurve.standard,
        builder: (context, t, _) => CustomPaint(
          size: Size.square(size),
          painter: _BracketPainter(
            color: Color.lerp(colors.tint, colors.warning, t)!,
            width: _bracketWidth + t * 1.5,
          ),
        ),
      ),
    );
  }
}

class _BracketPainter extends CustomPainter {
  const _BracketPainter({required this.color, required this.width});

  final Color color;
  final double width;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round;
    final w = size.width;
    final h = size.height;
    const r = _bracketRadius;
    const arm = _bracketArm;

    Path corner(double x, double y, double sx, double sy) => Path()
      ..moveTo(x + sx * arm, y)
      ..lineTo(x + sx * r, y)
      ..quadraticBezierTo(x, y, x, y + sy * r)
      ..lineTo(x, y + sy * arm);

    canvas
      ..drawPath(corner(0, 0, 1, 1), paint)
      ..drawPath(corner(w, 0, -1, 1), paint)
      ..drawPath(corner(0, h, 1, -1), paint)
      ..drawPath(corner(w, h, -1, -1), paint);
  }

  @override
  bool shouldRepaint(_BracketPainter old) =>
      old.color != color || old.width != width;
}

/// What to do when there is no camera to scan with. A denial and a device
/// without a camera need different sentences and only one of them can be
/// fixed in Settings.
///
/// On the app's own canvas, not black: once the camera is out of the picture
/// this is an ordinary screen, and a black one would read as a crash. It is
/// mounted *instead of* the viewfinder stack, never inside it — there is no
/// scrim over it, no brackets across it and exactly one close button.
class ScannerUnavailableView extends StatelessWidget {
  const ScannerUnavailableView({
    super.key,
    required this.error,
    required this.onLink,
    this.onRetry,
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

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
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

    return ColoredBox(
      color: colors.background,
      child: SafeArea(
        child: Column(
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.all(JamSpace.sm),
                child: IconButton(
                  tooltip: JamScanStrings.close,
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () =>
                      context.canPop() ? context.pop() : context.go('/'),
                ),
              ),
            ),
            Expanded(
              child: JamEmptyState(
                icon: denied || declined
                    ? Icons.no_photography_rounded
                    : Icons.qr_code_scanner_rounded,
                title: title,
                body: body,
                // One primary action per screen: Settings where Settings can
                // fix it, another go at the camera where that is the thing
                // most likely to work, the link field where nothing else can.
                actionLabel: denied
                    ? JamPermissionCopy.openSettings
                    : canRetry
                    ? JamScanStrings.retry
                    : JamScanStrings.enterLink,
                onAction: denied
                    ? () => unawaited(openAppSettings())
                    : canRetry
                    ? onRetry
                    : () => unawaited(onLink()),
              ),
            ),
            // Every dead end still needs the way through; it just is not the
            // loudest thing on it. (Where nothing else can help, "Enter link
            // instead" *is* the primary and this would repeat it.)
            if (denied || canRetry)
              Padding(
                padding: const EdgeInsets.only(bottom: JamSpace.xxl),
                child: JamButton.plain(
                  label: JamScanStrings.enterLink,
                  onPressed: () => unawaited(onLink()),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
