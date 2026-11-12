package np.com.bibektimsina.localjam_audio

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.drawable.Icon
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.util.Log
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * Process-wide LocalJam session state on Android: the OS [MediaSession]
 * (lock-screen / notification transport controls + metadata) and the
 * foreground-service keep-alive (wake + Wi-Fi locks) that keeps playback and
 * a host's server sockets alive while the app is backgrounded.
 *
 * Driven from Dart over two channels the plugin registers:
 *  * `localjam/keepalive` — `acquire` starts [JamSessionService] in the
 *    foreground, `release` stops it (the pre-existing contract of
 *    `JamKeepAlive` in package:localjam_client).
 *  * `localjam_audio/media_session` — `update {title, artist, ...}` /
 *    `clear`; transport commands flow back as
 *    `remoteCommand {command, positionUs?}`.
 *
 * The notification IS the media card: while now-playing state is set it is a
 * `MediaStyle` notification bound to the session (title/artist/artwork +
 * previous/play-pause/next actions per the sender's §5.6 capabilities);
 * cleared, it falls back to the quiet "session active" line. One service,
 * one notification.
 */
internal object JamMediaSessionManager {
    private const val TAG = "JamSession"

    private val mainHandler = Handler(Looper.getMainLooper())

    /** The Dart-facing media-session channel; last attached engine wins. */
    @Volatile var channel: MethodChannel? = null

    /**
     * The Dart-facing keep-alive channel, used to push [KEEP_ALIVE_LOST] when
     * the OS refuses the foreground service after `acquire` already returned.
     */
    @Volatile var keepAliveChannel: MethodChannel? = null

    /** Dart method invoked when a started keep-alive turns out not to hold. */
    const val KEEP_ALIVE_LOST = "keepAliveLost"

    /**
     * Installed by [LocaljamAudioPlugin]: tears playback down (writer thread
     * out of the AudioTrack, track released) before [release] stops the
     * foreground service. Dart's `stopSessionGuards` releases the keep-alive
     * BEFORE it disposes the player, so without this the service would be
     * stopped out from under a live writer thread.
     */
    @Volatile var onSessionEnding: (() -> Unit)? = null

    private var appContext: Context? = null
    private var session: MediaSession? = null

    /** Last received now-playing payload; null = cleared / none yet. */
    @Volatile private var nowPlaying: Map<*, *>? = null

    /** Whether the keep-alive service is (being) started. */
    private var serviceRunning = false

    /**
     * Artwork decoding: bitmaps arrive as encoded bytes and full-size album art
     * is far too big to decode on the main thread (or to hand to the binder),
     * so decoding happens here, downscaled, keyed by the sender's artworkId so
     * a re-push of the same track never decodes twice.
     */
    private val artworkExecutor = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "localjam-artwork").apply { isDaemon = true }
    }

    /** Both written on the main thread only; read from the platform thread. */
    @Volatile private var artworkKey: String? = null
    @Volatile private var artwork: Bitmap? = null

    /** Longest edge of a decoded artwork bitmap (px). */
    private const val ARTWORK_MAX_PX = 512

    fun attach(context: Context) {
        appContext = context.applicationContext
    }

    // ------------------------------------------------------------ keep-alive

    /**
     * Starts the keep-alive service, returning whether the OS accepted it.
     *
     * Android 12+ throws `ForegroundServiceStartNotAllowedException` when a
     * backgrounded app starts a foreground service outside an allowed
     * exemption, and 14+ can throw `SecurityException` when the FGS type or
     * its permission does not line up — both are `IllegalStateException` /
     * `SecurityException` subclasses that would otherwise crash the app on
     * the platform thread. A jam without a keep-alive still works while the
     * app is foregrounded, so this degrades to "no keep-alive" and lets Dart
     * decide what to tell the user (a host is the one that really wants to
     * know: its server dies with the process).
     */
    fun acquire(): Boolean {
        val context = appContext ?: return false
        val intent = Intent(context, JamSessionService::class.java)
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
            serviceRunning = true
            true
        } catch (e: Throwable) {
            Log.w(TAG, "foreground keep-alive refused by the OS", e)
            serviceRunning = false
            false
        }
    }

    /**
     * Stops the keep-alive service — after playback is torn down, never
     * before: [onSessionEnding] gets the writer thread out of the AudioTrack
     * and frees it first, so the service (and the media notification that goes
     * with it) outlives the audio it was keeping alive rather than the other
     * way round.
     */
    fun release() {
        val context = appContext ?: return
        try {
            onSessionEnding?.invoke()
        } catch (e: Throwable) {
            Log.w(TAG, "stopping playback before the keep-alive release failed", e)
        }
        serviceRunning = false
        try {
            context.stopService(Intent(context, JamSessionService::class.java))
        } catch (e: Throwable) {
            Log.w(TAG, "stopping the keep-alive service failed", e)
        }
    }

    /**
     * Stops the keep-alive when what it was keeping alive is gone without a
     * [release]: the Flutter engine was destroyed (plugin detach) or the task
     * was swiped out of recents. The server, the clock and the audio all live
     * in that engine, so a service that outlived it would hold a wake lock,
     * the Wi-Fi locks and a media notification whose buttons reach no one.
     * Playback is the caller's to stop: on detach the plugin frees its own
     * track, and [JamSessionService.onTaskRemoved] goes through [release].
     */
    fun stopOrphaned() {
        val context = appContext ?: return
        if (!serviceRunning) return
        serviceRunning = false
        try {
            context.stopService(Intent(context, JamSessionService::class.java))
        } catch (e: Throwable) {
            Log.w(TAG, "stopping the orphaned keep-alive service failed", e)
        }
    }

    /**
     * Called by the service when `startForeground` itself was refused: the
     * process has no keep-alive after all, so Dart is told rather than left
     * believing a backgrounded jam will survive.
     */
    fun onKeepAliveLost() {
        serviceRunning = false
        mainHandler.post { keepAliveChannel?.invokeMethod(KEEP_ALIVE_LOST, null) }
    }

    // --------------------------------------------------------- media session

    /**
     * Publishes one now-playing payload. The text lands immediately; artwork
     * follows on the decode thread when this payload carries a new
     * `artworkId`, so a 3 MB cover never stalls the main thread and the same
     * cover is decoded once per track, not once per position update.
     */
    fun update(payload: Map<*, *>) {
        nowPlaying = payload
        mainHandler.post {
            applyNowPlaying(payload)
            refreshNotification()
        }
        val key = payload["artworkId"] as? String
        val bytes = payload["artworkBytes"] as? ByteArray
        if (key != null && key == artworkKey) return // already decoded
        if (bytes == null || bytes.isEmpty()) {
            if (artwork == null && artworkKey == key) return // nothing to drop
            mainHandler.post {
                if (nowPlaying !== payload) return@post
                artworkKey = key
                artwork = null
                applyNowPlaying(payload)
                refreshNotification()
            }
            return
        }
        artworkExecutor.execute {
            val bitmap = decodeArtwork(bytes)
            mainHandler.post {
                // A newer payload already won the card: keep its artwork.
                if (nowPlaying !== payload) return@post
                artworkKey = key
                artwork = bitmap
                applyNowPlaying(payload)
                refreshNotification()
            }
        }
    }

    fun clear() {
        nowPlaying = null
        mainHandler.post {
            artworkKey = null
            artwork = null
            session?.isActive = false
            refreshNotification()
        }
    }

    /** Tears the session down entirely (plugin detach). */
    fun dispose() {
        nowPlaying = null
        mainHandler.post {
            artworkKey = null
            artwork = null
            session?.release()
            session = null
        }
    }

    /**
     * Decodes encoded artwork bytes, downscaled so the longest edge is at most
     * [ARTWORK_MAX_PX] — the media card never shows more, and an undecimated
     * cover is both a main-thread hazard and a binder-transaction one. Runs on
     * [artworkExecutor]; null on any decode failure (the card just has no art).
     */
    private fun decodeArtwork(bytes: ByteArray): Bitmap? = try {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        val longest = maxOf(bounds.outWidth, bounds.outHeight)
        var sample = 1
        while (longest > 0 && longest / sample > ARTWORK_MAX_PX) sample *= 2
        BitmapFactory.decodeByteArray(
            bytes, 0, bytes.size,
            BitmapFactory.Options().apply { inSampleSize = sample },
        )
    } catch (e: Throwable) {
        Log.w(TAG, "artwork decode failed", e)
        null
    }

    private fun ensureSession(): MediaSession? {
        val context = appContext ?: return null
        session?.let { return it }
        return try {
            MediaSession(context, "localjam").apply {
                // API 24-25 route headset/BT media buttons and transport
                // controls to a session only when it opts in (26+ always do).
                JamSessionPolicy.legacyMediaSessionFlags(Build.VERSION.SDK_INT)
                    .takeIf { it != 0 }
                    ?.let {
                        @Suppress("DEPRECATION")
                        setFlags(it)
                    }
                setCallback(object : MediaSession.Callback() {
                    override fun onPlay() = sendCommand("play")
                    override fun onPause() = sendCommand("pause")
                    override fun onSkipToNext() = sendCommand("next")
                    override fun onSkipToPrevious() = sendCommand("previous")
                    override fun onSeekTo(pos: Long) =
                        sendCommand("seek", positionUs = pos * 1000)
                })
                session = this
            }
        } catch (e: Throwable) {
            Log.e(TAG, "MediaSession creation failed", e)
            null
        }
    }

    /** Routes one transport command to Dart (notification action / callback). */
    fun sendCommand(command: String, positionUs: Long? = null) {
        mainHandler.post {
            val args = HashMap<String, Any>()
            args["command"] = command
            if (positionUs != null) args["positionUs"] = positionUs
            channel?.invokeMethod("remoteCommand", args)
        }
    }

    private fun applyNowPlaying(payload: Map<*, *>) {
        val session = ensureSession() ?: return
        val title = payload["title"] as? String ?: "LocalJam"
        val artist = payload["artist"] as? String
        val album = payload["album"] as? String
        val durationUs = (payload["durationUs"] as? Number)?.toLong()
        val positionUs = (payload["positionUs"] as? Number)?.toLong() ?: 0L
        val rate = (payload["rate"] as? Number)?.toFloat() ?: 1.0f
        val playing = payload["playing"] as? Boolean ?: false
        val sessionName = payload["sessionName"] as? String

        val metadata = MediaMetadata.Builder().apply {
            putString(MediaMetadata.METADATA_KEY_TITLE, title)
            if (artist != null) putString(MediaMetadata.METADATA_KEY_ARTIST, artist)
            if (album != null) putString(MediaMetadata.METADATA_KEY_ALBUM, album)
            // The subtitle every media surface shows: the artist when the tags
            // knew one, otherwise the room — a LocalJam card should say which
            // jam it belongs to, never a generic product line.
            putString(MediaMetadata.METADATA_KEY_DISPLAY_TITLE, title)
            (artist ?: sessionName)?.let {
                putString(MediaMetadata.METADATA_KEY_DISPLAY_SUBTITLE, it)
            }
            if (artist != null && sessionName != null) {
                putString(MediaMetadata.METADATA_KEY_DISPLAY_DESCRIPTION, sessionName)
            }
            if (durationUs != null) {
                putLong(MediaMetadata.METADATA_KEY_DURATION, durationUs / 1000)
            }
            // Decoded off the main thread and cached by artworkId (see update);
            // ART as well as ALBUM_ART because different surfaces read either.
            artwork?.let {
                putBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART, it)
                putBitmap(MediaMetadata.METADATA_KEY_ART, it)
            }
        }.build()

        var actions = 0L
        if (payload["canPlayPause"] as? Boolean ?: false) {
            actions = actions or PlaybackState.ACTION_PLAY or
                PlaybackState.ACTION_PAUSE or PlaybackState.ACTION_PLAY_PAUSE
        }
        if (payload["canNext"] as? Boolean ?: false) {
            actions = actions or PlaybackState.ACTION_SKIP_TO_NEXT
        }
        if (payload["canPrevious"] as? Boolean ?: false) {
            actions = actions or PlaybackState.ACTION_SKIP_TO_PREVIOUS
        }
        if (payload["canSeek"] as? Boolean ?: false) {
            actions = actions or PlaybackState.ACTION_SEEK_TO
        }
        val state = PlaybackState.Builder()
            .setActions(actions)
            .setState(
                if (playing) PlaybackState.STATE_PLAYING else PlaybackState.STATE_PAUSED,
                positionUs / 1000,
                if (playing) rate else 0f,
            )
            .build()

        session.setMetadata(metadata)
        session.setPlaybackState(state)
        session.isActive = true
    }

    // ---------------------------------------------------------- notification

    private const val CHANNEL_ID = "localjam_session"
    const val NOTIFICATION_ID = 0x10CA

    /** Logged once so a denied POST_NOTIFICATIONS is diagnosable, not noisy. */
    private var notificationsDeniedLogged = false

    /**
     * Re-posts the service notification to reflect the current state.
     *
     * On Android 13+ the user can refuse POST_NOTIFICATIONS. That costs the
     * media card and nothing else: `notify` is a silent no-op without the
     * permission, the foreground service still runs with its wake/Wi-Fi locks,
     * and [onKeepAliveLost] is NOT reported — the keep-alive is genuinely
     * held, it just has no visible notification. Skipping the post explicitly
     * (rather than relying on the no-op) keeps that distinction in the log.
     */
    private fun refreshNotification() {
        val context = appContext ?: return
        if (!serviceRunning) return
        val manager =
            context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        try {
            if (!manager.areNotificationsEnabled()) {
                if (!notificationsDeniedLogged) {
                    notificationsDeniedLogged = true
                    Log.i(
                        TAG,
                        "notifications are disabled for this app; the jam keep-alive still " +
                            "runs, only its media card is hidden",
                    )
                }
                return
            }
            manager.notify(NOTIFICATION_ID, buildNotification(context))
        } catch (e: Throwable) {
            Log.w(TAG, "notification refresh failed", e)
        }
    }

    /** The service's (foreground) notification for the current state. */
    fun buildNotification(context: Context): Notification {
        val manager =
            context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "LocalJam session",
                    NotificationManager.IMPORTANCE_LOW,
                ),
            )
        }
        val contentIntent =
            context.packageManager.getLaunchIntentForPackage(context.packageName)?.let {
                PendingIntent.getActivity(
                    context, 0, it,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                )
            }
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context)
        }
        builder
            // The LocalJam mark, not a generic play triangle: this is the one
            // glyph the status bar shows for a running jam.
            .setSmallIcon(R.drawable.ic_stat_localjam)
            .setContentIntent(contentIntent)
            .setOngoing(true)

        val payload = nowPlaying
        val token = session?.sessionToken
        val sessionName = payload?.get("sessionName") as? String
        if (payload == null || token == null) {
            return builder
                .setContentTitle(sessionName ?: "LocalJam session active")
                .setContentText("Keeping playback in sync")
                .build()
        }

        val playing = payload["playing"] as? Boolean ?: false
        val artist = payload["artist"] as? String
        builder
            .setContentTitle(payload["title"] as? String ?: "LocalJam")
            // Second line: who is playing, else which jam. Never a hardcoded
            // product string — the room name is the identity that matters.
            .setContentText(artist ?: sessionName ?: "LocalJam session")
            .setStyle(Notification.MediaStyle().setMediaSession(token))
        // Third line: the room, once the second line is spoken for.
        if (artist != null && sessionName != null) builder.setSubText(sessionName)
        // The cover, decoded and cached in `update`. MediaStyle also pulls
        // METADATA_KEY_ALBUM_ART from the session on newer SystemUI, but the
        // shade's own large icon is what older ones render.
        artwork?.let { builder.setLargeIcon(it) }

        fun action(icon: Int, label: String, command: String) = Notification.Action.Builder(
            Icon.createWithResource(context, icon),
            label,
            PendingIntent.getService(
                context,
                command.hashCode(),
                Intent(context, JamSessionService::class.java)
                    .setAction(JamSessionService.ACTION_COMMAND)
                    .putExtra(JamSessionService.EXTRA_COMMAND, command),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            ),
        ).build()

        if (payload["canPrevious"] as? Boolean ?: false) {
            builder.addAction(
                action(android.R.drawable.ic_media_previous, "Previous", "previous"),
            )
        }
        if (payload["canPlayPause"] as? Boolean ?: false) {
            builder.addAction(
                if (playing) {
                    action(android.R.drawable.ic_media_pause, "Pause", "pause")
                } else {
                    action(android.R.drawable.ic_media_play, "Play", "play")
                },
            )
        }
        if (payload["canNext"] as? Boolean ?: false) {
            builder.addAction(action(android.R.drawable.ic_media_next, "Next", "next"))
        }
        return builder.build()
    }
}

