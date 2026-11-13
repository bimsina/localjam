package dev.bimsina.localjam_audio

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertSame
import kotlin.test.assertTrue

/**
 * Event payloads must match exactly what `LocaljamAudio._decodeEvent`
 * reads (contract items 3–5): a misspelt key decodes as "absent".
 */
internal class AudioEventsTest {
    @Test
    fun routeChanged_carriesLatencyRouteIdAndOldDeviceUnavailable() {
        val p = AudioEvents.routeChanged(12_000L, "speaker:0123456789abcdef", true)
        assertEquals(
            mapOf(
                "type" to "routeChanged",
                "outputLatencyUs" to 12_000L,
                "routeId" to "speaker:0123456789abcdef",
                "oldDeviceUnavailable" to true,
            ),
            p,
        )
        assertTrue(p["outputLatencyUs"] is Long, "decodes as a Dart int")
    }

    @Test
    fun routeChanged_omitsAnUnknownRouteId_neverSendsNull() {
        val p = AudioEvents.routeChanged(0L, null, false)
        assertFalse(p.containsKey("routeId"))
        assertEquals(false, p["oldDeviceUnavailable"])
    }

    @Test
    fun interruptions() {
        assertEquals(mapOf("type" to "interruptionBegan"), AudioEvents.interruptionBegan())
        // Permanent focus loss: Dart maps shouldResume == false on a began
        // to "another app is playing" (no interruptionEnded will follow).
        assertEquals(
            mapOf("type" to "interruptionBegan", "shouldResume" to false),
            AudioEvents.interruptionBegan(shouldResume = false),
        )
        assertEquals(
            mapOf("type" to "interruptionEnded", "shouldResume" to true),
            AudioEvents.interruptionEnded(shouldResume = true),
        )
    }

    @Test
    fun playbackError_hasCodeAndMessage() {
        assertEquals(
            mapOf("type" to "playbackError", "code" to "writer_failed", "message" to "boom"),
            AudioEvents.playbackError(AudioEvents.ERROR_WRITER_FAILED, "boom"),
        )
    }

    @Test
    fun playbackErrorCodes_matchTheReadmeAndDesktop() {
        assertEquals("decode_failed", AudioEvents.ERROR_DECODE_FAILED)
        assertEquals("writer_failed", AudioEvents.ERROR_WRITER_FAILED)
    }

    @Test
    fun legacyEventTypesAreUnchanged() {
        assertEquals("engineRestarted", AudioEvents.ENGINE_RESTARTED)
        assertEquals("playbackFinished", AudioEvents.PLAYBACK_FINISHED)
        assertEquals(mapOf("type" to "playbackFinished"), AudioEvents.simple("playbackFinished"))
    }

    /**
     * The writer thread had no top-level catch: any unexpected throwable
     * escaped the thread and Android killed the process. Everything thrown
     * inside the guard must reach the failure handler instead.
     */
    @Test
    fun runGuarded_routesEveryThrowableToTheHandler_onARealThread() {
        val errors = listOf(
            RuntimeException("bug"),
            IllegalStateException("dead track"),
            OutOfMemoryError("oom"),
            StackOverflowError(),
        )
        for (error in errors) {
            var handled: Throwable? = null
            var escaped: Throwable? = null
            val thread = Thread {
                runGuarded({ throw error }) { handled = it }
            }
            thread.setUncaughtExceptionHandler { _, e -> escaped = e }
            thread.start()
            thread.join(5_000)
            assertSame(error, handled)
            assertEquals(null, escaped, "${error.javaClass.simpleName} escaped the thread")
        }
    }

    @Test
    fun runGuarded_swallowsAFailingHandlerToo() {
        var escaped: Throwable? = null
        val thread = Thread {
            runGuarded({ throw RuntimeException("first") }) { throw RuntimeException("second") }
        }
        thread.setUncaughtExceptionHandler { _, e -> escaped = e }
        thread.start()
        thread.join(5_000)
        assertEquals(null, escaped)
    }

    @Test
    fun runGuarded_runsTheBodyNormally() {
        var ran = false
        var failed = false
        runGuarded({ ran = true }) { failed = true }
        assertTrue(ran)
        assertFalse(failed)
    }
}
