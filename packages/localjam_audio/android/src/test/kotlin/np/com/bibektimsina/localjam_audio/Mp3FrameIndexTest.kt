package np.com.bibektimsina.localjam_audio

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * [Mp3FrameIndex] against real encoder output. Fixtures (src/test/resources/
 * gapless, regenerate with packages/localjam_audio/tool/gapless_fixtures.sh)
 * are 3 s of the same deterministic signal, encoded by FFmpeg's libmp3lame.
 * Expected numbers come from ffprobe/FFmpeg, and the gapless lengths are
 * exactly what Chrome's decodeAudioData returns for these files (measured):
 * the index must call the same sample frame 0 that the browser does.
 */
internal class Mp3FrameIndexTest {
    private fun fixture(name: String): File {
        val url = javaClass.classLoader!!.getResource("gapless/$name")
            ?: error("missing fixture gapless/$name")
        return File(url.toURI())
    }

    private fun index(name: String) = assertNotNull(Mp3FrameIndex.build(fixture(name)))

    @Test
    fun lameCbrStereo_mpeg1_gaplessLengthMatchesTheSource() {
        val ix = index("lame_cbr_44100_stereo.mp3")
        assertEquals(44100, ix.sampleRate)
        assertEquals(2, ix.channels)
        assertEquals(1152, ix.samplesPerFrame)
        assertEquals(116, ix.frameCount) // ffprobe -count_packets (Info frame excluded)
        assertEquals(576, ix.encoderDelay)
        // 3 s at 44.1 kHz: what Chrome decodes, what was encoded.
        assertEquals(132_300L, ix.gaplessFrames)
        assertEquals(116L * 1152 - 576 - 132_300, ix.encoderPadding.toLong())
    }

    @Test
    fun lameVbrMono_mpeg2_gaplessLengthMatchesTheSource() {
        val ix = index("lame_vbr_22050_mono.mp3")
        assertEquals(22050, ix.sampleRate)
        assertEquals(1, ix.channels)
        assertEquals(576, ix.samplesPerFrame)
        assertEquals(117, ix.frameCount)
        assertEquals(576, ix.encoderDelay)
        assertEquals(66_150L, ix.gaplessFrames)
    }

    @Test
    fun noXingFrame_withId3v2_indexesEveryFrame_noGaplessInfo() {
        val ix = index("noxing_44100_mono.mp3")
        assertEquals(116, ix.frameCount)
        assertEquals(0, ix.encoderDelay)
        assertEquals(0, ix.encoderPadding)
        assertEquals(116L * 1152, ix.gaplessFrames)
        // The ID3v2 tag FFmpeg wrote (title=no-xing) is skipped.
        val bytes = fixture("noxing_44100_mono.mp3").readBytes()
        assertEquals("ID3", String(bytes, 0, 3, Charsets.ISO_8859_1))
        assertTrue(ix.offset(0) > 10)
    }

    @Test
    fun everyIndexedFrameIsAContiguousValidHeader() {
        for (name in listOf("lame_cbr_44100_stereo.mp3", "lame_vbr_22050_mono.mp3", "noxing_44100_mono.mp3")) {
            val bytes = fixture(name).readBytes()
            val ix = index(name)
            for (i in 0 until ix.frameCount) {
                val o = ix.offset(i).toInt()
                val h = (bytes[o].toInt() and 0xFF shl 24) or (bytes[o + 1].toInt() and 0xFF shl 16) or
                    (bytes[o + 2].toInt() and 0xFF shl 8) or (bytes[o + 3].toInt() and 0xFF)
                val hdr = assertNotNull(Mp3FrameIndex.parseHeader(h), "$name frame $i")
                assertEquals(hdr.frameSize, ix.size(i), "$name frame $i size")
                if (i + 1 < ix.frameCount) {
                    assertEquals(ix.offset(i) + ix.size(i), ix.offset(i + 1), "$name contiguous at $i")
                }
            }
            assertEquals(bytes.size.toLong(), ix.offset(ix.frameCount - 1) + ix.size(ix.frameCount - 1))
        }
    }

    @Test
    fun frameContaining_accountsForTheEncoderDelay() {
        val ix = index("lame_cbr_44100_stereo.mp3") // delay 576, 1152 per frame
        assertEquals(0, ix.frameContaining(0)) // zero-delay frame 576
        assertEquals(0, ix.frameContaining(575)) // zero-delay 1151
        assertEquals(1, ix.frameContaining(576)) // zero-delay 1152
        assertEquals(ix.frameCount - 1, ix.frameContaining(10_000_000)) // clamped
    }

