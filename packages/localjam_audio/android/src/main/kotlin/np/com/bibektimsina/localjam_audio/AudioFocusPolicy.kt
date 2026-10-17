package np.com.bibektimsina.localjam_audio

import android.media.AudioManager

/** Outcome of one audio-focus request, decoupled from AudioManager's ints. */
internal enum class FocusRequestResult {
    GRANTED,
    DELAYED,
    FAILED;

    companion object {
        fun of(code: Int): FocusRequestResult = when (code) {
            AudioManager.AUDIOFOCUS_REQUEST_GRANTED -> GRANTED
            AudioManager.AUDIOFOCUS_REQUEST_DELAYED -> DELAYED
            else -> FAILED
        }
    }
}

/**
 * Whether [mode] (an `AudioManager.MODE_*`) means a call owns the audio path:
 * ringing, a cellular call, VoIP, call screening or a redirected call. While
 * true, playAt must not play — a VoIP app's transient focus is NOT locked, so
 * asking for focus here would steal it and play music into the call.
 */
internal fun isCallAudioMode(mode: Int): Boolean = when (mode) {
    AudioManager.MODE_RINGTONE,
    AudioManager.MODE_IN_CALL,
    AudioManager.MODE_IN_COMMUNICATION,
    AudioManager.MODE_CALL_SCREENING,
    AudioManager.MODE_CALL_REDIRECT,
    AudioManager.MODE_COMMUNICATION_REDIRECT -> true
    else -> false
}

/**
 * The interruption state machine behind the `interruptionBegan` /
 * `interruptionEnded` events (localjam_audio contract item 4), free of
 * Android plumbing so every transition is unit-testable. The plugin feeds it
 * focus requests, focus changes and audio-mode changes and applies the
 * returned [Effect]s in order; it is guarded by the plugin's lock.
 *
 * Interruption is the OR of independent reasons, so overlapping causes (an
 * incoming call is BOTH a mode change and a transient focus loss) produce one
 * `interruptionBegan` when the first lands and one `interruptionEnded` when
 * the last clears — never a began/ended pair per cause. The one exception is
 * a permanent focus loss, which turns an interruption that would have ended
 * into one that will not, and says so with a second began (below).
 *
 * Rules:
 *  * playAt asks for focus ONLY when it does not hold it ([beginPlay]).
 *    Re-requesting while held pushes us back on top of the focus stack, so
 *    an app ducking us right now (a navigation prompt) would get
 *    AUDIOFOCUS_LOSS — a drift re-anchor must never do that.
 *  * playAt in a call mode → no focus request, no play, began.
 *  * playAt focus GRANTED (or already held) → play; any lingering
 *    interruption clears SILENTLY (Dart initiated this playAt, it already
 *    knows playback is back) — but only reasons that predate the request.
 *    Focus callbacks run on the main thread while playAt negotiates on the
 *    handler thread, so a loss can land between the request and the
 *    decision; such a reason is news this playAt knows nothing about, and it
 *    survives: no play, and the matching GAIN still ends it.
 *  * playAt focus DELAYED (focus locked by a call) / FAILED → no play, began.
 *    DELAYED is resolved by a later GAIN → ended{shouldResume: true}.
 *  * EVERY playAt that does not play emits began, even when an interruption
 *    is already known: Dart cleared its own suspension when it decided to
 *    play (the user pressed resume), so a refusal it is not told about would
 *    leave it believing it plays. The Dart engine never re-applies on began,
 *    so this cannot loop.
 *  * AUDIOFOCUS_LOSS_TRANSIENT → stop output, began; the matching
 *    AUDIOFOCUS_GAIN → ended{shouldResume: true}.
 *  * AUDIOFOCUS_LOSS (permanent: the user started another player) → stop
 *    output, began{shouldResume: false}, abandon focus. **interruptionEnded
 *    is never sent for a permanent loss**: the system will not hand focus
 *    back, and the only correct way out is a user-initiated playAt (which
 *    re-requests focus and clears the interruption silently). Sending
 *    ended{shouldResume:false} would invite the Dart engine to re-apply its
 *    snapshot, and a re-applied playAt would steal focus straight back from
 *    the app the user chose. The began says so up front instead, so Dart
 *    shows "another app is playing" rather than waiting for an end that
 *    never comes — and it is sent even when a transient loss or a call
 *    already began the interruption, upgrading it to permanent.
 *  * While a permanent loss stands, every began (a refused or raced playAt)
 *    carries shouldResume:false: no interruptionEnded can follow it.
 *  * AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK → duck volume only, no interruption;
 *    GAIN un-ducks. (On API 26+ the system ducks for us and normally does not
 *    deliver this; API 24-25 relies on it.) A playAt that does not request
 *    focus stays ducked — the other app is still talking.
 *  * Audio mode enters a call while engaged → stop output, began; mode back
 *    to normal → that reason clears (ended once nothing else holds us).
 *
 * The native side never resumes output itself: the room timeline moved on,
 * so Dart re-anchors with playAt.
 */
