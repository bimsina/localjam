package dev.bimsina.localjam_audio

import android.media.MediaCodecList
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.util.Log
import java.io.File
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap

/**
 * Metadata-only duration reading (localjam_audio contract item 1). Shared by
 * `load` and `probeDuration` so both report the IDENTICAL number for a file —
 * a playlist built from probes must agree with what playback clamps against.
 *
 * Owns nothing but its own MediaExtractor/MediaMetadataRetriever per call, so
 * it never touches the playback engine and any number of probes can run
 * concurrently with each other and with playback.
 */
internal object DurationProbe {
    private const val TAG = "LocaljamAudio"

    /**
     * Duration of the first audio track of [path] in µs — what `load` would
     * return — or null when `load` would refuse the file: missing,
     * unreadable, no audio track, no decoder on this device for its codec, a
     * format outside [PlaybackLimits.fileProblem] or no determinable
     * duration. Metadata only: unlike `load` it does not decode the first
     * buffer (that costs a codec instance), so a file whose codec exists but
     * produces no audio still probes non-null. Never throws.
     */
    fun probeDurationUs(path: String): Long? {
        if (!File(path).isFile) return null
        val extractor = MediaExtractor()
        return try {
            extractor.setDataSource(path)
            val (trackIndex, format) = findAudioTrack(extractor) ?: return null
            val mime = format.getString(MediaFormat.KEY_MIME) ?: return null
            if (!hasDecoder(mime)) return null
            extractor.selectTrack(trackIndex)
            val durationUs = durationUs(extractor, format, path)
            // The container's format: a decoder may report a different
            // output rate (HE-AAC's 2× SBR), within the same bounds.
            val sampleRate = format.intOrNull(MediaFormat.KEY_SAMPLE_RATE) ?: return null
            val channels = format.intOrNull(MediaFormat.KEY_CHANNEL_COUNT) ?: return null
            durationUs.takeIf { PlaybackLimits.fileProblem(sampleRate, channels, durationUs) == null }
        } catch (e: Throwable) {
            Log.w(TAG, "probeDuration: could not read $path: $e")
            null
        } finally {
            try {
                extractor.release()
            } catch (_: Throwable) {
            }
        }
    }

    /** MIME type (lower case) → whether any decoder on this device takes it. */
    private val decoderSupport = ConcurrentHashMap<String, Boolean>()

    /**
     * Whether this device has a decoder for [mime] — the question
     * `MediaCodec.createDecoderByType` (which `load` uses) answers by
     * throwing. Cached: the codec list is fixed for the process.
     */
    fun hasDecoder(mime: String): Boolean {
        val key = mime.lowercase(Locale.ROOT)
        return decoderSupport.getOrPut(key) {
            try {
                MediaCodecList(MediaCodecList.ALL_CODECS).codecInfos.any { info ->
                    !info.isEncoder && info.supportedTypes.any { it.equals(key, ignoreCase = true) }
                }
            } catch (e: Throwable) {
                Log.w(TAG, "codec list unavailable: $e")
                true // unknown: let load be the judge rather than hide the file
            }
        }
    }

    private fun MediaFormat.intOrNull(key: String): Int? =
        if (containsKey(key)) getInteger(key) else null

    /** First audio track of [extractor], or null. */
    fun findAudioTrack(extractor: MediaExtractor): Pair<Int, MediaFormat>? {
        for (i in 0 until extractor.trackCount) {
            val f = extractor.getTrackFormat(i)
            val mime = f.getString(MediaFormat.KEY_MIME) ?: continue
            if (mime.startsWith("audio/")) return i to f
        }
        return null
    }

    /**
     * Duration chain: KEY_DURATION → MediaMetadataRetriever → compressed
     * packet scan (still no decode; a full decode-count is deliberately
     * avoided — that is the O(file) cost a probe must not pay). −1 when
     * unknown. [extractor] must have the audio track selected; a scan leaves
     * it rewound to the start.
     */
    fun durationUs(extractor: MediaExtractor, format: MediaFormat, path: String): Long {
        var durationUs = if (format.containsKey(MediaFormat.KEY_DURATION)) {
            format.getLong(MediaFormat.KEY_DURATION)
        } else {
            -1L
        }
        if (durationUs <= 0) durationUs = retrieverDurationUs(path)
        if (durationUs <= 0) {
            Log.w(TAG, "no duration metadata for $path; scanning packet pts")
            durationUs = scanDurationUs(extractor)
            extractor.seekTo(0, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
        }
        return durationUs
    }

    /** Duration via MediaMetadataRetriever (ms metadata), −1 when unknown. */
    private fun retrieverDurationUs(path: String): Long {
        val r = MediaMetadataRetriever()
        return try {
            r.setDataSource(path)
            val ms = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                ?.toLongOrNull() ?: -1L
            if (ms > 0) ms * 1000 else -1L
        } catch (_: Throwable) {
            -1L
        } finally {
            try {
                r.release()
            } catch (_: Throwable) {
            }
        }
    }

    /**
     * Last-resort duration: walk the remaining compressed packets (sampleTime
     * + advance — no decode, no sample reads) and estimate duration as the
     * last pts plus one inter-packet gap.
     */
    private fun scanDurationUs(extractor: MediaExtractor): Long {
        var prev = -1L
        var last = -1L
        while (true) {
            val t = extractor.sampleTime
            if (t < 0) break
            if (t > last) {
                prev = last
                last = t
            }
            if (!extractor.advance()) break
        }
        if (last < 0) return -1
        return last + if (prev in 0 until last) last - prev else 0
    }
}
