/// Sample-accurate scheduled audio playback for LocalJam clients.
///
/// The whole point of this plugin is ONE capability ordinary audio players
/// lack: **start playback of a local file at an exact future instant of the
/// platform's monotonic clock** (PROTOCOL.md §5.3), plus precise position
/// readback and micro rate adjustment for drift correction (§5.4).
///
/// Clock domains: the native side runs on its own monotonic clock
/// ("native time", µs). [calibrate] measures the offset between Dart's
/// monotonic clock (the one `localjam_net` uses for session-clock mapping)
/// and native time with a min-RTT burst over the method channel, so callers
/// can convert session time → Dart-local time → native time.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform, visibleForTesting;
import 'package:flutter/services.dart';

/// Offset between Dart's monotonic clock and the native audio clock:
/// `nativeUs = dartLocalUs + offsetUs`.
class NativeClockCalibration {
  const NativeClockCalibration({required this.offsetUs, required this.rttUs});

  final int offsetUs;

  /// Round-trip of the winning (minimum-RTT) sample; a quality indicator.
  final int rttUs;
}

/// One [LocaljamAudio.positionSample]: the heard position and, where the
/// platform reports it, the native-clock instant it was computed for.
class LocaljamPositionSample {
  const LocaljamPositionSample({required this.positionUs, this.nativeTimeUs});

  /// The heard media position (µs), as [LocaljamAudio.positionUs].
  final int positionUs;

  /// The native-clock instant (µs, [LocaljamAudio.nativeNowUs]'s clock)
  /// [positionUs] was computed for. Null when the platform answers a bare
  /// position (iOS, macOS, desktop, web today): the caller can only take it
  /// as "about now".
  final int? nativeTimeUs;

  @override
  String toString() =>
      'LocaljamPositionSample($positionUs'
      '${nativeTimeUs == null ? '' : ' @ $nativeTimeUs'})';
}

/// What a [LocaljamAudioEvent] reports.
enum LocaljamAudioEventKind {
  /// The audio output route changed (headphones plugged/unplugged, Bluetooth
  /// connected/disconnected, default output device switched).
  ///
  /// [LocaljamAudioEvent.outputLatencyUs] carries the NEW route's
  /// platform-reported output latency (§7) when the platform knows it (null →
  /// re-query [LocaljamAudio.outputLatencyUs]); [LocaljamAudioEvent.routeId]
  /// identifies the new route.
  ///
  /// When [LocaljamAudioEvent.oldDeviceUnavailable] is true the previous
  /// output went away (headphones unplugged, Bluetooth gone, Android
  /// "becoming noisy", a desktop output device removed or dead): the native
  /// side has ALREADY stopped its output, so audio never jumps to the
  /// speaker, and it will not restart by itself. That holds whichever order
  /// the OS reports the unplug and the engine reconfiguration it causes in:
  /// no [engineRestarted] is emitted for a schedule lost that way.
  /// Otherwise playback continues on the new route.
  ///
  /// Android also re-emits it (with `oldDeviceUnavailable`) for a
  /// [LocaljamAudio.playAt] held back within ~2 s of an unplug, while the
  /// reroute to the speaker is still pending: that `playAt` completes
  /// normally without playing.
  routeChanged,

  /// The OS interrupted playback (phone call, Siri, another app took the
  /// session / audio focus). The native side has stopped its output; it
  /// stays stopped until the next [LocaljamAudio.playAt].
  ///
  /// Also emitted by EVERY [LocaljamAudio.playAt] the OS refuses to let play
  /// (iOS: session activation refused; Android: audio focus refused or a
  /// call owns the audio path) — one event per refused call, not per
  /// interruption, so a client that retries learns again that nothing
  /// plays. That `playAt` completes normally without playing. Such a refusal
  /// may never be followed by [interruptionEnded]. macOS and desktop never
  /// refuse.
  ///
  /// [LocaljamAudioEvent.shouldResume] `false` here means the interruption
  /// is permanent — Android's permanent audio-focus loss (the user started
  /// another player): no [interruptionEnded] will follow, and only a
  /// [LocaljamAudio.playAt] (which asks for the audio back) ends it. It can
  /// arrive while an interruption is already in progress, turning it
  /// permanent. Absent (null) otherwise.
  interruptionBegan,

