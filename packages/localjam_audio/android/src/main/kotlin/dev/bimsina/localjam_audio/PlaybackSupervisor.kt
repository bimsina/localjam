package dev.bimsina.localjam_audio

import android.media.AudioTrack

/**
 * Why a schedule died off the method-call path; decides which event Dart
 * hears (localjam_audio README, "Events"). The distinction matters because
 * the Dart engine RE-APPLIES on engineRestarted but not on playbackError:
 * reporting a failure that a fresh schedule would hit again as
 * engineRestarted makes the client recreate the AudioTrack + MediaCodec (and
 * re-request focus) every ~150 ms, forever.
 */
internal enum class ScheduleFailure {
    /**
     * The FILE cannot be played: extractor/codec exception, a decoder that
     * stalled, an output-format change, the decoder thread crashing. A new
     * schedule decodes the same bytes → `playbackError{decode_failed}`.
     */
    DECODE,

    /**
     * The AudioTrack died under a healthy schedule (media server restart, a
     * HAL reroute: IllegalStateException on a dead handle, ERROR_DEAD_OBJECT).
     * A fresh track fixes it → `engineRestarted`, like iOS's configuration
     * change — unless it keeps happening, see [PlaybackSupervisor].
     */
    TRACK_DEAD,

    /**
     * Any other writer failure: a write error code that is not a dead
     * object, an unexpected throwable on the writer thread →
     * `playbackError{writer_failed}`.
     */
    WRITER;

    companion object {
        /** A negative AudioTrack.write() result. */
        fun ofWriteError(code: Int): ScheduleFailure =
            if (code == AudioTrack.ERROR_DEAD_OBJECT) TRACK_DEAD else WRITER
    }
}

/**
 * The playback decisions of the plugin that are not platform plumbing —
 * schedule generations, the focus/interruption policy, route decisions and
 * failure reporting — in one pure class so the WIRING between them is
 * unit-testable: a focus loss or an unplug landing while a playAt is half
 * way through, a failure reported by a schedule that was already replaced,
 * a dead track that dies again on every re-apply. Not thread-safe: the
 * plugin calls it only while holding its lock.
 *
 * ## Generations (iOS scheduleGeneration)
 * [generation] is bumped by every event that retires output: each Dart
 * stop/load/playAt/dispose and each OS-driven stop (focus loss, call,
 * unplug, failure). A schedule — and a playAt still negotiating — carries
 * the generation it started under; once that is no longer current, its
 * writer/decoder exit silently, its failures are not reported (whoever
 * retired it owns the outcome), and a playAt that was overtaken mid-flight
 * must not install its track.
 */
