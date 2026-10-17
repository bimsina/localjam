package np.com.bibektimsina.localjam_audio

import android.media.AudioFormat
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

/**
 * Files with more than two channels used to be rejected at `load`
 * ("unsupported channel count"); they are now folded down to stereo.
 */
internal class StereoFolderTest {
    private fun pcm(vararg samples: Int): ByteArray {
        val out = ByteArray(samples.size * 2)
        samples.forEachIndexed { i, v ->
            out[2 * i] = (v and 0xff).toByte()
            out[2 * i + 1] = ((v shr 8) and 0xff).toByte()
        }
        return out
    }

    private fun samples(bytes: ByteArray): IntArray = IntArray(bytes.size / 2) {
        ((bytes[2 * it].toInt() and 0xff) or (bytes[2 * it + 1].toInt() shl 8)).toShort().toInt()
    }

    @Test
    fun fivePointOne_defaultLayout_foldsFrontsCentreAndSurrounds_dropsLfe() {
        val folder = StereoFolder(6, null) // FL FR FC LFE BL BR
        val scale = 1f / (1f + 2 * 0.70710677f)

        val frontLeftOnly = samples(folder.fold(pcm(10000, 0, 0, 0, 0, 0), 0, 12))
        assertEquals(Math.round(10000 * scale), frontLeftOnly[0])
        assertEquals(0, frontLeftOnly[1])

        val centreOnly = samples(folder.fold(pcm(0, 0, 10000, 0, 0, 0), 0, 12))
        assertEquals(centreOnly[0], centreOnly[1], "centre lands equally on both sides")
        assertEquals(Math.round(10000 * 0.70710677f * scale), centreOnly[0])

        val lfeOnly = samples(folder.fold(pcm(0, 0, 0, 30000, 0, 0), 0, 12))
        assertContentEquals(intArrayOf(0, 0), lfeOnly, "LFE is dropped (ITU-R BS.775)")

        val backRightOnly = samples(folder.fold(pcm(0, 0, 0, 0, 0, 10000), 0, 12))
        assertEquals(0, backRightOnly[0])
        assertEquals(Math.round(10000 * 0.70710677f * scale), backRightOnly[1])
    }

    @Test
    fun fullScaleOnEveryChannel_neverClips() {
        for (channels in 3..8) {
            val folder = StereoFolder(channels, null)
            val loud = pcm(*IntArray(channels) { 32767 })
            val quiet = pcm(*IntArray(channels) { -32768 })
            for (s in samples(folder.fold(loud, 0, loud.size))) {
                assertTrue(s in 0..32767, "$channels ch: $s")
            }
            for (s in samples(folder.fold(quiet, 0, quiet.size))) {
                assertTrue(s in -32768..0, "$channels ch: $s")
            }
        }
    }

    @Test
    fun keepsTheFrameCount_andHonoursOffset() {
        val folder = StereoFolder(4, null) // quad
        val two = pcm(0, 0, 0, 0, 1000, 2000, 0, 0, 7, 7, 7, 7)
        val out = folder.fold(two, 8, 16) // skip the first quad frame
        assertEquals(2 * 4, out.size, "2 stereo frames from 2 quad frames")
    }

    @Test
    fun explicitChannelMask_drivesInterleaveOrder() {
        // 3 channels laid out L R + back-centre (not the default L R C):
        val mask = AudioFormat.CHANNEL_OUT_STEREO or AudioFormat.CHANNEL_OUT_BACK_CENTER
        assertContentEquals(
            intArrayOf(
                AudioFormat.CHANNEL_OUT_FRONT_LEFT,
                AudioFormat.CHANNEL_OUT_FRONT_RIGHT,
                AudioFormat.CHANNEL_OUT_BACK_CENTER,
            ),
            StereoFolder.positionsFor(3, mask),
        )
        // A mask that disagrees with the channel count is ignored.
        assertContentEquals(
            intArrayOf(
                AudioFormat.CHANNEL_OUT_FRONT_LEFT,
                AudioFormat.CHANNEL_OUT_FRONT_RIGHT,
                AudioFormat.CHANNEL_OUT_FRONT_CENTER,
            ),
            StereoFolder.positionsFor(3, AudioFormat.CHANNEL_OUT_STEREO),
        )
    }

    @Test
    fun sevenPointOne_sidesGoToTheirSide() {
        val folder = StereoFolder(8, AudioFormat.CHANNEL_OUT_7POINT1_SURROUND)
        // FL FR FC LFE BL BR SL SR → side-left only:
        val out = samples(folder.fold(pcm(0, 0, 0, 0, 0, 0, 10000, 0), 0, 16))
        assertTrue(out[0] > 0)
        assertEquals(0, out[1])
    }

    @Test
    fun unknownLayout_alternatesLeftRight() {
        val folder = StereoFolder(10, null)
        val out = samples(folder.fold(pcm(10000, 0, 0, 0, 0, 0, 0, 0, 0, 0), 0, 20))
        assertTrue(out[0] > 0)
        assertEquals(0, out[1])
    }

    @Test
    fun rejectsPartialFramesAndStereoInput() {
        assertFailsWith<IllegalArgumentException> { StereoFolder(2, null) }
        assertFailsWith<IllegalArgumentException> {
            StereoFolder(6, null).fold(ByteArray(10), 0, 10)
        }
    }
}
