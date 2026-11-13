package dev.bimsina.localjam_audio

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Stereo 16-bit frames whose two samples encode the raw index r. */
private fun frames(firstRaw: Long, n: Int): ByteArray {
    val out = ByteArray(n * 4)
    for (i in 0 until n) {
        val r = firstRaw + i
        val lo = (r and 0x7FFF).toInt()
        val hi = (r shr 15).toInt()
        out[4 * i] = lo.toByte(); out[4 * i + 1] = (lo shr 8).toByte()
        out[4 * i + 2] = hi.toByte(); out[4 * i + 3] = (hi shr 8).toByte()
    }
    return out
}

private fun rawAt(pcm: ByteArray, frame: Int): Long {
    val o = 4 * frame
    val lo = (pcm[o].toInt() and 0xFF) or (pcm[o + 1].toInt() and 0xFF shl 8)
    val hi = (pcm[o + 2].toInt() and 0xFF) or (pcm[o + 3].toInt() and 0xFF shl 8)
    return (hi.toLong() shl 15) or lo.toLong()
}

/**
 * The Android decode path's media-position mapping, end to end against a
 * model of the platform (MPEG4Extractor timestamps and PREVIOUS_SYNC seeks,
 * a zero-delay AAC decoder whose output pts is its input pts — the
 * c2.android.aac contract once the platform's SkipCutBuffer is off).
 *
 * Every decoded PCM frame carries its RAW decoder-output index (priming
 * included), so "which sample plays as media frame P" is checked exactly:
 * the gapless-correct answer — what AVAudioFile and decodeAudioData play —
 * is raw index P + priming.
 */
internal class GaplessTimelineTest {
    /** One AAC-in-MP4 file as Android sees it. */
    private class Mp4Model(
        val sampleRate: Int,
        val auFrames: Int,
        val auCount: Int,
        val delay: Int,
        val padding: Int,
        /** MPEG4Extractor (Android 10+) shifted pts by an `elst` media time. */
        val shifted: Boolean
    ) {
        val shift = if (shifted) delay else 0

        /** Extractor pts (µs) of AU k: (raw − shift)·1e6/sr, truncated like C. */
        fun ptsUs(k: Int): Long = (k.toLong() * auFrames - shift) * 1_000_000L / sampleRate

        /** seekTo(t, SEEK_TO_PREVIOUS_SYNC): last AU at/before t (every AU is sync). */
        fun seek(t: Long): Int {
            var k = 0
            while (k + 1 < auCount && ptsUs(k + 1) <= t) k++
            return k
        }

        fun timeline() = GaplessTimeline.fromTrack(
            firstSampleUs = ptsUs(0),
            encoderDelay = delay,
            encoderPadding = padding,
            formatSampleRate = sampleRate,
            outputSampleRate = sampleRate
        )

        /** Decoder output for AU k: pts = input pts, PCM = raw frames of AU k. */
        fun pcm(k: Int): ByteArray = frames(k.toLong() * auFrames, auFrames)

        val gaplessTotal get() = auCount.toLong() * auFrames - delay - padding
    }

    /** Runs the plugin's algorithm: seek with pre-roll, decode, trim. */
    private fun play(m: Mp4Model, startFrame: Long): ByteArray {
        val tl = m.timeline()
        val seek = tl.seekUsFor(startFrame, m.sampleRate, GaplessTimeline.SEEK_PREROLL_US)
        val firstAu = if (seek == null) 0 else m.seek(seek)
        val trimmer = PcmTrimmer(startFrame, 4, tl.paddingFrames, tl.gaplessFrames)
        val out = java.io.ByteArrayOutputStream()
        for (k in firstAu until m.auCount) {
            for (c in trimmer.accept(m.pcm(k), tl.frameAt(m.ptsUs(k), m.sampleRate))) out.write(c)
        }
        trimmer.finish()
        assertEquals(0L, trimmer.lateFrames, "pre-roll never resumes past the target")
        return out.toByteArray()
    }

