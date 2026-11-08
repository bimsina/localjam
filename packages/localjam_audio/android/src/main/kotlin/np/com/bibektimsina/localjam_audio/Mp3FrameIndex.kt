package np.com.bibektimsina.localjam_audio

import java.io.Closeable
import java.io.File
import java.io.RandomAccessFile

/**
 * A frame-exact index of an MPEG-1/2/2.5 Layer III file: the byte offset and
 * size of every audio frame, plus the LAME/Xing gapless info.
 *
 * Why: MediaExtractor cannot seek an MP3 frame-exactly. With a Xing/Info
 * header (every VBR file and LAME's CBR files) MP3Extractor turns the time
 * into a byte offset through the 100-entry TOC and then REPORTS THE REQUESTED
 * TIME as the pts of whatever frame it landed on; without one it estimates
 * the offset from the bitrate. Either way the pts can be tens to hundreds of
 * ms away from the PCM it labels, so frame-exact positions (what Apple's
 * AVAudioFile and the browser give) need the decoder fed from this index.
 *
 * Gapless info follows FFmpeg (hence Chrome's decodeAudioData): the Xing /
 * Info / VBRI frame is metadata, not audio; the LAME tag's encoder delay and
 * padding are honored when its encoder string is LAME, Lavf or Lavc. Delay
 * and padding are in "zero-decoder-delay" frames — the convention of
 * Android's MP3 decoders, which already drop the 529-frame decoder delay at
 * the start — so gapless frame g is zero-delay frame g + [encoderDelay].
 */
