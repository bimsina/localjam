package np.com.bibektimsina.localjam

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// Session keep-alive and the OS media session live in the localjam_audio
// plugin (JamSessionService / JamMediaSessionManager) — nothing app-side.
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // A back at the app's root while a jam is live backgrounds the app
        // instead of finishing this activity, which would take the engine —
        // and the jam — with it (lib/src/widgets/live_jam_back.dart).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "localjam/task")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "moveToBack" -> result.success(moveTaskToBack(true))
                    else -> result.notImplemented()
                }
            }
    }
}
