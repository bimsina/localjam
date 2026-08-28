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
 *  - Caller thread(s): all lj_* calls. They are internally serialised by a
 *    mutex; none of them block on audio I/O.
 *  - Device callback (audio thread, owned by miniaudio): drains the ring,
 *    records clock samples. Takes the same mutex, but only ever for a few
 *    microseconds of arithmetic — no allocation, no I/O, no waiting.
 *  - One decoder thread per schedule, generation-tagged exactly like the
 *    Android writer/decoder pair so a superseded thread exits silently.
 *  - One monitor thread for the whole engine: emits playbackFinished when the
 *    last media frame has been presented, and logs the measured start error.
 *    Events NEVER fire on the audio thread.
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
 *   engineRestarted     device error / decoder failure — the schedule is gone
 *   routeChanged        miniaudio ma_device_notification_type_rerouted, where
 *                       the backend reports it (WASAPI default-device change;
 *                       PulseAudio server events). Carries the new route's
 *                       output latency.
 *   interruptionBegan   ma_device_notification_type_interruption_began /
 *   interruptionEnded   ..._ended, plus an unexpected device stop.
 */
typedef enum {
  LJ_EVENT_ROUTE_CHANGED = 0,
  LJ_EVENT_INTERRUPTION_BEGAN,
  LJ_EVENT_INTERRUPTION_ENDED,
  LJ_EVENT_ENGINE_RESTARTED,
  LJ_EVENT_PLAYBACK_FINISHED
} lj_event_kind;

const char* lj_event_type_name(lj_event_kind kind);

/*
 * One event for the `localjam_audio/events` EventChannel. `has_latency` is 1
 * when `output_latency_us` should be included as the payload's
 * "outputLatencyUs" key (today: routeChanged only), 0 otherwise.
 *
 * NEVER invoked from the audio callback; safe to hop to a UI thread inside.
 * Also never invoked re-entrantly from inside an lj_* call.
 */
typedef void (*lj_event_cb)(void* user_data,
                            lj_event_kind kind,
                            int64_t output_latency_us,
                            int has_latency);

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
 * Replaces any previously loaded file, stopping playback first. O(1) in file
 * length for wav/flac/ogg; mp3 needs one parse-only pass to count frames
 * exactly (no decoding).
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
 * Calling while playing retires the previous schedule.
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
  float first_media_sample; /* channel-0 value of that frame */
} lj_tap_sample;

typedef void (*lj_tap_cb)(void* user_data, const lj_tap_sample* sample);
void lj_set_tap(lj_engine* engine, lj_tap_cb tap, void* user_data);

/* Device parameters of the active schedule (0 when none) — for test asserts. */
uint32_t lj_device_sample_rate(lj_engine* engine);
int64_t lj_device_latency_frames(lj_engine* engine);

#if defined(__cplusplus)
} /* extern "C" */
#endif

#endif /* LOCALJAM_AUDIO_CORE_H_ */
