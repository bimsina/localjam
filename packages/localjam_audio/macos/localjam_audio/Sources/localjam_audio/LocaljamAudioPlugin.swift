import AVFoundation
import MediaPlayer
#if canImport(localjam_audio_objc)
// Swift Package Manager: the Objective-C exception catcher is its own target.
// Under CocoaPods it is part of this module and needs no import.
import localjam_audio_objc
#endif
#if os(iOS)
import Flutter
import UIKit
#else
import AppKit
import CoreAudio
import FlutterMacOS
#endif

/// Sample-accurate scheduled audio playback for LocalJam (PROTOCOL.md §5.3–§5.4).
///
/// This file is shared verbatim between the iOS and macOS targets; platform
/// differences are confined to `#if os(iOS)` blocks.
///
/// ## Clock domain
/// "Native time" is `mach_absolute_time()` converted to microseconds via
/// `mach_timebase_info`. `playAt` converts a native-time µs value back to mach
/// host ticks for `AVAudioTime(hostTime:)` — AVAudioTime host time IS the mach
/// clock, so scheduling and `nowUs` share one timebase with no translation
/// error. (`mach_absolute_time` is a "System boot time" required-reason API;
/// PrivacyInfo.xcprivacy declares it, reason 35F9.1.)
///
/// ## Position math (verified empirically against AVAudioEngine on macOS 15)
/// The graph is `player → AVAudioUnitTimePitch → mainMixer → output`, with the
/// player connected using the file's processing format, so the player's
/// timeline runs at the FILE's sample rate.
///
/// `player.playerTime(forNodeTime:).sampleTime` is the player's SOURCE-frame
/// timeline: 0 at the scheduled start instant, negative before it
/// (extrapolated). Because the time-pitch unit downstream pulls source frames
/// at ×rate realtime, this timeline advances at ×rate realtime (measured
/// slope 1.0508 at rate = 1.05, exactly 1.0 at rate = 1.0, and it follows
/// live rate changes). It therefore directly measures elapsed MEDIA time:
///
///     positionUs = segmentStartUs + sampleTime / sampleRate * 1e6
///
/// No explicit ×rate term appears because the timeline embodies it — this is
/// the spec formula `position = scheduledStartPositionUs + elapsedRenderedUs
/// × rate` with `elapsedRenderedUs × rate` measured in one step on the
/// player's source-frame clock. A bonus of this form: it remains exact across
/// live `setRate` changes with no re-anchoring bookkeeping.
///
/// Which nodeTime to query at (measured, macOS 15, default output):
///  * `lastRenderTime` → leads audible "now" by the render-ahead
///    (~13–23 ms at rate 1.0, ~40–49 ms at 1.05), jittering per render cycle.
///  * `AVAudioTime(hostTime: mach_absolute_time())` → the player converts the
///    CURRENT host time through its render-anchored mapping: error ≤ ~35 µs
///    at rate 1.0; a near-constant ~24 ms lead at rate 1.05 from the pitch
///    unit's priming consumption (scales with |rate−1|, so ~2 ms at the
///    ±0.5 % drift-slew rates — under the §5.4 15 ms ignore threshold).
/// We use the host-time-now query, falling back to lastRenderTime. Any
/// residual constant lead is part of output latency in the §7 sense and is
/// absorbed by output-latency calibration / the manual nudge.
///
/// Also measured: AVAudioUnitTimePitch realizes rate 1.05 as ~1.0508 (small
/// rate quantization). Irrelevant for drift slew — the §5.4 loop measures
/// position and iterates, so exact rate realization doesn't matter.
///
/// ## Never crash on bad input or an unlucky moment
/// AVFAudio reports many failures by raising NSException, which Swift cannot
/// catch (measured on macOS: `play(at:)` raises "player did not see an IO
/// cycle" for files ≤ 32 Hz; `scheduleSegment` raises on 0 frames; frame
/// counts ≥ 2^32 trap the `AVAudioFrameCount` conversion). So: inputs are
/// validated before they reach AVFAudio, every raising call runs inside
/// `LJObjCExceptionCatcher` (`engine.start()`, `pause()` and teardown
/// included), all Int64 conversions of computed doubles are range-checked,
/// and an engine that raised is discarded and rebuilt on the next `playAt`
/// (measured: after a caught exception the player's sample timeline is
/// garbage for every later schedule on the same node). File headers are
/// untrusted too — peers upload files to a host — so a declared length or
/// sample rate outside what any recording has is refused at load (a ~1 KB
/// CAF can declare 2^62 frames).
///
/// ## Output loss, interruptions, errors (contract: README "Events")
///  * Route change with reason `.oldDeviceUnavailable` (headphones unplugged,
///    Bluetooth gone) — and on macOS, the default output device disappearing
///    or the built-in device's headphone data source going away — stops our
///    output FIRST, then emits `routeChanged{oldDeviceUnavailable: true}`.
///    Playback is never restarted natively: audio must not jump to the
///    speaker. Other route changes keep playing.
///  * The same unplug also reconfigures the engine, and the OS does not order
///    the two notifications. So `engineRestarted` (which makes Dart
///    re-schedule) waits `restartEventDelay` and is dropped if the change
///    turns out to be a lost output; on macOS a configuration change whose
///    output device no longer exists is reported as the lost output directly.
///    The result is the same whichever notification comes first.
///  * Interruptions stop output and report `interruptionBegan`; the end is
///    reported with the OS's `shouldResume` hint. Never auto-resumed — the
///    room timeline moved on, so Dart re-anchors with `playAt`. A `playAt`
///    the OS refuses (iOS session activation refused, e.g. during a call)
///    completes without playing and emits `interruptionBegan` on EVERY
///    refused call, not once per interruption (Android parity).
///  * `playbackError{code, message}` reports failures off the method-call
///    path that leave output stopped (engine cannot restart after a
///    configuration change).
public class LocaljamAudioPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  public static func register(with registrar: FlutterPluginRegistrar) {
    #if os(iOS)
    let messenger = registrar.messenger()
    #else
    let messenger = registrar.messenger
    #endif
    let channel = FlutterMethodChannel(name: "localjam_audio", binaryMessenger: messenger)
    let instance = LocaljamAudioPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
    let eventChannel = FlutterEventChannel(
      name: "localjam_audio/events", binaryMessenger: messenger)
    eventChannel.setStreamHandler(instance)

