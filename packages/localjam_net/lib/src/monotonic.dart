/// Process-wide monotonic clock, in integer microseconds.
///
/// PROTOCOL.md §4 requires monotonic clocks from an *arbitrary epoch* on both
/// sides: the host's instance is the session clock, the guest's is its local
/// clock. Both `JamHostServer` and `JamGuestClient` read this shared
/// [Stopwatch], so within one process (e.g. loopback tests) the guest↔host
/// offset is ~0; across processes the epochs differ arbitrarily, which is
/// exactly what clock sync measures.
library;

final Stopwatch _stopwatch = Stopwatch()..start();

/// The current monotonic time in microseconds since an arbitrary epoch
/// (first use within this process).
int monotonicNowUs() => _stopwatch.elapsedMicroseconds;