internal class Mp3FrameIndex private constructor(
    val sampleRate: Int,
    val channels: Int,
    /** PCM frames per MP3 frame: 1152 (MPEG-1) or 576 (MPEG-2/2.5). */
    val samplesPerFrame: Int,
    private val offsets: LongArray,
    private val sizes: IntArray,
    val frameCount: Int,
    /** LAME encoder delay (frames), 0 without a recognized LAME tag. */
    val encoderDelay: Int,
    /** LAME encoder padding (frames), 0 without a recognized LAME tag. */
    val encoderPadding: Int
) {
    fun offset(i: Int): Long = offsets[i]

    fun size(i: Int): Int = sizes[i]

    /** Total zero-delay decoded frames (what the decoder outputs). */
    val decodedFrames: Long get() = frameCount.toLong() * samplesPerFrame

    /** Gapless length: decoded frames minus delay and padding. */
    val gaplessFrames: Long
        get() = (decodedFrames - encoderDelay - encoderPadding).coerceAtLeast(0L)

    /** Index of the MP3 frame whose PCM contains gapless [frame]. */
    fun frameContaining(frame: Long): Int {
        val z = frame + encoderDelay
        return (z / samplesPerFrame).toInt().coerceIn(0, frameCount - 1)
    }

    /**
     * First frame to feed a fresh decoder so gapless [frame] decodes with
     * full context: Layer III frames borrow up to 511 (MPEG-1) / 255
     * (MPEG-2/2.5) bytes of main data from earlier frames (the bit
     * reservoir) and overlap their predecessor in the IMDCT, so decoding
     * starts at least [MIN_PREROLL_FRAMES] frames — and enough frames to
     * cover the reservoir — earlier. Bounded by [MAX_PREROLL_FRAMES].
     */
    fun firstFrameToFeed(frame: Long): Int {
        val target = frameContaining(frame)
        val reservoir = if (samplesPerFrame == 1152) 511 else 255
        var first = target
        var bytes = 0
        while (first > 0 && target - first < MAX_PREROLL_FRAMES &&
            (target - first < MIN_PREROLL_FRAMES || bytes < reservoir)
        ) {
            first--
            bytes += sizes[first] - 4
        }
        return first
    }

    /** Presentation time (µs) to stamp on frame [i] for the decoder. */
    fun ptsUs(i: Int): Long = i.toLong() * samplesPerFrame * 1_000_000L / sampleRate

    /** The [GaplessTimeline] of the decoder fed from this index. */
    fun timeline(): GaplessTimeline = GaplessTimeline(
        firstSampleUs = 0L,
        delayUs = encoderDelay * 1e6 / sampleRate,
        paddingFrames = 0L,
        gaplessFrames = gaplessFrames
    )

    /** Random access to the file's bytes (a file, or memory in tests). */
    interface Source : Closeable {
        val length: Long

        /** Reads up to [n] bytes at [pos] into [dst]; returns the count (0 at EOF). */
        fun read(pos: Long, dst: ByteArray, n: Int): Int
    }

    class FileSource(file: File) : Source {
        private val raf = RandomAccessFile(file, "r")
        override val length: Long = raf.length()
        private val window = ByteArray(64 * 1024)
        private var windowPos = -1L
        private var windowLen = 0

        override fun read(pos: Long, dst: ByteArray, n: Int): Int {
            if (pos < 0 || pos >= length) return 0
            if (n > window.size) {
                raf.seek(pos)
                return raf.read(dst, 0, n).coerceAtLeast(0)
            }
            if (windowPos < 0 || pos < windowPos || pos + n > windowPos + windowLen) {
                raf.seek(pos)
                windowLen = raf.read(window, 0, window.size).coerceAtLeast(0)
                windowPos = pos
            }
            val count = minOf(n.toLong(), windowPos + windowLen - pos).toInt().coerceAtLeast(0)
            System.arraycopy(window, (pos - windowPos).toInt(), dst, 0, count)
            return count
        }

        override fun close() = raf.close()
    }

    class BytesSource(private val bytes: ByteArray) : Source {
        override val length: Long get() = bytes.size.toLong()

        override fun read(pos: Long, dst: ByteArray, n: Int): Int {
            if (pos < 0 || pos >= bytes.size) return 0
            val count = minOf(n.toLong(), bytes.size - pos).toInt()
            System.arraycopy(bytes, pos.toInt(), dst, 0, count)
            return count
        }

        override fun close() {}
    }

    /** One parsed 4-byte Layer III frame header. */
    internal data class Header(
        val mpeg1: Boolean,
        val sampleRate: Int,
        val channels: Int,
        val frameSize: Int,
        val samplesPerFrame: Int,
        /** Header bits that must not change between frames of one stream. */
        val fixedBits: Int
    )

    companion object {
        const val MIN_PREROLL_FRAMES = 2
        const val MAX_PREROLL_FRAMES = 32

        /** Hard bound on indexed frames (~6.5 h at 44.1 kHz); larger files fall back. */
        private const val MAX_FRAMES = 1 shl 20

        private val BITRATE_V1_L3 =
            intArrayOf(0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320)
        private val BITRATE_V2_L3 =
            intArrayOf(0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160)
        private val SAMPLE_RATE_V1 = intArrayOf(44100, 48000, 32000)

        /** Parses a Layer III header, or null (not a frame / unsupported). */
        internal fun parseHeader(h: Int): Header? {
            if ((h ushr 21) and 0x7FF != 0x7FF) return null
            val version = (h ushr 19) and 3 // 0 = 2.5, 1 = reserved, 2 = 2, 3 = 1
            val layer = (h ushr 17) and 3 // 1 = Layer III
            val bitrateIdx = (h ushr 12) and 0xF
            val srIdx = (h ushr 10) and 3
            val padding = (h ushr 9) and 1
            val mode = (h ushr 6) and 3
            if (version == 1 || layer != 1 || bitrateIdx == 0 || bitrateIdx == 15 || srIdx == 3) {
                return null // reserved, not Layer III, free-format or bad
            }
            val mpeg1 = version == 3
            val sr = SAMPLE_RATE_V1[srIdx] shr (if (mpeg1) 0 else if (version == 2) 1 else 2)
            val kbps = (if (mpeg1) BITRATE_V1_L3 else BITRATE_V2_L3)[bitrateIdx]
            val size = (if (mpeg1) 144_000 else 72_000) * kbps / sr + padding
            // Sync + version + layer + sample rate + mono/stereo must hold
            // for every frame of the stream (MP3Extractor's kMask, plus mode).
            val fixed = h and 0xFFFE0C00.toInt() or (if (mode == 3) 0xC0 else 0)
            return Header(mpeg1, sr, if (mode == 3) 1 else 2, size, if (mpeg1) 1152 else 576, fixed)
        }

        private fun fixedOf(h: Int): Int =
            h and 0xFFFE0C00.toInt() or (if ((h ushr 6) and 3 == 3) 0xC0 else 0)

        private fun be32(b: ByteArray, o: Int): Int =
            (b[o].toInt() and 0xFF shl 24) or (b[o + 1].toInt() and 0xFF shl 16) or
                (b[o + 2].toInt() and 0xFF shl 8) or (b[o + 3].toInt() and 0xFF)

        /** Builds the index of [file], or null when it is not a usable Layer III stream. */
        fun build(file: File): Mp3FrameIndex? = FileSource(file).use { build(it) }

        /** Builds the index from [src], or null (see [build]). Never throws on bad data. */
        fun build(src: Source): Mp3FrameIndex? = try {
            buildOrThrow(src)
        } catch (_: RuntimeException) {
            null
        }

        private fun buildOrThrow(src: Source): Mp3FrameIndex? {
            val buf = ByteArray(4096)
            var pos = 0L
            // Skip any ID3v2 tags (there can be several, back to back).
            while (true) {
                if (src.read(pos, buf, 10) < 10) return null
                if (buf[0] != 'I'.code.toByte() || buf[1] != 'D'.code.toByte() ||
                    buf[2] != '3'.code.toByte()
                ) {
                    break
                }
                val size = (buf[6].toInt() and 0x7F shl 21) or (buf[7].toInt() and 0x7F shl 14) or
                    (buf[8].toInt() and 0x7F shl 7) or (buf[9].toInt() and 0x7F)
                val footer = if (buf[5].toInt() and 0x10 != 0) 10 else 0
                pos += 10L + size + footer
            }
            // First frame: a valid header whose successor (at the computed
            // size) is a matching header — the usual guard against a false
            // sync inside junk/cover art. Bounded search.
            val first = findFirstFrame(src, pos, buf) ?: return null
            var p = first.first
            val head = first.second
            // Xing/Info/VBRI frame: metadata, not audio (FFmpeg and
            // MP3Extractor both skip it). The LAME tag rides in the Xing frame.
            var delay = 0
            var padding = 0
            val n = src.read(p, buf, minOf(head.frameSize, buf.size))
            val sideInfo = if (head.mpeg1) {
                if (head.channels == 1) 17 else 32
            } else {
                if (head.channels == 1) 9 else 17
            }
            val xingAt = 4 + sideInfo
            var isInfoFrame = false
            if (n >= xingAt + 8) {
                val tag = be32(buf, xingAt)
                if (tag == 0x58696E67 || tag == 0x496E666F) { // "Xing" / "Info"
                    isInfoFrame = true
                    val flags = be32(buf, xingAt + 4)
                    var o = xingAt + 8
                    if (flags and 1 != 0) o += 4
                    if (flags and 2 != 0) o += 4
                    if (flags and 4 != 0) o += 100
                    if (flags and 8 != 0) o += 4
                    // LAME tag: 9-byte encoder string, then 12 bytes, then the
                    // 24-bit delay(12)/padding(12) field.
                    if (o + 24 <= n) {
                        val enc = String(buf, o, 4, Charsets.ISO_8859_1)
                        if (enc == "LAME" || enc == "Lavf" || enc == "Lavc") {
                            val v = (buf[o + 21].toInt() and 0xFF shl 16) or
                                (buf[o + 22].toInt() and 0xFF shl 8) or (buf[o + 23].toInt() and 0xFF)
                            delay = v ushr 12
                            padding = v and 0xFFF
                        }
                    }
                }
            }
            if (!isInfoFrame && n >= 4 + 32 + 4 && be32(buf, 4 + 32) == 0x56425249) { // "VBRI"
                isInfoFrame = true
            }
            if (isInfoFrame) p += head.frameSize

            var offsets = LongArray(1024)
            var sizes = IntArray(1024)
            var count = 0
            val length = src.length
            while (p + 4 <= length) {
                if (src.read(p, buf, 4) < 4) break
                val h = be32(buf, 0)
                val hdr = parseHeader(h)
                if (hdr == null || hdr.fixedBits != head.fixedBits) {
                    // Lost sync (junk, a trailing ID3v1/APE tag): resync to
                    // the next matching header, or stop.
                    p = resync(src, p + 1, head.fixedBits, buf) ?: break
                    continue
                }
                if (p + hdr.frameSize > length) break // truncated last frame
                if (count == offsets.size) {
                    if (count >= MAX_FRAMES) return null
                    offsets = offsets.copyOf(count * 2)
                    sizes = sizes.copyOf(count * 2)
                }
                offsets[count] = p
                sizes[count] = hdr.frameSize
                count++
                p += hdr.frameSize
            }
            if (count == 0) return null
            return Mp3FrameIndex(
                head.sampleRate, head.channels, head.samplesPerFrame,
                offsets, sizes, count, delay, padding
            )
        }

        private fun findFirstFrame(src: Source, from: Long, buf: ByteArray): Pair<Long, Header>? {
            var p = from
            val limit = minOf(src.length, from + 256 * 1024)
            while (p + 4 <= limit) {
                if (src.read(p, buf, 4) < 4) return null
                val hdr = parseHeader(be32(buf, 0))
                if (hdr != null) {
                    val next = p + hdr.frameSize
                    if (next + 4 > src.length) return p to hdr // single-frame file
                    if (src.read(next, buf, 4) == 4) {
                        val h2 = parseHeader(be32(buf, 0))
                        if (h2 != null && h2.fixedBits == hdr.fixedBits) return p to hdr
                    }
                }
                p++
            }
            return null
        }

        private fun resync(src: Source, from: Long, fixed: Int, buf: ByteArray): Long? {
            var p = from
            val limit = minOf(src.length, from + 64 * 1024)
            while (p + 4 <= limit) {
                val got = src.read(p, buf, minOf(buf.size.toLong(), limit - p).toInt())
                if (got < 4) return null
                for (i in 0..got - 4) {
                    if (buf[i] == 0xFF.toByte() && (buf[i + 1].toInt() and 0xE0) == 0xE0) {
                        val h = be32(buf, i)
                        val hdr = parseHeader(h)
                        if (hdr != null && fixedOf(h) == fixed) return p + i
                    }
                }
                p += got - 3
            }
            return null
        }
    }
}