    // OS media session (lock screen / Control Center / Now Playing):
    // now-playing pushes in, remote transport commands out.
    let mediaSessionChannel = FlutterMethodChannel(
      name: "localjam_audio/media_session", binaryMessenger: messenger)
    let mediaSession = JamMediaSessionHandler(channel: mediaSessionChannel)
    instance.mediaSession = mediaSession  // Retain alongside the plugin.
    mediaSessionChannel.setMethodCallHandler(mediaSession.handle)
  }

  /// The media-session handler, retained for the plugin's lifetime.
  private var mediaSession: JamMediaSessionHandler?

  // MARK: - Event channel
  //
  // Emits maps {type: String, ...payload} for playback interruptions the Dart
  // side must react to (route changes, OS audio interruptions, engine
  // restarts, natural end of the scheduled segment, unrecoverable errors).
  // Payload keys per type are documented on LocaljamAudioEvent in
  // lib/localjam_audio.dart.

  /// The Dart-side listener's sink. Only touched on the main thread
  /// (onListen/onCancel arrive there; emitEvent hops there).
  private var eventSink: FlutterEventSink?

  public func onListen(
    withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    eventSink = events
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  /// Emits one event to Dart. Callable from any thread (including the serial
  /// queue); delivery always happens on the main thread, per the
  /// FlutterEventSink threading contract.
  private func emitEvent(_ type: String, _ fields: [String: Any] = [:]) {
    DispatchQueue.main.async { [weak self] in
      guard let sink = self?.eventSink else { return }
      var payload = fields
      payload["type"] = type
      sink(payload)
    }
  }

  // MARK: - Mach clock

  private static let timebase: mach_timebase_info_data_t = {
    var tb = mach_timebase_info_data_t()
    mach_timebase_info(&tb)
    return tb
  }()

  /// Current native monotonic time in µs (mach_absolute_time → µs, exact
  /// integer math to avoid double rounding over long uptimes).
  private static func machNowUs() -> Int64 {
    let ticks = mach_absolute_time()
    let n = UInt64(timebase.numer)
    let d = UInt64(timebase.denom)
    let ns = (ticks / d) * n + (ticks % d) * n / d
    return Int64(ns / 1000)
  }

  /// Native-time µs → mach host ticks (for AVAudioTime(hostTime:)).
  /// Saturates instead of trapping: `nativeTimeUs` comes straight from Dart,
  /// and an absurd far-future anchor must not overflow the ×1000.
  private static func hostTicks(fromUs us: Int64) -> UInt64 {
    let (ns, overflow) = UInt64(max(0, us)).multipliedReportingOverflow(by: 1000)
    if overflow { return UInt64.max }
    let n = UInt64(timebase.numer)
    let d = UInt64(timebase.denom)
    let (whole, wholeOverflow) = (ns / n).multipliedReportingOverflow(by: d)
    if wholeOverflow { return UInt64.max }
    return whole &+ (ns % n) * d / n
  }

  /// `Int64(value)` without the trap: NaN → 0, ±∞ / out of range saturate.
  /// Used for every conversion of a computed Double, because the inputs to
  /// those computations (positions, anchors, rates, file metadata) are not
  /// ours to trust.
  private static func clampedInt64(_ value: Double) -> Int64 {
    if value.isNaN { return 0 }
    if value >= 9.2e18 { return Int64.max }
    if value <= -9.2e18 { return Int64.min }
    return Int64(value)
  }

  // MARK: - State

  private enum PlaybackState {
    case idle      // no file
    case loaded    // file loaded, not playing (also after stop)
    case playing   // scheduled or audibly playing
    case paused
    case finished  // segment ran to the end of file
  }

  /// All engine/player access happens on this serial queue. Method-channel
  /// results are always delivered back on the main thread, exactly once.
  private let queue = DispatchQueue(label: "localjam_audio")

  private var engine: AVAudioEngine?
  private var player: AVAudioPlayerNode?
  private var timePitch: AVAudioUnitTimePitch?
  private var file: AVAudioFile?
  private var state: PlaybackState = .idle

  /// Media position (µs, frame-exact) of the first frame of the scheduled
  /// segment — the `scheduledStartPositionUs` term of the position formula.
  private var segmentStartUs: Int64 = 0
  /// Duration of the loaded file (µs); positionUs is clamped to it.
  private var durationUs: Int64 = 0
  /// Bumped on every (re)schedule/stop/dispose so stale segment-completion
  /// callbacks can be ignored.
  private var scheduleGeneration: UInt64 = 0
  private var configChangeObserver: NSObjectProtocol?
  #if os(iOS)
  private var routeChangeObserver: NSObjectProtocol?
  private var interruptionObserver: NSObjectProtocol?
  private var mediaServicesResetObserver: NSObjectProtocol?
  /// Between interruptionBegan and interruptionEnded: the session is not
  /// ours, so a configuration change must not try to restart the engine.
  private var interruptionInProgress = false
  /// The OS deactivated our session (interruption); the next playAt must
  /// re-activate it before starting the engine.
  private var sessionMayBeInactive = false
  #else
  /// CoreAudio listener on the system default output device (macOS has no
  /// AVAudioSession route notifications).
  private var defaultOutputListener: AudioObjectPropertyListenerBlock?
  private var lastOutputDevice: AudioDeviceID?
  /// CoreAudio listener on the default device's output data source: Intel
  /// Macs switch speaker ↔ headphone jack as data sources of ONE device, so
  /// pulling the headphones changes no device at all.
  private var dataSourceListener: AudioObjectPropertyListenerBlock?
  private var dataSourceDevice: AudioDeviceID?
  private var lastDataSource: UInt32?
  #endif
  /// `engineRestarted` waiting out the route-change notification of the same
  /// physical change (see handleConfigurationChange). Serial queue only.
  private var pendingRestartEvent: DispatchWorkItem?
  /// Identifies the live `pendingRestartEvent`; bumped on cancel/re-arm.
  private var restartEventToken: UInt64 = 0
  /// How long `engineRestarted` waits for a lost-output route change that the
  /// OS may deliver after the engine's configuration change.
  private static let restartEventDelay: DispatchTimeInterval = .milliseconds(200)

  /// Files below this rate are rejected at load: AVAudioPlayerNode never
  /// "sees an IO cycle" for them and play(at:) raises (measured: ≤ 32 Hz on
  /// macOS). No real music is anywhere near it; the margin covers devices
  /// with larger IO buffers.
  private static let minSampleRate: Double = 4000
  /// Upper bound, the same as the desktop core's (LJ_MAX_SAMPLE_RATE), so a
  /// file plays on every platform or on none.
  private static let maxSampleRate: Double = 384_000

  /// Longest file `load` accepts: 2^37 frames is 99 h even at 384 kHz, so
  /// anything longer is a crafted header (a ~1 KB CAF can declare 2^62
  /// frames, which used to queue 2^32 scheduleSegment calls on the serial
  /// queue — a hang, then out of memory). Bounds the segment loop in playAt
  /// to 128 iterations. Same bound as the desktop core (LJ_MAX_FRAMES).
  private static let maxFrames = AVAudioFramePosition(1) << 37

  /// Longest single scheduleSegment. `frameCount` is an AVAudioFrameCount
  /// (UInt32), so files of ≥ 2^32 frames (27 h at 44.1 kHz) used to trap the
  /// conversion; longer remainders are queued as consecutive segments, which
  /// AVAudioPlayerNode plays back to back sample-contiguously. 2^30 frames is
  /// 6.7 h at 44.1 kHz, so real tracks are still exactly one segment.
  private static let maxSegmentFrames = AVAudioFramePosition(1 << 30)

  /// Rates playAt/setRate accept: what AVAudioUnitTimePitch can realise
  /// (it silently clamps outside, which would desynchronise the position
  /// math). Excludes NaN/∞/≤0, which used to reach Int64 conversions. Same
  /// bounds as the desktop core (LJ_MIN_RATE/LJ_MAX_RATE).
  private static let rateRange: ClosedRange<Double> = (1.0 / 32.0)...32.0

  /// Furthest-ahead anchor playAt accepts (1 h; desktop: LJ_MAX_LEAD_US).
  private static let maxLeadUs: Int64 = 3_600_000_000

  // MARK: - Method channel

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any]
    // `reply` marshals back to the platform thread; each case below calls it
    // exactly once.
    let reply: (Any?) -> Void = { value in
      DispatchQueue.main.async { result(value) }
    }
    switch call.method {
    // Neither of these touches the engine, the loaded file, the play state or
    // the session, so they run OFF the serial queue: a probe must never wait
    // behind (or delay) a playAt that is waiting for its first render cycle.
    case "probeDuration":
      handleProbeDuration(args, reply)
      return
    case "currentRouteId":
      reply(Self.currentRouteId())
      return
    default:
      break
    }
    queue.async { [weak self] in
      guard let self = self else {
        reply(FlutterError(code: "disposed", message: "plugin deallocated", details: nil))
        return
      }
      switch call.method {
      case "nowUs":
        reply(Self.machNowUs())
      case "load":
        self.handleLoad(args, reply)
      case "playAt":
        self.handlePlayAt(args, reply)
      case "pause":
        self.handlePause(reply)
      case "stop":
        self.handleStop(reply)
      case "positionUs":
        self.handlePositionUs(reply)
      case "setRate":
        self.handleSetRate(args, reply)
      case "outputLatencyUs":
        self.handleOutputLatencyUs(reply)
      case "dispose":
        self.handleDispose(reply)
      default:
        reply(FlutterMethodNotImplemented)
      }
    }
  }

  // MARK: - Files

  private struct FileProblem: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }

  /// Opens `path` and checks it is something the engine can schedule. The
  /// single source of truth for both `load` and `probeDuration`, so a probe
  /// reports exactly the duration `load` would.
  private static func openPlayableFile(_ path: String) throws -> (file: AVAudioFile, durationUs: Int64) {
    let audioFile: AVAudioFile
    do {
      audioFile = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    } catch {
      throw FileProblem(message: "Could not open audio file at \(path): \(error.localizedDescription)")
    }
    let format = audioFile.processingFormat
    let sampleRate = format.sampleRate
    guard sampleRate.isFinite, sampleRate >= minSampleRate, sampleRate <= maxSampleRate else {
      throw FileProblem(message: "\(path) has an unsupported sample rate (\(sampleRate) Hz)")
    }
    guard format.channelCount > 0 else {
      throw FileProblem(message: "\(path) has no audio channels")
    }
    guard audioFile.length > 0 else {
      throw FileProblem(message: "\(path) contains no audio frames")
    }
    guard audioFile.length <= maxFrames else {
      throw FileProblem(message: "\(path) declares an implausible length (\(audioFile.length) frames)")
    }
    let durationUs = clampedInt64(Double(audioFile.length) * 1_000_000.0 / sampleRate)
    return (audioFile, durationUs)
  }

  private func handleProbeDuration(_ args: [String: Any]?, _ reply: @escaping (Any?) -> Void) {
    guard let path = args?["path"] as? String else {
      reply(FlutterError(code: "bad_args", message: "probeDuration requires {path: String}", details: nil))
      return
    }
    // A private AVAudioFile per call: header/packet-table metadata only (the
    // same frame count `load` reports), no engine, no session. Concurrent
    // probes are independent.
    DispatchQueue.global(qos: .userInitiated).async {
      reply((try? Self.openPlayableFile(path))?.durationUs)
    }
  }

  // MARK: - Handlers (serial queue)

  private func handleLoad(_ args: [String: Any]?, _ reply: (Any?) -> Void) {
    guard let path = args?["path"] as? String else {
      reply(FlutterError(code: "bad_args", message: "load requires {path: String}", details: nil))
      return
    }
    // Replace any previously loaded file: stop playback and forget the old
    // file first, so a failed load never leaves the previous track playable
    // under the new track's name (matches the desktop core).
    stopOutput()
    file = nil
    durationUs = 0
    state = .idle
    let opened: (file: AVAudioFile, durationUs: Int64)
    do {
      opened = try Self.openPlayableFile(path)
    } catch {
      reply(FlutterError(
        code: "load_failed",
        message: error.localizedDescription,
        details: nil))
      return
    }
    do {
      try setUpEngine(for: opened.file)
    } catch {
      reply(FlutterError(
        code: "load_failed",
        message: "The audio engine rejected \(path): \(error.localizedDescription)",
        details: nil))
      return
    }
    file = opened.file
    durationUs = opened.durationUs
    state = .loaded
    reply(durationUs)
  }

  private func handlePlayAt(_ args: [String: Any]?, _ reply: (Any?) -> Void) {
    guard let audioFile = file else {
      reply(FlutterError(code: "no_file", message: "playAt before load", details: nil))
      return
    }
    guard
      let nativeTimeUs = (args?["nativeTimeUs"] as? NSNumber)?.int64Value,
      let positionUs = (args?["positionUs"] as? NSNumber)?.int64Value
    else {
      reply(FlutterError(code: "bad_args", message: "playAt requires nativeTimeUs and positionUs", details: nil))
      return
    }
    let rate = (args?["rate"] as? NSNumber)?.doubleValue ?? 1.0
    guard Self.rateRange.contains(rate) else {
      reply(FlutterError(
        code: "bad_args", message: "playAt rate must be within \(Self.rateRange)", details: nil))
      return
    }

    // An anchor further ahead than any jam schedules is a caller bug (e.g. an
    // uncalibrated clock). Refused rather than scheduled: AVFAudio's own
    // host-time arithmetic overflows for absurd values and reports garbage
    // positions.
    guard Double(nativeTimeUs) - Double(Self.machNowUs()) <= Double(Self.maxLeadUs) else {
      reply(FlutterError(
        code: "bad_args",
        message: "playAt nativeTimeUs is more than \(Self.maxLeadUs / 1_000_000) s ahead of the native clock",
        details: nil))
      return
    }

    // Calling while already playing/scheduled: stop the node (clears the
    // schedule and resets its sample clock) and reschedule below. Until the
    // new schedule is installed we are not playing, whatever happens next.
    // A pending engineRestarted is moot: this IS the re-schedule.
    stopOutput()
    cancelRestartEvent()

    #if os(iOS)
    // After an interruption the OS has deactivated our session; the engine
    // cannot start until we re-activate it.
    if sessionMayBeInactive || !(engine?.isRunning ?? false) {
      do {
        try AVAudioSession.sharedInstance().setActive(true)
        sessionMayBeInactive = false
        interruptionInProgress = false
      } catch let error where Self.isActivationRefusal(error) {
        // The OS refused us audio (a call is in progress, or a higher-priority
        // session holds the hardware). Same contract as Android's refused
        // audio focus: do not play, report an interruption, and complete
        // normally — the Dart engine re-anchors once the device is free.
        // Reported on EVERY refusal, like Android, not once per interruption:
        // Dart clears its suspension when it retries (e.g. resuming local
        // output) and relies on each refused playAt re-reporting it.
        interruptionInProgress = true
        sessionMayBeInactive = true
        emitEvent("interruptionBegan")
        reply(nil)
        return
      } catch {
        // Anything else: let engine.start() below report it.
      }
    }
    #endif

    if engine == nil {
      // Discarded after an AVFAudio exception or a media-services reset.
      do { try setUpEngine(for: audioFile) } catch {
        reply(FlutterError(
          code: "engine_error",
          message: "Could not rebuild the audio engine: \(error.localizedDescription)",
          details: nil))
        return
      }
    }
    guard let engine = engine, let player = player, let timePitch = timePitch else {
      reply(FlutterError(code: "engine_error", message: "audio engine unavailable", details: nil))
      return
    }

    if !engine.isRunning {
      do { try startEngine(engine) } catch {
        reply(FlutterError(
          code: "engine_start_failed",
          message: "AVAudioEngine failed to start: \(error.localizedDescription)",
          details: nil))
        return
      }
    }
    // play(at:) raises an NSException ("player did not see an IO cycle") if
    // the engine has not rendered since starting, so ensure a render cycle
    // has happened first (the exception catcher below is the backstop).
    guard waitForFirstRenderCycle(engine) else {
      reply(FlutterError(
        code: "engine_not_running",
        message: "audio engine produced no IO cycle within 1 s (output device unavailable?)",
        details: nil))
      return
    }

    timePitch.rate = Float(rate)

    // A "start ASAP" path is deliberately absent: an unscheduled start incurs
    // the engine's unpredictable spin-up delay (tens of ms), which shows up as
    // a constant position lag that drift correction can never remove (it
    // re-anchors through this same path and lags again). Instead a late
    // anchor (§5.3 late join) is re-anchored minLeadUs into the future with
    // the media position advanced to match, so the engine itself lands the
    // start sample-accurately.
    //
    // The arithmetic is in Double and range-checked before any Int64
    // conversion: both inputs come from Dart and must not be able to trap.
    let minLeadUs: Int64 = 150_000
    let now = Self.machNowUs()
    var startPositionUs = Double(positionUs)
    var effectiveAnchorUs = nativeTimeUs
    if nativeTimeUs < now + minLeadUs {
      effectiveAnchorUs = now + minLeadUs
      startPositionUs += ((Double(effectiveAnchorUs) - Double(nativeTimeUs)) * rate).rounded()
    }
    let startTime = AVAudioTime(hostTime: Self.hostTicks(fromUs: effectiveAnchorUs))

    let sampleRate = audioFile.processingFormat.sampleRate
    let startFrameExact = (startPositionUs * sampleRate / 1_000_000.0).rounded()
    guard startFrameExact.isFinite, startFrameExact >= 0, startFrameExact < Double(audioFile.length) else {
      reply(FlutterError(
        code: "bad_position",
        message: "start position \(Self.clampedInt64(startPositionUs))us is outside the file (duration \(durationUs)us)",
        details: nil))
      return
    }
    let startFrame = AVAudioFramePosition(startFrameExact)
    // Keep the anchor frame-exact so the position formula has no rounding bias.
    segmentStartUs = Self.clampedInt64(Double(startFrame) * 1_000_000.0 / sampleRate)

    // Last-moment check: a route change can stop the engine at any instant
    // (on the system's thread), and play(at:) on a stopped engine raises
    // "required condition is false: _engine->IsRunning()". The catcher below
    // covers the remaining check-to-call window.
    guard engine.isRunning else {
      reply(FlutterError(
        code: "engine_not_running",
        message: "audio engine stopped before playback could be scheduled (route change?)",
        details: nil))
      return
    }

    let generation = scheduleGeneration
    let completion: AVAudioPlayerNodeCompletionHandler = { [weak self] _ in
      guard let self = self else { return }
      self.queue.async {
        guard self.scheduleGeneration == generation else { return }
        self.state = .finished
        self.emitEvent("playbackFinished")
      }
    }
    let fileLength = audioFile.length
    // load refuses lengths beyond maxFrames, so this is at most 128 segments;
    // checked again here because the loop below runs on the serial queue and
    // must never be the thing a crafted file can stretch.
    let segmentCount = (fileLength - startFrame + Self.maxSegmentFrames - 1) / Self.maxSegmentFrames
    guard fileLength <= Self.maxFrames, segmentCount <= Self.maxFrames / Self.maxSegmentFrames else {
      reply(FlutterError(
        code: "bad_position",
        message: "the file declares an implausible length (\(fileLength) frames)",
        details: nil))
      return
    }
    do {
      try LJObjCExceptionCatcher.catching {
        var segmentStart = startFrame
        while segmentStart < fileLength {
          let count = min(fileLength - segmentStart, Self.maxSegmentFrames)
          let isLast = segmentStart + count >= fileLength
          player.scheduleSegment(
            audioFile,
            startingFrame: segmentStart,
            frameCount: AVAudioFrameCount(count),
            at: nil,
            completionCallbackType: .dataPlayedBack,
            completionHandler: isLast ? completion : nil)
          segmentStart += count
        }
        player.play(at: startTime)
      }
    } catch {
      // The node's timeline cannot be trusted after AVFAudio raised (see the
      // class comment); rebuild the graph on the next playAt.
      discardEngine()
      reply(FlutterError(
        code: "engine_error",
        message: "AVAudioEngine refused to schedule playback: \(error.localizedDescription)",
        details: nil))
      return
    }
    state = .playing
    reply(nil)
  }

  private func handlePause(_ reply: (Any?) -> Void) {
    if state == .playing {
      let player = self.player
      do {
        try LJObjCExceptionCatcher.catching { player?.pause() }
        state = .paused
      } catch {
        // The node raised (engine torn down under it by a route change):
        // its timeline is untrustworthy, so rebuild on the next playAt. The
        // output is stopped either way, which is what pause promised.
        discardEngine()
      }
    }
    reply(nil)
  }

  private func handleStop(_ reply: (Any?) -> Void) {
    stopOutput()
    cancelRestartEvent()
    state = (file != nil) ? .loaded : .idle
    reply(nil)
  }

  private func handlePositionUs(_ reply: (Any?) -> Void) {
    // Contract: null when nothing is playing or scheduled.
    guard state == .playing, let player = player else {
      reply(nil)
      return
    }
    // Derived from the engine's sample clock, not a cached value: the player
    // maintains a host-time ↔ source-frame mapping from its actual render
    // callbacks; querying it AT the current host time yields the source-frame
    // count "now" (see the class comment for why no ×rate term appears and
    // for measured accuracy). Before a scheduled start it extrapolates
    // negative, matching the §5.1 anchor formula. Fall back to lastRenderTime
    // (~render-ahead lead) if the host-time query fails.
    let nowNodeTime = AVAudioTime(hostTime: mach_absolute_time())
    guard let playerTime =
      player.playerTime(forNodeTime: nowNodeTime)
        ?? player.lastRenderTime.flatMap({ player.playerTime(forNodeTime: $0) }),
      playerTime.sampleRate > 0
    else {
      // Engine stalled (e.g. mid route change): no live sample clock to read.
      reply(nil)
      return
    }
    // Clamped, not converted: a far-future anchor extrapolates a huge
    // negative sampleTime whose µs value does not fit an Int64.
    let elapsedMediaUs = Self.clampedInt64(Double(playerTime.sampleTime) * 1_000_000.0 / playerTime.sampleRate)
    let positionUs = segmentStartUs.addingReportingOverflow(elapsedMediaUs)
    let clamped = positionUs.overflow ? (elapsedMediaUs < 0 ? 0 : durationUs) : positionUs.partialValue
    reply(min(max(clamped, 0), durationUs))
  }

  private func handleSetRate(_ args: [String: Any]?, _ reply: (Any?) -> Void) {
    guard let rate = (args?["rate"] as? NSNumber)?.doubleValue, Self.rateRange.contains(rate) else {
      reply(FlutterError(
        code: "bad_args", message: "setRate requires {rate: double within \(Self.rateRange)}", details: nil))
      return
    }
    // AVAudioUnitTimePitch.rate is settable live without a glitch, and it
    // pitch-corrects, so a ±0.5% drift slew is inaudible. The position
    // formula needs no re-anchoring (the player's source-frame clock simply
    // changes slope).
    timePitch?.rate = Float(rate)
    reply(nil)
  }

  private func handleOutputLatencyUs(_ reply: (Any?) -> Void) {
    #if os(iOS)
    let latencySeconds = AVAudioSession.sharedInstance().outputLatency
    #else
    let latencySeconds = engine?.outputNode.presentationLatency ?? 0
    #endif
    reply(latencySeconds.isFinite ? Self.clampedInt64(latencySeconds * 1_000_000.0) : Int64(0))
  }

  private func handleDispose(_ reply: (Any?) -> Void) {
    cancelRestartEvent()
    discardEngine()
    removeSessionObservers()
    file = nil
    state = .idle
    durationUs = 0
    #if os(iOS)
    interruptionInProgress = false
    sessionMayBeInactive = false
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    #endif
    reply(nil)
  }

  // MARK: - Engine plumbing

  /// Stops our own output immediately and drops any schedule. Returns whether
  /// a live (playing or paused) schedule was dropped.
  @discardableResult
  private func stopOutput() -> Bool {
    scheduleGeneration &+= 1
    let hadSchedule = state == .playing || state == .paused
    try? LJObjCExceptionCatcher.catching { self.player?.stop() }
    if hadSchedule {
      state = (file != nil) ? .loaded : .idle
    }
    return hadSchedule
  }

  /// Throws the engine graph away; the next playAt (or load) rebuilds it.
  /// Used after AVFAudio raised, and after a media-services reset.
  private func discardEngine() {
    scheduleGeneration &+= 1
    let oldPlayer = player
    let oldEngine = engine
    try? LJObjCExceptionCatcher.catching {
      oldPlayer?.stop()
      oldEngine?.stop()
    }
    if let observer = configChangeObserver {
      NotificationCenter.default.removeObserver(observer)
      configChangeObserver = nil
    }
    engine = nil
    player = nil
    timePitch = nil
    if state == .playing || state == .paused || state == .finished {
      state = (file != nil) ? .loaded : .idle
    }
  }

  private func setUpEngine(for audioFile: AVAudioFile) throws {
    #if os(iOS)
    let session = AVAudioSession.sharedInstance()
    try? session.setCategory(.playback, mode: .default)
    if (try? session.setActive(true)) != nil {
      sessionMayBeInactive = false
    }
    #endif
    installSessionObservers()
    if engine == nil {
      let newEngine = AVAudioEngine()
      let newPlayer = AVAudioPlayerNode()
      let newTimePitch = AVAudioUnitTimePitch()
      newEngine.attach(newPlayer)
      newEngine.attach(newTimePitch)
      engine = newEngine
      player = newPlayer
      timePitch = newTimePitch
      // A route change (headphones unplugged, Bluetooth connect) fires this
      // and may stop the engine and drop the player's schedule. We restart
      // the engine so subsequent calls work and emit 'engineRestarted' on the
      // event channel; the Dart side re-calibrates and re-schedules from the
      // authoritative anchor.
      configChangeObserver = NotificationCenter.default.addObserver(
        forName: .AVAudioEngineConfigurationChange,
        object: newEngine,
        queue: nil
      ) { [weak self, weak newEngine] _ in
        self?.queue.async {
          // Ignore a late notification from an engine discarded since.
          guard let self = self, let changed = newEngine, changed === self.engine else { return }
          self.handleConfigurationChange()
        }
      }
    }
    guard let engine = engine, let player = player, let timePitch = timePitch else {
      throw FileProblem(message: "audio engine unavailable")
    }
    // (Re)connect with the new file's processing format so the player's
    // timeline runs at the file's sample rate. connect() raises on a format a
    // node rejects; a graph that raised is not reused.
    do {
      try LJObjCExceptionCatcher.catching {
        engine.stop()
        engine.connect(player, to: timePitch, format: audioFile.processingFormat)
        engine.connect(timePitch, to: engine.mainMixerNode, format: audioFile.processingFormat)
        engine.prepare()
      }
    } catch {
      discardEngine()
      throw error
    }
    // Starting now only warms the output up so the first playAt needs no
    // spin-up; it is not required to succeed (e.g. during a phone call).
    // playAt starts it again and reports a failure where it matters.
    try? startEngine(engine)
  }

  /// `AVAudioEngine.start()` both throws (a Swift error: no output device, the
  /// session is not ours) and, mid route change, RAISES (an NSException Swift
  /// cannot catch). Both surface as a thrown error here; an engine that raised
  /// is discarded so the next playAt rebuilds the graph.
  private func startEngine(_ engine: AVAudioEngine) throws {
    var startError: Error?
    do {
      try LJObjCExceptionCatcher.catching {
        do { try engine.start() } catch { startError = error }
      }
    } catch {
      discardEngine()
      throw error
    }
    if let startError = startError {
      throw startError
    }
  }

  /// Blocks (on the plugin's serial queue only) until the engine's output has
  /// rendered at least one cycle, which play(at:) requires. Returns false on
  /// timeout.
  private func waitForFirstRenderCycle(_ engine: AVAudioEngine, timeoutUs: Int64 = 1_000_000) -> Bool {
    let deadline = Self.machNowUs() + timeoutUs
    while Self.machNowUs() < deadline {
      if let renderTime = engine.outputNode.lastRenderTime, renderTime.isSampleTimeValid {
        return true
      }
      if !engine.isRunning {
        return false
      }
      usleep(2000)
    }
    return false
  }

  private func handleConfigurationChange() {
    guard let engine = engine else { return }
    // The player's schedule is gone (or about to be); reflect reality.
    let lostSchedule = stopOutput()
    var lostOutput = false
    #if os(iOS)
    // The session is not ours during an interruption: restarting would fail,
    // and the next playAt re-activates and restarts anyway.
    if interruptionInProgress { return }
    #else
    // Unplugged, and this notification beat the default-device listener: the
    // device the engine was playing on no longer exists. That is a lost
    // output, never a re-schedule (which would land on the speaker).
    if lostSchedule, let previous = lastOutputDevice, !Self.deviceIsAlive(previous) {
      reportLostDefaultOutput(previous)
      lostOutput = true
    }
    #endif
    if !engine.isRunning {
      do {
        try startEngine(engine)
      } catch {
        // Nothing more we can do by ourselves: output stays stopped until the
        // next playAt, which starts (or rebuilds) the engine afresh. (After a
        // lost output Dart already waits for the user; no second report.)
        if (lostSchedule && !lostOutput) || pendingRestartEvent != nil {
          cancelRestartEvent()
          emitEvent("playbackError", [
            "code": "engine_start_failed",
            "message": "AVAudioEngine could not restart after a configuration change: \(error.localizedDescription)",
          ])
        }
        return
      }
    }
    // Tell Dart the schedule it relied on is gone so it can re-calibrate and
    // re-schedule from the authoritative anchor — unless the same change
    // turns out to be a lost output, whose route-change notification the OS
    // may deliver after this one (see scheduleRestartEvent). Nothing to say
    // when nothing was playing — in particular after an oldDeviceUnavailable
    // stop, where a re-schedule would put the audio on the speaker.
    if (lostSchedule && !lostOutput) || pendingRestartEvent != nil {
      scheduleRestartEvent()
    }
  }

  /// Emits `engineRestarted` after `restartEventDelay`, unless a lost-output
  /// route change (handleRouteChange), a new schedule, a stop or dispose
  /// comes first. Re-arming keeps one pending event across bursts of
  /// configuration changes.
  private func scheduleRestartEvent() {
    pendingRestartEvent?.cancel()
    let generation = scheduleGeneration
    restartEventToken &+= 1
    let token = restartEventToken
    let item = DispatchWorkItem { [weak self] in
      // A cancelled or re-armed event is stale even if it already started.
      guard let self = self, self.restartEventToken == token else { return }
      self.pendingRestartEvent = nil
      // Anything that replaced or dropped the schedule since makes the event
      // moot (it bumped the generation).
      guard self.scheduleGeneration == generation, self.state != .playing else { return }
      self.emitEvent("engineRestarted")
    }
    pendingRestartEvent = item
    queue.asyncAfter(deadline: .now() + Self.restartEventDelay, execute: item)
  }

  private func cancelRestartEvent() {
    restartEventToken &+= 1
    pendingRestartEvent?.cancel()
    pendingRestartEvent = nil
  }

  /// Handles any output-route change. `oldDeviceUnavailable`: the previous
  /// output went away (unplugged / disconnected) — stop first, so the audio
  /// never jumps to the speaker, and leave it stopped.
  private func handleRouteChange(oldDeviceUnavailable: Bool) {
    if oldDeviceUnavailable {
      stopOutput()
      // An engineRestarted still pending for this same unplug (the engine's
      // configuration change came first) would make Dart re-schedule — onto
      // the speaker. The lost output is the whole story.
      cancelRestartEvent()
    }
    var fields: [String: Any] = ["oldDeviceUnavailable": oldDeviceUnavailable]
    #if os(iOS)
    // By now the session reflects the NEW route, so this is the new route's
    // output latency (§7). (macOS omits it: the engine re-binds to the new
    // device only after its configuration change, so Dart re-queries
    // outputLatencyUs at schedule time instead.)
    let latencySeconds = AVAudioSession.sharedInstance().outputLatency
    fields["outputLatencyUs"] = latencySeconds.isFinite
      ? Self.clampedInt64(latencySeconds * 1_000_000.0) : Int64(0)
    #endif
    if let routeId = Self.currentRouteId() {
      fields["routeId"] = routeId
    }
    emitEvent("routeChanged", fields)
  }

  private func installSessionObservers() {
    #if os(iOS)
    if routeChangeObserver == nil {
      routeChangeObserver = NotificationCenter.default.addObserver(
        forName: AVAudioSession.routeChangeNotification,
        object: nil,
        queue: nil
      ) { [weak self] note in
        let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue
        let oldDeviceUnavailable =
          reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
        self?.queue.async { self?.handleRouteChange(oldDeviceUnavailable: oldDeviceUnavailable) }
      }
    }
    if interruptionObserver == nil {
      interruptionObserver = NotificationCenter.default.addObserver(
        forName: AVAudioSession.interruptionNotification,
        object: nil,
        queue: nil
      ) { [weak self] note in
        guard
          let raw = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue,
          let type = AVAudioSession.InterruptionType(rawValue: raw)
        else { return }
        switch type {
        case .began:
          self?.queue.async { self?.handleInterruptionBegan() }
        case .ended:
          let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? NSNumber)?.uintValue ?? 0
          let shouldResume = AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume)
          self?.queue.async { self?.handleInterruptionEnded(shouldResume: shouldResume) }
        @unknown default:
          break
        }
      }
    }
    if mediaServicesResetObserver == nil {
      mediaServicesResetObserver = NotificationCenter.default.addObserver(
        forName: AVAudioSession.mediaServicesWereResetNotification,
        object: nil,
        queue: nil
      ) { [weak self] _ in
        self?.queue.async { self?.handleMediaServicesReset() }
      }
    }
    #else
    if defaultOutputListener == nil {
      lastOutputDevice = Self.defaultOutputDevice()
      var address = Self.defaultOutputDeviceAddress
      // Delivered straight onto the serial queue.
      let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.handleDefaultOutputDeviceChange()
      }
      let status = AudioObjectAddPropertyListenerBlock(
        AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
      if status == noErr {
        defaultOutputListener = listener
        watchDataSource(of: lastOutputDevice)
      }
    }
    #endif
  }

  private func removeSessionObservers() {
    #if os(iOS)
    for observer in [routeChangeObserver, interruptionObserver, mediaServicesResetObserver] {
      if let observer = observer {
        NotificationCenter.default.removeObserver(observer)
      }
    }
    routeChangeObserver = nil
    interruptionObserver = nil
    mediaServicesResetObserver = nil
    #else
    if let listener = defaultOutputListener {
      var address = Self.defaultOutputDeviceAddress
      AudioObjectRemovePropertyListenerBlock(
        AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
      defaultOutputListener = nil
    }
    watchDataSource(of: nil)
    #endif
  }

  #if os(iOS)
  private func handleInterruptionBegan() {
    // The OS has already silenced us; make our state say so too, and make
    // sure nothing resumes by itself when the session comes back.
    interruptionInProgress = true
    sessionMayBeInactive = true
    stopOutput()
    emitEvent("interruptionBegan")
  }

  private func handleInterruptionEnded(shouldResume: Bool) {
    // Never auto-resume: the room timeline moved on while we were silent.
    // Dart re-anchors with playAt (which re-activates the session) if and
    // when it wants to; `shouldResume` is the OS's hint for that decision.
    interruptionInProgress = false
    emitEvent("interruptionEnded", ["shouldResume": shouldResume])
  }

  private func handleMediaServicesReset() {
    // Every AVAudioEngine/node object is now invalid. Throw them away; the
    // next playAt rebuilds the graph (and re-applies the session category)
    // from the loaded file.
    let lostSchedule = state == .playing || state == .paused
    discardEngine()
    sessionMayBeInactive = true
    interruptionInProgress = false
    if let url = file?.url {
      file = try? AVAudioFile(forReading: url)
      if file == nil {
        durationUs = 0
        state = .idle
      }
    }
    if lostSchedule {
      emitEvent("engineRestarted")
    }
  }

  /// Session-activation failures that mean "the OS will not give you audio
  /// right now" rather than "something is broken".
  private static func isActivationRefusal(_ error: Error) -> Bool {
    let code = (error as NSError).code
    return code == AVAudioSession.ErrorCode.insufficientPriority.rawValue
      || code == AVAudioSession.ErrorCode.cannotInterruptOthers.rawValue
  }
  #else
  private func handleDefaultOutputDeviceChange() {
    let previous = lastOutputDevice
    let current = Self.defaultOutputDevice()
    lastOutputDevice = current
    guard previous != current else { return }
    watchDataSource(of: current)
    // The previous device vanished (headphones / USB DAC unplugged, Bluetooth
    // disconnected) rather than the user picking another output.
    let oldDeviceUnavailable = previous.map { !Self.deviceIsAlive($0) } ?? false
    handleRouteChange(oldDeviceUnavailable: oldDeviceUnavailable)
  }

  /// The default output `previous` no longer exists, and a configuration
  /// change noticed before the default-device listener did. Reports the lost
  /// output now; the listener's own notification of the same change then
  /// finds nothing new to claim (at most a plain routeChanged naming the new
  /// route, if CoreAudio had not switched the default yet).
  private func reportLostDefaultOutput(_ previous: AudioDeviceID) {
    let current = Self.defaultOutputDevice()
    lastOutputDevice = current == previous ? nil : current
    watchDataSource(of: lastOutputDevice)
    handleRouteChange(oldDeviceUnavailable: true)
  }

  private static let dataSourceAddress = AudioObjectPropertyAddress(
    mSelector: kAudioDevicePropertyDataSource,
    mScope: kAudioDevicePropertyScopeOutput,
    mElement: elementMain)

  /// 'hdpn': the headphone-jack data source of a built-in output device.
  private static let headphonesDataSource: UInt32 = 0x6864_706e

  /// (Re)targets the data-source listener at `device` — the default output.
  private func watchDataSource(of device: AudioDeviceID?) {
    if let old = dataSourceDevice, let listener = dataSourceListener {
      var address = Self.dataSourceAddress
      AudioObjectRemovePropertyListenerBlock(old, &address, queue, listener)
    }
    dataSourceDevice = nil
    dataSourceListener = nil
    lastDataSource = nil
    guard let device = device else { return }
    var address = Self.dataSourceAddress
    guard AudioObjectHasProperty(device, &address) else { return }
    // Delivered straight onto the serial queue.
    let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
      self?.handleDataSourceChange()
    }
    guard AudioObjectAddPropertyListenerBlock(device, &address, queue, listener) == noErr else { return }
    dataSourceDevice = device
    dataSourceListener = listener
    lastDataSource = Self.uint32Property(
      device, kAudioDevicePropertyDataSource, kAudioDevicePropertyScopeOutput)
  }

  /// Speaker ↔ headphone jack on one device. Headphones pulled out is a lost
  /// output exactly like an unplugged USB DAC: stop, never fall back to the
  /// speaker by ourselves.
  private func handleDataSourceChange() {
    guard let device = dataSourceDevice else { return }
    let previous = lastDataSource
    let current = Self.uint32Property(
      device, kAudioDevicePropertyDataSource, kAudioDevicePropertyScopeOutput)
    lastDataSource = current
    guard previous != current else { return }
    handleRouteChange(oldDeviceUnavailable: previous == Self.headphonesDataSource)
  }
  #endif

  // MARK: - Route identity

  /// Stable, opaque id of the current output route: same headphones → same
  /// id across sessions, different device → different id. Port/device UIDs
  /// are hashed because Bluetooth UIDs embed the device's MAC address.
  ///
  /// iOS: `<portType>:<hash(uid)>` per output port (joined with `+`).
  /// macOS: `<transport>[/<dataSource>]:<hash(uid)>` of the default output
  /// device.
  private static func currentRouteId() -> String? {
    #if os(iOS)
    let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
    guard !outputs.isEmpty else { return nil }
    return outputs
      .map { "\($0.portType.rawValue):\(stableHash($0.uid))" }
      .sorted()
      .joined(separator: "+")
    #else
    guard let device = defaultOutputDevice(), let uid = deviceUID(device) else { return nil }
    var kind = uint32Property(device, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal)
      .map(fourCC) ?? "unknown"
    // Intel Macs switch speaker ↔ headphone jack as a data source of ONE
    // device; the data source keeps those two routes apart.
    if let source = uint32Property(device, kAudioDevicePropertyDataSource, kAudioDevicePropertyScopeOutput) {
      kind += "/" + fourCC(source)
    }
    return "\(kind):\(stableHash(uid))"
    #endif
  }

  /// FNV-1a 64 — deterministic across launches (unlike Swift's Hasher).
  private static func stableHash(_ text: String) -> String {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in text.utf8 {
      hash ^= UInt64(byte)
      hash = hash &* 0x0000_0100_0000_01b3
    }
    return String(format: "%016llx", hash)
  }

  #if os(macOS)
  /// kAudioObjectPropertyElementMain (macOS 12+; "Master" before) — both 0.
  private static let elementMain = AudioObjectPropertyElement(0)

  private static let defaultOutputDeviceAddress = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultOutputDevice,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: elementMain)

  private static func defaultOutputDevice() -> AudioDeviceID? {
    var device = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var address = defaultOutputDeviceAddress
    let status = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
    guard status == noErr, device != AudioDeviceID(kAudioObjectUnknown) else { return nil }
    return device
  }

  private static func deviceIsAlive(_ device: AudioDeviceID) -> Bool {
    // A removed device's id is simply invalid: the query fails.
    uint32Property(device, kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal)
      .map { $0 != 0 } ?? false
  }

  private static func deviceUID(_ device: AudioDeviceID) -> String? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyDeviceUID,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: elementMain)
    var uid: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid)
    guard status == noErr, let value = uid else { return nil }
    // The property hands over a +1 reference.
    return value.takeRetainedValue() as String
  }

  private static func uint32Property(
    _ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
    _ scope: AudioObjectPropertyScope
  ) -> UInt32? {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: elementMain)
    guard AudioObjectHasProperty(object, &address) else { return nil }
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
    return status == noErr ? value : nil
  }

  /// 'blue' → "blue"; non-printable codes fall back to hex.
  private static func fourCC(_ value: UInt32) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> UInt32($0)) }
    guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }) else {
      return String(format: "%08x", value)
    }
    return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
  }
  #endif

  deinit {
    pendingRestartEvent?.cancel()
    if let observer = configChangeObserver {
      NotificationCenter.default.removeObserver(observer)
    }
    removeSessionObservers()
    // Teardown raises too (an engine mid route change); a crash while the
    // plugin is being released is still a crash.
    let player = self.player
    let engine = self.engine
    try? LJObjCExceptionCatcher.catching {
      player?.stop()
      engine?.stop()
    }
  }
}

