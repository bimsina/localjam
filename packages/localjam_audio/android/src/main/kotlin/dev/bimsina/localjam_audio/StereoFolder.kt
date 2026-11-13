package dev.bimsina.localjam_audio

import android.media.AudioFormat
import kotlin.math.roundToInt

/**
 * Folds interleaved 16-bit little-endian PCM with more than two channels
 * down to stereo, so 5.1/7.1/quad files play instead of being rejected.
 *
 * Done here rather than by handing AudioTrack a multichannel mask: the
 * low-latency path is stereo-only on many devices, and our own fold-down is
 * deterministic and testable.
 *
 * Channel order: MediaCodec interleaves channels in ascending
 * `AudioFormat.CHANNEL_OUT_*` bit order of the stream's channel mask
 * (MediaFormat.KEY_CHANNEL_MASK); without a usable mask the platform's
 * default layout for the channel count is assumed (3 = L R C, 4 = quad,
 * 5 = 5.0, 6 = 5.1, 7 = 6.1, 8 = 7.1).
 *
 * Coefficients follow ITU-R BS.775 fold-down: fronts at unity, centre and
 * surrounds at −3 dB (0.7071) into their side(s), LFE dropped. The result is
 * scaled so the larger side's coefficient sum is 1, which makes clipping
 * impossible (quieter than the original mix, never distorted).
 */
internal class StereoFolder(val channels: Int, channelMask: Int?) {
    private val left = FloatArray(channels)
    private val right = FloatArray(channels)

    init {
        require(channels > 2) { "fold-down needs more than 2 channels, got $channels" }
        val positions = positionsFor(channels, channelMask)
        for (i in 0 until channels) {
            val (l, r) = gainsFor(positions[i], i)
            left[i] = l
            right[i] = r
        }
        val scale = 1f / maxOf(left.sum(), right.sum(), 1f)
        for (i in 0 until channels) {
            left[i] *= scale
            right[i] *= scale
        }
    }

    /**
     * Folds [len] bytes of [src] from [off] (a whole number of source frames)
     * into a new stereo buffer of `len / channels * 2` bytes.
     */
    fun fold(src: ByteArray, off: Int, len: Int): ByteArray {
        val srcFrameBytes = 2 * channels
        require(len % srcFrameBytes == 0) { "partial frame: $len bytes for $channels ch" }
        val frames = len / srcFrameBytes
        val out = ByteArray(frames * 4)
        var s = off
        var o = 0
        for (f in 0 until frames) {
            var l = 0f
            var r = 0f
            for (c in 0 until channels) {
                val v = ((src[s].toInt() and 0xff) or (src[s + 1].toInt() shl 8)).toShort().toFloat()
                l += v * left[c]
                r += v * right[c]
                s += 2
            }
            val li = l.roundToInt().coerceIn(-32768, 32767)
            val ri = r.roundToInt().coerceIn(-32768, 32767)
            out[o++] = (li and 0xff).toByte()
            out[o++] = ((li shr 8) and 0xff).toByte()
            out[o++] = (ri and 0xff).toByte()
            out[o++] = ((ri shr 8) and 0xff).toByte()
        }
        return out
    }

    internal companion object {
        private const val MINUS_3DB = 0.70710677f

        /** Interleaved channel positions (CHANNEL_OUT_* bits) of one frame. */
        fun positionsFor(channels: Int, channelMask: Int?): IntArray {
            val mask = channelMask?.takeIf { it != 0 && Integer.bitCount(it) == channels }
                ?: defaultMask(channels)
            if (mask == 0) return IntArray(channels) // unknown layout: see gainsFor
            val out = IntArray(channels)
            var bits = mask
            var i = 0
            while (bits != 0 && i < channels) {
                val low = Integer.lowestOneBit(bits)
                out[i++] = low
                bits = bits and low.inv()
            }
            return out
        }

        private fun defaultMask(channels: Int): Int = when (channels) {
            3 -> AudioFormat.CHANNEL_OUT_STEREO or AudioFormat.CHANNEL_OUT_FRONT_CENTER
            4 -> AudioFormat.CHANNEL_OUT_QUAD
            5 -> AudioFormat.CHANNEL_OUT_QUAD or AudioFormat.CHANNEL_OUT_FRONT_CENTER
            6 -> AudioFormat.CHANNEL_OUT_5POINT1
            7 -> AudioFormat.CHANNEL_OUT_5POINT1 or AudioFormat.CHANNEL_OUT_BACK_CENTER
            8 -> AudioFormat.CHANNEL_OUT_7POINT1_SURROUND
            else -> 0
        }

        /**
         * (left, right) gain for one position. An unknown layout (position
         * 0) alternates left/right by index, the least-surprising guess.
         */
        fun gainsFor(position: Int, index: Int): Pair<Float, Float> = when (position) {
            AudioFormat.CHANNEL_OUT_FRONT_LEFT -> 1f to 0f
            AudioFormat.CHANNEL_OUT_FRONT_RIGHT -> 0f to 1f
            AudioFormat.CHANNEL_OUT_LOW_FREQUENCY, LOW_FREQUENCY_2 -> 0f to 0f
            AudioFormat.CHANNEL_OUT_FRONT_CENTER,
            AudioFormat.CHANNEL_OUT_BACK_CENTER,
            TOP_CENTER, TOP_FRONT_CENTER, TOP_BACK_CENTER, BOTTOM_FRONT_CENTER ->
                MINUS_3DB to MINUS_3DB
            AudioFormat.CHANNEL_OUT_BACK_LEFT,
            AudioFormat.CHANNEL_OUT_SIDE_LEFT,
            AudioFormat.CHANNEL_OUT_FRONT_LEFT_OF_CENTER,
            TOP_FRONT_LEFT, TOP_BACK_LEFT, TOP_SIDE_LEFT, BOTTOM_FRONT_LEFT, FRONT_WIDE_LEFT ->
                MINUS_3DB to 0f
            AudioFormat.CHANNEL_OUT_BACK_RIGHT,
            AudioFormat.CHANNEL_OUT_SIDE_RIGHT,
            AudioFormat.CHANNEL_OUT_FRONT_RIGHT_OF_CENTER,
            TOP_FRONT_RIGHT, TOP_BACK_RIGHT, TOP_SIDE_RIGHT, BOTTOM_FRONT_RIGHT, FRONT_WIDE_RIGHT ->
                0f to MINUS_3DB
            else -> if (index % 2 == 0) 1f to 0f else 0f to 1f
        }

        // CHANNEL_OUT_* positions added after minSdk 24 (API 32+), as raw bits
        // so they resolve on every API level.
        private const val TOP_CENTER = 0x2000
        private const val TOP_FRONT_LEFT = 0x4000
        private const val TOP_FRONT_CENTER = 0x8000
        private const val TOP_FRONT_RIGHT = 0x10000
        private const val TOP_BACK_LEFT = 0x20000
        private const val TOP_BACK_CENTER = 0x40000
        private const val TOP_BACK_RIGHT = 0x80000
        private const val TOP_SIDE_LEFT = 0x100000
        private const val TOP_SIDE_RIGHT = 0x200000
        private const val BOTTOM_FRONT_LEFT = 0x400000
        private const val BOTTOM_FRONT_CENTER = 0x800000
        private const val BOTTOM_FRONT_RIGHT = 0x1000000
        private const val LOW_FREQUENCY_2 = 0x2000000
        private const val FRONT_WIDE_LEFT = 0x4000000
        private const val FRONT_WIDE_RIGHT = 0x8000000
    }
}
