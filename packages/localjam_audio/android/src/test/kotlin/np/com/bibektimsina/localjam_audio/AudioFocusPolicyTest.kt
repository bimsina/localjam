package np.com.bibektimsina.localjam_audio

import android.media.AudioManager
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import np.com.bibektimsina.localjam_audio.AudioFocusPolicy.Effect

/**
 * Contract item 4: interruptions. Before this policy the plugin played when
 * focus was refused, treated a permanent AUDIOFOCUS_LOSS as transient (and
 * then announced interruptionEnded on the next GAIN), ignored can-duck, and
 * never looked at the audio mode — so it would play into a call.
 */
internal class AudioFocusPolicyTest {
    /** One whole playAt negotiation with nothing racing it. */
    private fun AudioFocusPolicy.play(
        focus: FocusRequestResult? = FocusRequestResult.GRANTED,
        inCallMode: Boolean = false,
    ): AudioFocusPolicy.PlayDecision = onPlayRequested(beginPlay(), inCallMode, focus)

    private fun grantedPolicy(): AudioFocusPolicy = AudioFocusPolicy().also {
        assertTrue(it.play().play)
    }

    @Test
    fun granted_plays_withNoEvents() {
        val d = AudioFocusPolicy().play()
        assertTrue(d.play)
        assertEquals(emptyList(), d.effects)
    }

    @Test
    fun refusedFocus_doesNotPlay_andBeginsAnInterruption_everyTime() {
        val p = AudioFocusPolicy()
        val d = p.play(FocusRequestResult.FAILED)
        assertFalse(d.play, "a refused focus request must not play")
        assertEquals(listOf(Effect.EMIT_BEGAN), d.effects)
        assertTrue(p.isInterrupted)
        // A second refused playAt is the user pressing resume (Dart cleared
        // its suspension to send it): it must hear the refusal again, or it
        // believes it plays.
        val again = p.play(FocusRequestResult.FAILED)
        assertFalse(again.play)
        assertEquals(listOf(Effect.EMIT_BEGAN), again.effects)
    }

    @Test
    fun callMode_refusesWithoutRequestingFocus_andBeginsEveryTime() {
        val p = AudioFocusPolicy()
        val d = p.onPlayRequested(p.beginPlay(), inCallMode = true, focus = null)
        assertFalse(d.play)
        assertEquals(listOf(Effect.EMIT_BEGAN), d.effects)
        assertEquals(listOf(Effect.EMIT_BEGAN), p.play(focus = null, inCallMode = true).effects)
    }

    @Test
    fun delayedFocus_waitsForGain_thenEndsWithShouldResume() {
        val p = AudioFocusPolicy()
        val d = p.play(FocusRequestResult.DELAYED)
        assertFalse(d.play)
        assertEquals(listOf(Effect.EMIT_BEGAN), d.effects)
        assertEquals(
            listOf(Effect.EMIT_ENDED_SHOULD_RESUME),
            p.onFocusChange(AudioManager.AUDIOFOCUS_GAIN, inCallMode = false),
        )
        assertFalse(p.isInterrupted)
    }

    @Test
    fun transientLoss_stopsAndBegins_gainEndsWithShouldResume() {
        val p = grantedPolicy()
        assertEquals(
            listOf(Effect.STOP_OUTPUT, Effect.EMIT_BEGAN),
            p.onFocusChange(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT, false),
        )
        assertEquals(
            listOf(Effect.EMIT_ENDED_SHOULD_RESUME),
            p.onFocusChange(AudioManager.AUDIOFOCUS_GAIN, false),
        )
        assertFalse(p.isInterrupted)
    }

    @Test
    fun permanentLoss_stopsBeginsAbandons_andIsNeverEndedByTheSystem() {
        val p = grantedPolicy()
        // Began says up front that no end will follow (shouldResume: false):
        // a bare began left Dart showing "paused, may resume" for good.
        assertEquals(
            listOf(Effect.STOP_OUTPUT, Effect.EMIT_BEGAN_NO_RESUME, Effect.ABANDON_FOCUS),
            p.onFocusChange(AudioManager.AUDIOFOCUS_LOSS, false),
        )
        // The old bug: a later GAIN announced interruptionEnded, inviting the
        // Dart engine to re-apply and steal focus back from the app the user
        // switched to.
        assertEquals(emptyList(), p.onFocusChange(AudioManager.AUDIOFOCUS_GAIN, false))
        assertTrue(p.isInterrupted)
        // Mode changes after a permanent loss are ignored too.
        assertEquals(emptyList(), p.onModeChanged(true))
        assertEquals(emptyList(), p.onModeChanged(false))
    }