  /// The OS interruption ended. Native NEVER resumes by itself — the room
  /// timeline moved on — so the client re-anchors with
  /// [LocaljamAudio.playAt] if it wants sound again.
  /// [LocaljamAudioEvent.shouldResume] is the OS's hint whether resuming is
  /// appropriate (false e.g. when another app now owns the audio).
  interruptionEnded,

  /// The native engine was restarted after a configuration change and a
  /// schedule it held (playing or paused) is gone; the client should
  /// re-schedule. Not emitted when nothing was scheduled, nor when the
  /// change turned out to be a lost output (see [routeChanged]; iOS/macOS
  /// hold this event ~200 ms to tell the two apart).
  engineRestarted,

  /// The scheduled segment played through to the end of the file.
  playbackFinished,

  /// An unrecoverable failure off the method-call path (decoder or writer
  /// thread died, engine could not restart). Output is stopped;
  /// [LocaljamAudioEvent.code] / [LocaljamAudioEvent.message] say why. The
  /// next [LocaljamAudio.playAt] starts from scratch. (A lost output device
  /// is not an error: it is [routeChanged] with `oldDeviceUnavailable`.)
  playbackError,
}

/// One event from the native audio engine (event channel
/// `localjam_audio/events`).
///
/// Wire payload: a map with `type` (the [LocaljamAudioEventKind] name) plus
/// the optional keys `outputLatencyUs` (int), `routeId` (String),
/// `oldDeviceUnavailable` (bool), `shouldResume` (bool), `code` (String),
/// `message` (String). Missing or mistyped keys decode to the defaults below.
class LocaljamAudioEvent {
  const LocaljamAudioEvent({
    required this.kind,
    this.outputLatencyUs,
    this.routeId,
    this.oldDeviceUnavailable = false,
    this.shouldResume,
    this.code,
    this.message,
  });

  final LocaljamAudioEventKind kind;

  /// The current route's output latency (µs), when the event carries one
  /// (today: [LocaljamAudioEventKind.routeChanged] on iOS/Android/desktop).
  final int? outputLatencyUs;

  /// [LocaljamAudioEventKind.routeChanged]: opaque, stable id of the NEW
  /// output route — same as [LocaljamAudio.currentRouteId] would return.
  /// Null when the platform cannot tell.
  final String? routeId;

  /// [LocaljamAudioEventKind.routeChanged]: the previous output device went
  /// away and native output has been stopped (see the kind's docs).
  final bool oldDeviceUnavailable;

  /// [LocaljamAudioEventKind.interruptionEnded]: the OS's hint that resuming
  /// is appropriate. Null when the platform did not say.
  ///
  /// [LocaljamAudioEventKind.interruptionBegan]: `false` when the
  /// interruption is permanent (Android's permanent focus loss) and no
  /// `interruptionEnded` will follow; null otherwise.
  final bool? shouldResume;

  /// [LocaljamAudioEventKind.playbackError]: stable machine-readable reason
  /// (today `engine_start_failed` on iOS/macOS, `decode_failed` on Android
  /// and desktop, `writer_failed` on Android; an open set — treat unknown
  /// codes generically; no platform sends `device_lost`). Always non-null
  /// for that kind (`unknown` if the native side sent none).
  final String? code;

  /// [LocaljamAudioEventKind.playbackError]: human-readable detail, for logs.
  final String? message;