// MARK: - OS media session (channel `localjam_audio/media_session`)

/// Publishes now-playing state to MPNowPlayingInfoCenter (lock screen,
/// Control Center, macOS Now Playing menu) and routes MPRemoteCommandCenter
/// transport commands (lock screen, headset buttons, watch, car) back to
/// Dart as `remoteCommand {command, positionUs?}`.
///
/// Shared verbatim between the iOS and macOS targets, like the player above.
final class JamMediaSessionHandler {
  private let channel: FlutterMethodChannel
  private var commandTargetsInstalled = false

  init(channel: FlutterMethodChannel) {
    self.channel = channel
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "update":
      guard let args = call.arguments as? [String: Any] else {
        result(FlutterError(code: "bad_args", message: "update needs a map", details: nil))
        return
      }
      update(args)
      result(nil)
    case "clear":
      clear()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func update(_ args: [String: Any]) {
    installCommandTargetsIfNeeded()

    var info: [String: Any] = [:]
    info[MPMediaItemPropertyTitle] = (args["title"] as? String) ?? "LocalJam"
    if let artist = args["artist"] as? String { info[MPMediaItemPropertyArtist] = artist }
    if let album = args["album"] as? String { info[MPMediaItemPropertyAlbumTitle] = album }
    if let durationUs = (args["durationUs"] as? NSNumber)?.doubleValue {
      info[MPMediaItemPropertyPlaybackDuration] = durationUs / 1_000_000.0
    }
    let positionUs = (args["positionUs"] as? NSNumber)?.doubleValue ?? 0
    info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = positionUs / 1_000_000.0
    let playing = (args["playing"] as? Bool) ?? false
    let rate = (args["rate"] as? NSNumber)?.doubleValue ?? 1.0
    info[MPNowPlayingInfoPropertyPlaybackRate] = playing ? rate : 0.0

    if let artworkData = (args["artworkBytes"] as? FlutterStandardTypedData)?.data {
      #if os(iOS)
      if let image = UIImage(data: artworkData) {
        info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
      }
      #else
      if let image = NSImage(data: artworkData) {
        info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
      }
      #endif
    }

    let center = MPRemoteCommandCenter.shared()
    let canPlayPause = (args["canPlayPause"] as? Bool) ?? false
    center.playCommand.isEnabled = canPlayPause
    center.pauseCommand.isEnabled = canPlayPause
    center.togglePlayPauseCommand.isEnabled = canPlayPause
    center.nextTrackCommand.isEnabled = (args["canNext"] as? Bool) ?? false
    center.previousTrackCommand.isEnabled = (args["canPrevious"] as? Bool) ?? false
    center.changePlaybackPositionCommand.isEnabled = (args["canSeek"] as? Bool) ?? false

    let nowPlaying = MPNowPlayingInfoCenter.default()
    nowPlaying.nowPlayingInfo = info
    #if os(macOS)
    nowPlaying.playbackState = playing ? .playing : .paused
    #endif
    lastKnownPlaying = playing
  }

  private func clear() {
    let nowPlaying = MPNowPlayingInfoCenter.default()
    nowPlaying.nowPlayingInfo = nil
    #if os(macOS)
    nowPlaying.playbackState = .stopped
    #endif
    let center = MPRemoteCommandCenter.shared()
    center.playCommand.isEnabled = false
    center.pauseCommand.isEnabled = false
    center.togglePlayPauseCommand.isEnabled = false
    center.nextTrackCommand.isEnabled = false
    center.previousTrackCommand.isEnabled = false
    center.changePlaybackPositionCommand.isEnabled = false
  }

  /// Last `playing` pushed from Dart, so togglePlayPause maps to the right
  /// concrete command.
  private var lastKnownPlaying = false

  private func installCommandTargetsIfNeeded() {
    guard !commandTargetsInstalled else { return }
    commandTargetsInstalled = true
    let center = MPRemoteCommandCenter.shared()
    center.playCommand.addTarget { [weak self] _ in
      self?.send("play")
      return .success
    }
    center.pauseCommand.addTarget { [weak self] _ in
      self?.send("pause")
      return .success
    }
    center.togglePlayPauseCommand.addTarget { [weak self] _ in
      guard let self else { return .commandFailed }
      self.send(self.lastKnownPlaying ? "pause" : "play")
      return .success
    }
    center.nextTrackCommand.addTarget { [weak self] _ in
      self?.send("next")
      return .success
    }
    center.previousTrackCommand.addTarget { [weak self] _ in
      self?.send("previous")
      return .success
    }
    center.changePlaybackPositionCommand.addTarget { [weak self] event in
      guard let event = event as? MPChangePlaybackPositionCommandEvent else {
        return .commandFailed
      }
      self?.send("seek", positionUs: Int64(event.positionTime * 1_000_000.0))
      return .success
    }
  }

  private func send(_ command: String, positionUs: Int64? = nil) {
    DispatchQueue.main.async { [channel] in
      var args: [String: Any] = ["command": command]
      if let positionUs { args["positionUs"] = positionUs }
      channel.invokeMethod("remoteCommand", arguments: args)
    }
  }
}
