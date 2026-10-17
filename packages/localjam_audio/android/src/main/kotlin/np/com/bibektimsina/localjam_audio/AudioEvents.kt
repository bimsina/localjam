package np.com.bibektimsina.localjam_audio

/**
 * Payloads of the `localjam_audio/events` channel — exactly the keys and
 * value types `LocaljamAudio._decodeEvent` reads (localjam_audio contract
 * items 3–5). Built here, not inline, so their shape is unit-tested: a typo'd
 * key would silently decode as "absent" on the Dart side.
 *
 * Values cross the StandardMessageCodec as Dart int (Kotlin Long), bool and
 * String. Optional keys are omitted, never sent as null.
 */
internal object AudioEvents {
    const val ROUTE_CHANGED = "routeChanged"
    const val INTERRUPTION_BEGAN = "interruptionBegan"
    const val INTERRUPTION_ENDED = "interruptionEnded"
    const val ENGINE_RESTARTED = "engineRestarted"
    const val PLAYBACK_FINISHED = "playbackFinished"
    const val PLAYBACK_ERROR = "playbackError"

    /**
     * `playbackError` code: the writer failed in a way a fresh schedule would
     * not fix — an unexpected throwable, a write error other than a dead
     * track, or a track that keeps dying before it plays anything.
     */
    const val ERROR_WRITER_FAILED = "writer_failed"

    /**
     * `playbackError` code: the file cannot be decoded (extractor/codec error,
     * decoder stall, format change). Desktop parity; the Dart engine never
     * re-applies the same item for it.
     */
    const val ERROR_DECODE_FAILED = "decode_failed"

    fun simple(type: String): Map<String, Any> = mapOf("type" to type)

    /**
     * [oldDeviceUnavailable] true means the previous output went away and
     * native output is ALREADY stopped (and stays stopped until playAt).
     */
    fun routeChanged(
        outputLatencyUs: Long,
        routeId: String?,
        oldDeviceUnavailable: Boolean,
    ): Map<String, Any> = buildMap {
        put("type", ROUTE_CHANGED)
        put("outputLatencyUs", outputLatencyUs)
        if (routeId != null) put("routeId", routeId)
        put("oldDeviceUnavailable", oldDeviceUnavailable)
    }

    /**
     * [shouldResume] false = the interruption is permanent (Android's
     * permanent focus loss): no `interruptionEnded` will follow. Null (the
     * usual case) omits the key: an interruption that may still end.
     */
    fun interruptionBegan(shouldResume: Boolean? = null): Map<String, Any> = buildMap {
        put("type", INTERRUPTION_BEGAN)
        if (shouldResume != null) put("shouldResume", shouldResume)
    }

    fun interruptionEnded(shouldResume: Boolean): Map<String, Any> =
        mapOf("type" to INTERRUPTION_ENDED, "shouldResume" to shouldResume)

    fun playbackError(code: String, message: String): Map<String, Any> =
        mapOf("type" to PLAYBACK_ERROR, "code" to code, "message" to message)
}

/**
 * Runs [body] so that NO throwable escapes it: anything thrown goes to
 * [onFailure] instead (whose own throw is swallowed too). For the writer and
 * decoder threads — an uncaught throwable on an app thread kills the process
 * on Android — and for platform-thread callbacks (focus, routes, noisy) and
 * probe tasks.
 */
internal inline fun runGuarded(body: () -> Unit, onFailure: (Throwable) -> Unit) {
    try {
        body()
    } catch (t: Throwable) {
        try {
            onFailure(t)
        } catch (_: Throwable) {
        }
    }
}