internal class PlaybackSupervisor(
    val focus: AudioFocusPolicy = AudioFocusPolicy(),
    val routes: RouteChangeTracker = RouteChangeTracker(),
    /**
     * Dead-track restarts tolerated back to back, with no schedule reaching
     * the media phase in between, before the next one is reported as
     * `playbackError{writer_failed}` instead: a track that dies on every
     * re-apply is not a reroute, and engineRestarted would loop.
     */
    private val maxConsecutiveRestarts: Int = 3,
) {
    var generation = 0L
        private set

    private var restartsWithoutMedia = 0

    /** One playAt in flight: its generation and its focus-race fence. */
    internal class PlayAtTicket(val generation: Long, val focus: AudioFocusPolicy.PlayTicket)

    /** Retires every outstanding schedule (and playAt in flight). */
    fun retire() {
        generation += 1
    }

    fun isCurrent(generation: Long): Boolean = generation == this.generation

    // ------------------------------------------------------------------ playAt

    /**
     * playAt entry, after argument validation: the previous schedule is
     * retired whatever this playAt ends up doing (Dart asked for something
     * else), and the focus negotiation is fenced.
     */
    fun beginPlayAt(): PlayAtTicket {
        retire()
        return PlayAtTicket(generation, focus.beginPlay())
    }

    /** Non-null = do not play; emit this routeChanged (see [RouteChangeTracker.playbackHold]). */
    fun playbackHold(nowNs: Long): RouteChangeTracker.Decision? = routes.playbackHold(nowNs)

    fun negotiateFocus(
        ticket: PlayAtTicket,
        inCallMode: Boolean,
        result: FocusRequestResult?,
    ): AudioFocusPolicy.PlayDecision = focus.onPlayRequested(ticket.focus, inCallMode, result)

    /** Whether nothing retired output since [ticket] was taken. */
    fun mayInstall(ticket: PlayAtTicket): Boolean = isCurrent(ticket.generation)

    // ---------------------------------------------------- OS-driven decisions

    /** Focus callback; a STOP_OUTPUT effect has already retired the generation. */
    fun onFocusChange(change: Int, inCallMode: Boolean): List<AudioFocusPolicy.Effect> =
        focus.onFocusChange(change, inCallMode).also { retireOn(it) }

    /** Mode callback; a STOP_OUTPUT effect has already retired the generation. */
    fun onModeChanged(inCallMode: Boolean): List<AudioFocusPolicy.Effect> =
        focus.onModeChanged(inCallMode).also { retireOn(it) }

    fun onBecomingNoisy(
        nowNs: Long,
        goingRouteId: String?,
        nextRouteId: String?,
    ): RouteChangeTracker.Decision =
        routes.onBecomingNoisy(nowNs, goingRouteId, nextRouteId).also { if (it.stopOutput) retire() }

    fun onDevicesRemoved(
        nowNs: Long,
        removed: List<RouteDevice>,
        newRoute: RouteDevice?,
    ): RouteChangeTracker.Decision =
        routes.onDevicesRemoved(nowNs, removed, newRoute).also { if (it.stopOutput) retire() }

    fun onDevicesAdded(newRoute: RouteDevice?): RouteChangeTracker.Decision =
        routes.onDevicesAdded(newRoute)

    // ---------------------------------------------------------------- failures

    /** A schedule's first media PCM reached the track: it was healthy. */
    fun onMediaStreaming(generation: Long) {
        if (isCurrent(generation)) restartsWithoutMedia = 0
    }

    /**
     * A schedule of [generation] failed. Null = it was already superseded:
     * stay silent. Otherwise the generation is retired (the caller releases
     * the track) and the returned event payload must be emitted.
     */
    fun onScheduleFailure(
        generation: Long,
        failure: ScheduleFailure,
        detail: String,
    ): Map<String, Any>? {
        if (!isCurrent(generation)) return null
        retire()
        return when (failure) {
            ScheduleFailure.DECODE ->
                AudioEvents.playbackError(AudioEvents.ERROR_DECODE_FAILED, detail)
            ScheduleFailure.WRITER ->
                AudioEvents.playbackError(AudioEvents.ERROR_WRITER_FAILED, detail)
            ScheduleFailure.TRACK_DEAD -> {
                restartsWithoutMedia += 1
                if (restartsWithoutMedia > maxConsecutiveRestarts) {
                    restartsWithoutMedia = 0
                    AudioEvents.playbackError(
                        AudioEvents.ERROR_WRITER_FAILED,
                        "the audio output died before playing $maxConsecutiveRestarts times " +
                            "in a row; last: $detail",
                    )
                } else {
                    AudioEvents.simple(AudioEvents.ENGINE_RESTARTED)
                }
            }
        }
    }

    // ---------------------------------------------------------------- lifecycle

    /** A new file: earlier failures said nothing about it. */
    fun onLoad() {
        retire()
        restartsWithoutMedia = 0
    }

    /** dispose / session end: output retired, focus given back. */
    fun onReleased() {
        focus.onReleased()
        retire()
        restartsWithoutMedia = 0
    }

    private fun retireOn(effects: List<AudioFocusPolicy.Effect>) {
        if (AudioFocusPolicy.Effect.STOP_OUTPUT in effects) retire()
    }
}