    @Test
    fun permanentLoss_clearsSilentlyOnAUserPlayAt() {
        val p = grantedPolicy()
        p.onFocusChange(AudioManager.AUDIOFOCUS_LOSS, false)
        val ticket = p.beginPlay()
        assertTrue(ticket.requestFocus, "focus was lost: ask again")
        val d = p.onPlayRequested(ticket, false, FocusRequestResult.GRANTED)
        assertTrue(d.play)
        assertEquals(emptyList(), d.effects, "Dart started this playAt; no ended event")
        assertFalse(p.isInterrupted)
    }

    @Test
    fun transientThenPermanent_upgradesWithABeganThatWillNotEnd() {
        // The transient loss's began promised an end; the permanent loss
        // cancels that promise, so Dart must hear about it — it used to wait
        // for an interruptionEnded that never came.
        val p = grantedPolicy()
        assertEquals(
            listOf(Effect.STOP_OUTPUT, Effect.EMIT_BEGAN),
            p.onFocusChange(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT, false),
        )
        assertEquals(
            listOf(Effect.STOP_OUTPUT, Effect.EMIT_BEGAN_NO_RESUME, Effect.ABANDON_FOCUS),
            p.onFocusChange(AudioManager.AUDIOFOCUS_LOSS, false),
        )
        assertEquals(emptyList(), p.onFocusChange(AudioManager.AUDIOFOCUS_GAIN, false))
    }

    @Test
    fun callThenPermanent_upgradesToo_andTheCallsEndDoesNotEndIt() {
        val p = grantedPolicy()
        assertEquals(listOf(Effect.STOP_OUTPUT, Effect.EMIT_BEGAN), p.onModeChanged(true))
        assertEquals(
            listOf(Effect.STOP_OUTPUT, Effect.EMIT_BEGAN_NO_RESUME, Effect.ABANDON_FOCUS),
            p.onFocusChange(AudioManager.AUDIOFOCUS_LOSS, true),
        )
        assertEquals(emptyList(), p.onModeChanged(false))
        assertTrue(p.isInterrupted)
    }

    @Test
    fun refusedPlayAt_whileAPermanentLossStands_beginsWithoutResume() {
        // Dart cleared its suspension to send this playAt (the user pressed
        // resume); the refusal must not read as an interruption that ends.
        val p = grantedPolicy()
        p.onFocusChange(AudioManager.AUDIOFOCUS_LOSS, false)
        val refused = p.play(FocusRequestResult.FAILED)
        assertFalse(refused.play)
        assertEquals(listOf(Effect.EMIT_BEGAN_NO_RESUME), refused.effects)
        val inCall = p.play(focus = null, inCallMode = true)
        assertFalse(inCall.play)
        assertEquals(listOf(Effect.EMIT_BEGAN_NO_RESUME), inCall.effects)
        // A grant still ends it silently, and later refusals are ordinary.
        assertTrue(p.play().play)
        p.onFocusChange(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT, false)
        assertEquals(listOf(Effect.EMIT_BEGAN), p.play(FocusRequestResult.FAILED).effects)
    }

    @Test
    fun canDuck_ducksOnly_andGainUnducks() {
        val p = grantedPolicy()
        assertEquals(
            listOf(Effect.DUCK),
            p.onFocusChange(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK, false),
        )
        assertTrue(p.ducked)
        assertFalse(p.isInterrupted, "ducking is not an interruption")
        assertEquals(listOf(Effect.UNDUCK), p.onFocusChange(AudioManager.AUDIOFOCUS_GAIN, false))
        assertFalse(p.ducked)
    }

    @Test
    fun incomingCall_modeAndFocusTogether_giveOneBeganAndOneEnded() {
        val p = grantedPolicy()
        // Ringing: mode first, then the dialer's transient focus request.
        assertEquals(listOf(Effect.STOP_OUTPUT, Effect.EMIT_BEGAN), p.onModeChanged(true))
        assertEquals(
            listOf(Effect.STOP_OUTPUT),
            p.onFocusChange(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT, true),
        )
        // Call over: focus comes back while the mode still says in-call —
        // not over yet.
        assertEquals(emptyList(), p.onFocusChange(AudioManager.AUDIOFOCUS_GAIN, true))
        assertTrue(p.isInterrupted)
        assertEquals(listOf(Effect.EMIT_ENDED_SHOULD_RESUME), p.onModeChanged(false))
        assertFalse(p.isInterrupted)
    }

    @Test
    fun voipModeWithoutFocus_stillInterrupts() {
        val p = grantedPolicy()
        assertEquals(listOf(Effect.STOP_OUTPUT, Effect.EMIT_BEGAN), p.onModeChanged(true))
        assertEquals(listOf(Effect.EMIT_ENDED_SHOULD_RESUME), p.onModeChanged(false))
    }

