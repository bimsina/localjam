package dev.bimsina.localjam_audio

import kotlin.math.roundToLong

/**
 * What Android reports as `outputLatencyUs` — the latency contract shared
 * with iOS/macOS and web (localjam_audio README, "positionUs"):
 *
 *  * `outputLatencyUs` is how long after `playAt`'s `nativeTimeUs` the
 *    scheduled frame is HEARD. Dart subtracts it from every anchor (§7).
 *  * `positionUs` is the position heard now.
 *
 * Apple and web schedule the frame that is DUE (rendered) at `nativeTimeUs`
 * and it is heard the output latency later, so they report that latency.
 * Android's silence priming targets the frame PRESENTED at `nativeTimeUs`
 * ([PlaybackLimits.silenceFrames] over a mature AudioTimestamp, which already
 * includes the whole pipeline latency), so the frame is heard exactly at
 * `nativeTimeUs`: the scheduling latency is 0, whatever the device says its
 * output latency is. Reporting the hidden AudioManager property there made
 * Dart subtract it on top — every schedule heard that much EARLY, and the
 * drift check (which reads presented frames) saw it as constant drift.
 *
 * The raw property value is still read, for diagnostics only
 * (`debugLatencyInfo`, logs).
 */
internal object OutputLatency {
    /**
     * µs between `playAt`'s `nativeTimeUs` and the scheduled frame being
     * heard on Android: none, see the object doc. What `outputLatencyUs` and
     * every event's `outputLatencyUs` carry.
     */
    const val SCHEDULING_US = 0L

    /**
     * The hidden "android.media.property.OUTPUT_LATENCY" AudioManager
     * property (milliseconds, honored by some devices) in µs; 0 when absent
     * or malformed. Diagnostic only — never a scheduling compensation.
     */
    fun propertyUs(ms: String?): Long {
        val value = ms?.toDoubleOrNull() ?: return 0
        if (!value.isFinite() || value < 0) return 0
        return (value * 1000).roundToLong()
    }
}
