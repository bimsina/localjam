package np.com.bibektimsina.localjam_audio

import android.content.ContentUris
import android.content.Context
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.provider.MediaStore
import android.webkit.MimeTypeMap
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Device music-library access over the `localjam_audio/library` channel
 * (there is no maintained cross-platform plugin for this in 2026; owning
 * ~150 lines of Kotlin matches the rest of this plugin's philosophy):
 *
 *  * `queryAudio` — one MediaStore sweep of the device's audio, returning
 *    `[{id, title, artist, album, durationMs, sizeBytes, contentUri,
 *    path?}]`. Requires `READ_MEDIA_AUDIO` (API 33+) or
 *    `READ_EXTERNAL_STORAGE` (below) to already be granted — the app owns
 *    the permission prompt; denied queries answer error `permission_denied`.
 *  * `resolveToPath {contentUri, id}` — a readable filesystem path for one
 *    track: the direct MediaStore path when the file is world-readable by
 *    this app, else a copy streamed into the app cache (scoped storage),
 *    named with the track's real extension ([LibraryFileNames]). LocalJam's
 *    host serves raw files, so a real path is non-negotiable.
 */
internal class JamMediaLibrary(
    private val context: Context,
    messenger: BinaryMessenger,
) {
    private val channel = MethodChannel(messenger, "localjam_audio/library")
    private val mainHandler = Handler(Looper.getMainLooper())
    private val thread = HandlerThread("localjam_library").apply { start() }
    private val handler = Handler(thread.looper)

    init {
        channel.setMethodCallHandler { call, result ->
            handler.post {
                try {
                    when (call.method) {
                        "queryAudio" -> reply(result) { it.success(queryAudio()) }
                        "resolveToPath" -> {
                            val uri = call.argument<String>("contentUri")
                            val id = call.argument<Number>("id")?.toLong()
                            if (uri == null || id == null) {
                                reply(result) {
                                    it.error("bad_args", "contentUri and id required", null)
                                }
                            } else {
                                val path = resolveToPath(uri, id)
                                reply(result) { it.success(path) }
                            }
                        }
                        else -> reply(result) { it.notImplemented() }
                    }
                } catch (e: SecurityException) {
                    reply(result) {
                        it.error("permission_denied", "audio library permission not granted", null)
                    }
                } catch (e: Throwable) {
                    reply(result) { it.error("internal", "${call.method} failed: $e", null) }
                }
            }
        }
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        thread.quitSafely()
    }

    /** Marshals the reply back to the platform thread. */
    private fun reply(result: MethodChannel.Result, block: (MethodChannel.Result) -> Unit) {
        mainHandler.post { block(result) }
    }

    private fun queryAudio(): List<Map<String, Any?>> {
        val projection = arrayOf(
            MediaStore.Audio.Media._ID,
            MediaStore.Audio.Media.TITLE,
            MediaStore.Audio.Media.ARTIST,
            MediaStore.Audio.Media.ALBUM,
            MediaStore.Audio.Media.DURATION,
            MediaStore.Audio.Media.SIZE,
            MediaStore.Audio.Media.DATA,
        )
        val tracks = ArrayList<Map<String, Any?>>()
        context.contentResolver.query(
            MediaStore.Audio.Media.EXTERNAL_CONTENT_URI,
            projection,
            "${MediaStore.Audio.Media.IS_MUSIC} != 0",
            null,
            "${MediaStore.Audio.Media.TITLE} COLLATE NOCASE ASC",
        )?.use { cursor ->
            val idCol = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media._ID)
            val titleCol = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.TITLE)
            val artistCol = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.ARTIST)
            val albumCol = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.ALBUM)
            val durationCol = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.DURATION)
            val sizeCol = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.SIZE)
            val dataCol = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.DATA)
            while (cursor.moveToNext()) {
                val id = cursor.getLong(idCol)
                val path = if (cursor.isNull(dataCol)) null else cursor.getString(dataCol)
                tracks.add(
                    mapOf(
                        "id" to id,
                        "title" to cursor.getString(titleCol),
                        // MediaStore reports "<unknown>" rather than null.
                        "artist" to cursor.getString(artistCol)
                            ?.takeIf { it.isNotBlank() && it != "<unknown>" },
                        "album" to cursor.getString(albumCol)
                            ?.takeIf { it.isNotBlank() && it != "<unknown>" },
                        "durationMs" to if (cursor.isNull(durationCol)) {
                            null
                        } else {
                            cursor.getLong(durationCol)
                        },
                        "sizeBytes" to cursor.getLong(sizeCol),
                        "contentUri" to ContentUris.withAppendedId(
                            MediaStore.Audio.Media.EXTERNAL_CONTENT_URI,
                            id,
                        ).toString(),
                        "path" to path,
                    ),
                )
            }
        }
        return tracks
    }

    private fun resolveToPath(contentUri: String, id: Long): String? {
        val uri = android.net.Uri.parse(contentUri)
        var displayName: String? = null
        var mimeType: String? = null
        // Fast path: the MediaStore DATA path, when this app can read it
        // (own uploads, pre-scoped-storage devices, some vendors).
        runCatching {
            context.contentResolver.query(
                uri,
                arrayOf(
                    MediaStore.Audio.Media.DATA,
                    MediaStore.Audio.Media.DISPLAY_NAME,
                    MediaStore.Audio.Media.MIME_TYPE,
                ),
                null,
                null,
                null,
            )?.use { cursor ->
                if (cursor.moveToFirst()) {
                    if (!cursor.isNull(1)) displayName = cursor.getString(1)
                    if (!cursor.isNull(2)) mimeType = cursor.getString(2)
                    if (!cursor.isNull(0)) {
                        val direct = File(cursor.getString(0))
                        if (direct.canRead()) return direct.absolutePath
                    }
                }
            }
        }
        if (mimeType == null) mimeType = runCatching { context.contentResolver.getType(uri) }.getOrNull()
        // Scoped-storage path: stream a copy into the app cache, cached by
        // MediaStore id (a re-pick reuses the copy). The copy keeps the
        // track's real extension: the host derives the served MIME type
        // from it, so an extensionless copy reached guests as
        // application/octet-stream.
        val dir = File(context.cacheDir, "localjam_library").apply { mkdirs() }
        dir.listFiles()
            ?.firstOrNull { it.name.startsWith("$id.") && !it.name.endsWith(".part") && it.length() > 0 }
            ?.let { return it.absolutePath }
        val tmp = File(dir, "$id.part")
        context.contentResolver.openInputStream(uri)?.use { input ->
            tmp.outputStream().use { output -> input.copyTo(output) }
        } ?: return null
        val ext = LibraryFileNames.extensionFor(displayName, mimeType, ::platformExtensionForMime)
            ?: LibraryFileNames.sniffExtension(readHeader(tmp))
            ?: LibraryFileNames.FALLBACK_EXTENSION
        val dest = File(dir, "$id.$ext")
        if (!tmp.renameTo(dest)) return null
        return dest.absolutePath
    }

    private fun platformExtensionForMime(mime: String): String? =
        MimeTypeMap.getSingleton().getExtensionFromMimeType(mime)

    private fun readHeader(file: File): ByteArray = try {
        file.inputStream().use { input ->
            val buf = ByteArray(12)
            var n = 0
            while (n < buf.size) {
                val r = input.read(buf, n, buf.size - n)
                if (r < 0) break
                n += r
            }
            buf.copyOf(n)
        }
    } catch (_: Throwable) {
        ByteArray(0)
    }
}