  @override
  String toString() {
    final fields = <String>[
      kind.name,
      if (outputLatencyUs != null) 'outputLatencyUs: $outputLatencyUs',
      if (routeId != null) 'routeId: $routeId',
      if (oldDeviceUnavailable) 'oldDeviceUnavailable: true',
      if (shouldResume != null) 'shouldResume: $shouldResume',
      if (code != null) 'code: $code',
      if (message != null) 'message: $message',
    ];
    return 'LocaljamAudioEvent(${fields.join(', ')})';
  }
}

/// Scheduled audio player backed by the platform's audio engine
/// (AVAudioEngine on iOS/macOS, AudioTrack + MediaCodec on Android, a shared
/// miniaudio core on Windows/Linux).
///
/// One instance = one loaded file at a time. All times are int microseconds.
class LocaljamAudio {
  LocaljamAudio({
    @visibleForTesting MethodChannel? channel,
    @visibleForTesting Stream<Object?>? rawEvents,
  }) : _ch = channel ?? const MethodChannel('localjam_audio'),
       _injectedRawEvents = rawEvents;

  final MethodChannel _ch;

  static const EventChannel _eventChannel = EventChannel(
    'localjam_audio/events',
  );

  /// Test injection point for the raw (undecoded) native event stream.
  final Stream<Object?>? _injectedRawEvents;

  Stream<LocaljamAudioEvent>? _events;

  /// Playback-interruption events from the native engine: route changes,
  /// OS interruptions, engine restarts, end-of-file, unrecoverable errors
  /// (see [LocaljamAudioEventKind]).
  ///
  /// Broadcast; the native side is subscribed lazily on first listen.
  /// Unknown event types are ignored, so old Dart keeps working against a
  /// newer native side.
  Stream<LocaljamAudioEvent> get events =>
      _events ??= (_injectedRawEvents ?? _eventChannel.receiveBroadcastStream())
          .map(_decodeEvent)
          .where((event) => event != null)
          .cast<LocaljamAudioEvent>();

  static const Map<String, LocaljamAudioEventKind> _eventKindsByType = {
    'routeChanged': LocaljamAudioEventKind.routeChanged,
    'interruptionBegan': LocaljamAudioEventKind.interruptionBegan,
    'interruptionEnded': LocaljamAudioEventKind.interruptionEnded,
    'engineRestarted': LocaljamAudioEventKind.engineRestarted,
    'playbackFinished': LocaljamAudioEventKind.playbackFinished,
    'playbackError': LocaljamAudioEventKind.playbackError,
  };

  /// Decodes one native event map; null for anything unrecognized. Tolerant
  /// by design: unknown types are dropped, unknown keys ignored, and a key
  /// that is missing or of the wrong type decodes to its default — so an
  /// older or newer native side never breaks this decoder.
  static LocaljamAudioEvent? _decodeEvent(Object? raw) {
    if (raw is! Map) return null;
    final kind = _eventKindsByType[raw['type']];
    if (kind == null) return null;
    T? typed<T>(String key) {
      final value = raw[key];
      return value is T ? value : null;
    }

    return LocaljamAudioEvent(
      kind: kind,
      outputLatencyUs: typed<int>('outputLatencyUs'),
      routeId: typed<String>('routeId'),
      oldDeviceUnavailable: typed<bool>('oldDeviceUnavailable') ?? false,
      shouldResume: typed<bool>('shouldResume'),
      code:
          typed<String>('code') ??
          (kind == LocaljamAudioEventKind.playbackError ? 'unknown' : null),
      message: typed<String>('message'),
    );
  }

  /// Current native monotonic time (µs). Cheap; used by [calibrate].
  Future<int> nativeNowUs() async => (await _ch.invokeMethod<int>('nowUs'))!;

