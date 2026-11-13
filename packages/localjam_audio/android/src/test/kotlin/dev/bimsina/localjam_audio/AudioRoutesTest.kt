package dev.bimsina.localjam_audio

import android.media.AudioDeviceInfo
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Contract items 2–3: route identity and the unplug decisions. */
internal class AudioRoutesTest {
    private val speaker = RouteDevice(AudioDeviceInfo.TYPE_BUILTIN_SPEAKER, "Pixel 9 Pro", "")
    private val earpiece = RouteDevice(AudioDeviceInfo.TYPE_BUILTIN_EARPIECE, "Pixel 9 Pro", "")
    private val wired = RouteDevice(AudioDeviceInfo.TYPE_WIRED_HEADPHONES, "", "")
    private val budsA = RouteDevice(AudioDeviceInfo.TYPE_BLUETOOTH_A2DP, "Buds", "AA:BB:CC:DD:EE:01")
    private val budsB = RouteDevice(AudioDeviceInfo.TYPE_BLUETOOTH_A2DP, "Buds", "AA:BB:CC:DD:EE:02")
    private val sco = RouteDevice(AudioDeviceInfo.TYPE_BLUETOOTH_SCO, "Buds", "AA:BB:CC:DD:EE:01")
    private val telephony = RouteDevice(AudioDeviceInfo.TYPE_TELEPHONY, "", "")

    // ------------------------------------------------------------- route ids

    @Test
    fun routeId_isStable_forTheSameDevice() {
        val again = RouteDevice(AudioDeviceInfo.TYPE_BLUETOOTH_A2DP, "Buds", "AA:BB:CC:DD:EE:01")
        assertEquals(budsA.id, again.id)
        assertEquals(
            AudioRoutes.routeId(AudioDeviceInfo.TYPE_BLUETOOTH_A2DP, "Buds", "AA:BB:CC:DD:EE:01"),
            budsA.id,
        )
    }

    @Test
    fun routeId_differs_byAddressNameOrType() {
        assertNotEquals(budsA.id, budsB.id, "same model, different unit")
        assertNotEquals(
            budsA.id,
            RouteDevice(AudioDeviceInfo.TYPE_BLUETOOTH_A2DP, "Other", budsA.address).id,
        )
        assertNotEquals(budsA.id, sco.id, "same headset, different transport")
        assertNotEquals(speaker.id, wired.id)
    }

    @Test
    fun routeId_neverLeaksTheRawAddress_andIsReadable() {
        assertFalse(budsA.id.contains("AA:BB", ignoreCase = true))
        assertFalse(budsA.id.contains("aabbcc", ignoreCase = true))
        assertFalse(budsA.toString().contains("AA:BB"), "toString must not log the MAC")
        assertTrue(Regex("^bt_a2dp:[0-9a-f]{16}$").matches(budsA.id), budsA.id)
        assertTrue(speaker.id.startsWith("speaker:"))
    }

    @Test
    fun routeId_treatsNullsAsEmpty() {
        assertEquals(
            AudioRoutes.routeId(AudioDeviceInfo.TYPE_WIRED_HEADPHONES, null, null),
            AudioRoutes.routeId(AudioDeviceInfo.TYPE_WIRED_HEADPHONES, "", ""),
        )
    }

    // ---------------------------------------------------------- route picking

    @Test
    fun pickMediaRoute_prefersExternalOverSpeaker_andSkipsNonMediaSinks() {
        assertEquals(budsA.id, AudioRoutes.pickMediaRoute(listOf(speaker, earpiece, budsA))?.id)
        assertEquals(wired.id, AudioRoutes.pickMediaRoute(listOf(speaker, wired, sco))?.id)
        assertEquals(speaker.id, AudioRoutes.pickMediaRoute(listOf(earpiece, speaker, telephony))?.id)
        assertNull(AudioRoutes.pickMediaRoute(listOf(telephony, sco)))
    }

    @Test
    fun pickMediaRoute_honoursExclusions() {
        assertEquals(
            speaker.id,
            AudioRoutes.pickMediaRoute(listOf(speaker, wired), exclude = setOf(wired.id))?.id,
        )
    }

    // ------------------------------------------------------- unplug decisions

    @Test
    fun noisy_stopsAndReportsOldDeviceUnavailable_withTheNextRoute() {
        val t = RouteChangeTracker()
        t.observe(wired)
        val d = t.onBecomingNoisy(nowNs = 0, goingRouteId = wired.id, nextRouteId = speaker.id)
        assertTrue(d.stopOutput)
        assertTrue(d.oldDeviceUnavailable)
        assertEquals(speaker.id, d.routeId)
    }

    @Test
    fun removalAfterNoisy_isOneIncident_aPlainRouteChange() {
        val t = RouteChangeTracker()
        t.observe(wired)
        t.onBecomingNoisy(0, wired.id, speaker.id)
        val d = t.onDevicesRemoved(1_000_000_000L, listOf(wired), speaker)
        assertFalse(d.stopOutput, "already stopped by the noisy")
        assertFalse(d.oldDeviceUnavailable, "one unplug, one oldDeviceUnavailable")
        assertEquals(speaker.id, d.routeId, "the authoritative new route")
    }

    @Test
    fun removalOfTheActiveRoute_withoutNoisy_stopsAndReports() {
        val t = RouteChangeTracker()
        t.observe(budsA)
        val d = t.onDevicesRemoved(0, listOf(budsA), wired)
        assertTrue(d.stopOutput)
        assertTrue(d.oldDeviceUnavailable)
        assertEquals(wired.id, d.routeId)
    }

