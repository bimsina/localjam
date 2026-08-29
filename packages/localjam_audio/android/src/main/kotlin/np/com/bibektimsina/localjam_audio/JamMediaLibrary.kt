package np.com.bibektimsina.localjam_audio

import android.content.ContentUris
import android.content.Context
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.provider.MediaStore
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
 *    this app, else a copy streamed into the app cache (scoped storage).
 *    LocalJam's host serves raw files, so a real path is non-negotiable.
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
        // Fast path: the MediaStore DATA path, when this app can read it
        // (own uploads, pre-scoped-storage devices, some vendors).
        runCatching {
            context.contentResolver.query(
                android.net.Uri.parse(contentUri),
                arrayOf(MediaStore.Audio.Media.DATA),
                null,
                null,
                null,
            )?.use { cursor ->
                if (cursor.moveToFirst() && !cursor.isNull(0)) {
                    val direct = File(cursor.getString(0))
                    if (direct.canRead()) return direct.absolutePath
                }
            }
        }
        // Scoped-storage path: stream a copy into the app cache. Content is
        // cached by MediaStore id; a re-pick reuses the copy.
        val dir = File(context.cacheDir, "localjam_library").apply { mkdirs() }
        val dest = File(dir, "$id.audio")
        if (dest.exists() && dest.length() > 0) return dest.absolutePath
        val tmp = File(dir, "$id.part")
        context.contentResolver.openInputStream(android.net.Uri.parse(contentUri))?.use { input ->
            tmp.outputStream().use { output -> input.copyTo(output) }
        } ?: return null
        if (!tmp.renameTo(dest)) return null
        return dest.absolutePath
    }
}
