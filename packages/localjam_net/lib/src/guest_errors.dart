/// The errors the guest surfaces for a failed transport (PROTOCOL.md §1,
/// §6.2): [JamTransportException] when the host cannot be reached or a
/// connection breaks, [JamHttpStatusException] when the media plane answers
/// with a status the guest did not ask for.
///
/// Both are defined twice behind one name. On native platforms they extend
/// `dart:io`'s `SocketException` and `HttpException`, exactly as the guest
/// threw before it ran in browsers, so a caller's `on SocketException` /
/// `on HttpException` keeps catching them. In a browser, where `dart:io`
/// does not exist, they are plain [Exception]s with the same members
/// (`message`, `cause`; `statusCode`, `message`, `uri`). Callers that want
/// one `catch` on every platform catch these names.
library;

export 'guest_errors_portable.dart' if (dart.library.io) 'guest_errors_io.dart';
