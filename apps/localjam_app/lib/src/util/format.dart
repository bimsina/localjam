/// Small formatting helpers for microsecond timelines and telemetry.
library;

/// `mm:ss` (or `h:mm:ss`) from a media position in µs.
String formatPositionUs(int positionUs) {
  final totalSeconds = positionUs ~/ 1000000;
  final seconds = totalSeconds % 60;
  final minutes = (totalSeconds ~/ 60) % 60;
  final hours = totalSeconds ~/ 3600;
  final mmss =
      '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  return hours > 0 ? '$hours:$mmss' : mmss;
}

/// Signed milliseconds with one decimal, e.g. `+12.3 ms`, from µs.
String formatSignedMs(int us) {
  final ms = us / 1000;
  final sign = ms >= 0 ? '+' : '';
  return '$sign${ms.toStringAsFixed(1)} ms';
}
