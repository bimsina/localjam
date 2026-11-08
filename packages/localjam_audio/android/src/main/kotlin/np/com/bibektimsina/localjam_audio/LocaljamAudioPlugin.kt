package np.com.bibektimsina.localjam_audio

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
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
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.Executor
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToLong

private const val LOG_TAG = "LocaljamAudio"

/** MediaFormat.KEY_ENCODER_DELAY / _PADDING (constants are API 30; the keys are older). */
private const val KEY_ENCODER_DELAY = "encoder-delay"
private const val KEY_ENCODER_PADDING = "encoder-padding"

/**
 * How long [LocaljamAudioPlugin] waits for threads to leave the native
 * AudioTrack before releasing it. The pause()/flush() that precedes the wait
 * unblocks a WRITE_BLOCKING writer immediately, so in practice this expires
 * only on a wedged HAL — where releasing anyway (and letting the guarded call
 * site catch the IllegalStateException) beats hanging the teardown.
 */
private const val TRACK_DRAIN_WAIT_NS = 200_000_000L

/**
 * Lifetime guard for one native [AudioTrack] handle — the fix for
 * "IllegalStateException: Unable to retrieve AudioTrack pointer for write()".
 *
 * ## The race
 * Every AudioTrack call the writer thread makes — above all the
 * WRITE_BLOCKING `write` — can block for as long as the sink takes to drain,
 * and blocks FOREVER on a paused track. Holding the plugin's state lock across
 * it would hang every method-channel handler, so the writer necessarily calls
 * the track with no lock held. That is the bug: the writer's staleness check
 * releases the lock, an End-jam teardown takes it, releases the track, and the
 * writer's next `write` lands on a freed native handle.
 *
 * ## The guard
 * A caller registers itself in [use] and is refused once [release] has run;
 * [release] sets that flag FIRST, then pause()/flush()es (which interrupts an
 * in-flight blocking write so its caller returns promptly), then waits for the
 * registered callers to leave, and only then frees the handle. So teardown
 * never blocks behind a long write, and a write never reaches a freed handle.
 * [IllegalStateException] is still caught in [use] as defense in depth: a HAL
 * can kill a track on its own, and the wait above is bounded.
 *
 * This monitor is a LEAF: it may be taken while holding the plugin lock, never
 * the other way round, and nothing running inside [use] takes the plugin lock.
 */
internal class AudioTrackGate(private val track: AudioTrack) {
    // java.lang.Object, not kotlin.Any: the monitor needs wait()/notifyAll(),
    // which Any does not expose (same for the plugin's other two monitors).
    @Suppress("PLATFORM_CLASS_MAPPED_TO_KOTLIN")
    private val gate = Object()
    private var released = false
    private var users = 0

    /** Whether the handle is gone — callers must give up, not retry. */
    val isReleased: Boolean get() = synchronized(gate) { released }

    /** Test seam: how many callers are inside the track right now. */
    internal val activeUsers: Int get() = synchronized(gate) { users }

    /**
     * Runs [op] on a track guaranteed not to be freed underneath it. Returns
     * null when the track is already released (give up) or when the call threw
     * [IllegalStateException] anyway. Any other throwable propagates — that is
     * a real, reportable track failure.
     */
    fun <T> use(op: (AudioTrack) -> T): T? {
        synchronized(gate) {
            if (released) return null
            users += 1
        }
        try {
            return op(track)
        } catch (e: IllegalStateException) {
            Log.w(LOG_TAG, "AudioTrack call on a dead track", e)
            return null
        } finally {
            synchronized(gate) {
                users -= 1
                gate.notifyAll()
            }
        }
    }

    /**
     * Frees the handle exactly once, after every [use] caller has left it.
     * Idempotent, so the Dart teardown order (session guards → plugin
     * `dispose`) can never double-release: a second call returns at the flag
     * check without touching the freed handle.
     */
    fun release() {
        synchronized(gate) {
            if (released) return
            released = true // no new caller can enter from here on
        }
        // Interrupt an in-flight WRITE_BLOCKING so its caller returns and
        // deregisters (AudioTrack::pause/flush interrupt the buffer proxy);
        // without this a paused track would never drain and the wait below
        // would always time out.
        try {
            track.pause()
            track.flush()
        } catch (_: Throwable) {
        }
        synchronized(gate) {
            val deadline = System.nanoTime() + TRACK_DRAIN_WAIT_NS
            while (users > 0) {
                val remainMs = (deadline - System.nanoTime()) / 1_000_000L
                if (remainMs <= 0) break
                try {
                    gate.wait(remainMs)
                } catch (_: InterruptedException) {
                }
            }
            if (users > 0) {
                Log.w(
                    LOG_TAG,
                    "releasing AudioTrack with $users caller(s) still inside it " +
                        "(wedged HAL); the guarded call site will catch the throw"
                )
            }
        }
        try {
            track.release()
        } catch (_: Throwable) {
        }
    }
}

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
 * thread with blocking writes; a decoder thread (see "Streaming decode")
 * produces the PCM the writer consumes. Deviation from "one long-lived
 * track": the track is *recreated on every schedule* (playAt/stop/load),
 * because the epoch of AudioTimestamp.framePosition after stop()/flush() is
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
 * ## Streaming decode (replaces the v1 full-decode-in-RAM)
 * 'load' only *probes* the file: MediaExtractor for the container format and
 * duration metadata, plus a bounded MediaCodec probe that decodes at most the
 * first output buffer to learn the decoder's TRUE output format (HE-AAC
 * containers under-report the sample rate 2×; frame math at the wrong rate
 * would wreck every µs anchor in this file). No PCM is retained; 'load'
 * returns in milliseconds regardless of file length.
 *
 * Duration accuracy contract: the value 'load' returns is METADATA-derived —
 * MediaFormat.KEY_DURATION, falling back to MediaMetadataRetriever, last
 * resort a compressed-packet pts scan (no decode; a full decode-count is
 * deliberately avoided). It can differ from the true decoded length by up to
 * a codec frame (~26 ms for mp3) plus encoder padding. End of playback is
 * detected by decoder EOS, never by this number; it is only used for
 * position clamping and playAt range checks.
 *
 * Each playAt starts its OWN decoder thread (fresh MediaExtractor +
 * MediaCodec, generation-tagged exactly like the writer) which produces
 * 16-bit interleaved PCM into a bounded [PcmQueue] the writer consumes.
 * Memory target: O(queue cap) — [QUEUE_TARGET_SECONDS] (8 s) of PCM,
 * hard-capped at [QUEUE_MAX_BYTES] (4 MB) — independent of file length
 * (v1 held the whole file: ~10.6 MB per stereo 44.1 kHz minute).
 *
 * Seek / frame accuracy: media frame P is the GAPLESS frame P — encoder
 * delay (AAC priming from `elst`/iTunSMPB, the LAME tag's delay) excluded —
 * the same sample AVAudioFile and the browser's decodeAudioData call P
 * ([GaplessTimeline] has the why and the measurements). The codec is
 * configured with the platform's own delay/padding trim OFF (it trims from
 * wherever decoding starts and decouples pts from the PCM), so output pts
 * describe their PCM and [GaplessTimeline.frameAt] maps them to media
 * frames. Container files seek the extractor
 * [GaplessTimeline.SEEK_PREROLL_US] before the
 * target (or not at all near the start) with SEEK_TO_PREVIOUS_SYNC; MP3s are
 * fed from an [Mp3FrameIndex] (MediaExtractor's MP3 seeks are not
 * frame-exact) starting a few frames early for the bit reservoir. A
 * [PcmTrimmer] then drops the pre-roll, fills silence in the (should-not-
 * happen) case that decoding resumed past the target, and withholds the
 * trailing padding — so the first frame the writer streams is media frame
 * startFrame exactly.
 *
 * The silence-priming path needs no PCM: the decoder starts at playAt entry
 * and runs in parallel with priming (≥ MIN_LEAD_US), so the queue already
 * holds decoded audio when the writer reaches the media phase. Pause = the
 * writer parks, the queue fills, the decoder blocks on the full queue
 * (natural backpressure) — resume is playAt (a new generation retires BOTH
 * threads).
 *
 * ## Failures off the method-call path ([ScheduleFailure])
 * A decode error (extractor/codec exception, a stalled decoder, a format
 * change) stops output and reports `playbackError{decode_failed}`: a new
 * schedule would decode the same bytes and fail again, and engineRestarted
 * would make the Dart engine re-apply in a loop. Only a track that died
 * under a healthy schedule (dead handle, ERROR_DEAD_OBJECT) is
 * engineRestarted — a fresh track fixes that — and only until it happens
 * several times in a row without any media playing in between. Every other
 * writer failure is `playbackError{writer_failed}`.
 *
 * ## outputLatencyUs
 * Always 0 ([OutputLatency.SCHEDULING_US]): getTimestamp-based scheduling
 * already includes the full pipeline latency (the HAL timestamps the frame
 * *presented at the output*), so the frame scheduled for nativeTimeUs is
 * heard at nativeTimeUs — and `outputLatencyUs` is, on every platform, how
 * much later than nativeTimeUs it is heard (Dart subtracts it from anchors).
 * The hidden "android.media.property.OUTPUT_LATENCY" AudioManager property
 * some devices honor is read for diagnostics only (`debugLatencyInfo`).
 *
 * ## Interruptions, unplugs and routes (localjam_audio contract items 2–5)
 * Native output is only ever STOPPED by the OS-driven paths — audio focus
 * loss, a call taking the audio mode, ACTION_AUDIO_BECOMING_NOISY / removal
 * of the active output, a writer failure — and never restarted: the room
 * timeline moved on meanwhile, so Dart re-anchors with playAt. Each path
 * stops output FIRST and only then emits its event. The decisions live in
 * pure, unit-tested classes ([PlaybackSupervisor] over [AudioFocusPolicy]
 * and [RouteChangeTracker]); this class only feeds them platform signals and
 * applies their effects. playAt itself is gated: no play during a call,
 * without audio focus, or in the ~1 s between "becoming noisy" and the
 * reroute to the speaker — each refusal completes playAt normally and
 * re-emits the event that explains it — and a playAt overtaken by any of
 * those stops mid-flight (generation check) completes without playing.
 * Focus is requested only when not already held (re-requesting would hand
 * a ducking navigation prompt AUDIOFOCUS_LOSS).
 *
 * After `dispose` the plugin is dormant — platform listeners unregistered,
 * nothing emitted — until the next method call re-arms it (a new
 * LocaljamAudio on the same channel).
 *
 * `probeDuration` reads the same metadata chain as 'load' ([DurationProbe])
 * on its own small executor, never touching the engine, and answers null
 * for exactly the files 'load' would refuse on metadata grounds.
 *
 * ## Threading
 * Method-channel handlers run serialized on one background HandlerThread
 * (except `probeDuration`, see above); every handler posts its result back
 * to the main thread exactly once.
 * The writer thread AND the decoder thread (one pair per schedule, both
 * tagged with a generation counter à la iOS scheduleGeneration) are separate.
 * All shared state is guarded by [lock]; the PCM queue has its own internal
 * monitor and is retired (both sides unblocked) whenever the schedule is
 * released. Events are delivered on the main thread.
 *
 * The native AudioTrack handle has a THIRD monitor of its own — the gate in
 * [Schedule.useTrack] / [Schedule.releaseTrack] — because the writer's
 * blocking calls cannot be made under [lock]. Lock order is strictly
 * lock → queue / trackGate; nothing running inside a gate takes [lock].
 */