  /// Measures Dart-monotonic ↔ native-clock offset with [samples] round trips,
  /// keeping the minimum-RTT sample: offset = nativeNow - (t0+t3)/2.
  /// Callers supply [dartNowUs] (e.g. `monotonicNowUs` from localjam_net) so
  /// the Dart side of the measurement shares the caller's timebase.
  Future<NativeClockCalibration> calibrate(
    int Function() dartNowUs, {
    int samples = 10,
  }) async {
    // 2^53 − 1, not `1 << 62`: compiled to JS that shift is 0, no sample
    // would ever win and the web offset would read 0.
    var bestRtt = 0x1FFFFFFFFFFFFF;
    var bestOffset = 0;
    for (var i = 0; i < samples; i++) {
      final t0 = dartNowUs();
      final native = await nativeNowUs();
      final t3 = dartNowUs();
      final rtt = t3 - t0;
      if (rtt < bestRtt) {
        bestRtt = rtt;
        bestOffset = native - (t0 + (rtt ~/ 2));
      }
    }
    return NativeClockCalibration(offsetUs: bestOffset, rttUs: bestRtt);
  }

  /// Loads a local audio file; returns its duration in µs.
  /// Replaces any previously loaded file (stops playback first). If the new
  /// file fails to load, nothing is loaded afterwards.
  ///
  /// Throws `PlatformException(load_failed)` for an unreadable file and for
  /// one whose header is outside what any recording has — a sample rate
  /// outside 4–384 kHz, no frames, or more than 2^37 frames (files are
  /// untrusted: peers upload them) — the same limits on every platform;
  /// `unsupported_format` on desktop for containers it cannot decode (m4a…).
  Future<int> load(String filePath) async =>
      (await _ch.invokeMethod<int>('load', {'path': filePath}))!;

  /// Duration (µs) of the audio file at [filePath] — the same value [load]
  /// would return — read from its headers/metadata without loading it. Null
  /// when unknown: unreadable, or a file [load] would refuse.
  ///
  /// Does not touch the playback engine, the loaded file, the play state or
  /// the audio session, so it is safe while playing and concurrently. Runs
  /// off the platform's UI thread (header parsing can be O(file) for mp3).
  ///
  /// Web: the browser has no header-only probe, so this decodes the whole
  /// file. Null there means only "bytes [load] would refuse"; a probe that
  /// could not tell (fetch failed, the decode failed for a reason that is
  /// not the format) throws `PlatformException` (`load_failed`,
  /// `engine_error`) instead, so a caller can retry. [keepForLoad] keeps
  /// the decoded buffer for a following [load] of the same URL, which then
  /// does not decode again (one buffer kept at most; native ignores it).
  Future<int?> probeDurationUs(
    String filePath, {
    bool keepForLoad = false,
  }) async {
    try {
      return await _ch.invokeMethod<int>('probeDuration', {
        'path': filePath,
        if (keepForLoad) 'keep': true,
      });
    } on MissingPluginException {
      return null; // A native side without the method: duration unknown.
    }
  }

  /// Opaque, stable id of the current audio output route: the same
  /// headphones give the same id across sessions, a different device a
  /// different id. Use it to key per-route state such as §7 output-latency
  /// calibration. Null when the platform cannot tell. Only equality is
  /// meaningful (desktop: `<backend>:<hash>` of the default output device).
  Future<String?> currentRouteId() async {
    try {
      return await _ch.invokeMethod<String>('currentRouteId');
    } on MissingPluginException {
      return null;
    }
  }

