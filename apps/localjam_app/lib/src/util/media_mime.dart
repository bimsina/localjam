/// Best-effort MIME type from a file extension (audio-centric), matching the
/// CLI's mapping so mediaIds stay content-addressed the same way.
library;

/// Audio extensions the pickers and the Documents-directory scan accept.
const supportedAudioExtensions = ['mp3', 'm4a', 'aac', 'wav'];

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
