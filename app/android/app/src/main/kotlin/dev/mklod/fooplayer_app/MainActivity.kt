package dev.mklod.fooplayer_app

import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// AudioServiceActivity, not FlutterActivity: audio_service runs playback in a
// foreground service with its own Flutter engine, and the activity has to
// hand its engine over rather than starting a second one. With a plain
// FlutterActivity the notification appears but its buttons talk to an engine
// that isn't the one making sound.
class MainActivity : AudioServiceActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // Back at the root of the app sends it to the background
                    // rather than finishing the activity. Finishing tears the
                    // UI down, so coming back re-reads the whole library --
                    // minutes on this library -- and loses where you were.
                    // moveTaskToBack is what the system Back gesture does for
                    // a launcher-rooted task, and it leaves playback and the
                    // foreground service exactly as they are.
                    "moveToBackground" -> result.success(moveTaskToBack(true))
                    else -> result.notImplemented()
                }
            }
    }

    companion object {
        private const val CHANNEL = "dev.mklod.fooplayer/app"
    }
}
