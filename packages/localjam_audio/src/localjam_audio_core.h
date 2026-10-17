/*
 * localjam_audio_core.h — sample-accurate scheduled audio playback for LocalJam
 * (PROTOCOL.md §5.3–§5.4), shared by the Windows and Linux plugin backends.
 *
 * ONE C API, TWO PLATFORM SHELLS
 * -----------------------------
 * The Windows (C++/flutter::MethodChannel) and Linux (GObject/FlMethodChannel)
 * plugins are thin translators: they decode channel arguments, call the
 * functions below, and encode the result. Every piece of scheduling, decoding
 * and position math lives here, in one place that can be compiled and RUN on a
 * developer machine (see src/test/core_test.cpp, which exercises this exact
 * code against a real audio device). The semantic reference for the whole
 * family is the iOS/macOS Swift plugin; the closest structural analogue is the
 * Android Kotlin plugin, whose silence-priming design this file mirrors.
 *
 * The function set is deliberately a 1:1 image of the MethodChannel contract in
 * lib/localjam_audio.dart:
 *
 *   nowUs            -> lj_now_us
 *   load             -> lj_load
 *   playAt           -> lj_play_at
 *   pause            -> lj_pause
 *   stop             -> lj_stop
 *   positionUs       -> lj_position_us
 *   setRate          -> lj_set_rate
 *   outputLatencyUs  -> lj_output_latency_us
 *   probeDuration    -> lj_probe_duration   (no engine involved at all)
 *   currentRouteId   -> lj_current_route_id
 *   dispose          -> lj_destroy
 *   events channel   -> lj_event_cb
 *
 * CLOCK DOMAIN
 * ------------
 * "Native time" is std::chrono::steady_clock in microseconds (lj_now_us). It is
 * THE scheduling timebase: every timestamp in this API — the anchor passed to
 * lj_play_at, the callback timestamps used to build the device clock model, the
 * instants position math extrapolates over — is in that one domain, with no
 * cross-clock translation anywhere. steady_clock is CLOCK_MONOTONIC on Linux and
 * QueryPerformanceCounter on Windows; both are unaffected by wall-clock
 * adjustments, which is what the Dart-side calibrate() assumes.
 *
 * SCHEDULING: SILENCE PRIMING AGAINST THE DEVICE-CALLBACK CLOCK
 * ------------------------------------------------------------
 * miniaudio (like AudioTrack, unlike AVAudioEngine) cannot start "at time T".
 * It can only start ASAP and then ask us for frames. So lj_play_at:
 *
 *   1. Starts an ma_device and streams SILENCE from the data callback.
 *   2. Timestamps every callback with lj_now_us() and records how many output
 *      frames had been handed over before it. Because the device consumes
 *      frames at exactly the device rate, those pairs lie on a line
 *
 *          W(t) = (t - origin) * devRate / 1e6            [frames handed over]
 *
 *      and the frame actually being PRESENTED at the output at time t trails
 *      that line by the device's buffered depth L (see "Output latency"):
 *
 *          presented(t) = W(t) - L
 *
 *   3. Once the mapping is MATURE (see below), the output-frame index that
 *      will be presented exactly at the anchor instant is
 *
 *          S = (targetUs - origin) * devRate / 1e6 - L
 *
 *      S is the total number of silence frames to emit; real PCM starts at
 *      output frame S. S is refined against fresher callbacks while silence
 *      remains, and frozen the moment media starts.
 *
 *   4. If the target has already passed when the mapping matures (S < the
 *      frames already handed over), silence cannot be un-emitted: the media is
 *      TRIMMED instead. mediaSkip = W_firstMedia - S output frames' worth of
 *      source audio is dropped, which preserves the invariant exactly:
 *
 *          output frame S + k always carries media position P + k*rate/devRate
 *
 *      i.e. the session anchor the Dart side passed remains the truth and the
 *      §5.4 drift check converges to zero instead of seeing a constant offset.
 *
 * MATURITY GATE (the Android lesson, restated for a pull-model callback)
 * ---------------------------------------------------------------------
 * Do NOT trust the first callback. Every backend PREFILLS its buffer at start
 * by calling the data callback several times back to back; during that burst
 * frames are handed over with almost no wall time elapsing, so a line fitted
 * through those points has a wildly wrong intercept and would place the first
 * real sample tens of milliseconds off — a constant error drift correction can
 * never remove, because every hard resync re-primes the same way (Android
 * measured -68 ms from the analogous mistake). A callback pair counts only once
 *
 *   - at least LJ_MATURITY_CALLBACKS callbacks have been seen, AND
 *   - at least LJ_MATURITY_SPAN_US of wall time has elapsed since the first, AND
 *   - the implied consumption rate over that span is within 2x of devRate
 *     (i.e. we are past the prefill burst and into real-time consumption).
 *
 * The estimator for `origin` is a running MINIMUM of (t_cb - W*1e6/devRate)
 * over mature callbacks. That direction is not arbitrary: the device asks for
 * frames when it needs them, so scheduling jitter can only make a callback fire
 * LATE, never early; the smallest observed intercept is therefore the closest to
 * the true one. LJ_MIN_LEAD_US of priming yields on the order of ten samples to
 * minimise over, and the observed spread is logged.
 *
 * POSITION MATH
 * -------------
 *     f_now      = (now - origin) * devRate / 1e6 - L        [presented frame]
 *     positionUs = P + (f_now - S) * rate / devRate * 1e6
 *     clamped to [0, durationUs]
 *
 * The ×rate factor is explicit here (unlike Android, where framePosition counts
 * SOURCE frames and rate is already embodied) because f is an OUTPUT-device
 * frame index: one output frame advances media time by rate/devRate seconds,
 * since the resampler consumes rate*srcRate/devRate source frames per output
 * frame. That is the same "consumed source frames at the resample ratio"
 * bookkeeping Android does with its ×rate terms.
 *
 * Before the media starts (f_now < S) the formula extrapolates BELOW P — the
 * same anchor-consistent pre-start behaviour as the iOS player's negative
 * sampleTime. While the mapping is still immature, position falls back to the
 * pure anchor formula P + (now - target) * rate, which is the same line.
 *
 * RATE (§5.4 drift slew)
 * ----------------------
 * Rate is realised as a plain resample: ratio = rate * srcRate / devRate fed to
 * ma_resampler_set_rate_ratio. This SHIFTS PITCH by the ratio — there is no
 * time-stretching here (miniaudio has no pitch-preserving stretcher and pulling
 * one in would dwarf this file). For the ±0.5 % slews §5.4 asks for that is
 * 1200*log2(1.005) ~= 8.6 cents, inaudible in practice; the Dart API's
 * "keep pitch unaffected ... if the platform allows" caveat covers it. Large
 * rates are accepted but will sound like a tape speed change.
 *
 * A live rate change re-anchors (S, P) at the instant of the change — S' is the
 * currently presented frame and P' the current position — so the mapping stays
 * exact across changes with no accumulated error.
 *
 * FORMATS
 * -------
 * wav / flac / mp3 / ogg-vorbis, decoded by the vendored single-file libraries
 * (dr_wav, dr_flac, dr_mp3, stb_vorbis), selected by MAGIC-BYTE SNIFFING first
 * and file extension only as a fallback.
 *
 * m4a / aac / alac are NOT supported on this backend: there is no
 * public-domain single-file AAC decoder to vendor, and shelling out to a system
 * codec (Media Foundation / GStreamer) would put a different decoder on each
 * platform. lj_load returns LJ_ERR_UNSUPPORTED_FORMAT ("unsupported_format")
 * with a message naming the detected container. Callers should transcode to
 * flac/wav/ogg for desktop sessions. (iOS/macOS/Android DO support m4a via
 * their system codecs — this is a desktop-backend limitation, documented in
 * README.md and in the windows/linux plugin sources.)
 *
 * STREAMING DECODE (not full-file-in-RAM)
 * ---------------------------------------
 * lj_load only PROBES: it opens the decoder, reads sample rate, channel count
 * and total frame count, and closes again. No PCM is retained.
 *
 * Each lj_play_at starts its own decoder thread, which seeks to the anchor frame
 * and produces f32 interleaved PCM into a bounded single-producer/single-consumer
 * ring the device callback drains. Ring capacity is
 * min(LJ_RING_SECONDS * srcRate, LJ_RING_MAX_BYTES / bytesPerFrame) frames —
 * ~8 s or 4 MB, whichever is smaller — so peak decoded-audio memory is
 * independent of file length, exactly like the Android design. The producer
 * sleeps when the ring is full (natural backpressure, and the pause state); the
 * consumer NEVER blocks — an underrun emits silence and is counted, because a
 * glitch must not stall the audio thread and does not perturb the frame<->time
 * anchor math.
 *
 * OUTPUT LATENCY (§7)
 * -------------------
 * L = internalPeriodSizeInFrames * internalPeriods, converted to client-rate
 * frames. This is miniaudio's visible buffer depth and the best portable proxy
 * for the handover->presentation delay; lj_output_latency_us reports exactly the
 * value the scheduler used, so a §7 manual nudge composes with it predictably.
 * It cannot see hardware/HAL latency beyond miniaudio's own buffering (nor can
 * any portable API), so a residual CONSTANT per output device remains. That is
 * precisely what §7 calibration and the ±500 ms manual nudge exist for: it is
 * stable across re-schedules and identical for every client on the same
 * hardware, unlike a variable start-up delay, which is why this file never
 * starts playback "ASAP" (see lj_play_at).
 *
 * THREADS
 * -------
 *  - Caller thread: all lj_* calls that take an engine, from ONE control
 *    thread (the plugins' platform thread). Engine state is guarded by a
 *    mutex, but device open/close (inside lj_play_at / lj_load / lj_destroy)
 *    rely on not racing each other. None of them block on audio I/O.
 *    lj_probe_duration and lj_current_route_id touch no engine at all and may
 *    run on any thread, concurrently; both can block on file or audio-server
 *    I/O, so the plugins run them on a worker thread, never the UI thread.
 *  - Device callback (audio thread, owned by miniaudio): drains the ring,
 *    records clock samples. Takes the same mutex, but only ever for a few
 *    microseconds of arithmetic — no allocation, no I/O, no waiting.
 *  - One decoder thread per schedule, generation-tagged exactly like the
 *    Android writer/decoder pair so a superseded thread exits silently.
 *  - One monitor thread for the whole engine: emits playbackFinished when the
 *    last media frame has been presented, logs the measured start error,
 *    follows the output route (see "Routes"), and delivers every event.
 *    Events NEVER fire on the audio thread.
 *
 * ROUTES (output device changes)
 * ------------------------------
 * The device follows the system default output (miniaudio auto-routing). A
 * backend reroutes by STOPPING the stream, re-opening it on the new device and
 * starting it again — so a "stopped" notification is not, by itself, a dead
 * device. The pure state machine lj_internal::RouteWatch
 * (localjam_audio_internal.h) turns the notification sequence plus the polled
 * device state into one verdict per change:
 *   - stopped, then started again within LJ_ROUTE_DEBOUNCE_US, rerouted: the
 *     output moved. If the PREVIOUS device is still listed by the system the
 *     user switched outputs: keep playing, re-measure the device clock and its
 *     latency, emit routeChanged{outputLatencyUs, routeId}. If it is gone it
 *     was unplugged and the OS fell back to another output: stop (the audio
 *     must never jump to the speaker) and emit routeChanged
 *     {oldDeviceUnavailable: true, routeId}.
 *   - stopped and NOT restarted within the debounce (unplugged with nothing
 *     to fall back to, or the driver died — including the backends that skip
 *     the "stopped" notification): stop, emit routeChanged
 *     {oldDeviceUnavailable: true}. Never restarted by itself; the next
 *     lj_play_at opens a fresh device.
 *   - stopped and resumed with no reroute (PulseAudio suspend): re-measure
 *     the clock, no event.
 * From the first unexpected notification until that verdict, the callback's
 * output is muted, so nothing is heard on a device we are about to abandon.
 * Not visible to any backend: PulseAudio/PipeWire PORT switches on one sink
 * (headphone jack vs speaker on the same card) — the stream never moves.
 *
 * FAILURES
 * --------
 * A failure off the method-call path that leaves output stopped is reported
 * as playbackError{code, message} and the schedule is retired:
 *   decode_failed  the decoder/resampler for the schedule failed (e.g. the
 *                  file vanished after load) — re-scheduling would fail the
 *                  same way, so this is NOT engineRestarted.
 * A lost output device is a route change, not an error (see "Routes").
 *
 * No C++ exception leaves this API: allocation or thread-creation failures
 * become LJ_ERR_INTERNAL (or decode_failed inside a decoder thread) rather
 * than std::terminate.
 *
 * Licence: same as the LocalJam repo. Vendored third-party code in
 * src/third_party (public domain / MIT-0) — see third_party/LICENSES.md.
 */

