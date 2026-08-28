/// Network transport for the LocalJam protocol (PROTOCOL.md §1): the host's
/// combined WebSocket control plane + HTTP media plane server, and the guest
/// client with clock sync, state mirroring, and media fetching.
///
/// Message types, codec, clock estimation, and the host state machine come
/// from `package:localjam_core` (re-exported by this library for convenience).
library;

export 'package:localjam_core/localjam_core.dart';

export 'src/guest_client.dart';
export 'src/guest_session.dart';
export 'src/host_server.dart';
export 'src/monotonic.dart';
