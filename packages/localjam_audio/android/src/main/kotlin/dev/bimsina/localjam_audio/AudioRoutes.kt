package dev.bimsina.localjam_audio

import android.media.AudioDeviceInfo
import java.security.MessageDigest

/**
 * One output device reduced to what route identity needs (localjam_audio
 * contract item 2). Built from an [AudioDeviceInfo] by the plugin; plain data
 * here so identity and route picking are unit-testable.
 *
 * [address] is a Bluetooth MAC for BT devices (anonymized by Android 14+ for
 * apps without BLUETOOTH_CONNECT, which still leaves it stable per device). It
 * only ever leaves this class hashed: never log a [RouteDevice] wholesale.
 */
internal class RouteDevice(val type: Int, val productName: String, val address: String) {
    /** Stable route id — see [AudioRoutes.routeId]. */
    val id: String by lazy { AudioRoutes.routeId(type, productName, address) }

    override fun toString(): String = "RouteDevice($id)" // no raw address in logs
}

internal object AudioRoutes {
    /**
     * Stable, privacy-preserving id for one output route: a readable type
     * tag plus the first 64 bits of SHA-256(type|productName|address). The
     * same headphones give the same id across sessions and reboots; a
     * different device (different name or address) gives a different one;
     * the raw MAC never appears. All wired headphones share one id — Android
     * cannot tell them apart either (iOS has the same limit).
     */
    fun routeId(type: Int, productName: String?, address: String?): String {
        val key = "$type|${productName.orEmpty()}|${address.orEmpty()}"
        val digest = MessageDigest.getInstance("SHA-256").digest(key.toByteArray(Charsets.UTF_8))
        val hex = StringBuilder(16)
        for (i in 0 until 8) {
            val b = digest[i].toInt() and 0xff
            hex.append(HEX[b ushr 4]).append(HEX[b and 0x0f])
        }
        return "${typeTag(type)}:$hex"
    }

    private val HEX = "0123456789abcdef".toCharArray()

    fun typeTag(type: Int): String = when (type) {
        AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> "earpiece"
        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER,
        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER_SAFE -> "speaker"
        AudioDeviceInfo.TYPE_WIRED_HEADSET -> "wired_headset"
        AudioDeviceInfo.TYPE_WIRED_HEADPHONES -> "wired_headphones"
        AudioDeviceInfo.TYPE_LINE_ANALOG,
        AudioDeviceInfo.TYPE_LINE_DIGITAL,
        AudioDeviceInfo.TYPE_AUX_LINE -> "line"
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> "bt_sco"
        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP -> "bt_a2dp"
        AudioDeviceInfo.TYPE_BLE_HEADSET,
        AudioDeviceInfo.TYPE_BLE_SPEAKER,
        AudioDeviceInfo.TYPE_BLE_BROADCAST -> "ble_audio"
        AudioDeviceInfo.TYPE_HEARING_AID -> "hearing_aid"
        AudioDeviceInfo.TYPE_HDMI,
        AudioDeviceInfo.TYPE_HDMI_ARC,
        AudioDeviceInfo.TYPE_HDMI_EARC -> "hdmi"
        AudioDeviceInfo.TYPE_USB_DEVICE,
        AudioDeviceInfo.TYPE_USB_ACCESSORY,
        AudioDeviceInfo.TYPE_USB_HEADSET -> "usb"
        AudioDeviceInfo.TYPE_DOCK,
        AudioDeviceInfo.TYPE_DOCK_ANALOG -> "dock"
        else -> "other"
    }

