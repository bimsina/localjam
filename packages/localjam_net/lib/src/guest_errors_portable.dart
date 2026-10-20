/// Platform-neutral definitions of the guest's transport errors (see
/// `guest_errors.dart`), used where `dart:io` does not exist — in a browser.
/// Same names and members as the native ones, minus the `dart:io` supertypes.
library;

/// The host could not be reached, or a connection to it failed (PROTOCOL.md
/// §1): no join candidate answered (§1 Discovery), the control socket closed
/// during the `hello` handshake (§3.1), or a `fetch` of the media plane
/// failed at the network level or broke mid-body (§6.2).
///
/// A browser says almost nothing about why — a WebSocket that fails to open
/// fires a bare `error` event, a failed `fetch` rejects with "Failed to
/// fetch" — so [message] names what was being attempted, and [cause] carries
/// whatever the browser did say.
class JamTransportException implements Exception {
  const JamTransportException(this.message, {this.cause});

  /// What failed, in words.
  final String message;

  /// The underlying error, when there was one.
  final Object? cause;

  @override
  String toString() => 'JamTransportException: $message';
}

/// A media-plane request the host answered with an unexpected status
/// (§6.2, §6.4, §6.5), with the [statusCode], so a caller can tell a full
/// room (`507`) from a busy one (`429`) or a refused add (`403`) without
/// parsing text.
class JamHttpStatusException implements Exception {
  const JamHttpStatusException(this.statusCode, this.message, {this.uri});

  /// The HTTP status the host answered with.
  final int statusCode;

  /// What failed, in words.
  final String message;

  /// The request's URI, when known.
  final Uri? uri;

  @override
  String toString() =>
      'JamHttpStatusException: $message${uri == null ? '' : ', uri = $uri'}';
}
