import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'src/app.dart';
import 'src/state/error_log.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  _installErrorHandlers();
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks([
      'Manrope',
    ], await rootBundle.loadString('assets/fonts/OFL.txt'));
  });
  // The app paints its own ground behind both system bars, so Android's
  // navigation bar is left transparent rather than being a grey strip the
  // palette never asked for. The glyph tinting comes from the theme's
  // `systemOverlayStyle` and the root `AnnotatedRegion` in `app.dart`.
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  runApp(const LocalJamApp());
}

/// One place every uncaught error passes through.
///
/// LocalJam ships no crash SDK — there is no server in this product and no
/// account to attach a report to — but a jam runs for an hour on a phone in
/// someone's pocket, and an error that only ever reached a debug console is
/// an error nobody will ever hear about. So everything that lands here is
/// also kept in [JamErrorLog], a small in-memory ring a "Report a problem"
/// screen can read back later. Nothing is shown for it yet, and nothing
/// leaves the device.
void _installErrorHandlers() {
  final presentError = FlutterError.presentError;
  FlutterError.onError = (details) {
    JamErrorLog.record(
      details.exceptionAsString(),
      stack: details.stack,
      context: 'flutter',
    );
    debugPrint('localjam: flutter error: ${details.exceptionAsString()}');
    // The stack is in the ring either way; printing it belongs to the build
    // where a console is being read.
    if (kDebugMode && details.stack != null) debugPrint('${details.stack}');
    presentError(details);
  };

  // Errors from outside the framework's own zones: platform channels, async
  // gaps in the engines, socket callbacks.
  PlatformDispatcher.instance.onError = (error, stack) {
    JamErrorLog.record(error, stack: stack, context: 'platform');
    debugPrint('localjam: uncaught error: $error');
    if (kDebugMode) debugPrint('$stack');
    return true; // Handled — do not take the app down over it.
  };

  // A release build must never show a user the red screen. In debug it stays,
  // because that is the build where it is being read on purpose.
  if (kReleaseMode) {
    ErrorWidget.builder = (details) => const _FriendlyError();
  }
}

/// What replaces the red screen in release: an apology, not a stack trace.
class _FriendlyError extends StatelessWidget {
  const _FriendlyError();

  @override
  Widget build(BuildContext context) {
    return const Material(
      child: Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Something went wrong.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 16),
          ),
        ),
      ),
    );
  }
}