  /// Schedules playback of the loaded file to be at media position
  /// [positionUs] exactly when the native clock reads [nativeTimeUs],
  /// playing at [rate].
  ///
  /// If [nativeTimeUs] is already in the past, starts immediately at the
  /// correspondingly advanced position (late join, §5.3).
  ///
  /// If the OS will not let the app play right now (iOS/Android, e.g. a
  /// phone call holds the audio), this completes normally WITHOUT playing
  /// and the native side emits [LocaljamAudioEventKind.interruptionBegan] —
  /// on every refused call. Android likewise holds back a call made within
  /// ~2 s of an unplug and re-emits
  /// [LocaljamAudioEventKind.routeChanged] with `oldDeviceUnavailable`.
  ///
  /// [rate] must lie in [1/32, 32] and [nativeTimeUs] at most one hour ahead
  /// of the native clock; otherwise a `PlatformException(bad_args)`. Android
  /// may also answer `bad_args` for an in-range rate its output cannot
  /// time-stretch to (API 36 emulator: 0.1–4 plays, ≤ 1/16 and ≥ 8 do not).
  /// A start outside the file is `PlatformException(bad_position)`; before
  /// [load], `no_file`.
  ///
  /// Engine failures (`PlatformException.code`, nothing scheduled; a later
  /// `playAt` retries from scratch):
  ///  * `engine_start_failed` — the audio engine / output device could not
  ///    be started (all platforms).
  ///  * `engine_not_running` (iOS/macOS) — the engine started but produced
  ///    no render cycle within 1 s, or stopped (route change) before the
  ///    schedule could be installed.
  ///  * `engine_error` (iOS/macOS) — AVFoundation raised while scheduling or
  ///    the graph could not be rebuilt; the engine is rebuilt on the next
  ///    call.
  ///  * `internal` (desktop) — out of memory / threads.
  Future<void> playAt({
    required int nativeTimeUs,
    required int positionUs,
    double rate = 1.0,
  }) => _ch.invokeMethod<void>('playAt', {
    'nativeTimeUs': nativeTimeUs,
    'positionUs': positionUs,
    'rate': rate,
  });

  /// Pauses playback, keeping the loaded file.
  Future<void> pause() => _ch.invokeMethod<void>('pause');

  /// Stops and discards playback state (file stays loaded).
  Future<void> stop() => _ch.invokeMethod<void>('stop');

  /// Current playback position (µs), derived from the engine's sample time —
  /// NOT a cached value. Null when nothing is playing or scheduled.
  ///
  /// It is the position being HEARD now (the frame leaving the speaker), not
  /// the frame being rendered or due now, which is heard [outputLatencyUs]
  /// later. Callers schedule [playAt] anchors shifted [outputLatencyUs]
  /// early so they are heard on time (§7), so a drift check against the
  /// anchor reads 0 when the schedule, shifted by `outputLatencyUs`, landed
  /// on time; a due-now position would read the whole latency as drift.
  /// Android reads presented frames (`AudioTimestamp`); web maps through the
  /// output timestamp with no latency shift; iOS/macOS query the player's
  /// node-time mapping at now − [outputLatencyUs] (as read at [playAt]).
  Future<int?> positionUs() => _ch.invokeMethod<int>('positionUs');

  /// [positionUs] together with the native instant it was computed for, so
  /// a drift check can compare it with where the room was at THAT instant
  /// rather than when the reply arrived — a busy platform thread delays the
  /// reply by milliseconds (more under load), which a bare position reads
  /// as the player running behind. Null when nothing is playing or
  /// scheduled.
  ///
  /// Channel: `positionUs {withTime: true}`. Android answers
  /// `{positionUs, nativeTimeUs}`; platforms that ignore the argument answer
  /// a bare position, which comes back with a null
  /// [LocaljamPositionSample.nativeTimeUs].
  Future<LocaljamPositionSample?> positionSample() async {
    final raw = await _ch.invokeMethod<Object?>('positionUs', {
      'withTime': true,
    });
    if (raw is int) return LocaljamPositionSample(positionUs: raw);
    if (raw is Map) {
      final positionUs = raw['positionUs'];
      final nativeTimeUs = raw['nativeTimeUs'];
      if (positionUs is int) {
        return LocaljamPositionSample(
          positionUs: positionUs,
          nativeTimeUs: nativeTimeUs is int ? nativeTimeUs : null,
        );
      }
    }
    return null;
  }