    @Test
    fun refusedForACall_endsWhenTheModeReturnsToNormal() {
        val p = AudioFocusPolicy()
        p.play(focus = null, inCallMode = true)
        assertEquals(listOf(Effect.EMIT_ENDED_SHOULD_RESUME), p.onModeChanged(false))
    }

    @Test
    fun modeChangesWhileIdle_areIgnored() {
        val p = AudioFocusPolicy() // never played
        assertEquals(emptyList(), p.onModeChanged(true))
        assertEquals(emptyList(), p.onModeChanged(false))
        val released = grantedPolicy().apply { onReleased() }
        assertEquals(emptyList(), released.onModeChanged(true))
    }

    @Test
    fun grantedRequest_afterDuck_unducks() {
        val p = grantedPolicy()
        p.onFocusChange(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK, false)
        p.onFocusChange(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT, false)
        val ticket = p.beginPlay()
        assertTrue(ticket.requestFocus)
        val d = p.onPlayRequested(ticket, false, FocusRequestResult.GRANTED)
        assertTrue(d.play)
        assertEquals(listOf(Effect.UNDUCK), d.effects, "on top of the focus stack again")
        assertFalse(p.ducked)
    }

    // -------------------------------------------- item 8: focus held → no ask

    @Test
    fun heldFocus_isNotRequestedAgain() {
        val p = grantedPolicy()
        assertTrue(p.focusHeld)
        val ticket = p.beginPlay()
        assertFalse(ticket.requestFocus, "a drift re-anchor must not re-request held focus")
        val d = p.onPlayRequested(ticket, false, null)
        assertTrue(d.play)
        assertEquals(emptyList(), d.effects)
    }

    @Test
    fun reAnchorDuringANavigationPrompt_staysDucked_andDoesNotAskForFocus() {
        // The bug: every playAt re-requested AUDIOFOCUS_GAIN, which pushed us
        // back over the navigation app's transient focus — the prompt got
        // AUDIOFOCUS_LOSS and stopped mid-sentence.
        val p = grantedPolicy()
        assertEquals(
            listOf(Effect.DUCK),
            p.onFocusChange(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK, false),
        )
        val ticket = p.beginPlay()
        assertFalse(ticket.requestFocus)
        val d = p.onPlayRequested(ticket, false, null)
        assertTrue(d.play, "ducking is not an interruption")
        assertEquals(emptyList(), d.effects, "still ducked: the prompt is still talking")
        assertTrue(p.ducked)
        assertEquals(listOf(Effect.UNDUCK), p.onFocusChange(AudioManager.AUDIOFOCUS_GAIN, false))
    }

    @Test
    fun focusIsHeldOnlyWhileOwned() {
        val p = grantedPolicy()
        p.onFocusChange(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT, false)
        assertFalse(p.focusHeld)
        assertTrue(p.beginPlay().requestFocus, "a user resume after a transient loss asks again")
        p.onFocusChange(AudioManager.AUDIOFOCUS_GAIN, false)
        assertTrue(p.focusHeld)
        p.onFocusChange(AudioManager.AUDIOFOCUS_LOSS, false)
        assertFalse(p.focusHeld)
        val delayed = AudioFocusPolicy().apply { play(FocusRequestResult.DELAYED) }
        assertFalse(delayed.focusHeld)
        val released = grantedPolicy().apply { onReleased() }
        assertFalse(released.focusHeld)
    }

    // -------------------------------- item 9: a loss racing playAt's request

    @Test
    fun transientLossDuringTheRequest_survivesTheGrant_andItsGainStillEnds() {
        // The bug: GRANTED cleared every reason, including the loss that had
        // landed (on the main thread) after the request — so the matching
        // GAIN saw nothing to end and the Dart engine stayed interrupted.
        val p = AudioFocusPolicy()
        val ticket = p.beginPlay()
        assertTrue(ticket.requestFocus)
        assertEquals(
            listOf(Effect.STOP_OUTPUT, Effect.EMIT_BEGAN),
            p.onFocusChange(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT, false),
        )
        val d = p.onPlayRequested(ticket, false, FocusRequestResult.GRANTED)
        assertFalse(d.play, "must not undo the interruption")
        assertEquals(listOf(Effect.EMIT_BEGAN), d.effects, "Dart learns this playAt did not play")
        assertTrue(p.isInterrupted)
        assertFalse(p.focusHeld, "the loss came after the grant")
        assertEquals(
            listOf(Effect.EMIT_ENDED_SHOULD_RESUME),
            p.onFocusChange(AudioManager.AUDIOFOCUS_GAIN, false),
        )
    }

