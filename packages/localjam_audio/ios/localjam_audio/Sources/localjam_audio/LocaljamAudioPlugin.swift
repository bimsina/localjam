import AVFoundation
import MediaPlayer
#if os(iOS)
import Flutter
import UIKit
#else
import AppKit
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
/// error.
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
  // Emits maps {type: String, outputLatencyUs: Int64?} for playback
  // interruptions the Dart side must react to (route changes, OS audio
  // interruptions, engine restarts, natural end of the scheduled segment).

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
  private func emitEvent(_ type: String, outputLatencyUs: Int64? = nil) {
    DispatchQueue.main.async { [weak self] in
      guard let sink = self?.eventSink else { return }
      var payload: [String: Any] = ["type": type]
      if let latencyUs = outputLatencyUs {
        payload["outputLatencyUs"] = latencyUs
      }
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
  private static func hostTicks(fromUs us: Int64) -> UInt64 {
    let ns = UInt64(max(0, us)) * 1000
    let n = UInt64(timebase.numer)
    let d = UInt64(timebase.denom)
    return (ns / n) * d + (ns % n) * d / n
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
  #endif

  // MARK: - Method channel

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any]
    // `reply` marshals back to the platform thread; each case below calls it
    // exactly once.
    let reply: (Any?) -> Void = { value in
      DispatchQueue.main.async { result(value) }
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

  // MARK: - Handlers (serial queue)

  private func handleLoad(_ args: [String: Any]?, _ reply: (Any?) -> Void) {
    guard let path = args?["path"] as? String else {
      reply(FlutterError(code: "bad_args", message: "load requires {path: String}", details: nil))
      return
    }
    // Replace any previously loaded file; stop playback first.
    scheduleGeneration &+= 1
    player?.stop()
    let audioFile: AVAudioFile
    do {
      audioFile = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    } catch {
      reply(FlutterError(
        code: "load_failed",
        message: "Could not open audio file at \(path): \(error.localizedDescription)",
        details: nil))
      return
    }
    do {
      try setUpEngine(for: audioFile)
    } catch {
      reply(FlutterError(
        code: "engine_start_failed",
        message: "AVAudioEngine failed to start: \(error.localizedDescription)",
        details: nil))
      return
    }
    file = audioFile
    durationUs = Int64(Double(audioFile.length) * 1_000_000.0 / audioFile.processingFormat.sampleRate)
    state = .loaded
    reply(durationUs)
  }

  private func handlePlayAt(_ args: [String: Any]?, _ reply: (Any?) -> Void) {
    guard let audioFile = file, let engine = engine, let player = player, let timePitch = timePitch else {
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

    // Calling while already playing/scheduled: stop the node (clears the
    // schedule and resets its sample clock) and reschedule below.
    scheduleGeneration &+= 1
    player.stop()

    if !engine.isRunning {
      do { try engine.start() } catch {
        reply(FlutterError(
          code: "engine_start_failed",
          message: "AVAudioEngine failed to start: \(error.localizedDescription)",
          details: nil))
        return
      }
    }
    // play(at:) raises an NSException ("player did not see an IO cycle") if
    // the engine has not rendered since starting; Swift cannot catch it, so
    // ensure a render cycle has happened first.
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
    let minLeadUs: Int64 = 150_000
    let now = Self.machNowUs()
    var startPositionUs = positionUs
    var effectiveAnchorUs = nativeTimeUs
    if nativeTimeUs < now + minLeadUs {
      effectiveAnchorUs = now + minLeadUs
      startPositionUs =
        positionUs + Int64((Double(effectiveAnchorUs - nativeTimeUs) * rate).rounded())
    }
    let startTime = AVAudioTime(hostTime: Self.hostTicks(fromUs: effectiveAnchorUs))

    let sampleRate = audioFile.processingFormat.sampleRate
    let startFrame = AVAudioFramePosition((Double(startPositionUs) * sampleRate / 1_000_000.0).rounded())
    let remainingFrames = audioFile.length - startFrame
    guard startFrame >= 0, remainingFrames > 0 else {
      reply(FlutterError(
        code: "bad_position",
        message: "start position \(startPositionUs)us is outside the file (duration \(durationUs)us)",
        details: nil))
      return
    }
    // Keep the anchor frame-exact so the position formula has no rounding bias.
    segmentStartUs = Int64(Double(startFrame) * 1_000_000.0 / sampleRate)

    let generation = scheduleGeneration
    player.scheduleSegment(
      audioFile,
      startingFrame: startFrame,
      frameCount: AVAudioFrameCount(remainingFrames),
      at: nil,
      completionCallbackType: .dataPlayedBack
    ) { [weak self] _ in
      guard let self = self else { return }
      self.queue.async {
        guard self.scheduleGeneration == generation else { return }
        self.state = .finished
        self.emitEvent("playbackFinished")
      }
    }
    player.play(at: startTime)
    state = .playing
    reply(nil)
  }

  private func handlePause(_ reply: (Any?) -> Void) {
    if state == .playing {
      player?.pause()
      state = .paused
    }
    reply(nil)
  }

  private func handleStop(_ reply: (Any?) -> Void) {
    scheduleGeneration &+= 1
    player?.stop()
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
        ?? player.lastRenderTime.flatMap({ player.playerTime(forNodeTime: $0) })
    else {
      // Engine stalled (e.g. mid route change): no live sample clock to read.
      reply(nil)
      return
    }
    let elapsedMediaUs = Int64(Double(playerTime.sampleTime) * 1_000_000.0 / playerTime.sampleRate)
    let positionUs = segmentStartUs + elapsedMediaUs
    reply(min(max(positionUs, 0), durationUs))
  }

  private func handleSetRate(_ args: [String: Any]?, _ reply: (Any?) -> Void) {
    guard let rate = (args?["rate"] as? NSNumber)?.doubleValue else {
      reply(FlutterError(code: "bad_args", message: "setRate requires {rate: double}", details: nil))
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
    reply(latencySeconds.isFinite ? Int64(latencySeconds * 1_000_000.0) : Int64(0))
  }

  private func handleDispose(_ reply: (Any?) -> Void) {
    scheduleGeneration &+= 1
    player?.stop()
    engine?.stop()
    if let observer = configChangeObserver {
      NotificationCenter.default.removeObserver(observer)
      configChangeObserver = nil
    }
    #if os(iOS)
    if let observer = routeChangeObserver {
      NotificationCenter.default.removeObserver(observer)
      routeChangeObserver = nil
    }
    if let observer = interruptionObserver {
      NotificationCenter.default.removeObserver(observer)
      interruptionObserver = nil
    }
    #endif
    engine = nil
    player = nil
    timePitch = nil
    file = nil
    state = .idle
    durationUs = 0
    #if os(iOS)
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    #endif
    reply(nil)
  }

  // MARK: - Engine plumbing

  private func setUpEngine(for audioFile: AVAudioFile) throws {
    #if os(iOS)
    let session = AVAudioSession.sharedInstance()
    try? session.setCategory(.playback, mode: .default)
    try? session.setActive(true)
    if routeChangeObserver == nil {
      routeChangeObserver = NotificationCenter.default.addObserver(
        forName: AVAudioSession.routeChangeNotification,
        object: nil,
        queue: nil
      ) { [weak self] _ in
        // By the time this fires the session already reflects the NEW route,
        // so this is the new route's output latency (§7).
        let latencySeconds = AVAudioSession.sharedInstance().outputLatency
        let latencyUs = latencySeconds.isFinite
          ? Int64(latencySeconds * 1_000_000.0) : Int64(0)
        self?.emitEvent("routeChanged", outputLatencyUs: latencyUs)
      }
    }
    if interruptionObserver == nil {
      interruptionObserver = NotificationCenter.default.addObserver(
        forName: AVAudioSession.interruptionNotification,
        object: nil,
        queue: nil
      ) { [weak self] note in
        guard
          let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
          let type = AVAudioSession.InterruptionType(rawValue: raw)
        else { return }
        switch type {
        case .began:
          self?.emitEvent("interruptionBegan")
        case .ended:
          self?.emitEvent("interruptionEnded")
        @unknown default:
          break
        }
      }
    }
    #endif
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
      ) { [weak self] _ in
        self?.queue.async { self?.handleConfigurationChange() }
      }
    }
    guard let engine = engine, let player = player, let timePitch = timePitch else {
      throw NSError(domain: "localjam_audio", code: 1)
    }
    // (Re)connect with the new file's processing format so the player's
    // timeline runs at the file's sample rate.
    engine.stop()
    engine.connect(player, to: timePitch, format: audioFile.processingFormat)
    engine.connect(timePitch, to: engine.mainMixerNode, format: audioFile.processingFormat)
    engine.prepare()
    try engine.start()
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
    if state == .playing || state == .paused {
      // The player's schedule is gone; reflect reality.
      player?.stop()
      state = (file != nil) ? .loaded : .idle
    }
    if !engine.isRunning {
      try? engine.start()
    }
    // Tell Dart the engine was restarted (its schedule, if any, is gone) so
    // it can re-calibrate and re-schedule from the authoritative anchor.
    emitEvent("engineRestarted")
  }

  deinit {
    if let observer = configChangeObserver {
      NotificationCenter.default.removeObserver(observer)
    }
    #if os(iOS)
    if let observer = routeChangeObserver {
      NotificationCenter.default.removeObserver(observer)
    }
    if let observer = interruptionObserver {
      NotificationCenter.default.removeObserver(observer)
    }
    #endif
    player?.stop()
    engine?.stop()
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