  /// Adjusts playback rate without re-anchoring (drift slew, §5.4).
  /// Implementations must keep pitch unaffected for small changes
  /// (|rate - 1| <= 0.01) if the platform allows. [rate] must lie in
  /// [1/32, 32] (`PlatformException(bad_args)` otherwise). Android keeps
  /// the previous rate when the playing track cannot play [rate] and says
  /// so — never success: `bad_args` when its output cannot play that rate
  /// at all (see [playAt]), `rate_needs_reanchor` when only this track
  /// cannot (a low-latency track has no time-stretcher; the next [playAt]
  /// uses a track that has). [positionUs] stays true either way; re-anchor
  /// with [playAt] to correct instead.
  Future<void> setRate(double rate) =>
      _ch.invokeMethod<void>('setRate', {'rate': rate});

  /// How long after a [playAt] anchor's `nativeTimeUs` its frame is HEARD
  /// on the current route (µs): what callers subtract from anchors (§7).
  /// iOS/macOS/web schedule the frame due at `nativeTimeUs` and report the
  /// route's output latency; Android schedules the frame presented at
  /// `nativeTimeUs` (AudioTimestamp includes the pipeline latency) and so
  /// always reports 0 — its device-claimed latency is diagnostic only
  /// ([debugLatencyInfo]). 0 when unknown.
  Future<int> outputLatencyUs() async =>
      (await _ch.invokeMethod<int>('outputLatencyUs')) ?? 0;

  /// Releases the native engine. Web: releases the buffer and the node but
  /// keeps the page's gesture-unlocked `AudioContext` for the next engine.
  Future<void> dispose() => _ch.invokeMethod<void>('dispose');

  /// iOS/macOS debug builds only (a test hook, absent from release builds):
  /// replaces the latency the plugin reports from [outputLatencyUs] and maps
  /// [positionUs]'s heard instant with, so a test can pin the latency
  /// contract whatever the machine's output device reports. Null restores
  /// the platform's value. The override outlives [dispose]; reset it.
  @visibleForTesting
  Future<void> debugSetOutputLatencyOverrideUs(int? us) =>
      _ch.invokeMethod<void>('debugSetOutputLatencyOverride', {'us': us});

  /// iOS/macOS debug builds only: every latency quantity the platform
  /// reports for the current output (µs and frames), for measurement.
  /// Android (any build): `schedulingLatencyUs` (what [outputLatencyUs]
  /// reports, 0) and `propertyOutputLatencyUs` (the device's hidden
  /// AudioManager latency property, 0 when absent).
  @visibleForTesting
  Future<Map<String, Object?>> debugLatencyInfo() async =>
      (await _ch.invokeMapMethod<String, Object?>('debugLatencyInfo')) ??
      const {};
}

// ---------------------------------------------------------------------------
// Device music library (Android MediaStore; other platforms use pickers)
// ---------------------------------------------------------------------------

/// One track from the device's music library.
class JamLibraryTrack {
  const JamLibraryTrack({
    required this.id,
    required this.title,
    this.artist,
    this.album,
    this.durationMs,
    required this.sizeBytes,
    required this.contentUri,
    this.path,
  });

  /// Platform-stable id (Android: MediaStore id).
  final int id;

  final String title;
  final String? artist;
  final String? album;
  final int? durationMs;
  final int sizeBytes;

  /// Platform content identifier ([resolve] turns it into a readable file).
  final String contentUri;

  /// Direct filesystem path, when the platform exposed a readable one.
  final String? path;

  static JamLibraryTrack? _fromMap(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final contentUri = raw['contentUri'];
    if (id is! int || contentUri is! String) return null;
    return JamLibraryTrack(
      id: id,
      title: (raw['title'] as String?) ?? 'Unknown',
      artist: raw['artist'] as String?,
      album: raw['album'] as String?,
      durationMs: raw['durationMs'] as int?,
      sizeBytes: (raw['sizeBytes'] as int?) ?? 0,
      contentUri: contentUri,
      path: raw['path'] as String?,
    );
  }
}