/**
 * Version-dependent session choices, pure so they are unit-tested.
 */
internal object JamSessionPolicy {
    /**
     * MediaSession flags to set explicitly: API 24-25 deliver media buttons
     * and transport controls only to sessions that set these (deprecated —
     * and always on — from API 26). 0 = set nothing.
     */
    @Suppress("DEPRECATION")
    fun legacyMediaSessionFlags(sdkInt: Int): Int =
        if (sdkInt < Build.VERSION_CODES.O) {
            MediaSession.FLAG_HANDLES_MEDIA_BUTTONS or MediaSession.FLAG_HANDLES_TRANSPORT_CONTROLS
        } else {
            0
        }

    /**
     * Wi-Fi lock modes to hold for a session, strongest first.
     *
     *  * API 29+: WIFI_MODE_FULL_LOW_LATENCY. It only takes effect while the
     *    app is foreground with the screen on.
     *  * API 29-33: ALSO WIFI_MODE_FULL_HIGH_PERF — documented to take over
     *    whenever LOW_LATENCY is inactive, i.e. exactly the screen-off,
     *    backgrounded host this lock exists for (no power-save, so guests'
     *    clock-sync pings are answered promptly).
     *  * API 34+: HIGH_PERF is deprecated and silently becomes a LOW_LATENCY
     *    lock, so holding it adds nothing.
     *  * Below 29: HIGH_PERF, the only mode there is.
     */
    @Suppress("DEPRECATION")
    fun wifiLockModes(sdkInt: Int): IntArray = when {
        sdkInt >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE ->
            intArrayOf(WifiManager.WIFI_MODE_FULL_LOW_LATENCY)
        sdkInt >= Build.VERSION_CODES.Q ->
            intArrayOf(WifiManager.WIFI_MODE_FULL_LOW_LATENCY, WifiManager.WIFI_MODE_FULL_HIGH_PERF)
        else -> intArrayOf(WifiManager.WIFI_MODE_FULL_HIGH_PERF)
    }
}

