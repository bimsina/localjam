package dev.bimsina.localjam_audio

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Item 10: the same argument and file bounds as iOS/macOS and the desktop
 * core. Android accepted any positive finite rate, any anchor, and loaded
 * files every playAt then refused.
 */
internal class PlaybackLimitsTest {
    private val now = 5_000_000_000L

    // ------------------------------------------------------------------ rate

    @Test
    fun rate_acceptsExactlyOneThirtySecondToThirtyTwo() {
        for (ok in listOf(1.0 / 32.0, 0.5, 1.0, 1.005, 32.0)) {
            assertTrue(PlaybackLimits.isValidRate(ok), "$ok")
            assertNull(PlaybackLimits.playAtArgsProblem(now, ok, now))
        }
        for (bad in listOf(0.0, -1.0, 0.03, 32.0001, 64.0, Double.NaN, Double.POSITIVE_INFINITY)) {
            assertTrue(!PlaybackLimits.isValidRate(bad), "$bad")
            assertNotNull(PlaybackLimits.playAtArgsProblem(now, bad, now), "$bad")
        }
    }

    // ---------------------------------------------------------------- anchor

    @Test
    fun anchor_atMostOneHourAhead() {
        assertNull(PlaybackLimits.playAtArgsProblem(now + 3_600_000_000L, 1.0, now))
        assertNotNull(PlaybackLimits.playAtArgsProblem(now + 3_600_000_001L, 1.0, now))
        assertNotNull(PlaybackLimits.playAtArgsProblem(now + 7_200_000_000L, 1.0, now))
        assertNotNull(PlaybackLimits.playAtArgsProblem(Long.MAX_VALUE, 1.0, now))
    }

    @Test
    fun anchor_farInThePast_isNotABadArg_butWrapsNeither() {
        // Long arithmetic would wrap MIN_VALUE - now into "far ahead".
        assertNull(PlaybackLimits.playAtArgsProblem(Long.MIN_VALUE, 1.0, now))
        assertNull(
            PlaybackLimits.planStart(Long.MIN_VALUE, 0, 1.0, now, 150_000, 44_100, 441_000),
            "a start that far behind is outside the file: bad_position",
        )
    }

    // ------------------------------------------------------------- planStart

    @Test
    fun planStart_onTimeAnchor_isKept() {
        val p = PlaybackLimits.planStart(now + 300_000, 1_000_000, 1.0, now, 150_000, 48_000, 480_000)!!
        assertEquals(now + 300_000, p.anchorUs)
        assertEquals(48_000, p.startFrame)
        assertEquals(1_000_000, p.anchorMediaUs)
    }

    @Test
    fun planStart_lateAnchor_isReAnchoredWithThePositionAdvancedAtRate() {
        // 850 ms late (anchor = now - 700 ms; earliest = now + 150 ms) at 1.5×.
        val p = PlaybackLimits.planStart(now - 700_000, 0, 1.5, now, 150_000, 48_000, 4_800_000)!!
        assertEquals(now + 150_000, p.anchorUs)
        assertEquals(1_275_000, p.startPosUs)
        assertEquals(61_200, p.startFrame)
        assertEquals(1_275_000, p.anchorMediaUs)
    }

    @Test
    fun planStart_anchorMedia_isFrameExact() {
        val p = PlaybackLimits.planStart(now + 300_000, 10, 1.0, now, 150_000, 44_100, 441_000)!!
        assertEquals(0, p.startFrame) // 10 µs rounds to frame 0
        assertEquals(0, p.anchorMediaUs)
    }

    @Test
    fun planStart_outsideTheFile_orOverflowing_isNull() {
        val frames = 441_000L // 10 s @ 44.1 kHz
        assertNull(PlaybackLimits.planStart(now + 300_000, -1_000_000, 1.0, now, 150_000, 44_100, frames))
        assertNull(PlaybackLimits.planStart(now + 300_000, 10_000_000, 1.0, now, 150_000, 44_100, frames))
        // Used to wrap a Long to negative and only fail by luck.
        assertNull(PlaybackLimits.planStart(now - 1_000, Long.MAX_VALUE, 1.0, now, 150_000, 44_100, frames))
        assertNull(PlaybackLimits.planStart(now + 300_000, Long.MIN_VALUE, 1.0, now, 150_000, 44_100, frames))
    }

    // ------------------------------------------------------------ file limits

    @Test
    fun fileProblem_acceptsOrdinaryMusic() {
        assertNull(PlaybackLimits.fileProblem(44_100, 2, 180_000_000))
        assertNull(PlaybackLimits.fileProblem(48_000, 6, 1_000))
        assertNull(PlaybackLimits.fileProblem(8_000, 1, 1_000_000))
    }

    @Test
    fun fileProblem_refusesZeroFrameFiles() {
        assertNotNull(PlaybackLimits.fileProblem(44_100, 2, 0))
        assertNotNull(PlaybackLimits.fileProblem(44_100, 2, -1))
        // 10 µs at 44.1 kHz is 0.44 frames: every playAt was bad_position.
        assertNotNull(PlaybackLimits.fileProblem(44_100, 2, 10))
    }

    @Test
    fun fileProblem_refusesAbsurdFormats() {
        assertNotNull(PlaybackLimits.fileProblem(32, 1, 3_000_000), "32 Hz (iOS integration test)")
        assertNotNull(PlaybackLimits.fileProblem(3_999, 1, 3_000_000))
        assertNotNull(PlaybackLimits.fileProblem(384_001, 2, 3_000_000))
        assertNotNull(PlaybackLimits.fileProblem(Int.MAX_VALUE, 2, 3_000_000))
        assertNotNull(PlaybackLimits.fileProblem(44_100, 0, 3_000_000))
        // A crafted duration: > 2^37 frames, and it would overflow the
        // durationUs × sampleRate frame count.
        assertNotNull(PlaybackLimits.fileProblem(44_100, 2, Long.MAX_VALUE))
        assertNotNull(PlaybackLimits.fileProblem(8_000, 1, (1L shl 37) / 8_000 * 1_000_000 + 2_000_000))
    }

    // ---------------------------------------------------------- silence math

    @Test
    fun silenceFrames_isNotClampedWhenTheTargetAlreadyPassed() {
        // The cold-start case measured on the emulator: the first mature
        // timestamp said frame 1088 presented at 320.680409610 s, the target
        // was 320.396992 s. S = 1088 − 13604 = −12516; clamped to 0 the media
        // started 260 ms late.
        val s = PlaybackLimits.silenceFrames(1_088, 320_680_409_610L, 320_396_992_000L, 48_000, 1.0)
        assertEquals(-12_516, s)
        // Writer: written = 14 400 → trims written − S = 26 916 media frames,
        // so the first media frame (source frame `written`) carries media
        // position P + (written − S)/sr, exactly on the session line.
        assertEquals(26_916, 14_400 - s)
    }

    @Test
    fun silenceFrames_padsForAFutureTarget_atRate() {
        assertEquals(
            1_000 + 7_200,
            PlaybackLimits.silenceFrames(1_000, 1_000_000_000L, 1_100_000_000L, 48_000, 1.5),
        )
    }
}
