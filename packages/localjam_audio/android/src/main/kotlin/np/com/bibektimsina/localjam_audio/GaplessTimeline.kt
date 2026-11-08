package np.com.bibektimsina.localjam_audio

import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToLong

/**
 * What "media position P" means on Android, and how a decoder's output
 * timestamps map onto it.
 *
 * ## The contract (shared with Apple and the browser)
 * Media frame 0 is the first frame of the file's GAPLESS content: the
 * encoder's leading delay (AAC priming, LAME's encoder delay) and trailing
 * padding are not part of the timeline. This is what AVAudioFile (AAC, via
 * the packet table built from an `edts/elst` or iTunSMPB) and Chrome's
 * decodeAudioData (FFmpeg's skip-samples for `elst`, iTunSMPB and the LAME
 * tag) treat as frame 0 — measured, see the package README. A constant
 * offset between platforms would desync guests while every drift reading
 * stayed at ~0, because drift telemetry compares each player against its own
 * timeline, never against the audio content.
 *
 * ## Why Android needs its own mapping
 * Left alone, the platform gets this wrong in two different ways:
 *  - MediaCodec trims the encoder delay/padding itself (a SkipCutBuffer
 *    built from the format's `encoder-delay`/`encoder-padding`), but from
 *    wherever decoding STARTS — after a seek it drops `delay` frames of real
 *    content — and it only shifts bytes, so output timestamps no longer
 *    describe the PCM they carry (an iTunSMPB AAC started at 0 reports its
 *    first PCM at pts frame 3072 while the PCM is gapless frame 0).
 *  - MPEG4Extractor (Android 10+) shifts timestamps by the `elst` media time
 *    (priming samples get negative pts) AND reports that same priming as
 *    `encoder-delay`, so the delay is removed twice for `elst` files; files
 *    with only an iTunSMPB atom keep raw (priming-inclusive) timestamps.
 *
 * The decoder therefore configures MediaCodec with encoder-delay/padding 0
 * (output pts then describe their own PCM) and maps pts itself:
 *
 *     gapless frame = (pts − firstSampleUs − delayUs) · sampleRate / 1e6
 *
 * where [firstSampleUs] is the pts of the first sample the extractor returns
 * before any seek. For a shifted `elst` file firstSampleUs = −delay, for an
 * iTunSMPB file (or an `elst` on an Android that does not shift) it is 0 —
 * one formula for both. The delay is interpreted exactly like the platform's
 * own SkipCutBuffer does: frames at the TRACK format's sample rate, i.e. a
 * duration.
 */
internal class GaplessTimeline(
    /** Extractor pts (µs) of the first sample, read before any seek. */
    val firstSampleUs: Long,
    /** Leading encoder delay (priming) to remove, as a duration (µs). */
    val delayUs: Double,
    /** Trailing encoder padding to remove, in OUTPUT frames (0 = none). */
    val paddingFrames: Long,
    /**
     * Gapless length in output frames when known exactly (an indexed MP3),
     * else null — the trailing [paddingFrames] holdback then trims the end.
     */
    val gaplessFrames: Long? = null
) {
    init {
        require(delayUs >= 0.0 && paddingFrames >= 0) { "negative delay/padding" }
    }

    /** Extractor pts (µs, may be fractional) of gapless [frame]. */
    fun ptsUsOf(frame: Long, sampleRate: Int): Double =
        firstSampleUs + delayUs + frame * 1e6 / sampleRate

    /** Gapless frame of the PCM whose extractor/decoder pts is [ptsUs]. */
    fun frameAt(ptsUs: Long, sampleRate: Int): Long =
        ((ptsUs - firstSampleUs - delayUs) * sampleRate / 1e6).roundToLong()

    /**
     * Where to seek the extractor so gapless [frame] decodes with at least
     * [prerollUs] of codec warm-up before it (an AAC frame overlaps its
     * predecessor; a fresh decoder's first frame is not the steady-state
     * output), or null when the target is near enough to the start that
     * decoding from the first sample (no seek at all) is both cheaper and
     * exact — that also keeps seeks clear of the negative pts a shifted
     * `elst` timeline gives priming samples.
     */
    fun seekUsFor(frame: Long, sampleRate: Int, prerollUs: Long): Long? {
        val t = (ptsUsOf(frame, sampleRate) - prerollUs).toLong()
        return if (t <= max(firstSampleUs, 0L)) null else t
    }

    companion object {
        /**
         * Codec warm-up decoded (and dropped) before a seek target in a
         * container stream: an AAC frame overlaps its predecessor, and a
         * fresh decoder's first frame is not steady-state output. 200 ms
         * covers several frames of any AAC flavor and costs ~nothing.
         * (Indexed MP3 pre-roll is in frames: [Mp3FrameIndex.firstFrameToFeed].)
         */
        const val SEEK_PREROLL_US = 200_000L

        /**
         * From the extractor's view of a track: [encoderDelay] and
         * [encoderPadding] (`encoder-delay`/`encoder-padding`, 0 when
         * absent) are frames at [formatSampleRate] (the track format's
         * rate); [outputSampleRate] is what the decoder really produces
         * (HE-AAC's SBR doubles it). Same scaling as the platform's
         * SkipCutBuffer.
         */
        fun fromTrack(
            firstSampleUs: Long,
            encoderDelay: Int,
            encoderPadding: Int,
            formatSampleRate: Int,
            outputSampleRate: Int
        ): GaplessTimeline {
            val rate = if (formatSampleRate > 0) formatSampleRate else outputSampleRate
            val delay = max(encoderDelay, 0)
            val padding = max(encoderPadding, 0)
            return GaplessTimeline(
                firstSampleUs = firstSampleUs,
                delayUs = delay * 1e6 / rate,
                paddingFrames = padding.toLong() * outputSampleRate / rate
            )
        }
    }
}

