package np.com.bibektimsina.localjam_app

import android.content.Intent
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Session keep-alive requested by the LocalJam engines (Dart side:
        // JamKeepAlive in package:localjam_client): a foreground service +
        // wake/Wi-Fi locks while a jam session is active.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "localjam/keepalive")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "acquire" -> {
                        val intent = Intent(this, KeepAliveService::class.java)
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(intent)
                        } else {
                            startService(intent)
                        }
                        result.success(null)
                    }
                    "release" -> {
                        stopService(Intent(this, KeepAliveService::class.java))
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
