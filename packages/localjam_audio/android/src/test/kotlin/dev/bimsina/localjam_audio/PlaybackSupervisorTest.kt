package dev.bimsina.localjam_audio

import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.media.AudioTrack
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import dev.bimsina.localjam_audio.AudioFocusPolicy.Effect

/**
 * The wiring between generations, the focus policy, route decisions and
 * failure reporting — the sequences the plugin drives across its handler,
 * main, writer and decoder threads, replayed deterministically.
 */
internal class PlaybackSupervisorTest {
    private val wired = RouteDevice(AudioDeviceInfo.TYPE_WIRED_HEADPHONES, "", "")
    private val speaker = RouteDevice(AudioDeviceInfo.TYPE_BUILTIN_SPEAKER, "Pixel", "")

    /** A playAt that negotiated focus and installed its schedule. */
    private fun PlaybackSupervisor.installedSchedule(): Long {
        val t = beginPlayAt()
        val d = negotiateFocus(t, false, if (t.focus.requestFocus) FocusRequestResult.GRANTED else null)
        assertTrue(d.play)
        assertTrue(mayInstall(t))
        return t.generation
    }

    // --------------------------------------------- item 4: failure → event

    @Test
    fun decodeFailure_isPlaybackErrorDecodeFailed_notEngineRestarted() {
        // The bug: a decode error reached Dart as engineRestarted, which the
        // engine answers by re-applying — recreating AudioTrack + MediaCodec
        // and re-requesting focus every ~150 ms, forever.
        val s = PlaybackSupervisor()
        val gen = s.installedSchedule()
        val event = s.onScheduleFailure(gen, ScheduleFailure.DECODE, "codec exploded")
        assertEquals(
            mapOf("type" to "playbackError", "code" to "decode_failed", "message" to "codec exploded"),
            event,
        )
        assertFalse(s.isCurrent(gen), "output is retired with the report")
    }

    @Test
    fun deadTrack_isEngineRestarted() {
        val s = PlaybackSupervisor()
        val gen = s.installedSchedule()
        assertEquals(
            mapOf("type" to "engineRestarted"),
            s.onScheduleFailure(gen, ScheduleFailure.TRACK_DEAD, "dead object"),
        )
    }

    @Test
    fun otherWriterFailures_arePlaybackErrorWriterFailed() {
        val s = PlaybackSupervisor()
        val gen = s.installedSchedule()
        assertEquals("writer_failed", s.onScheduleFailure(gen, ScheduleFailure.WRITER, "x")!!["code"])
    }

    @Test
    fun writeErrorCodes_onlyADeadObjectIsADeadTrack() {
        assertEquals(ScheduleFailure.TRACK_DEAD, ScheduleFailure.ofWriteError(AudioTrack.ERROR_DEAD_OBJECT))
        assertEquals(ScheduleFailure.WRITER, ScheduleFailure.ofWriteError(AudioTrack.ERROR_INVALID_OPERATION))
        assertEquals(ScheduleFailure.WRITER, ScheduleFailure.ofWriteError(AudioTrack.ERROR_BAD_VALUE))
        assertEquals(ScheduleFailure.WRITER, ScheduleFailure.ofWriteError(AudioTrack.ERROR))
    }

    @Test
    fun aTrackThatDiesOnEveryReApply_escalatesToPlaybackError() {
        val s = PlaybackSupervisor(maxConsecutiveRestarts = 3)
        repeat(3) {
            val gen = s.installedSchedule()
            assertEquals("engineRestarted", s.onScheduleFailure(gen, ScheduleFailure.TRACK_DEAD, "d")!!["type"])
        }
        val gen = s.installedSchedule()
        val event = s.onScheduleFailure(gen, ScheduleFailure.TRACK_DEAD, "d")!!
        assertEquals("playbackError", event["type"], "the 4th in a row is not a reroute")
        assertEquals("writer_failed", event["code"])
        // And the budget starts over (the Dart engine retries with backoff).
        val next = s.installedSchedule()
        assertEquals("engineRestarted", s.onScheduleFailure(next, ScheduleFailure.TRACK_DEAD, "d")!!["type"])
    }

    @Test
    fun mediaReachingTheTrack_resetsTheRestartBudget() {
        val s = PlaybackSupervisor(maxConsecutiveRestarts = 1)
        val first = s.installedSchedule()
        s.onScheduleFailure(first, ScheduleFailure.TRACK_DEAD, "d")
        val healthy = s.installedSchedule()
        s.onMediaStreaming(healthy) // played for a while, then a reroute killed it
        assertEquals("engineRestarted", s.onScheduleFailure(healthy, ScheduleFailure.TRACK_DEAD, "d")!!["type"])
    }

    @Test
    fun aNewFile_resetsTheRestartBudget() {
        val s = PlaybackSupervisor(maxConsecutiveRestarts = 1)
        s.onScheduleFailure(s.installedSchedule(), ScheduleFailure.TRACK_DEAD, "d")
        s.onLoad()
        assertEquals(
            "engineRestarted",
            s.onScheduleFailure(s.installedSchedule(), ScheduleFailure.TRACK_DEAD, "d")!!["type"],
        )
    }

    // ------------------------------------------------- generation supersession

