package np.com.bibektimsina.localjam_audio

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioFocusRequest
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTimestamp
import android.media.AudioTrack
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.PlaybackParams
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToLong

/**
 * Sample-accurate scheduled audio playback for LocalJam (PROTOCOL.md §5.3–§5.4),
 * Android implementation. Semantic reference: the iOS/macOS Swift plugin.
 *
 * ## Clock domain
 * "Native time" is `System.nanoTime() / 1000` (µs). System.nanoTime() is
 * CLOCK_MONOTONIC — the SAME clock domain as [AudioTimestamp.nanoTime], which
 * is what makes precise scheduling possible: every piece of scheduling math in
 * this file lives in that one domain, with no cross-clock translation.
 *
 * ## Playback pipeline
 * One [AudioTrack] in MODE_STREAM (USAGE_MEDIA / CONTENT_TYPE_MUSIC,
 * PERFORMANCE_MODE_LOW_LATENCY where available), fed by a dedicated writer
 * thread with blocking writes. Deviation from "one long-lived track": the
 * track is *recreated on every schedule* (playAt/stop/load), because the
 * epoch of AudioTimestamp.framePosition after stop()/flush() is
 * device-inconsistent, while a freshly created track has an unambiguous
 * frame 0. Creation costs tens of ms, well inside the minLeadUs re-anchor
 * budget below.
 *
 * ## Silence-priming schedule math (the heart of playAt)
 * AudioTrack cannot start "at time T"; it can only start ASAP. So:
 *
 *  1. Start the track immediately and stream *silence* frames.
 *  2. Poll [AudioTrack.getTimestamp] between chunks. Only a MATURE pair —
 *     framePosition > 0 — counts: "source frame F_ts was presented at the
 *     output at monotonic instant T_ts", latency already accounted for by
 *     the HAL. (The first report typically has framePosition == 0, an
 *     optimistic mapping that EXCLUDES pipeline latency; anchoring on it
 *     makes the first real sample render ~an-output-latency late — a
 *     constant error drift correction can never remove, because every hard
 *     resync re-primes the same way. Measured −68 ms on a Pixel 9 Pro
 *     emulator.) Given a mature pair, the source-frame index that will be
 *     presented exactly at the target instant is:
 *
 *         S = F_ts + (targetNs − T_ts) × sampleRate × rate / 1e9
 *
 *     (×rate because with PlaybackParams speed=r the sink consumes *source*
 *     frames at r × realtime; framePosition counts source frames.)
 *  3. S is the total number of silence frames: pad (write more silence) until
 *     exactly S frames are queued, refining S against fresh timestamps along
 *     the way, then stream real PCM. If more than S silence frames were
 *     already queued (overshoot Δ = written − S, e.g. timestamp warm-up was
 *     slow), the media is *trimmed* instead: the first Δ decoded frames are
 *     skipped, which keeps every subsequent frame on the anchor formula
 *     exactly (frame S+k always carries media position P + k/sampleRate).
 *
 * A "start ASAP" path is deliberately absent (same rationale as iOS): an
 * uncontrolled start incurs unpredictable spin-up delay that shows up as a
 * permanent position lag drift correction can never remove. A late anchor
 * (§5.3 late join) is re-anchored minLeadUs into the future with the media
 * position advanced at ×rate to match, so the priming loop itself lands the
 * start sample-accurately.
 *
 * ## Position math
 *     fNow        = refFrame + (nowNs − refNanos) × sampleRate × rate / 1e9
 *     positionUs  = anchorMediaUs + (fNow − S) / sampleRate × 1e6
 *     clamped to [0, durationUs]
 * where (refFrame, refNanos) is the freshest known frame↔time mapping.
 * Before the real audio starts (fNow < S) the formula extrapolates below
 * anchorMediaUs — the same anchor-consistent pre-start behavior as the iOS
 * player's negative sampleTime. While the priming timestamp is not yet
 * available, positionUs falls back to the pure anchor formula
 * P + (now − anchor) × rate, which is the same line.
 *
 * ## Rate-change bookkeeping ([setRate])
 * framePosition counts *source* frames, so the (frame − S) → media-time
 * mapping needs NO re-anchoring across speed changes (exactly like the iOS
 * source-frame clock changing slope). Only the *extrapolation* term uses the
 * current rate; a HAL timestamp taken before a rate change would extrapolate
 * wrongly at the new rate, so setRate re-anchors the (refFrame, refNanos)
 * mapping at the instant of the change, and fresher HAL timestamps
 * (nanoTime > refNanos, hence post-change) replace it as they arrive.
 * Residual error is |Δrate| × timestamp staleness — for §5.4's ±0.5% slews
 * that is well under the 15 ms ignore threshold.
 *
 * ## Decode
 * 'load' decodes the whole file (mp3/m4a/aac/wav) to 16-bit interleaved PCM
 * in memory via MediaExtractor + MediaCodec. Memory cost: ~10.6 MB per
 * stereo 44.1 kHz minute — acceptable for v1 (LocalJam plays single local
 * music tracks); a streaming decoder is the v2 option.
 *
 * ## outputLatencyUs
 * Android has no public output-latency API; we best-effort the hidden
 * "android.media.property.OUTPUT_LATENCY" AudioManager property (ms) that
 * some devices honor, else 0. This is fine: getTimestamp-based scheduling
 * already includes the full pipeline latency (the HAL timestamps the frame
 * *presented at the output*), so this value is only the §7 calibration
 * starting point for the UI nudge.
 *
 * ## Threading
 * Method-channel handlers run serialized on one background HandlerThread;
 * every handler posts its result back to the main thread exactly once.
 * The writer thread (one per schedule, tagged with a generation counter à la
 * iOS scheduleGeneration) is separate. All shared state is guarded by [lock].
 * Events are delivered on the main thread.
 */
