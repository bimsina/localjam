/// The LocalJam guest, on every platform — browsers included (PROTOCOL.md
/// §1): [JamGuestClient] and the self-healing [JamGuestSession] over a
/// transport that is `dart:io` natively and the browser's `WebSocket` and
/// `fetch` on the web (`package:web`), picked at compile time.
///
/// Exports only what compiles without `dart:io`: no host server, no tag
/// reading, no file-backed fetch or upload. Media arrives through
/// [JamGuestClient.fetchMedia] (bytes) or [JamGuestClient.fetchMediaToSink]
/// (a [JamMediaSink] of the caller's); uploads go through
/// [JamGuestClient.uploadMediaStream]. Transport failures surface as
/// [JamTransportException] and refused requests as
/// [JamHttpStatusException] — natively the `SocketException` /
/// `HttpException` subtypes they always were.
///
/// Native code that also wants the host or the file conveniences imports
/// `package:localjam_net/localjam_net.dart`, which exports all of this too.
/// `package:localjam_core` is re-exported here as well.
library;

export 'package:localjam_core/localjam_core.dart';

export 'src/guest_client.dart';
export 'src/guest_errors.dart';
export 'src/guest_session.dart';
export 'src/jam_ticker.dart';
export 'src/media_sink.dart';
export 'src/monotonic.dart';