    @Test
    fun aSupersededSchedule_failsSilently() {
        val s = PlaybackSupervisor()
        val old = s.installedSchedule()
        val current = s.installedSchedule() // Dart re-anchored
        assertNull(s.onScheduleFailure(old, ScheduleFailure.DECODE, "late"), "the new schedule owns the outcome")
        assertTrue(s.isCurrent(current), "and it keeps playing")
        assertNull(s.onScheduleFailure(old, ScheduleFailure.TRACK_DEAD, "late"))
    }

    @Test
    fun aFailureReportedTwice_isReportedOnce() {
        // The decoder reports, and the writer then pops the failed queue.
        val s = PlaybackSupervisor()
        val gen = s.installedSchedule()
        assertNotNull(s.onScheduleFailure(gen, ScheduleFailure.DECODE, "x"))
        assertNull(s.onScheduleFailure(gen, ScheduleFailure.DECODE, "x"))
    }

    @Test
    fun anyStop_retiresAPlayAtInFlight() {
        val s = PlaybackSupervisor()
        val t = s.beginPlayAt()
        s.retire() // Dart stop / session end
        assertFalse(s.mayInstall(t))
        val t2 = s.beginPlayAt()
        s.onLoad()
        assertFalse(s.mayInstall(t2))
        val t3 = s.beginPlayAt()
        s.onReleased()
        assertFalse(s.mayInstall(t3))
    }

    // -------------------------------------- items 3/4: gates around a playAt

    @Test
    fun focusLossWhilePlayAtNegotiates_neverInstalls_andTheGainEndsIt() {
        val s = PlaybackSupervisor()
        val t = s.beginPlayAt()
        val effects = s.onFocusChange(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT, false)
        assertEquals(listOf(Effect.STOP_OUTPUT, Effect.EMIT_BEGAN), effects)
        val d = s.negotiateFocus(t, false, FocusRequestResult.GRANTED)
        assertFalse(d.play)
        assertFalse(s.mayInstall(t), "the loss retired the generation")
        assertEquals(
            listOf(Effect.EMIT_ENDED_SHOULD_RESUME),
            s.onFocusChange(AudioManager.AUDIOFOCUS_GAIN, false),
            "Dart is told it may re-anchor — it used to stay interrupted forever",
        )
    }

    @Test
    fun focusLossAfterTheGrant_stillStopsTheInstall() {
        val s = PlaybackSupervisor()
        val t = s.beginPlayAt()
        assertTrue(s.negotiateFocus(t, false, FocusRequestResult.GRANTED).play)
        s.onFocusChange(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT, false) // while creating the track
        assertFalse(s.mayInstall(t))
    }

    @Test
    fun callWhilePlaying_retiresTheSchedule() {
        val s = PlaybackSupervisor()
        val gen = s.installedSchedule()
        assertEquals(listOf(Effect.STOP_OUTPUT, Effect.EMIT_BEGAN), s.onModeChanged(true))
        assertFalse(s.isCurrent(gen))
        assertNull(s.onScheduleFailure(gen, ScheduleFailure.TRACK_DEAD, "stopped by the call"))
    }

    @Test
    fun duckingDoesNotRetireTheSchedule() {
        val s = PlaybackSupervisor()
        val gen = s.installedSchedule()
        assertEquals(listOf(Effect.DUCK), s.onFocusChange(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK, false))
        assertTrue(s.isCurrent(gen))
    }

    @Test
    fun aDriftReAnchor_doesNotRequestHeldFocus() {
        val s = PlaybackSupervisor()
        s.installedSchedule()
        assertFalse(s.beginPlayAt().focus.requestFocus)
    }

    @Test
    fun unplugWhilePlayAtStarts_neverInstalls() {
        val s = PlaybackSupervisor()
        s.routes.observe(wired)
        val t = s.beginPlayAt()
        assertNull(s.playbackHold(0))
        assertTrue(s.negotiateFocus(t, false, FocusRequestResult.GRANTED).play)
        val noisy = s.onBecomingNoisy(1_000L, wired.id, speaker.id)
        assertTrue(noisy.stopOutput)
        assertFalse(s.mayInstall(t), "it would have played on the departing headphones")
    }

    @Test
    fun aPlayAtRightAfterAnUnplug_isHeld_andToldWhy() {
        val s = PlaybackSupervisor()
        s.routes.observe(wired)
        s.onBecomingNoisy(0, wired.id, speaker.id)
        val hold = s.playbackHold(300_000_000L)
        assertNotNull(hold)
        assertTrue(hold.oldDeviceUnavailable)
        assertEquals(speaker.id, hold.routeId)
    }

    @Test
    fun removalOfTheActiveRoute_retires_butAnIdleOneDoesNot() {
        val s = PlaybackSupervisor()
        s.routes.observe(wired)
        val gen = s.installedSchedule()
        val idle = RouteDevice(AudioDeviceInfo.TYPE_BLUETOOTH_A2DP, "Buds", "AA:BB:CC:DD:EE:01")
        assertFalse(s.onDevicesRemoved(0, listOf(idle), wired).stopOutput)
        assertTrue(s.isCurrent(gen))
        assertTrue(s.onDevicesRemoved(0, listOf(wired), speaker).stopOutput)
        assertFalse(s.isCurrent(gen))
    }
}