    /**
     * Media-routing preference for the fallback route guess (API < 33 with no
     * live track), modelled on AOSP's STRATEGY_MEDIA device order: Bluetooth
     * (LE, then A2DP), hearing aid, wired, USB, dock/HDMI/line, and the
     * built-in speaker last. 0 = never a media route (calls, telephony,
     * remote submix, buses, FM, …) — such devices are ignored entirely.
     */
    fun mediaPriority(type: Int): Int = when (type) {
        AudioDeviceInfo.TYPE_BLE_HEADSET,
        AudioDeviceInfo.TYPE_BLE_SPEAKER,
        AudioDeviceInfo.TYPE_BLE_BROADCAST -> 100
        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP -> 95
        AudioDeviceInfo.TYPE_HEARING_AID -> 90
        AudioDeviceInfo.TYPE_WIRED_HEADPHONES -> 85
        AudioDeviceInfo.TYPE_LINE_ANALOG -> 84
        AudioDeviceInfo.TYPE_WIRED_HEADSET -> 83
        AudioDeviceInfo.TYPE_USB_HEADSET -> 80
        AudioDeviceInfo.TYPE_USB_ACCESSORY -> 79
        AudioDeviceInfo.TYPE_USB_DEVICE -> 78
        AudioDeviceInfo.TYPE_DOCK,
        AudioDeviceInfo.TYPE_DOCK_ANALOG -> 70
        AudioDeviceInfo.TYPE_HDMI,
        AudioDeviceInfo.TYPE_HDMI_ARC,
        AudioDeviceInfo.TYPE_HDMI_EARC -> 65
        AudioDeviceInfo.TYPE_LINE_DIGITAL,
        AudioDeviceInfo.TYPE_AUX_LINE -> 60
        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> 10
        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER_SAFE -> 9
        AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> 1
        else -> 0
    }

    /** Whether media can play on [type] at all (see [mediaPriority]). */
    fun isMediaOutput(type: Int): Boolean = mediaPriority(type) > 0

    /** The phone's own speaker/earpiece — where audio lands when a device goes. */
    fun isBuiltIn(type: Int): Boolean = when (type) {
        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER,
        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER_SAFE,
        AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> true
        else -> false
    }

    /**
     * Best guess of the media route among [candidates] (the connected
     * outputs), skipping ids in [exclude]. Only a fallback: a live track's
     * routed device and API 33's getAudioDevicesForAttributes are exact.
     */
    fun pickMediaRoute(
        candidates: List<RouteDevice>,
        exclude: Set<String> = emptySet(),
    ): RouteDevice? = candidates
        .filter { isMediaOutput(it.type) && it.id !in exclude }
        .maxByOrNull { mediaPriority(it.type) }

    /**
     * Where media plays right after outputs were [added]. A live track's
     * routed device is STALE at this moment — AudioDeviceCallback fires
     * before AudioPolicy moves existing tracks — so it only counts once it
     * already sits on one of the added devices. Order: the audio policy's
     * own answer ([policyRoute], API 33+), then such a live route, then the
     * AOSP-like priority guess over every [connected] output. Matters
     * because §7 per-route latency calibration is keyed on the id reported
     * here: a stale id files the new headphones' calibration under the old
     * route.
     */
    fun routeAfterAddition(
        policyRoute: RouteDevice?,
        liveRoute: RouteDevice?,
        added: Set<String>,
        connected: List<RouteDevice>,
    ): RouteDevice? = policyRoute
        ?: liveRoute?.takeIf { it.id in added }
        ?: pickMediaRoute(connected)
}

/**
 * Turns raw route signals into `routeChanged` decisions (contract item 3).
 * Pure: the plugin supplies devices and clock; guarded by the plugin's lock.
 *
 * An unplug reaches us twice: ACTION_AUDIO_BECOMING_NOISY first (AudioService
 * sends it ~1 s BEFORE it reroutes, precisely so players can stop before the
 * speaker takes over), then onAudioDevicesRemoved once the device is gone.
 * The first one stops output and reports oldDeviceUnavailable; the second,
 * when it matches the same device inside [noisyWindowNs], is a plain route
 * change carrying the now-authoritative new routeId — one unplug, one
 * "old device unavailable".
 */
internal class RouteChangeTracker(private val noisyWindowNs: Long = 5_000_000_000L) {
    internal data class Decision(
        val stopOutput: Boolean,
        val oldDeviceUnavailable: Boolean,
        val routeId: String?,
    )

    /** The route media was last known to be on (before the change at hand). */
    var lastRouteId: String? = null
        private set

