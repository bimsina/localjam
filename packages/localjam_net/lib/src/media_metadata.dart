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
///
/// [maxMetadataBytes] bounds what reading the file may cost, for files that
/// are remote input (a guest upload, §6.4). The tag parser reads a frame —
/// a cover, a text field — whole, at whatever size the file declares, so a
/// crafted 200 MB "cover" costs 200 MB of the host's memory before any cap
/// on the result can look at it. With a bound, no single read may exceed
/// it (plus a little slack for a picture frame's own header) and all reads
/// together may not exceed twice it plus 1 MB; past either, the parse is
/// abandoned before the bytes are read. A file whose artwork is what broke
/// the bound is read again without artwork, so it keeps its title; one
/// whose other tags broke it keeps nothing. Null (the host's own library)
/// reads everything.
Future<JamAudioTags> readAudioTags(File file, {int? maxMetadataBytes}) async {
  try {
    return await Isolate.run(
      () => readAudioTagsSync(file, maxMetadataBytes: maxMetadataBytes),
    );
  } catch (_) {
    // Isolate spawn unavailable (some embedders): degrade to inline parsing.
    try {
      return readAudioTagsSync(file, maxMetadataBytes: maxMetadataBytes);
    } catch (_) {
      return const JamAudioTags();
    }
  }
}

/// Synchronous body of [readAudioTags]; exposed for isolate-free callers.
/// Unlike the async wrapper this may throw on I/O errors — callers other
/// than [readAudioTags] must catch.
@visibleForTesting
JamAudioTags readAudioTagsSync(File file, {int? maxMetadataBytes}) {
  final Object parsed;
  if (maxMetadataBytes == null) {
    try {
      parsed = amr.readAllMetadata(file, getImage: true);
    } catch (_) {
      return const JamAudioTags();
    }
  } else {
    final bounded = _readBounded(file, maxMetadataBytes);
    if (bounded == null) return const JamAudioTags();
    parsed = bounded;
  }
  final fields = _fieldsOf(parsed);
  if (fields == null) return const JamAudioTags();

  // The front cover preferred, else the first picture — either only once
  // its bytes are recognisably an image ([sniffArtwork]).
  ({Uint8List bytes, String mime})? artwork;
  for (final candidate in fields.pictures) {
    final sniffed = sniffArtwork(candidate.bytes);
    if (sniffed == null) continue;
    artwork ??= sniffed;
    if (candidate.pictureType == amr.PictureType.coverFront) {
      artwork = sniffed;
      break;
    }
  }

  final duration = fields.duration;
  return JamAudioTags(
    title: _clean(fields.title),
    artist: fields.artist,
    album: _clean(fields.album),
    durationUs: (duration == null || duration <= Duration.zero)
        ? null
        : duration.inMicroseconds,
    artworkBytes: artwork?.bytes,
    artworkMime: artwork?.mime,
  );
}

/// [value] trimmed, or null when nothing is left. A UTF-16 tag can leave
/// its byte-order mark in the text; it is not part of the name.
String? _clean(String? value) {
  final trimmed = value?.replaceAll('﻿', '').trim();
  return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
}

/// What [readAudioTagsSync] takes from one parsed file.
typedef _TagFields = ({
  String? title,
  String? artist,
  String? album,
  Duration? duration,
  List<amr.Picture> pictures,
});

/// The display fields of [parsed] (one of the parser's format-specific
/// results, `readAllMetadata`). The artist is the track's own — ID3 `TPE1`,
/// Vorbis and APE `ARTIST`, MP4 `©ART`, RIFF `IART` — with the album artist
/// (`TPE2`, `ALBUMARTIST`) only its fallback. The parser's summary
/// (`readMetadata`) prefers `TPE2` for MP3, which put a soundtrack's
/// composer on every song instead of who sings it.
_TagFields? _fieldsOf(Object parsed) => switch (parsed) {
  amr.Mp3Metadata m => (
    title: m.songName,
    artist:
        normalizeArtistCredit(m.leadPerformer) ??
        normalizeArtistCredit(m.bandOrOrchestra) ??
        normalizeArtistCredit(m.originalArtist),
    album: m.album,
    duration: m.duration,
    pictures: m.pictures,
  ),
  amr.VorbisMetadata m => (
    title: m.title.firstOrNull,
    artist:
        normalizeArtistCredit(m.artist.join('\u0000')) ??
        normalizeArtistCredit(m.albumArtist.join('\u0000')),
    album: m.album.firstOrNull,
    duration: m.duration,
    pictures: m.pictures,
  ),
  amr.Mp4Metadata m => (
    title: m.title,
    artist: normalizeArtistCredit(m.artist),
    album: m.album,
    duration: m.duration,
    pictures: [?m.picture],
  ),
  amr.ApeMetadata m => (
    title: m.title,
    artist:
        normalizeArtistCredit(m.artist) ?? normalizeArtistCredit(m.albumArtist),
    album: m.album,
    duration: m.duration,
    pictures: m.pictures,
  ),
  amr.RiffMetadata m => (
    title: m.title,
    artist: normalizeArtistCredit(m.artist),
    album: m.album,
    duration: m.duration,
    pictures: m.pictures,
  ),
  _ => null,
};

