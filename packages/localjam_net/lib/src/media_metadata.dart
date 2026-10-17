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
  final amr.AudioMetadata parsed;
  if (maxMetadataBytes == null) {
    try {
      parsed = amr.readMetadata(file, getImage: true);
    } catch (_) {
      return const JamAudioTags();
    }
  } else {
    final bounded = _readBounded(file, maxMetadataBytes);
    if (bounded == null) return const JamAudioTags();
    parsed = bounded;
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

/// What a picture frame may add on top of the image it carries (its MIME
/// type, description and type byte), so a cover exactly at the cap still
/// reads.
const int _pictureFrameSlack = 64 * 1024;

/// [readAudioTagsSync] under a read budget of [maxMetadataBytes] (see
/// [readAudioTags]): with artwork if that fits, else without, else null.
amr.AudioMetadata? _readBounded(File file, int maxMetadataBytes) {
  for (final getImage in const [true, false]) {
    final budget = _ReadBudget(
      maxSingleRead: maxMetadataBytes + _pictureFrameSlack,
      maxTotal: 2 * maxMetadataBytes + 1024 * 1024,
    );
    try {
      return amr.readMetadata(_BudgetedFile(file, budget), getImage: getImage);
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