class LocaljamAudioPlugin :
    FlutterPlugin,
    MethodCallHandler,
    EventChannel.StreamHandler {
    private companion object {
        const val TAG = LOG_TAG

        /**
         * Minimum achievable scheduling lead (µs): track creation + timestamp
         * warm-up + safety margin. Anchors closer than this are re-anchored
         * to now + MIN_LEAD_US (mirrors iOS minLeadUs).
         */
        const val MIN_LEAD_US = 150_000L

        /**
         * Track volume while another app holds "may duck" focus (API 24–25;
         * API 26+ ducks for us). −14 dB: clearly under a navigation prompt.
         */
        const val DUCK_VOLUME = 0.2f

        /** Give getTimestamp this long to become valid before falling back. */
        const val TIMESTAMP_WARMUP_NS = 1_000_000_000L

        /**
         * Decoded-PCM queue sizing: the queue holds up to QUEUE_TARGET_SECONDS
         * of audio, byte-capped at QUEUE_MAX_BYTES. This IS the memory target
         * of the streaming design: peak decoded-audio memory per schedule is
         * min(8 s × sampleRate × bytesPerFrame, 4 MB) — ~1.4 MB for stereo
         * 44.1 kHz — independent of file length.
         */
        const val QUEUE_TARGET_SECONDS = 8
        const val QUEUE_MAX_BYTES = 4 * 1024 * 1024

        /** Current native monotonic time in µs. */
        fun nowUs(): Long = System.nanoTime() / 1000
    }

    private enum class State { IDLE, LOADED, PLAYING, PAUSED, FINISHED }

    /**
     * A loaded (probed, NOT decoded) file — see "Streaming decode" in the
     * class doc. [sampleRate]/[srcChannels] are the decoder's true OUTPUT
     * format (probed), [durationUs] is metadata-derived (accuracy contract in
     * the class doc). [channels] is what the AudioTrack plays: the decoder's
     * channels, except that >2 are folded down to stereo ([StereoFolder]).
     */
    private class LoadedAudio(
        val path: String,
        val mime: String,
        val sampleRate: Int,
        val srcChannels: Int,
        /** Decoder output KEY_CHANNEL_MASK when it reported one. */
        val srcChannelMask: Int?,
        val durationUs: Long,
        /** How decoder pts map to gapless media frames ([GaplessTimeline]). */
        val timeline: GaplessTimeline,
        /** Frame index of an MP3 (frame-exact seeks), else null: MediaExtractor. */
        val mp3: Mp3FrameIndex?
    ) {
        val channels get() = min(srcChannels, 2)

        val bytesPerFrame get() = 2 * channels

        /** Metadata-derived frame count; range checks only, never EOS. */
        val totalFrames get() = durationUs * sampleRate / 1_000_000L
    }

    /**
     * Bounded producer-consumer PCM queue between the decoder thread (push)
     * and the writer thread (pop). Frame-aligned byte chunks; capacity is
     * byte-capped (see [QUEUE_TARGET_SECONDS]/[QUEUE_MAX_BYTES]). Its own
     * monitor — never touched while holding the plugin [lock] — and a
     * [retire] switch that unblocks both sides when the schedule dies.
     */
    private class PcmQueue(private val capBytes: Int) {
        companion object {
            const val POP_EOS = -1
            const val POP_ERROR = -2
            const val POP_RETIRED = -3
        }

        @Suppress("PLATFORM_CLASS_MAPPED_TO_KOTLIN") // wait()/notifyAll() monitor
        private val qlock = Object()
        private val chunks = ArrayDeque<ByteArray>()
        private var bytes = 0
        private var headOffset = 0
        private var eos = false
        private var retired = false

        var error: String? = null
            private set

        /** Blocks while full. False once retired (caller must exit). */
        fun push(chunk: ByteArray): Boolean {
            synchronized(qlock) {
                while (!retired && bytes >= capBytes) {
                    try {
                        qlock.wait()
                    } catch (_: InterruptedException) {
                    }
                }
                if (retired) return false
                chunks.addLast(chunk)
                bytes += chunk.size
                qlock.notifyAll()
                return true
            }
        }

        /** Producer reached end of stream cleanly. */
        fun close() {
            synchronized(qlock) {
                eos = true
                qlock.notifyAll()
            }
        }

        /**
         * Producer failed. The decoder reports the failure itself
         * (playbackError{decode_failed}); this only makes sure a writer that
         * pops first stops instead of playing out the buffered tail.
         */
        fun fail(msg: String) {
            synchronized(qlock) {
                if (error == null) error = msg
                eos = true
                qlock.notifyAll()
            }
        }

        /** Unblocks both sides permanently (schedule retired). */
        fun retire() {
            synchronized(qlock) {
                retired = true
                qlock.notifyAll()
            }
        }

        /**
         * Copies up to dst.size queued bytes into dst. Returns the byte count
         * (> 0), 0 on timeout (caller re-checks staleness), or POP_EOS /
         * POP_ERROR / POP_RETIRED. An error is reported before any remaining
         * buffered audio: a broken decode must stop the schedule, not play
         * out its tail.
         */
        fun pop(dst: ByteArray, timeoutMs: Long): Int {
            synchronized(qlock) {
                val deadlineNs = System.nanoTime() + timeoutMs * 1_000_000L
                while (true) {
                    if (retired) return POP_RETIRED
                    if (error != null) return POP_ERROR
                    if (bytes > 0) break
                    if (eos) return POP_EOS
                    val remainMs = (deadlineNs - System.nanoTime()) / 1_000_000L
                    if (remainMs <= 0) return 0
                    try {
                        qlock.wait(remainMs)
                    } catch (_: InterruptedException) {
                    }
                }
                var copied = 0
                while (copied < dst.size && chunks.isNotEmpty()) {
                    val head = chunks.first()
                    val n = min(head.size - headOffset, dst.size - copied)
                    System.arraycopy(head, headOffset, dst, copied, n)
                    copied += n
                    headOffset += n
                    bytes -= n
                    if (headOffset == head.size) {
                        chunks.removeFirst()
                        headOffset = 0
                    }
                }
                qlock.notifyAll()
                return copied
            }
        }
    }

    /**
     * One playAt schedule. Immutable identity + mutable position-mapping
     * fields; ALL fields are guarded by [lock] except where noted in the
     * writer, which snapshots under the lock, [queue], which has its own
     * monitor, and the native track, which has its own gate (see [useTrack]).
     *
     * ## Why the track needs its own gate rather than [lock]
     * Every AudioTrack call the writer makes — above all the WRITE_BLOCKING
     * `write` — can block for as long as the sink takes to drain, and blocks
     * FOREVER on a paused track. Holding [lock] across it would hang every
     * method-channel handler, so the writer necessarily calls the track with
     * no lock held. That is the whole bug: `isStale()` releases [lock], the
     * teardown path takes it, releases the track, and the writer's next
     * `write` lands on a freed native handle — "IllegalStateException: Unable
     * to retrieve AudioTrack pointer for write()".
     *
     * The gate closes it without ever blocking teardown behind a long write:
     * a caller registers itself under [trackGate] and is refused once
     * [trackReleased] is set, and [releaseTrack] sets that flag, *then*
     * pause()/flush()es (which interrupts an in-flight blocking write so it
     * returns promptly), then waits for the registered callers to leave, and
     * only then frees the handle. [trackGate] is a leaf monitor — it is taken
     * while holding [lock] but never the other way round, and [useTrack]
     * bodies never take [lock] — so the two cannot deadlock.
     */
    private class Schedule(
        val generation: Long,
        /** Owned by [gate] from here on; nothing else may touch it. */
        track: AudioTrack,
        val sampleRate: Int,
        val channels: Int,
        /** Effective anchor instant, native ns (already ≥ now + MIN_LEAD). */
        val targetNs: Long,
        /** Media position (µs, frame-exact) at the anchor — 'P'. */
        val anchorMediaUs: Long,
        /** First media frame of the segment (before any overshoot trim). */
        val startFrame: Long,
        /** Decoder → writer PCM hand-off (bounded; see class doc). */
        val queue: PcmQueue,
        var rate: Double,
        /**
         * Total silence frames 'S' — meaningful once [refValid] (the priming
         * timestamp landed). Can be NEGATIVE: see [PlaybackLimits.silenceFrames].
         */
        var silenceFrames: Long = 0L,
        /** Freshest source-frame ↔ CLOCK_MONOTONIC mapping for extrapolation. */
        var refFrame: Double = 0.0,
        var refNanos: Long = 0L,
        var refValid: Boolean = false
    ) {
        private val gate = AudioTrackGate(track)

        /** Whether the native track is gone (writers must exit, not retry). */
        val isTrackReleased: Boolean get() = gate.isReleased

        /**
         * The ONLY way to touch the native track; see [AudioTrackGate.use].
         * MUST NOT be called with a body that takes [LocaljamAudioPlugin.lock]
         * (see the lock order in the class doc).
         */
        fun <T> useTrack(op: (AudioTrack) -> T): T? = gate.use(op)

        /** Frees the native track once every writer has left it; idempotent. */
        fun releaseTrack() = gate.release()
    }

    private lateinit var channel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private var keepAliveChannel: MethodChannel? = null
    private var mediaSessionChannel: MethodChannel? = null
    private var mediaLibrary: JamMediaLibrary? = null
    private var appContext: Context? = null
    private var audioManager: AudioManager? = null

    private val mainHandler = Handler(Looper.getMainLooper())
    private var handlerThread: HandlerThread? = null
    private var bgHandler: Handler? = null

    /** Dart-side event sink; touched on the main thread only. */
    private var eventSink: EventChannel.EventSink? = null

    /** Guards every field below (and Schedule mutables). */
    @Suppress("PLATFORM_CLASS_MAPPED_TO_KOTLIN") // wait()/notifyAll() monitor
    private val lock = Object()
    private var state = State.IDLE
    private var loaded: LoadedAudio? = null
    private var schedule: Schedule? = null

    /**
     * Schedule generations (bumped on every (re)schedule/stop/load/dispose and
     * every OS-driven stop, so stale writer AND decoder threads, their
     * completion signals and overtaken playAts are ignored — iOS
     * scheduleGeneration), the interruption policy (contract item 4), route
     * decisions (items 2–3) and failure reporting (item 5). Guarded by [lock].
     */
    private val supervisor = PlaybackSupervisor()

    /** Shorthand: the supervisor's focus policy (guarded by [lock]). */
    private val focusPolicy get() = supervisor.focus

    /**
     * Learned once per process: this output's low-latency (FAST) tracks
     * refuse a playback speed, so later tracks are created without asking
     * for low latency (see [TrackSpeed]). Handler thread only.
     */
    @Volatile private var lowLatencyRefusesSpeed = false

    @Volatile private var focusRequest: AudioFocusRequest? = null

    /**
     * True between `dispose` and the next method call: platform listeners are
     * unregistered and [emit] drops everything (events after dispose).
     */
    @Volatile private var dormant = false

    /** Guards the registration state of the three platform listeners below. */
    private val listenerLock = Any()
    private var listenersDetached = false
    private var deviceCallback: AudioDeviceCallback? = null
    private var noisyReceiver: BroadcastReceiver? = null

    /** AudioManager.OnModeChangedListener (API 31+), typed loosely for API 24. */
    private var modeListener: Any? = null

    /**
     * Runs `probeDuration` calls — NOT the serialized handler thread, so a
     * slow probe (packet scan of a long file) never delays playAt/positionUs,
     * and probes run concurrently with each other and with playback.
     */
    private var probeExecutor: ExecutorService? = null

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
        probeExecutor = Executors.newFixedThreadPool(2) { runnable ->
            Thread(runnable, "localjam_audio-probe").apply { isDaemon = true }
        }
        registerPlatformListeners()

        // Device music library (JamMediaLibrary.kt).
        mediaLibrary = JamMediaLibrary(binding.applicationContext, binding.binaryMessenger)

        // Session keep-alive + OS media session (JamSession.kt). The
        // keep-alive channel keeps the pre-existing `localjam/keepalive`
        // contract of package:localjam_client's JamKeepAlive.
        JamMediaSessionManager.attach(binding.applicationContext)
        // Teardown ordering: the keep-alive `release` (Dart's
        // stopSessionGuards) runs BEFORE the engine's `player.dispose()`, so
        // without this hook the foreground service would be stopped while the
        // writer thread is still feeding the track. Release the track first;
        // the later `dispose` is then a no-op (the schedule is already gone
        // and Schedule.releaseTrack is idempotent — no double-release).
        JamMediaSessionManager.onSessionEnding = { stopPlaybackForSessionEnd() }
        keepAliveChannel = MethodChannel(binding.binaryMessenger, "localjam/keepalive").apply {
            JamMediaSessionManager.keepAliveChannel = this
            setMethodCallHandler { call, result ->
                when (call.method) {
                    // `acquire` answers whether the OS accepted the start;
                    // a later refusal inside the service arrives as the
                    // `keepAliveLost` call on this same channel.
                    "acquire" -> result.success(JamMediaSessionManager.acquire())
                    "release" -> {
                        JamMediaSessionManager.release()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
        mediaSessionChannel =
            MethodChannel(binding.binaryMessenger, "localjam_audio/media_session").apply {
                JamMediaSessionManager.channel = this
                setMethodCallHandler { call, result ->
                    when (call.method) {
                        "update" -> {
                            val args = call.arguments
                            if (args is Map<*, *>) JamMediaSessionManager.update(args)
                            result.success(null)
                        }
                        "clear" -> {
                            JamMediaSessionManager.clear()
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                }
            }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        if (JamMediaSessionManager.keepAliveChannel === keepAliveChannel) {
            JamMediaSessionManager.keepAliveChannel = null
        }
        keepAliveChannel?.setMethodCallHandler(null)
        keepAliveChannel = null
        if (JamMediaSessionManager.channel === mediaSessionChannel) {
            JamMediaSessionManager.channel = null
        }
        JamMediaSessionManager.onSessionEnding = null
        mediaSessionChannel?.setMethodCallHandler(null)
        mediaSessionChannel = null
        JamMediaSessionManager.dispose()
        mediaLibrary?.dispose()
        mediaLibrary = null
        synchronized(lock) {
            supervisor.onReleased()
            lock.notifyAll()
            releaseTrackLocked()
            loaded = null
            state = State.IDLE
        }
        abandonFocus()
        dormant = true
        unregisterPlatformListeners(detaching = true)
        // Probes still queued would never run: answer them, so no Dart
        // future is left hanging (a running probe answers by itself).
        probeExecutor?.shutdownNow()?.forEach { (it as? ProbeTask)?.reject() }
        probeExecutor = null
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
     * Emits one event payload (built by [AudioEvents]) to Dart. Callable from
     * any thread — including with [lock] held: it only posts. Delivery is
     * always on the main thread (the EventSink threading contract), in post
     * order.
     */
    private fun emit(payload: Map<String, Any>) {
        if (dormant) return // disposed: nobody asked for events any more
        mainHandler.post {
            val sink = eventSink ?: return@post
            sink.success(payload)
        }
    }

    private fun emitEvent(type: String) = emit(AudioEvents.simple(type))

    // --------------------------------------------------------- method channel

    override fun onMethodCall(call: MethodCall, result: Result) {
        val handler = bgHandler
        if (handler == null) {
            result.error("disposed", "plugin detached", null)
            return
        }
        if (call.method == "probeDuration") {
            // Deliberately NOT on the serialized handler thread (see
            // probeExecutor): a probe must never queue behind, or delay, the
            // playback calls.
            handleProbeDuration(call, result)
            return
        }
        // All handlers run serialized on the background thread (like iOS's
        // serial queue); `reply` marshals back to the platform thread and is
        // called exactly once per invocation.
        handler.post {
            try {
                // A call after `dispose` is a new LocaljamAudio on the same
                // channel: re-arm the listeners and events dispose shut off.
                if (dormant && call.method != "dispose") wake()
                when (call.method) {
                    "nowUs" -> replySuccess(result, nowUs())
                    "load" -> handleLoad(call, result)
                    "playAt" -> handlePlayAt(call, result)
                    "pause" -> handlePause(result)
                    "stop" -> handleStop(result)
                    "positionUs" -> handlePositionUs(call, result)
                    "setRate" -> handleSetRate(call, result)
                    "outputLatencyUs" -> replySuccess(result, OutputLatency.SCHEDULING_US)
                    "debugLatencyInfo" -> replySuccess(result, latencyInfo())
                    "currentRouteId" -> replySuccess(result, currentRoute()?.id)
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

    /**
     * `probeDuration {path}` → µs or null (contract item 1). The duration a
     * `load` of the same file would return, read without touching the
     * engine, the loaded file, the play state or audio focus — adding a track
     * mid-song used to `load` it on the shared player, which stops playback.
     */
    private fun handleProbeDuration(call: MethodCall, result: Result) {
        val path = call.argument<String>("path")
        if (path == null) {
            result.error("bad_args", "probeDuration requires {path: String}", null)
            return
        }
        val executor = probeExecutor
        if (executor == null) {
            result.error("disposed", "plugin detached", null)
            return
        }
        try {
            executor.execute(ProbeTask(path, result))
        } catch (e: Throwable) {
            // RejectedExecutionException: detached while the call was in flight.
            result.error("disposed", "plugin detached", null)
        }
    }

    /**
     * One `probeDuration` call. A named Runnable so that detaching, which
     * drops queued tasks (`shutdownNow`), can still answer each of them.
     * Answers exactly once either way.
     */
    private inner class ProbeTask(val path: String, val result: Result) : Runnable {
        private val answered = java.util.concurrent.atomic.AtomicBoolean(false)

        override fun run() {
            runGuarded({
                val us = DurationProbe.probeDurationUs(path)
                if (answered.compareAndSet(false, true)) replySuccess(result, us)
            }) {
                // probeDurationUs never throws; if it ever did: "unknown".
                if (answered.compareAndSet(false, true)) replySuccess(result, null)
            }
        }

        fun reject() {
            if (answered.compareAndSet(false, true)) {
                replyError(result, "disposed", "plugin detached before the probe ran")
            }
        }
    }

    private fun handleLoad(call: MethodCall, result: Result) {
        val path = call.argument<String>("path")
        if (path == null) {
            replyError(result, "bad_args", "load requires {path: String}")
            return
        }
        // Replace any previously loaded file; stop playback first, and forget
        // the old file BEFORE probing the new one, so a failed load leaves
        // nothing loaded (never the previous track under the new name).
        synchronized(lock) {
            supervisor.onLoad()
            lock.notifyAll()
            releaseTrackLocked()
            state = State.IDLE
            loaded = null
        }
        val audio: LoadedAudio
        try {
            audio = probeAudio(path)
        } catch (e: Throwable) {
            replyError(result, "load_failed", "Could not open audio file at $path: $e")
            return
        }
        Log.d(
            TAG,
            "load: $path -> ${audio.durationUs} us (metadata-derived) @ " +
                "${audio.sampleRate} Hz x${audio.channels}ch, streaming decode"
        )
        synchronized(lock) {
            loaded = audio
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
        // Same bounds as iOS/macOS/desktop ([PlaybackLimits]); refused before
        // anything is stopped, like there.
        PlaybackLimits.playAtArgsProblem(nativeTimeUs, rate, nowUs())?.let {
            replyError(result, "bad_args", it)
            return
        }

        val audio: LoadedAudio
        val ticket: PlaybackSupervisor.PlayAtTicket
        synchronized(lock) {
            val a = loaded
            if (a == null) {
                replyError(result, "no_file", "playAt before load")
                return
            }
            audio = a
            // Calling while already playing/scheduled: retire the old schedule
            // (generation bump makes its writer AND decoder exit; release +
            // queue retire unblock them).
            ticket = supervisor.beginPlayAt()
            lock.notifyAll()
            releaseTrackLocked()
            state = State.LOADED // until the new schedule is installed below
        }

        // Never an uncontrolled "ASAP" start: a late anchor is re-anchored
        // minLead into the future with the position advanced at ×rate (§5.3
        // late join), so the priming loop lands the start precisely.
        val now = nowUs()
        val sr = audio.sampleRate
        val plan = PlaybackLimits.planStart(
            nativeTimeUs, positionUs, rate, now, MIN_LEAD_US, sr, audio.totalFrames
        )
        if (plan == null) {
            replyError(
                result,
                "bad_position",
                "start position for positionUs=$positionUs at nativeTimeUs=$nativeTimeUs " +
                    "is outside the file (duration ${audio.durationUs}us)"
            )
            return
        }

        // Gates that keep output off (contract items 3–4). Each completes
        // playAt NORMALLY without playing and (re-)emits the event that says
        // why — this playAt may be the user pressing resume, and Dart must
        // not believe it plays. Dart re-anchors with playAt later.
        val hold = synchronized(lock) { supervisor.playbackHold(System.nanoTime()) }
        if (hold != null) {
            // ACTION_AUDIO_BECOMING_NOISY just fired: the output is about to
            // vanish and media would reroute to the speaker within ~1 s.
            Log.i(TAG, "playAt held back: the output device is going away")
            emit(AudioEvents.routeChanged(OutputLatency.SCHEDULING_US, hold.routeId, true))
            replySuccess(result, null)
            return
        }
        if (!negotiateFocusForPlay(ticket)) {
            replySuccess(result, null)
            return
        }

        val opened: TrackSpeed.Opened<AudioTrack>?
        try {
            opened = TrackSpeed.openAtRate(
                rate,
                preferLowLatency = !lowLatencyRefusesSpeed,
                create = { lowLatency -> createTrack(audio, lowLatency, rate) },
                applySpeed = TrackSpeed::apply,
                isLowLatency = ::isLowLatencyTrack,
                release = { t -> releaseQuietly(t) },
            )
        } catch (e: Throwable) {
            replyError(result, "engine_start_failed", "AudioTrack creation failed: $e")
            return
        }
        if (opened == null) {
            // Playing at 1.0 while the math assumed ×rate would silently
            // mis-time the start and every position after it.
            replyError(
                result, "bad_args", "playAt rate $rate is not supported by this audio output"
            )
            return
        }
        if (opened.lowLatencyRefusedSpeed) {
            Log.w(TAG, "low-latency tracks refuse playback speed here; using normal tracks")
            lowLatencyRefusesSpeed = true
        }
        val track = opened.track

        val queueCapBytes =
            min(QUEUE_TARGET_SECONDS * sr * audio.bytesPerFrame, QUEUE_MAX_BYTES)
        val sched: Schedule
        synchronized(lock) {
            if (!supervisor.mayInstall(ticket)) {
                // Something stopped output while this playAt was in flight
                // (focus loss, call, noisy, session end — none of them run
                // on this handler thread). Starting now would undo it; that
                // path already emitted its event.
                Log.i(TAG, "playAt superseded while starting (output was stopped); not playing")
                releaseQuietly(track)
                replySuccess(result, null)
                return
            }
            if (focusPolicy.ducked) {
                try {
                    track.setVolume(DUCK_VOLUME)
                } catch (_: Throwable) {
                }
            }
            sched = Schedule(
                generation = ticket.generation,
                track = track,
                sampleRate = sr,
                channels = audio.channels,
                targetNs = plan.anchorUs * 1000,
                anchorMediaUs = plan.anchorMediaUs,
                startFrame = plan.startFrame,
                queue = PcmQueue(queueCapBytes),
                rate = rate
            )
            schedule = sched
            state = State.PLAYING
        }
        Log.d(
            TAG,
            "playAt: requested nativeTimeUs=$nativeTimeUs positionUs=$positionUs rate=$rate " +
                "-> effective anchorUs=${plan.anchorUs} startPosUs=${plan.startPosUs} " +
                "startFrame=${plan.startFrame} anchorMediaUs=${plan.anchorMediaUs} " +
                "(now=$now leadUs=${plan.anchorUs - now})"
        )
        // Decoder starts NOW, in parallel with the writer's silence priming
        // (≥ MIN_LEAD_US), so the queue holds PCM before the media phase.
        Thread({ decoderMain(sched, audio) }, "localjam_audio-decoder").start()
        Thread({ writerMain(sched, audio) }, "localjam_audio-writer").start()
        // Remember where this output went: the reference an unplug or
        // removal is compared against (RouteChangeTracker).
        val route = currentRoute()
        synchronized(lock) { supervisor.routes.observe(route) }
        replySuccess(result, null)
    }

    private fun releaseQuietly(track: AudioTrack) {
        try {
            track.release()
        } catch (_: Throwable) {
        }
    }

    /** Whether [track] was actually granted the low-latency (FAST) path. */
    private fun isLowLatencyTrack(track: AudioTrack): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            track.performanceMode == AudioTrack.PERFORMANCE_MODE_LOW_LATENCY

    private fun handlePause(result: Result) {
        synchronized(lock) {
            if (state == State.PLAYING) {
                try {
                    // Gated: a released track is a no-op, never a throw.
                    schedule?.useTrack { it.pause() }
                } catch (e: Throwable) {
                    Log.w(TAG, "pause failed", e)
                }
                // The writer parks; the decoder then blocks on the full queue
                // (backpressure) — both effectively paused. Resume is playAt.
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
            state = if (loaded != null) State.LOADED else State.IDLE
        }
        replySuccess(result, null)
    }

    /**
     * `positionUs {withTime?}`: the heard position, or null when nothing is
     * playing or scheduled. With `withTime: true` the answer is
     * `{positionUs, nativeTimeUs}` — the native instant the position was
     * computed for — so the caller compares it with the room's position at
     * that instant rather than after the reply's trip back (Dart side:
     * `LocaljamAudio.positionSample`).
     */
    private fun handlePositionUs(call: MethodCall, result: Result) {
        val withTime = call.argument<Boolean>("withTime") == true
        // Contract: null when nothing is playing or scheduled (paused/finished
        // included — matching iOS's `guard state == .playing`).
        var sampledNs = 0L
        val value: Long? = synchronized(lock) {
            val sched = schedule
            if (state != State.PLAYING || sched == null) return@synchronized null
            // The instant the position below is computed for.
            val nowNs = System.nanoTime()
            sampledNs = nowNs
            if (!sched.refValid) {
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
            if (trackTimestamp(sched, ts) && ts.framePosition > 0 &&
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
        if (withTime && value != null) {
            replySuccess(result, mapOf("positionUs" to value, "nativeTimeUs" to sampledNs / 1000))
        } else {
            replySuccess(result, value)
        }
    }

    private fun handleSetRate(call: MethodCall, result: Result) {
        val rate = call.argument<Number>("rate")?.toDouble()
        if (rate == null || !PlaybackLimits.isValidRate(rate)) {
            replyError(
                result,
                "bad_args",
                "setRate requires {rate: double within " +
                    "[${PlaybackLimits.MIN_RATE}, ${PlaybackLimits.MAX_RATE}]}"
            )
            return
        }
        val refused: Pair<String, String>? = synchronized(lock) {
            val sched = schedule ?: return@synchronized null
            val nowNs = System.nanoTime()
            // Gated: a released track is a no-op (null), never a throw.
            val applied = sched.useTrack { TrackSpeed.apply(it, rate) }
            if (applied == false) {
                // The track refused the speed. The math stays on the rate the
                // track REALLY plays, so positions stay true — and the caller
                // is told, never answered success: it would wait out a slew
                // that never happens. A low-latency track cannot time-stretch
                // on many devices: `rate_needs_reanchor`, a playAt fixes it
                // (its track is created without low latency from now on). A
                // normal track refusing means this output cannot play the
                // rate: `bad_args`.
                Log.w(TAG, "setRate($rate) refused by the track; still playing at ${sched.rate}")
                val lowLatency = sched.useTrack(::isLowLatencyTrack) == true
                if (lowLatency) lowLatencyRefusesSpeed = true
                TrackSpeed.setRateRefusalCode(lowLatency) to
                    if (lowLatency) {
                        "setRate $rate refused by a low-latency track; re-anchor with playAt " +
                            "(it uses a normal track that can)"
                    } else {
                        "setRate $rate is not supported by this audio output"
                    }
            } else {
                // Re-anchor the extrapolation mapping AT the instant of the
                // rate change: frames before this instant were consumed at
                // the old rate, frames after at the new one. The media
                // mapping (frame − S) needs no change (source-frame domain).
                if (sched.refValid) {
                    sched.refFrame +=
                        (nowNs - sched.refNanos).toDouble() * sched.sampleRate * sched.rate / 1e9
                    sched.refNanos = nowNs
                }
                sched.rate = rate
                Log.d(TAG, "setRate: $rate (refFrame=${sched.refFrame} refNanos=${sched.refNanos})")
                null
            }
        }
        if (refused != null) {
            replyError(result, refused.first, refused.second)
        } else {
            replySuccess(result, null)
        }
    }

    private fun handleDispose(result: Result) {
        synchronized(lock) {
            supervisor.onReleased()
            lock.notifyAll()
            releaseTrackLocked()
            loaded = null
            state = State.IDLE
        }
        abandonFocus()
        // Dormant until the next method call: no platform listener and no
        // event outlives dispose (a disposed player used to keep reporting
        // route changes).
        dormant = true
        unregisterPlatformListeners(detaching = false)
        replySuccess(result, null)
    }

    /**
     * The session is ending (keep-alive release): retire the schedule and free
     * the track — waiting for the writer to leave it — BEFORE the foreground
     * service is stopped. Idempotent, and safe to call from the platform
     * thread: the wait is bounded by TRACK_DRAIN_WAIT_NS and normally returns
     * at once, because releaseTrack interrupts the blocking write first.
     */
    private fun stopPlaybackForSessionEnd() {
        synchronized(lock) {
            supervisor.onReleased()
            // Unconditional (idempotent): the generation bump also retires a
            // playAt that is mid-flight on the handler thread right now.
            stopOutputLocked()
        }
        // The jam is over: hand audio focus back (a paused music app may
        // resume) and cancel any pending delayed-focus request.
        abandonFocus()
    }

    // ------------------------------------------------------------ shared state

    /**
     * Must hold [lock]. Stops native output — the schedule is retired and its
     * track freed — keeping the loaded file. The one stop used by every path
     * that is NOT a Dart call (focus loss, calls, unplug, writer failure,
     * session end); it never restarts anything, Dart re-anchors with playAt.
     * Idempotent.
     */
    private fun stopOutputLocked() {
        bumpGenerationLocked()
        releaseTrackLocked()
        state = if (loaded != null) State.LOADED else State.IDLE
    }

    /** Must hold [lock]. Retires all outstanding writers/decoders/completions. */
    private fun bumpGenerationLocked() {
        supervisor.retire()
        lock.notifyAll() // wake any writer parked in PAUSED
    }

    /**
     * Must hold [lock]. Retires the current schedule and frees its native
     * track — never while a writer is inside it (see [Schedule.releaseTrack]).
     *
     * The brief wait for the writer to leave happens with [lock] held, which
     * is safe by construction: nothing a [Schedule.useTrack] body does takes
     * [lock], so the writer always reaches its deregistration without needing
     * the lock this thread is holding. Callers must have bumped the generation
     * first so the writer exits instead of looping.
     */
    private fun releaseTrackLocked() {
        val sched = schedule ?: return
        schedule = null
        // Unblock a decoder parked in push() and a writer parked in pop().
        sched.queue.retire()
        sched.releaseTrack()
    }

    /** Must hold [lock]. */
    private fun clampToDuration(us: Long): Long {
        val duration = loaded?.durationUs ?: return max(0, us)
        return min(max(0, us), duration)
    }

    private fun isStale(sched: Schedule): Boolean =
        synchronized(lock) { !supervisor.isCurrent(sched.generation) }

    /**
     * Whether the writer must exit silently: its schedule was superseded, or
     * its native track was released out from under it. Both mean "somebody
     * else already owns the outcome" — reporting engineRestarted here would
     * make an orderly End-jam look like a failure.
     */
    private fun writerRetired(sched: Schedule): Boolean =
        sched.isTrackReleased || isStale(sched)

    // ------------------------------------------------------------ writer thread

    /**
     * Streams one schedule: silence priming, then media PCM popped from the
     * decoder's bounded queue, then completion detection. Exits silently the
     * moment its generation is stale or its track is released.
     *
     * Every native-track call goes through [Schedule.useTrack]; a null result
     * means the track is gone (or died mid-call), which is either a normal
     * teardown — exit — or, if the schedule is still current, a real track
     * failure to report.
     *
     * Nothing may escape this thread: an uncaught throwable on an app thread
     * kills the whole process on Android (the host's server with it). The
     * expected failures above are classified ([ScheduleFailure]) and
     * reported by [writerTrackFailure]; anything unexpected lands in
     * [writerCrashed] → output stopped + `playbackError{writer_failed}`.
     */
    private fun writerMain(sched: Schedule, audio: LoadedAudio) {
        runGuarded({ writerLoop(sched, audio) }) { t -> writerCrashed(sched, t) }
    }

    private fun writerLoop(sched: Schedule, audio: LoadedAudio) {
        val sr = sched.sampleRate
        val bpf = audio.bytesPerFrame
        val chunkFrames = max(sr / 100, 128) // ~10 ms
        val silence = ByteArray(chunkFrames * bpf)
        var written = 0L // source frames queued to the track so far

        try {
            if (sched.useTrack { it.play() } == null) {
                if (writerRetired(sched)) return
                writerTrackFailure(
                    sched, ScheduleFailure.TRACK_DEAD, "play() threw on a dead track"
                )
                return
            }
        } catch (e: Throwable) {
            writerTrackFailure(sched, ScheduleFailure.WRITER, "play() failed: $e")
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
            // The write is NOT guarded by `lock` (it blocks): the gate is what
            // keeps the handle alive across it, and returns null the instant
            // teardown claimed the track.
            val n = sched.useTrack {
                it.write(silence, 0, silence.size, AudioTrack.WRITE_BLOCKING)
            }
            if (n == null) {
                if (writerRetired(sched)) return
                writerTrackFailure(
                    sched, ScheduleFailure.TRACK_DEAD, "write threw on a dead track during priming"
                )
                return
            }
            if (n < 0) {
                writerTrackFailure(
                    sched, ScheduleFailure.ofWriteError(n), "write returned $n during priming"
                )
                return
            }
            written += n / bpf
            if (trackTimestamp(sched, ts) && ts.framePosition > 0) {
                primed = true
            } else if (System.nanoTime() >= warmupDeadline) {
                // Some outputs (emulators, odd HALs) never publish timestamps.
                // Degrade to playbackHeadPosition ~= "presented now": the
                // pipeline latency goes unaccounted (schedule lands early by
                // that much); §7 calibration absorbs it. Logged loudly.
                val head =
                    sched.useTrack { it.playbackHeadPosition.toLong() and 0xffffffffL }
                if (head == null) {
                    // Track gone: a teardown owns the outcome — unless the
                    // schedule is still current, then the track died and Dart
                    // must hear it (returning silently left Dart believing it
                    // played).
                    if (writerRetired(sched)) return
                    writerTrackFailure(
                        sched, ScheduleFailure.TRACK_DEAD, "track died during timestamp warm-up"
                    )
                    return
                }
                ts.framePosition = head
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
            if (!supervisor.isCurrent(sched.generation)) return
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
            val n = sched.useTrack {
                it.write(silence, 0, todoFrames * bpf, AudioTrack.WRITE_BLOCKING)
            }
            if (n == null) {
                if (writerRetired(sched)) return
                writerTrackFailure(
                    sched,
                    ScheduleFailure.TRACK_DEAD,
                    "write threw on a dead track during silence pad"
                )
                return
            }
            if (n < 0) {
                writerTrackFailure(
                    sched, ScheduleFailure.ofWriteError(n), "write returned $n during silence pad"
                )
                return
            }
            written += n / bpf
            // Refine S against fresher MATURE timestamps while silence
            // remains — the warm-up sample can be jittery; later samples are
            // steadier. framePosition == 0 reports are optimistic (no latency)
            // and must never re-anchor the mapping.
            if (trackTimestamp(sched, ts) && ts.framePosition > 0) {
                synchronized(lock) {
                    if (!supervisor.isCurrent(sched.generation)) return
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
        // The skip is applied to the queue output below — the decoder always
        // produces from startFrame exactly.
        val mediaSkip = written - s
        val firstPcmFrame = sched.startFrame + mediaSkip
        val firstMediaSourceFrame = s + mediaSkip // == `written` at trim time
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
                "endSourceFrameEst=${s + (audio.totalFrames - sched.startFrame)} " +
                "totalFramesMeta=${audio.totalFrames}"
        )

        // ---- Phase 3: stream the media PCM from the decoder queue. The
        // decoder's first queued frame is exactly startFrame; the overshoot
        // trim discards the first mediaSkip frames of it here.
        val q = sched.queue
        val buf = ByteArray(chunkFrames * bpf)
        var skipBytes = mediaSkip * bpf
        var mediaBytesWritten = 0L
        var startErrorLogged = false
        var eosReached = false
        while (!eosReached) {
            synchronized(lock) {
                while (supervisor.isCurrent(sched.generation) && state == State.PAUSED) {
                    // Writer parks while paused (the decoder then blocks on
                    // the full queue). There is no resume-in-place: the Dart
                    // side re-schedules via playAt (generation bump), which
                    // wakes and retires this writer.
                    try {
                        lock.wait()
                    } catch (_: InterruptedException) {
                    }
                }
                if (!supervisor.isCurrent(sched.generation)) return
            }
            val n = q.pop(buf, 100)
            when {
                n == PcmQueue.POP_RETIRED -> return
                n == PcmQueue.POP_ERROR -> {
                    // Normally already reported by the decoder itself (then
                    // this schedule is stale and this stays silent).
                    writerTrackFailure(sched, ScheduleFailure.DECODE, "decoder failed: ${q.error}")
                    return
                }
                n == PcmQueue.POP_EOS -> eosReached = true
                n == 0 -> {
                    // Timed out waiting for the decoder (it is normally well
                    // ahead); loop to re-check staleness/pause. A slow decode
                    // can underrun the track — a glitch, not a schedule error:
                    // the frame↔time anchor math is unaffected.
                }
                else -> {
                    var off = 0
                    var len = n
                    if (skipBytes > 0) { // overshoot trim (see above)
                        val drop = min(skipBytes, len.toLong()).toInt()
                        off += drop
                        len -= drop
                        skipBytes -= drop
                    }
                    while (len > 0) {
                        // THE crash site: an End-jam teardown used to free the
                        // track between the staleness check at the top of this
                        // loop and this call. The gate now refuses the call
                        // (null) instead of letting it reach a freed handle.
                        val w = sched.useTrack {
                            it.write(buf, off, len, AudioTrack.WRITE_BLOCKING)
                        }
                        if (w == null) {
                            if (writerRetired(sched)) return
                            writerTrackFailure(
                                sched,
                                ScheduleFailure.TRACK_DEAD,
                                "write threw on a dead track during media stream"
                            )
                            return
                        }
                        if (w < 0) {
                            writerTrackFailure(
                                sched,
                                ScheduleFailure.ofWriteError(w),
                                "write returned $w during media stream"
                            )
                            return
                        }
                        off += w
                        len -= w
                        if (mediaBytesWritten == 0L && w > 0) {
                            // Media reached the track: this schedule is
                            // healthy, so earlier dead tracks were reroutes,
                            // not a track that cannot play at all.
                            synchronized(lock) { supervisor.onMediaStreaming(sched.generation) }
                        }
                        mediaBytesWritten += w
                    }
                    if (trackTimestamp(sched, ts) && ts.framePosition > 0) {
                        synchronized(lock) {
                            if (!supervisor.isCurrent(sched.generation)) return
                            if (ts.nanoTime > sched.refNanos) {
                                sched.refFrame = ts.framePosition.toDouble()
                                sched.refNanos = ts.nanoTime
                            }
                            if (!startErrorLogged) {
                                // Measured start error for live verification:
                                // when did the first real PCM frame actually
                                // present, vs the instant the session anchor
                                // intended for it (targetNs shifted by the
                                // media advance at ×rate)?
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
            }
        }

        // ---- Phase 4: decoder EOS and all frames written; wait until they
        // are consumed (getTimestamp extrapolation reaches the last media
        // frame), then report playbackFinished — matching iOS's
        // .dataPlayedBack callback. endSourceFrame is EXACT here: total source
        // frames queued = silence (s) + overshoot standing in for media
        // (mediaSkip) + media actually written.
        val endSourceFrame = s + mediaSkip + mediaBytesWritten / bpf
        val remainingUs = synchronized(lock) {
            if (!supervisor.isCurrent(sched.generation)) return
            val fNow = sched.refFrame +
                (System.nanoTime() - sched.refNanos).toDouble() * sr * sched.rate / 1e9
            ((endSourceFrame - fNow) * 1e6 / (sr * sched.rate)).toLong()
        }
        val drainDeadline = System.nanoTime() + max(0, remainingUs) * 1000 + 2_000_000_000L
        while (true) {
            if (isStale(sched)) return
            val fNow = synchronized(lock) {
                if (!supervisor.isCurrent(sched.generation)) return
                if (trackTimestamp(sched, ts) && ts.framePosition > 0 &&
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
            if (!supervisor.isCurrent(sched.generation)) return
            state = State.FINISHED
            schedule = null
            sched.queue.retire() // decoder already exited at EOS; belt-and-braces
            // This thread IS the only track user and it is not inside
            // useTrack here, so the release takes effect immediately.
            sched.releaseTrack()
        }
        Log.d(TAG, "playbackFinished (generation=${sched.generation})")
        emitEvent(AudioEvents.PLAYBACK_FINISHED)
    }

    /**
     * Must hold [lock]. Source-frame index presented exactly at the target —
     * NOT clamped at 0 (see [PlaybackLimits.silenceFrames]).
     */
    private fun computeSilenceFramesLocked(sched: Schedule, ts: AudioTimestamp): Long =
        PlaybackLimits.silenceFrames(
            ts.framePosition, ts.nanoTime, sched.targetNs, sched.sampleRate, sched.rate
        )

    /**
     * getTimestamp that never throws and never touches a freed handle:
     * gated like every other track call, false for a released track.
     */
    private fun trackTimestamp(sched: Schedule, ts: AudioTimestamp): Boolean =
        sched.useTrack {
            try {
                it.getTimestamp(ts)
            } catch (_: Throwable) {
                false
            }
        } ?: false

    /**
     * A track or decoder failure the schedule cannot survive: unless the
     * schedule was already superseded (then stay silent — whoever retired it
     * owns the outcome), stop output FIRST and report what the supervisor
     * decides — engineRestarted for a dead track (re-schedule from the
     * authoritative anchor, iOS's configuration-change semantics), else
     * playbackError ([ScheduleFailure]).
     */
    private fun writerTrackFailure(sched: Schedule, failure: ScheduleFailure, why: String) {
        val event = synchronized(lock) {
            supervisor.onScheduleFailure(sched.generation, failure, why)
                ?.also {
                    Log.w(TAG, "schedule failed ($failure): $why")
                    lock.notifyAll()
                    releaseTrackLocked()
                    state = if (loaded != null) State.LOADED else State.IDLE
                }
        } ?: return
        emit(event)
    }

    /**
     * The writer threw something unexpected (a bug, OOM, a HAL surprise).
     * Stop output and free the track — releaseTrack is idempotent and the
     * gate waits for nothing here, since this thread has already left every
     * useTrack — then tell Dart with `playbackError` (contract item 5). A
     * superseded writer (stale generation) stays silent: whoever bumped the
     * generation already released its track.
     */
    private fun writerCrashed(sched: Schedule, t: Throwable) {
        val current = synchronized(lock) { supervisor.isCurrent(sched.generation) }
        if (!current) {
            Log.w(TAG, "writer (superseded) threw; ignoring", t)
            return
        }
        Log.e(TAG, "writer thread failed; output stopped", t)
        writerTrackFailure(
            sched,
            ScheduleFailure.WRITER,
            "audio writer failed: ${t.javaClass.simpleName}: ${t.message}"
        )
    }

    // ------------------------------------------------------------ decoder thread

    /**
     * Produces the PCM for one schedule into its bounded queue. One per
     * schedule, generation-tagged like the writer; owns a private
     * MediaExtractor + MediaCodec pair (no sharing across schedules, so a new
     * playAt never fights an old decoder over extractor position).
     *
     * Frame accuracy (see class doc): [openPacketSource] positions the
     * source with pre-roll before the target; the first output buffer's
     * presentationTimeUs, mapped by [GaplessTimeline.frameAt], anchors a
     * [PcmTrimmer] that makes the FIRST queued frame media frame startFrame.
     *
     * Files with more than two channels are folded down to stereo here
     * ([StereoFolder]) before queueing, so the writer and the AudioTrack only
     * ever see mono or stereo.
     */
    private fun decoderMain(sched: Schedule, audio: LoadedAudio) {
        // Same rule as the writer: nothing escapes this thread.
        runGuarded({ decoderLoop(sched, audio) }) { t ->
            Log.e(TAG, "decoder thread failed", t)
            decoderFailed(sched, "decoder thread failed: $t")
        }
    }

    /**
     * The decoder cannot go on: playbackError{decode_failed}, reported HERE
     * rather than when the writer reaches the failure in the queue — the
     * writer may still be priming (or parked in a pause) and would report it
     * late, or never. The queue is failed too so a writer that pops first
     * stops instead of playing out the buffered tail. A superseded schedule
     * stays silent.
     */
    private fun decoderFailed(sched: Schedule, why: String) {
        sched.queue.fail(why)
        writerTrackFailure(sched, ScheduleFailure.DECODE, why)
    }

    /** Compressed packets for one schedule's decoder (an extractor or the MP3 index). */
    private interface PacketSource : java.io.Closeable {
        /** Reads the current packet into [buf]; its size, or −1 at the end. */
        fun read(buf: ByteBuffer): Int

        /** Pts (µs) of the packet [read] just returned. */
        val sampleTimeUs: Long

        fun advance()
    }

    private class ExtractorSource(private val ex: MediaExtractor) : PacketSource {
        override var sampleTimeUs = 0L
            private set

        override fun read(buf: ByteBuffer): Int {
            sampleTimeUs = ex.sampleTime
            return ex.readSampleData(buf, 0)
        }

        override fun advance() {
            ex.advance()
        }

        override fun close() = ex.release()
    }

    /** Feeds MP3 frames straight from the file by [Mp3FrameIndex], pts = frame time. */
    private class Mp3IndexSource(
        path: String,
        private val index: Mp3FrameIndex,
        private var next: Int
    ) : PacketSource {
        private val raf = java.io.RandomAccessFile(path, "r")
        private val scratch = ByteArray(4096)

        override var sampleTimeUs = 0L
            private set

        override fun read(buf: ByteBuffer): Int {
            if (next >= index.frameCount) return -1
            val size = index.size(next)
            raf.seek(index.offset(next))
            raf.readFully(scratch, 0, size)
            buf.clear()
            buf.put(scratch, 0, size)
            sampleTimeUs = index.ptsUs(next)
            return size
        }

        override fun advance() {
            next++
        }

        override fun close() = raf.close()
    }

    /**
     * Opens the packet source for decoding from gapless frame [startFrame]
     * (positioned for pre-roll) and the format to configure the codec with.
     */
    private fun openPacketSource(audio: LoadedAudio, startFrame: Long): Pair<PacketSource, MediaFormat> {
        audio.mp3?.let { index ->
            val first = index.firstFrameToFeed(startFrame)
            val format = MediaFormat.createAudioFormat(audio.mime, index.sampleRate, index.channels)
            format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 4096)
            return Mp3IndexSource(audio.path, index, first) to format
        }
        val ex = MediaExtractor()
        try {
            ex.setDataSource(audio.path)
            val (trackIndex, trackFormat) = DurationProbe.findAudioTrack(ex)
                ?: throw IllegalArgumentException("no audio track in file")
            ex.selectTrack(trackIndex)
            // No seek near the start: decoding from the first sample is exact
            // and keeps clear of a shifted elst timeline's negative pts.
            audio.timeline.seekUsFor(
                startFrame, audio.sampleRate, GaplessTimeline.SEEK_PREROLL_US
            )?.let {
                ex.seekTo(it, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
            }
            // The platform's own delay/padding trim (SkipCutBuffer) applies
            // from wherever decoding starts and decouples pts from the PCM;
            // [GaplessTimeline]/[PcmTrimmer] do it exactly instead.
            trackFormat.setInteger(KEY_ENCODER_DELAY, 0)
            trackFormat.setInteger(KEY_ENCODER_PADDING, 0)
            return ExtractorSource(ex) to trackFormat
        } catch (t: Throwable) {
            ex.release()
            throw t
        }
    }

    private fun decoderLoop(sched: Schedule, audio: LoadedAudio) {
        val q = sched.queue
        val sr = audio.sampleRate
        val bpf = audio.bytesPerFrame // OUTPUT (≤ stereo) frame size
        val srcBpf = 2 * audio.srcChannels // decoded frame size
        var folder: StereoFolder? =
            if (audio.srcChannels > 2) StereoFolder(audio.srcChannels, audio.srcChannelMask) else null
        val timeline = audio.timeline
        val trimmer = PcmTrimmer(
            targetFrame = sched.startFrame,
            bytesPerFrame = bpf,
            holdbackFrames = timeline.paddingFrames,
            endFrame = timeline.gaplessFrames,
            maxFillFrames = 10L * sr
        )
        var source: PacketSource? = null
        var codec: MediaCodec? = null
        try {
            val (src, format) = openPacketSource(audio, sched.startFrame)
            source = src
            val c = MediaCodec.createDecoderByType(audio.mime)
            codec = c
            c.configure(format, null, null, 0)
            c.start()

            var pcmEncoding = AudioFormat.ENCODING_PCM_16BIT
            var firstOutput = true
            var carry: ByteArray? = null // frame-alignment remainder (rare)
            val info = MediaCodec.BufferInfo()
            var inputDone = false
            var idleSpins = 0
            while (true) {
                if (isStale(sched)) return
                var progressed = false
                if (!inputDone) {
                    val inIdx = c.dequeueInputBuffer(10_000)
                    if (inIdx >= 0) {
                        progressed = true
                        val buf = c.getInputBuffer(inIdx)!!
                        val n = src.read(buf)
                        if (n < 0) {
                            c.queueInputBuffer(
                                inIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM
                            )
                            inputDone = true
                        } else {
                            c.queueInputBuffer(inIdx, 0, n, src.sampleTimeUs, 0)
                            src.advance()
                        }
                    }
                }
                val outIdx = c.dequeueOutputBuffer(info, 10_000)
                when {
                    outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        progressed = true
                        val f = c.outputFormat
                        val newSr = f.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                        val newCh = f.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                        pcmEncoding = if (f.containsKey(MediaFormat.KEY_PCM_ENCODING)) {
                            f.getInteger(MediaFormat.KEY_PCM_ENCODING)
                        } else {
                            AudioFormat.ENCODING_PCM_16BIT
                        }
                        if (newSr != sr || newCh != audio.srcChannels) {
                            // The AudioTrack was created from the load-probed
                            // format; a mid-stream change cannot be honored.
                            decoderFailed(
                                sched,
                                "decoder output format $newSr Hz x${newCh}ch != " +
                                    "probed $sr Hz x${audio.srcChannels}ch"
                            )
                            return
                        }
                        if (newCh > 2) {
                            // This decoder's own mask is the authority on the
                            // interleave order of what it is about to emit.
                            val mask = if (f.containsKey(MediaFormat.KEY_CHANNEL_MASK)) {
                                f.getInteger(MediaFormat.KEY_CHANNEL_MASK)
                            } else {
                                audio.srcChannelMask
                            }
                            folder = StereoFolder(newCh, mask)
                        }
                    }
                    outIdx >= 0 -> {
                        progressed = true
                        val eos = info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                        var payload: List<ByteArray> = emptyList()
                        if (info.size > 0) {
                            val out = c.getOutputBuffer(outIdx)!!
                            out.position(info.offset)
                            out.limit(info.offset + info.size)
                            var chunk = pcm16Bytes(out, pcmEncoding)
                            // Gapless frame of this buffer's first PCM frame:
                            // with the platform trim off, pts describes the PCM
                            // it labels (see [GaplessTimeline]). Only the first
                            // buffer's value anchors the trimmer.
                            val bufFrame = timeline.frameAt(info.presentationTimeUs, sr)
                            carry?.let { chunk = it + chunk; carry = null }
                            var alignedBytes = chunk.size - chunk.size % srcBpf
                            if (alignedBytes != chunk.size) {
                                carry = chunk.copyOfRange(alignedBytes, chunk.size)
                                chunk = chunk.copyOfRange(0, alignedBytes)
                            }
                            folder?.let {
                                // >2 channels: fold the whole decoded frames
                                // to stereo; frame count is unchanged, so the
                                // trim below is layout-independent.
                                chunk = it.fold(chunk, 0, alignedBytes)
                                alignedBytes = chunk.size
                            }
                            payload = trimmer.accept(chunk, bufFrame)
                            if (firstOutput) {
                                firstOutput = false
                                if (trimmer.lateFrames > 0) {
                                    // Pre-roll should make this impossible; if
                                    // it happens the gap is silence, so media
                                    // frame startFrame still plays on time.
                                    Log.w(
                                        TAG,
                                        "decoder: resumed ${trimmer.lateFrames} frames past the " +
                                            "target (startFrame=${sched.startFrame} " +
                                            "pts=${info.presentationTimeUs}us); filled with silence"
                                    )
                                } else {
                                    Log.d(
                                        TAG,
                                        "decoder: startFrame=${sched.startFrame} first pts=" +
                                            "${info.presentationTimeUs}us = gapless frame $bufFrame"
                                    )
                                }
                            }
                        }
                        // Release the codec buffer BEFORE the potentially long
                        // blocking push (queue full while paused).
                        c.releaseOutputBuffer(outIdx, false)
                        for (p in payload) {
                            if (!q.push(p)) return // retired
                        }
                        if (eos) {
                            // The trimmer's withheld tail is the encoder
                            // padding: dropped. Includes "file ends before
                            // startFrame" (metadata duration over-reported):
                            // the queue closes with whatever was decodable.
                            trimmer.finish()
                            q.close()
                            return
                        }
                    }
                }
                idleSpins = if (progressed) 0 else idleSpins + 1
                if (idleSpins > 500) { // ~10 s of no progress: codec wedged
                    decoderFailed(sched, "decoder made no progress (stalled)")
                    return
                }
            }
        } catch (e: Throwable) {
            if (!isStale(sched)) Log.w(TAG, "decoder: error", e)
            decoderFailed(sched, "decoder exception: $e")
        } finally {
            try {
                codec?.stop()
            } catch (_: Throwable) {
            }
            try {
                codec?.release()
            } catch (_: Throwable) {
            }
            try {
                source?.close()
            } catch (_: Throwable) {
            }
        }
    }

    // ------------------------------------------------------------- AudioTrack

    /**
     * A fresh MODE_STREAM track for [audio] that can play at [rate];
     * [lowLatency] asks for PERFORMANCE_MODE_LOW_LATENCY (API 26+), which
     * some outputs grant as a FAST track that cannot change speed (see
     * [TrackSpeed]).
     */
    private fun createTrack(audio: LoadedAudio, lowLatency: Boolean, rate: Double): AudioTrack {
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
        // unaffected by buffer depth) — more for fast rates, which AudioTrack
        // otherwise refuses ("buffer size"): see [TrackSpeed.bufferFactor].
        val bufBytes = minBuf * TrackSpeed.bufferFactor(rate)
        val builder = AudioTrack.Builder()
            .setAudioAttributes(mediaAttributes)
            .setAudioFormat(
                AudioFormat.Builder()
                    .setSampleRate(audio.sampleRate)
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setChannelMask(channelMask)
                    .build()
            )
            .setTransferMode(AudioTrack.MODE_STREAM)
            .setBufferSizeInBytes(bufBytes)
        if (lowLatency && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            builder.setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY)
        }
        val track = builder.build()
        if (track.state != AudioTrack.STATE_INITIALIZED) {
            track.release()
            throw IllegalStateException("AudioTrack failed to initialize")
        }
        return track
    }

    // ------------------------------------------------------------------ probe

    /**
     * Opens [path] and probes it WITHOUT decoding the file: duration from
     * metadata (accuracy contract in the class doc) and the decoder's true
     * output format from a bounded probe that decodes at most the first
     * output buffer (a few frames, milliseconds — needed because containers
     * can misreport the output rate, e.g. HE-AAC's 2× SBR).
     */
    private fun probeAudio(path: String): LoadedAudio {
        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(path)
            val (trackIndex, trackFormat) = DurationProbe.findAudioTrack(extractor)
                ?: throw IllegalArgumentException("no audio track in file")
            extractor.selectTrack(trackIndex)
            val mime = trackFormat.getString(MediaFormat.KEY_MIME)!!
            // Gapless mapping inputs ([GaplessTimeline]): the first sample's
            // pts BEFORE anything reads or seeks (negative for an `elst`
            // timeline MPEG4Extractor shifted), and the encoder delay/padding
            // the extractor found (elst, iTunSMPB, LAME tag).
            // (sampleTime is −1 only when there is no sample at all.)
            val firstSampleUs = extractor.sampleTime.let { if (it == -1L) 0L else it }
            val encoderDelay = trackFormat.intOr(KEY_ENCODER_DELAY, 0)
            val encoderPadding = trackFormat.intOr(KEY_ENCODER_PADDING, 0)
            val formatSampleRate = trackFormat.intOr(MediaFormat.KEY_SAMPLE_RATE, 0)

            // Duration: the SAME metadata chain probeDuration uses (so a
            // probed playlist and a loaded track agree to the µs).
            val durationUs = DurationProbe.durationUs(extractor, trackFormat, path)
            if (durationUs <= 0) {
                throw IllegalArgumentException("could not determine duration")
            }
            // Container-level limits first (no codec spun up for a 1 Hz
            // header); the decoder's real output format is checked below.
            if (trackFormat.containsKey(MediaFormat.KEY_SAMPLE_RATE) &&
                trackFormat.containsKey(MediaFormat.KEY_CHANNEL_COUNT)
            ) {
                PlaybackLimits.fileProblem(
                    trackFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE),
                    trackFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT),
                    durationUs
                )?.let { throw IllegalArgumentException(it) }
            }

            // Bounded format probe: decode until the first output buffer.
            var sampleRate = trackFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            var channels = trackFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            var channelMask: Int? = trackFormat.channelMaskOrNull()
            val codec = MediaCodec.createDecoderByType(mime)
            try {
                codec.configure(trackFormat, null, null, 0)
                codec.start()
                val info = MediaCodec.BufferInfo()
                var inputDone = false
                var idleSpins = 0
                var gotOutput = false
                while (!gotOutput) {
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
                            channelMask = f.channelMaskOrNull()
                        }
                        outIdx >= 0 -> {
                            progressed = true
                            codec.releaseOutputBuffer(outIdx, false)
                            if (info.size > 0) {
                                gotOutput = true
                            } else if (info.flags and
                                MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                            ) {
                                throw IllegalArgumentException("decoded zero audio frames")
                            }
                        }
                    }
                    idleSpins = if (progressed) 0 else idleSpins + 1
                    if (idleSpins > 500) { // ~10 s of no progress: codec wedged
                        throw IllegalStateException("decoder made no progress (probe stalled)")
                    }
                }
            } finally {
                try {
                    codec.stop()
                } catch (_: Throwable) {
                }
                codec.release()
            }
            // >2 channels are folded down to stereo while decoding
            // (StereoFolder) rather than rejected. Same limits as
            // probeDuration (and iOS/desktop): a 0-frame file, an absurd
            // sample rate or a crafted duration is load_failed here, not a
            // bad_position on every playAt or an AudioTrack that never builds.
            PlaybackLimits.fileProblem(sampleRate, channels, durationUs)
                ?.let { throw IllegalArgumentException(it) }
            // MP3: feed the decoder from a frame index (MediaExtractor's MP3
            // seeks are not frame-exact — see [Mp3FrameIndex]); anything the
            // index cannot describe keeps the extractor path.
            val mp3 = if (mime.equals(MediaFormat.MIMETYPE_AUDIO_MPEG, ignoreCase = true)) {
                Mp3FrameIndex.build(java.io.File(path))?.takeIf {
                    val ok = it.sampleRate == sampleRate && it.channels == channels
                    if (!ok) {
                        Log.w(
                            TAG,
                            "mp3 index ${it.sampleRate} Hz x${it.channels} != decoder " +
                                "$sampleRate Hz x$channels; using MediaExtractor"
                        )
                    }
                    ok
                }
            } else {
                null
            }
            val timeline = mp3?.timeline() ?: GaplessTimeline.fromTrack(
                firstSampleUs, encoderDelay, encoderPadding, formatSampleRate, sampleRate
            )
            Log.i(
                TAG,
                "load: $mime ${sampleRate}Hz x$channels firstSampleUs=$firstSampleUs " +
                    "encoderDelay=$encoderDelay encoderPadding=$encoderPadding " +
                    (mp3?.let {
                        "mp3Frames=${it.frameCount} lameDelay=${it.encoderDelay} " +
                            "lamePadding=${it.encoderPadding}"
                    } ?: "extractor")
            )
            return LoadedAudio(
                path, mime, sampleRate, channels, channelMask, durationUs, timeline, mp3
            )
        } finally {
            extractor.release()
        }
    }

    private fun MediaFormat.intOr(key: String, default: Int): Int =
        if (containsKey(key)) getInteger(key) else default

    private fun MediaFormat.channelMaskOrNull(): Int? =
        if (containsKey(MediaFormat.KEY_CHANNEL_MASK)) {
            getInteger(MediaFormat.KEY_CHANNEL_MASK).takeIf { it != 0 }
        } else {
            null
        }

    /** One decoder output buffer as interleaved 16-bit LE PCM bytes. */
    private fun pcm16Bytes(buf: ByteBuffer, encoding: Int): ByteArray = when (encoding) {
        AudioFormat.ENCODING_PCM_16BIT ->
            ByteArray(buf.remaining()).also { buf.get(it) }
        AudioFormat.ENCODING_PCM_FLOAT -> {
            val floats = buf.order(ByteOrder.nativeOrder()).asFloatBuffer()
            val out = ByteArray(floats.remaining() * 2)
            var o = 0
            while (floats.hasRemaining()) {
                val v = (floats.get() * 32767.0f).coerceIn(-32768.0f, 32767.0f).toInt()
                out[o++] = (v and 0xff).toByte()
                out[o++] = ((v shr 8) and 0xff).toByte()
            }
            out
        }
        else -> throw IllegalArgumentException("unsupported decoder PCM encoding $encoding")
    }

    // --------------------------------------------------- focus / interruptions

    /** Media attributes shared by the track, the focus request and route queries. */
    private val mediaAttributes: AudioAttributes by lazy {
        AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
            .build()
    }

    private val focusListener = AudioManager.OnAudioFocusChangeListener { change ->
        runGuarded({
            val inCall = isInCallMode()
            val effects = synchronized(lock) {
                supervisor.onFocusChange(change, inCall).also { applyFocusEffectsLocked(it) }
            }
            Log.d(TAG, "audio focus change $change -> $effects")
            if (AudioFocusPolicy.Effect.ABANDON_FOCUS in effects) abandonFocus()
        }) { t -> Log.e(TAG, "audio focus callback failed", t) }
    }

    /**
     * Must hold [lock]. Applies the focus policy's effects in order — STOP
     * always precedes the event that reports it. ABANDON_FOCUS is left to the
     * caller (outside the lock).
     */
    private fun applyFocusEffectsLocked(effects: List<AudioFocusPolicy.Effect>) {
        for (effect in effects) {
            when (effect) {
                AudioFocusPolicy.Effect.STOP_OUTPUT -> stopOutputLocked()
                AudioFocusPolicy.Effect.EMIT_BEGAN -> emit(AudioEvents.interruptionBegan())
                AudioFocusPolicy.Effect.EMIT_BEGAN_NO_RESUME ->
                    emit(AudioEvents.interruptionBegan(shouldResume = false))
                AudioFocusPolicy.Effect.EMIT_ENDED_SHOULD_RESUME ->
                    emit(AudioEvents.interruptionEnded(shouldResume = true))
                AudioFocusPolicy.Effect.DUCK -> schedule?.useTrack { it.setVolume(DUCK_VOLUME) }
                AudioFocusPolicy.Effect.UNDUCK -> schedule?.useTrack { it.setVolume(1.0f) }
                AudioFocusPolicy.Effect.ABANDON_FOCUS -> Unit
            }
        }
    }

    /**
     * playAt's focus gate (contract item 4): no focus request at all while a
     * call owns audio, nor while focus is already held (re-requesting would
     * hand a navigation prompt that is ducking us AUDIOFOCUS_LOSS); else
     * request it. The request runs outside [lock] — focus callbacks land on
     * the main thread meanwhile, and the [ticket] fences them (see
     * [AudioFocusPolicy.onPlayRequested]). False = do not play; the policy
     * has emitted interruptionBegan and playAt completes normally.
     */
    private fun negotiateFocusForPlay(ticket: PlaybackSupervisor.PlayAtTicket): Boolean {
        val inCall = isInCallMode()
        val focus = if (!inCall && ticket.focus.requestFocus) requestFocus() else null
        val decision = synchronized(lock) {
            supervisor.negotiateFocus(ticket, inCall, focus)
                .also { applyFocusEffectsLocked(it.effects) }
        }
        if (!decision.play) {
            Log.i(
                TAG,
                when {
                    inCall -> "playAt refused: a call owns the audio path (mode ${audioManager?.mode})"
                    focus == null -> "playAt refused: interrupted while starting (focus held)"
                    else -> "playAt refused: audio focus $focus"
                }
            )
        }
        return decision.play
    }

    /** Whether a call (cellular, VoIP, ringing, screening) owns audio now. */
    private fun isInCallMode(): Boolean = try {
        audioManager?.mode?.let(::isCallAudioMode) ?: false
    } catch (_: Throwable) {
        false
    }

    /** Requests media audio focus for playAt (only when not already held). */
    private fun requestFocus(): FocusRequestResult {
        val am = audioManager ?: return FocusRequestResult.GRANTED
        val code = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val request = focusRequest ?: AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(mediaAttributes)
                // A cellular call holds focus LOCKED: queue behind it
                // (DELAYED, then GAIN when it ends = interruptionEnded)
                // rather than fail and never hear about the call ending.
                .setAcceptsDelayedFocusGain(true)
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
        return FocusRequestResult.of(code)
    }

    /** Releases focus, also cancelling a pending delayed request. Idempotent. */
    private fun abandonFocus() {
        val am = audioManager ?: return
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                focusRequest?.let { am.abandonAudioFocusRequest(it) }
            } else {
                @Suppress("DEPRECATION")
                am.abandonAudioFocus(focusListener)
            }
        } catch (e: Throwable) {
            Log.w(TAG, "abandonAudioFocus failed", e)
        }
    }

    // --------------------------------------------------- platform listeners

    /**
     * Registers the device callback, the becoming-noisy receiver and the
     * mode listener (each once). At attach, and again on the first method
     * call after a `dispose` ([wake]). Never after detach.
     */
    private fun registerPlatformListeners() {
        synchronized(listenerLock) {
            if (listenersDetached) return
            val context = appContext ?: return
            if (deviceCallback == null) registerRouteCallback()
            if (noisyReceiver == null) registerNoisyReceiver(context)
            if (modeListener == null) registerModeListener()
        }
    }

    /** Unregisters all three; [detaching] also forbids registering again. */
    private fun unregisterPlatformListeners(detaching: Boolean) {
        synchronized(listenerLock) {
            if (detaching) listenersDetached = true
            unregisterRouteCallback()
            unregisterNoisyReceiver()
            unregisterModeListener()
        }
    }

    /** First method call after `dispose`: events and listeners come back. */
    private fun wake() {
        dormant = false
        registerPlatformListeners()
    }

    /**
     * API 31+: calls that do not go through audio focus (a VoIP app that only
     * switches the mode) still interrupt us, and the end of a call we were
     * refused for is observable. Below 31 the in-call check at playAt plus
     * the focus callbacks are all there is.
     */
    private fun registerModeListener() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return
        val am = audioManager ?: return
        val listener = AudioManager.OnModeChangedListener { mode ->
            runGuarded({
                val effects = synchronized(lock) {
                    supervisor.onModeChanged(isCallAudioMode(mode))
                        .also { applyFocusEffectsLocked(it) }
                }
                if (effects.isNotEmpty()) Log.d(TAG, "audio mode $mode -> $effects")
            }) { t -> Log.e(TAG, "audio mode callback failed", t) }
        }
        try {
            am.addOnModeChangedListener(Executor { mainHandler.post(it) }, listener)
            modeListener = listener
        } catch (e: Throwable) {
            Log.w(TAG, "audio mode listener unavailable", e)
        }
    }

    private fun unregisterModeListener() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return
        val listener = modeListener as? AudioManager.OnModeChangedListener ?: return
        try {
            audioManager?.removeOnModeChangedListener(listener)
        } catch (_: Throwable) {
        }
        modeListener = null
    }

    // ----------------------------------------------------------------- routes

    /**
     * ACTION_AUDIO_BECOMING_NOISY: headphones are being unplugged / the BT
     * sink is dropping. AudioService sends it BEFORE rerouting so a player
     * can stop before audio blares from the speaker — so output stops FIRST,
     * then Dart hears routeChanged{oldDeviceUnavailable: true}. Nothing is
     * restarted natively. Dynamically registered: it is a protected system
     * broadcast (manifest receivers for it are not delivered, and nothing
     * but the system can send it — adb included).
     */
    private fun registerNoisyReceiver(context: Context) {
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(ctx: Context?, intent: Intent?) {
                if (intent?.action != AudioManager.ACTION_AUDIO_BECOMING_NOISY) return
                runGuarded({ onBecomingNoisy() }) { t ->
                    Log.e(TAG, "becoming-noisy handling failed", t)
                }
            }
        }
        val filter = IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                // NOT_EXPORTED still receives system broadcasts.
                context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                context.registerReceiver(receiver, filter)
            }
            noisyReceiver = receiver
        } catch (e: Throwable) {
            Log.w(TAG, "could not register the becoming-noisy receiver", e)
        }
    }

    private fun unregisterNoisyReceiver() {
        val receiver = noisyReceiver ?: return
        noisyReceiver = null
        try {
            appContext?.unregisterReceiver(receiver)
        } catch (_: Throwable) {
        }
    }

    private fun onBecomingNoisy() {
        // Still routed to the departing device; guess where media lands next
        // (the removal callback that follows reports the real new route).
        val going = currentRoute()
        val next = currentRoute(exclude = setOfNotNull(going?.id))
        val latencyUs = OutputLatency.SCHEDULING_US
        val decision = synchronized(lock) {
            supervisor.onBecomingNoisy(System.nanoTime(), going?.id, next?.id)
                .also { if (it.stopOutput) stopOutputLocked() }
        }
        Log.i(TAG, "audio becoming noisy: output stopped (route ${going?.id} -> ${next?.id})")
        emit(AudioEvents.routeChanged(latencyUs, decision.routeId, decision.oldDeviceUnavailable))
    }

    private fun registerRouteCallback() {
        val am = audioManager ?: return
        val callback = object : AudioDeviceCallback() {
            // Registration immediately fires onAudioDevicesAdded with the
            // CURRENT device list; it only primes the route tracker, so no
            // spurious routeChanged lands.
            private var initial = true

            override fun onAudioDevicesAdded(added: Array<out AudioDeviceInfo>) {
                runGuarded({
                    if (initial) {
                        initial = false
                        val route = currentRoute()
                        synchronized(lock) { supervisor.routes.observe(route) }
                        return@runGuarded
                    }
                    val sinks = added
                        .filter { it.isSink && AudioRoutes.isMediaOutput(it.type) }
                        .map(::deviceOf)
                    if (sinks.isEmpty()) return@runGuarded
                    val route = routeAfterAddition(sinks.map { it.id }.toSet())
                    val latencyUs = OutputLatency.SCHEDULING_US
                    val decision = synchronized(lock) { supervisor.onDevicesAdded(route) }
                    emit(AudioEvents.routeChanged(latencyUs, decision.routeId, false))
                }) { t -> Log.e(TAG, "route (added) callback failed", t) }
            }

            override fun onAudioDevicesRemoved(removed: Array<out AudioDeviceInfo>) {
                runGuarded({
                    val sinks = removed
                        .filter { it.isSink && AudioRoutes.isMediaOutput(it.type) }
                        .map(::deviceOf)
                    if (sinks.isEmpty()) return@runGuarded
                    val route = currentRoute(exclude = sinks.map { it.id }.toSet())
                    val latencyUs = OutputLatency.SCHEDULING_US
                    val decision = synchronized(lock) {
                        supervisor.onDevicesRemoved(System.nanoTime(), sinks, route)
                            .also { if (it.stopOutput) stopOutputLocked() } // FIRST
                    }
                    if (decision.oldDeviceUnavailable) {
                        Log.i(TAG, "active output removed: output stopped (now ${decision.routeId})")
                    }
                    emit(
                        AudioEvents.routeChanged(
                            latencyUs, decision.routeId, decision.oldDeviceUnavailable
                        )
                    )
                }) { t -> Log.e(TAG, "route (removed) callback failed", t) }
            }
        }
        am.registerAudioDeviceCallback(callback, mainHandler)
        deviceCallback = callback
    }

    private fun unregisterRouteCallback() {
        deviceCallback?.let { audioManager?.unregisterAudioDeviceCallback(it) }
        deviceCallback = null
    }

    private fun deviceOf(info: AudioDeviceInfo): RouteDevice = RouteDevice(
        type = info.type,
        productName = info.productName?.toString().orEmpty(),
        address = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.address.orEmpty()
        } else {
            ""
        },
    )

    /**
     * The device media plays on (or would play on) right now, skipping ids
     * in [exclude] — `currentRouteId` (contract item 2). Most exact source
     * first: a live track's routed device, then API 33's audio-policy answer
     * for media attributes, then a static AOSP-like priority guess.
     */
    private fun currentRoute(exclude: Set<String> = emptySet()): RouteDevice? {
        val am = audioManager ?: return null
        return try {
            liveRoute()?.takeIf { it.id !in exclude }
                ?: policyRoute(am, exclude)
                ?: AudioRoutes.pickMediaRoute(outputDevices(am), exclude)
        } catch (e: Throwable) {
            Log.w(TAG, "route query failed", e)
            null
        }
    }

    /**
     * The route right after outputs with ids [added] appeared — NOT
     * [currentRoute], whose first source (the live track) has not been
     * moved yet at this point: see [AudioRoutes.routeAfterAddition].
     */
    private fun routeAfterAddition(added: Set<String>): RouteDevice? {
        val am = audioManager ?: return null
        return try {
            AudioRoutes.routeAfterAddition(
                policyRoute(am, emptySet()), liveRoute(), added, outputDevices(am)
            )
        } catch (e: Throwable) {
            Log.w(TAG, "route query failed", e)
            null
        }
    }

    /** The live track's routed device (exact, once the track is playing). */
    private fun liveRoute(): RouteDevice? {
        val sched = synchronized(lock) { schedule }
        return sched?.useTrack { it.routedDevice }
            ?.takeIf { it.isSink && AudioRoutes.isMediaOutput(it.type) }
            ?.let(::deviceOf)
    }

    /** API 33+: the audio policy's own answer for media attributes. */
    private fun policyRoute(am: AudioManager, exclude: Set<String>): RouteDevice? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return null
        return am.getAudioDevicesForAttributes(mediaAttributes)
            .filter { it.isSink && AudioRoutes.isMediaOutput(it.type) }
            .map(::deviceOf)
            .firstOrNull { it.id !in exclude }
    }

    private fun outputDevices(am: AudioManager): List<RouteDevice> =
        am.getDevices(AudioManager.GET_DEVICES_OUTPUTS).map(::deviceOf)

    /**
     * `debugLatencyInfo`: the latency the plugin reports for scheduling (0,
     * see [OutputLatency]) next to the device's own claim — the hidden
     * AudioManager property, diagnostic only.
     */
    private fun latencyInfo(): Map<String, Any> = mapOf(
        "schedulingLatencyUs" to OutputLatency.SCHEDULING_US,
        "propertyOutputLatencyUs" to OutputLatency.propertyUs(
            audioManager?.getProperty("android.media.property.OUTPUT_LATENCY")
        ),
    )
}
