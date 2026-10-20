/// Web implementation of the `localjam_audio` channels (docs/design/
/// WEB_GUEST.md D6/D7), registered by the Flutter web plugin registrant.
///
/// It answers the SAME method channel (`localjam_audio`) and event channel
/// (`localjam_audio/events`) as the native engines, with the same method
/// names, argument maps, error codes and event maps, so `LocaljamAudio` and
/// everything above it run unchanged in a browser.
///
/// Engine: Web Audio. One decoded `AudioBuffer` at a time (D7: a 5-min track
/// is ~100 MB of PCM), played by an `AudioBufferSourceNode` started with
/// `start(when, offset)` — sample-accurate, unlike an `<audio>` element whose
/// `currentTime` is tens of ms coarse (D6). Graph: source → `GainNode` (the
/// page's mute, `setMuted`) → destination. On iOS/iPadOS the gain feeds a
/// `MediaStreamAudioDestinationNode` whose stream plays in a hidden
/// `<audio playsinline>` element instead, so the page holds a media-element
/// audio session: it is meant to survive screen lock and the silent switch
/// (to be verified on a real iPhone; tests can only build the graph).
///
/// Clocks: the "native clock" is `performance.now()` in µs, so the Dart
/// side's calibration measures ~0 offset. A `playAt` anchor means the same as
/// on native: the frame at `positionUs` is due when the native clock reads
/// `nativeTimeUs`, and is HEARD [outputLatencyUs] later (the Dart side
/// subtracts that latency from its anchors, §7). Performance time is mapped
/// to `AudioContext` time with `getOutputTimestamp()` (the context time being
/// heard at a performance time) shifted by the reported latency; where that
/// API is missing or never yields a timestamp, `currentTime` is sampled
/// against `performance.now()` (render clock; heard ≈ render + reported
/// latency). With an accurate output timestamp the reported latency cancels
/// out, so a browser that under-reports it (or reports none) still lands on
/// time. Measured in headless Chrome: the timestamp trails `currentTime` by
/// exactly `outputLatency + baseLatency` and is stable to ~0.05 ms, while
/// `currentTime` moves in 23 ms callback steps.
///
/// Autoplay: the `AudioContext` is created lazily by the first call that
/// needs it and `resume()`d (and, on iOS, the `<audio>` element `play()`ed)
/// synchronously at the start of `load`, `playAt`, `outputLatencyUs` and
/// `setMuted` — so the page's "Tap to listen" handler must call one of them
/// (e.g. `outputLatencyUs()`) inside the gesture. Once running, the context
/// and the element are never paused by this plugin (later starts come from
/// the network, with no gesture to unlock them again).
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';
import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'package:web/web.dart' as web;

/// Where the loaded buffer is in its life (mirrors the native engines).
enum _State { idle, loaded, playing, paused, finished }

/// One straight piece of the schedule's media timeline: from context time
/// [ctxTime] on, media seconds advance from [mediaSec] at [rate] per second.
/// A `setRate` appends a piece instead of re-anchoring.
class _Segment {
  const _Segment(this.ctxTime, this.mediaSec, this.rate);

  final double ctxTime;
  final double mediaSec;
  final double rate;

  double mediaAt(double ctx) => mediaSec + (ctx - ctxTime) * rate;
}