    private fun assertGaplessPlayback(m: Mp4Model, starts: List<Long>) {
        for (p in starts) {
            val pcm = play(m, p)
            val frames = pcm.size / 4
            assertEquals(m.gaplessTotal - p, frames.toLong(), "length from $p")
            if (frames > 0) {
                assertEquals(p + m.delay, rawAt(pcm, 0), "media frame $p (shifted=${m.shifted})")
                assertEquals(p + m.delay + frames - 1, rawAt(pcm, frames - 1), "contiguous from $p")
            }
        }
    }

    private val starts = listOf(
        0L, 1L, 63L, 64L, 959L, 960L, 1023L, 1024L, 2111L, 2112L, 3071L, 3072L,
        4409L, 30_001L, 44_100L, 65_535L, 100_000L
    )

    @Test
    fun itunsmpbOnly_rawTimeline_playsTheGaplessSample() {
        // test-media/*.m4a: afconvert AAC, iTunSMPB priming 2112 /
        // remainder 996, no edts — MPEG4Extractor keeps raw pts.
        assertGaplessPlayback(Mp4Model(22050, 1024, 120, 2112, 996, shifted = false), starts)
    }

    @Test
    fun elst_shiftedTimeline_playsTheGaplessSample() {
        // FFmpeg's AAC in MP4: elst media_time 1024 (Android 10+ shifts pts)…
        assertGaplessPlayback(Mp4Model(22050, 1024, 120, 1024, 820, shifted = true), starts)
        // …and an Apple-style elst with 2112 priming at 44.1 kHz.
        assertGaplessPlayback(Mp4Model(44100, 1024, 200, 2112, 576, shifted = true), starts)
    }

    @Test
    fun elst_unshiftedTimeline_olderAndroid_playsTheGaplessSample() {
        assertGaplessPlayback(Mp4Model(44100, 1024, 200, 2112, 576, shifted = false), starts)
    }

    @Test
    fun noPriming_identity() {
        val m = Mp4Model(48000, 1024, 100, 0, 0, shifted = false)
        assertGaplessPlayback(m, starts)
        assertEquals(0L, m.timeline().frameAt(m.ptsUs(7), 48000) - 7 * 1024)
    }

    @Test
    fun platformSkipCut_decouplesPtsFromPcm_theLogcatFinding() {
        // Before: MediaCodec trimmed 2112 priming frames and held back the
        // 996-frame padding (SkipCutBuffer) while leaving buffer pts alone.
        // Model that on test-media's file from AU 0: the first NON-EMPTY
        // buffer is AU 3, pts frame 3072 — exactly the "seek resumed PAST
        // the target (ptsFrame=3072 startFrame=0)" warning — yet its PCM
        // starts at raw 2112 = gapless frame 0. Pts no longer described the
        // PCM, so no pts arithmetic could be right for every seek.
        val skip = 2112L
        val cut = 996L
        var written = 0L
        var read = 0L
        var firstNonEmptyAu = -1
        for (k in 0 until 10) {
            written = maxOf(0L, (k + 1) * 1024L - skip)
            val avail = written - cut - read
            if (avail > 0) {
                firstNonEmptyAu = k
                break
            }
        }
        assertEquals(3, firstNonEmptyAu)
        assertEquals(3072L, firstNonEmptyAu * 1024L)
        // The new path never asks the platform to trim, and maps that same
        // situation (start 0) to raw 2112 at media frame 0.
        val m = Mp4Model(22050, 1024, 120, 2112, 996, shifted = false)
        assertEquals(2112L, rawAt(play(m, 0), 0))
    }

    @Test
    fun seekUsFor_noSeekNearTheStart_prerollOtherwise() {
        val tl = GaplessTimeline(firstSampleUs = 0, delayUs = 2112 * 1e6 / 22050, paddingFrames = 0)
        assertNull(tl.seekUsFor(0, 22050, 200_000))
        assertNull(tl.seekUsFor(2000, 22050, 200_000)) // still within pre-roll of the start
        val s = tl.seekUsFor(22050, 22050, 200_000)!!
        assertEquals((1_000_000.0 + 2112 * 1e6 / 22050 - 200_000).toLong(), s)
        // Shifted timeline: never a negative seek.
        val shifted = GaplessTimeline(-95_782, 2112 * 1e6 / 22050, 0)
        assertNull(shifted.seekUsFor(3000, 22050, 200_000))
        assertTrue(shifted.seekUsFor(22050, 22050, 200_000)!! > 0)
    }