/// Thrown by [JamMediaLibrary] when the OS audio-library permission has not
/// been granted (Android: `READ_MEDIA_AUDIO` / `READ_EXTERNAL_STORAGE`).
/// The app owns requesting it (e.g. via permission_handler) before querying.
class JamLibraryPermissionException implements Exception {
  const JamLibraryPermissionException();

  @override
  String toString() =>
      'JamLibraryPermissionException: audio library permission not granted';
}

/// The device music library (channel `localjam_audio/library`).
///
/// Implemented on Android (MediaStore). On platforms without an
/// implementation (iOS — where most libraries are DRM'd Apple Music
/// content — and desktop, where folder pickers fit better), [isSupported]
/// is false and [queryAudio] returns an empty list.
class JamMediaLibrary {
  JamMediaLibrary._();

  static const MethodChannel channel = MethodChannel('localjam_audio/library');

  /// Whether this platform implements library queries.
  static bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Every music track the OS indexes, sorted by title. Empty on
  /// unsupported platforms. Throws [JamLibraryPermissionException] when the
  /// permission is missing.
  static Future<List<JamLibraryTrack>> queryAudio() async {
    if (!isSupported) return const [];
    try {
      final raw = await channel.invokeMethod<List<Object?>>('queryAudio');
      return [
        for (final entry in raw ?? const <Object?>[])
          ?JamLibraryTrack._fromMap(entry),
      ];
    } on MissingPluginException {
      return const [];
    } on PlatformException catch (e) {
      if (e.code == 'permission_denied') {
        throw const JamLibraryPermissionException();
      }
      rethrow;
    }
  }

  /// A readable filesystem path for [track] — the direct path when the OS
  /// exposes one, else a cached copy — or null when the content is gone.
  /// LocalJam hosts serve raw files, so this is the bridge from a library
  /// pick to `addMediaFile`.
  static Future<String?> resolve(JamLibraryTrack track) async {
    final direct = track.path;
    if (direct != null && File(direct).existsSync()) return direct;
    if (!isSupported) return null;
    try {
      return await channel.invokeMethod<String>('resolveToPath', {
        'contentUri': track.contentUri,
        'id': track.id,
      });
    } on MissingPluginException {
      return null;
    } on PlatformException catch (e) {
      if (e.code == 'permission_denied') {
        throw const JamLibraryPermissionException();
      }
      rethrow;
    }
  }
}

// ---------------------------------------------------------------------------
// System media session (lock screen / notification / now playing)
// ---------------------------------------------------------------------------

/// A transport command delivered by the OS media session (lock screen,
/// media notification, headset buttons, watch, car).
enum JamRemoteCommand {
  play('play'),
  pause('pause'),
  next('next'),
  previous('previous'),

  /// Carries [JamRemoteCommandEvent.positionUs] (lock-screen seekbar).
  seek('seek');

  const JamRemoteCommand(this.wire);

  final String wire;

  static JamRemoteCommand? fromWire(String? wire) {
    for (final command in values) {
      if (command.wire == wire) return command;
    }
    return null; // Unknown commands from a newer native side are ignored.
  }
}

/// One OS media-session command event.
class JamRemoteCommandEvent {
  const JamRemoteCommandEvent(this.command, {this.positionUs});

  final JamRemoteCommand command;

  /// Target position for [JamRemoteCommand.seek].
  final int? positionUs;

  @override
  String toString() =>
      'JamRemoteCommandEvent(${command.wire}'
      '${positionUs == null ? '' : ', positionUs: $positionUs'})';
}

/// What the OS media session should display and allow right now.
class JamNowPlaying {
  const JamNowPlaying({
    required this.title,
    this.artist,
    this.album,
    this.sessionName,
    this.artworkBytes,
    this.artworkId,
    this.durationUs,
    required this.positionUs,
    this.rate = 1.0,
    required this.playing,
    this.canPlayPause = true,
    this.canNext = true,
    this.canPrevious = true,
    this.canSeek = true,
  });