/// The inline web platform of `localjam_audio` (pubspec `web:` entry).
///
/// Channel methods as on native (`nowUs`, `load`, `probeDuration`, `playAt`,
/// `pause`, `stop`, `positionUs`, `setRate`, `outputLatencyUs`,
/// `currentRouteId`, `dispose`) plus one web-only method, `setMuted
/// {muted: bool}`, which native sides do not implement (callers catch
/// `MissingPluginException`). Web-specific behaviour:
///  * `load {path}` / `probeDuration {path}`: `path` is a URL the page can
///    `fetch` — a `blob:` URL of bytes it already holds, or a same-origin
///    `http(s):` URL. Fetch failure or a non-2xx answer → `load_failed`; bytes
///    the browser cannot decode (Ogg/Opus on Safari) → `unsupported_format`.
///    `probeDuration` decodes the whole file too (the browser offers no
///    header-only probe), so it costs a full decode's CPU and transient
///    memory; it never touches the loaded buffer or playback, and answers
///    null on any failure. Durations are of the buffer as decoded, i.e.
///    resampled to the context's rate (within a frame of the file's).
///  * `playAt`: a past anchor (or one less than [_minLeadSec] ahead of the
///    render clock) starts [_minLeadSec] ahead with the position advanced
///    at ×rate, like native's late join. If the context cannot be brought to
///    `running` within 1 s (no user gesture yet, or iOS refused the audio
///    element), it completes WITHOUT playing and emits `interruptionBegan`,
///    as native does when the OS refuses audio; `interruptionEnded` follows
///    when the context runs again.
///  * `setRate` changes the live node's `playbackRate` (a resample: pitch
///    shifts ~9 cents at the ±0.5 % §5.4 slews, as on desktop).
///  * `pause` stops the node (native keeps a paused node; here `playAt`
///    re-anchors either way). `positionUs` is null unless playing/scheduled.
///  * `outputLatencyUs` = `outputLatency + baseLatency` where reported, else
///    0. `currentRouteId` is always null: browsers expose no output identity.
///  * Events: `playbackFinished` (the buffer ran out), `interruptionBegan`/
///    `interruptionEnded` (context `suspended`/`interrupted` and back; on iOS
///    also the `<audio>` element paused by the system and playing again),
///    `playbackError{code: context_closed}` (the browser closed the context
///    under a schedule). Never `routeChanged` or `engineRestarted`.
class LocaljamAudioWeb {
  LocaljamAudioWeb._(this._events);

  /// Installs the method-channel handler and the event stream on
  /// [registrar] (called by the generated web plugin registrant).
  static void registerWith(Registrar registrar) {
    final events = StreamController<Object?>.broadcast();
    final plugin = LocaljamAudioWeb._(events);
    debugInstance = plugin;
    MethodChannel(
      'localjam_audio',
      const StandardMethodCodec(),
      registrar,
    ).setMethodCallHandler(plugin._handle);
    PluginEventChannel<Object?>(
      'localjam_audio/events',
      const StandardMethodCodec(),
      registrar,
    ).setController(events);
  }

  /// The most recently registered instance (tests reach its context).
  @visibleForTesting
  static LocaljamAudioWeb? debugInstance;

  /// Forces the iOS graph (`<audio>` element output) on or off; null =
  /// detect from the user agent.
  @visibleForTesting
  static bool? debugIsIOSOverride;

  /// The live `AudioContext`, if one was created.
  @visibleForTesting
  web.AudioContext? get debugContext => _ctx;

  /// The hidden `<audio>` element of the iOS graph, if any.
  @visibleForTesting
  web.HTMLAudioElement? get debugElement => _element;

  static const double _minRate = 1.0 / 32.0;
  static const double _maxRate = 32.0;

  /// Same bound as native: an anchor further ahead is a caller bug.
  static const int _maxLeadUs = 3600000000;

  /// How far ahead of the render clock a start must be scheduled so that
  /// `start(when)` is honoured exactly even when the main thread's view of
  /// `currentTime` is a callback stale (Chrome: ~10 ms; 'playback' latency
  /// hint and phones: more).
  static const double _minLeadSec = 0.05;

  final StreamController<Object?> _events;

  web.AudioContext? _ctx;
  web.GainNode? _gain;
  web.HTMLAudioElement? _element;

  /// The outcome of the element's latest `play()`: true once it plays.
  Future<bool>? _elementPlay;
  bool _muted = false;

  web.AudioBuffer? _buffer;
  int _durationUs = 0;
  _State _state = _State.idle;
  web.AudioBufferSourceNode? _source;