    @Test
    fun firstFrameToFeed_prerollsForOverlapAndBitReservoir() {
        val ix = index("lame_cbr_44100_stereo.mp3")
        assertEquals(0, ix.firstFrameToFeed(0))
        assertEquals(0, ix.firstFrameToFeed(1000)) // only one frame before: start
        val target = ix.frameContaining(88_200)
        val first = ix.firstFrameToFeed(88_200)
        assertTrue(target - first >= Mp3FrameIndex.MIN_PREROLL_FRAMES)
        var reservoirBytes = 0
        for (i in first until target) reservoirBytes += ix.size(i) - 4
        assertTrue(reservoirBytes >= 511, "pre-roll covers the 511-byte bit reservoir")
        // Low-bitrate MPEG-2: tiny frames, so more of them for 255 bytes.
        val small = index("lame_vbr_22050_mono.mp3")
        val t2 = small.frameContaining(44_100)
        val f2 = small.firstFrameToFeed(44_100)
        var b2 = 0
        for (i in f2 until t2) b2 += small.size(i) - 4
        assertTrue(b2 >= 255 && t2 - f2 <= Mp3FrameIndex.MAX_PREROLL_FRAMES)
    }

    @Test
    fun timeline_mapsDecoderPtsToGaplessFrames() {
        val ix = index("lame_cbr_44100_stereo.mp3")
        val tl = ix.timeline()
        // Android's MP3 decoders drop their 529-frame delay and stamp output
        // with the first input's pts: zero-delay frame z has pts z/sr.
        // Gapless frame 0 is zero-delay frame 576 (the LAME delay).
        assertEquals(-576L, tl.frameAt(ix.ptsUs(0), 44100))
        assertEquals(1152L - 576, tl.frameAt(ix.ptsUs(1), 44100))
        for (i in 0 until ix.frameCount) {
            assertEquals(i * 1152L - 576, tl.frameAt(ix.ptsUs(i), 44100), "frame $i")
        }
        assertEquals(132_300L, tl.gaplessFrames)
        assertEquals(0L, tl.paddingFrames) // the end is cut by gaplessFrames
    }

    @Test
    fun notAnMp3_orTruncated_isNull_neverThrows() {
        assertNull(Mp3FrameIndex.build(Mp3FrameIndex.BytesSource(ByteArray(0))))
        assertNull(Mp3FrameIndex.build(Mp3FrameIndex.BytesSource(ByteArray(5000) { 0x55 })))
        // An ID3 header that claims more than the file holds.
        val id3 = byteArrayOf(0x49, 0x44, 0x33, 4, 0, 0, 0x7F, 0x7F, 0x7F, 0x7F) + ByteArray(100)
        assertNull(Mp3FrameIndex.build(Mp3FrameIndex.BytesSource(id3)))
        // A file cut mid-frame keeps every complete frame.
        val bytes = fixture("lame_cbr_44100_stereo.mp3").readBytes()
        val full = index("lame_cbr_44100_stereo.mp3")
        val cut = bytes.copyOf((full.offset(50) + 7).toInt())
        val ix = assertNotNull(Mp3FrameIndex.build(Mp3FrameIndex.BytesSource(cut)))
        assertEquals(50, ix.frameCount)
    }

    @Test
    fun junkBetweenFrames_resyncs() {
        val bytes = fixture("noxing_44100_mono.mp3").readBytes()
        val full = index("noxing_44100_mono.mp3")
        val at = full.offset(10).toInt()
        val junk = ByteArray(37) { 0x11 }
        val spliced = bytes.copyOfRange(0, at) + junk + bytes.copyOfRange(at, bytes.size)
        val ix = assertNotNull(Mp3FrameIndex.build(Mp3FrameIndex.BytesSource(spliced)))
        assertEquals(full.frameCount, ix.frameCount)
        assertEquals(full.offset(10) + junk.size, ix.offset(10))
    }

    @Test
    fun parseHeader_rejectsNonLayer3AndReservedValues() {
        // MPEG-1 Layer III, 128 kbps, 44.1 kHz, stereo, no padding: 417 bytes.
        val ok = assertNotNull(Mp3FrameIndex.parseHeader(0xFFFB9000.toInt()))
        assertEquals(417, ok.frameSize)
        assertEquals(2, ok.channels)
        assertNull(Mp3FrameIndex.parseHeader(0xFFFD9000.toInt())) // Layer II
        assertNull(Mp3FrameIndex.parseHeader(0xFFFB0000.toInt())) // free format
        assertNull(Mp3FrameIndex.parseHeader(0xFFFBF000.toInt())) // bad bitrate
        assertNull(Mp3FrameIndex.parseHeader(0xFFFB9C00.toInt())) // reserved rate
        assertNull(Mp3FrameIndex.parseHeader(0xFFEB9000.toInt())) // reserved version
        assertNull(Mp3FrameIndex.parseHeader(0x12345678))
    }
}
