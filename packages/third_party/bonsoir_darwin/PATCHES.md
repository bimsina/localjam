# bonsoir_darwin — LocalJam's vendored copy

Upstream: `bonsoir_darwin` **7.1.1** from pub.dev
(sha256 `6f695a0b4465514b75fc1a457746ab6dfc10d7180f0d04810fd9512e6520df69`),
<https://github.com/Skyost/Bonsoir/tree/main/packages/bonsoir_darwin>.
Unmodified apart from what is listed here; the upstream `LICENSE` (MIT,
Skyost) ships with it and still applies.

Wired in as a `dependency_overrides` path entry from
`packages/localjam_client/pubspec.yaml` and `apps/localjam_app/pubspec.yaml`
(overrides do not propagate across packages, so every consumer that builds for
Apple platforms needs its own).

## The patch: DNS-SD registration must not block the main thread

`darwin/bonsoir_darwin/Sources/bonsoir_darwin/Broadcast/BonsoirServiceBroadcast.swift`

Upstream `start()` called `DNSServiceRegister` and then waited for the daemon's
confirmation with a **synchronous `DNSServiceProcessResult(sdRef)`** — on the
thread the method channel called it from, which is the platform main thread:

```swift
if error == kDNSServiceErr_NoError {
    log(logMessages[Generated.broadcastInitialized]!, [service])
    DNSServiceProcessResult(sdRef)   // ← blocks until the daemon replies
}
```

If the daemon never replies, that call never returns. It never replies on the
Apple Simulator (the registration is accepted, a PTR even goes on the wire, the
reply does not come back), and on real hardware it can stall while the Local
Network prompt is unanswered or when Bonjour is blocked. Since Flutter merged
the UI thread onto the platform thread on iOS, the wedged thread is *also* the
Dart isolate's: every timer stops, `Future.timeout` included, and the app is
dead rather than slow. A sample of a wedged host:

```text
Thread_987308  DispatchQueue_1: com.apple.main-thread
  … FlutterMethodChannel setMethodCallHandler _block_invoke
    SwiftBonsoirPlugin.handle           SwiftBonsoirPlugin.swift:56
      BonsoirServiceBroadcast.start()   BonsoirServiceBroadcast.swift:35
        DNSServiceProcessResult → read_all → __recvfrom_nocancel
```

The patch replaces the blocking read with the asynchronous form the same header
offers, which is what the discovery/resolution side of this plugin already uses:

- a serial background `DispatchQueue` per broadcast
  (`fr.skyost.bonsoir.broadcast.<id>`);
- `DNSServiceSetDispatchQueue(sdRef, queue)` instead of
  `DNSServiceProcessResult(sdRef)`, so libdispatch reads the socket and
  `registerCallback` fires off-main;
- the callback copies the (transient) `name` C string on that queue and hops to
  `DispatchQueue.main.async` for everything else — `FlutterEventSink` may only
  be called from the platform thread, and every other member of the class is
  read and written there;
- the callback context is now `Unmanaged.passRetained`, not `passUnretained`: a
  reply can arrive after the plugin has dropped its own reference, so the
  registration holds one until it is torn down. The matching `release()` is
  hopped to the main thread so the owned `FlutterEventChannel` cannot
  deallocate on a background queue;
- `dispose()` tears the registration down through `stopRegistration()`, which
  deallocates the reference **on the queue it was scheduled on** (dns_sd.h asks
  the caller for exactly that mutual exclusion), and a reply already in flight
  finds `isDisposed` set by the time its main-thread hop runs;
- both failure paths (`DNSServiceRegister`, `DNSServiceSetDispatchQueue`) report
  through the existing `broadcastError` event.

Behaviour change for callers: `broadcast.start()`'s method-channel reply now
means "registration requested", not "registration confirmed". Confirmation is
the `broadcastStarted` event, exactly as documented — which is what
`packages/localjam_client/lib/src/jam_discovery.dart` now waits for, on a
budget, before falling back to its own responder.

Discovery was already non-blocking upstream: `resolveService` and
`resolveAddress` schedule with `DNSServiceSetDispatchQueue(sdRef,
DispatchQueue.main)` and never call `DNSServiceProcessResult`, and browsing runs
on `NWBrowser`. Left alone.

## Updating

Re-copy the pub.dev package for the new version, re-apply the above, and update
the version and hash at the top of this file. If upstream fixes this itself
(the blocking call is a bug there too), drop the override and the vendored copy.
