/// Host-side audio tag extraction (PROTOCOL.md §6.1/§6.5).
///
/// One implementation for both ways media enters a session — the host's own
/// files and guest uploads — so guests never need a tag parser: tags and
/// artwork ride the playlist broadcast and the artwork endpoint.
library;

import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:audio_metadata_reader/audio_metadata_reader.dart' as amr;
import 'package:meta/meta.dart';

/// Tag metadata read from one audio file. All fields are best-effort:
/// anything the file didn't carry (or the parser choked on) is null.
@immutable
class JamAudioTags {
  const JamAudioTags({
    this.title,
    this.artist,
    this.album,
    this.durationUs,
    this.artworkBytes,
    this.artworkMime,
  });

  final String? title;
  final String? artist;
  final String? album;

  /// Tag-declared duration. Less reliable than a decoder probe — callers
  /// with a real audio engine should prefer their own probe and use this as
  /// the fallback.
  final int? durationUs;

  /// Embedded artwork (front cover preferred), when present.
  final Uint8List? artworkBytes;
  final String? artworkMime;

  bool get hasArtwork => artworkBytes != null && artworkBytes!.isNotEmpty;

  @override
  String toString() =>
      'JamAudioTags(title: $title, artist: $artist, album: $album, '
      'durationUs: $durationUs, '
      'artwork: ${hasArtwork ? '${artworkBytes!.length} bytes' : 'none'})';
}

/// Reads tags + embedded artwork from [file], never throwing: any parse
/// failure — unsupported container, truncated file, parser bug — yields an
/// empty [JamAudioTags], and the caller falls back to filename-derived
/// display metadata. Parsing runs in a short-lived isolate so a host app's
/// UI isolate never blocks on tag I/O.
Future<JamAudioTags> readAudioTags(File file) async {
  try {
    return await Isolate.run(() => readAudioTagsSync(file));
  } catch (_) {
    // Isolate spawn unavailable (some embedders): degrade to inline parsing.
    try {
      return readAudioTagsSync(file);
    } catch (_) {
      return const JamAudioTags();
    }
  }
}

/// Synchronous body of [readAudioTags]; exposed for isolate-free callers.
/// Unlike the async wrapper this throws on parser errors — callers other
/// than [readAudioTags] must catch.
@visibleForTesting
JamAudioTags readAudioTagsSync(File file) {
  final amr.AudioMetadata parsed;
  try {
    parsed = amr.readMetadata(file, getImage: true);
  } catch (_) {
    return const JamAudioTags();
  }
  amr.Picture? picture;
  for (final candidate in parsed.pictures) {
    if (candidate.bytes.isEmpty) continue;
    picture ??= candidate;
    if (candidate.pictureType == amr.PictureType.coverFront) {
      picture = candidate;
      break;
    }
  }
  String? clean(String? value) {
    final trimmed = value?.trim();
    return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
  }

  final duration = parsed.duration;
  return JamAudioTags(
    title: clean(parsed.title),
    artist: clean(parsed.artist),
    album: clean(parsed.album),
    durationUs: (duration == null || duration <= Duration.zero)
        ? null
        : duration.inMicroseconds,
    artworkBytes: picture?.bytes,
    artworkMime: picture == null
        ? null
        : (clean(picture.mimetype) ?? 'application/octet-stream'),
  );
}