/// One artist credit for display, from a tag — or a library column copied
/// from one — that may name several artists: ID3v2.4 separates them with
/// NUL, ID3v2.3 (and most taggers, and Android's MediaStore after them)
/// with `/`, and Vorbis comments repeat the field (the caller joins the
/// repeats with NUL). Each artist once, in order, joined with ", ":
/// `A.R. Rahman/Javed Ali/Mohit Chauhan` reads "A.R. Rahman, Javed Ali,
/// Mohit Chauhan". Null when nothing is left.
///
/// A `/` splits only when every piece around it is at least three
/// characters long, so a name with a slash in it — `AC/DC`, `N/A` — stays
/// whole (a three-letter-a-side name like `Foo/Bar` cannot be told apart
/// from two artists, and splits). Commas are never split: "Earth, Wind &
/// Fire" is one artist.
String? normalizeArtistCredit(String? raw) {
  if (raw == null) return null;
  final parts = <String>[];
  final seen = <String>{};
  for (final value in raw.replaceAll('﻿', '').split('\u0000')) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) continue;
    final pieces = [for (final p in trimmed.split('/')) p.trim()];
    final split = pieces.length > 1 && pieces.every((p) => p.runes.length >= 3);
    for (final piece in split ? pieces : [trimmed]) {
      if (seen.add(piece.toLowerCase())) parts.add(piece);
    }
  }
  return parts.isEmpty ? null : parts.join(', ');
}

/// How far into a picture [sniffArtwork] looks for where the image starts.
const int _artworkSniffWindow = 512;

