/// The guest transport on a platform with neither `dart:io` nor a browser
/// (see `guest_transport.dart`): there is no network to reach a host with.
library;

import 'guest_transport.dart';

/// Throws [UnsupportedError]: this platform has no transport for the guest.
JamGuestTransport createGuestTransport({
  required Duration timeout,
  required int maxConnections,
}) => throw UnsupportedError(
  'The LocalJam guest needs dart:io or a browser (dart:js_interop)',
);
