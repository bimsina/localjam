package dev.bimsina.localjam_audio

import android.media.session.MediaSession
import android.net.wifi.WifiManager
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertNull

/**
 * Library-copy naming (copies were `$id.audio`, which guests received as
 * application/octet-stream) and the version-dependent session choices.
 */
internal class JamPlatformPolicyTest {
    // ------------------------------------------------------ library extension

    @Test
    fun extension_comesFromTheDisplayName() {
        assertEquals("mp3", LibraryFileNames.extensionFor("Song.MP3", "audio/mpeg"))
        assertEquals("flac", LibraryFileNames.extensionFor("a.b.flac", null))
        assertEquals("opus", LibraryFileNames.extensionFor("voice.opus", "application/octet-stream"))
    }

    @Test
    fun extension_fallsBackToTheMimeType() {
        assertEquals("m4a", LibraryFileNames.extensionFor("Untitled", "audio/mp4"))
        assertEquals("m4a", LibraryFileNames.extensionFor(null, "audio/x-m4a"))
        assertEquals("wav", LibraryFileNames.extensionFor(null, "audio/x-wav"))
        assertEquals("ogg", LibraryFileNames.extensionFor(null, "application/ogg"))
        assertEquals("mp3", LibraryFileNames.extensionFor(null, "Audio/MPEG; charset=binary"))
        // A non-audio name extension loses to a known MIME.
        assertEquals("aac", LibraryFileNames.extensionFor("track.tmp", "audio/aac"))
    }

    @Test
    fun extension_usesThePlatformTable_forUncommonTypes() {
        assertEquals(
            "amr",
            LibraryFileNames.extensionFor(null, "audio/amr") { if (it == "audio/amr") "amr" else null },
        )
        // The platform answer is sanitized like everything else.
        assertNull(LibraryFileNames.extensionFor(null, "audio/x-odd") { "../evil" })
    }

    @Test
    fun extension_unknown_isNull_neverUnsafe() {
        assertNull(LibraryFileNames.extensionFor(null, null))
        assertNull(LibraryFileNames.extensionFor("noextension", null))
        assertNull(LibraryFileNames.extensionFor("weird.ext/../../x", null))
        assertEquals("tmp", LibraryFileNames.extensionFor("track.tmp", null), "safe, if unknown")
    }

    @Test
    fun sniff_recognisesCommonContainers() {
        fun bytes(vararg parts: Any): ByteArray = parts.flatMap { part ->
            when (part) {
                is String -> part.toByteArray(Charsets.US_ASCII).toList()
                is Int -> listOf(part.toByte())
                else -> error("bad part")
            }
        }.toByteArray()
        assertEquals("flac", LibraryFileNames.sniffExtension(bytes("fLaC", 0, 0, 0, 34)))
        assertEquals("ogg", LibraryFileNames.sniffExtension(bytes("OggS", 0, 2)))
        assertEquals("wav", LibraryFileNames.sniffExtension(bytes("RIFF", 1, 2, 3, 4, "WAVE")))
        assertEquals("m4a", LibraryFileNames.sniffExtension(bytes(0, 0, 0, 32, "ftypM4A ")))
        assertEquals("mp3", LibraryFileNames.sniffExtension(bytes("ID3", 4, 0)))
        assertEquals("mp3", LibraryFileNames.sniffExtension(bytes(0xFF, 0xFB, 0x90)))
        assertEquals("aac", LibraryFileNames.sniffExtension(bytes(0xFF, 0xF1, 0x50)))
        assertNull(LibraryFileNames.sniffExtension(bytes("RIFF", 1, 2, 3, 4, "AVI ")))
        assertNull(LibraryFileNames.sniffExtension(ByteArray(0)))
    }

    // ------------------------------------------------------- session policies

    @Suppress("DEPRECATION")
    @Test
    fun mediaButtons_areClaimedExplicitly_onlyBelowApi26() {
        val legacy = MediaSession.FLAG_HANDLES_MEDIA_BUTTONS or
            MediaSession.FLAG_HANDLES_TRANSPORT_CONTROLS
        assertEquals(legacy, JamSessionPolicy.legacyMediaSessionFlags(24))
        assertEquals(legacy, JamSessionPolicy.legacyMediaSessionFlags(25))
        assertEquals(0, JamSessionPolicy.legacyMediaSessionFlags(26))
        assertEquals(0, JamSessionPolicy.legacyMediaSessionFlags(36))
    }

    @Suppress("DEPRECATION")
    @Test
    fun wifiLock_lowLatencyFrom29_highPerfOnlyWhereItStillWorks() {
        val high = WifiManager.WIFI_MODE_FULL_HIGH_PERF
        val low = WifiManager.WIFI_MODE_FULL_LOW_LATENCY
        assertContentEquals(intArrayOf(high), JamSessionPolicy.wifiLockModes(24))
        assertContentEquals(intArrayOf(high), JamSessionPolicy.wifiLockModes(28))
        assertContentEquals(intArrayOf(low, high), JamSessionPolicy.wifiLockModes(29))
        assertContentEquals(intArrayOf(low, high), JamSessionPolicy.wifiLockModes(33))
        assertContentEquals(intArrayOf(low), JamSessionPolicy.wifiLockModes(34))
        assertContentEquals(intArrayOf(low), JamSessionPolicy.wifiLockModes(36))
    }
}
