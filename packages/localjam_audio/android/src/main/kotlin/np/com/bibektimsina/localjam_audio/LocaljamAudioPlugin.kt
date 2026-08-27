package np.com.bibektimsina.localjam_audio

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

/**
 * LocaljamAudioPlugin — Android STUB.
 *
 * The real Android implementation (ExoPlayer/Oboe scheduled playback,
 * PROTOCOL.md §5.3–§5.4) is a later milestone. Only the clock ('nowUs') and
 * 'outputLatencyUs' answer; every playback method throws
 * PlatformException("unimplemented").
 */
class LocaljamAudioPlugin :
    FlutterPlugin,
    MethodCallHandler {
    private lateinit var channel: MethodChannel

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(flutterPluginBinding.binaryMessenger, "localjam_audio")
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(
        call: MethodCall,
        result: Result
    ) {
        when (call.method) {
            // Monotonic clock in µs; the timebase 'playAt' will use once the
            // Android engine lands.
            "nowUs" -> result.success(System.nanoTime() / 1000)
            // Unknown until the real engine reports it (§7): 0 = "unknown".
            "outputLatencyUs" -> result.success(0L)
            "load", "playAt", "pause", "stop", "positionUs", "setRate", "dispose" ->
                result.error(
                    "unimplemented",
                    "localjam_audio: '${call.method}' is not implemented on Android yet",
                    null
                )
            else -> result.notImplemented()
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }
}
