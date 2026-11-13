package dev.bimsina.localjam_audio

import kotlin.math.roundToLong

/**
 * Argument and file limits shared by `load`, `probeDuration`, `playAt` and
 * `setRate` — the SAME bounds as iOS/macOS (`rateRange`, `maxLeadUs`,
 * `minSampleRate`) and the desktop core (`LJ_MIN_RATE`, `LJ_MAX_RATE`,
 * `LJ_MAX_LEAD_US`), so one Dart caller sees one contract
 * (localjam_audio README, "API at a glance"). Pure, so every bound is
 * unit-tested.
 */
internal object PlaybackLimits {
    const val MIN_RATE = 1.0 / 32.0
    const val MAX_RATE = 32.0

    /** Furthest-ahead anchor playAt accepts (1 h). */
    const val MAX_LEAD_US = 3_600_000_000L

    /**
     * Sample rates a file may declare. Below 4 kHz nothing plays it (and
     * AudioTrack refuses it at every playAt); above 384 kHz is a crafted
     * header, not music. Desktop parity.
     */
    const val MIN_SAMPLE_RATE = 4_000
    const val MAX_SAMPLE_RATE = 384_000

    /**
     * Most frames a file may declare: 2^37 (~36 days at 44.1 kHz). A
     * metadata duration beyond it is a crafted header, and it would overflow
     * the frame arithmetic. Apple parity.
     */
    const val MAX_FRAMES = 1L shl 37

    fun isValidRate(rate: Double): Boolean = rate.isFinite() && rate >= MIN_RATE && rate <= MAX_RATE

    /** The `bad_args` message for playAt's rate/anchor, or null when fine. */
    fun playAtArgsProblem(nativeTimeUs: Long, rate: Double, nowUs: Long): String? = when {
        !isValidRate(rate) -> "playAt rate must be within [$MIN_RATE, $MAX_RATE]"
        // Doubles: Long.MIN_VALUE - now must not wrap into "far ahead".
        nativeTimeUs.toDouble() - nowUs.toDouble() > MAX_LEAD_US.toDouble() ->
            "playAt nativeTimeUs is more than ${MAX_LEAD_US / 1_000_000} s ahead of the native clock"
        else -> null
    }

    /** Frames in [durationUs] at [sampleRate], as a double (no overflow). */
    fun frames(durationUs: Long, sampleRate: Int): Double = durationUs.toDouble() * sampleRate / 1e6

    /**
     * The `load_failed` reason for a file with this (decoder output) format
     * and metadata duration, or null when the engine can schedule it. Shared
     * with `probeDuration`, which must answer null for exactly these files.
     */
    fun fileProblem(sampleRate: Int, channels: Int, durationUs: Long): String? {
        if (sampleRate < MIN_SAMPLE_RATE || sampleRate > MAX_SAMPLE_RATE) {
            return "unsupported sample rate ($sampleRate Hz)"
        }
        if (channels < 1) return "no audio channels"
        if (durationUs <= 0) return "could not determine duration"
        val frames = frames(durationUs, sampleRate)
        if (frames < 1.0) return "contains no audio frames"
        if (frames > MAX_FRAMES.toDouble()) return "implausible duration (${durationUs}us)"
        return null
    }

    /**
     * Where a playAt actually starts: the effective anchor (≥ now + minLead;
     * a late anchor is re-anchored minLead into the future with the media
     * position advanced at ×rate, §5.3 late join), the first media frame and
     * its frame-exact media position. Null = the start lies outside the file
     * (`bad_position`) — including inputs whose arithmetic would overflow a
     * Long, which used to wrap into nonsense instead.
     */
    fun planStart(
        nativeTimeUs: Long,
        positionUs: Long,
        rate: Double,
        nowUs: Long,
        minLeadUs: Long,
        sampleRate: Int,
        totalFrames: Long,
    ): StartPlan? {
        var anchorUs = nativeTimeUs
        var startPosUs = positionUs.toDouble()
        val earliest = nowUs + minLeadUs
        if (anchorUs < earliest) {
            startPosUs += (earliest.toDouble() - anchorUs.toDouble()) * rate
            anchorUs = earliest
        }
        val startFrameExact = startPosUs * sampleRate / 1e6
        if (!startFrameExact.isFinite() || startFrameExact < 0.0 ||
            startFrameExact >= totalFrames.toDouble()
        ) {
            return null
        }
        val startFrame = startFrameExact.roundToLong()
        if (startFrame >= totalFrames) return null
        // Keep the anchor frame-exact so the position formula has no rounding
        // bias (mirrors iOS segmentStartUs).
        val anchorMediaUs = (startFrame.toDouble() * 1e6 / sampleRate).roundToLong()
        return StartPlan(anchorUs, startPosUs.roundToLong(), startFrame, anchorMediaUs)
    }

    internal data class StartPlan(
        /** Effective anchor instant, native µs (≥ now + minLead). */
        val anchorUs: Long,
        /** Media position at the effective anchor before frame rounding. */
        val startPosUs: Long,
        /** First media frame of the segment. */
        val startFrame: Long,
        /** Frame-exact media position (µs) of [startFrame] — 'P'. */
        val anchorMediaUs: Long,
    )

    /**
     * Total silence frames S that put the first media frame exactly on the
     * target: S = F_ts + (targetNs − T_ts) × sr × rate / 1e9.
     *
     * NOT clamped at 0. A negative S means the target instant passed before
     * even frame 0 of this track presents (a cold first AudioTrack can take
     * longer than the lead to mature its timestamps): the writer then skips
     * written − S media frames — more than it wrote — so frame S+k still
     * carries media position P + k/sr. Clamping at 0 trimmed only `written`
     * frames and started the media late by −S/sr, a constant offset the
     * drift check then had to hard-resync away (measured 260 ms on the first
     * schedule after a cold start on a Pixel 9 Pro emulator).
     */
    fun silenceFrames(
        tsFrame: Long,
        tsNanos: Long,
        targetNs: Long,
        sampleRate: Int,
        rate: Double,
    ): Long = tsFrame + ((targetNs - tsNanos).toDouble() * sampleRate * rate / 1e9).roundToLong()
}
