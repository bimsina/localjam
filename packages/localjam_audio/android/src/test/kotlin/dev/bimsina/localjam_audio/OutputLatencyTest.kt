package dev.bimsina.localjam_audio

import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * The latency contract (README "positionUs", [OutputLatency]): Dart schedules
 * `playAt` at `heardInstant − outputLatencyUs`, so `outputLatencyUs` must be
 * how much later than `nativeTimeUs` the scheduled frame is heard. Android
 * primes against PRESENTED frames, so that is 0 — a device whose hidden
 * latency property says 40 ms used to have it subtracted on top, and every
 * schedule was heard 40 ms early.
 */
internal class OutputLatencyTest {
    private val sampleRate = 48_000
    private val pipelineLatencyNs = 40_000_000L // what the device's property claims
    private val writeStartNs = 5_000_000_000L

    /** A sink whose frame f leaves the mixer at f/sr and is HEARD 40 ms later. */
    private fun presentedNs(frame: Long): Long =
        writeStartNs + frame * 1_000_000_000L / sampleRate + pipelineLatencyNs

    /** Where the frame the plugin schedules for [nativeTimeUs] is heard. */
    private fun heardNsForSchedule(nativeTimeUs: Long): Long {
        // A mature AudioTimestamp: frame F_ts presented (heard) at T_ts —
        // the pipeline latency is in it.
        val tsFrame = 9_600L
        val s = PlaybackLimits.silenceFrames(
            tsFrame, presentedNs(tsFrame), nativeTimeUs * 1000, sampleRate, 1.0
        )
        return presentedNs(s)
    }

    @Test
    fun aScheduleShiftedByTheReportedLatency_isHeardOnTime_withANonzeroDeviceLatency() {
        val heardAtUs = 7_000_000L // the room wants the anchor frame heard here
        val property = OutputLatency.propertyUs("40")
        assertEquals(40_000L, property) // the device does report a latency

        // What Dart sends: the anchor shifted by the REPORTED latency.
        val reported = OutputLatency.SCHEDULING_US
        val heardNs = heardNsForSchedule(heardAtUs - reported)
        assertTrue(abs(heardNs - heardAtUs * 1000) <= 1_000_000_000L / sampleRate)

        // Had the property been reported, Dart's shift would land it early by
        // the whole latency: the double count this pins.
        val doubleCounted = heardNsForSchedule(heardAtUs - property)
        assertTrue(abs((heardAtUs * 1000 - doubleCounted) - pipelineLatencyNs) <= 1_000_000_000L / sampleRate)
    }

    @Test
    fun propertyUs_parsesMilliseconds_andRejectsGarbage() {
        assertEquals(40_000L, OutputLatency.propertyUs("40"))
        assertEquals(12_500L, OutputLatency.propertyUs("12.5"))
        assertEquals(0L, OutputLatency.propertyUs(null))
        assertEquals(0L, OutputLatency.propertyUs("n/a"))
        assertEquals(0L, OutputLatency.propertyUs("-3"))
        assertEquals(0L, OutputLatency.propertyUs("NaN"))
    }
}
