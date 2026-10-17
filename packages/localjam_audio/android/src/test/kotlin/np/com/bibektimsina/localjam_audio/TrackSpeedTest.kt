package np.com.bibektimsina.localjam_audio

import android.media.AudioTrack
import android.media.PlaybackParams
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import org.mockito.ArgumentMatchers.any
import org.mockito.Mockito

/**
 * Item 10: a refused playback speed used to be logged and ignored ("playing
 * at 1.0") while every piece of the schedule math still assumed ×rate — the
 * start and every position silently wrong.
 */
internal class TrackSpeedTest {
    private class FakeTrack(val lowLatency: Boolean, val acceptsSpeed: Boolean) {
        var released = false
    }

    private fun open(
        rate: Double,
        preferLowLatency: Boolean,
        lowLatencyAccepts: Boolean,
        normalAccepts: Boolean,
        grantsLowLatency: Boolean = true,
        created: MutableList<FakeTrack>,
    ) = TrackSpeed.openAtRate(
        rate,
        preferLowLatency,
        create = { ll ->
            val granted = ll && grantsLowLatency
            FakeTrack(granted, if (granted) lowLatencyAccepts else normalAccepts).also { created += it }
        },
        applySpeed = { t, _ -> t.acceptsSpeed },
        isLowLatency = { it.lowLatency },
        release = { it.released = true },
    )

    @Test
    fun anAcceptingTrack_isUsedAsIs() {
        val created = mutableListOf<FakeTrack>()
        val o = open(1.0, true, lowLatencyAccepts = true, normalAccepts = true, created = created)!!
        assertEquals(1, created.size)
        assertFalse(o.lowLatencyRefusedSpeed)
        assertFalse(o.track.released)
    }

    @Test
    fun aLowLatencyTrackRefusingTheSpeed_isReplacedByANormalOne() {
        val created = mutableListOf<FakeTrack>()
        val o = open(1.05, true, lowLatencyAccepts = false, normalAccepts = true, created = created)!!
        assertEquals(2, created.size)
        assertTrue(created[0].released, "the refusing track is freed")
        assertFalse(o.track.lowLatency)
        assertTrue(o.lowLatencyRefusedSpeed, "remembered: later tracks skip low latency")
    }

    @Test
    fun aRateNoTrackAccepts_isRefused_andEveryTrackFreed() {
        val created = mutableListOf<FakeTrack>()
        assertNull(open(25.0, true, lowLatencyAccepts = false, normalAccepts = false, created = created))
        assertEquals(2, created.size)
        assertTrue(created.all { it.released })
    }

    @Test
    fun aNormalTrackRefusing_isNotRetried() {
        val created = mutableListOf<FakeTrack>()
        assertNull(
            open(
                25.0, true, lowLatencyAccepts = true, normalAccepts = false,
                grantsLowLatency = false, created = created,
            )
        )
        assertEquals(1, created.size, "low latency was not granted: retrying changes nothing")
        assertTrue(created[0].released)
        assertNull(open(25.0, false, true, false, created = created.also { it.clear() }))
        assertEquals(1, created.size)
    }

    @Test
    fun bufferFactor_coversTheSpeed() {
        // Measured on an API 36 emulator: speed 4 on a 3× buffer failed with
        // "setPlaybackRate ... failed (buffer size)".
        assertEquals(3, TrackSpeed.bufferFactor(1.0))
        assertEquals(3, TrackSpeed.bufferFactor(1.005))
        assertEquals(3, TrackSpeed.bufferFactor(2.0))
        assertEquals(5, TrackSpeed.bufferFactor(4.0))
        assertEquals(12, TrackSpeed.bufferFactor(10.5))
        assertEquals(33, TrackSpeed.bufferFactor(32.0))
    }

    @Test
    fun apply_reportsARefusalInsteadOfThrowing() {
        val refusing = Mockito.mock(AudioTrack::class.java)
        Mockito.doThrow(IllegalArgumentException("setPlaybackParams failed"))
            .`when`(refusing).playbackParams = any(PlaybackParams::class.java)
        assertFalse(TrackSpeed.apply(refusing, 1.05))

        val dead = Mockito.mock(AudioTrack::class.java)
        Mockito.doThrow(IllegalStateException("dead"))
            .`when`(dead).playbackParams = any(PlaybackParams::class.java)
        assertFalse(TrackSpeed.apply(dead, 1.05))

        assertTrue(TrackSpeed.apply(Mockito.mock(AudioTrack::class.java), 1.05))
    }
}
