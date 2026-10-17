/// Small formatting helpers for microsecond timelines, telemetry and the
/// names we put in front of people.
library;

import 'package:localjam_client/localjam_client.dart';

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

/// Below this many milliseconds a signed figure is shown as plain `0.0 ms`.
///
/// One decimal place means anything under 0.05 ms rounds to zero — and the
/// old formatter then still stamped a sign on it, so a drift hovering around
/// perfect flapped between `+0.0 ms` and `-0.0 ms` several times a second.
/// Two readings that render identically must read identically.
const double kJamZeroMs = 0.05;

/// Signed milliseconds with one decimal, e.g. `+12.3 ms`, from µs.
///
/// Zero — and anything that rounds to it — is unsigned: `0.0 ms`.
String formatSignedMs(int us) {
  final ms = us / 1000;
  if (ms.abs() < kJamZeroMs) return '0.0 ms';
  final sign = ms > 0 ? '+' : '';
  return '$sign${ms.toStringAsFixed(1)} ms';
}

/// The sync sheet's drift and clock-offset figures. Same shape as
/// [formatSignedMs]; named for the one place it is read so the deadband is
/// discoverable from the call site.
String formatDriftMs(int us) => formatSignedMs(us);

/// Extensions [stripAudioExtension] will take off a display name.
///
/// Broader than [supportedAudioExtensions] on purpose: this is about what a
/// filename can *end in*, not what this build can play, and the name may have
/// come from another device.
const Set<String> _audioExtensions = {
  'mp3',
  'm4a',
  'm4b',
  'mp4',
  'aac',
  'wav',
  'wave',
  'flac',
  'ogg',
  'oga',
  'opus',
  'aiff',
  'aif',
  'alac',
  'wma',
};

/// A display name with a trailing audio extension removed: `track1.m4a`
/// becomes `track1`.
///
/// A tagless file falls back to its filename, and "track1.m4a" on the
/// now-playing screen reads as a bug. Defensive — the engine trims its own
/// fallback too — and conservative: anything that does not end in a known
/// audio extension is returned untouched.
String stripAudioExtension(String name) {
  final dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) return name;
  final ext = name.substring(dot + 1).toLowerCase();
  return _audioExtensions.contains(ext) ? name.substring(0, dot) : name;
}

/// What to call [item] on screen: its tag title, else its filename without
/// the extension.
String jamDisplayTitle(MediaItem item) =>
    stripAudioExtension(item.displayTitle);