    /** Whether [lastRouteId] is the phone's own speaker/earpiece. */
    private var lastRouteBuiltIn = false

    private var noisyRouteId: String? = null
    private var noisyNextRouteId: String? = null
    private var noisyAtNs = 0L
    private var noisyPending = false

    /** Records the route as currently observed (attach, playAt, events). */
    fun observe(route: RouteDevice?) {
        if (route == null) return
        lastRouteId = route.id
        lastRouteBuiltIn = AudioRoutes.isBuiltIn(route.type)
    }

    /**
     * ACTION_AUDIO_BECOMING_NOISY. [goingRouteId] is the route still active
     * right now (the one about to disappear); [nextRouteId] the best guess of
     * where media lands next — corrected by the removal that follows.
     */
    fun onBecomingNoisy(nowNs: Long, goingRouteId: String?, nextRouteId: String?): Decision {
        noisyRouteId = goingRouteId ?: lastRouteId
        noisyNextRouteId = nextRouteId
        noisyAtNs = nowNs
        noisyPending = true
        return Decision(stopOutput = true, oldDeviceUnavailable = true, routeId = nextRouteId)
    }

    fun onDevicesAdded(newRoute: RouteDevice?): Decision {
        observe(newRoute)
        return Decision(stopOutput = false, oldDeviceUnavailable = false, routeId = newRoute?.id)
    }

    /**
     * Media sinks were removed ([removed], already filtered to media
     * outputs); [newRoute] is where media is routed now.
     */
    fun onDevicesRemoved(nowNs: Long, removed: List<RouteDevice>, newRoute: RouteDevice?): Decision {
        val previous = lastRouteId
        val previousBuiltIn = lastRouteBuiltIn
        lastRouteId = newRoute?.id
        lastRouteBuiltIn = newRoute != null && AudioRoutes.isBuiltIn(newRoute.type)
        val removedIds = removed.map { it.id }.toSet()
        // Lost the active route: either we knew it and it is in the removed
        // set, or (route knowledge was only a guess) an external device left
        // and media fell back to the phone itself — the case that matters.
        // The fallback clause never applies when media was KNOWN to be on the
        // phone already (the user picked "This phone" with earbuds still
        // connected): those earbuds leaving changes nothing audible.
        val lostActive = (previous != null && previous in removedIds) ||
            (
                (previous == null || !previousBuiltIn) &&
                    removed.any { !AudioRoutes.isBuiltIn(it.type) } &&
                    newRoute != null && AudioRoutes.isBuiltIn(newRoute.type)
                )
        val alreadyReported = noisyPending &&
            nowNs - noisyAtNs <= noisyWindowNs &&
            (noisyRouteId == null || noisyRouteId in removedIds)
        if (alreadyReported) noisyPending = false
        return if (lostActive && !alreadyReported) {
            Decision(stopOutput = true, oldDeviceUnavailable = true, routeId = newRoute?.id)
        } else {
            Decision(stopOutput = false, oldDeviceUnavailable = false, routeId = newRoute?.id)
        }
    }

    /**
     * Non-null when a playAt arriving now must be held back: a noisy is
     * pending (the device is leaving but the reroute has not happened), so
     * starting output would play on the departing device and then jump to
     * the speaker — the exact thing oldDeviceUnavailable exists to prevent.
     *
     * The returned decision is re-emitted for the held playAt rather than
     * swallowing it: that playAt may be the user pressing resume right after
     * the unplug (Dart cleared its own "output lost" state to send it), and
     * it must learn that nothing plays — exactly like a refused focus request
     * re-emits interruptionBegan. Output is already stopped, so no stop.
     */
    fun playbackHold(nowNs: Long): Decision? =
        if (noisyPending && nowNs - noisyAtNs <= NOISY_PLAY_HOLD_NS) {
            Decision(stopOutput = false, oldDeviceUnavailable = true, routeId = noisyNextRouteId)
        } else {
            null
        }

    private companion object {
        /** Long enough to cover AudioService's ~1 s noisy→reroute delay. */
        const val NOISY_PLAY_HOLD_NS = 2_000_000_000L
    }
}