/**
 * The file extension a cached library copy is saved under — pure, so it is
 * unit-tested. The host serves raw files and the MIME it announces comes
 * from the extension (localjam_client `mimeForPath`), so these names match
 * that mapping: mp3, m4a, aac, wav, flac, ogg, opus.
 */
internal object LibraryFileNames {
    /** Last resort when nothing identifies the format. */
    const val FALLBACK_EXTENSION = "bin"

    private val SAFE_EXTENSION = Regex("^[a-z0-9]{1,5}$")

    private val MIME_EXTENSIONS = mapOf(
        "audio/mpeg" to "mp3",
        "audio/mp3" to "mp3",
        "audio/mpeg3" to "mp3",
        "audio/x-mpeg" to "mp3",
        "audio/mp4" to "m4a",
        "audio/x-m4a" to "m4a",
        "audio/m4a" to "m4a",
        "audio/mp4a-latm" to "m4a",
        "audio/aac" to "aac",
        "audio/aac-adts" to "aac",
        "audio/x-aac" to "aac",
        "audio/wav" to "wav",
        "audio/x-wav" to "wav",
        "audio/wave" to "wav",
        "audio/vnd.wave" to "wav",
        "audio/flac" to "flac",
        "audio/x-flac" to "flac",
        "audio/ogg" to "ogg",
        "application/ogg" to "ogg",
        "audio/vorbis" to "ogg",
        "audio/opus" to "opus",
    )

    /** Extensions the host maps to a real audio MIME type. */
    private val KNOWN_AUDIO_EXTENSIONS =
        setOf("mp3", "m4a", "mp4", "aac", "wav", "flac", "ogg", "oga", "opus")

    /**
     * Extension for a library copy, or null when nothing identifies it: the
     * DISPLAY_NAME's own extension when it is a known audio one (the real
     * file name wins), else the MIME type's (our table, then the platform's
     * [mimeLookup]), else whatever safe extension the name has. Lower-case,
     * no dot, always safe as a file-name suffix.
     */
    fun extensionFor(
        displayName: String?,
        mimeType: String?,
        mimeLookup: (String) -> String? = { null },
    ): String? {
        val nameExt = displayName?.substringAfterLast('.', "")?.lowercase()
            ?.takeIf { SAFE_EXTENSION.matches(it) }
        if (nameExt != null && nameExt in KNOWN_AUDIO_EXTENSIONS) return nameExt
        val mime = mimeType?.substringBefore(';')?.trim()?.lowercase()?.takeIf { it.isNotEmpty() }
        if (mime != null) {
            MIME_EXTENSIONS[mime]?.let { return it }
            runCatching { mimeLookup(mime) }.getOrNull()
                ?.lowercase()
                ?.takeIf { SAFE_EXTENSION.matches(it) }
                ?.let { return it }
        }
        return nameExt
    }

    /** Extension from a file's first bytes (magic numbers), or null. */
    fun sniffExtension(header: ByteArray): String? {
        fun at(offset: Int, ascii: String): Boolean =
            header.size >= offset + ascii.length &&
                ascii.indices.all { header[offset + it] == ascii[it].code.toByte() }
        return when {
            at(0, "fLaC") -> "flac"
            at(0, "OggS") -> "ogg"
            at(0, "RIFF") && at(8, "WAVE") -> "wav"
            at(4, "ftyp") -> "m4a"
            at(0, "ID3") -> "mp3"
            header.size >= 2 && header[0] == 0xFF.toByte() &&
                (header[1].toInt() and 0xF6) == 0xF0 -> "aac" // ADTS sync word
            header.size >= 2 && header[0] == 0xFF.toByte() &&
                (header[1].toInt() and 0xE0) == 0xE0 -> "mp3" // MPEG audio frame sync
            else -> null
        }
    }
}
