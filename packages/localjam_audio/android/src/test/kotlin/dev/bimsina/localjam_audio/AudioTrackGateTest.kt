package dev.bimsina.localjam_audio

import android.media.AudioTrack
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import org.mockito.Mockito

/**
 * The P0 "Unable to retrieve AudioTrack pointer for write()" fix.
 *
 * These exercise the real ordering guarantee [AudioTrackGate] exists for:
 * a release that overlaps a long blocking write must not free the handle
 * while the writer is inside it, and the writer must be told to give up.
 */
internal class AudioTrackGateTest {
    private fun mockTrack(): AudioTrack = Mockito.mock(AudioTrack::class.java)

    @Test
    fun use_runsTheOperationAndReturnsItsValue() {
        val gate = AudioTrackGate(mockTrack())
        assertEquals(42, gate.use { 42 })
        assertFalse(gate.isReleased)
        assertEquals(0, gate.activeUsers)
    }

    @Test
    fun use_refusesEveryCallAfterRelease() {
        val track = mockTrack()
        val gate = AudioTrackGate(track)
        gate.release()

        assertTrue(gate.isReleased)
        var ran = false
        assertNull(gate.use { ran = true })
        assertFalse(ran, "the operation must never reach a freed handle")
        Mockito.verify(track).release()
    }

    @Test
    fun release_isIdempotent_soADoubleTeardownCannotDoubleFree() {
        // Dart tears down twice: keep-alive release (which stops playback)
        // and then the engine's player.dispose().
        val track = mockTrack()
        val gate = AudioTrackGate(track)
        gate.release()
        gate.release()
        gate.release()
        Mockito.verify(track, Mockito.times(1)).release()
    }

    @Test
    fun release_waitsForAnInFlightWriteBeforeFreeingTheHandle() {
        // THE race: the writer is inside a blocking write when End jam runs.
        val track = mockTrack()
        val gate = AudioTrackGate(track)
        val inside = CountDownLatch(1)
        val letGo = CountDownLatch(1)
        val freed = AtomicBoolean(false)
        val releaseObservedFromInside = AtomicReference<Boolean>()
        Mockito.doAnswer { freed.set(true); null }.`when`(track).release()

        val writer = Thread {
            gate.use {
                inside.countDown()
                letGo.await(5, TimeUnit.SECONDS) // stands in for a long write
                releaseObservedFromInside.set(gate.isReleased)
                0
            }
        }
        writer.start()
        assertTrue(inside.await(5, TimeUnit.SECONDS), "writer never entered the track")

        val releaser = Thread { gate.release() }
        releaser.start()
        Thread.sleep(80) // well inside the drain wait: a real chance to get it wrong

        assertFalse(freed.get(), "freed the handle while a writer was still inside it")
        assertTrue(gate.isReleased, "the refusal flag must be set before the wait, not after")
        assertNull(gate.use { 1 }, "no new caller may enter once release has started")
        // pause()/flush() must already have run: that is what interrupts a real
        // WRITE_BLOCKING so the wait below can ever finish.
        Mockito.verify(track).pause()
        Mockito.verify(track).flush()

        letGo.countDown()
        writer.join(5_000)
        releaser.join(5_000)

        assertFalse(writer.isAlive)
        assertFalse(releaser.isAlive)
        assertTrue(freed.get(), "the handle must be freed once the writer left")
        assertEquals(0, gate.activeUsers)
        assertTrue(
            releaseObservedFromInside.get(),
            "the in-flight writer must see isReleased and exit its loop",
        )
    }

    @Test
    fun use_swallowsIllegalStateException_asDefenseInDepth() {
        // The exact throw from a released track: the writer must see null and
        // exit, never propagate a crash out of the writer thread.
        val gate = AudioTrackGate(mockTrack())
        val result = gate.use<Int> {
            throw IllegalStateException("Unable to retrieve AudioTrack pointer for write()")
        }
        assertNull(result)
        assertEquals(0, gate.activeUsers, "the failed call must still deregister")
    }

    @Test
    fun use_propagatesOtherFailures_whichAreRealTrackErrors() {
        val gate = AudioTrackGate(mockTrack())
        var thrown: Throwable? = null
        try {
            gate.use<Int> { throw IllegalArgumentException("bad buffer") }
        } catch (e: Throwable) {
            thrown = e
        }
        assertTrue(thrown is IllegalArgumentException)
        assertEquals(0, gate.activeUsers)
    }

    @Test
    fun concurrentUsersAndRelease_neverFreeUnderneathACaller() {
        repeat(20) {
            val track = mockTrack()
            val gate = AudioTrackGate(track)
            val freedWhileInside = AtomicBoolean(false)
            Mockito.doAnswer {
                if (gate.activeUsers > 0) freedWhileInside.set(true)
                null
            }.`when`(track).release()

            val start = CountDownLatch(1)
            val threads = (0 until 4).map {
                Thread {
                    start.await()
                    repeat(200) { gate.use { Thread.yield() } }
                }
            }
            threads.forEach { it.start() }
            val releaser = Thread {
                start.await()
                Thread.yield()
                gate.release()
            }
            releaser.start()
            start.countDown()
            threads.forEach { it.join(10_000) }
            releaser.join(10_000)

            assertFalse(freedWhileInside.get(), "freed the handle with a caller inside it")
            assertEquals(0, gate.activeUsers)
        }
    }
}