/**
 * The `mediaPlayback` foreground service keeping the app process — audio
 * playback and, on a host, the LocalJam server sockets — alive while the
 * app is backgrounded during an active jam session, holding a partial wake
 * lock and a Wi-Fi lock so clock-sync pings and the media plane keep
 * flowing with the screen off.
 *
 * Its notification is built by [JamMediaSessionManager]: the media card
 * when now-playing state is set, the quiet "session active" line otherwise.
 * Lifetime = session lifetime (acquire → release), NOT playback state — a
 * paused jam keeps its server alive.
 */
class JamSessionService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null
    private val wifiLocks = ArrayList<WifiManager.WifiLock>()

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Notification transport actions route back through the manager.
        if (intent?.action == ACTION_COMMAND) {
            intent.getStringExtra(EXTRA_COMMAND)?.let {
                JamMediaSessionManager.sendCommand(it)
            }
            return START_NOT_STICKY
        }
        if (!startAsForeground()) {
            // Without foreground status the service is killable at any moment
            // and the locks below would be a lie: stop, and tell Dart.
            JamMediaSessionManager.onKeepAliveLost()
            stopSelf()
            return START_NOT_STICKY
        }
        acquireLocks()
        // A session the OS killed is not resumed by restarting the service:
        // the engines re-acquire on the next session start.
        return START_NOT_STICKY
    }

    /**
     * The user swiped the app out of recents. The activity, and the Flutter
     * engine that runs the whole jam with it, are going away, so the session
     * is over: stop the audio and the service now rather than trust the
     * engine's own teardown to arrive (the process can be killed first, and
     * a foreground service is what would keep a half-dead one around).
     */
    override fun onTaskRemoved(rootIntent: Intent?) {
        JamMediaSessionManager.release()
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        wakeLock?.takeIf { it.isHeld }?.release()
        wakeLock = null
        wifiLocks.forEach { lock -> lock.takeIf { it.isHeld }?.release() }
        wifiLocks.clear()
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }

    /**
     * Goes foreground, returning whether the OS allowed it.
     *
     * The `mediaPlayback` type passed here MUST match
     * `android:foregroundServiceType` in the plugin manifest (it does) and be
     * backed by FOREGROUND_SERVICE_MEDIA_PLAYBACK, or API 34+ throws
     * `SecurityException`/`InvalidForegroundServiceTypeException`; API 31+
     * throws `ForegroundServiceStartNotAllowedException` when the start came
     * from the background. All of them are recoverable here — the jam simply
     * has no keep-alive — and none of them may take the app down.
     */
    private fun startAsForeground(): Boolean = try {
        val notification = JamMediaSessionManager.buildNotification(this)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                JamMediaSessionManager.NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK,
            )
        } else {
            startForeground(JamMediaSessionManager.NOTIFICATION_ID, notification)
        }
        true
    } catch (e: Throwable) {
        Log.w("JamSession", "startForeground refused by the OS", e)
        false
    }

    /** Best effort: a missing lock costs sync accuracy, never the session. */
    private fun acquireLocks() = try {
        acquireLocksOrThrow()
    } catch (e: Throwable) {
        Log.w("JamSession", "wake/Wi-Fi lock unavailable", e)
    }

    private fun acquireLocksOrThrow() {
        if (wakeLock == null) {
            // Deliberately SESSION-long (acquire → release), not tied to
            // playback state. The host is a server: while the jam is paused,
            // with the screen off, it must keep answering guests' clock-sync
            // pings and control traffic — a few seconds of host silence is
            // the guests' host-gone timeout (PROTOCOL.md) and they drop out
            // of a jam that is merely paused. Without a partial
            // wake lock the CPU suspends between packets and the host goes
            // dark. This is the "continue an ongoing user-initiated session"
            // case the mediaPlayback foreground-service type is for; it is
            // released the moment the session ends (release → onDestroy).
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "localjam:session").apply {
                setReferenceCounted(false)
                acquire()
            }
        }
        if (wifiLocks.isEmpty()) {
            val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            for (mode in JamSessionPolicy.wifiLockModes(Build.VERSION.SDK_INT)) {
                wifiLocks += wm.createWifiLock(mode, "localjam:session:$mode").apply {
                    setReferenceCounted(false)
                    acquire()
                }
            }
        }
    }

    companion object {
        const val ACTION_COMMAND = "np.com.bibektimsina.localjam_audio.COMMAND"
        const val EXTRA_COMMAND = "command"
    }
}
