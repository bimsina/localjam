package np.com.bibektimsina.localjam_audio

import android.media.AudioTrack
import android.media.PlaybackParams
import android.util.Log
import kotlin.math.ceil

/**
 * Playback speed on an [AudioTrack] — the ×rate every piece of the schedule
 * math assumes (S, the position formula, the late-anchor advance). If the
 * track does not actually play at the rate the math uses, every start and
 * every position is silently wrong, so a refused speed is never ignored:
 * playAt finds a track that accepts it or answers `bad_args`, and setRate
 * keeps the math on the rate the track really plays.
 *
 * Why a track refuses: AudioTrack::setPlaybackRate returns
 * INVALID_OPERATION for FAST (PERFORMANCE_MODE_LOW_LATENCY) tracks — no
 * time-stretcher on the fast mixer — BAD_VALUE for a buffer too small for
 * the speed (see [bufferFactor]), and BAD_VALUE outside the platform's
 * time-stretch range ("effective rate out of bounds": measured [0.1, 10]
 * on an API 36 emulator — narrower than the [1/32, 32] Dart accepts). The
 * Java layer turns all of them into IllegalArgumentException.
 */
internal object TrackSpeed {
    private const val TAG = "LocaljamAudio"

    /** Sets speed [rate] at pitch 1 on [track]; false when the track refuses it. */
    fun apply(track: AudioTrack, rate: Double): Boolean = try {
        // Builder calls on separate lines: the setters' return values are
        // not needed, and that keeps this callable against the JVM stubs.
        val params = PlaybackParams()
        params.setSpeed(rate.toFloat())
        params.setPitch(1.0f)
        track.playbackParams = params
        true
    } catch (e: IllegalArgumentException) {
        Log.w(TAG, "track refused playback speed $rate: $e")
        false
    } catch (e: IllegalStateException) {
        Log.w(TAG, "track refused playback speed $rate: $e")
        false
    }

    /**
     * Track buffer size, in multiples of AudioTrack.getMinBufferSize (which
     * is for speed 1): AudioTrack refuses a speed whose minimum frame count
     * (≈ that minimum × speed) exceeds the buffer ("failed (buffer size)" —
     * measured: 4× refused on a 3× buffer). 3× covers every drift slew;
     * faster playAt rates get room for their speed plus one.
     */
    fun bufferFactor(rate: Double): Int = maxOf(3, ceil(rate).toInt() + 1)

    internal class Opened<T>(
        val track: T,
        /** The low-latency track refused the speed: stop asking for one. */
        val lowLatencyRefusedSpeed: Boolean,
    )

    /**
     * Creates a track that plays at [rate]: first as [preferLowLatency]
     * says; if that track was granted low latency and refuses the speed, once
     * more without it. Null (both refused, every track released) means this
     * output cannot play [rate] — playAt answers `bad_args`.
     */
    fun <T> openAtRate(
        rate: Double,
        preferLowLatency: Boolean,
        create: (lowLatency: Boolean) -> T,
        applySpeed: (T, Double) -> Boolean,
        isLowLatency: (T) -> Boolean,
        release: (T) -> Unit,
    ): Opened<T>? {
        val first = create(preferLowLatency)
        if (applySpeed(first, rate)) return Opened(first, lowLatencyRefusedSpeed = false)
        val wasLowLatency = preferLowLatency && isLowLatency(first)
        release(first)
        if (!wasLowLatency) return null
        val second = create(false)
        if (applySpeed(second, rate)) return Opened(second, lowLatencyRefusedSpeed = true)
        release(second)
        return null
    }
}