  /// Bumped whenever the current node is abandoned, so its late `onended`
  /// cannot report a finish for a schedule that no longer exists.
  int _generation = 0;
  List<_Segment> _segments = const [];

  /// `contextTime − performanceTime` (s) of the output timestamp, once two
  /// successive render callbacks agree on it; null until then (and without
  /// `getOutputTimestamp`). Per context.
  double? _tsOffsetSec;

  /// A reading that disagreed with [_tsOffsetSec], awaiting confirmation.
  double? _tsCandidateSec;

  /// Context time of the last reading taken, to take each callback once.
  double _tsLastContextTime = 0;

  /// Performance time (ms) of the reading [_tsOffsetSec] last came from.
  double _tsAcceptedAtMs = 0;

  /// Whether this context already had its one wait for a first offset.
  bool _tsWaited = false;

  /// Whether the current schedule maps through [_tsOffsetSec] (else through
  /// `currentTime`). Fixed per schedule, so the mapping never flips under it.
  bool _scheduleUsesTimestamps = false;

  /// The latency (ms) the current schedule was mapped with, frozen so that
  /// browser jitter in `outputLatency` does not jitter [positionUs].
  double _scheduleLatencyMs = 0;

  bool _contextWasRunning = false;
  bool _interrupted = false;

  /// Serializes the state-changing methods, like the native serial queue.
  Future<void> _tail = Future<void>.value();

  Future<T> _serial<T>(Future<T> Function() body) {
    final result = _tail.then((_) => body());
    _tail = result.then((_) {}, onError: (Object _) {});
    return result;
  }

  Future<Object?> _handle(MethodCall call) {
    final args = call.arguments;
    switch (call.method) {
      // Off the serial path: clock reads and queries that touch no state.
      case 'nowUs':
        return Future<Object?>.value(_nowUs());
      case 'currentRouteId':
        return Future<Object?>.value(null);
      case 'probeDuration':
        return _probeDuration(args);
      case 'outputLatencyUs':
        return Future<Object?>.value(_latencyUs(_unlock()));
      // Unlocked synchronously, i.e. still inside the page's user gesture.
      case 'load':
        _unlock();
        return _serial(() => _load(args));
      case 'playAt':
        _unlock();
        return _serial(() => _playAt(args));
      case 'setMuted':
        _unlock();
        return _serial(() async => _setMuted(args));
      case 'pause':
        return _serial(() async => _pause());
      case 'stop':
        return _serial(() async => _stop());
      case 'positionUs':
        return _serial(() async => _positionUs());
      case 'setRate':
        return _serial(() async => _setRate(args));
      case 'dispose':
        return _serial(() async => _dispose());
    }
    // Answered as "not implemented", like FlutterMethodNotImplemented.
    throw MissingPluginException('localjam_audio (web): ${call.method}');
  }

  // ---------------------------------------------------------------------
  // Clock
  // ---------------------------------------------------------------------

  static double _perfNowMs() => web.window.performance.now();

  /// `performance.now()` in µs, floored (monotonic non-decreasing).
  static int _nowUs() => (_perfNowMs() * 1000).floor();

  /// Readings of successive callbacks agree to ~0.05 ms (Chrome); 2 ms is a
  /// real change.
  static const double _tsAgreeSec = 0.002;

  /// How fast the sound card's clock may legitimately walk away from
  /// `performance.now()` between readings (crystals: tens of ppm).
  static const double _tsDriftPerSec = 0.0005;