class LocaljamAudioPlugin :
    FlutterPlugin,
    MethodCallHandler,
    EventChannel.StreamHandler {
    private companion object {
        const val TAG = "LocaljamAudio"

        /**
         * Minimum achievable scheduling lead (µs): track creation + timestamp
         * warm-up + safety margin. Anchors closer than this are re-anchored
         * to now + MIN_LEAD_US (mirrors iOS minLeadUs).
         */
        const val MIN_LEAD_US = 150_000L

        /** Give getTimestamp this long to become valid before falling back. */
        const val TIMESTAMP_WARMUP_NS = 1_000_000_000L

        /** Current native monotonic time in µs. */
        fun nowUs(): Long = System.nanoTime() / 1000
    }

    private enum class State { IDLE, LOADED, PLAYING, PAUSED, FINISHED }

    /** Decoded file: interleaved 16-bit LE PCM, fully in memory (see class doc). */
    private class DecodedAudio(
        val pcm: ByteArray,
        val sampleRate: Int,
        val channels: Int
    ) {
        val bytesPerFrame get() = 2 * channels
        val totalFrames get() = pcm.size.toLong() / bytesPerFrame
        val durationUs get() = totalFrames * 1_000_000L / sampleRate
    }

    /**
     * One playAt schedule. Immutable identity + mutable position-mapping
     * fields; ALL fields (and the track's lifecycle) are guarded by [lock]
     * except where noted in the writer, which snapshots under the lock.
     */
    private class Schedule(
        val generation: Long,
        val track: AudioTrack,
        val sampleRate: Int,
        val channels: Int,
        /** Effective anchor instant, native ns (already ≥ now + MIN_LEAD). */
        val targetNs: Long,
        /** Media position (µs, frame-exact) at the anchor — 'P'. */
        val anchorMediaUs: Long,
        /** First decoded-PCM frame of the segment (before any overshoot trim). */
        val startFrame: Long,
        var rate: Double,
        /** Total silence frames 'S'; −1 until the priming timestamp lands. */
        var silenceFrames: Long = -1L,
        /** Freshest source-frame ↔ CLOCK_MONOTONIC mapping for extrapolation. */
        var refFrame: Double = 0.0,
        var refNanos: Long = 0L,
        var refValid: Boolean = false
    )

    private lateinit var channel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private var appContext: Context? = null
    private var audioManager: AudioManager? = null

    private val mainHandler = Handler(Looper.getMainLooper())
    private var handlerThread: HandlerThread? = null
    private var bgHandler: Handler? = null

    /** Dart-side event sink; touched on the main thread only. */
    private var eventSink: EventChannel.EventSink? = null

    /** Guards every field below (and Schedule mutables). */
    private val lock = Object()
    private var state = State.IDLE
    private var decoded: DecodedAudio? = null
    private var schedule: Schedule? = null

    /**
     * Bumped on every (re)schedule/stop/load/dispose so stale writer threads
     * and their completion signals can be ignored (iOS scheduleGeneration).
     */
    private var generation = 0L

    private var focusRequest: AudioFocusRequest? = null
    private var deviceCallback: AudioDeviceCallback? = null

    // ---------------------------------------------------------------- plugin

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        audioManager =
            binding.applicationContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        channel = MethodChannel(binding.binaryMessenger, "localjam_audio")
        channel.setMethodCallHandler(this)
        eventChannel = EventChannel(binding.binaryMessenger, "localjam_audio/events")
        eventChannel.setStreamHandler(this)
        val thread = HandlerThread("localjam_audio")
        thread.start()
        handlerThread = thread
        bgHandler = Handler(thread.looper)
        registerRouteCallback()
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        synchronized(lock) {
            bumpGenerationLocked()
            releaseTrackLocked()
            decoded = null
            state = State.IDLE
        }
        abandonFocus()
        unregisterRouteCallback()
        handlerThread?.quitSafely()
        handlerThread = null
        bgHandler = null
        audioManager = null
        appContext = null
    }

    // ---------------------------------------------------------- event channel

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    /**
     * Emits one event to Dart. Callable from any thread; delivery always on
     * the main thread (the EventSink threading contract).
     */
    private fun emitEvent(type: String, outputLatencyUs: Long? = null) {
        mainHandler.post {
            val sink = eventSink ?: return@post
            val payload = HashMap<String, Any>()
            payload["type"] = type
            if (outputLatencyUs != null) payload["outputLatencyUs"] = outputLatencyUs
            sink.success(payload)
        }
    }

    // --------------------------------------------------------- method channel

    override fun onMethodCall(call: MethodCall, result: Result) {
        val handler = bgHandler
        if (handler == null) {
            result.error("disposed", "plugin detached", null)
            return
        }
        // All handlers run serialized on the background thread (like iOS's
        // serial queue); `reply` marshals back to the platform thread and is
        // called exactly once per invocation.
        handler.post {
            try {
                when (call.method) {
                    "nowUs" -> replySuccess(result, nowUs())
                    "load" -> handleLoad(call, result)
                    "playAt" -> handlePlayAt(call, result)
                    "pause" -> handlePause(result)
                    "stop" -> handleStop(result)
                    "positionUs" -> handlePositionUs(result)
                    "setRate" -> handleSetRate(call, result)
                    "outputLatencyUs" -> replySuccess(result, currentOutputLatencyUs())
                    "dispose" -> handleDispose(result)
                    else -> mainHandler.post { result.notImplemented() }
                }
            } catch (e: Throwable) {
                Log.e(TAG, "unhandled error in '${call.method}'", e)
                replyError(result, "internal", "${call.method} failed: $e")
            }
        }
    }

    private fun replySuccess(result: Result, value: Any?) {
        mainHandler.post { result.success(value) }
    }

    private fun replyError(result: Result, code: String, message: String) {
        mainHandler.post { result.error(code, message, null) }
    }

    // ---------------------------------------------------------------- handlers

    private fun handleLoad(call: MethodCall, result: Result) {
        val path = call.argument<String>("path")
        if (path == null) {
            replyError(result, "bad_args", "load requires {path: String}")
            return
        }
        // Replace any previously loaded file; stop playback first.
        synchronized(lock) {
            bumpGenerationLocked()
            releaseTrackLocked()
            state = State.IDLE
            decoded = null
        }
        val audio: DecodedAudio
        try {
            audio = decodeToPcm16(path)
        } catch (e: Throwable) {
            replyError(result, "load_failed", "Could not decode audio file at $path: $e")
            return
        }
        Log.d(
            TAG,
            "load: $path -> ${audio.totalFrames} frames @ ${audio.sampleRate} Hz x" +
                "${audio.channels}ch (${audio.pcm.size} bytes, ${audio.durationUs} us)"
        )
        synchronized(lock) {
            decoded = audio
            state = State.LOADED
        }
        replySuccess(result, audio.durationUs)
    }

    private fun handlePlayAt(call: MethodCall, result: Result) {
        val nativeTimeUs = call.argument<Number>("nativeTimeUs")?.toLong()
        val positionUs = call.argument<Number>("positionUs")?.toLong()
        val rate = call.argument<Number>("rate")?.toDouble() ?: 1.0
        if (nativeTimeUs == null || positionUs == null) {
            replyError(result, "bad_args", "playAt requires nativeTimeUs and positionUs")
            return
        }
        if (rate <= 0.0 || !rate.isFinite()) {
            replyError(result, "bad_args", "playAt rate must be a positive finite number")
            return
        }

        val audio: DecodedAudio
        synchronized(lock) {
            val a = decoded
            if (a == null) {
                replyError(result, "no_file", "playAt before load")
                return
            }
            audio = a
            // Calling while already playing/scheduled: retire the old schedule
            // (generation bump makes its writer exit; release unblocks it).
            bumpGenerationLocked()
            releaseTrackLocked()
            state = State.LOADED // until the new schedule is installed below
        }

        // Never an uncontrolled "ASAP" start: a late anchor is re-anchored
        // minLead into the future with the position advanced at ×rate (§5.3
        // late join), so the priming loop lands the start precisely.
        val now = nowUs()
        var anchorUs = nativeTimeUs
        var startPosUs = positionUs
        if (anchorUs < now + MIN_LEAD_US) {
            startPosUs += ((now + MIN_LEAD_US - anchorUs) * rate).roundToLong()
            anchorUs = now + MIN_LEAD_US
        }

        val sr = audio.sampleRate
        val startFrame = (startPosUs.toDouble() * sr / 1e6).roundToLong()
        if (startFrame < 0 || startFrame >= audio.totalFrames) {
            replyError(
                result,
                "bad_position",
                "start position ${startPosUs}us is outside the file (duration ${audio.durationUs}us)"
            )
            return
        }
        // Keep the anchor frame-exact so the position formula has no rounding
        // bias (mirrors iOS segmentStartUs).
        val anchorMediaUs = (startFrame.toDouble() * 1e6 / sr).roundToLong()

        requestFocus()

        val track: AudioTrack
        try {
            track = createTrack(audio)
        } catch (e: Throwable) {
            replyError(result, "engine_start_failed", "AudioTrack creation failed: $e")
            return
        }
        try {
            track.playbackParams = PlaybackParams().setSpeed(rate.toFloat()).setPitch(1.0f)
        } catch (e: Throwable) {
            // Rate 1.0 never fails; an exotic rate falling back to 1.0 is a
            // soft failure the §5.4 loop will notice and correct around.
            Log.w(TAG, "setPlaybackParams(speed=$rate) failed, playing at 1.0", e)
        }

        val sched: Schedule
        synchronized(lock) {
            sched = Schedule(
                generation = generation,
                track = track,
                sampleRate = sr,
                channels = audio.channels,
                targetNs = anchorUs * 1000,
                anchorMediaUs = anchorMediaUs,
                startFrame = startFrame,
                rate = rate
            )
            schedule = sched
            state = State.PLAYING
        }
        Log.d(
            TAG,
            "playAt: requested nativeTimeUs=$nativeTimeUs positionUs=$positionUs rate=$rate " +
                "-> effective anchorUs=$anchorUs startPosUs=$startPosUs startFrame=$startFrame " +
                "anchorMediaUs=$anchorMediaUs (now=$now leadUs=${anchorUs - now})"
        )
        Thread({ writerMain(sched, audio) }, "localjam_audio-writer").start()
        replySuccess(result, null)
    }

    private fun handlePause(result: Result) {
        synchronized(lock) {
            if (state == State.PLAYING) {
                try {
                    schedule?.track?.pause()
                } catch (e: Throwable) {
                    Log.w(TAG, "pause failed", e)
                }
                state = State.PAUSED
                lock.notifyAll()
            }
        }
        replySuccess(result, null)
    }

    private fun handleStop(result: Result) {
        synchronized(lock) {
            bumpGenerationLocked()
            releaseTrackLocked()
            state = if (decoded != null) State.LOADED else State.IDLE
        }
        replySuccess(result, null)
    }

    private fun handlePositionUs(result: Result) {
        // Contract: null when nothing is playing or scheduled (paused/finished
        // included — matching iOS's `guard state == .playing`).
        val value: Long? = synchronized(lock) {
            val sched = schedule
            if (state != State.PLAYING || sched == null) return@synchronized null
            val nowNs = System.nanoTime()
            if (sched.silenceFrames < 0 || !sched.refValid) {
                // Still priming: the anchor formula itself (identical line,
                // just not yet expressed in frames). Extrapolates below the
                // anchor position pre-start, like iOS's negative sampleTime.
                val us = sched.anchorMediaUs +
                    ((nowNs / 1000 - sched.targetNs / 1000) * sched.rate).roundToLong()
                return@synchronized clampToDuration(us)
            }
            // Refresh the frame↔time mapping from the HAL if it has a newer
            // sample than our current reference (which may be a synthetic
            // rate-change re-anchor; see setRate). framePosition == 0 reports
            // are immature (nothing presented yet, latency excluded) and are
            // never accepted as a mapping.
            val ts = AudioTimestamp()
            if (trackTimestamp(sched.track, ts) && ts.framePosition > 0 &&
                ts.nanoTime > sched.refNanos
            ) {
                sched.refFrame = ts.framePosition.toDouble()
                sched.refNanos = ts.nanoTime
            }
            val fNow = sched.refFrame +
                (nowNs - sched.refNanos).toDouble() * sched.sampleRate * sched.rate / 1e9
            val us = sched.anchorMediaUs +
                ((fNow - sched.silenceFrames) * 1e6 / sched.sampleRate).roundToLong()
            clampToDuration(us)
        }
        replySuccess(result, value)
    }

    private fun handleSetRate(call: MethodCall, result: Result) {
        val rate = call.argument<Number>("rate")?.toDouble()
        if (rate == null || rate <= 0.0 || !rate.isFinite()) {
            replyError(result, "bad_args", "setRate requires {rate: positive double}")
            return
        }
        synchronized(lock) {
            val sched = schedule
            if (sched != null) {
                // Re-anchor the extrapolation mapping AT the instant of the
                // rate change: frames before this instant were consumed at the
                // old rate, frames after at the new one. The media mapping
                // (frame − S) needs no change (source-frame domain).
                val nowNs = System.nanoTime()
                if (sched.refValid) {
                    sched.refFrame +=
                        (nowNs - sched.refNanos).toDouble() * sched.sampleRate * sched.rate / 1e9
                    sched.refNanos = nowNs
                }
                sched.rate = rate
                try {
                    sched.track.playbackParams =
                        PlaybackParams().setSpeed(rate.toFloat()).setPitch(1.0f)
                } catch (e: Throwable) {
                    Log.w(TAG, "setRate($rate) failed", e)
                }
                Log.d(TAG, "setRate: $rate (refFrame=${sched.refFrame} refNanos=${sched.refNanos})")
            }
        }
        replySuccess(result, null)
    }

    private fun handleDispose(result: Result) {
        synchronized(lock) {
            bumpGenerationLocked()
            releaseTrackLocked()
            decoded = null
            state = State.IDLE
        }
        abandonFocus()
        replySuccess(result, null)
    }

    // ------------------------------------------------------------ shared state

    /** Must hold [lock]. Retires all outstanding writers/completions. */
    private fun bumpGenerationLocked() {
        generation += 1
        lock.notifyAll() // wake any writer parked in PAUSED
    }

    /** Must hold [lock]. */
    private fun releaseTrackLocked() {
        val sched = schedule ?: return
        schedule = null
        try {
            sched.track.pause()
            sched.track.flush()
        } catch (_: Throwable) {
        }
        try {
            sched.track.release() // also unblocks a writer stuck in write()
        } catch (_: Throwable) {
        }
    }

    /** Must hold [lock]. */
    private fun clampToDuration(us: Long): Long {
        val duration = decoded?.durationUs ?: return max(0, us)
        return min(max(0, us), duration)
    }

    private fun isStale(sched: Schedule): Boolean =
        synchronized(lock) { generation != sched.generation }

    // ------------------------------------------------------------ writer thread

    /**
     * Streams one schedule: silence priming, then media PCM, then completion
     * detection. Exits silently the moment its generation is stale.
     */
    private fun writerMain(sched: Schedule, audio: DecodedAudio) {
        val track = sched.track
        val sr = sched.sampleRate
        val bpf = audio.bytesPerFrame
        val chunkFrames = max(sr / 100, 128) // ~10 ms
        val silence = ByteArray(chunkFrames * bpf)
        var written = 0L // source frames queued to the track so far

        try {
            track.play()
        } catch (e: Throwable) {
            writerTrackFailure(sched, "play() failed: $e")
            return
        }

        // ---- Phase 1: silence until getTimestamp yields a MATURE frame↔time
        // mapping. Maturity means framePosition > 0: the HAL has actually
        // presented frames, so the pair includes the real pipeline latency.
        // The very first report typically carries framePosition == 0 — an
        // optimistic mapping that EXCLUDES latency; computing S from it lands
        // the first real sample tens of ms late (measured −68 ms on a Pixel 9
        // Pro emulator), an error the Dart drift check can never slew away
        // because every hard resync re-primes and repeats it.
        val ts = AudioTimestamp()
        val warmupDeadline = System.nanoTime() + TIMESTAMP_WARMUP_NS
        var primed = false
        while (!primed) {
            if (isStale(sched)) return
            val n = track.write(silence, 0, silence.size, AudioTrack.WRITE_BLOCKING)
            if (n < 0) {
                writerTrackFailure(sched, "write returned $n during priming")
                return
            }
            written += n / bpf
            if (trackTimestamp(track, ts) && ts.framePosition > 0) {
                primed = true
            } else if (System.nanoTime() >= warmupDeadline) {
                // Some outputs (emulators, odd HALs) never publish timestamps.
                // Degrade to playbackHeadPosition ~= "presented now": the
                // pipeline latency goes unaccounted (schedule lands early by
                // that much); §7 calibration absorbs it. Logged loudly.
                ts.framePosition = track.playbackHeadPosition.toLong() and 0xffffffffL
                ts.nanoTime = System.nanoTime()
                primed = true
                Log.w(
                    TAG,
                    "getTimestamp never became valid; using playbackHeadPosition fallback " +
                        "(output latency unaccounted)"
                )
            }
        }

        // ---- Phase 2: compute S and pad/trim the silence to hit the target.
        var s: Long
        synchronized(lock) {
            if (generation != sched.generation) return
            s = computeSilenceFramesLocked(sched, ts)
            sched.silenceFrames = s
            sched.refFrame = ts.framePosition.toDouble()
            sched.refNanos = ts.nanoTime
            sched.refValid = true
            Log.d(
                TAG,
                "prime: tsFrame=${ts.framePosition} tsNanos=${ts.nanoTime} " +
                    "targetNs=${sched.targetNs} rate=${sched.rate} -> S(silenceFrames)=$s " +
                    "written=$written (${if (s >= written) "pad ${s - written}" else "trim media ${written - s}"})"
            )
        }
        while (written < s) {
            if (isStale(sched)) return
            val todoFrames = min(chunkFrames.toLong(), s - written).toInt()
            val n = track.write(silence, 0, todoFrames * bpf, AudioTrack.WRITE_BLOCKING)
            if (n < 0) {
                writerTrackFailure(sched, "write returned $n during silence pad")
                return
            }
            written += n / bpf
            // Refine S against fresher MATURE timestamps while silence
            // remains — the warm-up sample can be jittery; later samples are
            // steadier. framePosition == 0 reports are optimistic (no latency)
            // and must never re-anchor the mapping.
            if (trackTimestamp(track, ts) && ts.framePosition > 0) {
                synchronized(lock) {
                    if (generation != sched.generation) return
                    if (ts.nanoTime > sched.refNanos) {
                        sched.refFrame = ts.framePosition.toDouble()
                        sched.refNanos = ts.nanoTime
                        s = computeSilenceFramesLocked(sched, ts)
                        sched.silenceFrames = s
                    }
                }
            }
        }

        // Overshoot trim: written − s already-queued silence frames stand where
        // media should be; skip that many decoded frames so source frame s+k
        // still carries media position anchorMediaUs + k/sr (see class doc).
        val mediaSkip = written - s
        val firstPcmFrame = sched.startFrame + mediaSkip
        val firstMediaSourceFrame = s + mediaSkip // == `written` at trim time
        val endSourceFrame = s + (audio.totalFrames - sched.startFrame)
        if (mediaSkip > 0) {
            // The target instant passed while the mapping matured (the 150 ms
            // lead can be shorter than warm-up, esp. on emulators). This IS
            // the late-anchor re-anchor path, expressed in frames: the media
            // start advances by mediaSkip/sr µs — exactly rate × the delay
            // past the anchor — so the SESSION anchor the Dart side passed
            // remains the truth and its drift check converges to zero instead
            // of seeing a constant offset.
            val (rateNow, tsF, tsNs) = synchronized(lock) {
                Triple(sched.rate, ts.framePosition, ts.nanoTime)
            }
            val achievedNs =
                tsNs + ((written - tsF).toDouble() * 1e9 / (sr * rateNow)).toLong()
            Log.d(
                TAG,
                "re-anchor during priming: requested targetNs=${sched.targetNs} " +
                    "achievedStartNs~=$achievedNs " +
                    "(late by ${(achievedNs - sched.targetNs) / 1000} us), " +
                    "media advanced ${mediaSkip * 1_000_000L / sr} us to stay on the session anchor"
            )
        }
        Log.d(
            TAG,
            "stream: mediaSkip=$mediaSkip firstPcmFrame=$firstPcmFrame " +
                "firstMediaSourceFrame=$firstMediaSourceFrame " +
                "endSourceFrame=$endSourceFrame totalFrames=${audio.totalFrames}"
        )

        // ---- Phase 3: stream the media PCM.
        var offset = (firstPcmFrame * bpf).toInt()
        val chunkBytes = chunkFrames * bpf
        var startErrorLogged = false
        while (offset < audio.pcm.size) {
            synchronized(lock) {
                while (generation == sched.generation && state == State.PAUSED) {
                    // Writer parks while paused. There is no resume-in-place:
                    // the Dart side re-schedules via playAt (generation bump),
                    // which wakes and retires this writer.
                    try {
                        lock.wait()
                    } catch (_: InterruptedException) {
                    }
                }
                if (generation != sched.generation) return
            }
            val n = track.write(
                audio.pcm, offset, min(chunkBytes, audio.pcm.size - offset),
                AudioTrack.WRITE_BLOCKING
            )
            if (n < 0) {
                writerTrackFailure(sched, "write returned $n during media stream")
                return
            }
            if (n > 0) offset += n
            if (trackTimestamp(track, ts) && ts.framePosition > 0) {
                synchronized(lock) {
                    if (generation != sched.generation) return
                    if (ts.nanoTime > sched.refNanos) {
                        sched.refFrame = ts.framePosition.toDouble()
                        sched.refNanos = ts.nanoTime
                    }
                    if (!startErrorLogged) {
                        // Measured start error for live verification: when did
                        // the first real PCM frame actually present, vs the
                        // instant the session anchor intended for it
                        // (targetNs shifted by the media advance at ×rate)?
                        startErrorLogged = true
                        val measuredNs = ts.nanoTime +
                            ((firstMediaSourceFrame - ts.framePosition).toDouble() * 1e9 /
                                (sr * sched.rate)).toLong()
                        val intendedNs = sched.targetNs +
                            (mediaSkip.toDouble() * 1e9 / (sr * sched.rate)).toLong()
                        Log.d(
                            TAG,
                            "start error: firstMediaSourceFrame=$firstMediaSourceFrame " +
                                "measuredNs=$measuredNs intendedNs=$intendedNs " +
                                "errorUs=${(measuredNs - intendedNs) / 1000}"
                        )
                    }
                }
            }
        }

        // ---- Phase 4: all frames written; wait until they are consumed
        // (getTimestamp extrapolation reaches the last media frame), then
        // report playbackFinished — matching iOS's .dataPlayedBack callback.
        val remainingUs = synchronized(lock) {
            if (generation != sched.generation) return
            val fNow = sched.refFrame +
                (System.nanoTime() - sched.refNanos).toDouble() * sr * sched.rate / 1e9
            ((endSourceFrame - fNow) * 1e6 / (sr * sched.rate)).toLong()
        }
        val drainDeadline = System.nanoTime() + max(0, remainingUs) * 1000 + 2_000_000_000L
        while (true) {
            if (isStale(sched)) return
            val fNow = synchronized(lock) {
                if (generation != sched.generation) return
                if (trackTimestamp(track, ts) && ts.framePosition > 0 &&
                    ts.nanoTime > sched.refNanos
                ) {
                    sched.refFrame = ts.framePosition.toDouble()
                    sched.refNanos = ts.nanoTime
                }
                sched.refFrame +
                    (System.nanoTime() - sched.refNanos).toDouble() * sr * sched.rate / 1e9
            }
            if (fNow >= endSourceFrame) break
            if (System.nanoTime() >= drainDeadline) {
                Log.w(TAG, "drain deadline hit (fNow=$fNow end=$endSourceFrame); finishing anyway")
                break
            }
            try {
                Thread.sleep(20)
            } catch (_: InterruptedException) {
            }
        }
        synchronized(lock) {
            if (generation != sched.generation) return
            state = State.FINISHED
            schedule = null
            try {
                sched.track.pause()
                sched.track.flush()
            } catch (_: Throwable) {
            }
            try {
                sched.track.release()
            } catch (_: Throwable) {
            }
        }
        Log.d(TAG, "playbackFinished (generation=${sched.generation})")
        emitEvent("playbackFinished")
    }

    /**
     * Must hold [lock]. Source-frame index presented exactly at the target:
     * S = F_ts + (targetNs − T_ts) × sr × rate / 1e9, clamped ≥ 0.
     */
    private fun computeSilenceFramesLocked(sched: Schedule, ts: AudioTimestamp): Long =
        max(
            0L,
            ts.framePosition +
                ((sched.targetNs - ts.nanoTime).toDouble() * sched.sampleRate * sched.rate / 1e9)
                    .roundToLong()
        )

    /** getTimestamp that never throws (dead track → false). */
    private fun trackTimestamp(track: AudioTrack, ts: AudioTimestamp): Boolean =
        try {
            track.getTimestamp(ts)
        } catch (_: Throwable) {
            false
        }

    /**
     * A track error the schedule cannot survive: drop the schedule and tell
     * Dart the engine restarted (its schedule is gone; re-schedule from the
     * authoritative anchor) — iOS's configuration-change semantics.
     */
    private fun writerTrackFailure(sched: Schedule, why: String) {
        synchronized(lock) {
            if (generation != sched.generation) return // superseded; stay silent
            Log.w(TAG, "writer: unrecoverable track error: $why")
            bumpGenerationLocked()
            releaseTrackLocked()
            state = if (decoded != null) State.LOADED else State.IDLE
        }
        emitEvent("engineRestarted")
    }

    // ------------------------------------------------------------- AudioTrack

    private fun createTrack(audio: DecodedAudio): AudioTrack {
        val channelMask = when (audio.channels) {
            1 -> AudioFormat.CHANNEL_OUT_MONO
            2 -> AudioFormat.CHANNEL_OUT_STEREO
            else -> throw IllegalArgumentException("unsupported channel count ${audio.channels}")
        }
        val minBuf = AudioTrack.getMinBufferSize(
            audio.sampleRate, channelMask, AudioFormat.ENCODING_PCM_16BIT
        )
        require(minBuf > 0) { "getMinBufferSize failed: $minBuf" }
        // 3× the minimum: underrun headroom for the blocking writer without
        // bloating the pipeline (scheduling precision is timestamp-based and
        // unaffected by buffer depth).
        val bufBytes = minBuf * 3
        val builder = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                    .build()
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setSampleRate(audio.sampleRate)
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setChannelMask(channelMask)
                    .build()
            )
            .setTransferMode(AudioTrack.MODE_STREAM)
            .setBufferSizeInBytes(bufBytes)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            builder.setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY)
        }
        val track = builder.build()
        if (track.state != AudioTrack.STATE_INITIALIZED) {
            track.release()
            throw IllegalStateException("AudioTrack failed to initialize")
        }
        return track
    }

    // ------------------------------------------------------------------ decode

    /**
     * Fully decodes [path] to interleaved 16-bit LE PCM in memory (see the
     * class doc for the memory-cost tradeoff).
     */
    private fun decodeToPcm16(path: String): DecodedAudio {
        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(path)
            var trackIndex = -1
            var format: MediaFormat? = null
            for (i in 0 until extractor.trackCount) {
                val f = extractor.getTrackFormat(i)
                val mime = f.getString(MediaFormat.KEY_MIME) ?: continue
                if (mime.startsWith("audio/")) {
                    trackIndex = i
                    format = f
                    break
                }
            }
            val trackFormat = format
                ?: throw IllegalArgumentException("no audio track in file")
            extractor.selectTrack(trackIndex)
            val mime = trackFormat.getString(MediaFormat.KEY_MIME)!!
            val codec = MediaCodec.createDecoderByType(mime)
            try {
                codec.configure(trackFormat, null, null, 0)
                codec.start()
                var sampleRate = trackFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                var channels = trackFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                var pcmEncoding = AudioFormat.ENCODING_PCM_16BIT
                val out = ByteArrayOutputStream()
                val info = MediaCodec.BufferInfo()
                var inputDone = false
                var outputDone = false
                var idleSpins = 0
                while (!outputDone) {
                    var progressed = false
                    if (!inputDone) {
                        val inIdx = codec.dequeueInputBuffer(10_000)
                        if (inIdx >= 0) {
                            progressed = true
                            val buf = codec.getInputBuffer(inIdx)!!
                            val n = extractor.readSampleData(buf, 0)
                            if (n < 0) {
                                codec.queueInputBuffer(
                                    inIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM
                                )
                                inputDone = true
                            } else {
                                codec.queueInputBuffer(inIdx, 0, n, extractor.sampleTime, 0)
                                extractor.advance()
                            }
                        }
                    }
                    val outIdx = codec.dequeueOutputBuffer(info, 10_000)
                    when {
                        outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                            progressed = true
                            val f = codec.outputFormat
                            sampleRate = f.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                            channels = f.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                            pcmEncoding = if (f.containsKey(MediaFormat.KEY_PCM_ENCODING)) {
                                f.getInteger(MediaFormat.KEY_PCM_ENCODING)
                            } else {
                                AudioFormat.ENCODING_PCM_16BIT
                            }
                        }
                        outIdx >= 0 -> {
                            progressed = true
                            if (info.size > 0) {
                                val buf = codec.getOutputBuffer(outIdx)!!
                                buf.position(info.offset)
                                buf.limit(info.offset + info.size)
                                appendPcm(out, buf, pcmEncoding)
                            }
                            codec.releaseOutputBuffer(outIdx, false)
                            if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                                outputDone = true
                            }
                        }
                    }
                    idleSpins = if (progressed) 0 else idleSpins + 1
                    if (idleSpins > 500) { // ~10 s of no progress: codec wedged
                        throw IllegalStateException("decoder made no progress (stalled)")
                    }
                }
                val pcm = out.toByteArray()
                if (pcm.isEmpty()) throw IllegalArgumentException("decoded zero audio frames")
                if (channels !in 1..2) {
                    throw IllegalArgumentException("unsupported channel count $channels")
                }
                return DecodedAudio(pcm, sampleRate, channels)
            } finally {
                try {
                    codec.stop()
                } catch (_: Throwable) {
                }
                codec.release()
            }
        } finally {
            extractor.release()
        }
    }

    /** Appends one decoder output buffer as 16-bit LE PCM (converting float). */
    private fun appendPcm(out: ByteArrayOutputStream, buf: ByteBuffer, encoding: Int) {
        when (encoding) {
            AudioFormat.ENCODING_PCM_16BIT -> {
                val bytes = ByteArray(buf.remaining())
                buf.get(bytes)
                out.write(bytes)
            }
            AudioFormat.ENCODING_PCM_FLOAT -> {
                val floats = buf.order(ByteOrder.nativeOrder()).asFloatBuffer()
                val scratch = ByteArray(floats.remaining() * 2)
                var o = 0
                while (floats.hasRemaining()) {
                    val v = (floats.get() * 32767.0f).coerceIn(-32768.0f, 32767.0f).toInt()
                    scratch[o++] = (v and 0xff).toByte()
                    scratch[o++] = ((v shr 8) and 0xff).toByte()
                }
                out.write(scratch)
            }
            else -> throw IllegalArgumentException("unsupported decoder PCM encoding $encoding")
        }
    }

    // ------------------------------------------------- focus / route / latency

    private val focusListener = AudioManager.OnAudioFocusChangeListener { change ->
        when (change) {
            AudioManager.AUDIOFOCUS_LOSS, AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> {
                // Mirror iOS: the OS interruption stops playback until
                // interruptionEnded; the Dart side re-schedules from the anchor.
                synchronized(lock) {
                    if (state == State.PLAYING) {
                        try {
                            schedule?.track?.pause()
                        } catch (_: Throwable) {
                        }
                        state = State.PAUSED
                        lock.notifyAll()
                    }
                }
                emitEvent("interruptionBegan")
            }
            AudioManager.AUDIOFOCUS_GAIN -> emitEvent("interruptionEnded")
            // AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK: keep playing at full volume;
            // staying in sync matters more than ducking etiquette for LocalJam.
        }
    }

    /** Requests audio focus for playback (playAt). Denial is non-fatal. */
    private fun requestFocus() {
        val am = audioManager ?: return
        val granted = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val request = focusRequest ?: AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                        .build()
                )
                .setOnAudioFocusChangeListener(focusListener, mainHandler)
                .build()
                .also { focusRequest = it }
            am.requestAudioFocus(request)
        } else {
            @Suppress("DEPRECATION")
            am.requestAudioFocus(
                focusListener, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN
            )
        }
        if (granted != AudioManager.AUDIOFOCUS_REQUEST_GRANTED) {
            Log.w(TAG, "audio focus not granted ($granted); playing anyway")
        }
    }

    private fun abandonFocus() {
        val am = audioManager ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            focusRequest?.let { am.abandonAudioFocusRequest(it) }
        } else {
            @Suppress("DEPRECATION")
            am.abandonAudioFocus(focusListener)
        }
    }

    private fun registerRouteCallback() {
        val am = audioManager ?: return
        val callback = object : AudioDeviceCallback() {
            // Registration immediately fires onAudioDevicesAdded with the
            // CURRENT device list; skip it so no spurious routeChanged lands.
            private var initial = true

            override fun onAudioDevicesAdded(added: Array<out AudioDeviceInfo>) {
                if (initial) {
                    initial = false
                    return
                }
                if (added.any { it.isSink }) {
                    emitEvent("routeChanged", currentOutputLatencyUs())
                }
            }

            override fun onAudioDevicesRemoved(removed: Array<out AudioDeviceInfo>) {
                if (removed.any { it.isSink }) {
                    emitEvent("routeChanged", currentOutputLatencyUs())
                }
            }
        }
        am.registerAudioDeviceCallback(callback, mainHandler)
        deviceCallback = callback
    }

    private fun unregisterRouteCallback() {
        deviceCallback?.let { audioManager?.unregisterAudioDeviceCallback(it) }
        deviceCallback = null
    }

    /**
     * Best-effort platform output latency (§7). Android has no public API;
     * some devices honor this hidden AudioManager property (milliseconds).
     * 0 = unknown, which is fine: getTimestamp-based scheduling already
     * includes the full pipeline latency, so this is only the calibration
     * starting point for the manual nudge.
     */
    private fun currentOutputLatencyUs(): Long {
        val ms = audioManager
            ?.getProperty("android.media.property.OUTPUT_LATENCY")
            ?.toDoubleOrNull()
            ?: return 0
        if (!ms.isFinite() || ms < 0) return 0
        return (ms * 1000).roundToLong()
    }
}
