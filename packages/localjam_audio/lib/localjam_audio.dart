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

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';

/// Offset between Dart's monotonic clock and the native audio clock:
/// `nativeUs = dartLocalUs + offsetUs`.
class NativeClockCalibration {
  const NativeClockCalibration({required this.offsetUs, required this.rttUs});

  final int offsetUs;

  /// Round-trip of the winning (minimum-RTT) sample; a quality indicator.
  final int rttUs;
}

/// What a [LocaljamAudioEvent] reports.
enum LocaljamAudioEventKind {
  /// The audio output route changed (headphones unplugged, Bluetooth
  /// connected). [LocaljamAudioEvent.outputLatencyUs] carries the NEW
  /// route's platform-reported output latency (§7).
  routeChanged,

  /// The OS interrupted playback (phone call, Siri, another app took the
  /// session). Playback is ducked/stopped until [interruptionEnded].
  interruptionBegan,

  /// The OS interruption ended; the client should re-schedule from the
  /// authoritative anchor.
  interruptionEnded,

  /// The native engine was restarted after a configuration change; any
  /// schedule it held is gone and the client should re-schedule.
  engineRestarted,

  /// The scheduled segment played through to the end of the file.
  playbackFinished,
}

/// One event from the native audio engine (event channel
/// `localjam_audio/events`).
class LocaljamAudioEvent {
  const LocaljamAudioEvent({required this.kind, this.outputLatencyUs});

  final LocaljamAudioEventKind kind;

  /// The current route's output latency (µs), when the event carries one
  /// (today: [LocaljamAudioEventKind.routeChanged]).
  final int? outputLatencyUs;

  @override
  String toString() =>
      'LocaljamAudioEvent(${kind.name}'
      '${outputLatencyUs == null ? '' : ', outputLatencyUs: $outputLatencyUs'})';
}

/// Scheduled audio player backed by the platform's audio engine
/// (AVAudioEngine on iOS/macOS, ExoPlayer/Oboe on Android).
///
/// One instance = one loaded file at a time. All times are int microseconds.
class LocaljamAudio {
  LocaljamAudio({
    @visibleForTesting MethodChannel? channel,
    @visibleForTesting Stream<Object?>? rawEvents,
  })  : _ch = channel ?? const MethodChannel('localjam_audio'),
        _injectedRawEvents = rawEvents;

  final MethodChannel _ch;

  static const EventChannel _eventChannel =
      EventChannel('localjam_audio/events');

  /// Test injection point for the raw (undecoded) native event stream.
  final Stream<Object?>? _injectedRawEvents;

  Stream<LocaljamAudioEvent>? _events;

  /// Playback-interruption events from the native engine: route changes,
  /// OS interruptions, engine restarts, end-of-file (see
  /// [LocaljamAudioEventKind]).
  ///
  /// Broadcast; the native side is subscribed lazily on first listen.
  /// Unknown event types are ignored, so old Dart keeps working against a
  /// newer native side.
  Stream<LocaljamAudioEvent> get events => _events ??=
      (_injectedRawEvents ?? _eventChannel.receiveBroadcastStream())
          .map(_decodeEvent)
          .where((event) => event != null)
          .cast<LocaljamAudioEvent>();

  static const Map<String, LocaljamAudioEventKind> _eventKindsByType = {
    'routeChanged': LocaljamAudioEventKind.routeChanged,
    'interruptionBegan': LocaljamAudioEventKind.interruptionBegan,
    'interruptionEnded': LocaljamAudioEventKind.interruptionEnded,
    'engineRestarted': LocaljamAudioEventKind.engineRestarted,
    'playbackFinished': LocaljamAudioEventKind.playbackFinished,
  };

  /// Decodes one native event map; null for anything unrecognized.
  static LocaljamAudioEvent? _decodeEvent(Object? raw) {
    if (raw is! Map) return null;
    final kind = _eventKindsByType[raw['type']];
    if (kind == null) return null;
    final latency = raw['outputLatencyUs'];
    return LocaljamAudioEvent(
      kind: kind,
      outputLatencyUs: latency is int ? latency : null,
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
    var bestRtt = 1 << 62;
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
  /// Replaces any previously loaded file (stops playback first).
  Future<int> load(String filePath) async =>
      (await _ch.invokeMethod<int>('load', {'path': filePath}))!;

  /// Schedules playback of the loaded file to be at media position
  /// [positionUs] exactly when the native clock reads [nativeTimeUs],
  /// playing at [rate].
  ///
  /// If [nativeTimeUs] is already in the past, starts immediately at the
  /// correspondingly advanced position (late join, §5.3).
  Future<void> playAt({
    required int nativeTimeUs,
    required int positionUs,
    double rate = 1.0,
  }) =>
      _ch.invokeMethod<void>('playAt', {
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
  Future<int?> positionUs() => _ch.invokeMethod<int>('positionUs');

  /// Adjusts playback rate without re-anchoring (drift slew, §5.4).
  /// Implementations must keep pitch unaffected for small changes
  /// (|rate - 1| <= 0.01) if the platform allows.
  Future<void> setRate(double rate) =>
      _ch.invokeMethod<void>('setRate', {'rate': rate});

  /// The platform-reported output latency (µs) of the current route
  /// (§7 calibration starting point). 0 when unknown.
  Future<int> outputLatencyUs() async =>
      (await _ch.invokeMethod<int>('outputLatencyUs')) ?? 0;

  /// Releases the native engine.
  Future<void> dispose() => _ch.invokeMethod<void>('dispose');
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
    this.artworkBytes,
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

  /// Encoded image bytes (any format the platform decodes); null = no art.
  final Uint8List? artworkBytes;

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
        'artworkBytes': artworkBytes,
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
  static const MethodChannel channel =
      MethodChannel('localjam_audio/media_session');

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