internal class AudioFocusPolicy {
    internal enum class Effect {
        STOP_OUTPUT,
        EMIT_BEGAN,

        /**
         * `interruptionBegan{shouldResume: false}`: a permanent focus loss
         * stands, so no interruptionEnded will follow — only a playAt that
         * wins focus back ends it.
         */
        EMIT_BEGAN_NO_RESUME,
        EMIT_ENDED_SHOULD_RESUME,
        DUCK,
        UNDUCK,
        ABANDON_FOCUS,
    }

    internal data class PlayDecision(val play: Boolean, val effects: List<Effect>)

    /**
     * Taken (under the plugin lock) before playAt talks to AudioManager
     * (outside it). [requestFocus] false = focus is already held; do not ask.
     * [epoch] dates the reasons this playAt may clear.
     */
    internal class PlayTicket(internal val epoch: Long, val requestFocus: Boolean)

    private companion object {
        const val UNSET = -1L
    }

    /**
     * Bumped by every focus / mode callback. Each reason below records the
     * epoch it was set at (or [UNSET]); a playAt clears only reasons dated at
     * or before its [PlayTicket.epoch].
     */
    private var epoch = 0L
    private var transientLossAt = UNSET
    private var permanentLossAt = UNSET
    private var awaitingDelayedGainAt = UNSET
    private var refusedAt = UNSET
    private var callModeAt = UNSET
    private var duckedAt = UNSET

    /**
     * Whether we are in a focus lifecycle at all: from the first playAt until
     * a permanent loss or [onReleased]. Mode changes outside it are ignored —
     * a call while LocalJam is idle (or after the user moved to another app)
     * must not end with an interruptionEnded that restarts playback.
     */
    private var engaged = false

    /**
     * Whether AudioService has us as the focus owner (or as the one it
     * returns focus to after a may-duck prompt): granted and neither lost
     * nor abandoned since.
     */
    var focusHeld = false
        private set

    /** Whether output volume is currently ducked; new tracks start ducked too. */
    val ducked: Boolean get() = duckedAt != UNSET

    val isInterrupted: Boolean
        get() = transientLossAt != UNSET || permanentLossAt != UNSET ||
            awaitingDelayedGainAt != UNSET || refusedAt != UNSET || callModeAt != UNSET

    /** Step 1 of a playAt: whether to ask for focus, and the race fence. */
    fun beginPlay(): PlayTicket = PlayTicket(epoch, requestFocus = !focusHeld)

    /**
     * Step 2 of a playAt. [inCallMode] is checked first (the caller does not
     * request focus in a call); otherwise [focus] is the request's result when
     * [PlayTicket.requestFocus] was true, and ignored when it was false.
     */
    fun onPlayRequested(
        ticket: PlayTicket,
        inCallMode: Boolean,
        focus: FocusRequestResult?,
    ): PlayDecision {
        engaged = true
        if (inCallMode) {
            if (callModeAt == UNSET) callModeAt = epoch
            return refused()
        }
        val result = if (ticket.requestFocus) focus ?: FocusRequestResult.FAILED else null
        when (result) {
            FocusRequestResult.DELAYED -> {
                focusHeld = false
                awaitingDelayedGainAt = epoch
                return refused()
            }
            FocusRequestResult.FAILED -> {
                focusHeld = false
                refusedAt = epoch
                return refused()
            }
            FocusRequestResult.GRANTED, null -> Unit
        }
        // Granted, or already held: this playAt supersedes every reason it
        // could know about. Anything newer happened mid-request and stays.
        transientLossAt = clearIfBy(transientLossAt, ticket.epoch)
        permanentLossAt = clearIfBy(permanentLossAt, ticket.epoch)
        awaitingDelayedGainAt = clearIfBy(awaitingDelayedGainAt, ticket.epoch)
        refusedAt = clearIfBy(refusedAt, ticket.epoch)
        callModeAt = clearIfBy(callModeAt, ticket.epoch)
        val effects = ArrayList<Effect>()
        if (result == FocusRequestResult.GRANTED) {
            // On top of the focus stack now — unless a loss arrived after the
            // request, which AudioService delivered after granting it.
            if (transientLossAt == UNSET && permanentLossAt == UNSET) focusHeld = true
            if (duckedAt != UNSET && duckedAt <= ticket.epoch) {
                duckedAt = UNSET
                effects += Effect.UNDUCK
            }
        }
        if (isInterrupted) {
            // Raced: an interruption landed while we were asking. It stopped
            // whatever was playing and announced itself; this playAt must not
            // undo it, and Dart must learn the playAt did not play.
            return PlayDecision(false, effects + beganEffect())
        }
        return PlayDecision(true, effects)
    }