#ifndef LOCALJAM_AUDIO_CORE_H_
#define LOCALJAM_AUDIO_CORE_H_

#include <stddef.h>
#include <stdint.h>

#if defined(__cplusplus)
extern "C" {
#endif

/* ---------------------------------------------------------------- tuning --- */

/*
 * Minimum achievable scheduling lead (µs): device start + callback-clock
 * maturity + safety margin. Anchors closer than this are re-anchored to
 * now + LJ_MIN_LEAD_US with the media position advanced at ×rate (§5.3 late
 * join), so the priming loop itself always lands the start precisely. Mirrors
 * Android's MIN_LEAD_US / iOS's minLeadUs.
 */
#ifndef LJ_MIN_LEAD_US
#define LJ_MIN_LEAD_US 150000
#endif

/*
 * Maturity gate for the device-callback clock model (see the file comment).
 * Overridable at compile time so src/test can build a second binary whose gate
 * deliberately outlasts LJ_MIN_LEAD_US and therefore takes the overshoot-trim
 * branch — the one path a healthy machine never reaches on its own.
 */
#ifndef LJ_MATURITY_CALLBACKS
#define LJ_MATURITY_CALLBACKS 3
#endif
#ifndef LJ_MATURITY_SPAN_US
#define LJ_MATURITY_SPAN_US 15000
#endif

/*
 * Stream limits applied at load/probe (LJ_ERR_LOAD_FAILED outside them). The
 * same bounds as the iOS/macOS plugin, so a file plays on every platform or on
 * none. They also cap every size derived from a file header (see
 * lj_internal::ComputeStreamSizing).
 */
#define LJ_MIN_SAMPLE_RATE 4000u
#define LJ_MAX_SAMPLE_RATE 384000u
/* 2^37 frames: 99 h even at 384 kHz; anything longer is a crafted header. */
#define LJ_MAX_FRAMES (1ULL << 37)

/* Bounded PCM ring sizing — peak decoded memory per schedule. */
#ifndef LJ_RING_SECONDS
#define LJ_RING_SECONDS 8
#endif
#ifndef LJ_RING_MAX_BYTES
#define LJ_RING_MAX_BYTES (4 * 1024 * 1024)
#endif

/* ---------------------------------------------------------------- status --- */

typedef enum {
  LJ_OK = 0,
  /* Malformed arguments. Channel code: "bad_args". */
  LJ_ERR_BAD_ARGS,
  /* playAt/positionUs before a successful load. Channel code: "no_file". */
  LJ_ERR_NO_FILE,
  /* File missing, unreadable, or corrupt. Channel code: "load_failed". */
  LJ_ERR_LOAD_FAILED,
  /* Recognised container this backend cannot decode (m4a/aac/alac/wma/...).
     Channel code: "unsupported_format". */
  LJ_ERR_UNSUPPORTED_FORMAT,
  /* Start position outside the file. Channel code: "bad_position". */
  LJ_ERR_BAD_POSITION,
  /* The audio device could not be opened or started. Channel code:
     "engine_start_failed". */
  LJ_ERR_ENGINE_START_FAILED,
  /* Anything unexpected. Channel code: "internal". */
  LJ_ERR_INTERNAL
} lj_status;

/* Accepted playback rates (playAt / setRate). The ±0.5 % §5.4 slews sit deep
 * inside; the bounds match what AVAudioUnitTimePitch can realise on Apple
 * platforms and keep the resampler ratio arithmetic finite. */
#define LJ_MIN_RATE (1.0 / 32.0)
#define LJ_MAX_RATE 32.0

/* Furthest-ahead anchor lj_play_at accepts (1 h). Anything beyond is a caller
 * bug (an uncalibrated clock), refused with LJ_ERR_BAD_ARGS rather than
 * scheduled hours of silence ahead. Same bound on iOS/macOS. */
#define LJ_MAX_LEAD_US 3600000000LL

/* Stable string code for `status`, matching the codes the iOS/Android plugins
 * put in FlutterError/MethodChannel.Result.error. Never NULL. */
const char* lj_status_code(lj_status status);

/* ---------------------------------------------------------------- events --- */

/*
 * Mirrors LocaljamAudioEventKind in lib/localjam_audio.dart. lj_event_type_name
 * returns the exact `type` string the Dart decoder expects.
 *
 * Availability on this backend:
 *   playbackFinished    always (the scheduled segment reached end of file)
 *   engineRestarted     never (nothing here restarts by itself)
 *   routeChanged        see "Routes" above: a reroute the backend reports
 *                       (WASAPI default-device change; PulseAudio stream
 *                       move) carries the new route's output latency and id;
 *                       a lost output carries oldDeviceUnavailable.
 *   interruptionBegan   ma_device_notification_type_interruption_began /
 *   interruptionEnded   ..._ended.
 *   playbackError       decode_failed (see "Failures" above).
 */
typedef enum {
  LJ_EVENT_ROUTE_CHANGED = 0,
  LJ_EVENT_INTERRUPTION_BEGAN,
  LJ_EVENT_INTERRUPTION_ENDED,
  LJ_EVENT_ENGINE_RESTARTED,
  LJ_EVENT_PLAYBACK_FINISHED,
  LJ_EVENT_PLAYBACK_ERROR
} lj_event_kind;

const char* lj_event_type_name(lj_event_kind kind);

/*
 * One event for the `localjam_audio/events` EventChannel; the shells turn it
 * into the payload map:
 *   type                  lj_event_type_name(kind)
 *   outputLatencyUs       output_latency_us, when has_latency (routeChanged)
 *   routeId               route_id, when non-NULL (routeChanged)
 *   oldDeviceUnavailable  old_device_unavailable != 0 (routeChanged; always
 *                         sent for that kind)
 *   code, message         when non-NULL (playbackError; both always set there)
 * The strings are only valid for the duration of the callback.
 */
typedef struct {
  lj_event_kind kind;
  int64_t output_latency_us;
  int has_latency;
  const char* code;
  const char* message;
  const char* route_id;
  int old_device_unavailable;
} lj_event;

/*
 * NEVER invoked from the audio callback; safe to hop to a UI thread inside
 * (copy the strings). Also never invoked re-entrantly from inside an lj_*
 * call.
 */
typedef void (*lj_event_cb)(void* user_data, const lj_event* event);

/*
 * Diagnostic log sink. Receives the scheduling traces this engine emits —
 * including the measured "start error: ..." line that is the live check on
 * scheduling accuracy (same role as the Android log of that name). NULL sends
 * them to stderr; pass lj_log_discard to silence them.
 */
typedef void (*lj_log_cb)(void* user_data, const char* message);
void lj_log_discard(void* user_data, const char* message);

/* --------------------------------------------------------------- engine ---- */

typedef struct lj_engine lj_engine;

/*
 * Current native monotonic time (µs) — the scheduling timebase. Cheap; this is
 * what the `nowUs` channel method returns and what the Dart-side calibrate()
 * measures its offset against.
 */
int64_t lj_now_us(void);

/*
 * Creates the engine. No audio device is opened yet (the device is opened per
 * schedule, from the loaded file's format). `event_cb` may be NULL.
 * `err`/`err_len` receive a human-readable message on failure; pass NULL to
 * skip.
 */
lj_status lj_create(lj_engine** out_engine,
                    lj_event_cb event_cb,
                    void* event_user_data,
                    lj_log_cb log_cb,
                    void* log_user_data,
                    char* err,
                    size_t err_len);

/* Stops everything and frees the engine. Safe on NULL. Matches `dispose`. */
void lj_destroy(lj_engine* engine);

/*
 * Loads (probes) a local audio file and returns its duration in µs.
 * Replaces any previously loaded file, stopping playback first; a failed load
 * leaves nothing loaded. O(1) in file length for wav/flac/ogg; mp3 needs one
 * parse-only pass to count frames exactly (no decoding). Files outside
 * [LJ_MIN_SAMPLE_RATE, LJ_MAX_SAMPLE_RATE], with more than LJ_MAX_FRAMES
 * frames, no frames, or more than two channels fail with LJ_ERR_LOAD_FAILED.
 */
lj_status lj_load(lj_engine* engine,
                  const char* path,
                  int64_t* out_duration_us,
                  char* err,
                  size_t err_len);

/*
 * Schedules playback so that media position `position_us` is being presented
 * exactly when the native clock reads `native_time_us`, at `rate`.
 * An anchor closer than LJ_MIN_LEAD_US (or in the past) is re-anchored forward
 * with the position advanced at ×rate — never an uncontrolled ASAP start.
 * Calling while playing retires the previous schedule. `rate` must lie in
 * [LJ_MIN_RATE, LJ_MAX_RATE]; `native_time_us` at most LJ_MAX_LEAD_US ahead.
 */
lj_status lj_play_at(lj_engine* engine,
                     int64_t native_time_us,
                     int64_t position_us,
                     double rate,
                     char* err,
                     size_t err_len);

/* Pauses playback, keeping the loaded file. Resume is a fresh lj_play_at. */
lj_status lj_pause(lj_engine* engine);

/* Stops and discards playback state; the file stays loaded. */
lj_status lj_stop(lj_engine* engine);

/*
 * Current playback position (µs), derived from the device clock — not a cached
 * value. Returns 1 and writes *out_us when playing or scheduled; returns 0 when
 * idle/paused/finished, in which case the channel must reply null.
 */
int lj_position_us(lj_engine* engine, int64_t* out_us);

/* Adjusts playback rate without re-anchoring the session (§5.4 drift slew).
 * Plain resample: pitch shifts by the ratio (see the file comment). */
lj_status lj_set_rate(lj_engine* engine, double rate, char* err, size_t err_len);

/* Output latency of the current route (µs); 0 when no device is open. */
int64_t lj_output_latency_us(lj_engine* engine);

/*
 * Duration (µs) of the file at `path` — exactly what lj_load would report —
 * from a private decoder that is opened and closed again. Touches no engine,
 * so it is safe while playing and from any thread. Returns LJ_OK, or the
 * status lj_load would have failed with (the channel replies null then).
 * O(1) for wav/flac/ogg; mp3 needs one parse-only pass over frame headers.
 */
lj_status lj_probe_duration(const char* path,
                            int64_t* out_duration_us,
                            char* err,
                            size_t err_len);

/*
 * Writes the id of the current output route — the system default playback
 * device, which the open device follows — into `out` and returns 1, or
 * returns 0 when no output device can be identified. Format
 * "<miniaudio backend>:<16 hex digits>", the digits an FNV-1a 64 hash of the
 * backend's device id (WASAPI endpoint id, PulseAudio sink name, ...) or, when
 * the backend has none, of the device name: stable for one device across
 * sessions, opaque like the other platforms' route ids.
 *
 * Touches no engine: it asks the audio server through a private, throwaway
 * miniaudio context, so it is safe from any thread, concurrently — but it
 * BLOCKS on that server (milliseconds; longer if it is wedged), so never call
 * it on a UI thread.
 */
int lj_current_route_id(char* out, size_t out_len);

/* ------------------------------------------------------ test instrumentation */

/*
 * Per-callback trace used by src/test/core_test.cpp to verify the source-frame
 * bookkeeping INDEPENDENTLY of the clock model: the test file's channel 0 is a
 * linear ramp encoding its own frame index, so `first_sample` identifies which
 * source frame the callback actually emitted, and can be checked against what
 * the position formula claims. Not used in production; the tap is NULL there.
 *
 * Called ON the audio thread — it must only write to preallocated memory.
 */
typedef struct {
  int64_t callback_time_us; /* lj_now_us() at callback entry */
  int64_t out_frames_before; /* output frames handed over before this callback */
  uint32_t frame_count;      /* frames requested */
  int64_t first_media_out_frame; /* output index of the first media frame in
                                    this callback, or -1 if all silence */
  float first_media_sample; /* channel-0 value of that frame (before muting) */
  int muted; /* the callback's output was silenced (route change pending) */
} lj_tap_sample;

typedef void (*lj_tap_cb)(void* user_data, const lj_tap_sample* sample);
void lj_set_tap(lj_engine* engine, lj_tap_cb tap, void* user_data);

/* Device parameters of the active schedule (0 when none) — for test asserts. */
uint32_t lj_device_sample_rate(lj_engine* engine);
int64_t lj_device_latency_frames(lj_engine* engine);

/*
 * Replays a device notification into the engine exactly as if the backend had
 * sent it for the open device, so src/test/core_test.cpp can drive the route
 * logic (see "Routes") end to end on a real device without unplugging
 * anything. LJ_TEST_FORGET_ROUTE instead makes the engine's record of the
 * device's output name one the system does not list, so the next reroute reads
 * as "the previous output was unplugged". No effect without an open device.
 * Not used in production.
 */
typedef enum {
  LJ_TEST_DEVICE_STARTED = 0,
  LJ_TEST_DEVICE_STOPPED,
  LJ_TEST_DEVICE_REROUTED,
  LJ_TEST_FORGET_ROUTE
} lj_test_signal;
void lj_test_signal_device(lj_engine* engine, lj_test_signal signal);

#if defined(__cplusplus)
} /* extern "C" */
#endif

#endif /* LOCALJAM_AUDIO_CORE_H_ */
