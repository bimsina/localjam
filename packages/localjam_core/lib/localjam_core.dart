/// Pure-Dart core for the LocalJam protocol: message types and codec,
/// NTP-style clock synchronization, and the anchor-based playback session
/// state machine. No I/O — transports and audio engines live in the clients.
library;

export 'src/protocol/messages.dart';
export 'src/protocol/codec.dart';
export 'src/protocol/join_link.dart';
export 'src/clock/clock_sync.dart';
export 'src/session/permissions.dart';
export 'src/session/playback_state.dart';
export 'src/session/host_session.dart';
export 'src/session/drift_policy.dart';
