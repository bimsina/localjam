#if canImport(Flutter)
    import Flutter
#endif
#if canImport(FlutterMacOS)
    import FlutterMacOS
#endif
import Dispatch
import Network

/// Allows to broadcast a given service to the local network.
@available(iOS 13.0, macOS 10.15, *)
class BonsoirServiceBroadcast: BonsoirAction {
    /// The advertised service.
    private let service: BonsoirService

    /// The reference to the registering..
    private var sdRef: DNSServiceRef?

    /// The queue DNSSD delivers the register reply on.
    ///
    /// LOCALJAM PATCH (see PATCHES.md). Upstream waits for that reply with a
    /// synchronous `DNSServiceProcessResult` on the thread `start()` was called
    /// from — the platform main thread. A daemon that never answers (the Apple
    /// Simulator always; a device whose Local Network prompt is unanswered or
    /// whose Bonjour is blocked) wedges it there, and since Flutter merged the
    /// UI thread onto the platform thread that is the whole app, Dart timers
    /// included. Scheduling the reference on a serial background queue instead
    /// lets `start()` return the moment registration has been *requested*;
    /// success and failure still arrive as the same events as before.
    private let queue: DispatchQueue

    /// Whether `sdRef` has been handed to `queue`.
    ///
    /// dns_sd.h requires a scheduled reference to be deallocated on the queue it
    /// was scheduled on; one that never got that far is ours to free inline.
    private var isScheduled = false

    /// The retained pointer to `self` handed to DNSSD as the callback context.
    ///
    /// Upstream passes it unretained, which is only safe while the reply is
    /// delivered synchronously inside `start()`. Now that a reply can land after
    /// the plugin has dropped its own reference, the registration owns one for
    /// as long as it is live; `stopRegistration()` gives it back.
    private var context: UnsafeMutableRawPointer?

    /// Initializes this class.
    public init(id: Int, printLogs: Bool, onDispose: @escaping () -> Void, messenger: FlutterBinaryMessenger, service: BonsoirService) {
        self.service = service
        queue = DispatchQueue(label: "\(SwiftBonsoirPlugin.package).broadcast.\(id)")
        super.init(id: id, action: "broadcast", logMessages: Generated.broadcastMessages, printLogs: printLogs, onDispose: onDispose, messenger: messenger)
    }

    /// Starts the broadcast.
    ///
    /// Returns as soon as the registration has been requested and scheduled. It
    /// never waits for the daemon.
    public func start() {
        var txtRecord = TXTRecordRef()
        TXTRecordCreate(&txtRecord, 0, nil)
        for (key, value) in service.attributes {
            guard let valueData = value.data(using: .utf8) else { continue }
            TXTRecordSetValue(&txtRecord, key, UInt8(valueData.count), [UInt8](valueData))
        }
        let callbackContext = Unmanaged.passRetained(self).toOpaque()
        context = callbackContext
        let error = DNSServiceRegister(&sdRef, 0, 0, service.name, service.type, "local.", service.hostAddresses.first ?? service.hostname, CFSwapInt16HostToBig(UInt16(service.port)), TXTRecordGetLength(&txtRecord), TXTRecordGetBytesPtr(&txtRecord), BonsoirServiceBroadcast.registerCallback as DNSServiceRegisterReply, callbackContext)
        guard error == kDNSServiceErr_NoError else {
            onError(parameters: [service, error], details: error)
            dispose()
            return
        }
        log(logMessages[Generated.broadcastInitialized]!, [service])

        // Where `DNSServiceProcessResult(sdRef)` used to block. The socket is
        // now read by libdispatch on `queue`, and `registerCallback` fires there
        // rather than on whatever thread got us here.
        let queueError = DNSServiceSetDispatchQueue(sdRef, queue)
        guard queueError == kDNSServiceErr_NoError else {
            onError(parameters: [service, queueError], details: queueError)
            dispose()
            return
        }
        isScheduled = true
    }

    override public func dispose() {
        stopRegistration()
        onSuccess(eventId: Generated.broadcastStopped, service: service)
        super.dispose()
    }

    /// Tears the registration down, on the queue that owns it.
    ///
    /// Called on the main thread only — from the plugin's `broadcast.stop`, from
    /// `detachFromEngineForRegistrar`, or from `registerCallback`'s error branch
    /// after it has hopped back. Deallocating on `queue` is what dns_sd.h asks
    /// for and is also what makes it terminal: a reply already in flight runs
    /// before the deallocation and finds `isDisposed` set by the time its own
    /// main-thread hop executes.
    private func stopRegistration() {
        guard let sdRef else {
            releaseContextOnMain()
            return
        }
        self.sdRef = nil
        let callbackContext = context
        context = nil
        if isScheduled {
            isScheduled = false
            queue.async {
                DNSServiceRefDeallocate(sdRef)
                BonsoirServiceBroadcast.releaseOnMain(callbackContext)
            }
        } else {
            DNSServiceRefDeallocate(sdRef)
            BonsoirServiceBroadcast.releaseOnMain(callbackContext)
        }
    }

    private func releaseContextOnMain() {
        let callbackContext = context
        context = nil
        BonsoirServiceBroadcast.releaseOnMain(callbackContext)
    }

    /// Gives back the reference `start()` took, on the main thread.
    ///
    /// The last release can be this one, and this class owns a
    /// `FlutterEventChannel`; letting that deallocate on a background queue is
    /// the kind of thing that is fine until it is not.
    private static func releaseOnMain(_ callbackContext: UnsafeMutableRawPointer?) {
        guard let callbackContext else { return }
        DispatchQueue.main.async {
            Unmanaged<BonsoirServiceBroadcast>.fromOpaque(callbackContext).release()
        }
    }

    /// Callback triggered by`DNSServiceRegister`.
    ///
    /// Delivered on `queue`, off the main thread. `name` points into memory the
    /// DNSSD library only guarantees for the duration of this call, so it is
    /// copied here; everything else is hopped to the main thread, which is where
    /// the rest of this class lives and the only thread a `FlutterEventSink` may
    /// be called from.
    private static let registerCallback: DNSServiceRegisterReply = { _, _, errorCode, name, _, _, context in
        guard let context else {
            return
        }
        let broadcast = Unmanaged<BonsoirServiceBroadcast>.fromOpaque(context).takeUnretainedValue()
        let newName = name == nil ? nil : String(cString: name!)
        DispatchQueue.main.async {
            guard !broadcast.isDisposed else {
                return
            }
            if errorCode == kDNSServiceErr_NoError {
                if let newName, broadcast.service.name != newName {
                    let oldName = broadcast.service.name
                    broadcast.service.name = newName
                    broadcast.onSuccess(eventId: Generated.broadcastNameAlreadyExists, service: broadcast.service, parameters: [oldName])
                }
                broadcast.onSuccess(eventId: Generated.broadcastStarted, service: broadcast.service)
            } else {
                broadcast.onError(parameters: [broadcast.service, errorCode], details: errorCode)
                broadcast.dispose()
            }
        }
    }
}