  /// Folds a fresh output timestamp into [_tsOffsetSec]. A reading counts
  /// only when plausible (non-zero, within 1 s of now) and from a new render
  /// callback (its context time advanced). Chrome's first readings after a
  /// start are garbage (context time ~0 against a real performance time,
  /// 25 ms off, then running backwards), and an underrun can genuinely move
  /// the offset, so a change beyond [_tsAgreeSec] (plus [_tsDriftPerSec] per
  /// second since the last accepted reading) is taken only once the next
  /// callback confirms it.
  void _refreshTimestamp(web.AudioContext ctx) {
    if (!(ctx as JSObject).has('getOutputTimestamp')) return;
    final ts = ctx.getOutputTimestamp();
    final contextTime = _number(ts, 'contextTime');
    final performanceTime = _number(ts, 'performanceTime');
    if (contextTime == null || performanceTime == null) return;
    if (contextTime <= 0 || performanceTime <= 0) return;
    if ((performanceTime - _perfNowMs()).abs() > 1000) return;
    if (contextTime <= _tsLastContextTime) return;
    _tsLastContextTime = contextTime;
    final offset = contextTime - performanceTime / 1000;
    final current = _tsOffsetSec;
    final candidate = _tsCandidateSec;
    final sinceAcceptedSec = math.max(
      0,
      (performanceTime - _tsAcceptedAtMs) / 1000,
    );
    final tolerance = _tsAgreeSec + _tsDriftPerSec * sinceAcceptedSec;
    if ((current != null && (offset - current).abs() <= tolerance) ||
        (candidate != null && (offset - candidate).abs() <= _tsAgreeSec)) {
      _tsOffsetSec = offset;
      _tsAcceptedAtMs = performanceTime;
      _tsCandidateSec = null;
    } else {
      _tsCandidateSec = offset;
    }
  }

