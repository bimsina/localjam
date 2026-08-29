/// Small terminal-output helpers shared by the `host` and `join` commands:
/// position/µs formatting, progress bars, a `\r`-refreshed status line that
/// coexists with scrolling log lines, and raw-mode keyboard input.
library;

import 'dart:async';
import 'dart:io';

import 'package:localjam_core/localjam_core.dart';

/// Formats a media position as `mm:ss.mmm`. Null renders as `--:--.---`;
/// negative values clamp to zero. Minutes may exceed 59 (no hours field).
String formatPositionUs(int? us) {
  if (us == null) return '--:--.---';
  final totalMs = us < 0 ? 0 : us ~/ 1000;
  final minutes = totalMs ~/ 60000;
  final seconds = (totalMs ~/ 1000) % 60;
  final millis = totalMs % 1000;
  return '${minutes.toString().padLeft(2, '0')}:'
      '${seconds.toString().padLeft(2, '0')}.'
      '${millis.toString().padLeft(3, '0')}';
}

/// Formats a signed microsecond quantity, e.g. `+1234us` / `-87us`.
String formatSignedUs(int us) => us >= 0 ? '+${us}us' : '${us}us';

/// An ASCII progress bar, e.g. `[########----------------]  33%`.
String progressBar(double fraction, {int width = 24}) {
  final f = fraction.clamp(0.0, 1.0);
  final filled = (f * width).round();
  final pct = (f * 100).round().toString().padLeft(3);
  return '[${'#' * filled}${'-' * (width - filled)}] $pct%';
}

/// Human label for a [DriftAction].
String describeDriftAction(DriftAction action) => switch (action) {
  DriftNone() => 'none',
  DriftSlew(:final rateMultiplier, :final durationUs) =>
    'slew x${rateMultiplier.toStringAsFixed(4)}/'
        '${(durationUs / 1e6).toStringAsFixed(1)}s',
  DriftHardResync(:final errorUs) => 'HARD RESYNC (${formatSignedUs(errorUs)})',
};

/// One `\r`-refreshed status line at the bottom, with normal scrolling log
/// lines above it. On a non-terminal stdout it degrades to plain lines.
class StatusScreen {
  StatusScreen({Stdout? out}) : _out = out ?? stdout;

  final Stdout _out;
  String _status = '';

  bool get _ansi => _out.hasTerminal;

  /// Prints a log line above the status line.
  void log(String line) {
    if (_ansi) {
      _out.write('\x1b[2K\r'); // Clear the status line.
      _out.writeln(line);
      _out.write(_status);
    } else {
      _out.writeln(line);
    }
  }

  /// Replaces the live status line.
  void status(String line) {
    _status = line;
    if (_ansi) {
      _out.write('\x1b[2K\r$line');
    } else {
      _out.writeln(line);
    }
  }

  /// Finishes the status line with a newline (call before exiting).
  void done() {
    if (_ansi && _status.isNotEmpty) _out.writeln();
    _status = '';
  }
}

/// Raw-mode single-key stdin input. Safe when stdin is not a TTY: raw mode is
/// only enabled behind [Stdin.hasTerminal], and a broken/closed stdin simply
/// yields no keys.
class KeyInput {
  KeyInput._(this._sub, this._restore);

  final StreamSubscription<List<int>>? _sub;
  final void Function() _restore;

  /// Starts listening; [onKey] receives one single-character string per key.
  static KeyInput start(void Function(String key) onKey) {
    var restore = () {};
    if (stdin.hasTerminal) {
      try {
        final prevLine = stdin.lineMode;
        final prevEcho = stdin.echoMode;
        stdin.lineMode = false;
        stdin.echoMode = false;
        restore = () {
          try {
            stdin.lineMode = prevLine;
            stdin.echoMode = prevEcho;
          } catch (_) {
            // Terminal already gone; nothing to restore.
          }
        };
      } catch (_) {
        // Could not switch modes (e.g. exotic stdin); fall through cooked.
      }
    }
    StreamSubscription<List<int>>? sub;
    try {
      sub = stdin.listen(
        (bytes) {
          for (final b in bytes) {
            onKey(String.fromCharCode(b));
          }
        },
        onError: (Object _) {},
        cancelOnError: true,
      );
    } catch (_) {
      // stdin unusable (closed / already listened); keyboard control is off.
    }
    return KeyInput._(sub, restore);
  }

  /// Stops listening and restores the previous terminal modes.
  Future<void> stop() async {
    await _sub?.cancel();
    _restore();
  }
}

/// Best-effort MIME type from a file extension (audio-centric).
String mimeForPath(String path) {
  final dot = path.lastIndexOf('.');
  final ext = dot < 0 ? '' : path.substring(dot + 1).toLowerCase();
  return switch (ext) {
    'mp3' => 'audio/mpeg',
    'wav' => 'audio/wav',
    'flac' => 'audio/flac',
    'm4a' || 'mp4' => 'audio/mp4',
    'aac' => 'audio/aac',
    'ogg' || 'oga' => 'audio/ogg',
    'opus' => 'audio/opus',
    _ => 'application/octet-stream',
  };
}