/// [bytes] as an image a guest can decode, with the MIME type its own
/// signature gives (JPEG, PNG, GIF, WebP, BMP, AVIF), or null when it is
/// not recognisably one.
///
/// A picture frame's description is sometimes left in front of the image:
/// audio_metadata_reader before 1.8 ended a UTF-16 description at the
/// first zero byte, so a cover described "Cover" came out as
/// `6f 00 76 00 65 00 72 00 00 00 ff d8 …`, which no decoder reads. The
/// image is looked for within the first [_artworkSniffWindow] bytes and
/// whatever precedes it dropped; a picture with no image signature there
/// (an ID3 `-->` URL, garbage) is no cover rather than bytes every guest
/// fails to decode. The signature's MIME type wins over the declared one,
/// which taggers get wrong (`image/jpg`, `jpeg`, empty).
@visibleForTesting
({Uint8List bytes, String mime})? sniffArtwork(Uint8List bytes) {
  bool at(int offset, List<int> signature) {
    if (offset < 0 || offset + signature.length > bytes.length) return false;
    for (var i = 0; i < signature.length; i++) {
      if (bytes[offset + i] != signature[i]) return false;
    }
    return true;
  }

  ({Uint8List bytes, String mime}) from(int offset, String mime) => (
    bytes: offset == 0 ? bytes : Uint8List.fromList(bytes.sublist(offset)),
    mime: mime,
  );

  // Only at the very start: signatures too short or too generic to hunt
  // for inside a prefix.
  if (at(0, const [0x42, 0x4D]) && bytes.length > 26) {
    return from(0, 'image/bmp');
  }
  if (at(4, const [0x66, 0x74, 0x79, 0x70, 0x61, 0x76, 0x69])) {
    return from(0, 'image/avif'); // `....ftypavif` / `....ftypavis`
  }
  final window = bytes.length < _artworkSniffWindow
      ? bytes.length
      : _artworkSniffWindow;
  for (var offset = 0; offset < window; offset++) {
    if (at(offset, const [0xFF, 0xD8, 0xFF])) {
      return from(offset, 'image/jpeg');
    }
    if (at(offset, const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) {
      return from(offset, 'image/png');
    }
    if (at(offset, const [0x47, 0x49, 0x46, 0x38]) &&
        (at(offset + 4, const [0x37, 0x61]) ||
            at(offset + 4, const [0x39, 0x61]))) {
      return from(offset, 'image/gif');
    }
    if (at(offset, const [0x52, 0x49, 0x46, 0x46]) &&
        at(offset + 8, const [0x57, 0x45, 0x42, 0x50])) {
      return from(offset, 'image/webp');
    }
  }
  return null;
}

/// What a picture frame may add on top of the image it carries (its MIME
/// type, description and type byte), so a cover exactly at the cap still
/// reads.
const int _pictureFrameSlack = 64 * 1024;

/// [readAudioTagsSync] under a read budget of [maxMetadataBytes] (see
/// [readAudioTags]): with artwork if that fits, else without, else null.
Object? _readBounded(File file, int maxMetadataBytes) {
  for (final getImage in const [true, false]) {
    final budget = _ReadBudget(
      maxSingleRead: maxMetadataBytes + _pictureFrameSlack,
      maxTotal: 2 * maxMetadataBytes + 1024 * 1024,
    );
    try {
      return amr.readAllMetadata(
        _BudgetedFile(file, budget),
        getImage: getImage,
      );
    } catch (_) {
      // Only a blown budget is worth a second try without artwork; any
      // other failure would just fail again.
      if (!budget.exceeded) return null;
    }
  }
  return null;
}

/// Bytes a tag parse may still read; see [readAudioTags].
class _ReadBudget {
  _ReadBudget({required this.maxSingleRead, required this.maxTotal});

  final int maxSingleRead;
  final int maxTotal;
  int _total = 0;

  /// Whether a read was refused — the parse failed on the budget, not on
  /// the file.
  bool exceeded = false;

  /// Refuses a read of [requested] bytes before it happens. Checked ahead
  /// of the read, not after: the parser allocates its destination first,
  /// and an allocation nobody writes to costs address space, not memory.
  void checkRead(int requested) {
    if (requested > maxSingleRead || _total >= maxTotal) _refuse();
  }

  /// Accounts [count] bytes actually read.
  void spend(int count) {
    _total += count;
    if (_total > maxTotal) _refuse();
  }

  Never _refuse() {
    exceeded = true;
    throw const FileSystemException('tag read budget exceeded');
  }
}

/// The file the tag parser is handed: the real one, opened through
/// [_BudgetedReader]. The parser only ever opens it and keeps it for its
/// error messages; anything else is not forwarded and fails the parse,
/// which the caller treats as "no tags".
class _BudgetedFile implements File {
  _BudgetedFile(this._file, this._budget);

  final File _file;
  final _ReadBudget _budget;

  @override
  String get path => _file.path;

  @override
  RandomAccessFile openSync({FileMode mode = FileMode.read}) =>
      _BudgetedReader(_file.openSync(mode: mode), _budget);

  @override
  String toString() => 'File: ${_file.path} (tag read budget)';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A read-only [RandomAccessFile] whose reads are held to a [_ReadBudget].
/// Only what a synchronous parser needs is forwarded.
class _BudgetedReader implements RandomAccessFile {
  _BudgetedReader(this._raf, this._budget);

  final RandomAccessFile _raf;
  final _ReadBudget _budget;

  @override
  String get path => _raf.path;

  @override
  int readByteSync() {
    _budget.checkRead(1);
    final byte = _raf.readByteSync();
    if (byte >= 0) _budget.spend(1);
    return byte;
  }

  @override
  Uint8List readSync(int count) {
    _budget.checkRead(count);
    final bytes = _raf.readSync(count);
    _budget.spend(bytes.length);
    return bytes;
  }

  @override
  int readIntoSync(List<int> buffer, [int start = 0, int? end]) {
    _budget.checkRead((end ?? buffer.length) - start);
    final count = _raf.readIntoSync(buffer, start, end);
    _budget.spend(count);
    return count;
  }

  @override
  int positionSync() => _raf.positionSync();

  @override
  RandomAccessFile setPositionSync(int position) {
    _raf.setPositionSync(position);
    return this;
  }

  @override
  int lengthSync() => _raf.lengthSync();

  @override
  void closeSync() => _raf.closeSync();

  @override
  Future<void> close() => _raf.close();

  @override
  String toString() => 'RandomAccessFile: ${_raf.path} (tag read budget)';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