    @Test
    fun transientLossDuringAHeldPlayAt_survivesToo() {
        val p = grantedPolicy()
        val ticket = p.beginPlay()
        assertFalse(ticket.requestFocus)
        p.onFocusChange(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT, false)
        val d = p.onPlayRequested(ticket, false, null)
        assertFalse(d.play)
        assertEquals(
            listOf(Effect.EMIT_ENDED_SHOULD_RESUME),
            p.onFocusChange(AudioManager.AUDIOFOCUS_GAIN, false),
        )
    }

    @Test
    fun permanentLossDuringTheRequest_survives_andOnlyAUserPlayAtClearsIt() {
        val p = AudioFocusPolicy()
        val ticket = p.beginPlay()
        assertEquals(
            listOf(Effect.STOP_OUTPUT, Effect.EMIT_BEGAN_NO_RESUME, Effect.ABANDON_FOCUS),
            p.onFocusChange(AudioManager.AUDIOFOCUS_LOSS, false),
        )
        val d = p.onPlayRequested(ticket, false, FocusRequestResult.GRANTED)
        assertFalse(d.play)
        assertEquals(listOf(Effect.EMIT_BEGAN_NO_RESUME), d.effects)
        assertTrue(p.isInterrupted)
        assertEquals(emptyList(), p.onFocusChange(AudioManager.AUDIOFOCUS_GAIN, false))
        assertTrue(p.play().play, "a later user playAt asks again and plays")
    }

    @Test
    fun callModeDuringTheRequest_survives_andEndsWithTheCall() {
        val p = grantedPolicy()
        val ticket = p.beginPlay()
        assertEquals(listOf(Effect.STOP_OUTPUT, Effect.EMIT_BEGAN), p.onModeChanged(true))
        assertFalse(p.onPlayRequested(ticket, false, null).play)
        assertEquals(listOf(Effect.EMIT_ENDED_SHOULD_RESUME), p.onModeChanged(false))
    }

    @Test
    fun reasonsFromBeforeTheRequest_areStillClearedSilently() {
        val p = grantedPolicy()
        p.onFocusChange(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT, false)
        val ticket = p.beginPlay() // the user resumes after the loss
        val d = p.onPlayRequested(ticket, false, FocusRequestResult.GRANTED)
        assertTrue(d.play)
        assertEquals(emptyList(), d.effects)
        assertFalse(p.isInterrupted)
    }

    @Test
    fun aGainOrDuckRacingTheRequest_doesNotBlockPlay() {
        val p = AudioFocusPolicy()
        val ticket = p.beginPlay()
        p.onFocusChange(AudioManager.AUDIOFOCUS_GAIN, false)
        assertTrue(p.onPlayRequested(ticket, false, FocusRequestResult.GRANTED).play)

        val q = AudioFocusPolicy()
        val t2 = q.beginPlay()
        q.onFocusChange(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK, false)
        val d = q.onPlayRequested(t2, false, FocusRequestResult.GRANTED)
        assertTrue(d.play)
        assertEquals(emptyList(), d.effects, "the duck is newer than the grant: stay ducked")
        assertTrue(q.ducked)
    }

    @Test
    fun callModes_coverRingingCellularVoipAndScreening() {
        assertTrue(isCallAudioMode(AudioManager.MODE_RINGTONE))
        assertTrue(isCallAudioMode(AudioManager.MODE_IN_CALL))
        assertTrue(isCallAudioMode(AudioManager.MODE_IN_COMMUNICATION))
        assertTrue(isCallAudioMode(AudioManager.MODE_CALL_SCREENING))
        assertTrue(isCallAudioMode(AudioManager.MODE_CALL_REDIRECT))
        assertTrue(isCallAudioMode(AudioManager.MODE_COMMUNICATION_REDIRECT))
        assertFalse(isCallAudioMode(AudioManager.MODE_NORMAL))
    }

    @Test
    fun focusRequestResult_mapsAudioManagerCodes() {
        assertEquals(
            FocusRequestResult.GRANTED,
            FocusRequestResult.of(AudioManager.AUDIOFOCUS_REQUEST_GRANTED),
        )
        assertEquals(
            FocusRequestResult.DELAYED,
            FocusRequestResult.of(AudioManager.AUDIOFOCUS_REQUEST_DELAYED),
        )
        assertEquals(
            FocusRequestResult.FAILED,
            FocusRequestResult.of(AudioManager.AUDIOFOCUS_REQUEST_FAILED),
        )
    }
}