    @Test
    fun removalFallingBackToTheSpeaker_stopsEvenWhenTheRouteWasOnlyGuessed() {
        val t = RouteChangeTracker()
        t.observe(budsA) // a pre-33 guess; actually it was on the wired set
        val d = t.onDevicesRemoved(0, listOf(wired), speaker)
        assertTrue(d.stopOutput)
        assertTrue(d.oldDeviceUnavailable)
    }

    @Test
    fun removalOfAnIdleDevice_keepsPlaying() {
        val t = RouteChangeTracker()
        t.observe(wired)
        val d = t.onDevicesRemoved(0, listOf(budsB), wired)
        assertFalse(d.stopOutput)
        assertFalse(d.oldDeviceUnavailable)
        assertEquals(wired.id, d.routeId)
    }

    @Test
    fun removalLongAfterNoisy_isANewIncident() {
        val t = RouteChangeTracker(noisyWindowNs = 5_000_000_000L)
        t.observe(wired)
        t.onBecomingNoisy(0, wired.id, speaker.id)
        t.observe(wired) // the device stayed (noisy without removal)
        val d = t.onDevicesRemoved(60_000_000_000L, listOf(wired), speaker)
        assertTrue(d.oldDeviceUnavailable)
    }

    @Test
    fun deviceAdded_isAPlainRouteChange_andBecomesTheReference() {
        val t = RouteChangeTracker()
        t.observe(speaker)
        val d = t.onDevicesAdded(budsA)
        assertFalse(d.stopOutput)
        assertFalse(d.oldDeviceUnavailable)
        assertEquals(budsA.id, d.routeId)
        assertEquals(budsA.id, t.lastRouteId)
    }

    @Test
    fun playback_isHeldBrieflyAfterNoisy_soItCannotLandOnTheDepartingDevice() {
        val t = RouteChangeTracker()
        assertNull(t.playbackHold(0))
        t.onBecomingNoisy(0, wired.id, speaker.id)
        assertNotNull(t.playbackHold(500_000_000L))
        assertNull(t.playbackHold(3_000_000_000L), "the hold is bounded")
        // The removal settles the reroute: no more hold.
        t.onBecomingNoisy(10_000_000_000L, wired.id, speaker.id)
        t.onDevicesRemoved(10_500_000_000L, listOf(wired), speaker)
        assertNull(t.playbackHold(10_600_000_000L))
    }

    @Test
    fun aHeldPlayAt_isAnsweredWithOldDeviceUnavailable_notSwallowed() {
        // The held playAt may be the user pressing resume right after the
        // unplug: it used to complete silently, leaving Dart believing it
        // played. It now re-reports the unavailable device.
        val t = RouteChangeTracker()
        t.onBecomingNoisy(0, wired.id, speaker.id)
        val hold = t.playbackHold(100_000_000L)!!
        assertFalse(hold.stopOutput, "output is already stopped")
        assertTrue(hold.oldDeviceUnavailable)
        assertEquals(speaker.id, hold.routeId)
    }

    // ------------------------------------ item 7: the fallback-to-phone rule

    @Test
    fun idleEarbudsLeaving_whileTheUserPickedThePhone_keepsPlaying() {
        // The bug: "an external device left and media is on the phone" fired
        // even when media was KNOWN to be on the phone already (the user chose
        // "This phone" in the output switcher with earbuds connected), so the
        // earbuds disconnecting stopped playback.
        val t = RouteChangeTracker()
        t.observe(speaker)
        val d = t.onDevicesRemoved(0, listOf(budsA), speaker)
        assertFalse(d.stopOutput)
        assertFalse(d.oldDeviceUnavailable)
        assertEquals(speaker.id, d.routeId)
    }

    @Test
    fun externalLeavingWithAnUnknownRoute_fallingBackToThePhone_stops() {
        val t = RouteChangeTracker() // nothing observed yet
        val d = t.onDevicesRemoved(0, listOf(budsA), speaker)
        assertTrue(d.stopOutput)
        assertTrue(d.oldDeviceUnavailable)
    }

    @Test
    fun theKnownPhoneRoute_isUpdatedByRemovalsToo() {
        val t = RouteChangeTracker()
        t.observe(budsA)
        t.onDevicesRemoved(0, listOf(budsA), speaker) // stops: buds were active
        // Now on the phone; another external leaving changes nothing.
        val d = t.onDevicesRemoved(1_000_000_000L, listOf(wired), speaker)
        assertFalse(d.stopOutput)
    }

    // --------------------------------------- routeId after a device is added

    @Test
    fun routeAfterAddition_prefersThePolicyAnswer() {
        assertEquals(
            budsA.id,
            AudioRoutes.routeAfterAddition(budsA, speaker, setOf(budsA.id), listOf(speaker, budsA))?.id,
        )
    }

    @Test
    fun routeAfterAddition_ignoresALiveTrackStillOnTheOldDevice() {
        // The live track has not been rerouted yet when the callback fires:
        // its routed device is the OLD route, and §7 calibration for the new
        // headphones would be filed under it.
        val connected = listOf(speaker, earpiece, wired)
        assertEquals(
            wired.id,
            AudioRoutes.routeAfterAddition(null, speaker, setOf(wired.id), connected)?.id,
        )
    }

    @Test
    fun routeAfterAddition_trustsALiveTrackAlreadyOnTheAddedDevice() {
        val connected = listOf(speaker, wired, budsA)
        assertEquals(
            wired.id,
            AudioRoutes.routeAfterAddition(null, wired, setOf(wired.id), connected)?.id,
            "exact beats the priority guess (which would say the buds)",
        )
    }
}
