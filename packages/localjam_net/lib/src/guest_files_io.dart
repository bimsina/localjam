/// The guest's file-backed conveniences, native only: fetch media straight
/// to disk (PROTOCOL.md §6.2) and upload a file from disk (§6.4). They are
/// extension methods over the platform-neutral [JamGuestClient] /
/// [JamGuestSession] surface ([JamGuestClient.fetchMediaToSink],
/// [JamGuestClient.uploadMediaStream]), so the guest itself compiles where
/// `dart:io` does not; `package:localjam_net/localjam_net.dart` exports
/// them, `package:localjam_net/guest.dart` (the web-safe barrel) does not.
/// Behaviour, arguments and errors are what these methods had before they
/// moved here.
library;

import 'dart:async';
import 'dart:io';

import 'package:localjam_core/localjam_core.dart';

import 'guest_client.dart';
import 'guest_errors.dart';
import 'guest_session.dart';
import 'media_sink.dart';

/// A [JamMediaSink] that streams a media body to [file] (§6.2): the parent
/// directory is created and the file opened only once the host has answered
/// `200`, and a failed transfer deletes the partial file.
class JamFileMediaSink extends JamMediaSink {
  JamFileMediaSink(this.file);

  /// Where the body goes.
  final File file;

  IOSink? _sink;

  @override
  Future<void> open() async {
    await file.parent.create(recursive: true);
    _sink = file.openWrite();
  }

  @override
  void add(List<int> chunk) => _sink!.add(chunk);

  @override
  Future<void> close() async {
    final sink = _sink;
    if (sink == null) return;
    try {
      await sink.flush();
    } finally {
      await sink.close();
    }
  }

  @override
  Future<void> abandon() async {
    try {
      await file.delete();
    } catch (_) {
      // Never written, or already gone: nothing to undo.
    }
  }
}

/// File-backed media fetch and upload on a [JamGuestClient] (native only).
extension JamGuestClientFiles on JamGuestClient {
  /// Fetches `GET /media/{mediaId}` with Bearer auth (§6.2), streaming the
  /// body straight to [destination] while hashing incrementally — the file
  /// is never held in memory. Reports `media_status` upstream (§6.3):
  /// `fetching` with progress while downloading, `ready` once the sha256
  /// digest matches the playlist entry. Bounded by the entry's `sizeBytes`
  /// ([JamGuestClient.sizeSlackBytes] of slack), so a host that keeps
  /// sending cannot fill the disk.
  ///
  /// [onProgress] receives values in [0, 1]. Returns [destination]. Throws
  /// [ArgumentError] if [mediaId] is not in the current playlist,
  /// [HttpException] ([JamHttpStatusException]) on a non-200 response,
  /// [TimeoutException] when the host stops answering (no connection, no
  /// response, or no body bytes within `mediaTimeout`), and [StateError] on
  /// a digest mismatch or an over-size body; those last three delete the
  /// partial [destination] and report `media_status: none`. See
  /// [JamGuestClient.fetchMediaToSink], which this wraps with a
  /// [JamFileMediaSink].
  Future<File> fetchMediaToFile(
    String mediaId,
    File destination, {
    void Function(double progress)? onProgress,
  }) async {
    await fetchMediaToSink(
      mediaId,
      JamFileMediaSink(destination),
      onProgress: onProgress,
    );
    return destination;
  }

  /// Uploads [file] to the host over the media plane (`POST /media`, §6.4),
  /// streaming it from disk — the file is never read into memory whole.
  /// [name] defaults to the file's basename. Everything else is
  /// [JamGuestClient.uploadMediaStream]: progress per flushed chunk, the
  /// upload key, [JamHttpStatusException] (an [HttpException]) for a refusal,
  /// [TimeoutException] for a host that stops reading or never answers.
  Future<MediaItem> uploadMedia(
    File file, {
    required MediaKind kind,
    String? name,
    String mime = 'application/octet-stream',
    int? durationUs,
    void Function(double progress)? onProgress,
  }) async {
    final total = await file.length();
    return uploadMediaStream(
      file.openRead(),
      length: total,
      name: name ?? Uri.file(file.path).pathSegments.last,
      kind: kind,
      mime: mime,
      durationUs: durationUs,
      onProgress: onProgress,
    );
  }
}

/// File-backed media fetch and upload on a [JamGuestSession] (native only),
/// via its current client.
extension JamGuestSessionFiles on JamGuestSession {
  /// Streams media over the HTTP plane straight to [destination] (§6.2) via
  /// the current client, verifying its sha256 on completion (see
  /// [JamGuestClientFiles.fetchMediaToFile]). Throws [StateError] unless
  /// connected.
  Future<File> fetchMediaToFile(
    String mediaId,
    File destination, {
    void Function(double progress)? onProgress,
  }) => fetchMediaToSink(
    mediaId,
    JamFileMediaSink(destination),
    onProgress: onProgress,
  ).then((_) => destination);

  /// Uploads [file] to the host (`POST /media`, §6.4) via the current
  /// client, streaming it from disk (see [JamGuestClientFiles.uploadMedia]).
  /// Throws [StateError] unless connected.
  Future<MediaItem> uploadMedia(
    File file, {
    required MediaKind kind,
    String? name,
    String mime = 'application/octet-stream',
    int? durationUs,
    void Function(double progress)? onProgress,
  }) {
    if (connectionState != JamConnectionState.connected) {
      throw StateError(
        'Session is ${connectionState.name}, not connected to the host',
      );
    }
    return file.length().then(
      (total) => uploadMediaStream(
        file.openRead(),
        length: total,
        name: name ?? Uri.file(file.path).pathSegments.last,
        kind: kind,
        mime: mime,
        durationUs: durationUs,
        onProgress: onProgress,
      ),
    );
  }
}