/**
 * Turns the decoder's PCM stream into exactly the gapless frames
 * [targetFrame], [targetFrame]+1, … — the contract the writer relies on
 * ("the first queued frame is media frame startFrame").
 *
 *  - Frames before the target (seek pre-roll, priming) are dropped.
 *  - If the first decoded frame is AFTER the target (a seek that resumed
 *    late), the gap is filled with silence so every later frame still plays
 *    at its own media position, instead of the whole track running early.
 *    [lateFrames] records how much was filled (logged by the caller).
 *  - The last [holdbackFrames] frames are withheld until more audio arrives
 *    and dropped at end of stream (trailing encoder padding), and nothing at
 *    or past [endFrame] (exclusive) is emitted when that is known.
 *
 * The first buffer's gapless start frame anchors the count; later buffers
 * are taken as contiguous (their own pts only re-confirm it), which keeps
 * µs rounding from ever duplicating or dropping a frame.
 */
internal class PcmTrimmer(
    private val targetFrame: Long,
    private val bytesPerFrame: Int,
    private val holdbackFrames: Long = 0L,
    private val endFrame: Long? = null,
    /** Bound on the silence fill; a larger gap is clamped (and logged). */
    private val maxFillFrames: Long = 10L * 48_000L
) {
    init {
        require(bytesPerFrame > 0 && holdbackFrames >= 0)
    }

    /** Gapless frame of the next decoded frame; null before the first buffer. */
    var position: Long? = null
        private set

    /** Silence frames inserted because decoding resumed past the target. */
    var lateFrames: Long = 0L
        private set

    /** Frames dropped before the target. */
    var droppedFrames: Long = 0L
        private set

    /** Next gapless frame to EMIT (after the fill); for the end clamp. */
    private var emitPosition = targetFrame

    private var tail = ByteArray(0)

    /**
     * Feeds one frame-aligned decoded buffer whose first frame is gapless
     * frame [firstFrame] (only the FIRST call's value is used) and returns
     * the chunks to queue, in order (possibly empty).
     */
    fun accept(pcm: ByteArray, firstFrame: Long): List<ByteArray> {
        require(pcm.size % bytesPerFrame == 0) { "unaligned PCM chunk" }
        val out = ArrayList<ByteArray>(2)
        var start = position ?: run {
            if (firstFrame > targetFrame) {
                val fill = min(firstFrame - targetFrame, maxFillFrames)
                lateFrames = firstFrame - targetFrame
                emit(ByteArray((fill * bytesPerFrame).toInt()), out)
            }
            firstFrame
        }
        val frames = (pcm.size / bytesPerFrame).toLong()
        position = start + frames
        var from = 0L
        if (start < targetFrame) {
            from = min(targetFrame - start, frames)
            droppedFrames += from
            start += from
        }
        if (from < frames) {
            emit(
                if (from == 0L) pcm else pcm.copyOfRange((from * bytesPerFrame).toInt(), pcm.size),
                out
            )
        }
        return out
    }

    /** End of stream: the withheld tail is the padding — dropped. */
    fun finish(): List<ByteArray> {
        tail = ByteArray(0)
        return emptyList()
    }

    private fun emit(data: ByteArray, out: MutableList<ByteArray>) {
        val holdBytes = holdbackFrames * bytesPerFrame
        var bytes = if (tail.isEmpty()) data else tail + data
        if (holdBytes > 0) {
            val release = (bytes.size - holdBytes).coerceAtLeast(0L).toInt()
            tail = bytes.copyOfRange(release, bytes.size)
            bytes = if (release == bytes.size) bytes else bytes.copyOfRange(0, release)
        }
        if (bytes.isEmpty()) return
        endFrame?.let { end ->
            val room = end - emitPosition
            if (room <= 0) return
            val frames = (bytes.size / bytesPerFrame).toLong()
            if (frames > room) bytes = bytes.copyOfRange(0, (room * bytesPerFrame).toInt())
        }
        emitPosition += bytes.size / bytesPerFrame
        out.add(bytes)
    }
}