  /// Gives a freshly running context up to 1 s (once) to produce a
  /// confirmed output timestamp: it reads zeros, then garbage, for the first
  /// few callbacks (~200 ms in Chrome).
  Future<void> _awaitTimestamp(web.AudioContext ctx) async {
    _refreshTimestamp(ctx);
    if (_tsWaited || _tsOffsetSec != null) return;
    _tsWaited = true;
    if (!(ctx as JSObject).has('getOutputTimestamp')) return;
    final deadline = _perfNowMs() + 1000;
    while (_tsOffsetSec == null && _perfNowMs() < deadline) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      if (!identical(ctx, _ctx)) return;
      _refreshTimestamp(ctx);
    }
  }

  /// Context time (s) of the frame due at performance time [perfMs], heard
  /// [latencyMs] later (see the library docs), through the output
  /// timestamp when [timestamps], else through `currentTime` (render clock,
  /// one callback coarse: 23 ms steps in Chrome with the 'playback' hint).
  double _ctxTimeAt(
    web.AudioContext ctx,
    double perfMs,
    double latencyMs, {
    required bool timestamps,
  }) {
    if (timestamps) {
      _refreshTimestamp(ctx); // Keeps the last good offset when stale.
      return _tsOffsetSec! + (perfMs + latencyMs) / 1000;
    }
    return ctx.currentTime + (perfMs - _perfNowMs()) / 1000;
  }

  /// `outputLatency + baseLatency` (s), each counted only where the browser
  /// reports a finite non-negative number (Safari: no `outputLatency`).
  static double _latencySec(web.AudioContext ctx) {
    var total = 0.0;
    for (final name in const ['outputLatency', 'baseLatency']) {
      final value = _number(ctx, name);
      if (value != null && value.isFinite && value > 0) total += value;
    }
    return total;
  }

  static int _latencyUs(web.AudioContext ctx) =>
      (_latencySec(ctx) * 1e6).round();

  static double? _number(JSObject object, String name) {
    final value = object.getProperty<JSAny?>(name.toJS);
    return value.isA<JSNumber>() ? (value as JSNumber).toDartDouble : null;
  }

  // ---------------------------------------------------------------------
  // Context and graph
  // ---------------------------------------------------------------------

  static bool get _isIOS {
    final override = debugIsIOSOverride;
    if (override != null) return override;
    final navigator = web.window.navigator;
    final ua = navigator.userAgent;
    if (RegExp('iPhone|iPad|iPod').hasMatch(ua)) return true;
    // iPadOS Safari claims to be a Mac; only the touch points give it away.
    return ua.contains('Macintosh') && navigator.maxTouchPoints > 1;
  }

  /// The context, created on first need with its graph (source nodes
  /// connect to [_gain]). Created suspended outside a user gesture.
  web.AudioContext _context() {
    final existing = _ctx;
    if (existing != null) return existing;
    final ctx = web.AudioContext(
      web.AudioContextOptions(latencyHint: 'playback'.toJS),
    );
    final gain = ctx.createGain()..gain.value = _muted ? 0 : 1;
    if (_isIOS) {
      final destination = ctx.createMediaStreamDestination();
      gain.connect(destination);
      final element =
          web.document.createElement('audio') as web.HTMLAudioElement
            ..autoplay = true
            ..setAttribute('playsinline', '')
            ..setAttribute('hidden', '')
            ..srcObject = destination.stream;
      element.addEventListener(
        'pause',
        ((web.Event _) {
          if (identical(element, _element)) _beginInterruption();
        }).toJS,
      );
      element.addEventListener(
        'playing',
        ((web.Event _) {
          if (identical(element, _element)) _maybeEndInterruption();
        }).toJS,
      );
      web.document.body?.append(element);
      _element = element;
    } else {
      gain.connect(ctx.destination);
    }
    ctx.onstatechange = ((web.Event _) => _onStateChange(ctx)).toJS;
    _ctx = ctx;
    _gain = gain;
    _resetTimestamps();
    _contextWasRunning = false;
    return ctx;
  }

  /// Creates the context if needed and asks it (and the iOS element) to
  /// run. Synchronous on purpose: called first thing in a method call, so
  /// the `resume()`/`play()` happen inside the page's user gesture.
  web.AudioContext _unlock() {
    final ctx = _context();
    final state = ctx.state;
    if (state == 'suspended' || state == 'interrupted') {
      unawaited(ctx.resume().toDart.then((_) {}, onError: (Object _) {}));
    }
    final element = _element;
    if (element != null && element.paused) {
      _elementPlay = element.play().toDart.then(
        (_) => true,
        onError: (Object _) => false,
      );
    }
    return ctx;
  }

  /// Unlocks and waits up to 1 s for the context to run (and the iOS
  /// element to play), then settles the clock mapping. False = the browser
  /// will not play right now.
  Future<bool> _ensureRunning() async {
    final ctx = _unlock();
    final deadline = _perfNowMs() + 1000;
    while (ctx.state != 'running') {
      if (ctx.state == 'closed' || _perfNowMs() > deadline) return false;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final element = _element;
    if (element != null && element.paused) {
      final playing = await (_elementPlay ?? Future<bool>.value(false)).timeout(
        const Duration(seconds: 1),
        onTimeout: () => false,
      );
      if (!playing || element.paused) return false;
    }
    await _awaitTimestamp(ctx);
    return identical(ctx, _ctx) && ctx.state == 'running';
  }

  void _onStateChange(web.AudioContext ctx) {
    if (!identical(ctx, _ctx)) return; // A disposed context closing.
    switch (ctx.state) {
      case 'running':
        _contextWasRunning = true;
        _maybeEndInterruption();
      case 'suspended' || 'interrupted':
        // The initial suspended → running is no interruption.
        if (_contextWasRunning) _beginInterruption();
      case 'closed':
        final hadSchedule = _state == _State.playing;
        _stopOutput();
        _dropContext();
        if (_state == _State.playing || _state == _State.paused) {
          _state = _buffer != null ? _State.loaded : _State.idle;
        }
        _setMediaSessionState('none');
        if (hadSchedule) {
          _emit('playbackError', {
            'code': 'context_closed',
            'message': 'the browser closed the AudioContext',
          });
        }
    }
  }

  /// The browser took the audio away (Safari `interrupted`/`suspended`, iOS
  /// element paused by the system): stop output, which stays stopped until
  /// the next `playAt`, and report it once per interruption.
  void _beginInterruption() {
    if (_state == _State.playing) {
      _stopOutput();
      _state = _State.loaded;
      _setMediaSessionState('paused');
    }
    if (_interrupted) return;
    _interrupted = true;
    _emit('interruptionBegan');
  }

  /// Ends a reported interruption once the context runs and, on iOS, the
  /// element plays again. Never resumes anything by itself.
  void _maybeEndInterruption() {
    final ctx = _ctx;
    if (!_interrupted || ctx == null || ctx.state != 'running') return;
    final element = _element;
    if (element != null && element.paused) return;
    _interrupted = false;
    _emit('interruptionEnded');
  }

  void _dropContext() {
    final element = _element;
    if (element != null) {
      _element = null;
      element.pause();
      element.srcObject = null;
      element.remove();
    }
    _elementPlay = null;
    _ctx = null;
    _gain = null;
    _resetTimestamps();
    _contextWasRunning = false;
  }

  void _resetTimestamps() {
    _tsOffsetSec = null;
    _tsCandidateSec = null;
    _tsLastContextTime = 0;
    _tsAcceptedAtMs = 0;
    _tsWaited = false;
  }

  void _emit(String type, [Map<String, Object?> fields = const {}]) {
    _events.add(<String, Object?>{...fields, 'type': type});
  }

  static void _setMediaSessionState(String state) {
    final navigator = web.window.navigator;
    if (!(navigator as JSObject).has('mediaSession')) return;
    try {
      navigator.mediaSession.playbackState = state;
    } catch (_) {
      // Best effort: the media card must never break playback.
    }
  }

  // ---------------------------------------------------------------------
  // Methods
  // ---------------------------------------------------------------------

  static String? _path(Object? args) {
    if (args is! Map) return null;
    final path = args['path'];
    return path is String && path.isNotEmpty ? path : null;
  }

  /// Fetches and decodes [url] into a buffer (and its duration in µs).
  static Future<(web.AudioBuffer, int)> _fetchAndDecode(
    web.AudioContext ctx,
    String url,
  ) async {
    final web.Response response;
    final JSArrayBuffer bytes;
    try {
      response = await web.window.fetch(url.toJS).toDart;
      if (!response.ok) {
        throw PlatformException(
          code: 'load_failed',
          message: 'Could not fetch $url: HTTP ${response.status}',
        );
      }
      bytes = await response.arrayBuffer().toDart;
    } on PlatformException {
      rethrow;
    } catch (error) {
      throw PlatformException(
        code: 'load_failed',
        message: 'Could not fetch $url: $error',
      );
    }
    if ((_number(bytes, 'byteLength') ?? 0) <= 0) {
      throw PlatformException(code: 'load_failed', message: '$url is empty');
    }
    final web.AudioBuffer buffer;
    try {
      buffer = await ctx.decodeAudioData(bytes).toDart;
    } catch (error) {
      throw PlatformException(
        code: 'unsupported_format',
        message: 'This browser cannot decode $url: $error',
      );
    }
    if (buffer.length <= 0 || !(buffer.sampleRate > 0)) {
      throw PlatformException(
        code: 'load_failed',
        message: '$url contains no audio frames',
      );
    }
    return (buffer, (buffer.length * 1e6 / buffer.sampleRate).round());
  }

  Future<Object?> _load(Object? args) async {
    final path = _path(args);
    if (path == null) {
      throw PlatformException(
        code: 'bad_args',
        message: 'load requires {path: String}',
      );
    }
    // Replace: stop and forget the old buffer first, so a failed load never
    // leaves the previous track playable (and its PCM is released, D7).
    _stopOutput();
    _buffer = null;
    _durationUs = 0;
    _state = _State.idle;
    _setMediaSessionState('paused');
    final (buffer, durationUs) = await _fetchAndDecode(_context(), path);
    _buffer = buffer;
    _durationUs = durationUs;
    _state = _State.loaded;
    return durationUs;
  }

  Future<Object?> _probeDuration(Object? args) async {
    final path = _path(args);
    if (path == null) {
      throw PlatformException(
        code: 'bad_args',
        message: 'probeDuration requires {path: String}',
      );
    }
    try {
      // Decoding needs a context but not a running one: no unlock here.
      return (await _fetchAndDecode(_context(), path)).$2;
    } catch (_) {
      return null; // Unknown, as on native: a file `load` would refuse.
    }
  }

  Future<Object?> _playAt(Object? args) async {
    final buffer = _buffer;
    if (buffer == null) {
      throw PlatformException(code: 'no_file', message: 'playAt before load');
    }
    final map = args is Map ? args : const <Object?, Object?>{};
    final nativeTimeUs = map['nativeTimeUs'];
    final positionUs = map['positionUs'];
    if (nativeTimeUs is! num || positionUs is! num) {
      throw PlatformException(
        code: 'bad_args',
        message: 'playAt requires nativeTimeUs and positionUs',
      );
    }
    final rateArg = map['rate'];
    final rate = rateArg is num ? rateArg.toDouble() : 1.0;
    if (!(rate >= _minRate && rate <= _maxRate)) {
      throw PlatformException(
        code: 'bad_args',
        message: 'playAt rate must be within [1/32, 32]',
      );
    }
    if (nativeTimeUs.toDouble() - _nowUs() > _maxLeadUs) {
      throw PlatformException(
        code: 'bad_args',
        message:
            'playAt nativeTimeUs is more than ${_maxLeadUs ~/ 1000000} s '
            'ahead of the native clock',
      );
    }

    // A new schedule replaces any current one; until it is installed we
    // are not playing, whatever happens next.
    _stopOutput();
    if (_state == _State.playing || _state == _State.paused) {
      _state = _State.loaded;
    }

    if (!await _ensureRunning()) {
      // The browser will not play now (no gesture yet, iOS refused the
      // element, context closing). Native's refused-audio contract: complete
      // without playing and report it on every refused call.
      _interrupted = true;
      _emit('interruptionBegan');
      return null;
    }
    final ctx = _ctx!;
    final gain = _gain!;

    // Map the anchor into context time. A late anchor (§5.3 late join) is
    // moved to the earliest exact start with the media advanced to match.
    final timestamps = _tsOffsetSec != null;
    final latencyMs = timestamps ? _latencySec(ctx) * 1000 : 0.0;
    var when = _ctxTimeAt(
      ctx,
      nativeTimeUs / 1000,
      latencyMs,
      timestamps: timestamps,
    );
    var startSec = positionUs / 1e6;
    final earliest = ctx.currentTime + _minLeadSec;
    if (!(when >= earliest)) {
      startSec += (earliest - when) * rate;
      when = earliest;
    }
    if (!startSec.isFinite || startSec < 0 || startSec >= buffer.duration) {
      throw PlatformException(
        code: 'bad_position',
        message:
            'start position ${(startSec * 1e6).round()}us is outside the '
            'file (duration ${_durationUs}us)',
      );
    }

    final source = ctx.createBufferSource()..buffer = buffer;
    source.playbackRate.value = rate;
    source.connect(gain);
    final generation = ++_generation;
    source.onended = ((web.Event _) => _onEnded(generation)).toJS;
    source.start(when, startSec);
    _source = source;
    _segments = [_Segment(when, startSec, rate)];
    _scheduleLatencyMs = latencyMs;
    _scheduleUsesTimestamps = timestamps;
    _state = _State.playing;
    _setMediaSessionState('playing');
    return null;
  }

  void _onEnded(int generation) {
    if (generation != _generation || _state != _State.playing) return;
    _source = null;
    _segments = const [];
    _state = _State.finished;
    _setMediaSessionState('paused');
    _emit('playbackFinished');
  }

  /// Silences and drops the current node (if any) without a finish event.
  void _stopOutput() {
    _generation++;
    _segments = const [];
    final source = _source;
    if (source == null) return;
    _source = null;
    source.onended = null;
    try {
      source.stop();
    } catch (_) {
      // Never started or already stopped: nothing is playing either way.
    }
    source.disconnect();
  }

  Object? _pause() {
    if (_state == _State.playing) {
      _stopOutput();
      _state = _State.paused;
      _setMediaSessionState('paused');
    }
    return null;
  }

  Object? _stop() {
    _stopOutput();
    _state = _buffer != null ? _State.loaded : _State.idle;
    _setMediaSessionState('paused');
    return null;
  }

  /// The media position of the frame due now (µs, clamped to the file),
  /// read from the context clock each call — so a sound card running fast
  /// or slow against `performance.now()` shows up as drift (§5.4). Before a
  /// scheduled start it reads 0, as on native.
  Object? _positionUs() {
    final ctx = _ctx;
    if (_state != _State.playing || ctx == null || _segments.isEmpty) {
      return null;
    }
    final now = _ctxTimeAt(
      ctx,
      _perfNowMs(),
      _scheduleLatencyMs,
      timestamps: _scheduleUsesTimestamps,
    );
    final segment = _segments.lastWhere(
      (s) => s.ctxTime <= now,
      orElse: () => _segments.first,
    );
    final us = (segment.mediaAt(now) * 1e6).round();
    return math.min(math.max(us, 0), _durationUs);
  }

  Object? _setRate(Object? args) {
    final rate = args is Map ? args['rate'] : null;
    if (rate is! num || !(rate >= _minRate && rate <= _maxRate)) {
      throw PlatformException(
        code: 'bad_args',
        message: 'setRate requires {rate: double within [1/32, 32]}',
      );
    }
    final ctx = _ctx;
    final source = _source;
    if (_state != _State.playing || ctx == null || source == null) {
      return null; // Nothing live; the next playAt carries its own rate.
    }
    // The change is scheduled just ahead of the render clock (or at the
    // start, if that is later), where the audio thread has not been yet, so
    // it lands exactly there; the timeline gets a new piece from that
    // instant and positions stay continuous without re-anchoring. (A change
    // "now" would land up to a callback after the stale main-thread
    // `currentTime`, misplacing the piece.)
    final last = _segments.last;
    final at = math.max(ctx.currentTime + _minLeadSec, last.ctxTime);
    source.playbackRate.setValueAtTime(rate.toDouble(), at);
    _segments = [
      // [positionUs] reads "now", which trails the render clock by up to
      // the output latency: keep recent pieces (16 is ample for slews).
      ..._segments.skip(_segments.length < 16 ? 0 : 1),
      _Segment(at, last.mediaAt(at), rate.toDouble()),
    ];
    return null;
  }

  Object? _setMuted(Object? args) {
    final muted = args is Map ? args['muted'] : null;
    if (muted is! bool) {
      throw PlatformException(
        code: 'bad_args',
        message: 'setMuted requires {muted: bool}',
      );
    }
    _muted = muted;
    final ctx = _ctx;
    final gain = _gain;
    if (ctx != null && gain != null) {
      // A 10 ms glide instead of a step: no click.
      gain.gain.setTargetAtTime(muted ? 0 : 1, ctx.currentTime, 0.01);
    }
    return null;
  }

  Object? _dispose() {
    _stopOutput();
    _buffer = null;
    _durationUs = 0;
    _state = _State.idle;
    _interrupted = false;
    final ctx = _ctx;
    _dropContext();
    if (ctx != null) {
      unawaited(ctx.close().toDart.then((_) {}, onError: (Object _) {}));
    }
    _setMediaSessionState('none');
    return null;
  }
}
