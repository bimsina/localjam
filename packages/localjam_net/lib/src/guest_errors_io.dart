/// Native definitions of the guest's transport errors (see
/// `guest_errors.dart`): subtypes of `dart:io`'s own, so code written
/// against `SocketException` / `HttpException` keeps working unchanged.
library;

import 'dart:io';

/// The host could not be reached, or a connection to it failed (PROTOCOL.md
/// §1): no join candidate answered (§1 Discovery), or the control socket
/// closed during the `hello` handshake (§3.1).
///
/// On native platforms this IS a [SocketException] — the type the guest
/// threw for these failures before it also ran in browsers — so an existing
/// `on SocketException` still catches it, and its `toString` reads the same.
/// Failures raised by `dart:io` itself (a reset mid-transfer, a refused
/// connection) still surface as `dart:io`'s own [SocketException] /
/// [HttpException] here, as they always have.
class JamTransportException extends SocketException {
  const JamTransportException(
    super.message, {
    this.cause,
    super.osError,
    super.address,
    super.port,
  });

  /// The underlying error, when there was one.
  final Object? cause;
}

/// A media-plane request the host answered with an unexpected status
/// (§6.2, §6.4, §6.5). Still an [HttpException] — the message is the same —
/// but with the [statusCode], so a caller can tell a full room (`507`) from
/// a busy one (`429`) or a refused add (`403`) without parsing text.
class JamHttpStatusException extends HttpException {
  const JamHttpStatusException(this.statusCode, super.message, {super.uri});

  /// The HTTP status the host answered with.
  final int statusCode;
}