    @Test
    fun fromTrack_scalesDelayAndPaddingLikeThePlatform() {
        // HE-AAC: format reports the core rate, the decoder outputs 2×.
        val tl = GaplessTimeline.fromTrack(0, 2112, 1000, 22050, 44100)
        assertEquals(2112 * 1e6 / 22050, tl.delayUs, 1e-6)
        assertEquals(2000L, tl.paddingFrames)
        assertEquals(0L, tl.frameAt((2112 * 1e6 / 22050).toLong() + 1, 44100))
        assertEquals(44100L, tl.frameAt(1_000_000L + (2112 * 1e6 / 22050).toLong(), 44100))
        // Negative keys (garbage metadata) read as none.
        val none = GaplessTimeline.fromTrack(0, -5, -5, 44100, 44100)
        assertEquals(0.0, none.delayUs)
        assertEquals(0L, none.paddingFrames)
    }

    @Test
    fun trimmer_lateStart_fillsSilenceSoLaterFramesKeepTheirPositions() {
        val t = PcmTrimmer(targetFrame = 100, bytesPerFrame = 4)
        val out = t.accept(frames(1000, 10), firstFrame = 130).fold(ByteArray(0)) { a, b -> a + b }
        assertEquals(30L, t.lateFrames)
        assertEquals(40, out.size / 4)
        for (i in 0 until 30) assertEquals(0L, rawAt(out, i))
        assertEquals(1000L, rawAt(out, 30))
    }

    @Test
    fun trimmer_dropsAcrossBuffers_andIgnoresLaterPts() {
        val t = PcmTrimmer(targetFrame = 2500, bytesPerFrame = 4)
        assertTrue(t.accept(frames(0, 1024), 0).isEmpty())
        assertTrue(t.accept(frames(1024, 1024), 999_999).isEmpty()) // pts ignored after the first
        val out = t.accept(frames(2048, 1024), 2048)
        assertEquals(1, out.size)
        assertEquals(2500L, rawAt(out[0], 0))
        assertEquals(2500L, t.droppedFrames)
    }

    @Test
    fun trimmer_holdbackDropsThePaddingAtTheEnd() {
        val t = PcmTrimmer(targetFrame = 0, bytesPerFrame = 4, holdbackFrames = 1500)
        val got = ArrayList<ByteArray>()
        got += t.accept(frames(0, 1024), 0)
        assertTrue(got.isEmpty(), "first 1024 frames all withheld")
        got += t.accept(frames(1024, 1024), 1024)
        got += t.accept(frames(2048, 1024), 2048)
        assertTrue(t.finish().isEmpty())
        val all = got.fold(ByteArray(0)) { a, b -> a + b }
        assertEquals(3072 - 1500, all.size / 4)
        assertContentEquals(frames(0, 3072 - 1500), all)
    }

    @Test
    fun trimmer_endFrameClamps() {
        val t = PcmTrimmer(targetFrame = 10, bytesPerFrame = 4, endFrame = 1000)
        val all = (t.accept(frames(0, 1024), 0) + t.accept(frames(1024, 1024), 1024))
            .fold(ByteArray(0)) { a, b -> a + b }
        assertEquals(990, all.size / 4)
        assertEquals(10L, rawAt(all, 0))
        assertEquals(999L, rawAt(all, 989))
    }

    @Test
    fun trimmer_rejectsUnalignedChunks() {
        val t = PcmTrimmer(targetFrame = 0, bytesPerFrame = 4)
        assertFailsWith<IllegalArgumentException> { t.accept(ByteArray(6), 0) }
    }
}
