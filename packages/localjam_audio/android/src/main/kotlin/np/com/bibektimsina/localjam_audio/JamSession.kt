package np.com.bibektimsina.localjam_audio

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.BitmapFactory
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

    private var appContext: Context? = null
    private var session: MediaSession? = null

    /** Last received now-playing payload; null = cleared / none yet. */
    private var nowPlaying: Map<*, *>? = null

    /** Whether the keep-alive service is (being) started. */
    private var serviceRunning = false

    fun attach(context: Context) {
        appContext = context.applicationContext
    }

    // ------------------------------------------------------------ keep-alive

    fun acquire() {
        val context = appContext ?: return
        serviceRunning = true
        val intent = Intent(context, JamSessionService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.startForegroundService(intent)
        } else {
            context.startService(intent)
        }
    }

    fun release() {
        val context = appContext ?: return
        serviceRunning = false
        context.stopService(Intent(context, JamSessionService::class.java))
    }

    // --------------------------------------------------------- media session

    fun update(payload: Map<*, *>) {
        nowPlaying = payload
        mainHandler.post {
            applyNowPlaying(payload)
            refreshNotification()
        }
    }

    fun clear() {
        nowPlaying = null
        mainHandler.post {
            session?.isActive = false
            refreshNotification()
        }
    }

    /** Tears the session down entirely (plugin detach). */
    fun dispose() {
        nowPlaying = null
        mainHandler.post {
            session?.release()
            session = null
        }
    }

    private fun ensureSession(): MediaSession? {
        val context = appContext ?: return null
        session?.let { return it }
        return try {
            MediaSession(context, "localjam").apply {
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
        val artworkBytes = payload["artworkBytes"] as? ByteArray

        val metadata = MediaMetadata.Builder().apply {
            putString(MediaMetadata.METADATA_KEY_TITLE, title)
            if (artist != null) putString(MediaMetadata.METADATA_KEY_ARTIST, artist)
            if (album != null) putString(MediaMetadata.METADATA_KEY_ALBUM, album)
            if (durationUs != null) {
                putLong(MediaMetadata.METADATA_KEY_DURATION, durationUs / 1000)
            }
            if (artworkBytes != null) {
                try {
                    val bitmap =
                        BitmapFactory.decodeByteArray(artworkBytes, 0, artworkBytes.size)
                    if (bitmap != null) {
                        putBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART, bitmap)
                    }
                } catch (e: Throwable) {
                    Log.w(TAG, "artwork decode failed", e)
                }
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

    /** Re-posts the service notification to reflect the current state. */
    private fun refreshNotification() {
        val context = appContext ?: return
        if (!serviceRunning) return
        val manager =
            context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        try {
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
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentIntent(contentIntent)
            .setOngoing(true)

        val payload = nowPlaying
        val token = session?.sessionToken
        if (payload == null || token == null) {
            return builder
                .setContentTitle("LocalJam session active")
                .setContentText("Keeping playback in sync")
                .build()
        }

        val playing = payload["playing"] as? Boolean ?: false
        builder
            .setContentTitle(payload["title"] as? String ?: "LocalJam")
            .setContentText(payload["artist"] as? String ?: "LocalJam session")
            .setStyle(Notification.MediaStyle().setMediaSession(token))

        fun action(icon: Int, label: String, command: String) = Notification.Action.Builder(
            android.graphics.drawable.Icon.createWithResource(context, icon),
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
    private var wifiLock: WifiManager.WifiLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Notification transport actions route back through the manager.
        if (intent?.action == ACTION_COMMAND) {
            intent.getStringExtra(EXTRA_COMMAND)?.let {
                JamMediaSessionManager.sendCommand(it)
            }
            return START_NOT_STICKY
        }
        startAsForeground()
        acquireLocks()
        // A session the OS killed is not resumed by restarting the service:
        // the engines re-acquire on the next session start.
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        wakeLock?.takeIf { it.isHeld }?.release()
        wakeLock = null
        wifiLock?.takeIf { it.isHeld }?.release()
        wifiLock = null
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }

    private fun startAsForeground() {
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
    }

    private fun acquireLocks() {
        if (wakeLock == null) {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "localjam:session").apply {
                setReferenceCounted(false)
                acquire()
            }
        }
        if (wifiLock == null) {
            val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            @Suppress("DEPRECATION") // HIGH_PERF: LOW_LATENCY only works foregrounded.
            wifiLock = wm.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "localjam:session").apply {
                setReferenceCounted(false)
                acquire()
            }
        }
    }

    companion object {
        const val ACTION_COMMAND = "np.com.bibektimsina.localjam_audio.COMMAND"
        const val EXTRA_COMMAND = "command"
    }
}
