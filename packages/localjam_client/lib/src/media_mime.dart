/// Best-effort MIME type from a file extension (audio-centric), matching the
/// CLI's mapping so mediaIds stay content-addressed the same way.
library;

import 'package:flutter/foundation.dart';

/// Audio extensions the pickers and the Documents-directory scan accept, for
/// the platform actually running.
///
/// One flat list got this wrong in both directions: it offered `m4a`/`aac`
/// on Windows and Linux, where the shared miniaudio core rejects them with
/// `unsupported_format`, and it hid `flac` and `ogg` everywhere — which is
/// most of what an offline music collection is made of.
///
/// * Apple: AVAudioEngine plays the AAC family and FLAC, but has no native
///   Ogg/Opus.
/// * Android: MediaCodec covers everything here.
/// * Windows/Linux: miniaudio + dr_libs — mp3/flac/wav/ogg only.
List<String> get supportedAudioExtensions => switch (defaultTargetPlatform) {
  TargetPlatform.iOS ||
  TargetPlatform.macOS => const ['mp3', 'm4a', 'aac', 'wav', 'flac'],
  TargetPlatform.android => const [
    'mp3',
    'm4a',
    'aac',
    'wav',
    'flac',
    'ogg',
    'opus',
  ],
  _ => const ['mp3', 'wav', 'flac', 'ogg'],
};

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

/// A sensible file extension for a playlist item's MIME type (used when a
/// guest writes fetched bytes to a temp file).
String extensionForMime(String mime) => switch (mime) {
  'audio/mpeg' => 'mp3',
  'audio/wav' => 'wav',
  'audio/flac' => 'flac',
  'audio/mp4' => 'm4a',
  'audio/aac' => 'aac',
  'audio/ogg' => 'ogg',
  'audio/opus' => 'opus',
  _ => 'bin',
};

/// Whether [path] looks like an audio file we can host.
bool isSupportedAudioPath(String path) {
  final dot = path.lastIndexOf('.');
  if (dot < 0) return false;
  final ext = path.substring(dot + 1).toLowerCase();
  return supportedAudioExtensions.contains(ext);
}