    /**
     * One AudioManager.OnAudioFocusChangeListener callback. [inCallMode] is
     * the audio mode right now; it refreshes the call reason on GAIN (below
     * API 31 there is no mode listener to clear it otherwise).
     */
    fun onFocusChange(change: Int, inCallMode: Boolean): List<Effect> {
        epoch += 1
        val wasInterrupted = isInterrupted
        return when (change) {
            AudioManager.AUDIOFOCUS_GAIN -> {
                val effects = ArrayList<Effect>()
                if (ducked) {
                    duckedAt = UNSET
                    effects += Effect.UNDUCK
                }
                transientLossAt = UNSET
                awaitingDelayedGainAt = UNSET
                refusedAt = UNSET
                // permanentLoss deliberately survives: only a playAt clears
                // it (see the class doc). Focus was abandoned, so a GAIN here
                // would be a platform oddity, not a reason to resume.
                if (permanentLossAt == UNSET) {
                    engaged = true
                    focusHeld = true
                }
                callModeAt = if (inCallMode) callModeAt.takeIf { it != UNSET } ?: epoch else UNSET
                if (wasInterrupted && !isInterrupted) effects += Effect.EMIT_ENDED_SHOULD_RESUME
                effects
            }
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> {
                transientLossAt = epoch
                focusHeld = false
                listOf(Effect.STOP_OUTPUT) + began(wasInterrupted)
            }
            AudioManager.AUDIOFOCUS_LOSS -> {
                val alreadyPermanent = permanentLossAt != UNSET
                permanentLossAt = epoch
                transientLossAt = UNSET
                awaitingDelayedGainAt = UNSET
                engaged = false
                focusHeld = false
                duckedAt = UNSET
                // Began even while a transient loss or a call already holds
                // us: Dart is waiting for an interruptionEnded that will now
                // never come, and must learn the interruption is permanent.
                val began =
                    if (alreadyPermanent) emptyList() else listOf(Effect.EMIT_BEGAN_NO_RESUME)
                listOf(Effect.STOP_OUTPUT) + began + Effect.ABANDON_FOCUS
            }
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> {
                if (ducked) {
                    emptyList()
                } else {
                    duckedAt = epoch
                    listOf(Effect.DUCK)
                }
            }
            else -> emptyList()
        }
    }

    /** AudioManager.OnModeChangedListener (API 31+). */
    fun onModeChanged(inCallMode: Boolean): List<Effect> {
        epoch += 1
        if (!engaged) return emptyList()
        val wasInterrupted = isInterrupted
        if (inCallMode && callModeAt == UNSET) {
            callModeAt = epoch
            return listOf(Effect.STOP_OUTPUT) + began(wasInterrupted)
        }
        if (!inCallMode && callModeAt != UNSET) {
            callModeAt = UNSET
            if (wasInterrupted && !isInterrupted) return listOf(Effect.EMIT_ENDED_SHOULD_RESUME)
        }
        return emptyList()
    }

    /** The session ended / the player was disposed: focus is abandoned. */
    fun onReleased() {
        epoch += 1
        transientLossAt = UNSET
        permanentLossAt = UNSET
        awaitingDelayedGainAt = UNSET
        refusedAt = UNSET
        callModeAt = UNSET
        duckedAt = UNSET
        focusHeld = false
        engaged = false
    }

    private fun clearIfBy(setAt: Long, ticketEpoch: Long): Long =
        if (setAt != UNSET && setAt <= ticketEpoch) UNSET else setAt

    private fun refused(): PlayDecision = PlayDecision(false, listOf(beganEffect()))

    /** The began a refused playAt sends: final while a permanent loss stands. */
    private fun beganEffect(): Effect =
        if (permanentLossAt != UNSET) Effect.EMIT_BEGAN_NO_RESUME else Effect.EMIT_BEGAN

    private fun began(wasInterrupted: Boolean): List<Effect> =
        if (wasInterrupted) emptyList() else listOf(Effect.EMIT_BEGAN)
}