  final String title;
  final String? artist;
  final String? album;

  /// The room this is playing in. The media card's identity line: platforms
  /// show it as the subtitle when [artist] is unknown, and as a third line
  /// beneath the artist when it is — a jam card should say *which* jam.
  final String? sessionName;

  /// Encoded image bytes (any format the platform decodes); null = no art.
  final Uint8List? artworkBytes;

  /// Content-addressed id of [artworkBytes] (§6.5), so the platform can cache
  /// one decoded bitmap per cover instead of re-decoding on every position
  /// update. Null when the item has no artwork.
  final String? artworkId;

  final int? durationUs;

  /// Position at the moment of this update; the OS interpolates from it
  /// using [rate] while [playing].
  final int positionUs;
  final double rate;
  final bool playing;

  /// Which transport controls to enable — mirrors the sender's §5.6
  /// capabilities so a guest who cannot control playback gets a read-only
  /// media card.
  final bool canPlayPause;
  final bool canNext;
  final bool canPrevious;
  final bool canSeek;

  Map<String, Object?> toMap() => {
    'title': title,
    'artist': artist,
    'album': album,
    'sessionName': sessionName,
    'artworkBytes': artworkBytes,
    'artworkId': artworkId,
    'durationUs': durationUs,
    'positionUs': positionUs,
    'rate': rate,
    'playing': playing,
    'canPlayPause': canPlayPause,
    'canNext': canNext,
    'canPrevious': canPrevious,
    'canSeek': canSeek,
  };
}

/// The OS media-session integration: publishes now-playing state (lock
/// screen, media notification, control center) and receives transport
/// commands from the system.
///
/// Implemented natively on Android (MediaSession + media-style notification
/// hosted by the plugin's session foreground service), iOS, and macOS
/// (MPNowPlayingInfoCenter + MPRemoteCommandCenter). Every call is
/// best-effort and never throws: on platforms without an implementation
/// (Linux/Windows for now, tests, CLI embeddings) it is a no-op.
class JamMediaSession {
  JamMediaSession._();

  /// The bidirectional channel: Dart sends `update`/`clear`; the native side
  /// sends `remoteCommand {command, positionUs?}`.
  static const MethodChannel channel = MethodChannel(
    'localjam_audio/media_session',
  );

  /// Receives OS transport commands. Setting this installs the channel
  /// handler; set null to stop listening.
  static void Function(JamRemoteCommandEvent event)? get onCommand =>
      _onCommand;
  static void Function(JamRemoteCommandEvent event)? _onCommand;
  static set onCommand(void Function(JamRemoteCommandEvent event)? handler) {
    _onCommand = handler;
    channel.setMethodCallHandler(handler == null ? null : _handleCall);
  }

  static Future<Object?> _handleCall(MethodCall call) async {
    if (call.method != 'remoteCommand') return null;
    final args = call.arguments;
    if (args is! Map) return null;
    final command = JamRemoteCommand.fromWire(args['command'] as String?);
    if (command == null) return null;
    _onCommand?.call(
      JamRemoteCommandEvent(command, positionUs: args['positionUs'] as int?),
    );
    return null;
  }

  /// Publishes [nowPlaying] to the OS media session.
  static Future<void> update(JamNowPlaying nowPlaying) =>
      _invoke('update', nowPlaying.toMap());

  /// Clears the media session (session over / nothing selected).
  static Future<void> clear() => _invoke('clear', null);

  static Future<void> _invoke(String method, Object? args) async {
    try {
      await channel.invokeMethod<void>(method, args);
    } on MissingPluginException {
      // No native implementation on this platform: nothing to show.
    } on PlatformException {
      // Best effort: a broken media card must never break playback.
    }
  }
}
